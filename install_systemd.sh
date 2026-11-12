#!/usr/bin/env bash
# ============================================================
# install_systemd.sh
#
# One-click installer for BLE Beacon Scanner.
# Automatically:
#   1. Installs pip & venv (if missing)          via apt
#   2. Creates Python virtual environment        (venv/bin/pip, 不是系統 pip)
#   3. Installs required bleak / paho-mqtt packages via pip
#      └ 安裝後一定用「venv 的 python」驗證 import，避免裝到系統 Python
#        卻以為成功（No module named 'paho' 的來源）
#   4. Adds SERVICE_USER to the bluetooth group  (BLE 掃描的 D-Bus 權限)
#   5. Prompts for my_secrets.py configuration (含 tcp / ws / wss 連線方式)
#   6. Installs & starts the systemd service     (uses venv Python)
#      └ unit 由 setup-system.sh 產生（唯一來源），確保與 deploy.sh 一致，
#        且一定包含 ExecStopPost（收乾淨 BlueZ discovery session）
#
# Usage:
#   sudo ./install_systemd.sh install     # Full one-click setup
#   sudo ./install_systemd.sh uninstall   # Stop & remove the service
#   sudo ./install_systemd.sh status      # Check service status
#
# 若只想修「No module named 'paho'」：
#   ./venv/bin/pip install -r requirements.txt && sudo systemctl restart ble-beacon-scanner
#   或先跑 ./diagnose_paho.sh 看套件到底裝到哪個 Python
# ============================================================

set -euo pipefail

SERVICE_NAME="ble-beacon-scanner"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
# Resolve the directory where this script lives (even if called via symlink)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PYTHON_PATH="${SCRIPT_DIR}/code.py"
WORKING_DIR="${SCRIPT_DIR}"
VENV_DIR="${SCRIPT_DIR}/venv"
VENV_PYTHON="${VENV_DIR}/bin/python3"
REQUIREMENTS="${SCRIPT_DIR}/requirements.txt"

# 服務執行身分：可用環境變數覆寫（deploy.sh / setup-system.sh 會帶入）
#   SERVICE_USER=pi SERVICE_GROUP=pi sudo -E ./install_systemd.sh install-service
SERVICE_USER="${SERVICE_USER:-$(id -un)}"
# BLE 掃描需要 D-Bus 存取權限，執行帳號必須在 bluetooth 群組裡（否則 BlueZ
# 會回 org.bluez.Error.NotPermitted）。根目錄服務不需額外群組，但以一般使用者
# 執行時「主群組」不等於「bluetooth 群組」，所以 default 不能帶入主群組。
SERVICE_GROUP="${SERVICE_GROUP:-}"

# installer 若以 sudo 執行，SUDO_USER 才是真正要跑服務的人
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    if [ "${SERVICE_USER}" = "root" ]; then
        SERVICE_USER="${SUDO_USER}"
    fi
fi

# --- Systemd Unit Definition ---
# ⚠️ 這份 unit 必須與 setup-system.sh 產生的完全一致，否則「用哪個腳本安裝」
#    會得到不同行為（例如漏掉 ExecStopPost 就會讓 org.bluez.Error.InProgress
#    復發）。要改就兩個檔案一起改。
UNIT_GROUP_LINE=""
if [ -n "${SERVICE_GROUP}" ]; then
    UNIT_GROUP_LINE="Group=${SERVICE_GROUP}"
fi
UNIT_CONTENT=$(cat <<EOF
[Unit]
Description=BLE Beacon Scanner – scans BLE advertisements and publishes via MQTT
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
${UNIT_GROUP_LINE}
WorkingDirectory=${WORKING_DIR}
ExecStart=${VENV_PYTHON} -u ${PYTHON_PATH}
# 服務結束時把 adapter 上殘留的 discovery 收乾淨；否則下一輪 StartDiscovery
# 會撞 org.bluez.Error.InProgress（"Operation already in progress"）。
ExecStopPost=-/usr/bin/bluetoothctl --timeout 3 scan off
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
)

