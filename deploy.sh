#!/usr/bin/env bash
# ============================================================
# deploy.sh — 一次把 beacons 部署到多台樹莓派
#
# 在你自己的電腦（Mac / Linux）上執行，靠 rsync + ssh 推到每台機器：
#
#   ./deploy.sh                      # 依 hosts.txt 部署所有機器
#   ./deploy.sh raspi-2.local        # 只部署其中一台（可用子字串比對）
#   ./deploy.sh --dry-run            # 只顯示會做什麼，不改遠端
#   ./deploy.sh --help
#   ./deploy.sh --print-sudo-setup           # 印出「建立免密碼 sudo」的指令（不改任何東西）
#
# 需要：ssh（金鑰登入）、rsync、python3（只用標準函式庫）
#
# 每台的流程（全部冪等，可重複跑）：
#   1. rsync 程式碼    → ~/beacons（排除 .venv / venv / __pycache__ / my_secrets.py）
#   2. 產生 my_secrets.py（本機渲染模板 → 透過 ssh 標準輸入寫入，密碼不落地）
#   3. 建立 / 更新 venv 並安裝 requirements.txt
#      （requirements.txt 只含常駐服務需要的 bleak + paho-mqtt；
#        量測工具 get_exponent.py 的 adafruit-* 相依另放在 requirements-measure.txt，
#        因為 adafruit-blinka 在 Linux 會拉進 lgpio / rpi_ws281x，需現場編譯 + swig）
#   4. 系統層設定：BlueZ、bluetooth 群組、systemd unit（sudo setup-system.sh）
#   5. restart 服務並檢查是否 healthy
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOSTS_FILE="${SCRIPT_DIR}/hosts.txt"
TEMPLATE="${SCRIPT_DIR}/my_secrets.py.tmpl"
LOG_DIR="${SCRIPT_DIR}/.deploy-logs"

# ─── 預設部署參數（可用環境變數 / .env.deploy 覆寫）──────
: "${MQTT_BROKER:=broker.stevehsiao.com}"
: "${MQTT_PORT:=443}"
: "${MQTT_TRANSPORT:=websockets}"      # tcp | websockets
: "${MQTT_USE_TLS:=True}"              # websockets ⇒ wss
: "${MQTT_WS_PATH:=/}"
: "${MQTT_CA_CERTS:=None}"             # None = 系統預設 CA；或 pem 路徑
: "${MQTT_USERNAME:=pi}"
: "${MQTT_PASSWORD:=}"                 # 建議用環境變數或 .env.deploy 傳
: "${MQTT_TOPIC:=mcu/indoor-location}"
: "${USE_TEST_MODE:=True}"
: "${REMOTE_DIR:=~/beacons}"           # 遠端安裝目錄
: "${SSH_PORT:=22}"
: "${SSH_OPTS:=-o BatchMode=yes -o StrictHostKeyChecking=accept-new}"
: "${PARALLEL:=0}"

# 本機 .env.deploy 可放 MQTT_PASSWORD 等，不進 git
if [ -f "${SCRIPT_DIR}/.env.deploy" ]; then
    # shellcheck disable=SC1091
    . "${SCRIPT_DIR}/.env.deploy"
fi

DRY_RUN=0
PRINT_SUDO=0
FILTERS=()

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'

log()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "${GREEN}" "${NC}" "$*"; }
warn() { printf '%s!%s %s\n' "${YELLOW}" "${NC}" "$*"; }
die()  { printf '%s✗%s %s\n' "${RED}" "${NC}" "$*" >&2; exit 1; }
step() { printf '\n%s%s── %s ──%s\n' "${BOLD}" "${BLUE}" "$*" "${NC}"; }

