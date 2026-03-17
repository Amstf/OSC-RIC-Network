#!/usr/bin/env bash
# deploy-plt.sh — Redeploy all RIC platform Helm charts from a recipe file.
# Unlike deploy-local.sh, this script does NOT touch the xApp namespace or
# install any xApp charts. Use it to redeploy or refresh the platform only.
#
# Usage: ./deploy-plt.sh <path-to-recipe.yaml>

if [ $# -ne 1 ]; then
  echo "Usage: $0 <path-to-recipe.yaml>"
  exit 1
fi
RECIPE="$1"

# locate our base dir and chart dirs
BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$BASEDIR/helm"
COMMON_CHART="$BASEDIR/ric-common/Common-Template/helm/ric-common"

# sanity check
[ -f "$COMMON_CHART/Chart.yaml" ] || {
  echo "❌ cannot find ric-common at $COMMON_CHART"
  exit 1
}

# detect col0 ip, fallback to default route iface
IFACE=${COL_IFACE:-col0}
if ! ip link show "$IFACE" &>/dev/null; then
  echo "⚠️  interface $IFACE not found, falling back to default route interface..."
  IFACE=$(ip route show default 0.0.0.0/0 | awk '{print $5}' | head -n1)
  if [ -z "$IFACE" ]; then
    echo "❌ could not determine default route interface"; exit 1
  fi
fi

COL0_IP=$(ip -o -4 addr show dev "$IFACE" | awk '{print $4}' | cut -d/ -f1)
echo "🔍 Using $IFACE → $COL0_IP"

# read releasePrefix
RELEASE_PREFIX=$(awk '/^ *releasePrefix:/ {print $2; exit}' "$RECIPE")
echo "🔧 releasePrefix=$RELEASE_PREFIX"

# read or default namespaces
ns_for(){ awk -v key="$1" '/^ *namespace:/,/^[^ ]/{
    if ($1==key":") print $2 }' "$RECIPE"; }
PLT_NS=$(ns_for platform); PLT_NS=${PLT_NS:-ricplt}
INF_NS=$(ns_for infra);    INF_NS=${INF_NS:-ricinfra}
XAPP_NS=$(ns_for xapp);    XAPP_NS=${XAPP_NS:-ricxapp}
echo "   namespaces: plt=$PLT_NS, inf=$INF_NS (xapp=$XAPP_NS — not touched)"

# patch ricip & auxip
PATCHED="$(mktemp)"
sed -E "/^extsvcplt:/,/^[^ ]/ {
  s|^(  ricip:).*|\1 $COL0_IP|;
  s|^(  auxip:).*|\1 $COL0_IP|;
}" "$RECIPE" > "$PATCHED"

# create platform/infra namespaces if needed (xapp namespace left untouched)
for ns in "$PLT_NS" "$INF_NS"; do
  if ! kubectl get ns "$ns" &>/dev/null; then
    echo "  ➤ creating namespace $ns"
    kubectl create ns "$ns"
  fi
done

# push recipe into a ConfigMap
kubectl -n "$PLT_NS" delete cm ricplt-recipe --ignore-not-found
kubectl -n "$PLT_NS" create cm ricplt-recipe --from-file=recipe="$PATCHED"

# components to deploy (platform only — no xApp)
COMPONENTS=(
  infrastructure dbaas appmgr rtmgr e2mgr e2term
  a1mediator submgr vespamgr o1mediator alarmmanager
)

echo "📦 Installing platform components: ${COMPONENTS[*]}"
for comp in "${COMPONENTS[@]}"; do
  CHART="$HELM_DIR/$comp"
  RELEASE="$RELEASE_PREFIX-$comp"

  if [ ! -d "$CHART" ]; then
    echo "⚠️  chart missing: $CHART – skipping"
    continue
  fi

  echo "── 🚀 $RELEASE"
  rm -rf "$CHART/charts/ric-common"
  mkdir -p "$CHART/charts"
  cp -r "$COMMON_CHART" "$CHART/charts/ric-common"

  helm upgrade --install "$RELEASE" "$CHART" \
    --namespace "$PLT_NS" \
    -f "$PATCHED" \
    --set global.image.pullPolicy=IfNotPresent \
    --wait --timeout 5m
done

rm "$PATCHED"

# remove liveness/readiness probes from a1mediator
kubectl -n "$PLT_NS" patch deployment deployment-ricplt-a1mediator \
  --type=json \
  -p '[
    {"op":"remove","path":"/spec/template/spec/containers/0/livenessProbe"},
    {"op":"remove","path":"/spec/template/spec/containers/0/readinessProbe"}
  ]'

# expose the e2term SCTP service on the host
kubectl -n "$PLT_NS" delete svc sctp-service --ignore-not-found
kubectl -n "$PLT_NS" expose deployment deployment-ricplt-e2term-alpha \
  --protocol=SCTP --port=36422 --target-port=36422 \
  --external-ip="$COL0_IP" --name=sctp-service

echo "✅ Platform deployment done!"
echo "→ $PLT_NS pods:"; kubectl get pods -n "$PLT_NS" -o wide
echo "→ $INF_NS pods:"; kubectl get pods -n "$INF_NS" -o wide
