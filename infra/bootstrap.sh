#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: run as root:  sudo bash infra/bootstrap.sh" >&2
  exit 1
fi

swapoff -a || true
sed -ri 's/^([^#].*[[:space:]]swap[[:space:]].*)$/#\1/' /etc/fstab || true

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates gnupg lsb-release apt-transport-https git jq tar gzip

if ! command -v docker >/dev/null 2>&1; then
  if ! curl -fsSL https://get.docker.com | sh; then
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

curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
chmod 755 /usr/local/bin/kubectl

curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" -o /usr/local/bin/kind
chmod 755 /usr/local/bin/kind

curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64" -o /usr/local/bin/argocd
chmod 755 /usr/local/bin/argocd

curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o "$TMPD/helm.tar.gz"
tar -xzf "$TMPD/helm.tar.gz" -C "$TMPD"
install -m 755 "$TMPD/linux-amd64/helm" /usr/local/bin/helm

curl -fsSL "https://github.com/open-cluster-management-io/clusteradm/releases/download/${CLUSTERADM_VERSION}/clusteradm_linux_amd64.tar.gz" -o "$TMPD/clusteradm.tar.gz"
tar -xzf "$TMPD/clusteradm.tar.gz" -C "$TMPD"
install -m 755 "$TMPD/clusteradm" /usr/local/bin/clusteradm

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