usage() {
    # 只印出檔頭的 # 註解；遇到第一行非註解就停（避免把 code 印出來）
    awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
    cat <<'EOF'

環境變數（或放在 beacons/.env.deploy）：
  MQTT_BROKER MQTT_PORT MQTT_TRANSPORT MQTT_USE_TLS MQTT_WS_PATH MQTT_CA_CERTS
  MQTT_USERNAME MQTT_PASSWORD MQTT_TOPIC USE_TEST_MODE
  REMOTE_DIR(~/beacons) SSH_PORT(22) SSH_OPTS PARALLEL(0)

範例：
  MQTT_PASSWORD=secret ./deploy.sh
  ./deploy.sh --parallel                   # 三台同時部署（快，但輸出會交錯）
  MQTT_BROKER=127.0.0.1 MQTT_PORT=1883 MQTT_TRANSPORT=tcp MQTT_USE_TLS=False \
      MQTT_USERNAME=None MQTT_PASSWORD=None ./deploy.sh      # 連區網 broker 測試

hosts.txt 每一行：<ssh 目標> [RECEIVER_NO]，例如
  pi@raspi-1.local  1
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|--dry) DRY_RUN=1; shift ;;
        --parallel|-p)   PARALLEL=1; shift ;;
        --print-sudo-setup) PRINT_SUDO=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        --) shift; FILTERS+=("$@"); break ;;
        -*) echo "未知選項: $1" >&2; usage; exit 2 ;;
        *) FILTERS+=("$1"); shift ;;
    esac
done

# ─── 前置檢查 ────────────────────────────────
command -v rsync >/dev/null || die "找不到 rsync（macOS: brew install rsync）"
command -v ssh   >/dev/null || die "找不到 ssh"
command -v python3 >/dev/null || die "找不到 python3"
[ -f "${HOSTS_FILE}" ] || die "找不到 ${HOSTS_FILE}"
[ -f "${TEMPLATE}" ]   || die "找不到 ${TEMPLATE}"

case "${MQTT_USE_TLS}" in
    True|true|1|yes)   MQTT_USE_TLS=True ;;
    False|false|0|no)  MQTT_USE_TLS=False ;;
    *) die "MQTT_USE_TLS 必須是 True/False（目前: ${MQTT_USE_TLS}）" ;;
esac
case "${USE_TEST_MODE}" in
    True|true|1|yes)  USE_TEST_MODE=True ;;
    False|false|0|no) USE_TEST_MODE=False ;;
    *) die "USE_TEST_MODE 必須是 True/False（目前: ${USE_TEST_MODE}）" ;;
esac
case "${MQTT_TRANSPORT}" in
    tcp) ;;
    websockets) ;;
    *) die "MQTT_TRANSPORT 必須是 tcp 或 websockets（目前: ${MQTT_TRANSPORT}）" ;;
esac

if [ "${MQTT_TRANSPORT}" = "websockets" ]; then
    if [ "${MQTT_USE_TLS}" = "True" ]; then
        LINK_DESC="wss://${MQTT_BROKER}:${MQTT_PORT}${MQTT_WS_PATH}"
    else
        LINK_DESC="ws://${MQTT_BROKER}:${MQTT_PORT}${MQTT_WS_PATH}"
    fi
elif [ "${MQTT_USE_TLS}" = "True" ]; then
    LINK_DESC="mqtts://${MQTT_BROKER}:${MQTT_PORT}"
else
    LINK_DESC="mqtt://${MQTT_BROKER}:${MQTT_PORT}"
fi

# ─── 解析 hosts.txt → 目標清單 "目標|RECEIVER_NO" ─────
TARGETS=()
line_no=0
while IFS= read -r line || [ -n "${line}" ]; do
    line_no=$((line_no + 1))
    line="${line%%#*}"                                # 去掉註解
    line="$(printf '%s' "${line}" | xargs || true)"    # 收斂空白
    [ -z "${line}" ] && continue

    read -r target no <<<"${line}"
    [ -z "${no:-}" ] && no="${line_no}"
    [[ "${no}" =~ ^[0-9]+$ ]] || die "hosts.txt 第 ${line_no} 行的 RECEIVER_NO 不是數字: ${no}"

    if [ "${#FILTERS[@]}" -gt 0 ]; then
        matched=0
        for f in "${FILTERS[@]}"; do
            case "${target}" in *"${f}"*) matched=1 ;; esac
        done
        [ "${matched}" -eq 1 ] || continue
    fi

    TARGETS+=("${target}|${no}")
done < "${HOSTS_FILE}"

[ "${#TARGETS[@]}" -gt 0 ] || die "hosts.txt 沒有符合的目標（或檔案是空的）"

