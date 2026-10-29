#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config.sh"

ROLE="${1:-}"
case "$ROLE" in
  hub)    IP="$HUB_IP" ;;
  spoke1) IP="$SPOKE1_IP" ;;
  spoke2) IP="$SPOKE2_IP" ;;
  *) echo "usage: bash infra/create-cluster.sh <hub|spoke1|spoke2>" >&2; exit 1 ;;
esac

mkdir -p "$HOME/.kube"
touch "$HOME/.kube/config"

if kind get clusters 2>/dev/null | grep -qx "$ROLE"; then
  echo "kind cluster '$ROLE' already exists - skipping creation"
else
  kind create cluster --config "$ROOT/infra/kind/${ROLE}.yaml" --wait 180s
fi

RAW_KC="$(mktemp)"
kind get kubeconfig --name "$ROLE" > "$RAW_KC"
sed -E "s|server: https://.*|server: https://${IP}:6443|" "$RAW_KC" > "$HOME/.kube/${ROLE}.kubeconfig"
rm -f "$RAW_KC"

KUBECONFIG="$HOME/.kube/config:$HOME/.kube/${ROLE}.kubeconfig" kubectl config view --flatten > "$HOME/.kube/config.merged"
mv "$HOME/.kube/config.merged" "$HOME/.kube/config"
kubectl config use-context "kind-${ROLE}" >/dev/null

echo
echo "== verifying apiserver at https://${IP}:6443 (TLS cert must carry this IP) =="
KUBECONFIG="$HOME/.kube/${ROLE}.kubeconfig" kubectl get nodes -o wide

echo
echo "standalone kubeconfig (for relay to hub): $HOME/.kube/${ROLE}.kubeconfig"
