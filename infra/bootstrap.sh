#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run as root:  sudo bash infra/bootstrap.sh" >&2
  exit 1
fi

fetch() {
  local dest="$1" primary="$2" fallback="${3:-}"
  if curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors "$primary" -o "$dest"; then
    return 0
  fi
  if [ -n "$fallback" ] && curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors "$fallback" -o "$dest"; then
    echo "note: primary mirror failed, used fallback: $fallback"
    return 0
  fi
  echo "ERROR: download failed after retries:" >&2
  echo "  primary:   $primary" >&2
  if [ -n "$fallback" ]; then echo "  fallback:  $fallback" >&2; fi
  echo "  test with:  curl -m 10 -sSI <url>" >&2
  echo "  then simply re-run:  sudo bash infra/bootstrap.sh   (idempotent)" >&2
  return 1
}

swapoff -a || true
sed -ri 's/^([^#].*[[:space:]]swap[[:space:]].*)$/#\1/' /etc/fstab || true

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates gnupg lsb-release apt-transport-https git jq tar gzip

if ! command -v docker >/dev/null 2>&1; then
  if ! curl -fsSL --retry 3 https://get.docker.com | sh; then
    apt-get install -y docker.io
  fi
fi
systemctl enable --now docker

SUDO_USER_NAME="${SUDO_USER:-}"
if [ -n "$SUDO_USER_NAME" ] && [ "$SUDO_USER_NAME" != "root" ]; then
  usermod -aG docker "$SUDO_USER_NAME"
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

if ! command -v kubectl >/dev/null 2>&1 || ! kubectl version --client 2>/dev/null | grep -q "$KUBECTL_VERSION"; then
  fetch "$TMPD/kubectl" \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    "https://cdn.dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  install -m 755 "$TMPD/kubectl" /usr/local/bin/kubectl
fi

if ! command -v kind >/dev/null 2>&1 || ! kind version 2>/dev/null | grep -q "$KIND_VERSION"; then
  fetch "$TMPD/kind" \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" \
    "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64"
  install -m 755 "$TMPD/kind" /usr/local/bin/kind
fi

if ! command -v argocd >/dev/null 2>&1 || ! argocd version --client 2>/dev/null | grep -q "$ARGOCD_VERSION"; then
  fetch "$TMPD/argocd" \
    "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64"
  install -m 755 "$TMPD/argocd" /usr/local/bin/argocd
fi

if ! command -v helm >/dev/null 2>&1 || ! helm version --short 2>/dev/null | grep -q "$HELM_VERSION"; then
  fetch "$TMPD/helm.tar.gz" \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
  tar -xzf "$TMPD/helm.tar.gz" -C "$TMPD"
  install -m 755 "$TMPD/linux-amd64/helm" /usr/local/bin/helm
fi

if ! command -v clusteradm >/dev/null 2>&1 || ! clusteradm version 2>/dev/null | grep -q "$CLUSTERADM_VERSION"; then
  fetch "$TMPD/clusteradm.tar.gz" \
    "https://github.com/open-cluster-management-io/clusteradm/releases/download/${CLUSTERADM_VERSION}/clusteradm_linux_amd64.tar.gz"
  tar -xzf "$TMPD/clusteradm.tar.gz" -C "$TMPD"
  install -m 755 "$TMPD/clusteradm" /usr/local/bin/clusteradm
fi

echo
echo "== installed versions =="
docker --version || true
kind version || true
kubectl version --client 2>/dev/null | head -n 1 || true
helm version --short || true
clusteradm version || true
argocd version --client 2>/dev/null || true
echo "========================="
echo "NOTE: log out/in (or run: newgrp docker) so your user gets docker group access."