# RECEIVER_NO 重複 = MQTT topic 撞號，先擋下來
dupes="$(printf '%s\n' "${TARGETS[@]}" | cut -d'|' -f2 | sort | uniq -d | tr '\n' ' ')"
[ -z "${dupes// /}" ] || die "hosts.txt 的 RECEIVER_NO 重複（會導致 MQTT topic 撞號）: ${dupes}"

# ─── --print-sudo-setup：只印出「讓 sudo -n 可用」的指令，不改任何東西 ───
if [ "${PRINT_SUDO:-0}" = "1" ]; then
    echo "# 讓 deploy.sh 的 'sudo -n' 可用（它不會卡在密碼提示）"
    echo "# 以下只是印出來給你貼，本腳本沒有執行任何變更。"
    echo
    echo "# 方式 1：對每個目標各跑一次（每台要輸入一次該台密碼）"
    _hosts=""
    for entry in "${TARGETS[@]}"; do
        _t="${entry%|*}"
        _hosts="${_hosts} ${_t}"
        _u="${_t%@*}"
        [ "${_u}" = "${_t}" ] && _u="${USER}"
        echo "  ssh ${_t} \"echo '${_u} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/010-${_u}-deploy && sudo chmod 440 /etc/sudoers.d/010-${_u}-deploy\""
    done
    # 迴圈版用第一台的帳號名（慣例上三台相同）
    _u="${TARGETS[0]%|*}"; _u="${_u%@*}"; [ "${_u}" = "${TARGETS[0]%|*}" ] && _u="${USER}"
    echo
    echo "# 方式 2：一行迴圈版"
    echo "  for h in${_hosts}; do ssh \"\$h\" \"echo '${_u} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/010-${_u}-deploy && sudo chmod 440 /etc/sudoers.d/010-${_u}-deploy\"; done"
    echo
    echo "# 驗證（每台都應印出 ok）"
    echo "  for h in${_hosts}; do printf '%s: ' \"\$h\"; ssh \"\$h\" 'sudo -n true && echo ok' 2>&1; done"
    echo
    echo "# 註：想縮小範圍可改成 NOPASSWD: /usr/bin/bash, /usr/bin/systemctl, /usr/bin/apt-get, /usr/bin/rfkill"
    echo "#     但允許 sudo bash 實質上就等於 ALL（bash 可執行任何指令）。"
    exit 0
fi

# ─── 渲染 my_secrets.py（本機完成、先 compile 驗證）─────
render_secrets() {
    local receiver_no="$1"
    RECEIVER_NO="${receiver_no}" \
    BROKER="${MQTT_BROKER}" PORT="${MQTT_PORT}" \
    TRANSPORT="${MQTT_TRANSPORT}" USE_TLS="${MQTT_USE_TLS}" \
    WS_PATH="${MQTT_WS_PATH}" CA_CERTS="${MQTT_CA_CERTS}" \
    USERNAME="${MQTT_USERNAME}" PASSWORD="${MQTT_PASSWORD}" \
    TOPIC="${MQTT_TOPIC}" USE_TEST_MODE="${USE_TEST_MODE}" \
    TEMPLATE="${TEMPLATE}" python3 - <<'PY'
import json, os, re, sys

tpl = open(os.environ["TEMPLATE"], encoding="utf-8").read()


def py_literal(key, numeric=False, boolean=False):
    """環境變數 → Python 字面值。

    numeric=True （port / RECEIVER_NO）→ 數字
    boolean=True （USE_TLS / USE_TEST_MODE）→ True / False
    其餘一律字串（用 json.dumps 跳脫），因為：
      MQTT_PASSWORD=0     → "password": 0     （型別錯，變成 int）
      MQTT_PASSWORD=0755  → "password": 0755  （SyntaxError：前導零）
    字串欄位填字面 None（代表「不使用」，例如 username=None）仍輸出 None。
    """
    val = os.environ.get(key, "")
    if boolean:
        return "True" if str(val).strip().lower() in ("1", "true", "yes", "y", "on") else "False"
    if numeric:
        if re.fullmatch(r"-?\d+", val):
            return val
        return json.dumps(val, ensure_ascii=False)
    if val == "None":
        return "None"
    return json.dumps(val, ensure_ascii=False)


# 數字欄位 / 布林欄位；其餘（含 password）一律字串
NUMERIC_KEYS = {"PORT", "RECEIVER_NO"}
BOOLEAN_KEYS = {"USE_TLS", "USE_TEST_MODE"}

for key in ("BROKER", "PORT", "TRANSPORT", "USE_TLS", "WS_PATH", "CA_CERTS",
            "USERNAME", "PASSWORD", "TOPIC", "RECEIVER_NO", "USE_TEST_MODE"):
    tpl = tpl.replace(
        f"@{key}@",
        py_literal(key, numeric=key in NUMERIC_KEYS, boolean=key in BOOLEAN_KEYS),
    )

left = sorted(set(re.findall(r"@[A-Z_]+@", tpl)))
if left:
    sys.exit(f"模板有未替換的變數: {left}")

# 先用本機 python 編譯，避免把語法錯誤推到三台機器才發現
compile(tpl, "<my_secrets>", "exec")
sys.stdout.write(tpl)
PY
}

