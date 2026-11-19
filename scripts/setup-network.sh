#!/bin/bash
set -euo pipefail

endpoint=${VPS_IP:?set VPS_IP in .env}
port=${WG_PORT:-51820}
python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1]); assert sys.argv[2].isdecimal() and 0 < int(sys.argv[2]) <= 65535' "$endpoint" "$port"
read -r gateway uplink < <(ip -4 route show default | awk 'NR==1 {print $3, $5}')
[[ $uplink =~ ^[a-zA-Z0-9_.-]+$ ]]

nft -f - <<EOF
table inet cage {
  map destinations { type ipv4_addr : ipv4_addr; }
  chain named { ip daddr 198.18.0.0/15 ct mark set 0x52 dnat ip to ip daddr map @destinations; }
  chain localnat { type nat hook output priority -110; policy accept; jump named; }
  chain prenat { type nat hook prerouting priority -110; policy accept; iifname != "$uplink" jump named; }
  chain localmark { type route hook output priority -90; policy accept; ct direction original ct mark 0x52 meta mark set 0x52; }
  chain premark { type filter hook prerouting priority -90; policy accept; ct direction original ct mark 0x52 meta mark set 0x52; }
  chain guarded {
    meta nfproto ipv6 drop
    ip daddr 198.18.0.0/15 drop
    oifname "wg-cage" accept
    oifname "$uplink" ip daddr 10.0.0.0/8 accept
    oifname "$uplink" ct mark 0x52 accept
    drop
  }
  chain out { type filter hook output priority -10; policy drop;
    oifname "lo" accept
    ct direction reply ct state established,related accept
    oifname "$uplink" ip daddr $endpoint udp dport $port meta mark 0x51 accept
    jump guarded
  }
  chain forward { type filter hook forward priority -10; policy drop;
    ct direction reply ct state established,related accept
    jump guarded
  }
  chain postnat { type nat hook postrouting priority 95; policy accept; oifname "wg-cage" masquerade; oifname "$uplink" ct mark 0x52 masquerade; }
}
EOF

ip link add wg-cage type wireguard
wg set wg-cage private-key /etc/cage-peer/wg.key fwmark 0x51 peer "$(cat /etc/cage-peer/server.pub)" endpoint "$endpoint:$port" allowed-ips 0.0.0.0/0 persistent-keepalive 25
ip addr add 10.77.0.2/32 dev wg-cage
ip link set wg-cage mtu 1380 up
ip route add default via "$gateway" dev "$uplink" table 151
ip rule add pref 91 fwmark 0x51 lookup 151
ip rule add pref 92 fwmark 0x52 lookup 151
ip rule add pref 93 to 10.0.0.0/8 lookup 151
ip rule add pref 94 lookup main suppress_prefixlength 0
ip route add default dev wg-cage table 152
ip rule add pref 95 lookup 152
ip rule add pref 96 prohibit
if [[ -n ${MAC_DNS_DOMAINS:-} ]]; then
    bridge=$(getent -s files ahostsv4 host.containers.internal | awk 'NR==1 {print $1}')
    python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$bridge"
    printf '%s\n' "$bridge" > /run/cage-mac-ip
    ip rule add pref 90 to "$bridge/32" ipproto tcp dport 38543 lookup 151
    nft insert rule inet cage out oifname "\"$uplink\"" ip daddr "$bridge" tcp dport 38543 meta skuid 0 accept
fi
