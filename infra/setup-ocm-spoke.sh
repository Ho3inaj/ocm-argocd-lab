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

HUB_URL="$(grep -m1 -oE -- '--hub=[^ ]+' "$JOIN_FILE" | cut -d= -f2- || true)"
TOKEN="$(grep -m1 -oE -- '--token=[^ ]+' "$JOIN_FILE" | cut -d= -f2- || true)"

if [ -z "$HUB_URL" ] || [ -z "$TOKEN" ]; then
  echo "ERROR: could not parse --hub/--token from $JOIN_FILE. Contents:" >&2
  cat "$JOIN_FILE" >&2
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

echo "joining '$CLUSTER' to hub $HUB_URL"
clusteradm join \
  --cluster-name="$CLUSTER" \
  --hub="$HUB_URL" \
  --token="$TOKEN" \
  --context "kind-${CLUSTER}" \
  ${WAIT:+"$WAIT"} \
  ${SILENT:+"$SILENT"}

echo
echo "join submitted. Next: on the HUB run  bash infra/setup-ocm-accept.sh"
