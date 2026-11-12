#!/usr/bin/env bash
# ============================================================
# setup-system.sh — 部署端的「系統層」設定（冪等，可重複執行）
#
# 由 deploy.sh 以 `sudo bash -s -- <args>` 透過 SSH 標準輸入送出，
# 也可以在樹莓派上直接執行：
#
#   sudo ./setup-system.sh --dir /home/pi/beacons --user pi --group pi
#
# 做的事：
#   1. 安裝 BlueZ / D-Bus / venv 等系統套件（只在缺的時候裝）
#   2. 開啟並啟用 bluetooth.service、unblock 射頻
#   3. 設定 BLE 掃描所需的權限（bluetooth 群組；NetworkManager 不亂斷 BLE）
#   4. 安裝 /etc/systemd/system/ble-beacon-scanner.service 並 enable
#      （含 ExecStopPost=bluetoothctl scan off：服務停止時收乾淨 discovery）
#   5. daemon-reload（不啟動；啟動 / 重啟由 deploy.sh 決定時機）
#   6. 調整 /etc/bluetooth/main.conf（[Policy] ReconnectAttempts=0）
#      —— 純掃描節點不需要自動重連，避免重連風暴打斷 LE discovery
#   7. 安裝 /usr/local/bin/ble-unstuck.sh + ble-unstuck.timer
#      —— 每 5 分鐘檢查 adapter 是否卡在 Discovering=true；
#         卡住才動作（stop → power cycle），用來解 org.bluez.Error.InProgress
#   8. 安裝 /usr/local/bin/diagnose_paho.sh
#      —— 「No module named 'paho'」這類「裝到錯的 Python」問題的診斷工具
#
# 為什麼需要 4/6/7（見 code.py 的 BLE bleak error）：
#   org.bluez.Error.InProgress（"Operation already in progress"）是 BlueZ
#   的 discovery session 沒被收乾淨，不是 Python 端的 bug；這三步分別在
#   「服務結束」「重連行為」「長時間卡住」三個層面把它收掉。
#
# 測試用：SETUP_SYSTEM_ALLOW_NONROOT=1 可跳過 root 檢查（只給自動化測試用）
#
# 刻意「不改」的東西：my_secrets.py、venv 內容 —— 那些由 deploy.sh 負責。
# ============================================================
set -euo pipefail

SERVICE_NAME="ble-beacon-scanner"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

APP_DIR="/home/pi/beacons"
SERVICE_USER="pi"
SERVICE_GROUP=""
INSTALL_UNIT=1

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)    APP_DIR="$2"; shift 2 ;;
        --user)   SERVICE_USER="$2"; shift 2 ;;
        --group)  SERVICE_GROUP="$2"; shift 2 ;;
        --no-unit) INSTALL_UNIT=0; shift ;;
        -h|--help)
            sed -n '4,17p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "未知參數: $1" >&2; exit 2 ;;
    esac
done

if [ "$EUID" -ne 0 ] && [ "${SETUP_SYSTEM_ALLOW_NONROOT:-0}" != "1" ]; then
    echo "ERROR: setup-system.sh 需要 root（請用 sudo 執行）" >&2
    exit 1
fi

SERVICE_GROUP="${SERVICE_GROUP:-$(id -gn "${SERVICE_USER}" 2>/dev/null || echo "${SERVICE_USER}")}"
VENV_PYTHON="${APP_DIR}/venv/bin/python3"

step() { echo ""; echo "── $* ──"; }

# ─── 1. 系統套件 ─────────────────────────────
step "檢查系統套件 (python3-venv / bluez / bluetooth / libglib2.0-dev)"
missing=()
if ! python3 -m venv --help &>/dev/null; then
    missing+=(python3-venv python3-pip)
fi
for pkg in bluez bluetooth libglib2.0-dev; do
    if ! dpkg -s "${pkg}" &>/dev/null; then
        missing+=("${pkg}")
    fi
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "   安裝: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "${missing[@]}"
else
    echo "   已齊全，略過。"
fi

# ─── 2. 藍牙服務 ─────────────────────────────
step "啟動 bluetooth.service"
systemctl enable --now bluetooth.service
# 若射頻被 soft-block（Raspi OS Lite / 省電設定常見），解除封鎖
if command -v rfkill &>/dev/null; then
    rfkill unblock bluetooth || true
fi

# ─── 3. 權限 ─────────────────────────────────
step "設定 ${SERVICE_USER} 的 BLE 權限"
if id "${SERVICE_USER}" &>/dev/null; then
    if ! id -nG "${SERVICE_USER}" | tr ' ' '\n' | grep -qx bluetooth; then
        usermod -aG bluetooth "${SERVICE_USER}"
        echo "   已將 ${SERVICE_USER} 加入 bluetooth 群組（下次登入生效；服務會 restart 所以不影響）"
    else
        echo "   ${SERVICE_USER} 已在 bluetooth 群組。"
    fi
