# ============================================================
# claude-in-docker — 基于 Ubuntu 24.04 的隔离容器环境
# ============================================================
# 构建: podman build -t claude-in-docker .
#
# 网络链路:
#   容器流量 → 策略路由 → WireGuard → VPS → 外网
# ============================================================

ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

LABEL maintainer="claude-in-docker"
LABEL description="Isolated container: US locale, all egress via WireGuard with whitelist bypass"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/New_York
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV DISPLAY=:99
ENV BROWSER=firefox

# -----------------------------------------------------------
# 1. 基础系统 — 美国环境 + 网络工具 + DinD
# -----------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    tzdata \
    locales \
    curl wget net-tools iproute2 iputils-ping dnsutils \
    iptables iptables-persistent \
    ca-certificates \
    procps vim-tiny less \
    dnsmasq \
    xz-utils \
    mtr traceroute \
    gnupg lsb-release \
    npm \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------
# 1a2. 安装 Claude Code CLI
# -----------------------------------------------------------
RUN npm install -g @anthropic-ai/claude-code

# -----------------------------------------------------------
# 1b. GUI 支持 — 虚拟显示 + 远程桌面 + 浏览器
# -----------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb \
    openbox \
    x11vnc \
    xterm \
    novnc \
    websockify \
    python3-websockify \
    dbus-x11 \
    x11-utils \
    libglib2.0-0t64 \
    libnss3 \
    libatk-bridge2.0-0t64 \
    libdrm2 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    libgbm1 \
    libasound2t64 \
    libpango-1.0-0 \
    libcairo2 \
    libatspi2.0-0t64 \
    libxshmfence1 \
    libgtk-3-0t64 \
    fonts-liberation \
    fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------
# 1c. Firefox (ARM64 兼容，Chrome .deb 只有 amd64)
# -----------------------------------------------------------
RUN case "$(dpkg --print-architecture)" in arm64) platform=linux64-aarch64;; amd64) platform=linux64;; *) exit 1;; esac \
    && FIREFOX_URL="https://download.mozilla.org/?product=firefox-latest&os=${platform}&lang=en-US" \
    && wget -q -O /tmp/firefox.tar "${FIREFOX_URL}" \
    && tar -xf /tmp/firefox.tar -C /opt/ \
    && rm /tmp/firefox.tar \
    && ln -sf /opt/firefox/firefox /usr/local/bin/firefox \
    && ln -sf /opt/firefox/firefox /usr/bin/x-www-browser \
    && firefox --version

# -----------------------------------------------------------
# 2. 美国时区和语言
# -----------------------------------------------------------
RUN ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime && echo ${TZ} > /etc/timezone \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen en_US.UTF-8 \
    && update-locale LANG=en_US.UTF-8

# -----------------------------------------------------------
# 4. Docker-in-Docker (使用阿里云镜像源)
# -----------------------------------------------------------
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------
# 5. 用户
# -----------------------------------------------------------
RUN groupadd -g 1001 claude \
    && useradd -m -u 1001 -g claude -s /bin/bash claude \
    && usermod -aG docker claude

# -----------------------------------------------------------
# 6. 目录
# -----------------------------------------------------------
RUN mkdir -p /home/claude/.claude \
    && mkdir -p /home/claude/.vnc \
    && mkdir -p /tmp/.X11-unix \
    && chmod 1777 /tmp/.X11-unix \
    && chown -R claude:claude /home/claude

# noVNC Web 客户端首页
RUN ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html || true

# -----------------------------------------------------------
# 7. 配置文件
# -----------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends wireguard-tools nftables python3-dnspython && rm -rf /var/lib/apt/lists/*
COPY config/cage-dns.conf /etc/cage-dns.conf
COPY config/firefox-policies.json /opt/firefox/distribution/policies.json
COPY scripts/named-direct.py /usr/local/bin/named-direct
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/setup-network.sh /usr/local/bin/setup-network
COPY scripts/start-gui.sh /usr/local/bin/start-gui
COPY scripts/claude-check /usr/local/bin/claude-check
COPY scripts/browser-check.py /usr/local/bin/browser-check.py

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && chmod +x /usr/local/bin/named-direct \
    && chmod +x /usr/local/bin/setup-network \
    && ln -s claude-check /usr/local/bin/verify-network \
    && chmod +x /usr/local/bin/start-gui \
    && chmod +x /usr/local/bin/claude-check

# -----------------------------------------------------------
# 8. 健康检查
# -----------------------------------------------------------
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD test -e /run/cage-ready && wg show wg-cage >/dev/null || exit 1

# -----------------------------------------------------------
# 9. 入口
# -----------------------------------------------------------
WORKDIR /home/claude
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
