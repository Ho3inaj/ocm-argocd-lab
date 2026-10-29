#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config.sh"

kubectl config use-context "kind-hub"

AGENT_PODS="$(kubectl -n open-cluster-management-agent get pods -o name 2>/dev/null || true)"
if [ -n "$AGENT_PODS" ]; then
  echo "ERROR: klusterlet agent pods are running ON THE HUB — a 'clusteradm join' was" >&2
  echo "  executed on the hub VM by mistake (the hub registered itself as a spoke)." >&2
  echo "  cleanup on the hub:" >&2
  echo "    kubectl delete managedcluster <the-name-it-used> --ignore-not-found" >&2
  echo "    kubectl delete ns open-cluster-management-agent --ignore-not-found" >&2
  echo "    kubectl delete klusterlet klusterlet --ignore-not-found" >&2
  echo "  then run the join ON THE SPOKE VM instead (check: hostname -I)" >&2
  exit 1
fi

FAIL=0
for c in spoke1 spoke2; do
  if ! kubectl get managedcluster "$c" >/dev/null 2>&1; then
    echo "ERROR: managedcluster '$c' does not exist on the hub yet - nothing to accept." >&2
    echo "  join it FIRST, running ON THE ${c} VM (not the hub):" >&2
    echo "    bash infra/setup-ocm-spoke.sh $c /root/ocm-join.txt" >&2
    echo "  (if the join token expired, re-run setup-ocm-hub.sh on the hub for a fresh one -" >&2
    echo "   tokens live about 1 hour)" >&2
    FAIL=1
  fi
done
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi

clusteradm accept --clusters spoke1,spoke2 --wait || \
  echo "NOTE: 'accept' returned non-zero (possibly already accepted) - verifying state instead"

if ! kubectl get managedclusterset default >/dev/null 2>&1; then
  kubectl apply -f - <<'EOF'
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata:
  name: default
spec: {}
EOF
fi

kubectl label managedcluster spoke1 spoke2 \
  "cluster.open-cluster-management.io/clusterset=default" --overwrite

kubectl label managedcluster spoke2 pull-target=true --overwrite

echo
kubectl get managedclusters
echo
kubectl get managedcluster --show-labels

FAIL=0
for c in spoke1 spoke2; do
  AVAIL="$(kubectl get managedcluster "$c" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterAvailable")].status}' 2>/dev/null || true)"
  if [ "$AVAIL" != "True" ]; then
    echo "ERROR: managedcluster $c is not Available yet (condition=$AVAIL)" >&2
    FAIL=1
  fi
done
if [ "$FAIL" -ne 0 ]; then
  echo "hint: on each SPOKE VM check: kubectl -n open-cluster-management-agent get pods" >&2
  exit 1
fi
echo "both spokes Available"
