#!/usr/bin/env bash

# ============ EDIT ME (one time) ============
export GIT_REPO_URL="https://github.com/YOUR_GITHUB_USERNAME/ocm-argocd-lab.git"
export GIT_REPO_BRANCH="main"
# ============================================

export HUB_IP="192.168.240.10"
export SPOKE1_IP="192.168.240.11"
export SPOKE2_IP="192.168.240.12"

export KIND_VERSION="v0.33.0"
export KUBECTL_VERSION="v1.37.2"
export HELM_VERSION="v3.22.1"
export CLUSTERADM_VERSION="v1.4.0"
export ARGOCD_VERSION="v3.5.6"
export PODINFO_CHART_VERSION="6.17.0"
export PODINFO_REPO="https://stefanprodan.github.io/podinfo"