# ─── 單台部署 ────────────────────────────────
# 回傳 0 = 成功；非 0 = 失敗（main 會彙整）
deploy_one() {
    local target="$1" receiver_no="$2"
    local host="${target##*@}"
    local log_file="${LOG_DIR}/${host//[^A-Za-z0-9._-]/_}.log"
    local ssh_cmd="ssh ${SSH_OPTS} -p ${SSH_PORT}"
    mkdir -p "${LOG_DIR}"
    : >"${log_file}"

    step "${target}  (RECEIVER_NO=${receiver_no})"

    # dry-run 不碰遠端（連 SSH 連線測試都跳過）
    if [ "${DRY_RUN}" = "1" ]; then
        local show_dir="${REMOTE_DIR}"
        case "${show_dir}" in
            /*) ;;
            *) show_dir="\$HOME/${show_dir#\~/}" ;;
        esac
        cat <<EOF
    [dry-run] 目標目錄      : ${show_dir}（遠端絕對路徑）
    [dry-run] rsync         : code.py get_exponent.py requirements.txt setup-system.sh
                              requirements-measure.txt install_systemd.sh
                              debug_output.sh my_secrets.py.tmpl diagnose_paho.sh
    [dry-run] my_secrets.py : RECEIVER_NO=${receiver_no} → ${LINK_DESC} topic=${MQTT_TOPIC}
    [dry-run] venv          : ${show_dir}/venv  (pip install -r requirements.txt)
    [dry-run]               : requirements.txt 只含 bleak + paho-mqtt（常駐服務用）
    [dry-run] sudo bash setup-system.sh --dir ${show_dir} --user <ssh user>
    [dry-run] systemctl restart ble-beacon-scanner + 健康檢查
EOF
        return 0
    fi

    # 1) 連線測試 —— 早點失敗比較好懂
    if ! ssh ${SSH_OPTS} -p "${SSH_PORT}" -o ConnectTimeout=10 "${target}" true 2>"${log_file}.ssh"; then
        warn "SSH 連不上 ${target}："
        sed 's/^/    /' "${log_file}.ssh" 2>/dev/null >&2 || true
        return 1
    fi
    ok "SSH 連線正常"

    # 展開遠端 ~ 與推斷遠端使用者名稱（unit 的 User= 要用）
    # 注意：ssh 的遠端命令會再做一次 word splitting + 展開，所以路徑含空白或 ~ 會被二次展開。
    #       這裡一次算成絕對路徑並在遠端設定 HOME，杜絕 '~' 在不同位置被展開成不同字串。
    local remote_home rc remote_dir remote_user
    remote_home="$(ssh ${SSH_OPTS} -p "${SSH_PORT}" "${target}" 'printf %s "$HOME"')"
    case "${remote_home}" in
        /*) ;;
        *) warn "無法取得 ${target} 的 \$HOME（得到 ${remote_home:-空}）"; return 1 ;;
    esac
    case "${REMOTE_DIR}" in
        "~")   remote_dir="${remote_home}" ;;
        "~/"*) remote_dir="${remote_home}/${REMOTE_DIR#\~/}" ;;
        /*)    remote_dir="${REMOTE_DIR}" ;;
        *)     remote_dir="${remote_home}/${REMOTE_DIR}" ;;
    esac
    remote_dir="${remote_dir%/}"
    case "${remote_dir}" in
        *[\'\"\ \\$]*) warn "遠端目錄含引號/空白/\$，請改用不含這些字元的路徑: ${remote_dir}"; return 1 ;;
    esac
    remote_user="${target%@*}"
    [ "${remote_user}" = "${target}" ] && remote_user="$(ssh ${SSH_OPTS} -p "${SSH_PORT}" "${target}" 'id -un')"

    # 2) 推程式碼（排除本機 venv / secrets / 快取 / 部署產物）
    ssh ${SSH_OPTS} -p "${SSH_PORT}" "${target}" "mkdir -p '${remote_dir}'" \
        || { warn "無法建立 ${remote_dir}"; return 1; }

    if ! rsync -az --delete \
            --exclude '.venv/' --exclude 'venv/' --exclude '__pycache__/' \
            --exclude 'my_secrets.py' --exclude 'result.txt' --exclude '.deploy-logs/' \
            --exclude '.env.deploy' --exclude '.DS_Store' --exclude '.git/' \
            -e "${ssh_cmd}" \
            "${SCRIPT_DIR}/" "${target}:${remote_dir}/" >>"${log_file}" 2>&1; then
        warn "rsync 失敗（詳見 ${log_file}）"
        tail -20 "${log_file}" | sed 's/^/    /' >&2 || true
        return 1
    fi
    ok "程式碼已同步到 ${remote_dir}"

    # 3) 寫 my_secrets.py（走 stdin：密碼不進指令列、不經過 rsync、不進 git）
    if ! render_secrets "${receiver_no}" \
        | ssh ${SSH_OPTS} -p "${SSH_PORT}" "${target}" \
            "umask 077 && cat > '${remote_dir}/.my_secrets.tmp' \
             && mv '${remote_dir}/.my_secrets.tmp' '${remote_dir}/my_secrets.py'"; then
        warn "寫入 my_secrets.py 失敗"
        return 1
    fi
    ok "my_secrets.py 已寫入（RECEIVER_NO=${receiver_no}, ${LINK_DESC}）"

    # 記錄版號：每一台 .deployed 寫下 commit/時間/參數，remote 沒 git 也能查
    local rev deployed_at
    rev="$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo nogit)"
    [ -n "$(git -C "${SCRIPT_DIR}" status --porcelain 2>/dev/null)" ] && rev="${rev}+dirty"
    deployed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ssh ${SSH_OPTS} -p "${SSH_PORT}" "${target}" \
        "printf '%s\n' 'rev=${rev}' 'deployed_at=${deployed_at}' 'receiver_no=${receiver_no}' 'broker=${LINK_DESC}' 'topic=${MQTT_TOPIC}' > '${remote_dir}/.deployed'" \
        >>"${log_file}" 2>&1 || warn "無法寫入 .deployed（不影響部署）"

    # 4) venv + 相依套件
    if ! ssh ${SSH_OPTS} -p "${SSH_PORT}" "${target}" bash -s -- "${remote_dir}" >>"${log_file}" 2>&1 <<'REMOTE'
set -euo pipefail
cd "$1"
if [ ! -x venv/bin/python3 ]; then
    python3 -m venv --help >/dev/null 2>&1 || {
        echo "ERROR: python3-venv 未安裝（先跑一次 sudo setup-system.sh）" >&2; exit 1; }
    python3 -m venv venv
fi
venv/bin/pip3 install -q --upgrade pip
venv/bin/pip3 install -q -r requirements.txt
# 驗證：code.py 需要的 import 都能成立（bleak 3.x 沒有 __version__，改用 importlib.metadata）
venv/bin/python3 - <<'PY'
import importlib.metadata as md
import sys
print("python:", sys.executable)
try:
    import bleak  # noqa: F401
    import paho.mqtt.client  # noqa: F401
except ModuleNotFoundError as e:
    # 明確指出「哪個 Python 少了哪個套件」——只印 traceback 很容易被誤認成
    # 裝到系統 Python 去了（No module named 'paho' 的經典來源）
    print(f"ERROR: {sys.executable} 缺少套件：{e}", file=sys.stderr)
    print("       請確認是用 venv/bin/pip 安裝，不是 pip3 install。", file=sys.stderr)
    raise
print("deps ok: bleak", md.version("bleak"), "/ paho-mqtt", md.version("paho-mqtt"))
PY
REMOTE
    then
        warn "安裝 Python 相依失敗（詳見 ${log_file}）"
        tail -20 "${log_file}" | sed 's/^/    /' >&2 || true
        # 針對常見的「要現場編譯」失敗給出可執行的建議
        if grep -q "swig' failed\|command 'swig'" "${log_file}" 2>/dev/null; then
            log  "  原因：某個相依沒有 Python $(ssh ${SSH_OPTS} -p "${SSH_PORT}" "${target}" 'python3 -c "import sys;print(\"%d.%d\"%sys.version_info[:2])"' 2>/dev/null || echo '?')" \
                 "的 wheel，pip 正在現場編譯但缺少 swig。"
            log  "  requirements.txt 只該包含常駐服務需要的 bleak / paho-mqtt；"
            log  "  若你剛把 adafruit-blinka 加回來，請改放到 requirements-measure.txt。"
        elif grep -q "No module named 'paho'\|No module named 'bleak'" "${log_file}" 2>/dev/null; then
            log  "  原因：套件沒進到 ${remote_dir}/venv（多半是裝到系統 Python 或 ~/.local）。"
            log  "  在 ${target} 上修："
            log  "    cd ${remote_dir} && venv/bin/pip install -r requirements.txt"
            log  "    sudo systemctl restart ble-beacon-scanner"
            log  "  想先確認裝到哪去了：cd ${remote_dir} && ./diagnose_paho.sh"
        elif grep -q 'No matching distribution\|Could not find a version' "${log_file}" 2>/dev/null; then
            log  "  原因：PyPI 上找不到對應此 Python 版本 / 架構的套件版本。"
        fi
        return 1
    fi
    ok "venv 與 requirements.txt 就緒"

    # 5) 系統層設定（BlueZ / bluetooth 群組 / systemd unit）；需要免密碼 sudo
    if ! ssh ${SSH_OPTS} -p "${SSH_PORT}" "${target}" \
            "sudo -n bash -s -- --dir '${remote_dir}' --user '${remote_user}'" \
            < "${SCRIPT_DIR}/setup-system.sh" >>"${log_file}" 2>&1; then
        if grep -q 'sudo: a password is required\|interactive authentication' "${log_file}" 2>/dev/null; then
            warn "需要免密碼 sudo（deploy.sh 用 sudo -n，不會卡在密碼提示）。在 ${target} 上執行："
            log  "    echo '${remote_user} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/010-${remote_user}-deploy"
            log  "    sudo chmod 440 /etc/sudoers.d/010-${remote_user}-deploy"
            log  "  （想縮小範圍可改成 NOPASSWD: /usr/bin/bash, /usr/bin/systemctl, /usr/bin/apt-get, /usr/bin/rfkill）"
            log  "  或先跑 ./deploy.sh --print-sudo-setup 取得三台的一次性指令。"
        else
            warn "setup-system.sh 失敗（詳見 ${log_file}）"
            tail -20 "${log_file}" | sed 's/^/    /' >&2 || true
        fi
        return 1
    fi
    ok "系統層設定完成（bluetooth + systemd unit）"

    # 6) 重啟 + 健康檢查
    if ! ssh ${SSH_OPTS} -p "${SSH_PORT}" "${target}" \
            "sudo -n systemctl restart ble-beacon-scanner" >>"${log_file}" 2>&1; then
        warn "restart 服務失敗（詳見 ${log_file}）"
        return 1
    fi
    sleep 5

    local health state
    health="$(ssh ${SSH_OPTS} -p "${SSH_PORT}" "${target}" bash -s <<'REMOTE' 2>&1
systemctl is-active ble-beacon-scanner || true
journalctl -u ble-beacon-scanner -n 40 --no-pager 2>/dev/null | tail -40
REMOTE
)" || true
    printf '%s\n' "${health}" >>"${log_file}"
    state="$(printf '%s\n' "${health}" | head -1)"

    if [ "${state}" != "active" ]; then
        warn "服務狀態 = ${state}（未啟動）"
        printf '%s\n' "${health}" | tail -15 | sed 's/^/    /' >&2 || true
        return 1
    fi
    if printf '%s\n' "${health}" | grep -qE 'Starting BLE scan|Successfully connected to MQTT|MQTT|學號'; then
        ok "服務運行中，且已開始 BLE 掃描 / 連上 MQTT"
        return 0
    fi
    warn "服務 active，但日誌還沒出現掃描或 MQTT 訊息（可能剛啟動）"
    printf '%s\n' "${health}" | tail -10 | sed 's/^/    /' || true
    return 0
}

# ─── Main ────────────────────────────────────
main() {
    mkdir -p "${LOG_DIR}"

    printf '%s%s══════════════════════════════════════════════════%s\n' "${BOLD}" "${BLUE}" "${NC}"
    printf '%s  beacons 多機部署%s\n' "${BOLD}" "${NC}"
    printf '%s══════════════════════════════════════════════════%s\n' "${BLUE}" "${NC}"
    log "  MQTT    : ${LINK_DESC}   topic=${MQTT_TOPIC}/receivers/<n>"
    log "  Auth    : $( [ "${MQTT_USERNAME}" = "None" ] && echo '-（無）' || echo "user=${MQTT_USERNAME}, password=$([ -n "${MQTT_PASSWORD}" ] && echo '***' || echo '（空）')" )"
    log "  測試模式: ${USE_TEST_MODE}   (USE_TEST_MODE 需 False 才會跟後端要 XOR Key)"
    log "  遠端目錄: ${REMOTE_DIR}"
    log "  目標    : ${#TARGETS[@]} 台$([ "${DRY_RUN}" = "1" ] && echo '  [dry-run]')"

    local failed=() succeeded=()
    local entry target no

    if [ "${PARALLEL}" = "1" ]; then
        # 平行：三台的 log 各自寫檔，完成後再一次性印出結果
        log "  模式    : 平行部署"
        local pids=()
        local idx=0
        for entry in "${TARGETS[@]}"; do
            target="${entry%|*}"
            no="${entry##*|}"
            ( if deploy_one "${target}" "${no}"; then echo "OK|${target}|${no}"; else echo "FAIL|${target}|${no}"; fi
            ) >"${LOG_DIR}/parallel-${idx}.out" 2>&1 &
            pids+=($!)
            idx=$((idx + 1))
        done
        local pid
        for pid in "${pids[@]}"; do wait "${pid}" || true; done
        local f status
        for f in "${LOG_DIR}"/parallel-*.out; do
            [ -f "${f}" ] || continue
            grep -vE '^(OK|FAIL)\|' "${f}" | sed '/^$/d' || true
            status="$(grep -E '^(OK|FAIL)\|' "${f}" | tail -1 || true)"
            case "${status}" in
                OK\|*)   succeeded+=("$(echo "${status}" | cut -d'|' -f2,3 --output-delimiter=' #')") ;;
                FAIL\|*) failed+=("$(echo "${status}" | cut -d'|' -f2,3 --output-delimiter=' #')") ;;
            esac
            rm -f "${f}"
        done
    else
        for entry in "${TARGETS[@]}"; do
            target="${entry%|*}"
            no="${entry##*|}"
            if deploy_one "${target}" "${no}"; then
                succeeded+=("${target} (#${no})")
            else
                failed+=("${target} (#${no})")
            fi
        done
    fi

    step "部署結果"
    local t
    for t in "${succeeded[@]:-}"; do [ -n "${t}" ] && ok "${t}"; done
    for t in "${failed[@]:-}";    do [ -n "${t}" ] && printf '%s✗%s %s\n' "${RED}" "${NC}" "${t}"; done
    log ""
    log "日誌：${LOG_DIR}/"
    log "看某台即時輸出：ssh ${TARGETS[0]%%|*} 'journalctl -u ble-beacon-scanner -f'"

    [ "${#failed[@]}" -eq 0 ] || { warn "${#failed[@]} 台失敗"; exit 1; }
    ok "全部 ${#succeeded[@]} 台部署完成"
}

main "$@"
