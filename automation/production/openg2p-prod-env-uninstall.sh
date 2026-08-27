#!/usr/bin/env bash
# =============================================================================
# OpenG2P 3-Node Production — ENVIRONMENT uninstall  (runs ON YOUR LAPTOP)
# =============================================================================
# Thin wrapper around roles/environment/uninstall.sh
#
# Usage:
#   ./openg2p-prod-env-uninstall.sh --config prod-config.yaml
#   ./openg2p-prod-env-uninstall.sh --config prod-config.yaml --full
#   ./openg2p-prod-env-uninstall.sh --config prod-config.yaml --keep-databases
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec bash "${SCRIPT_DIR}/roles/environment/uninstall.sh" "$@"
