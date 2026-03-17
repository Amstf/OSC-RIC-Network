#!/bin/bash

# setup_ric_container.sh — Setup and build OSC RIC + ORANSlice xApps inside a container

# ========== Colors ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m' # No Color

function error() { echo -e "${RED}❌ ERROR: $1${NC}"; }
function warn()  { echo -e "${BOLD}🚩 $1${NC}"; }
function success(){ echo -e "${GREEN}✅ $1${NC}"; }

IMAGE_NAME="$1"
ALIAS="${2:-${IMAGE_NAME%.tar.gz}}"
CONTAINER="${3:-${ALIAS}-cont}"
REMOTE_USER="${4:-alimustapha}"
SSH_KEY_PATH="$5"

if [ -z "$IMAGE_NAME" ]; then
  echo -e "${RED}Usage: $0 <image-name.tar.gz> [alias] [container-name] [remote-user] [ssh-key-path]${NC}"
  exit 1
fi

# Step 0 (host): kernel modules & sysctls needed for k3s/flannel/CNI
echo "🧩 Preparing host kernel features for k3s networking..."
sudo modprobe br_netfilter || true
sudo modprobe vxlan || true
sudo sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null
sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
sudo sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null

echo "🤩 Starting setup for:"
echo "  📦 Image:      $IMAGE_NAME"
echo "  🏷️  Alias:      $ALIAS"
echo "  🐧 Container:  $CONTAINER"
echo "  🌐 Remote User: $REMOTE_USER"
echo "  🔐 SSH Key:    ${SSH_KEY_PATH:-None provided}"
echo ""

# Step 1
echo "▶️  [1/7] Running download_image.sh..."
./download_image.sh "$IMAGE_NAME" "$REMOTE_USER" || { error "Failed to download image"; exit 1; }

# Step 2
echo "▶️  [2/7] Running import_and_launch.sh..."
./import_and_launch.sh -f "./images/$IMAGE_NAME" -a "$ALIAS" -c "$CONTAINER" || { error "Failed to import/launch container"; exit 1; }

# Step 0: Ensure /dev/kmsg (and make container k3s-friendly)
echo "🛠️  Enabling /dev/kmsg passthrough for K3s compatibility..."
# Also switch to privileged + nesting + unconfined AppArmor for k3s/Docker friendliness
echo "🔧 Configuring LXC container features (privileged, nesting, unconfined)…"
lxc stop "$CONTAINER"
lxc config set "$CONTAINER" security.nesting true
lxc config set "$CONTAINER" security.privileged true
lxc config set "$CONTAINER" raw.lxc "lxc.apparmor.profile=unconfined"
lxc config device add "$CONTAINER" kmsg unix-char source=/dev/kmsg path=/dev/kmsg 2>/dev/null || true
lxc config device add "$CONTAINER" fuse unix-char source=/dev/fuse path=/dev/fuse 2>/dev/null || true
lxc start "$CONTAINER"
sleep 5

# Step 3
echo "▶️  [3/7] Running set_lxc_network.sh..."
./set_lxc_network.sh "$CONTAINER" || { error "Failed to fix container network"; exit 1; }

# Step 4: DNS Fix
echo "📡 Forcing static DNS inside container..."
lxc exec "$CONTAINER" -- bash -c '
  systemctl stop systemd-resolved || true
  systemctl disable systemd-resolved || true
  rm -f /etc/resolv.conf
  echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
  chmod 644 /etc/resolv.conf
'

# Persist k3s-related sysctls inside the container
echo "🛡️  Setting k3s-required sysctls inside the container…"
lxc exec "$CONTAINER" -- bash -c '
  cat >/etc/sysctl.d/99-k3s.conf <<EOF
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
  sysctl --system || true
'