# ──────────────────────────────────────────────
# 把服務帳號加入 bluetooth 群組（BLE 掃描的 D-Bus 權限）
# ──────────────────────────────────────────────
ensure_bluetooth_group() {
    [ -z "${SERVICE_USER}" ] && return 0
    if ! id "${SERVICE_USER}" &>/dev/null; then
        echo "    ⚠️ 使用者 ${SERVICE_USER} 不存在，略過 bluetooth 群組設定"
        return 0
    fi
    # root 有完整 D-Bus 權限，不需群組
    if [ "${SERVICE_USER}" = "root" ]; then
        echo "    ${SERVICE_USER} 是 root，不需加入 bluetooth 群組。"
        return 0
    fi
    if id -nG "${SERVICE_USER}" | tr ' ' '\n' | grep -qx bluetooth; then
        echo "    ${SERVICE_USER} 已在 bluetooth 群組。"
        return 0
    fi
    echo ">>> 將 ${SERVICE_USER} 加入 bluetooth 群組（BLE 掃描需要 D-Bus 權限）..."
    if usermod -aG bluetooth "${SERVICE_USER}"; then
        # 注意：本腳本結束後、服務啟動前，systemd 會重新 fork 新 process，
        # 因此群組成員資格「會生效」；不需要重新登入。
        echo "    ✅ 已加入（服務下次啟動即生效；互動 shell 需重新登入）"
    else
        echo "    ⚠️ 無法加入 bluetooth 群組；若掃描出現 org.bluez.Error.NotPermitted，請手動執行："
        echo "       sudo usermod -aG bluetooth ${SERVICE_USER}"
    fi
}

# ──────────────────────────────────────────────
# Setup venv & install Python dependencies
# ──────────────────────────────────────────────
setup_venv() {
    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║   Step 1: Setting up Python virtual env...    ║"
    echo "╚═══════════════════════════════════════════════╝"

    # Install pip and venv if missing
    if ! command -v pip3 &>/dev/null; then
        echo ">>> Installing pip..."
        apt-get update -qq
        apt-get install -y -qq python3-pip python3-venv
    fi

    # Ensure venv module available
    if ! python3 -m venv --help &>/dev/null; then
        echo ">>> Installing python3-venv..."
        apt-get install -y -qq python3-venv
    fi

    # BlueZ / D-Bus 執行期相依（bleak 走 D-Bus；lite 版 Raspi OS 預設沒有）
    echo ">>> Ensuring BlueZ / D-Bus system packages..."
    apt-get install -y -qq bluez bluetooth libglib2.0-dev >/dev/null 2>&1 || \
        echo "    ⚠️ 無法安裝 bluez/bluetooth（請稍後手動 apt install bluez bluetooth）"

    # Create virtual environment (if not already exists)
    if [ ! -d "${VENV_DIR}" ]; then
        echo ">>> Creating virtual environment at ${VENV_DIR}..."
        python3 -m venv "${VENV_DIR}"
    else
        echo ">>> Virtual environment already exists at ${VENV_DIR}"
    fi

    # Upgrade pip inside venv
    echo ">>> Upgrading pip in venv..."
    local VENV_PIP="${VENV_DIR}/bin/pip"
    # ⚠️ 某些 venv（或 --without-pip 建立的）只有 pip 沒有 pip3；兩者都要試
    [ -x "${VENV_PIP}" ] || VENV_PIP="${VENV_DIR}/bin/pip3"
    if [ ! -x "${VENV_PIP}" ]; then
        echo "ERROR: venv 裡找不到 pip（${VENV_DIR}/bin/pip[3]）"
        echo "       重建： rm -rf '${VENV_DIR}' && python3 -m venv '${VENV_DIR}'"
        exit 1
    fi
    "${VENV_PIP}" install --upgrade pip -q

    # Install required packages（唯一的相依來源：requirements.txt）
    if [ -f "${REQUIREMENTS}" ]; then
        echo ">>> Installing packages from ${REQUIREMENTS}..."
        "${VENV_PIP}" install -q -r "${REQUIREMENTS}"
    else
        echo ">>> requirements.txt not found, installing bleak / paho-mqtt directly..."
        "${VENV_PIP}" install -q bleak paho-mqtt
    fi

    # 驗證：一定要用 venv 的 python 檢查，否則很容易「裝到系統 Python」
    # 卻以為裝好了（No module named 'paho' 的經典來源）
    if ! "${VENV_PYTHON}" - <<'PY'
import sys
print(">>> 使用 Python:", sys.executable)
try:
    import bleak  # noqa: F401
    import paho.mqtt.client  # noqa: F401
except ModuleNotFoundError as e:
    sys.exit(f"ERROR: {sys.executable} 缺少套件 {e}")
PY
    then
        echo "ERROR: venv 相依安裝不完整（見上方訊息）。"
        echo "       手動修正： ${VENV_PIP} install -r ${REQUIREMENTS}"
        exit 1
    fi

    echo "✅ Virtual environment ready."
}

