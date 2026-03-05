#!/usr/bin/env bash
set -euo pipefail

# lib-validate.sh is a sourced library; avoid "return" errors when run directly.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  echo "scripts/lib-validate.sh is a library and should be sourced, not executed." >&2
  exit 0
fi

if [ -n "${HIVEMOOT_LIB_VALIDATE_LOADED:-}" ]; then
  return 0
fi
HIVEMOOT_LIB_VALIDATE_LOADED=1

repo_name_is_valid() {
  local repo_name="$1"
  local repo_segment=""

  if ! printf '%s' "$repo_name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+$'; then
    return 1
  fi

  repo_segment="${repo_name#*/}"
  case "$repo_segment" in
    .|..)
      return 1
      ;;
  esac

  return 0
}

validate_target_repo() {
  local target_repo="$1"

  if [ -z "$target_repo" ]; then
    echo "TARGET_REPO is required. Set it as owner/repo." >&2
    exit 1
  fi

  if ! repo_name_is_valid "$target_repo"; then
    echo "Invalid TARGET_REPO: ${target_repo}. Expected owner/repo." >&2
    exit 1
  fi
}

validate_workspace_root() {
  local workspace_root="$1"

  case "$workspace_root" in
    /*) ;;
    *)
      echo "WORKSPACE_ROOT must be an absolute path" >&2
      exit 1
      ;;
  esac
}

validate_agent_id() {
  local agent_id="$1"

  case "$agent_id" in
    ''|*[!a-zA-Z0-9_-]*)
      echo "Invalid AGENT_ID: ${agent_id}" >&2
      exit 1
      ;;
  esac
}