# Step 5: SSH Keys
if [ -n "$SSH_KEY_PATH" ]; then
  echo "🔑 Pushing SSH key to container..."
  BASENAME=$(basename "$SSH_KEY_PATH")
  lxc exec "$CONTAINER" -- mkdir -p /root/.ssh
  lxc file push "$SSH_KEY_PATH"        "$CONTAINER"/root/.ssh/id_rsa
  lxc file push "$SSH_KEY_PATH.pub"    "$CONTAINER"/root/.ssh/id_rsa.pub
  lxc exec "$CONTAINER" -- chmod 600 /root/.ssh/id_rsa
  lxc exec "$CONTAINER" -- chmod 644 /root/.ssh/id_rsa.pub
  lxc exec "$CONTAINER" -- bash -c "ssh-keyscan github.com >> /root/.ssh/known_hosts"
  lxc exec "$CONTAINER" -- ssh -i /root/.ssh/id_rsa -T git@github.com || true
else
  warn "No SSH key path provided. Skipping SSH key setup."
fi

 # Step 6 — Install Docker & k3s (online, for baking your golden image) —
echo "▶️  [6/7] Installing Docker & k3s with VFS support (online)…"

# Clone support repo (idempotent)
lxc exec "$CONTAINER" -- bash -lc 'set -e; cd /root && git clone git@github.com:Amstf/OAI-RIC-Network.git || true' \
  || { error "Step 6.0: cloning OAI-RIC-Network failed"; exit 1; }

# 1) Base system + Python
lxc exec "$CONTAINER" -- bash -lc '
  set -e
  apt update && apt upgrade -y
  apt install -y git curl vim net-tools iproute2 conntrack socat ebtables ipset \
                 apt-transport-https ca-certificates gnupg software-properties-common python3-pip
  pip3 install --no-input requests
' || { error "Step 6.1: base packages install failed"; exit 1; }

# 2) Docker + VFS (avoid OverlayFS)
lxc exec "$CONTAINER" -- bash -lc '
  set -e
  mkdir -p /etc/docker
  printf "{ \"storage-driver\": \"vfs\" }\n" > /etc/docker/daemon.json
  rm -rf /var/lib/docker
  systemctl daemon-reexec
  curl -fsSL https://get.docker.com | sh
  usermod -aG docker root
' || { error "Step 6.2: Docker(VFS) setup failed"; exit 1; }

# 3) k3s installer → systemd service, using Docker runtime
# ! NOTE: You validated: curl -sfL https://get.k3s.io | sh -s - --flannel-backend=none --disable-network-policy
# Keep the current flags; add your CNI later as you prefer.
lxc exec "$CONTAINER" -- bash -lc '
  set -e
  export INSTALL_K3S_EXEC="--docker --disable traefik --write-kubeconfig-mode 644"
  curl -sfL https://get.k3s.io | sh -
' || { error "Step 6.3: k3s install failed"; exit 1; }

# make kubectl work for your user
lxc exec "$CONTAINER" -- bash -lc '
  set -e
  echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> /root/.bashrc
' || { error "Step 6.4: configuring KUBECONFIG in .bashrc failed"; exit 1; }

# 4) Helm & chartmuseum plugin
lxc exec "$CONTAINER" -- bash -lc '
  set -e
  curl -fsSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
' || { error "Step 6.5: Helm install failed"; exit 1; }

lxc exec "$CONTAINER" -- bash -lc '
  set -e
  helm plugin install https://github.com/chartmuseum/helm-push.git || true
' || { error "Step 6.6: Helm chartmuseum plugin failed"; exit 1; }
# Quick health snapshot
lxc exec "$CONTAINER" --env KUBECONFIG=/etc/rancher/k3s/k3s.yaml -- bash -lc '
  set -e
  for i in {1..30}; do kubectl get nodes >/dev/null 2>&1 && break; sleep 2; done
  kubectl get nodes -o wide || true
  kubectl -n kube-system get pods || true
  echo "— Recent kube-system events —"
  kubectl -n kube-system get events --sort-by=.lastTimestamp | tail -n 50 || true
' || { error "Step 6.7: k3s quick health snapshot failed"; exit 1; }

# 5) RIC + ORANSlice build (unchanged)
lxc exec "$CONTAINER" -- bash -lc '
  set -e
  cd /root && git clone https://gerrit.o-ran-sc.org/r/ric-plt/ric-dep || true
' || { error "Step 6.8: cloning ric-dep failed"; exit 1; }

