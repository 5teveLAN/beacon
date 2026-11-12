"""
BLE Beacon Scanner (bleak 版本)

改用 bleak (BlueZ) 做 *active scan*，主動觸發 scan response，
以取得手機 App 放在 scan response 裡的 Service Data (AD Type 0x16)。
原 adafruit_ble 在 BlueZ 上不易收到 scan response，故改用 bleak。

MQTT 改用 paho-mqtt，以支援 **wss（MQTT over WebSocket + TLS）**：
adafruit_minimqtt 只做原生 TCP/TLS socket，沒有 WebSocket handshake，
無法連上 mosquitto 的 `protocol websockets` listener（例如經過 Cloudflare
Tunnel 的 `wss://<host>:443/`）。paho 的 transport/ws_set_options/tls_set
與本專案 indoor-locator（mqtt_in / mqtt_out）用法一致。

⚠️ 收不到 session_key（資料一直 publish 不出去）的兩個坑，已在本檔修正：
  1. 【根本原因】`__mqtt_message_handler` 的簽章寫成 `(client, topic, message)`，
     但 paho 的 on_message 是 `(client, userdata, message)` —— 第 2 個參數是
     userdata（None），不是 topic。於是 `topic_str` 永遠是字串 "None"，
     永遠不等於 `SESSION_KEY_TOPIC`，`handle_session_key()` 從來沒被呼叫，
     `CURRENT_XOR_KEY` 一直是 None → 每輪掃描都走「沒有金鑰」分支，
     封包被默默丟棄（log 只有 TARGET UUID MATCH，沒有任何解密訊息）。
     現在 topic 一律取自 `message.topic`，並在檔尾加簽章防護檢查。
  2. 重複訂閱同一個 topic：paho 的待確認訂閱以 topic 為 key，SUBACK 之前再
     subscribe() 一次會覆蓋原本那筆，SUBACK 到達時被當成「已訂閱」而忽略，
     → retained 的 session_key 永遠不會送來。現在統一由 on_connect 呼叫
     _subscribe_session_key()（冪等），其他地方不再 subscribe()。
     另外也不要同時使用 loop_start() 與 loop()：兩個執行緒搶讀同一個 socket，
     會出現莫名的 on_disconnect 與重連風暴。現在只有 loop_start() 讀 socket，
     _mqtt_keepalive_thread() 只負責斷線後 reconnect()。
"""

import asyncio
import json
import logging
import os
import socket as _socket
import threading
import time

from bleak import BleakScanner
from bleak.exc import BleakError

