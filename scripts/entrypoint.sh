#!/bin/bash
set -euo pipefail
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
if [[ -n ${MAC_DNS_DOMAINS:-} ]]; then echo 'Move all local suffixes to DIRECT_DOMAINS' >&2; exit 1; fi
rm -f /run/cage-ready
setup-network
printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf
/usr/local/bin/named-direct &
named_pid=$!
cp /etc/cage-dns.conf /run/cage-dns.conf
IFS=',' read -ra suffixes <<< "${DIRECT_DOMAINS:-}"
for suffix in "${suffixes[@]}"; do
    [[ $suffix =~ ^([A-Za-z0-9-]+\.)+[A-Za-z0-9-]+$ ]] || { echo 'Invalid DIRECT_DOMAINS'; exit 1; }
    printf 'server=/%s/127.0.0.1#5354\n' "$suffix" >> /run/cage-dns.conf
done
dnsmasq --keep-in-foreground --conf-file=/run/cage-dns.conf &
dns_pid=$!
for attempt in {1..3}; do
    if claude-check; then touch /run/cage-ready; break; fi
    sleep 2
done
[[ -f /run/cage-ready ]] || { echo '出口未通过，拒绝启动桌面和 Docker。' >&2; exit 1; }
pids=("$named_pid" "$dns_pid")
if [[ ${ENABLE_DIND:-true} == true ]]; then
    dockerd --host=unix:///var/run/docker.sock --storage-driver=vfs --dns=10.77.0.2 &
    pids+=("$!")
fi
if [[ ${ENABLE_GUI:-true} == true ]]; then
    start-gui &
    pids+=("$!")
fi
if [[ ${1:-/bin/bash} != /bin/bash ]]; then exec "$@"; fi
wait -n "${pids[@]}" || :
exit 1
