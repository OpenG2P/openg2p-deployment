#!/usr/bin/env bash
# =============================================================================
# OpenG2P 3-Node Production — ENVIRONMENT install  (runs ON YOUR LAPTOP)
# =============================================================================
# Thin wrapper around roles/environment/run.sh (phase 1).
#
# Usage:
#   ./openg2p-prod-env-install.sh --config prod-config.yaml
#   ./openg2p-prod.sh --stage environment --config prod-config.yaml
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec bash "${SCRIPT_DIR}/roles/environment/run.sh" --phase 1 "$@"