else
    echo "   ⚠️ 使用者 ${SERVICE_USER} 不存在，略過群組設定。"
fi

# NetworkManager 會在 BLE 掃描/連線時介入，對純掃描節點關掉可避免掃描被斷
NM_CONF="/etc/NetworkManager/conf.d/99-ble-no-autoconnect.conf"
if [ "${SETUP_SYSTEM_ALLOW_NONROOT:-0}" = "1" ]; then
    NM_CONF="${HOME}/stub-etc/NetworkManager/conf.d/99-ble-no-autoconnect.conf"
fi
if [ -d /etc/NetworkManager/conf.d ]; then
    if [ ! -f "${NM_CONF}" ]; then
        mkdir -p "$(dirname "${NM_CONF}")"
        printf '[device-ble]\nmatch-device=type:bluetooth\nmanaged=false\n' > "${NM_CONF}"
        systemctl reload NetworkManager 2>/dev/null || true
        echo "   已寫入 ${NM_CONF}（BLE 交由 BlueZ 直接管理）"
    else
        echo "   ${NM_CONF} 已存在，略過。"
    fi
fi

# ─── 4. systemd unit ─────────────────────────
if [ "${INSTALL_UNIT}" = "1" ]; then
    step "安裝 systemd unit"
    if [ "${SETUP_SYSTEM_ALLOW_NONROOT:-0}" = "1" ]; then
        SERVICE_FILE="${HOME}/stub-etc/systemd/system/${SERVICE_NAME}.service"
    fi
    mkdir -p "$(dirname "${SERVICE_FILE}")"
    if [ ! -x "${VENV_PYTHON}" ]; then
        echo "   ⚠️ ${VENV_PYTHON} 不存在（venv 尚未建立）；unit 仍會寫入，等 venv 就緒後再 restart。"
    fi
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=BLE Beacon Scanner – scans BLE advertisements and publishes via MQTT
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${APP_DIR}
ExecStart=${VENV_PYTHON} -u ${APP_DIR}/code.py
# 服務結束（重啟、crash、stop）時把 adapter 上殘留的 discovery 收乾淨。
# 不做這件事，下一輪 StartDiscovery 會撞 org.bluez.Error.InProgress
# （"Operation already in progress"），也就是 log 一直洗版的來源。
ExecStopPost=-/usr/bin/bluetoothctl --timeout 3 scan off
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    echo "   已寫入 ${SERVICE_FILE} (User=${SERVICE_USER})"
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
    echo "   已 enable ${SERVICE_NAME}"
fi

# ─── 5. BlueZ main.conf 調校（降低 discovery 被中斷的機率）─────
# 純掃描節點不需要「主機模式」的重連與快速連線功能，這兩個預設值
# 在人多（很多手機同時廣播）的場合會讓 bluetoothd 中斷 LE discovery：
#   - le-connection-abort-by-local：某支手機連不上 → 整輪 discovery 結束
#   - 斷線自動重連（ReconnectAttempts>0）會在掃描期間反覆嘗試連線
step "調整 BlueZ main.conf（純掃描節點）"
BT_MAIN_CONF="/etc/bluetooth/main.conf"
if [ "${SETUP_SYSTEM_ALLOW_NONROOT:-0}" = "1" ]; then
    BT_MAIN_CONF="${HOME}/stub-etc/bluetooth/main.conf"
fi
if [ ! -f "${BT_MAIN_CONF}" ]; then
    echo "   ⚠️ 找不到 ${BT_MAIN_CONF}，略過（bluez 未安裝？）"
elif grep -q "managed by setup-system.sh" "${BT_MAIN_CONF}"; then
    echo "   ${BT_MAIN_CONF} 已設定過，略過。"
else
    cp "${BT_MAIN_CONF}" "${BT_MAIN_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    if grep -qx '\[Policy\]' "${BT_MAIN_CONF}"; then
        # 已經有 [Policy] 段：直接在該段第一行後面插入，避免重複 [Policy]
        # （重複 section 會讓 configparser 之類的解析器直接報錯）
        sed -i '/^\[Policy\]$/a # 由 beacons/setup-system.sh 設定：純掃描節點關閉自動重連\nReconnectAttempts = 0' \
            "${BT_MAIN_CONF}"
        echo "   已在既有 [Policy] 段加入 ReconnectAttempts = 0（原檔備份為 *.bak.*）"
    else
        cat >> "${BT_MAIN_CONF}" <<'EOF'

# 以下由 beacons/setup-system.sh 管理（managed by setup-system.sh）
# 只做被動掃描，關掉自動重連，避免重連風暴打斷 LE discovery。
[Policy]
ReconnectAttempts = 0
EOF
        echo "   已追加 [Policy] ReconnectAttempts = 0（原檔備份為 *.bak.*）"
    fi
fi

