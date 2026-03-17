# OAI-RIC-Network

This repository provides the tooling and configuration for deploying the **OSC Near-RT RIC** platform inside an LXC container on [Colosseum](https://www.colosseum.net) or any Linux host with LXC and k3s.

For container provisioning and first-time setup, refer to **[`src/README.md`](src/README.md)**.

---

## Repository Structure

```
OAI-RIC-Network/
├── src/                          # Container lifecycle scripts (see src/README.md)
│   ├── setup_container/
│   ├── Export_container/
│   └── setup_Github/
├── my_ric_recipe.yaml            # RIC deployment recipe (image versions, namespaces, IPs)
├── configure-and-start-k3s.sh   # Reconfigure and restart k3s
├── deploy-local.sh               # Redeploy RIC platform + xApp from a recipe
├── deploy-plt.sh                 # Redeploy RIC platform only (no xApp)
└── restart-pods.sh               # Restart the three most unstable RIC pods
```

---

## Namespaces

The RIC platform spans three Kubernetes namespaces:

| Namespace | Contents |
|-----------|----------|
| `ricplt` | All Near-RT RIC platform components (e2mgr, e2term, rtmgr, a1mediator, submgr, appmgr, dbaas, vespamgr, o1mediator, alarmmanager, Kong ingress, Prometheus) |
| `ricinfra` | Tiller / Helm infrastructure for xApp management |
| `ricxapp` | Deployed xApps |

---

## Deployment Recipe — `my_ric_recipe.yaml`

The RIC platform is deployed using [`my_ric_recipe.yaml`](my_ric_recipe.yaml), derived from the upstream `example_recipe_oran_e_release.yaml`. It configures image registries, component versions, namespaces, and the ingress IPs for the platform.

The platform installation follows the [OSC RIC deployment guide](https://docs.o-ran-sc.org/projects/o-ran-sc-ric-plt-ric-dep/en/latest/installation-guides.html).

Key settings:

| Field | Value |
|-------|-------|
| `common.releasePrefix` | `r4` |
| `extsvcplt.ricip` / `auxip` | `10.0.0.1` — auto-patched to the container's detected IP at deploy time |
| `dbaas.enableHighAvailability` | `false` |
| `dbaas.enablePodAntiAffinity` | `false` |
| `e2mgr.globalRicId` | `AACCE`, MCC `310`, MNC `411` |
| `e2term.alpha.dataVolSize` | `100Mi`, `local-storage` |

All component images pull from `nexus3.o-ran-sc.org:10002/o-ran-sc` at the versions pinned in the recipe.

---

## Expected Cluster State

After a successful deployment, `kubectl get pods -A` should show all platform pods in `Running` or `Completed` state:

```
NAMESPACE     NAME                                                        READY   STATUS      RESTARTS      AGE
kube-system   coredns-64fd4b4794-sm8zb                                    1/1     Running     1 (21d ago)   21d
kube-system   local-path-provisioner-774c6665dc-lqgd2                     1/1     Running     1 (21d ago)   21d
kube-system   metrics-server-7bfffcd44-5l525                              1/1     Running     1 (21d ago)   21d
kube-system   svclb-r4-infrastructure-kong-proxy-cb93fab7-9ktr7           2/2     Running     2 (21d ago)   21d
ricinfra      deployment-tiller-ricxapp-84b87b8c64-pnxsh                  1/1     Running     1 (21d ago)   21d
ricinfra      tiller-secret-generator-gtkt7                               0/1     Completed   0             21d
ricplt        deployment-ricplt-a1mediator-655587f8cc-v792b               1/1     Running     1 (21d ago)   21d
ricplt        deployment-ricplt-alarmmanager-74dccd8f5-jw92k              1/1     Running     1 (21d ago)   21d
ricplt        deployment-ricplt-appmgr-67dfb5db97-987cn                   1/1     Running     1 (21d ago)   21d
ricplt        deployment-ricplt-e2mgr-56df7d7fdc-tj6mv                    1/1     Running     0             20d
ricplt        deployment-ricplt-e2term-alpha-cf6785b4d-kmhc2              1/1     Running     0             20d
ricplt        deployment-ricplt-o1mediator-74754f5f7c-jv56m               1/1     Running     1 (21d ago)   21d
ricplt        deployment-ricplt-rtmgr-857c78bf8-6pst5                     1/1     Running     0             20d
ricplt        deployment-ricplt-submgr-5bf7469cc4-rtl8m                   1/1     Running     1 (21d ago)   21d
ricplt        deployment-ricplt-vespamgr-848f7bb874-5slb2                 1/1     Running     1 (21d ago)   21d
ricplt        r4-infrastructure-kong-78657d8f48-lwvmf                     2/2     Running     2 (21d ago)   21d
ricplt        r4-infrastructure-prometheus-alertmanager-b9cc56766-622xt   2/2     Running     2 (21d ago)   21d
ricplt        r4-infrastructure-prometheus-server-6476958975-zmgfk        1/1     Running     1 (21d ago)   21d
ricplt        statefulset-ricplt-dbaas-server-0                           1/1     Running     1 (21d ago)   21d
```

---

## Helper Scripts

### `configure-and-start-k3s.sh` — Reconfigure and restart k3s

Run this from inside the LXC container whenever the container's IP changes or k3s needs to be re-homed on a different network interface.

The script:
1. Detects the active network interface — prefers `col0` (the Colosseum dedicated interface), falls back to the default-route interface
2. Writes a fresh `/etc/rancher/k3s/config.yaml` binding the API server, Flannel, and node IP to the detected interface IP
3. Disables Traefik and sets kubelet flags required for unprivileged usernamespace operation
4. Purges all existing k3s state (`/var/lib/rancher/k3s`, old kubeconfig)
5. Restarts the k3s systemd service and waits for it to come up

```bash
sudo ./configure-and-start-k3s.sh
```

> After running this script all pods are gone. Use `deploy-plt.sh` to bring the RIC platform back up, then proceed with xApp deployment.

---

### `deploy-local.sh` — Redeploy RIC platform + xApp

Redeploys all RIC platform Helm charts from an existing recipe file without reinstalling k3s, Docker, or any system packages. Useful when resuming a Colosseum experiment with an already-provisioned container.

```bash
# Run from inside the container at /root/ric-dep/
./deploy-local.sh my_ric_recipe.yaml
```

What it does:
- Detects the active interface IP (`col0` or fallback) and patches `ricip`/`auxip` in the recipe
- Ensures the `ricplt`, `ricinfra`, and `ricxapp` namespaces exist
- Runs `helm upgrade --install` for all platform components
- Removes liveness/readiness probes from the `a1mediator` deployment
- Exposes the E2 termination SCTP endpoint on **port 36422** using the container's detected IP

After the platform is up, the script proceeds to xApp deployment. For xApp instructions refer to `<add-xapp-repo-link-here>`.

---

### `deploy-plt.sh` — Redeploy RIC platform only

Same as `deploy-local.sh` but stops before the xApp step. Use this when you want to redeploy or refresh the platform without affecting xApps, or when the xApp has not been set up yet.

```bash
# Run from inside the container at /root/ric-dep/
./deploy-plt.sh my_ric_recipe.yaml
```

Also re-exposes the E2 term SCTP service on **port 36422**.

---

### `restart-pods.sh` — Restart unstable RIC pods

The RIC deployment is not always fully stable. Pods may get stuck, fail to connect, or enter a crash loop — particularly after a container restart or network change. In most cases, restarting the three most failure-prone components is sufficient to restore normal operation:

```bash
./restart-pods.sh
```

Performs a rolling restart of:
- `deployment-ricplt-e2mgr`
- `deployment-ricplt-e2term-alpha`
- `deployment-ricplt-rtmgr`

Then waits for each to finish rolling out and prints the final pod status.

---

## Platform Stability Notes

The OSC Near-RT RIC platform can be unstable in LXC-constrained environments. Common symptoms include pods stuck in `CrashLoopBackOff`, `Pending`, or failing readiness checks after a container restart or IP change.

**Recommended recovery order:**

1. Run `restart-pods.sh` first — handles the majority of transient failures.
2. If the container IP has changed (common in Colosseum between experiments), run `configure-and-start-k3s.sh` followed by `deploy-plt.sh my_ric_recipe.yaml` to fully redeploy.

---

## License

This project is licensed under the **GPL-3.0 License**.
