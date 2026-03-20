#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
CONTROLLER_FILE="${REPO_ROOT}/scripts/controller.sh"

required_vars=(
  HEALTH_REPORT_URL
  HIVEMOOT_AGENT_TOKEN
  HIVEMOOT_AGENT_TOKEN_FILE
  HEALTH_REPORT_TIMEOUT_SECS
  HEALTH_REPORT_MAX_RETRIES
  HEALTH_REPORT_RUN_SUMMARY
)

fail=0

# Check docker-compose wiring for all required vars.
for var in "${required_vars[@]}"; do
  pattern="^[[:space:]]+${var}:[[:space:]]+\\$\\{${var}:-"
  if ! grep -Eq "$pattern" "$COMPOSE_FILE"; then
    echo "Missing docker-compose env wiring for ${var}" >&2
    fail=1
  fi
done

# Check controller.sh forwards every HEALTH_REPORT_* var via append_env_if_set.
# This catches any future health flag that is documented and compose-wired
# but never forwarded to worker containers.
for var in "${required_vars[@]}"; do
  [[ "$var" == HEALTH_REPORT_* ]] || continue
  if ! grep -qE "^[[:space:]]+append_env_if_set[[:space:]]+${var}([[:space:]]|$)" "$CONTROLLER_FILE"; then
    echo "Missing controller.sh forwarding: append_env_if_set ${var}" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "PASS: health reporting env vars are wired into docker-compose runtime env and controller.sh forwarding"
