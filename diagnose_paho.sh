#!/usr/bin/env bash
# ============================================================
# diagnose_paho.sh — 找出 "No module named paho" 到底裝到哪去了
#
# 在樹莓派上直接執行（不需要 root）：
#
#   cd ~/beacons && ./diagnose_paho.sh
#   # 或指定目錄：./diagnose_paho.sh /home/pi/beacons
#
# 症狀："ModuleNotFoundError: No module named 'paho'"
# 原因幾乎都是：套件裝進系統 Python（或 ~/.local），
#               但 systemd 服務是用 venv 的 python3 執行。
# ============================================================
set -uo pipefail

APP_DIR="${1:-$(cd "$(dirname "$0")" && pwd)}"
VENV_PY="${APP_DIR}/venv/bin/python3"
UNIT="ble-beacon-scanner"

echo "══ 1. 服務實際用哪個 Python 執行？════════════════"
if systemctl cat "${UNIT}" >/dev/null 2>&1; then
    systemctl cat "${UNIT}" | grep -E "^ExecStart" || echo "   ⚠️ unit 沒有 ExecStart"
else
    echo "   ⚠️ 找不到 unit ${UNIT}（尚未 sudo setup-system.sh？）"
fi
echo "   unit 檔位置：$(systemctl show -p FragmentPath --value "${UNIT}" 2>/dev/null || echo '?')"

echo
echo "══ 2. venv 存在嗎？══════════════════════════════"
# 注意：某些系統的 venv/bin/python3 是 symlink，-x 可能誤判；
#       改用「能執行且印得出路徑」來判斷。
venv_ok=0
if [ -f "${VENV_PY}" ] && "${VENV_PY}" -c 'import sys' >/dev/null 2>&1; then
    venv_ok=1
    echo "   ✔ ${VENV_PY}"
    "${VENV_PY}" -V
else
    echo "   ✘ ${VENV_PY} 不存在或無法執行 → 這就是原因"
    echo "     修正：cd ${APP_DIR} && python3 -m venv venv && venv/bin/pip install -r requirements.txt"
fi

echo
echo "══ 3. 各 Python 是否 import 得到 paho / bleak？═"
check() {
    local label="$1"; shift
    local py="$1"; shift
    if ! command -v "${py}" >/dev/null 2>&1 && [ ! -x "${py}" ]; then
        printf '   %-34s (不存在)\n' "${label}"
        return
    fi
    local out
    out="$("${py}" - <<'PY' 2>&1
import importlib.metadata as md
parts = []
for mod, dist in (("paho.mqtt.client", "paho-mqtt"), ("bleak", "bleak")):
    try:
        __import__(mod)
        try:
            parts.append(f"{dist} {md.version(dist)}")
        except Exception:
            parts.append(f"{dist} (unknown ver)")
    except Exception as e:
        parts.append(f"{dist} ✘ {type(e).__name__}")
print(" / ".join(parts))
PY
)"
    printf '   %-34s %s\n' "${label}" "${out}"
}
check "venv ($(basename "${APP_DIR}")/venv)" "${VENV_PY}"
check "系統 python3" "python3"
[ -f "${HOME}/.local/bin/python3" ] && check "~/.local/bin/python3" "${HOME}/.local/bin/python3"

echo
echo "══ 4. ~/.local 有沒有裝 paho？（常見錯誤來源）═"
if [ -d "${HOME}/.local/lib" ]; then
    found="$(find "${HOME}/.local/lib" -maxdepth 4 -name 'paho' -type d 2>/dev/null | head -3)"
    if [ -n "${found}" ]; then
        echo "   找到（但 venv 看不到，因為 venv 預設 --without-system-site-packages）："
        echo "${found}" | sed 's/^/     /'
    else
        echo "   ~/.local/lib 沒有 paho"
    fi
else
    echo "   沒有 ~/.local/lib"
fi

echo
echo "══ 5. venv 的 site-packages 裡到底有什麼 ═══════"
if [ "${venv_ok}" = "1" ]; then
    SP="$("${VENV_PY}" -c 'import site;print(site.getsitepackages()[0])' 2>/dev/null)"
    echo "   site-packages: ${SP}"
    ls "${SP}" 2>/dev/null | grep -i -E "paho|bleak|dbus" | sed 's/^/     /' || echo "     (沒有 paho/bleak/dbus)"
    echo
    echo "   pip list（前 15 筆）："
    "${VENV_PY}" -m pip list 2>/dev/null | head -15 | sed 's/^/     /' || echo "     pip 不可用"
fi

echo
echo "══ 6. 實際跑一次 code.py 的 import ══════════════"
if [ "${venv_ok}" = "1" ]; then
    ( cd "${APP_DIR}" && "${VENV_PY}" -c 'import paho.mqtt.client as p; import bleak; print("   ✔ import 成功")' ) 2>&1 | tail -5 | sed 's/^/   /'
fi

echo
echo "══ 7. 服務最近的錯誤 ═════════════════════════════"
journalctl -u "${UNIT}" -n 20 --no-pager 2>/dev/null | tail -20 | sed 's/^/   /' || echo "   (需要 sudo 或有 journal 權限)"

echo
echo "══ 結論 ═════════════════════════════════════════"
if [ "${venv_ok}" = "1" ] && "${VENV_PY}" -c 'import paho.mqtt.client' 2>/dev/null; then
    echo "   venv 裡有 paho。若服務仍報 No module named paho，"
    echo "   請確認 unit 的 ExecStart 指向的正是 ${VENV_PY}。"
else
    echo "   venv 裡沒有 paho → 在樹莓派上執行："
    echo "     cd ${APP_DIR}"
    echo "     venv/bin/pip install -r requirements.txt"
    echo "     sudo systemctl restart ${UNIT}"
fi
