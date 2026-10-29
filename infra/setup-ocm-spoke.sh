#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/config.sh"

CLUSTER="${1:-}"
JOIN_FILE="${2:-}"

if [ -z "$CLUSTER" ] || [ -z "$JOIN_FILE" ]; then
  echo "usage: bash infra/setup-ocm-spoke.sh <cluster-name> </path/to/ocm-join.txt>" >&2
  exit 1
fi
if [ ! -f "$JOIN_FILE" ]; then
  echo "ERROR: file not found: $JOIN_FILE" >&2
  exit 1
fi

JOIN_LINE="$(grep -m1 'clusteradm join' "$JOIN_FILE" || true)"
if [ -z "$JOIN_LINE" ]; then
  echo "ERROR: no 'clusteradm join' line found in $JOIN_FILE. Contents:" >&2
  cat "$JOIN_FILE" >&2
  exit 1
fi

HUB_URL="$(printf '%s\n' "$JOIN_LINE" | grep -oE -- '--hub-apiserver +[^ ]+' | awk '{print $2}' || true)"
TOKEN="$(printf '%s\n' "$JOIN_LINE" | grep -oE -- '--hub-token +[^ ]+' | awk '{print $2}' || true)"
HUB_STYLE=""
if [ -n "$HUB_URL" ] && [ -n "$TOKEN" ]; then
  HUB_STYLE="--hub-apiserver ${HUB_URL} --hub-token ${TOKEN}"
else
  HUB_URL="$(printf '%s\n' "$JOIN_LINE" | grep -oE -- '--hub=[^ ]+' | cut -d= -f2- || true)"
  TOKEN="$(printf '%s\n' "$JOIN_LINE" | grep -oE -- '--token=[^ ]+' | cut -d= -f2- || true)"
  if [ -n "$HUB_URL" ] && [ -n "$TOKEN" ]; then
    HUB_STYLE="--hub ${HUB_URL} --token ${TOKEN}"
  fi
fi

if [ -z "$HUB_STYLE" ]; then
  echo "ERROR: could not parse hub endpoint/token from $JOIN_FILE. Contents:" >&2
  cat "$JOIN_FILE" >&2
  exit 1
fi

if ! kubectl config get-contexts "kind-${CLUSTER}" >/dev/null 2>&1; then
  echo "ERROR: context 'kind-${CLUSTER}' not found in this machine's kubeconfig." >&2
  echo "  You are probably on the wrong VM. This command must run ON the ${CLUSTER} VM." >&2
  echo "  check: hostname -I   (hub=.10 spoke1=.11 spoke2=.12)" >&2
  exit 1
fi

SILENT=""
if clusteradm join --help 2>&1 | grep -q -- '--silent'; then
  SILENT="--silent"
fi
WAIT=""
if clusteradm join --help 2>&1 | grep -q -- '--wait'; then
  WAIT="--wait"
fi

echo "joining '$CLUSTER' to hub ${HUB_URL}"
clusteradm join $HUB_STYLE \
  --cluster-name="$CLUSTER" \
  --context "kind-${CLUSTER}" \
  ${WAIT:+"$WAIT"} \
  ${SILENT:+"$SILENT"}

echo
echo "join done. Next: on the HUB VM run  bash infra/setup-ocm-accept.sh"
