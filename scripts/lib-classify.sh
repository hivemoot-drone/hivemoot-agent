#!/usr/bin/env bash
# lib-classify.sh — run-once.sh failure classification from log files.
#
# Provides a single authoritative pattern table for classifying startup and
# credential failures emitted by run-once.sh. Both the task runner (run-task.sh)
# and the host controller (controller.sh) classify the same set of errors; this
# module replaces the two previously independent inline copies.
#
# No cross-lib dependencies — sources only standard POSIX utilities.
# Source this file in any script that needs failure classification.

# lib-classify.sh is a sourced library; avoid "return" errors when run directly.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  echo "scripts/lib-classify.sh is a library and should be sourced, not executed." >&2
  exit 0
fi

if [ -n "${HIVEMOOT_LIB_CLASSIFY_LOADED:-}" ]; then
  return 0
fi
HIVEMOOT_LIB_CLASSIFY_LOADED=1

# Classify a task failure from a file containing run-once.sh error output.
#
# Scans for known static error patterns emitted by run-once.sh to stderr and
# prints a safe, pre-defined one-line message. Prints nothing on no match.
# Never returns raw file content — only pre-classified messages.
#
# Usage:
#   msg="$(classify_run_failure_from_file "$log_file")"
#
# Arguments:
#   $1 — path to a file containing run-once.sh stderr or container log output
#
# Pattern ordering rationale:
#   Kilo-specific patterns (when KILO_PROVIDER=X) are checked before standalone
#   provider key patterns (ANTHROPIC_API_KEY is required, etc.) to avoid
#   misclassifying a Kilo run as a Claude/Codex/Gemini failure. The two pattern
#   sets share key names but differ in the surrounding error text.
classify_run_failure_from_file() {
  local file="$1"

  [ -s "$file" ] || return 0

  # run-once.sh: "ANTHROPIC_API_KEY is required when KILO_PROVIDER=anthropic."
  if grep -qF "when KILO_PROVIDER=anthropic" "$file" 2>/dev/null; then
    printf 'Kilo provider API key (ANTHROPIC_API_KEY) is missing for KILO_PROVIDER=anthropic'
    return 0
  fi
  # run-once.sh: "OPENAI_API_KEY is required when KILO_PROVIDER=openai."
  if grep -qF "when KILO_PROVIDER=openai" "$file" 2>/dev/null; then
    printf 'Kilo provider API key (OPENAI_API_KEY) is missing for KILO_PROVIDER=openai'
    return 0
  fi
  # run-once.sh: "GOOGLE_API_KEY is required when KILO_PROVIDER=google."
  if grep -qF "when KILO_PROVIDER=google" "$file" 2>/dev/null; then
    printf 'Kilo provider API key (GOOGLE_API_KEY / GEMINI_API_KEY) is missing for KILO_PROVIDER=google'
    return 0
  fi
  # run-once.sh: "OPENROUTER_API_KEY is required when KILO_PROVIDER=openrouter."
  if grep -qF "when KILO_PROVIDER=openrouter" "$file" 2>/dev/null; then
    printf 'Kilo provider API key (OPENROUTER_API_KEY) is missing for KILO_PROVIDER=openrouter'
    return 0
  fi
  # run-once.sh: "KILO_PROVIDER is required — set KILO_PROVIDER or KILOCODE_TOKEN."
  if grep -qF "KILO_PROVIDER is required" "$file" 2>/dev/null; then
    printf 'KILO_PROVIDER is required — set KILO_PROVIDER or KILOCODE_TOKEN'
    return 0
  fi
  # run-once.sh: "Missing GitHub token..."
  if grep -qF "Missing GitHub token" "$file" 2>/dev/null; then
    printf 'GitHub token is missing'
    return 0
  fi
  # run-once.sh: "Failed to validate GitHub token..."
  if grep -qF "Failed to validate GitHub token" "$file" 2>/dev/null; then
    printf 'GitHub token validation failed — check token scope or installation access'
    return 0
  fi
  # run-once.sh: "GitHub token cannot access target repository..."
  if grep -qF "GitHub token cannot access target repository" "$file" 2>/dev/null; then
    printf 'GitHub token cannot access target repository — check token scope or installation access'
    return 0
  fi
  # run-once.sh: "Failed to clone <repo>..."
  if grep -qF "Failed to clone" "$file" 2>/dev/null; then
    printf 'Failed to clone repository — check token and repo access'
    return 0
  fi
  # run-once.sh: "ANTHROPIC_API_KEY is required" (standalone Claude provider)
  if grep -qF "ANTHROPIC_API_KEY is required" "$file" 2>/dev/null; then
    printf 'Claude provider API key (ANTHROPIC_API_KEY) is missing'
    return 0
  fi
  # run-once.sh: "OPENAI_API_KEY is required" (standalone Codex provider)
  if grep -qF "OPENAI_API_KEY is required" "$file" 2>/dev/null; then
    printf 'Codex provider API key (OPENAI_API_KEY) is missing'
    return 0
  fi
  # run-once.sh: "GOOGLE_API_KEY (or GEMINI_API_KEY) is required" (standalone Gemini)
  if grep -qF "GOOGLE_API_KEY (or GEMINI_API_KEY) is required" "$file" 2>/dev/null; then
    printf 'Gemini provider API key (GOOGLE_API_KEY / GEMINI_API_KEY) is missing'
    return 0
  fi
  # run-once.sh: "subscription credentials not found" or "subscription login not found"
  if grep -qF "subscription credentials not found" "$file" 2>/dev/null || \
     grep -qF "subscription login not found" "$file" 2>/dev/null; then
    printf 'Provider subscription credentials not found — run the matching auth command'
    return 0
  fi
  # run-once.sh: "Failed to configure git credential helper"
  if grep -qF "Failed to configure git credential helper" "$file" 2>/dev/null; then
    printf 'Failed to configure git credentials'
    return 0
  fi

  return 0
}