# ──────────────────────────────────────────────
# Configure my_secrets.py interactively
# ──────────────────────────────────────────────
setup_secrets() {
    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║   Step 2: Configuring my_secrets.py...        ║"
    echo "╚═══════════════════════════════════════════════╝"

    SECRETS_FILE="${SCRIPT_DIR}/my_secrets.py"

    # Read current values if file exists
    current_broker="broker.hivemq.com"
    current_port="1883"
    current_username="None"
    current_password="None"
    current_topic="ble/beacons/ggg"
    current_no="1"
    current_transport="tcp"
    current_tls="False"
    current_ws_path="/"

    if [ -f "${SECRETS_FILE}" ]; then
        echo ">>> Existing my_secrets.py found. Reading current values as defaults."
        current_broker=$(sed -n 's/.*"broker":\s*"\(.*\)".*/\1/p' "${SECRETS_FILE}" | head -1)
        current_port=$(sed -n 's/.*"port":\s*\([0-9]*\).*/\1/p' "${SECRETS_FILE}" | head -1)
        current_username=$(sed -n 's/.*"username":\s*\([^,]*\).*/\1/p' "${SECRETS_FILE}" | head -1 | xargs)
        current_password=$(sed -n 's/.*"password":\s*\([^,]*\).*/\1/p' "${SECRETS_FILE}" | head -1 | xargs)
        current_topic=$(sed -n 's/.*"topic":\s*"\(.*\)".*/\1/p' "${SECRETS_FILE}" | head -1)
        current_no=$(grep -oP 'RECEIVER_NO\s*=\s*\K[0-9]+' "${SECRETS_FILE}")
        # 以下為選填欄位：舊版 my_secrets.py 沒有這些 key，故需先判斷非空才覆蓋
        _read_transport=$(sed -n 's/.*"transport":\s*"\([^"]*\)".*/\1/p' "${SECRETS_FILE}" | head -1)
        if [ -n "${_read_transport}" ]; then
            current_transport="${_read_transport}"
        fi
        _read_tls=$(sed -n 's/.*"use_tls":\s*\([^,]*\).*/\1/p' "${SECRETS_FILE}" | head -1 | xargs)
        if [ -n "${_read_tls}" ]; then
            current_tls="${_read_tls}"
        fi
        _read_ws=$(sed -n 's/.*"ws_path":\s*"\([^"]*\)".*/\1/p' "${SECRETS_FILE}" | head -1)
        if [ -n "${_read_ws}" ]; then
            current_ws_path="${_read_ws}"
        fi
    fi

    # Prompt user (with defaults)
    read -r -p "MQTT Broker [${current_broker}]: " input_broker
    broker="${input_broker:-$current_broker}"

    read -r -p "MQTT Port [${current_port}]: " input_port
    port="${input_port:-$current_port}"

    read -r -p "MQTT Username (or None) [${current_username}]: " input_username
    username="${input_username:-$current_username}"

    read -r -s -p "MQTT Password (or None) [${current_password}]: " input_password
    echo ""
    password="${input_password:-$current_password}"

    read -r -p "MQTT Topic [${current_topic}]: " input_topic
    topic="${input_topic:-$current_topic}"

    read -r -p "Receiver No. [${current_no}]: " input_no
    no="${input_no:-$current_no}"

    # ─── 連線方式（wss 支援）─────────────────────
    echo ""
    echo "  連線方式：tcp = 原生 MQTT(1883) / websockets = MQTT over WebSocket(9001 或 wss)"
    read -r -p "MQTT Transport (tcp|websockets) [${current_transport}]: " input_transport
    transport="${input_transport:-$current_transport}"
    case "${transport}" in
        tcp|websockets) ;;
        *) echo ">>> 無法辨識 '${transport}'，改用 tcp"; transport="tcp" ;;
    esac

    read -r -p "Use TLS / wss? (True|False) [${current_tls}]: " input_tls
    use_tls="${input_tls:-$current_tls}"
    case "${use_tls}" in
        True|true|1|yes|y|Y) use_tls="True" ;;
        *) use_tls="False" ;;
    esac

    ws_path="${current_ws_path}"
    if [ "${transport}" = "websockets" ]; then
        read -r -p "WebSocket Path (Cloudflare 常用 '/') [${current_ws_path}]: " input_ws
        ws_path="${input_ws:-$current_ws_path}"
    fi

    # 使用者輸入 None → 寫成 Python 的 None（不加引號），避免變成字串 "None"
    if [ "${username}" = "None" ] || [ -z "${username}" ]; then
        username_literal="None"
    else
        username_literal="\"${username}\""
    fi
    if [ "${password}" = "None" ] || [ -z "${password}" ]; then
        password_literal="None"
    else
        password_literal="\"${password}\""
    fi

    # Write secrets file
    echo ">>> Writing ${SECRETS_FILE}..."
    cat > "${SECRETS_FILE}" <<EOF
