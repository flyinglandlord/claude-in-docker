#!/bin/bash
# ============================================================
# start-gui — 启动容器内 GUI 桌面环境
# 链路: 浏览器 → noVNC(:6080) → websockify → x11vnc → Xvfb → Chromium/终端
# ============================================================
set -euo pipefail

# -----------------------------------------------------------
# 配置（可通过环境变量覆盖）
# -----------------------------------------------------------
DISPLAY_NUM="${DISPLAY_NUM:-99}"
RESOLUTION="${RESOLUTION:-1920x1080x24}"
VNC_PORT="${VNC_PORT:-5900}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
VNC_PASSWORD="${VNC_PASSWORD:-}"  # 空则无密码
WM="${WM:-openbox}"               # 窗口管理器: openbox / none

export DISPLAY=":${DISPLAY_NUM}"

mkdir -p /var/log/gui

# ============================================================
# start-firefox — 启动 Firefox 浏览器（必须在调用前定义）
# ============================================================
start-firefox() {
    FIREFOX_PROFILE="/home/claude/.mozilla/firefox/claude"
    mkdir -p "${FIREFOX_PROFILE}"

    # 如果 profile 不存在，创建默认配置
    if [ ! -f "${FIREFOX_PROFILE}/prefs.js" ]; then
        mkdir -p "${FIREFOX_PROFILE}"
        cat > "${FIREFOX_PROFILE}/user.js" << 'PREFS_EOF'
user_pref("browser.startup.homepage", "https://claude.ai");
user_pref("browser.newtabpage.enabled", false);
user_pref("browser.tabs.firefox-view", false);
user_pref("dom.disable_open_during_load", false);
user_pref("browser.download.panel.shown", false);
user_pref("geo.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("app.normandy.first_launch", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("browser.uitour.enabled", false);
PREFS_EOF
    fi

    TARGET_URL="${CHROME_URL:-about:blank}"
    chown -R claude:claude "${FIREFOX_PROFILE}"

    runuser -u claude -- env HOME=/home/claude firefox \
        --no-remote \
        --profile "${FIREFOX_PROFILE}" \
        --new-window "${TARGET_URL}" \
        --width=1920 --height=1080 \
        &>/var/log/gui/firefox.log &

    sleep 2
    echo "[GUI] Firefox 已启动 → ${TARGET_URL}"
}

# ============================================================
# 主流程
# ============================================================
echo "[GUI] 启动虚拟显示环境..."
echo "[GUI]  分辨率: ${RESOLUTION}"
echo "[GUI]  VNC 端口: ${VNC_PORT}"
echo "[GUI]  noVNC 端口: ${NOVNC_PORT}"

# --- 1. 清理残留进程 ---
pkill -f "Xvfb :${DISPLAY_NUM}" 2>/dev/null || true
pkill -f "x11vnc.*:${DISPLAY_NUM}" 2>/dev/null || true
sleep 0.5

# --- 2. 启动 dbus（容器环境可选，加超时防止卡住）---
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    eval "$(timeout 3 dbus-launch --sh-syntax --exit-with-session 2>/dev/null)" || true
fi

# --- 3. 启动 Xvfb（虚拟帧缓冲 = 虚拟显示器）---
echo "[GUI] 启动 Xvfb :${DISPLAY_NUM} ..."
Xvfb ":${DISPLAY_NUM}" \
    -screen 0 "${RESOLUTION}" \
    -ac +extension GLX +render -noreset \
    -nolisten tcp \
    &>/var/log/gui/xvfb.log &
XVFB_PID=$!

for i in $(seq 1 20); do
    if timeout 2 xdpyinfo -display ":${DISPLAY_NUM}" &>/dev/null; then
        echo "[GUI] Xvfb 就绪 (PID: ${XVFB_PID})"
        break
    fi
    sleep 0.3
done

# --- 4. 设置背景色 ---
xsetroot -solid "#2b2b2b" 2>/dev/null || true

# --- 5. 启动窗口管理器 ---
if [ "${WM}" = "openbox" ]; then
    echo "[GUI] 启动 Openbox ..."
    openbox-session &>/var/log/gui/openbox.log &
    sleep 0.5
fi

# --- 6. 启动 x11vnc ---
echo "[GUI] 启动 x11vnc ..."

# 处理 VNC 密码
mkdir -p /home/claude/.vnc
X11VNC_AUTH_ARGS=()
if [ -n "${VNC_PASSWORD}" ]; then
    x11vnc -storepasswd "${VNC_PASSWORD}" /home/claude/.vnc/passwd 2>/dev/null
    X11VNC_AUTH_ARGS+=(-rfbauth /home/claude/.vnc/passwd)
    echo "[GUI] VNC 密码: 已设置"
else
    X11VNC_AUTH_ARGS+=(-nopw)
    echo "[GUI] VNC 密码: 无"
fi

x11vnc \
    -display ":${DISPLAY_NUM}" \
    -forever \
    -shared \
    -rfbport "${VNC_PORT}" \
    "${X11VNC_AUTH_ARGS[@]}" \
    -o /var/log/gui/x11vnc.log \
    -noxrecord -noxfixes -noxdamage -cursor \
    &>/var/log/gui/x11vnc.log &
X11VNC_PID=$!
echo "[GUI] x11vnc 就绪 (PID: ${X11VNC_PID}, 端口: ${VNC_PORT})"

# --- 7. 启动 noVNC + websockify ---
echo "[GUI] 启动 noVNC (Web: http://localhost:${NOVNC_PORT}/vnc.html) ..."
websockify --web /usr/share/novnc "${NOVNC_PORT}" "localhost:${VNC_PORT}" \
    &>/var/log/gui/novnc.log &
NOVNC_PID=$!
echo "[GUI] noVNC 就绪 (PID: ${NOVNC_PID})"

# --- 8. 启动终端 ---
echo "[GUI] 启动终端 ..."
runuser -u claude -- env HOME=/home/claude xterm -geometry 160x48+10+10 -bg '#1e1e1e' -fg '#d4d4d4' \
    -sb -sl 5000 \
    &>/var/log/gui/xterm.log &
sleep 0.5

# --- 9. 可选：自动启动 Firefox ---
if [ "${AUTO_CHROME:-true}" = "true" ]; then
    echo "[GUI] 启动 Firefox ..."
    start-firefox
fi

# --- 10. 显示访问信息 ---
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  ✅ GUI 桌面环境已启动                            ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║                                                  ║"
printf "║  Web 桌面:  http://<宿主机IP>:%-5s             ║\n" "${NOVNC_PORT}/vnc.html"
printf "║  VNC 直连:  <宿主机IP>:%-5s                    ║\n" "${VNC_PORT}"
echo "║                                                  ║"
echo "║  已启动:                                         ║"
echo "║    • Xvfb (虚拟显示器)                           ║"
echo "║    • Openbox (窗口管理器)                        ║"
echo "║    • x11vnc (VNC 服务器)                         ║"
echo "║    • noVNC (Web 客户端)                          ║"
echo "║    • xterm (终端)                                ║"
if [ "${AUTO_CHROME:-true}" = "true" ]; then
echo "║    • Firefox → https://claude.ai                ║"
fi
echo "║                                                  ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# --- 11. 保持前台运行（等待 Xvfb 退出）---
wait ${XVFB_PID}
