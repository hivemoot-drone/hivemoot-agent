#!/usr/bin/env bash
# lib-auth.sh — secret loading and provider auth functions.
# Extracted from lib.sh; see #255.
#
# Dependencies: none (beyond bash builtins and standard env vars).
# Callers must source lib.sh first (for idempotency guards; lib.sh
# has no dependency on lib-auth.sh).
#
# Source guard: safe to source multiple times.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  echo "scripts/lib-auth.sh is a library and should be sourced, not executed." >&2
  exit 0
fi

if [ -n "${HIVEMOOT_LIB_AUTH_LOADED:-}" ]; then
  return 0
fi
HIVEMOOT_LIB_AUTH_LOADED=1

resolve_effective_auth_mode() {
  local provider="$1"
  local configured_auth_mode="${2:-auto}"

  case "$configured_auth_mode" in
    api_key|subscription)
      printf '%s' "$configured_auth_mode"
      return 0
      ;;
    auto|'')
      ;;
    *)
      return 1
      ;;
  esac

  case "$provider" in
    codex)
      if [ -n "${OPENAI_API_KEY:-}" ]; then
        printf 'api_key'
      else
        printf 'subscription'
      fi
      ;;
    gemini)
      if [ -n "${GOOGLE_API_KEY:-}" ] || [ -n "${GEMINI_API_KEY:-}" ]; then
        printf 'api_key'
      else
        printf 'subscription'
      fi
      ;;
    claude)
      if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        printf 'api_key'
      else
        printf 'subscription'
      fi
      ;;
    kilo)
      if [ -n "${KILOCODE_TOKEN:-}" ] || [ -n "${KILO_PROVIDER:-}" ]; then
        printf 'api_key'
      else
        printf 'subscription'
      fi
      ;;
    opencode)
      if [ -n "${OPENCODE_PROVIDER:-}" ]; then
        printf 'api_key'
      else
        printf 'subscription'
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

# Resolve secret value without mutating env so callers can consume a secret
# locally while still forwarding *_FILE to child processes when needed.
resolve_secret_value() {
  local var_name="$1"
  local file_var_name="${var_name}_FILE"
  local var_value="${!var_name:-}"
  local file_value="${!file_var_name:-}"

  if [ -n "$var_value" ] && [ -n "$file_value" ]; then
    echo "Set either ${var_name} or ${file_var_name}, not both." >&2
    return 1
  fi

  if [ -n "$var_value" ]; then
    printf '%s' "$var_value"
    return 0
  fi

  if [ -z "$file_value" ]; then
    return 0
  fi

  if [ ! -f "$file_value" ]; then
    echo "${file_var_name} is set but file does not exist: ${file_value}" >&2
    return 1
  fi

  tr -d '\r\n' < "$file_value"
}

load_secret_from_file() {
  local var_name="$1"
  local file_var_name="${var_name}_FILE"
  local var_value=""

  if ! var_value="$(resolve_secret_value "$var_name")"; then
    exit 1
  fi

  if [ -z "$var_value" ]; then
    return 0
  fi

  printf -v "$var_name" '%s' "$var_value"
  # shellcheck disable=SC2163  # dynamic export of the variable named in $var_name
  export "$var_name"
  # Clear _FILE after promoting to bare var so repeated calls (e.g.
  # run-task.sh → run-once.sh both call load_secret_from_file) don't
  # trip resolve_secret_value's mutual-exclusion guard.
  unset "$file_var_name"
}

# Load all provider API secrets from their corresponding *_FILE env vars.
# Called at startup in every entrypoint (entrypoint.sh, run-loop.sh,
# run-multi.sh, run-once.sh) so new provider keys only need adding here.
load_provider_secrets() {
  local secret_var
  for secret_var in \
    OPENAI_API_KEY \
    GOOGLE_API_KEY \
    GEMINI_API_KEY \
    ANTHROPIC_API_KEY \
    OPENROUTER_API_KEY \
    CLAUDE_CODE_OAUTH_TOKEN \
    KILOCODE_TOKEN \
    ZAI_API_KEY
  do
    load_secret_from_file "$secret_var"
  done
}

