# claude-in-docker

在 Podman 或 Docker 中启动带 Firefox、noVNC 和 Claude Code 的 Linux 桌面。公网 IPv4 默认走自备的 WireGuard 出口；回环和 `10.0.0.0/8` 直连。可另行指定直连域名；默认没有域名例外。公网 IPv6 不提供出口。

## 启动

1. 准备可工作的 WireGuard 服务端，开启 IPv4 转发并为客户端做出站 NAT。模板使用一个示例隧道网段：客户端 `10.77.0.2/32`，服务端 `10.77.0.1/30`。两端地址需一致，且不能与已有网络冲突。使用内核 WireGuard 不需要仓库内的 systemd 示例；该示例仅适用于已安装用户态 WireGuard 的 Linux VPS，使用前须核对网卡名、工具路径和防火墙。
2. 复制 `.env.example` 为 `.env`，填写自己的 `VPS_IP`；若实际出口地址不同，另填 `EXPECTED_EGRESS_IP`。如需域名分流，把 `config/domains.example.env` 复制为 `config/domains.local.env`，只在后者填写实际后缀。该文件不会进入 Git 或镜像；Podman 和 Compose（2.24+）在创建容器时读取，修改后需重新创建容器。`DIRECT_DOMAINS` 形如 `example.org,example.net`，不要带空格。默认通过隧道解析；白名单统一使用 Mac 系统 DNS，不设公共 DNS 回退。
3. 在本机创建 `config/tunnel/`（权限 700），仅放客户端私钥 `wg.key`（权限 600）与服务端公钥 `server.pub`。仅将客户端**公钥**登记到 VPS。不要在这个挂载目录放服务端私钥、SSH 凭据或其他秘密。
4. 在已有运行中 Podman 虚拟机的 Mac，或支持 WireGuard 的 Linux 上运行 `make start`。Docker 用户可运行 `docker compose up --build -d`。不要让两个实例同时使用同一 WireGuard 身份。
5. 打开 [本机桌面](http://127.0.0.1:6080/vnc.html)，或运行 `make shell` 以普通用户进入 Podman 容器。本机的 `data/` 对应容器的 `/home/claude`，删除容器不会删除这里的文件。Claude Code 需自行登录。

## 验证和限制

唯一的域名白名单是 `DIRECT_DOMAINS`：名单内（含子域）用 Mac 系统 DNS 解析 IPv4 并直连，查不到或 Mac 服务不可用就失败；其他域名的系统 DNS 查询和公网流量均经 WireGuard。原有 10/8 和回环的 IP 直连例外保留。旧配置中的 MAC_DNS_DOMAINS 请合并至 DIRECT_DOMAINS 并删除旧字段。

Mac + Podman 的 `make start` 会安装仅监听回环地址的解析服务。Compose 不会安装该服务，非空白名单也需要可达的 Mac 解析服务与 host.containers.internal；普通 Linux 部署请留空。不支持仅有 IPv6 的服务。

`make verify` 复查路由、出口和 Firefox；`make logs` 查看启动日志。启动自检要求两个公网服务返回预期地址、Cloudflare 将出口标为 US，且 Firefox 的 WebRTC 和定位 API 均不可用。测试失败时不启动桌面。定位不可用不等于身处某一地点；直连站点能看到直连出口。

容器默认以特权模式运行以管理网络及嵌套 Docker，不是运行不可信代码的隔离边界。noVNC 只绑定本机回环；不要在未加认证的情况下对外开放。配置文件、隧道密钥和持久化 home 均不随仓库发布，也不进入镜像构建上下文。
