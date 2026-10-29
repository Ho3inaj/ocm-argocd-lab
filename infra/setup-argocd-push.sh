#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config.sh"

SPOKE1_KUBECONFIG="${1:-}"

if [ -z "$SPOKE1_KUBECONFIG" ] || [ ! -f "$SPOKE1_KUBECONFIG" ]; then
  echo "usage: bash infra/setup-argocd-push.sh </path/to/spoke1.kubeconfig>" >&2
  echo "       (the standalone spoke1 kubeconfig relayed from the spoke1 VM)" >&2
  exit 1
fi

kubectl config use-context "kind-hub"

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

kubectl patch cm argocd-cm -n argocd --type merge \
  -p '{"data":{"kustomize.buildOptions":"--enable-helm"}}'

kubectl -n argocd rollout status deployment/argocd-server --timeout=600s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=600s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s
kubectl -n argocd rollout status deployment/argocd-applicationset-controller --timeout=600s

KC="$SPOKE1_KUBECONFIG"
CA="$(kubectl --kubeconfig "$KC" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
SERVER="$(kubectl --kubeconfig "$KC" config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')"
CLIENT_CERT="$(kubectl --kubeconfig "$KC" config view --raw --minify -o jsonpath='{.users[0].user.client-certificate-data}')"
CLIENT_KEY="$(kubectl --kubeconfig "$KC" config view --raw --minify -o jsonpath='{.users[0].user.client-key-data}')"

if [ -z "$CA" ] || [ -z "$SERVER" ]; then
  echo "ERROR: could not extract cluster info from $KC" >&2
  exit 1
fi

CLUSTER_CONFIG="{\"tlsClientConfig\":{\"insecure\":false,\"caData\":\"${CA}\",\"clientCertData\":\"${CLIENT_CERT}\",\"clientKeyData\":\"${CLIENT_KEY}\"}}"

kubectl -n argocd create secret generic argocd-cluster-spoke1 \
  --from-literal=name=spoke1 \
  --from-literal=server="$SERVER" \
  --from-literal=config="$CLUSTER_CONFIG" \
  --from-literal=project=default \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n argocd label secret argocd-cluster-spoke1 \
  argocd.argoproj.io/secret-type=cluster --overwrite

sed -e "s|__GIT_REPO_URL__|${GIT_REPO_URL}|g" \
    -e "s|__GIT_REPO_BRANCH__|${GIT_REPO_BRANCH}|g" \
    -e "s|__SPOKE1_SERVER__|https://${SPOKE1_IP}:6443|g" \
    "$ROOT/infra/argocd/push-application.yaml" | kubectl apply -f -

echo
echo "== registered ArgoCD cluster(s) =="
kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=cluster
echo
echo "== push Application =="
kubectl -n argocd get application podinfo-push-spoke1
echo
echo "ArgoCD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true
echo
