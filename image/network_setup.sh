#!/bin/bash

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
  echo "KPSNET: no virtio_net interface found"
  exit 1
fi

echo "KPSNET: using interface $iface"

mkdir -p /etc/systemd/network
cat <<'EOF' > /etc/systemd/network/00-static-tap.network
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
echo "KPSNET: networkd restart rc=$?"

sleep 1

ip -br link show dev "$iface" |
  while read -r line; do echo "KPSNET: link: $line"; done
ip -br -4 address show dev "$iface" |
  while read -r line; do echo "KPSNET: addr: $line"; done

ip -4 address show dev "$iface" | grep -q "192\.168\.100\.3/24"
