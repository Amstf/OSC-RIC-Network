# Colosseum / LXC Container Setup
Scripts for automating the full LXC container lifecycle when deploying the OSC nearRT-RIC and ORANSlice xApps on the [Colosseum](https://www.colosseum.net) wireless network emulator, or on any LXC-capable host. The tooling covers base image acquisition, container initialization, network configuration, Docker and k3s installation, RIC platform deployment, and xApp onboarding.
> After setup, refer to **[`../README.md`](../README.md)** for instructions on running the RIC and xApps.
---
## Directory Structure
```
src/
├── setup_container/              # Scripts to download, import, and prepare an LXC container
│   ├── setup_ric_container.sh        # Main orchestration script
│   ├── download_image.sh             # Downloads the base image from Colosseum storage
│   ├── import_and_launch.sh          # Imports the image into LXC and starts the container
│   └── set_lxc_network.sh            # Configures network inside the container
├── Export_container/             # Scripts to snapshot and upload a container to Colosseum
│   ├── export_container.sh           # Exports the running container as a .tar.gz image
│   ├── upload_image.sh               # Uploads the exported image to Colosseum storage
│   └── export_and_upload.sh          # Runs export then upload in one step
└── setup_Github/                 # SSH key generation helper for GitHub access
    └── generate_github_keys.sh
```
---
## Prerequisites
The following must be present on the host before running the setup script:
- LXC configured and operational — refer to `<add-your-lxc-setup-doc-here>`
- Internet access from inside the container (required for Docker, k3s, and RIC installation)
- Sufficient disk space — the RIC platform, Docker images, and xApp build are substantial
---
## Pre-step — GitHub SSH Key Setup (one-time)
Before running the container setup script, generate and register an SSH key for GitHub access.
**1. Run the key generator:**
```bash
cd src/setup_Github
./generate_github_keys.sh
```
When prompted, enter a GitHub username, email, target directory (default: `~/.ssh`), and an optional passphrase. The script prints the public key on completion.
**2. Add the public key to GitHub:**
- Go to [https://github.com/settings/keys](https://github.com/settings/keys)
- Click **New SSH key** and paste the printed key.
**3. Verify authentication:**
```bash
ssh -i ~/.ssh/github-keys -T git@github.com
```
Expected output:
```
Hi <your-username>! You've successfully authenticated, but GitHub does not provide shell access.
```
---
## Setting Up the Container — `setup_ric_container.sh`
`setup_ric_container.sh` automates the full pipeline from a base LXC image to a running nearRT-RIC with the ORANSlice xApp deployed. Run it from the `src/setup_container/` directory.
### Usage
```bash
cd src/setup_container
./setup_ric_container.sh \
    <image-name.tar.gz> \
    [alias] \
    [container-name] \
    [remote-user] \
    [ssh-key-path]
```
| Argument | Required | Description |
|----------|----------|-------------|
| `image-name.tar.gz` | yes | Filename of the base LXC image on Colosseum storage |
| `alias` | no | LXC image alias — defaults to filename without `.tar.gz` |
| `container-name` | no | LXC container name — defaults to `<alias>-cont` |
| `remote-user` | no | Colosseum username — defaults to `alimustapha` |
| `ssh-key-path` | no | Path to the GitHub SSH private key (host-side) to copy into the container |
### Example
```bash
./setup_ric_container.sh base-2204.tar.gz ric-image ric-cont myuser ~/.ssh/github-keys
```
### Execution Steps
The script runs **8 sequential steps**. Steps 1–5 execute on the host or configure the container environment; steps 6–8 execute entirely inside the container.
---
**[Pre / Host] Prepare host kernel for k3s networking**
Before container setup begins, the script loads the kernel modules and applies the sysctls required by k3s, flannel, and CNI on the host:
```
br_netfilter, vxlan
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
```
---
**[1/8] Download the image** — `download_image.sh`
Downloads the base LXC image from the Colosseum shared NAS, proxied through the Colosseum gateway. If the image is already present locally, this step is skipped. The image is saved under `./images/`.
---
**[2/8] Import and launch the container** — `import_and_launch.sh`
Imports the downloaded image into LXC under the given alias, then initializes and starts a container from it using the `bigpool` storage pool. Both steps are idempotent — if the image alias or container already exists, they are skipped.
After import, the container is reconfigured for k3s compatibility before the next step:
| Setting | Value | Purpose |
|---------|-------|---------|
| `security.nesting` | `true` | Required for Docker-in-LXC |
| `security.privileged` | `true` | Required for k3s and kernel namespace access |
| `raw.lxc apparmor.profile` | `unconfined` | Removes AppArmor restrictions that block k3s |
| `/dev/kmsg` device | passed through | Required by k3s for logging |
| `/dev/fuse` device | passed through | Required by some CNI components |
---
**[3/8] Configure the network** — `set_lxc_network.sh`
Attaches the `lxdbr1` bridge to the container's `eth0` interface, brings it up, and obtains a DHCP lease. Writes a static DNS configuration to prevent DHCP from overwriting `/etc/resolv.conf`. Verifies internet connectivity before exiting.
---
**[4/8] Apply static DNS and k3s sysctls inside the container**
Disables `systemd-resolved` and writes a static `/etc/resolv.conf` (nameservers `8.8.8.8` / `1.1.1.1`) to ensure stable DNS resolution under k3s. Persists the k3s-required sysctls to `/etc/sysctl.d/99-k3s.conf` and applies them via `sysctl --system`.
---
**[5/8] Push SSH key** *(only if `ssh-key-path` is provided)*
Copies the GitHub SSH key pair into `/root/.ssh/` inside the container as `id_rsa` / `id_rsa.pub`, sets correct permissions, adds `github.com` to known hosts, and runs an authentication test.
---
**[6/8] Install Docker, k3s, Helm, and deploy the RIC platform** — runs inside the container
This is the primary build step. It performs the following operations in order:
- Clones the `OAI-RIC-Network` repository from GitHub into `/root/OAI-RIC-Network/`
- Installs base system packages: `git`, `curl`, `vim`, `net-tools`, `iproute2`, `conntrack`, `socat`, `ebtables`, `ipset`, `python3-pip`, and related build dependencies
- Installs Docker with the **VFS storage driver** (`/etc/docker/daemon.json`) — OverlayFS is not used due to LXC filesystem constraints
- Installs k3s via the official installer with the Docker runtime (`--docker`), Traefik disabled, and kubeconfig world-readable
- Exports `KUBECONFIG=/etc/rancher/k3s/k3s.yaml` in `/root/.bashrc` and symlinks it to `/root/.kube/config`
- Installs Helm 3 and the `helm-push` chartmuseum plugin
- Waits for k3s to become ready, then runs a health snapshot (`kubectl get nodes`, `kubectl get pods -A`)
- Clones the OSC RIC platform repository (`ric-plt/ric-dep`) from `gerrit.o-ran-sc.org`
- Copies `example_recipe_oran_e_release.yaml` to `my_ric_recipe.yaml` as the active deployment recipe
- Runs `install_common_templates_to_helm.sh` to load shared Helm templates
- Deploys the full RIC platform via `./install -f my_ric_recipe.yaml`
- Copies `deploy-local.sh` and `configure-and-start-k3s.sh` helper scripts from `OAI-RIC-Network` into `ric-dep/`
> This step performs multiple online installations and may take 15–30 minutes depending on network conditions. Partial failures at any sub-step are reported with the failing operation name.
---
**[7/8] Install the xApp onboarder (`dms_cli`)** — runs inside the container
- Clones `ric-plt-appmgr` from the OSC repository and checks out the `e-release` branch
- Installs Python 3.9 from the `deadsnakes` PPA
- Creates a Python 3.9 virtual environment under `xapp_onboarder/.venv` and installs all requirements
- Starts a local chartmuseum instance on port `8090` via Docker
- Sets `CHART_REPO_URL=http://0.0.0.0:8090`
> Once `dms_cli` is operational and the chartmuseum instance is running, the RIC platform is ready for xApp onboarding.
---
**[8/8] Build and deploy the xApp** — runs inside the container
Builds the xApp Docker image, pushes it to a local registry, onboards the Helm chart via `dms_cli`, and installs it into the `ricxapp` namespace.
> For the full xApp setup, configuration, and deployment instructions, refer to **[`<add-xapp-repo-link-here>`](<add-xapp-repo-link-here>)**.
---
## Exporting a Container — `Export_container/`
A working container can be snapshotted and pushed back to Colosseum storage for reuse or sharing.
| Script | Description |
|--------|-------------|
| `export_container.sh` | Stops the container, publishes it as an LXC image, and exports it to `~/myimages/<alias>.tar.gz`. Optionally removes a private SSH key from inside the image before export to avoid credential leakage. |
| `upload_image.sh` | Uploads the exported `.tar.gz` to the Colosseum shared NAS via the gateway jump host. |
| `export_and_upload.sh` | Runs export then upload in one step. |
### Usage
```bash
cd src/Export_container
# Export only
./export_container.sh <container-name> [image-alias] [ssh-key-path-inside-container]
# Export and upload in one step
./export_and_upload.sh <container-name> [image-alias] [ssh-key-path-inside-container] [remote-user]
```