# Classify a periodic run failure from a run log file.
#
# Scans for quota-exhaustion and rate-limiting patterns emitted during a run
# and prints one of two classification tokens. Prints nothing when no known
# pattern is found; the caller should fall back to the default failure backoff.
#
# Only the last LOG_TAIL_LINES (default 200) lines of the log are scanned.
# Provider-fatal errors land at the end of a run after the CLI exits.
# Limiting the scan window prevents false positives from agent output that
# quotes code or issues containing these token strings.
#
# Return values (via stdout):
#   quota        — daily/billing quota exhausted; use a long backoff (hours)
#   rate_limited — transient rate limit; use a short backoff (minutes)
#   (empty)      — no recognisable pattern; use the default failure backoff
#
# Pattern taxonomy:
#   quota        — TerminalQuotaError, "quota exhausted", billing_hard_limit_reached,
#                  "You have exhausted your capacity", RESOURCE_EXHAUSTED
#   rate_limited — "429 Too Many Requests", rate_limit_exceeded, rate_limit_error,
#                  overloaded_error
#
# Case-insensitive matching is used for both groups so that minor casing
# variations across providers are covered without additional patterns.
#
# Arguments:
#   $1 — path to a run log file
classify_periodic_failure() {
  local file="$1"
  local tail_lines="${LOG_TAIL_LINES:-200}"

  [ -s "$file" ] || return 0

  # Quota-exhaustion patterns: terminal — long backoff (hours to days)
  if tail -n "$tail_lines" "$file" 2>/dev/null | grep -qiF \
       -e 'TerminalQuotaError' \
       -e 'quota exhausted' \
       -e 'billing_hard_limit_reached' \
       -e 'You have exhausted your capacity' \
       -e 'RESOURCE_EXHAUSTED'; then
    printf 'quota'
    return 0
  fi

  # Rate-limit patterns: transient — short backoff (minutes)
  if tail -n "$tail_lines" "$file" 2>/dev/null | grep -qiF \
       -e '429 Too Many Requests' \
       -e 'rate_limit_exceeded' \
       -e 'rate_limit_error' \
       -e 'overloaded_error'; then
    printf 'rate_limited'
    return 0
  fi

  return 0
}

# Exponential backoff for quota-exhaustion failures (daily limit / billing cap).
#
# Arguments (all required):
#   $1 — failure_count : number of consecutive failures (1-based)
#   $2 — floor_secs   : minimum delay in seconds
#   $3 — max_secs     : maximum delay ceiling in seconds
#   $4 — jitter_pct   : percentage of delay to add as random ±jitter (0 to disable)
calculate_quota_backoff_delay() {
  local failure_count="$1"
  local floor_secs="$2"
  local max_secs="$3"
  local jitter_pct="$4"
  local delay="$floor_secs"

  if [ "$failure_count" -le 0 ] || [ "$delay" -le 0 ]; then
    echo 0
    return
  fi

  for ((attempt = 1; attempt < failure_count; attempt++)); do
    if [ "$delay" -ge "$max_secs" ]; then
      delay="$max_secs"
      break
    fi
    delay=$((delay * 2))
  done

  if [ "$delay" -gt "$max_secs" ]; then
    delay="$max_secs"
  fi

  if [ "$jitter_pct" -gt 0 ] && [ "$delay" -gt 0 ]; then
    local jitter=$((delay * jitter_pct / 100))
    if [ "$jitter" -gt 0 ]; then
      local span=$((jitter * 2 + 1))
      local offset=$((RANDOM % span - jitter))
      delay=$((delay + offset))
      if [ "$delay" -lt 1 ]; then
        delay=1
      fi
    fi
  fi

  echo "$delay"
}

# Exponential backoff for transient rate-limit failures (429 / rate_limit_exceeded).
#
# Arguments (all required):
#   $1 — failure_count : number of consecutive failures (1-based)
#   $2 — floor_secs   : minimum delay in seconds
#   $3 — max_secs     : maximum delay ceiling in seconds
#   $4 — jitter_pct   : percentage of delay to add as random ±jitter (0 to disable)
calculate_rate_limit_backoff_delay() {
  local failure_count="$1"
  local floor_secs="$2"
  local max_secs="$3"
  local jitter_pct="$4"
  local delay="$floor_secs"

  if [ "$failure_count" -le 0 ] || [ "$delay" -le 0 ]; then
    echo 0
    return
  fi

  for ((attempt = 1; attempt < failure_count; attempt++)); do
    if [ "$delay" -ge "$max_secs" ]; then
      delay="$max_secs"
      break
    fi
    delay=$((delay * 2))
  done

  if [ "$delay" -gt "$max_secs" ]; then
    delay="$max_secs"
  fi

  if [ "$jitter_pct" -gt 0 ] && [ "$delay" -gt 0 ]; then
    local jitter=$((delay * jitter_pct / 100))
    if [ "$jitter" -gt 0 ]; then
      local span=$((jitter * 2 + 1))
      local offset=$((RANDOM % span - jitter))
      delay=$((delay + offset))
      if [ "$delay" -lt 1 ]; then
        delay=1
      fi
    fi
  fi

  echo "$delay"
}
