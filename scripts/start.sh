#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .env ]]; then set -a; source .env; set +a; fi
if [[ -f config/domains.local.env ]]; then
    while IFS= read -r entry || [[ -n $entry ]]; do
        case "$entry" in ''|'#'*) continue ;; esac
        if [[ ! $entry =~ ^(DIRECT_DOMAINS|MAC_DNS_DOMAINS)=([a-zA-Z0-9.,-]*)$ ]]; then
            echo 'Invalid config/domains.local.env entry' >&2; exit 1
        fi
        export "$entry"
    done < config/domains.local.env
fi
: "${VPS_IP:?set VPS_IP in .env}"
if [[ -n ${MAC_DNS_DOMAINS:-} ]]; then
    bash scripts/install-mac-resolver.sh "$MAC_DNS_DOMAINS"
fi
for file in wg.key server.pub; do
    [[ -s config/tunnel/$file ]] || { echo "缺少 config/tunnel/$file；请先按 README 配对 VPS。旧容器未改动。"; exit 1; }
done
name=${CONTAINER_NAME:-claude-in-docker}
image=${IMAGE_NAME:-claude-in-docker-wg}
podman build --build-arg "BASE_IMAGE=${BASE_IMAGE:-ubuntu:24.04}" -f Containerfile -t "$image" .
args=(--privileged --http-proxy=false --network bridge --hostname claude-us
    -v "$PWD/config/tunnel:/etc/cage-peer:ro" -e "VPS_IP=${VPS_IP:?set VPS_IP in .env}"
    -e "WG_PORT=${WG_PORT:-51820}" -e "EXPECTED_EGRESS_IP=${EXPECTED_EGRESS_IP:-${VPS_IP:?set VPS_IP in .env}}"
    -e "MAC_DNS_DOMAINS=${MAC_DNS_DOMAINS:-}" -e "DIRECT_DOMAINS=${DIRECT_DOMAINS:-}" -e "INTERNAL_DNS_SERVER=${INTERNAL_DNS_SERVER:-}" -e "TZ=${TZ:-America/New_York}")
if ! podman inspect -f '{{.ImageName}}' "$name" 2>/dev/null | grep -Fq "$image"; then
    podman run --rm "${args[@]}" -e ENABLE_GUI=false -e ENABLE_DIND=false "$image" /bin/true
fi
if podman container exists "$name"; then
    echo "现有容器将保留为备份；待新容器就绪再使用。"
    backup="$name-backup-$(date +%s)"
    podman stop "$name"
    podman rename "$name" "$backup"
    echo "备份名称：$backup"
fi
mkdir -p data
podman run -d --restart unless-stopped --name "$name" "${args[@]}" -v "$PWD/data:/home/claude:rw" -v claude-docker-data:/var/lib/docker \
    -p "127.0.0.1:${NOVNC_PORT:-6080}:6080" -e "ENABLE_GUI=${ENABLE_GUI:-true}" -e "ENABLE_DIND=${ENABLE_DIND:-true}" \
    -e "AUTO_CHROME=${AUTO_CHROME:-true}" -e "CHROME_URL=${CHROME_URL:-about:blank}" -e "VNC_PASSWORD=${VNC_PASSWORD:-}" "$image"
for attempt in {1..100}; do
    if podman exec "$name" test -e /run/cage-ready 2>/dev/null; then echo '出口自检通过'; exit 0; fi
    [[ $(podman inspect -f '{{.State.Running}}' "$name") == true ]] || break
    sleep 1
done
podman logs --tail 12 "$name"; exit 1