lxc exec "$CONTAINER" -- bash -lc '
  set -e
  cd /root/ric-dep/RECIPE_EXAMPLE
  cp -f example_recipe_oran_e_release.yaml my_ric_recipe.yaml
' || { error "Step 6.9: copying recipe failed"; exit 1; }

# ensure kube context exists for non-interactive shells
lxc exec "$CONTAINER" -- bash -lc '
  set -e
  mkdir -p /root/.kube
  ln -sf /etc/rancher/k3s/k3s.yaml /root/.kube/config
  chmod 600 /etc/rancher/k3s/k3s.yaml
' || { error "Step 6.9b: ensure kubeconfig link failed"; exit 1; }

# (optional but often required before install) load common templates
lxc exec "$CONTAINER" --env KUBECONFIG=/etc/rancher/k3s/k3s.yaml -- bash -lc '
  set -e
  cd /root/ric-dep/bin
  ./install_common_templates_to_helm.sh
' || { error "Step 6.10: install_common_templates_to_helm.sh failed"; exit 1; }

lxc exec "$CONTAINER" --env KUBECONFIG=/etc/rancher/k3s/k3s.yaml -- bash -lc '
  set -e
  cd /root/ric-dep/bin
  ./install -f ../RECIPE_EXAMPLE/my_ric_recipe.yaml
' || { error "Step 6.11: RIC install failed"; exit 1; }

lxc exec "$CONTAINER" --env KUBECONFIG=/etc/rancher/k3s/k3s.yaml -- bash -lc '
  set -e
  kubectl get pods -A
' || { error "Step 6.12: kubectl pod listing failed"; exit 1; }

# Copy helper scripts next to ric-dep (use absolute paths to avoid cwd confusion)
lxc exec "$CONTAINER" -- bash -lc '
  set -e
  cd /root/ric-dep 
  cp /root/OAI-RIC-Network/deploy-local.sh .
  cp /root/OAI-RIC-Network/configure-and-start-k3s.sh .
  chmod +x *
' || { error "Step 6.13: copying helper scripts failed"; exit 1; }

echo "▶️  [7/8] The dms_cli tool facilitates xApp onboarding."
  lxc exec "$CONTAINER" -- bash -c '
    git clone https://github.com/o-ran-sc/ric-plt-appmgr.git
    cd ric-plt-appmgr/xapp_orchestrater/dev/xapp_onboarder
    
    git checkout e-release
    # installing python 3.9 (needed for this repo)
    sudo add-apt-repository ppa:deadsnakes/ppa
    sudo apt update
    # installing python and python venv
    sudo apt install python3.9 python3.9-dev python3.9-venv
    # create virtual environment
    python3.9 -m venv .venv
    # activate the virtual environment
    source .venv/bin/activate
    # install requirements
    pip install -r requirements.txt
    pip install .
    docker run --rm -u 0 -it -d -p 8090:8080 \
    -e DEBUG=1 -e STORAGE=local -e STORAGE_LOCAL_ROOTDIR=/charts \
    -v $(pwd)/charts:/charts chartmuseum/chartmuseum:latest
    export CHART_REPO_URL=http://0.0.0.0:8090
'
echo "▶️  [8/8] Building ORANSlice xApp Docker image..."
lxc exec "$CONTAINER" -- bash -c '
  set -e
  cd /root/OAI-RIC-Network/xapp-oai
  docker build -t oranslice-xapp:latest -f Dockerfile .
  docker run -d -p 5000:5000 --name registry registry:2
  docker tag oranslice-xapp:latest myregistry.local:5000/oranslice-xapp:latest
  docker push myregistry.local:5000/oranslice-xapp:latest

  cd ric-plt-appmgr/xapp_orchestrater/dev/xapp_onboarder
  .venv/bin/dms_cli  onboard /root/OAI-RIC-Network/xapp-oai/xapp_bs_connector/init/config-file.json   --shcema_file_path=/root/OAI-RIC-Network/xapp-oai/xapp_bs_connector/init/schema.json
  cd charts
  helm install oranslice-xapp oranslice-xapp-1.0.0.tgz -n ricxapp
  '

success "All setup steps for RIC and ORANSlice xApp completed inside '$CONTAINER'"
