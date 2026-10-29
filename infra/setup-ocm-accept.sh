#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config.sh"

kubectl config use-context "kind-hub"

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
  echo "hint: check klusterlet pods on the spoke VMs:" >&2
  echo "  kubectl -n open-cluster-management-agent get pods" >&2
  exit 1
fi
echo "both spokes Available"
