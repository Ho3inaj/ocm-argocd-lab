#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config.sh"

kubectl config use-context "kind-hub"

if kubectl get namespace open-cluster-management >/dev/null 2>&1; then
  echo "OCM hub already initialized - skipping clusteradm init"
else
  clusteradm init --wait
fi

clusteradm get token | grep 'clusteradm join' > "$HOME/ocm-join.txt" || {
  echo "ERROR: could not extract join command from 'clusteradm get token'" >&2
  exit 1
}

echo
echo "join command saved to: $HOME/ocm-join.txt"
cat "$HOME/ocm-join.txt"
echo
echo "next: relay this file to spoke1 and spoke2 (RUNBOOK PHASE 2 step 2), then run infra/setup-ocm-spoke.sh"