mqtt_env = {
    "broker": "${broker}",
    "port": ${port},
    "username": ${username_literal},
    "password": ${password_literal},
    "topic": "${topic}",

    # "transport": "tcp" | "websockets"；use_tls=True ⇒ websockets 走 wss
    "transport": "${transport}",
    "use_tls": ${use_tls},
    "ws_path": "${ws_path}",
    "ca_certs": None,
}

RECEIVER_NO = ${no}

# 測試模式：True = 用固定 TEST_KEY_2024 離線測試，False = 需向後端 API 取得 XOR Key
USE_TEST_MODE = True
EOF

    echo "✅ my_secrets.py configured."
    echo "   連線方式: $( [ "${transport}" = "websockets" ] \
        && { [ "${use_tls}" = "True" ] && echo "wss://${broker}:${port}${ws_path}" \
             || echo "ws://${broker}:${port}${ws_path}"; } \
        || { [ "${use_tls}" = "True" ] && echo "mqtts://${broker}:${port}" \
             || echo "mqtt://${broker}:${port}"; } )"
}

# ──────────────────────────────────────────────
# Install systemd service
# ──────────────────────────────────────────────
install_service() {
    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║   Step 3: Installing systemd service...       ║"
    echo "╚═══════════════════════════════════════════════╝"

    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: Please run with sudo or as root to install a systemd service."
        exit 1
    fi

    # Check that Python exists
    if ! command -v python3 &>/dev/null; then
        echo "ERROR: python3 not found. Please install Python 3."
        exit 1
    fi

    # Check that the code.py exists
    if [ ! -f "${PYTHON_PATH}" ]; then
        echo "ERROR: ${PYTHON_PATH} not found!"
        exit 1
    fi

    # Check venv is ready
    # ⚠️ 不用 -x 判斷：部分系統的 venv/bin/python3 是 symlink，-x 可能誤判
    if [ ! -f "${VENV_PYTHON}" ] || ! "${VENV_PYTHON}" -c 'import sys' >/dev/null 2>&1; then
        echo "ERROR: Virtual environment not found or unusable at ${VENV_DIR}."
        echo "       Please run the install script again without skipping steps."
        exit 1
    fi

    # BLE 掃描需要的 D-Bus 權限（必須在 sudo 下執行才改得動群組）
    ensure_bluetooth_group

    # ── 優先用 setup-system.sh 產生 unit ──────────────────────────
    # 過去這個腳本自己寫 unit、setup-system.sh 也自己寫 unit，兩份內容會
    # 慢慢分岔（例如 ExecStopPost 只加在一邊），於是「用哪個腳本安裝」
    # 行為就不同。現在以 setup-system.sh 為唯一來源；找不到才退回內建版本。
    if [ -f "${SCRIPT_DIR}/setup-system.sh" ]; then
        echo ">>> 使用 setup-system.sh 產生 unit（唯一來源，與 deploy.sh 一致）"
        # 不用空陣列展開（bash < 4.4 + set -u 會報 unbound variable）
        if [ -n "${SERVICE_GROUP}" ]; then
            SS_ARGS=(--dir "${WORKING_DIR}" --user "${SERVICE_USER}" --group "${SERVICE_GROUP}")
        else
            SS_ARGS=(--dir "${WORKING_DIR}" --user "${SERVICE_USER}")
        fi
        if ! bash "${SCRIPT_DIR}/setup-system.sh" "${SS_ARGS[@]}"; then
            echo "ERROR: setup-system.sh 失敗。" >&2
            exit 1
        fi
    else
        echo "⚠️ 找不到 setup-system.sh，改用內建 unit 內容"
        echo "${UNIT_CONTENT}" | tee "${SERVICE_FILE}" > /dev/null
        echo ">>> Wrote ${SERVICE_FILE}"
        systemctl daemon-reload
        systemctl enable "${SERVICE_NAME}"
    fi

    systemctl restart "${SERVICE_NAME}"

    echo ""
    echo "✅ Service '${SERVICE_NAME}' installed and started."
    echo "   To view logs:  sudo journalctl -u ${SERVICE_NAME} -f"
    echo "   To stop:       sudo systemctl stop ${SERVICE_NAME}"
    echo "   To restart:    sudo systemctl restart ${SERVICE_NAME}"
}