preflight_check_provider_auth() {
  local provider="$1"
  local auth_mode="${2:-auto}"
  local failures=0

  # Provider auth check
  case "$provider" in
    codex)
      local resolved="$auth_mode"
      [ "$resolved" = "auto" ] && resolved=$( [ -n "${OPENAI_API_KEY:-}" ] && echo "api_key" || echo "subscription" )
      if [ "$resolved" = "api_key" ] && [ -z "${OPENAI_API_KEY:-}" ]; then
        echo "Pre-flight: OPENAI_API_KEY missing for codex + api_key mode." >&2
        failures=$((failures + 1))
      fi
      ;;
    gemini)
      local resolved="$auth_mode"
      [ "$resolved" = "auto" ] && resolved=$( { [ -n "${GOOGLE_API_KEY:-}" ] || [ -n "${GEMINI_API_KEY:-}" ]; } && echo "api_key" || echo "subscription" )
      if [ "$resolved" = "api_key" ] && [ -z "${GOOGLE_API_KEY:-}" ] && [ -z "${GEMINI_API_KEY:-}" ]; then
        echo "Pre-flight: GOOGLE_API_KEY/GEMINI_API_KEY missing for gemini + api_key mode." >&2
        failures=$((failures + 1))
      fi
      ;;
    claude)
      local resolved="$auth_mode"
      [ "$resolved" = "auto" ] && resolved=$( [ -n "${ANTHROPIC_API_KEY:-}" ] && echo "api_key" || echo "subscription" )
      if [ "$resolved" = "api_key" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        echo "Pre-flight: ANTHROPIC_API_KEY missing for claude + api_key mode." >&2
        failures=$((failures + 1))
      fi
      ;;
    kilo)
      if [ -z "${KILOCODE_TOKEN:-}" ]; then
        if [ -z "${KILO_PROVIDER:-}" ]; then
          echo "Pre-flight: KILO_PROVIDER is required for kilo (unless KILOCODE_TOKEN is set for gateway mode)." >&2
          failures=$((failures + 1))
        else
          case "${KILO_PROVIDER}" in
            anthropic)
              if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
                echo "Pre-flight: ANTHROPIC_API_KEY missing for KILO_PROVIDER=anthropic." >&2
                failures=$((failures + 1))
              fi
              ;;
            openai)
              if [ -z "${OPENAI_API_KEY:-}" ]; then
                echo "Pre-flight: OPENAI_API_KEY missing for KILO_PROVIDER=openai." >&2
                failures=$((failures + 1))
              fi
              ;;
            google)
              if [ -z "${GOOGLE_API_KEY:-}" ] && [ -z "${GEMINI_API_KEY:-}" ]; then
                echo "Pre-flight: GOOGLE_API_KEY/GEMINI_API_KEY missing for KILO_PROVIDER=google." >&2
                failures=$((failures + 1))
              fi
              ;;
            openrouter)
              if [ -z "${OPENROUTER_API_KEY:-}" ]; then
                echo "Pre-flight: OPENROUTER_API_KEY missing for KILO_PROVIDER=openrouter." >&2
                failures=$((failures + 1))
              fi
              ;;
          esac
        fi
      fi
      ;;
    opencode)
      if [ -n "${OPENCODE_PROVIDER:-}" ]; then
        case "${OPENCODE_PROVIDER}" in
          zai)
            if [ -z "${ZAI_API_KEY:-}" ]; then
              echo "Pre-flight: ZAI_API_KEY missing for OPENCODE_PROVIDER=zai." >&2
              failures=$((failures + 1))
            fi
            ;;
        esac
      elif [ ! -f "/home/node/.local/share/opencode/auth.json" ]; then
        echo "Pre-flight: OpenCode auth not configured. Set OPENCODE_PROVIDER + API key, or run: opencode auth login." >&2
        failures=$((failures + 1))
      fi
      ;;
  esac

  return "$failures"
}
