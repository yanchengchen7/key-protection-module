#!/bin/bash
serial_log() {
  printf "KPSNET: %s\n" "$*"
  printf "KPSNET: %s\n" "$*" > /dev/ttyS0 2>/dev/null || true
}

iface=""
for path in /sys/class/net/*; do
  name="${path##*/}"
  [[ "$name" == "lo" ]] && continue
  driver="$(basename "$(readlink -f "$path/device/driver" 2>/dev/null)")"
  if [[ "$driver" == "virtio_net" ]]; then
    iface="$name"
    break
  fi
done

if [[ -z "$iface" ]]; then
  serial_log "no virtio_net interface found"
  exit 1
fi

serial_log "using interface $iface"

mkdir -p /etc/systemd/network
cat > /etc/systemd/network/00-static-tap.network <<EOF
[Match]
Driver=virtio_net

[Network]
Address=192.168.100.3/24
DHCP=no
LinkLocalAddressing=no

[Route]
Gateway=192.168.100.1
EOF

systemctl restart systemd-networkd
serial_log "networkd restart rc=$?"

sleep 1
if ! ip -4 address show dev "$iface" | grep -q "192\.168\.100\.3/24"; then
  serial_log "networkd did not assign .3; applying fallback"
  ip link set "$iface" up
  ip address replace 192.168.100.3/24 dev "$iface"
  ip route replace default via 192.168.100.1 dev "$iface"
fi

ip -br link show dev "$iface" |
  while read -r line; do serial_log "link: $line"; done
ip -br -4 address show dev "$iface" |
  while read -r line; do serial_log "addr: $line"; done

ip -4 address show dev "$iface" | grep -q "192\.168\.100\.3/24"