# ──────────────────────────────────────────────
# Uninstall systemd service
# ──────────────────────────────────────────────
uninstall_service() {
    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║   Uninstalling systemd service...              ║"
    echo "╚═══════════════════════════════════════════════╝"

    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: Please run with sudo or as root to uninstall a systemd service."
        exit 1
    fi

    if systemctl is-enabled "${SERVICE_NAME}" &>/dev/null 2>&1; then
        systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
        systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    fi

    if [ -f "${SERVICE_FILE}" ]; then
        rm -f "${SERVICE_FILE}"
        echo ">>> Removed ${SERVICE_FILE}"
    fi

    systemctl daemon-reload

    read -r -p "Remove virtual environment at ${VENV_DIR}? [y/N]: " remove_venv
    if [[ "${remove_venv}" =~ ^[Yy]$ ]]; then
        rm -rf "${VENV_DIR}"
        echo ">>> Removed ${VENV_DIR}"
    fi

    echo "✅ Service '${SERVICE_NAME}' uninstalled."
}

# ──────────────────────────────────────────────
# Show status
# ──────────────────────────────────────────────
show_status() {
    echo ">>> Status of service: ${SERVICE_NAME}"
    echo ""
    if systemctl is-enabled "${SERVICE_NAME}" &>/dev/null 2>&1; then
        systemctl status "${SERVICE_NAME}" 2>/dev/null || echo "(service may not be running)"
    else
        echo "Service '${SERVICE_NAME}' is not installed."
    fi
}

# ──────────────────────────────────────────────
# Full install (all steps)
# ──────────────────────────────────────────────
full_install() {
    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║   BLE Beacon Scanner – One-Click Installer    ║"
    echo "╚═══════════════════════════════════════════════╝"

    # Step 1: Virtual environment (needs sudo for apt)
    if [ "$EUID" -ne 0 ]; then
        echo ">>> This script needs sudo for some steps. Please run as:"
        echo "    sudo $0 install"
        exit 1
    fi

    setup_venv

    # Step 2: Secrets (drop to normal user for interactive prompts)
    #    由 deploy.sh 自動化部署時會帶 SKIP_SECRETS=1（secrets 已用 API 金鑰寫好）
    if [ "${SKIP_SECRETS:-0}" = "1" ]; then
        echo ""
        echo ">>> Skipping my_secrets.py prompts (SKIP_SECRETS=1)"
        if [ ! -f "${SCRIPT_DIR}/my_secrets.py" ]; then
            echo "ERROR: ${SCRIPT_DIR}/my_secrets.py 不存在，無法跳過 Step 2。"
            exit 1
        fi
    else
        echo ""
        echo "╔═══════════════════════════════════════════════╗"
        echo "║   Step 2: Configuring my_secrets.py...        ║"
        echo "╚═══════════════════════════════════════════════╝"
        sudo -u "${SUDO_USER:-$(id -un)}" "$0" setup-secrets
    fi

    # Step 3: Systemd service
    install_service

    echo ""
    echo "🎉 Installation complete!"
    echo "   Service: ${SERVICE_NAME}"
    echo "   Logs:    sudo journalctl -u ${SERVICE_NAME} -f"
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
case "${1:-help}" in
    install)
        full_install
        ;;
    install-service)
        install_service
        ;;
    uninstall|remove)
        uninstall_service
        ;;
    status)
        show_status
        ;;
    setup-venv)
        setup_venv
        ;;
    setup-secrets)
        setup_secrets
        ;;
    *)
        echo "Usage: sudo $0 {install|uninstall|status}"
        echo ""
        echo "  install   – Full one-click setup (venv + secrets + service)"
        echo "  uninstall – Stop & remove the service"
        echo "  status    – Show current service status"
        echo ""
        echo "Advanced usage (run individual steps):"
        echo "  sudo $0 setup-venv     – Only create/recreate venv"
        echo "  $0 setup-secrets       – Only configure my_secrets.py"
        exit 1
        ;;
esac
