#!/usr/bin/env bash

# 1) try to use the dedicated "col0" interface if present
if ip link show col0 &>/dev/null && ip -4 addr show dev col0 | grep -q 'inet '; then
  IFACE=col0
  echo "✔️  Found dedicated col0 interface"
else
  # fallback to whatever interface carries your default route
  IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
  echo "⚠️  col0 not found, falling back to default-route iface: $IFACE"
fi

# grab the IPv4 address from the chosen interface
NODE_IP=$(ip -4 addr show dev "$IFACE" \
  | awk '/inet /{print $2}' | cut -d/ -f1)
ip route add default via NODE_IP dev col0 2>/dev/null

echo "▶️  Configuring k3s to use $IFACE → $NODE_IP"

# 2) write out /etc/rancher/k3s/config.yaml
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml > /dev/null <<EOF
# Bind API on all interfaces
bind-address: 0.0.0.0

# Use chosen IP for control-plane & pods
node-ip: $NODE_IP
advertise-address: $NODE_IP

# cert SANs
tls-san:
  - 127.0.0.1
  - $NODE_IP

# disable bundled Traefik
disable:
  - traefik

# make kubeconfig world-readable
write-kubeconfig-mode: 644

# required kubelet flags under unprivileged userns
kubelet-arg:
  - "eviction-hard=imagefs.available<1%,nodefs.available<1%"
  - "feature-gates=KubeletInUserNamespace=true"

# force Flannel onto the same interface
flannel-iface: $IFACE
EOF

# 3) blow away any old state
echo "🧹 Cleaning old k3s state…"
sudo systemctl stop k3s
sudo rm -rf /var/lib/rancher/k3s /etc/rancher/k3s/k3s.yaml

# 4) restart k3s
echo "🔄 Restarting k3s…"
sudo systemctl daemon-reload
sudo systemctl enable k3s
sudo systemctl start k3s

echo "⏳ Waiting a few seconds for k3s to come up…"
sleep 5

# 5) tail the journal so you can watch it boot
kubectl get nodes -A -o wide