# ─── 6. 定期清場：卡住的 discovery session ─────────────────────
# 即使程式每輪都 stop，BlueZ 仍可能因外部因素（NetworkManager、
# 某支手機連不上）停在 Discovering=true。timer 每 5 分鐘檢查一次，
# 只有在真的卡住時才 power cycle adapter，正常運作時完全不動作。
step "安裝 ble-unstuck timer（殘留 discovery 自動清場）"
UNSTUCK_SCRIPT="/usr/local/bin/ble-unstuck.sh"
UNSTUCK_SERVICE="/etc/systemd/system/ble-unstuck.service"
UNSTUCK_TIMER="/etc/systemd/system/ble-unstuck.timer"
if [ "${SETUP_SYSTEM_ALLOW_NONROOT:-0}" = "1" ]; then
    UNSTUCK_SCRIPT="${HOME}/stub-usr/local/bin/ble-unstuck.sh"
    UNSTUCK_SERVICE="${HOME}/stub-etc/systemd/system/ble-unstuck.service"
    UNSTUCK_TIMER="${HOME}/stub-etc/systemd/system/ble-unstuck.timer"
fi

mkdir -p "$(dirname "${UNSTUCK_SCRIPT}")"
cat > "${UNSTUCK_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
# 由 beacons/setup-system.sh 安裝；由 ble-unstuck.timer 每 5 分鐘呼叫。
#
# 目的：BlueZ 的 discovery 是 adapter 上的一輪 session，若某個 client
# 沒有正常 StopDiscovery，adapter 會停在 Discovering=true，之後所有
# StartDiscovery 都回 org.bluez.Error.InProgress（"Operation already in
# progress"）—— 也就是 ble-beacon-scanner 一直印 BLE bleak error 的原因。
#
# 這裡只在「真的卡住」時動作，正常掃描中斷的 3 秒窗口不會被誤判。
set -u

DISCOVERING="$(busctl --system get-property org.bluez /org/bluez/hci0 \
                 org.bluez.Adapter1 Discovering 2>/dev/null | awk '{print $2}')"

case "${DISCOVERING}" in
    true)
        # adapter 卡在 scanning：先試單純 stop，失敗才 power cycle
        bluetoothctl --timeout 3 scan off >/dev/null 2>&1
        sleep 1
        STILL="$(busctl --system get-property org.bluez /org/bluez/hci0 \
                   org.bluez.Adapter1 Discovering 2>/dev/null | awk '{print $2}')"
        if [ "${STILL}" = "true" ]; then
            echo "ble-unstuck: discovery 卡住，power cycle hci0"
            bluetoothctl --timeout 3 power off >/dev/null 2>&1
            sleep 2
            bluetoothctl --timeout 3 power on  >/dev/null 2>&1
        else
            echo "ble-unstuck: StopDiscovery 後恢復"
        fi
        ;;
    false|"")
        # false = 正常；空字串 = 沒有 adapter / busctl 失敗，什麼都不做
        ;;
    *)
        ;;
esac
EOF
chmod 755 "${UNSTUCK_SCRIPT}"

cat > "${UNSTUCK_SERVICE}" <<'EOF'
[Unit]
Description=Reset stuck BlueZ discovery session (beacons scanner)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ble-unstuck.sh
EOF

cat > "${UNSTUCK_TIMER}" <<'EOF'
[Unit]
Description=Periodically reset stuck BlueZ discovery session (beacons scanner)

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now ble-unstuck.timer >/dev/null 2>&1 || \
        echo "   ⚠️ 無法 enable ble-unstuck.timer（稍後手動 systemctl enable --now ble-unstuck.timer）"
fi
echo "   已安裝 ${UNSTUCK_SCRIPT} + ble-unstuck.timer（每 5 分鐘檢查一次）"

# ─── 7. 診斷工具 ───────────────────────────────────────────────
# 「No module named 'paho'」幾乎都是「套件裝到系統 Python，但服務用 venv」
# 造成的。把診斷腳本放到 PATH 裡，出問題時直接跑 diagnose_paho.sh 即可。
step "安裝 diagnose_paho.sh（依賴安裝問題診斷）"
DIAG_SRC="${APP_DIR}/diagnose_paho.sh"
DIAG_DST="/usr/local/bin/diagnose_paho.sh"
if [ "${SETUP_SYSTEM_ALLOW_NONROOT:-0}" = "1" ]; then
    DIAG_DST="${HOME}/stub-usr/local/bin/diagnose_paho.sh"
fi
if [ -f "${DIAG_SRC}" ]; then
    mkdir -p "$(dirname "${DIAG_DST}")"
    install -m 755 "${DIAG_SRC}" "${DIAG_DST}" 2>/dev/null \
        && echo "   已安裝 ${DIAG_DST}" \
        || echo "   ⚠️ 無法安裝 ${DIAG_DST}（可直接執行 ${DIAG_SRC}）"
else
    echo "   ⚠️ 找不到 ${DIAG_SRC}，略過。"
fi

step "系統層設定完成"