# ─── logging ─────────────────────────────────────
# 這裡**刻意**開 bleak 自己的 logger（WARNING 以上）：
# BlueZ 出問題時真正的訊息（例如 "le-connection-abort-by-local"、
# D-Bus 斷線）是 bleak/dbus-fast 用 logging 發出的，不是例外，
# 過去只印自己那行 `BLE bleak error ...` 完全看不到原因。
# 用 WARNING 而不是 INFO，避免每 3 秒一輪掃描把 journal 洗版。
logging.basicConfig(
    level=logging.WARNING,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
_ble_logger = logging.getLogger("ble-scanner")

import paho.mqtt.client as paho_mqtt

# Get wifi details and more from a secrets.py file
try:
    from my_secrets import mqtt_env, RECEIVER_NO, USE_TEST_MODE
except ImportError:
    print("WiFi secrets are kept in secrets.py, please add them there!")
    raise

# ─── 測試模式固定參數 ──────────────────────────
# 參考 ble-packet-encryption.md 5.2
TEST_XOR_KEY = "TEST_KEY_2024"

# ─── 全域 XOR Key（可被 MQTT session_key 更新）────
# 初始值視模式而定：
#   USE_TEST_MODE=True  → 固定用 TEST_XOR_KEY（離線自測、手機 App 也用同一把時）
#   USE_TEST_MODE=False → None（正式模式），等 MQTT {topic}/session_key 送來才解密。
#                         收到前不應該用測試金鑰硬解，否則只會得到亂碼。
CURRENT_XOR_KEY = TEST_XOR_KEY if USE_TEST_MODE else None
# 正式模式下「尚未收到 session_key」的提示只印一次（避免每 3 秒洗版）
_missing_key_warned = False
# 同上：尚未收到 session_id 的提示只印一次
_missing_session_warned = False
# 上次印出的金鑰（只在金鑰變動時提示，避免洗版）
_last_logged_key = None
# 是否印出每筆 publish 的確認訊息（每 3 秒就有資料，預設關閉以免洗版）
_mqtt_verbose = os.environ.get("MQTT_VERBOSE", "0") == "1"
# SUBACK 前的訂閱是「尚未確認」的，broker 不會下發 retained 訊息。
# 若在 SUBACK 前就對同一 topic 再 subscribe()，SUBACK 到達時就會被標成已確認，
# on_subscribe 不會重送 SUBSCRIBE → retained 的 session_key 永遠收不到。
# 因此下列旗標記錄「是否已經送過 SUBSCRIBE」，避免重複送出。
_session_key_subscribe_pending = False
_session_key_subscribed = False
# 是否已收到過任何 session_key（用來判斷「重連後要不要重新提示」）
_session_key_received = False
# 目前生效的 session_id（來自 §1.1 {topic}/session_key 的 payload）。
#
# ★ 為什麼需要它：§1.2 的 payload 規格要求帶 session_id 與 OTP，
#   但舊版只送 student_id / mac / rssi / scanner_id / time ——
#   定位程式（indoor-locator）在「第 2 關：session_id 是已知場次？」就把每封
#   封包丟掉，於是永遠湊不到三台感測器、也不會定位，§2.1 一律 504 timeout。
#   2026-10-26 在部署機（192.168.31.200）上就是這個狀況：
#   封包在 broker 上明明看得到，定位程式卻一個字都沒印。
#   session_id 由 server 在 §1.1 發布，這裡收下並附在每筆 §1.2 payload 裡。
CURRENT_SESSION_ID = None


# ─── Service UUID ────────────────────────────
# 學生端 App 廣播時用的完整 UUID
SERVICE_UUID = "00001111-0000-1000-8000-00805f9b34fb"
# 縮短成 16-bit 的表示法，用來比對 service_data / service_uuids 的 key
SERVICE_UUID_SHORT = "1111"

# ─── MQTT 設定 ──────────────────────────────
# 連線方式由 my_secrets.py 的 mqtt_env 決定（皆為選填，預設＝原生 TCP 明文）：
#   "transport": "tcp" | "websockets"   websockets ⇒ ws:// 或 wss://
#   "use_tls":   True | False           開啟 TLS（websockets ⇒ wss，tcp ⇒ mqtts）
#   "ws_path":   "/"                    websockets 的 path（Cloudflare 常見 '/'）
#   "ca_certs":  "/path/ca.crt" | None  自簽憑證時指定 CA（正式憑證留 None 即可）
MQTT_BROKER = mqtt_env["broker"]
MQTT_PORT = mqtt_env["port"]
MQTT_TRANSPORT = mqtt_env.get("transport", "tcp")
MQTT_USE_TLS = bool(mqtt_env.get("use_tls", False))
MQTT_WS_PATH = mqtt_env.get("ws_path", "/")
MQTT_CA_CERTS = mqtt_env.get("ca_certs")
# 帳號（僅供 log 顯示；實際認證在 username_pw_set 用同一組值）
MQTT_USERNAME = mqtt_env.get("username")

if MQTT_TRANSPORT not in ("tcp", "websockets"):
    print(f"    ⚠️ 未知的 transport {MQTT_TRANSPORT!r}，改用 'tcp'")
    MQTT_TRANSPORT = "tcp"


def _mqtt_proto_name() -> str:
    """回傳目前設定的協定名稱（僅供 log 顯示）。"""
    if MQTT_TRANSPORT == "websockets":
        return "wss" if MQTT_USE_TLS else "ws"
    return "mqtts" if MQTT_USE_TLS else "mqtt"


# client_id 必須唯一：同 id 的新連線會把舊的踢掉（互踢風暴）。
MQTT_CLIENT_ID = f"beacon-receiver-{RECEIVER_NO}-{_socket.gethostname()[:20]}"

# VERSION1 沿用既有 handler 簽章（rc 為 int），與 indoor-locator 一致。
mqtt_client = paho_mqtt.Client(
    paho_mqtt.CallbackAPIVersion.VERSION1,
    MQTT_CLIENT_ID,
    transport=MQTT_TRANSPORT,
)
if MQTT_TRANSPORT == "websockets":
    mqtt_client.ws_set_options(path=MQTT_WS_PATH)
if mqtt_env.get("username") is not None:
    mqtt_client.username_pw_set(mqtt_env["username"], mqtt_env.get("password"))
if MQTT_USE_TLS:
    # ca_certs=None ⇒ 用系統預設 CA（Cloudflare 等正式憑證）；
    # 自簽憑證則在 mqtt_env 指定 "ca_certs"。
    mqtt_client.tls_set(ca_certs=MQTT_CA_CERTS)


# MQTT Event Handlers
# paho-mqtt 2.x 的 on_connect rc 對應（VERSION1 回傳整數）
MQTT_RC_MEANING = {
    0: "連線成功",
    1: "MQTT 版本不被接受",
    2: "client identifier 被拒絕",
    3: "broker 無法使用",
    4: "帳號或密碼錯誤",           # 常見：username / password 打錯
    5: "未授權（Not Authorized）",  # 常見：ACL 不允許這個帳號，或密碼錯
}


def _subscribe_session_key(reason: str = ""):
    """訂閱 {topic}/session_key —— 全程式唯一的訂閱入口，確保冪等。

    paho 的 `_out_messages` 會以 topic 為 key 記錄「待確認」的訂閱，
    同一個 topic 在 SUBACK 前重複 subscribe() 會覆蓋掉原本那筆，
    SUBACK 到達時就變成「已在訂閱清單裡」而被忽略（見檔頭說明）。
    因此：
      - 已送出 SUBSCRIBE、還沒等到 SUBACK → 不再重送；
      - 已收到 SUBACK（訂閱成功）        → 也不重送；
    只有「沒送過」或「上次斷線」時才會真正呼叫 subscribe()。
    """
    global _session_key_subscribe_pending
    if _session_key_subscribe_pending or _session_key_subscribed:
        if _mqtt_verbose:
            print(f"     （略過重複訂閱 {SESSION_KEY_TOPIC}{'，' + reason if reason else ''}）")
        return
    mqtt_client.subscribe(SESSION_KEY_TOPIC)
    _session_key_subscribe_pending = True
    print(f"     已送出訂閱 {SESSION_KEY_TOPIC}" + (f"（{reason}）" if reason else ""))


def __mqtt_subscribe_handler(mqtt_client, userdata, mid, granted_qos, *args):
    """SUBACK：訂閱已由 broker 確認，之後 retained 訊息會補送過來。

    paho-mqtt 2.x 的 on_subscribe 簽名（依 callback_api_version）：
      VERSION1 → on_subscribe(client, userdata, mid, granted_qos)         共 4 個
      VERSION2 → on_subscribe(client, userdata, mid, rc, props)           共 5 個
    用 *args 兼容兩種版本；granted_qos 在 VERSION2 是 ReasonCode 清單。
    """
    global _session_key_subscribe_pending, _session_key_subscribed
    _session_key_subscribe_pending = False
    _session_key_subscribed = True
    print(f"     ✅ 訂閱已確認 (MID {mid}, granted_qos={granted_qos}) {SESSION_KEY_TOPIC}")
    if not _session_key_received:
        print("     （若 broker 上有 retained 的 session_key，會緊接著送來）")


def __mqtt_connect_handler(mqtt_client, userdata, flags, rc):
    # 注意：rc != 0 時不代表連線成功，不能一律印 "Successfully connected"
    if rc != 0:
        reason = MQTT_RC_MEANING.get(rc, "未知錯誤")
        print(f"❌ MQTT 連線被拒絕：RC={rc}（{reason}）")
        print(f"     broker={MQTT_BROKER}:{MQTT_PORT} user={MQTT_USERNAME!r}")
        print("     檢查 my_secrets.py 的 username/password，以及 broker 的 ACL 設定。")
        return

    print("Successfully connected to MQTT broker.")
    print("     Flags: {0}\n     RC: {1}".format(flags, rc))

    # 每次（重新）連線，paho 都會清掉訂閱記錄，所以這裡要重置旗標再訂閱。
    global _session_key_subscribe_pending, _session_key_subscribed, _session_key_received
    _session_key_subscribe_pending = False
    _session_key_subscribed = False
    _session_key_received = False

    # 認證成功後才訂閱（rc=5 時訂閱不會生效，重連也不會補上）
    # retainer：session_key 是 retained，broker 會在 SUBACK 後立刻補送最新一筆。
    _subscribe_session_key("on_connect")


def __mqtt_disconnect_handler(mqtt_client, userdata, rc):
    print(f"Disconnected from MQTT broker. (rc={rc})")
    global _session_key_subscribe_pending, _session_key_subscribed
    _session_key_subscribe_pending = False
    _session_key_subscribed = False
    # rc=0 是我們自己 disconnect()（例如測試模式收尾），其餘是意外斷線：
    # 把金鑰狀態標成「未收到」，重連後若仍拿不到 retained 金鑰會再提示一次。
    global _session_key_received
    if rc != 0:
        _session_key_received = False


def __mqtt_publish_handler(mqtt_client, userdata, mid, *args):
    # paho-mqtt 2.x 的 on_publish 簽名依 callback_api_version 而不同：
    #   VERSION1（本程式用的）→ on_publish(client, userdata, mid)          共 3 個
    #   VERSION2             → on_publish(client, userdata, mid, rc, props) 共 5 個
    # 舊版寫成 (client, userdata, topic, pid) 需要 4 個參數，但 VERSION1 只傳 3 個，
    # 每次發布都會拋 TypeError；而 paho 在 _do_on_publish 裡 re-raise 後
    # 就不會執行 _out_messages.pop(mid)，QoS1 的 inflight 永遠不遞減，
    # 導致之後的 publish 全部卡在佇列裡送不出去。
    # 這裡用 *args 兼容兩種版本，且只印 debug 層級資訊（避免每筆都刷 log）。
    if _mqtt_verbose:
        print(f"Published MID {mid}")


mqtt_client.on_connect = __mqtt_connect_handler
mqtt_client.on_disconnect = __mqtt_disconnect_handler
mqtt_client.on_subscribe = __mqtt_subscribe_handler
mqtt_client.on_publish = __mqtt_publish_handler


def publish_message(message: str):
    mqtt_client.publish(
        mqtt_env["topic"] + "/receivers/" + str(RECEIVER_NO), message, qos=1
    )


def publish_status(message: str):
    """Publish a status message (e.g. IP info) to the status topic."""
    mqtt_client.publish(
        mqtt_env["topic"] + "/status/" + str(RECEIVER_NO), message, qos=1
    )


def get_time():
    """回傳目前本地時間字串 (dd/mm/yyyy HH:MM:SS)。"""
    return time.strftime("%d/%m/%Y %H:%M:%S", time.localtime())


def get_local_ip():
    """Get the local IP address of this machine."""
    try:
        s = _socket.socket(_socket.AF_INET, _socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception as e:
        print("Failed to get local IP:", e)
        return "0.0.0.0"


# ─── 參與 Session：訂閱 XOR Key ─────────────────
# Server 開始點名時會發布最新 Session XOR Key 到
# {topic}/session_key（retained），本機訂閱並即時更新解密金鑰。
SESSION_KEY_TOPIC = mqtt_env["topic"] + "/session_key"

# ─── 主迴圈內的 BLE 掃描 ─────────────────────────


def handle_session_key(payload: str):
    """解析 server 發布的 session XOR key 並更新全域 CURRENT_XOR_KEY。

    ⚠️ 本函式名稱**不可**加前導雙底線：Python 會把函式內的 `global CURRENT_XOR_KEY`
    加上 `_<函式名去頭底線>` 前綴（name mangling），變成 `global _handle_session_keyCURRENT_XOR_KEY`
    —— 建出一個全新的全域變數，真正的 CURRENT_XOR_KEY 永遠不會被更新，
    於是每一輪掃描都認為「沒有金鑰」而默默丟棄封包（本程式舊版的 bug：
    log 只看到 TARGET UUID MATCH，卻沒有任何解密錯誤，也一直 publish 不出去）。

    除了金鑰，也會一併記下 session_id（CURRENT_SESSION_ID）：
    §1.2 的 payload 必須帶它，定位程式才有辦法把封包歸到正確的場次。
    """
    global CURRENT_XOR_KEY, _missing_key_warned, _last_logged_key
    global _session_key_received, CURRENT_SESSION_ID
    try:
        data = json.loads(payload)
    except (ValueError, TypeError):
        print(f"    ⚠️ session_key payload 不是合法 JSON: {payload!r}")
        return

    # 相容兩種欄位命名：1.1 文件用 "XOR_key"，2.2 API 用 "xor_key"
    new_key = data.get("XOR_key") or data.get("xor_key")
    if not new_key or not isinstance(new_key, str):
        print(f"    ⚠️ session_key payload 缺少 XOR key 欄位: {data}")
        return

    # session_id 同樣兩種命名都接受（正常是 session_id）
    new_session_id = data.get("session_id") or data.get("sessionId")
    if isinstance(new_session_id, str) and new_session_id:
        if new_session_id != CURRENT_SESSION_ID:
            CURRENT_SESSION_ID = new_session_id
            print(f"  🆔 已更新 Session ID 為 {CURRENT_SESSION_ID!r}"
                  "（之後的 §1.2 封包都會帶上它）")
    else:
        # 沒有 session_id 就代表下游一定會拒收，這裡要講清楚（只提示一次）
        if CURRENT_SESSION_ID is None:
            print("    ⚠️ session_key payload 沒有 session_id 欄位 ——"
                  " 定位程式會把本機送出的封包全部丟棄（§1.2 第 2 關）")

    # 若之前提示過「等不到金鑰」，現在拿到了就解除，之後金鑰若被清掉會再提示一次
    _missing_key_warned = False
    _session_key_received = True

    if new_key != CURRENT_XOR_KEY:
        CURRENT_XOR_KEY = new_key
        _last_logged_key = None      # 讓下一輪掃描重新印出新金鑰
        print(f"  🔑 已更新 Session XOR Key 為 {CURRENT_XOR_KEY!r}"
              f"（session_id={CURRENT_SESSION_ID!r}）")
    # retained 訊息每次重連都會重送，值沒變就不印，避免洗版


def __mqtt_message_handler(client, userdata, message):
    # ⚠️ paho-mqtt 的 on_message 簽章是 (client, userdata, message)：
    #    第 2 個參數是 userdata（本程式沒設定 → None），**不是 topic**！
    #    舊版寫成 (client, topic, message) 之後把 userdata 當 topic 用，
    #    於是 topic_str 永遠是字串 "None"，永遠不等於 SESSION_KEY_TOPIC，
    #    handle_session_key() 從來沒被呼叫 → CURRENT_XOR_KEY 一直是 None
    #    → 每輪掃描都因「沒有金鑰」而丟棄封包、完全不 publish
    #    （log 只有 TARGET UUID MATCH，看不到任何解密或錯誤訊息）。
    # topic 必須從 message.topic 取得（paho 2.x 的 MQTTMessage 物件）。
    try:
        if isinstance(message, (bytes, bytearray)):
            # 相容舊行為：若拿到的直接是 payload bytes，就沒有 topic 可用
            payload_str = bytes(message).decode("utf-8", errors="replace")
            topic_str = ""
        elif isinstance(message, str):
            payload_str = message
            topic_str = ""
        elif hasattr(message, "payload"):
            topic_str = getattr(message, "topic", "") or ""
            if isinstance(topic_str, (bytes, bytearray)):
                topic_str = bytes(topic_str).decode("utf-8", errors="replace")
            else:
                topic_str = str(topic_str)
            raw = message.payload
            payload_str = raw.decode("utf-8", errors="replace") if isinstance(raw, (bytes, bytearray)) else str(raw)
        else:
            raise TypeError(f"unexpected message type: {type(message).__name__}")
    except Exception as e:
        print(f"    ⚠️ 解析 MQTT 訊息失敗: {e}")
        return

    if topic_str != SESSION_KEY_TOPIC:
        # 其他（未訂閱）訊息，略過
        return

    if _mqtt_verbose:
        print(f"    📥 收到 {topic_str}: {payload_str[:120]}")
    handle_session_key(payload_str)


mqtt_client.on_message = __mqtt_message_handler


def _mqtt_keepalive_thread():
    """背景看門狗：定期回報連線狀態（真正的重連交給 paho 的 loop_start）。

    ⚠️ 這裡**不要**自己呼叫 `mqtt_client.loop()` 或 `mqtt_client.reconnect()`：
      - `loop_start()` 已在背景執行緒跑 `loop_forever()`，socket 由它獨佔。
        從別的執行緒再呼叫 `loop()` 會讓兩個執行緒同時讀同一個 socket，
        造成 `Unrecognized packet` 與莫名其妙的 on_disconnect。
      - 自己在另一個執行緒 `reconnect()` 會與 loop_forever 的內部流程互撞，
        狀態卡在 MQTT_CS_CONNECTING（is_connected() 永遠 False），
        而且 loop_forever 迴圈中斷後就再也不會重連。
    重連請用 paho 官方支援：
        Client(...).reconnect_on_failure = True   # loop_forever 自動重連
        mqtt_client.connect_async(...)            # 初次連線失敗也會重試
        mqtt_client.reconnect_delay_set(1, 30)    # 指數退避
    重連成功後 paho 會呼叫 on_connect → __mqtt_connect_handler 會重新訂閱
    session_key（retained 會自動補送最新金鑰）。

    本執行緒因此只負責「看」：連線掉很久時印一次提示，避免使用者誤以為資料
    不見了卻沒有任何 log。
    """
    print(f"    📡 Session XOR Key Topic: {SESSION_KEY_TOPIC}")
    last_state = None
    while True:
        time.sleep(5)
        connected = mqtt_client.is_connected()
        if connected != last_state:
            last_state = connected
            if connected:
                print("    ✅ MQTT 連線正常")
            else:
                print("    ⚠️ MQTT 目前未連線（等待 paho 自動重連…）")


# 先連接 MQTT，之後的 publish_status 才能成功
print(
    f"Trying to connect to MQTT broker - {_mqtt_proto_name()}://{MQTT_BROKER}:{MQTT_PORT}"
    + (MQTT_WS_PATH if MQTT_TRANSPORT == "websockets" else "")
)
# 斷線自動重連交給 paho：loop_forever() 看到 reconnect_on_failure=True 會自己 reconnect，
# 並在成功後重新呼叫 on_connect（在那裡重新訂閱 session_key）。
mqtt_client.reconnect_on_failure = True
mqtt_client.reconnect_delay_set(min_delay=1, max_delay=30)

# 用 connect_async() + loop_start()：連不上也不會拋例外卡住程式，
# 而是由 paho 的背景執行緒持續重試（樹莓派開機時網路可能還沒好）。
mqtt_client.connect_async(MQTT_BROKER, MQTT_PORT, keepalive=60)

# ⚠️ 順序很重要：session_key 的 SUBSCRIBE 統一在 on_connect 內送出
#    （_subscribe_session_key）。這裡不要再手動 subscribe()，否則會在 SUBACK 前
#    重複訂閱同一 topic，導致 retained 訊息永遠不送來。
mqtt_client.loop_start()

# 啟動背景看門狗執行緒（daemon，隨主程式結束而停止）：只回報連線狀態
_thread = threading.Thread(target=_mqtt_keepalive_thread,
                           name="mqtt-keepalive", daemon=True)
_thread.start()

# 等第一次連線建立（最多 15 秒），讓 startup 的 status 訊息能送出去。
# 真的連不上也不離開：之後 paho 會自動重連，status 在連上後才發布。
_wait_deadline = time.time() + 15
while not mqtt_client.is_connected() and time.time() < _wait_deadline:
    time.sleep(0.2)
if not mqtt_client.is_connected():
    print("    ⚠️ 15 秒內尚未連上 broker（paho 會在背景持續重連）")

# --- Startup: report local IP ---
local_ip = get_local_ip()
print(f"Receiver #{RECEIVER_NO} local IP: {local_ip}")
if USE_TEST_MODE:
    print(f"🔧 測試模式：固定使用 {TEST_XOR_KEY!r} 解密（不會向後端取 session key）")
else:
    print(f"🚀 正式模式：等待 MQTT {SESSION_KEY_TOPIC} 下發 Session XOR Key")
status_msg = json.dumps({
    "receiver_no": RECEIVER_NO,
    "ip": local_ip,
    "status": "online",
})
publish_status(status_msg)


# ─── XOR 解密 ──────────────────────────────────


def _warn_missing_key_once():
    """正式模式下還沒收到 session_key 時，只在第一次提示，避免洗版。"""
    global _missing_key_warned
    if _missing_key_warned:
        return
    _missing_key_warned = True
    print(f"    ⏳ 尚未收到 Session XOR Key（訂閱 {SESSION_KEY_TOPIC}），"
          f"暫時無法解密；請確認後端已開始點名並發布金鑰。")


def _warn_no_session_once():
    """還沒收到 session_id 時，只在第一次提示，避免每 3 秒洗版。"""
    global _missing_session_warned
    if _missing_session_warned:
        return
    _missing_session_warned = True
    print("    ⚠️ 尚未收到 Session ID（session_key 沒帶 session_id）——"
          " 本機送出的 §1.2 封包會被定位程式丟棄；請確認後端 §1.1 payload "
          "含 session_id。")


def _log_key(xor_key):
    """金鑰有變動時才印一次，避免每 3 秒掃描都洗版。"""
    global _last_logged_key
    if xor_key == _last_logged_key:
        return
    _last_logged_key = xor_key
    print(f"    🔑 目前使用 XOR Key: {xor_key!r}"
          + ("（測試模式）" if USE_TEST_MODE else ""))


def xor_decrypt(encrypted_bytes: bytes, key: str) -> bytes:
    """
    XOR 解密：encrypted[i] = rawBytes[i] XOR keyBytes[i % keyBytes.length]
    參考 ble-packet-encryption.md 3.2
    """
    key_bytes = key.encode("utf-8")
    result = bytearray(len(encrypted_bytes))
    for i, b in enumerate(encrypted_bytes):
        result[i] = b ^ key_bytes[i % len(key_bytes)]
    return bytes(result)


def extract_student_id(service_data: bytes, mac_str: str, xor_key=None):
    """只取學號（保留給舊呼叫端／量測工具）；實際解析見 decode_beacon_payload()。"""
    student_id, _otp = decode_beacon_payload(service_data, mac_str, xor_key)
    return student_id


def decode_beacon_payload(service_data: bytes, mac_str: str, xor_key=None):
    """從 bleak 取得的 Service Data payload 中 XOR 解密 → 取出學號與 OTP。

    解密後的明文格式是 `<學號>|<OTP>`（見 ble-packet-encryption.md 3.2），
    例如 "12363033|A1B2C3"。學號與 OTP 兩段都要，因為 §1.2 規格要求
    payload 同時帶 student_id 與 OTP —— 只送學號會被定位程式在第 4 關丟棄。

    注意：bleak 的 service_data dict value 已經「去掉 UUID 前綴」，
    所以 service_data 傳入的就是純加密 payload。

    xor_key 必須明確給（正式模式下未收到 session_key 時會是 None，
    此時直接略過，不使用測試金鑰硬解）。

    回傳 (student_id, otp)：OTP 可能是 None（明文沒有第二段時）。
    解析失敗回 (None, None)。
    """
    if not service_data or len(service_data) < 15:
        print(f"    ⚠️ {mac_str} service_data 不足 (len={len(service_data)}): "
              f"{service_data.hex() if service_data else '(空)'}")
        return None, None

    if not xor_key:
        # 正式模式尚未收到 session_key：這是正常狀態，不是錯誤，所以只提示一次
        _warn_missing_key_once()
        return None, None

    try:
        encrypted = service_data[:15]
        decrypted = xor_decrypt(encrypted, xor_key)
        plaintext = decrypted.decode("utf-8", errors="replace")

        if "|" not in plaintext:
            print(f"    ⚠️ {mac_str} XOR 解密結果沒有分隔符 '|'")
            print(f"          解密後 bytes={decrypted.hex()}")
            print(f"          解密後文字={plaintext!r}")
            print(f"          (XOR Key={xor_key!r}, 原始 service_data={service_data.hex()})")
            return None, None

        student_id, otp = plaintext.split("|", 1)
        student_id = student_id.strip()
        otp = otp.strip()
        if not student_id.isdigit() or len(student_id) != 8:
            print(f"    ⚠️ 學號格式異常: {student_id}")
            return None, None

        return student_id, (otp or None)
    except Exception as e:
        print(f"    ⚠️ 解密失敗 {mac_str}: {e}")
        return None, None


def _is_target_uuid(uuid_str):
    """判斷某個 UUID 字串是否屬於我們的 SERVICE_UUID (1111)。"""
    upper = str(uuid_str).upper()
    return SERVICE_UUID_SHORT in upper or SERVICE_UUID.upper() in upper


def _find_service_data(adv):
    """
    在 bleak 的 AdvertisementData.service_data dict 中，找出 UUID=1111
    對應的加密 payload。回傳 bytes 或 None。
    """
    sd = adv.service_data or {}
    for key, val in sd.items():
        if _is_target_uuid(key):
            return bytes(val)
    return None


# ─── BlueZ / bleak 錯誤分類 ───────────────────────
# 每一種錯誤的「該怎麼處理」完全不同，一律 sleep(2) 只會放大洗版：
#
#   InProgress              adapter 上還有一輪 discovery 沒結束
#                           → 先想辦法收乾淨，再退避重試
#   NotReady / NotPermitted adapter 沒開 / 權限不足（bluetooth 群組）
#                           → 退避長一點，等環境恢復
#   Failed + abort-by-local  某支手機連不上，bluetoothd 中斷整輪 discovery
#                           → 不是錯，退避短一點立刻再掃
#   DBusError / EOFError     bluetoothd 掛了或 D-Bus 斷線
#                           → 退避最長（連線會在下一輪重建成）
BLEAK_ERROR_IN_PROGRESS = "org.bluez.Error.InProgress"
BLEAK_ERROR_NOT_READY = "org.bluez.Error.NotReady"
BLEAK_ERROR_NOT_PERMITTED = "org.bluez.Error.NotPermitted"
BLEAK_ERROR_FAILED = "org.bluez.Error.Failed"


def _bleak_error_id(exc):
    """取出 BleakDBusError 的 dbus_error；非 D-Bus 錯誤回傳類別名。"""
    name = getattr(exc, "dbus_error", None)
    if name:
        return str(name)
    return type(exc).__name__


def describe_bleak_error(exc):
    """把 bleak 例外整理成一行可讀字串（給 log 用）。

    例：`[org.bluez.Error.InProgress] Operation already in progress`

    注意：`BleakDBusError.__str__()` 本身已經長成
    `"org.bluez.Error.InProgress: Operation already in progress"`（或
    `[...] ...`，視 bleak 版本），所以先把它自帶的錯誤名前綴剝掉，
    避免變成 `[InProgress] [InProgress] ...` 這種重複字串。
    """
    err_id = _bleak_error_id(exc)
    msg = str(exc)
    for prefix in (f"{err_id}: ", f"[{err_id}] "):
        if msg.startswith(prefix):
            msg = msg[len(prefix):]
            break
    return f"[{err_id}] {msg}"


def classify_bleak_error(exc):
    """把 bleak 例外分類成 (類別, 建議退避秒數)。

    類別：in_progress / not_ready / not_permitted / busy / dbus / other
    """
    err_id = _bleak_error_id(exc)
    msg = str(exc).lower()

    if err_id == BLEAK_ERROR_IN_PROGRESS or "already in progress" in msg:
        return "in_progress", 1.0
    if err_id == BLEAK_ERROR_NOT_READY:
        return "not_ready", 5.0
    if err_id == BLEAK_ERROR_NOT_PERMITTED:
        return "not_permitted", 10.0
    if "dbus" in err_id.lower() or isinstance(exc, (EOFError, ConnectionError)):
        return "dbus", 10.0
    if err_id == BLEAK_ERROR_FAILED:
        # 最常見的是 bluetoothd 的 ConnectionAttemptFailed：
        # "le-connection-abort-by-local"（某支手機連不上 → 整輪 discovery 被中斷）
        return "busy", 3.0
    return "other", 2.0


async def _stop_stuck_discovery(adapter_notice=None):
    """嘗試把 adapter 上殘留的 discovery session 收乾淨。

    InProgress 的成因是 adapter 還有一輪 discovery，所以「重試」之前
    先 StopDiscovery 比盲目 sleep 有效。bleak 3.0.x 不會自動處理
    （3.1.0 才修，見 bleak #2021），所以這裡自己來。

    做法：用一次極短的 BleakScanner 啟動/停止循環逼 bleak 送出
    StopDiscovery + SetDiscoveryFilter({})。若 BlueZ 回 NotReady
    （代表其實已經停了）就當成功。
    """
    scanner = BleakScanner(scanning_mode="passive",
                           detection_callback=lambda *_: None)
    try:
        await scanner.start()
    except BleakError as e:
        category, _ = classify_bleak_error(e)
        # 停不下來就是還在跑（InProgress）→ 直接進到下面的 stop 嘗試
        if category != "in_progress":
            if adapter_notice:
                adapter_notice(e)
            raise
    try:
        await scanner.stop()
    except BleakError as e:
        # NotReady = 本來就沒在掃，正是我們要的結果
        if _bleak_error_id(e) != BLEAK_ERROR_NOT_READY:
            raise


def recover_from_in_progress():
    """同步版本的收場：把卡住的 discovery 停掉，並回報是否成功。"""
    try:
        asyncio.run(_stop_stuck_discovery())
        return True
    except Exception as e:
        print(f"    ⚠️ 無法清除殘留 discovery：{describe_bleak_error(e)}")
        return False


async def _scan_once(timeout: float = 3.0):
    """
    執行一次 active scan，回傳符合條件裝置的清單。
    每筆：{"mac": str, "rssi": int, "payload": bytes}

    使用 BleakScanner detection_callback（bleak 2.x / 3.x 標準 API），
    scanning_mode="active" 會觸發 scan response。

    ⚠️ 為什麼 start/stop 要用 try/finally：
       BlueZ 的 discovery 是「adapter 上的一輪 session」，不是這個
       process 的區域變數。若 start() 之後任何地方拋錯而沒有 stop()，
       adapter 會停在 Discovering=true，下一輪 StartDiscovery 就會回
       org.bluez.Error.InProgress（"Operation already in progress"）
       —— 這正是 log 一直洗版的原因。無論如何都要把 session 還回去。
    """
    found = []
    seen_macs = set()

    def _detection_callback(device, advertisement_data):
        nonlocal found
        mac = str(getattr(device, "address", "") or "").replace(":", "").upper()
        rssi = getattr(advertisement_data, "rssi", None)
        sd = getattr(advertisement_data, "service_data", None) or {}
        service_uuids = list(getattr(advertisement_data, "service_uuids", []) or [])
        local_name = getattr(advertisement_data, "local_name", None)
        manufacturer_data = getattr(advertisement_data, "manufacturer_data", None)
        tx_power = getattr(advertisement_data, "tx_power", None)

        # Debug：印出所有掃到的裝置（前 5 台）
        if mac not in seen_macs:
            seen_macs.add(mac)
            if len(seen_macs) <= 5:
                print(f"       [SCAN] {mac} RSSI:{rssi} "
                      f"uuids={service_uuids} sd={list(sd.keys()) if sd else None} "
                      f"name={local_name!r}")

        # 判斷是不是目標裝置
        is_target = _is_target_uuid(local_name) if local_name else False
        for u in service_uuids:
            if _is_target_uuid(u):
                is_target = True
                break
        if not is_target and sd:
            for k in sd.keys():
                if _is_target_uuid(k):
                    is_target = True
                    break

        # Debug：印出目標封包
        if is_target:
            print(f"  📡 TARGET UUID MATCH! MAC:{mac} RSSI:{rssi}")
            print(f"       service_data keys: {list(sd.keys()) if sd else 'None'}")
            print(f"       service_data (raw): {sd}")
            print(f"       full: rssi={rssi}, service_uuids={service_uuids}, "
                  f"local_name={local_name}, manufacturer_data={manufacturer_data}, "
                  f"tx_power={tx_power}")

            payload = None
            for key, val in sd.items():
                if _is_target_uuid(key):
                    payload = bytes(val)
                    break
            if payload is not None:
                found.append({"mac": mac, "rssi": rssi, "payload": payload})

    scanner = BleakScanner(
        detection_callback=_detection_callback,
        scanning_mode="active",
    )
    await scanner.start()
    try:
        await asyncio.sleep(timeout)
    finally:
        # 只 stop 自己 start 成功的那一輪；stop 失敗不該蓋掉真正的錯誤
        try:
            await scanner.stop()
        except BleakError as e:
            _ble_logger.warning("scanner.stop() 失敗：%s", describe_bleak_error(e))
    return found


def start_scan():
    """
    使用 bleak active scan 掃描 BLE 廣告封包。
    收集所有 UUID=1111 且帶 Service Data 的裝置 → XOR 解密 → MQTT publish。
    """
    print("Starting BLE scan (bleak / active mode)...")
    devices_found = []

    # 使用目前最新的 Session XOR Key（可被 mqtt session_key 即時更新）
    xor_key = CURRENT_XOR_KEY
    if xor_key:
        # 每輪都印金鑰會洗版；只在金鑰變動時提示一次
        _log_key(xor_key)
    else:
        _warn_missing_key_once()

    try:
        results = asyncio.run(_scan_once(timeout=3.0))

        for dev in results:
            mac_str = dev["mac"]
            rssi = dev["rssi"]
            payload = dev["payload"]
            print(f"       [DBG {mac_str}] service_data payload({len(payload)}B)={payload.hex()}")

            student_id, otp = decode_beacon_payload(payload, mac_str, xor_key)
            if student_id is None:
                continue

            print(f"  ✅ {mac_str} → 學號:{student_id} RSSI:{rssi}")
            devices_found.append({
                "student_id": student_id,
                "otp": otp,
                "mac": mac_str,
                "rssi": rssi,
                "time": get_time(),
            })

    except BleakError as e:
        # 印出真正的 dbus_error（過去只印 str(e)，永遠是
        # "Operation already in progress"，看不出是哪一種 BlueZ 錯誤）
        print(f"BLE bleak error during scan: {describe_bleak_error(e)}")
        raise
    except Exception as e:
        _ble_logger.exception("Unexpected scan error: %s", e)
        raise

    # 批次發布 MQTT
    if devices_found:
        print(f"  發布 {len(devices_found)} 筆資料到 MQTT...")
        for device in devices_found:
            # §1.2 規格欄位：session_id / student_id / OTP / mac / rssi /
            # scanner_id / time。少了 session_id 或 OTP，定位程式會直接丟棄
            # （2026-10-26 部署機的 504 timeout 就是這樣來的）。
            message = json.dumps({
                "session_id": CURRENT_SESSION_ID,
                "student_id": device["student_id"],
                "OTP": device["otp"],
                "mac": device["mac"],
                "rssi": device["rssi"],
                "scanner_id": RECEIVER_NO,
                "time": device["time"],
            })
            publish_message(message)
            print(f"    📤 {device['student_id']} RSSI:{device['rssi']}")
        if CURRENT_SESSION_ID is None:
            # 沒有場次時仍會送（phase 1 封包），但下游一定丟；講一次免得查半天
            _warn_no_session_once()
    else:
        print("  本次掃描未發現有效裝置。")

    print("Scan done.")


def main():
    """
    主迴圈：每輪掃 3 秒，遇到 BlueZ 錯誤就分類退避後重試。

    為什麼要自己退避而不是固定 sleep(2)：
      - InProgress 代表 adapter 上還有一輪 discovery 沒結束 —— 先把它
        收乾淨，下一次幾乎一定成功，所以退避 1 秒就夠（盲目 sleep(2)
        會讓卡住的 session 更有時間「保持」在 Discovering=true）。
      - le-connection-abort-by-local 是環境造成（某支手機連不上），
        立刻再掃即可。
      - NotReady / NotPermitted / D-Bus 斷線要等環境恢復，退避長一點，
        而且要有上限，否則 log 會每 2 秒洗一次。
    """
    backoff = 0.0
    max_backoff = 30.0

    while True:
        try:
            start_scan()
            backoff = 0.0          # 成功一次就歸零
        except BleakError as e:
            category, delay = classify_bleak_error(e)
            print(f"BLE bleak error [{category}], retrying in {delay:.0f}s: "
                  f"{describe_bleak_error(e)}")

            if category == "in_progress":
                # 真正能讓 InProgress 消失的動作：把殘留的 discovery 停掉
                recover_from_in_progress()

            time.sleep(delay)
            continue
        except OSError as e:
            backoff = min(max(backoff * 2, 2.0), max_backoff)
            print(f"Failed to scan: {e} (retrying in {backoff:.0f}s)")
            time.sleep(backoff)
            continue
        except Exception as e:
            # 非 BLE 的意外錯誤（例如 JSON/MQTT）：印完整 traceback，
            # 但不讓整個服務死掉 —— systemd Restart=on-failure 會讓
            # 掃描節點反覆重啟，比留在迴圈裡更糟。
            _ble_logger.exception("Unexpected error: %s", e)
            backoff = min(max(backoff * 2, 2.0), max_backoff)
            time.sleep(backoff)
            continue

        backoff = 0.0
        time.sleep(2)


def _check_mqtt_handler_signatures():
    """防護：on_message 的簽章必須是 paho 的 (client, userdata, message)。

    paho 是用位置傳參呼叫 callback 的，若簽章命名/順序寫錯（例如
    `(client, topic, message)`），不會拋錯、也不會印警告，只會默默地
    拿 userdata(None) 當 topic 用 —— 這正是本程式收不到 session_key 的
    根本原因，而且 log 完全看不出來。啟動時檢查一次，之後改名也不會再踩。
    """
    import inspect

    params = list(inspect.signature(__mqtt_message_handler).parameters)
    if params != ["client", "userdata", "message"]:
        raise RuntimeError(
            f"__mqtt_message_handler 的參數必須是 (client, userdata, message)，"
            f"目前是 {params}；paho 會把 userdata 當第 2 個參數傳進來，"
            "topic 請一律從 message.topic 取得。"
        )
    if "message" not in __mqtt_message_handler.__code__.co_varnames:
        raise RuntimeError("__mqtt_message_handler 沒有使用 message 參數。")


if __name__ == "__main__":
    _check_mqtt_handler_signatures()
    main()

