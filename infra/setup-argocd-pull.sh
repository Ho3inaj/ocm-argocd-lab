#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config.sh"

kubectl config use-context "kind-hub"

if ! kubectl get deployment -n argocd argocd-pull-integration >/dev/null 2>&1; then
  clusteradm install hub-addon --names argocd
fi
for _ in $(seq 1 30); do
  kubectl get deployment -n argocd argocd-pull-integration >/dev/null 2>&1 && break
  sleep 2
done
kubectl -n argocd rollout status deployment/argocd-pull-integration --timeout=300s

if ! kubectl get managedclusteraddon -n spoke2 argocd >/dev/null 2>&1; then
  clusteradm addon enable --names argocd --clusters spoke2
fi
kubectl -n spoke2 wait managedclusteraddon/argocd --for=condition=Available --timeout=900s

kubectl label managedcluster spoke2 pull-target=true --overwrite

kubectl apply -f "$ROOT/infra/ocm/managedclustersetbinding.yaml"
kubectl apply -f "$ROOT/infra/ocm/placement.yaml"

kubectl wait placement/app-placement -n argocd --for=condition=PlacementSatisfied --timeout=60s || true
echo
echo "== placement decisions =="
kubectl get placementdecision -n argocd -o wide || true

sed -e "s|__GIT_REPO_URL__|${GIT_REPO_URL}|g" \
    -e "s|__GIT_REPO_BRANCH__|${GIT_REPO_BRANCH}|g" \
    "$ROOT/infra/argocd/pull-applicationset.yaml" | kubectl apply -f -

echo
echo "== ApplicationSet =="
kubectl -n argocd get applicationset podinfo-pull-set
echo
echo "watch the chain form (RUNBOOK, PHASE 3 step 2):"
echo "  kubectl -n argocd get application -w"
echo "  kubectl -n spoke2 get manifestwork -w"
