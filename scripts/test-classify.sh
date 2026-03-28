#!/usr/bin/env bash
# Tests for scripts/lib-classify.sh — classify_run_failure_from_file()
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=scripts/lib-classify.sh
. "${SCRIPT_DIR}/lib-classify.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: ${label}" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    exit 1
  fi
}

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

echo "Running lib-classify.sh tests"

# --- empty / missing file ---

assert_eq "" "$(classify_run_failure_from_file "${tmp}/nonexistent")" \
  "nonexistent file → empty"

touch "${tmp}/empty"
assert_eq "" "$(classify_run_failure_from_file "${tmp}/empty")" \
  "empty file → empty"

# --- Kilo provider patterns (checked before standalone provider patterns) ---

printf 'ANTHROPIC_API_KEY is required when KILO_PROVIDER=anthropic.\n' \
  > "${tmp}/kilo-anthropic"
assert_eq \
  "Kilo provider API key (ANTHROPIC_API_KEY) is missing for KILO_PROVIDER=anthropic" \
  "$(classify_run_failure_from_file "${tmp}/kilo-anthropic")" \
  "Kilo anthropic"

printf 'OPENAI_API_KEY is required when KILO_PROVIDER=openai.\n' \
  > "${tmp}/kilo-openai"
assert_eq \
  "Kilo provider API key (OPENAI_API_KEY) is missing for KILO_PROVIDER=openai" \
  "$(classify_run_failure_from_file "${tmp}/kilo-openai")" \
  "Kilo openai"

printf 'GOOGLE_API_KEY is required when KILO_PROVIDER=google.\n' \
  > "${tmp}/kilo-google"
assert_eq \
  "Kilo provider API key (GOOGLE_API_KEY / GEMINI_API_KEY) is missing for KILO_PROVIDER=google" \
  "$(classify_run_failure_from_file "${tmp}/kilo-google")" \
  "Kilo google"

printf 'OPENROUTER_API_KEY is required when KILO_PROVIDER=openrouter.\n' \
  > "${tmp}/kilo-openrouter"
assert_eq \
  "Kilo provider API key (OPENROUTER_API_KEY) is missing for KILO_PROVIDER=openrouter" \
  "$(classify_run_failure_from_file "${tmp}/kilo-openrouter")" \
  "Kilo openrouter"

printf 'KILO_PROVIDER is required — set KILO_PROVIDER or KILOCODE_TOKEN.\n' \
  > "${tmp}/kilo-missing"
assert_eq \
  "KILO_PROVIDER is required — set KILO_PROVIDER or KILOCODE_TOKEN" \
  "$(classify_run_failure_from_file "${tmp}/kilo-missing")" \
  "KILO_PROVIDER missing"

# --- GitHub token patterns ---

printf 'Missing GitHub token for agent.\n' > "${tmp}/gh-missing"
assert_eq \
  "GitHub token is missing" \
  "$(classify_run_failure_from_file "${tmp}/gh-missing")" \
  "Missing GitHub token"

printf 'Failed to validate GitHub token: 401\n' > "${tmp}/gh-validate"
assert_eq \
  "GitHub token validation failed — check token scope or installation access" \
  "$(classify_run_failure_from_file "${tmp}/gh-validate")" \
  "GitHub token validation failed"

printf 'GitHub token cannot access target repository foo/bar\n' > "${tmp}/gh-access"
assert_eq \
  "GitHub token cannot access target repository — check token scope or installation access" \
  "$(classify_run_failure_from_file "${tmp}/gh-access")" \
  "GitHub token access denied"

# --- Clone failure ---

printf 'Failed to clone https://github.com/foo/bar\n' > "${tmp}/clone-fail"
assert_eq \
  "Failed to clone repository — check token and repo access" \
  "$(classify_run_failure_from_file "${tmp}/clone-fail")" \
  "Failed to clone"

# --- Standalone provider key patterns ---

printf 'ANTHROPIC_API_KEY is required\n' > "${tmp}/claude-key"
assert_eq \
  "Claude provider API key (ANTHROPIC_API_KEY) is missing" \
  "$(classify_run_failure_from_file "${tmp}/claude-key")" \
  "ANTHROPIC_API_KEY missing"

printf 'OPENAI_API_KEY is required\n' > "${tmp}/codex-key"
assert_eq \
  "Codex provider API key (OPENAI_API_KEY) is missing" \
  "$(classify_run_failure_from_file "${tmp}/codex-key")" \
  "OPENAI_API_KEY missing"

printf 'GOOGLE_API_KEY (or GEMINI_API_KEY) is required\n' > "${tmp}/gemini-key"
assert_eq \
  "Gemini provider API key (GOOGLE_API_KEY / GEMINI_API_KEY) is missing" \
  "$(classify_run_failure_from_file "${tmp}/gemini-key")" \
  "GOOGLE_API_KEY missing"

# --- Subscription ---

printf 'subscription credentials not found\n' > "${tmp}/sub-creds"
assert_eq \
  "Provider subscription credentials not found — run the matching auth command" \
  "$(classify_run_failure_from_file "${tmp}/sub-creds")" \
  "subscription credentials not found"

printf 'subscription login not found\n' > "${tmp}/sub-login"
assert_eq \
  "Provider subscription credentials not found — run the matching auth command" \
  "$(classify_run_failure_from_file "${tmp}/sub-login")" \
  "subscription login not found"

# --- Git credential helper ---

printf 'Failed to configure git credential helper\n' > "${tmp}/git-cred"
assert_eq \
  "Failed to configure git credentials" \
  "$(classify_run_failure_from_file "${tmp}/git-cred")" \
  "git credential helper"

# --- Unknown error returns empty ---

printf 'Some completely unknown failure\n' > "${tmp}/unknown"
assert_eq "" \
  "$(classify_run_failure_from_file "${tmp}/unknown")" \
  "unknown error → empty"

# --- Kilo pattern takes priority over standalone provider pattern ---
# A file that contains both "when KILO_PROVIDER=anthropic" and "ANTHROPIC_API_KEY
# is required" must produce the Kilo-specific message, not the standalone one.

printf 'ANTHROPIC_API_KEY is required when KILO_PROVIDER=anthropic. Also: ANTHROPIC_API_KEY is required\n' \
  > "${tmp}/kilo-priority"
result="$(classify_run_failure_from_file "${tmp}/kilo-priority")"
if [ "$result" != "Kilo provider API key (ANTHROPIC_API_KEY) is missing for KILO_PROVIDER=anthropic" ]; then
  fail "Kilo pattern must take priority over standalone provider pattern (got: ${result})"
fi

# ── classify_periodic_failure() ────────────────────────────────────────────────

echo "Running classify_periodic_failure() tests"

# empty / missing
assert_eq "" "$(classify_periodic_failure "${tmp}/nonexistent")" \
  "classify_periodic_failure: nonexistent file → empty"

touch "${tmp}/pf-empty"
assert_eq "" "$(classify_periodic_failure "${tmp}/pf-empty")" \
  "classify_periodic_failure: empty file → empty"

# --- quota patterns ---

printf 'Error: TerminalQuotaError\n' > "${tmp}/pf-terminal-quota"
assert_eq "quota" "$(classify_periodic_failure "${tmp}/pf-terminal-quota")" \
  "classify_periodic_failure: TerminalQuotaError → quota"

printf 'API quota exhausted for this project\n' > "${tmp}/pf-quota-exhausted"
assert_eq "quota" "$(classify_periodic_failure "${tmp}/pf-quota-exhausted")" \
  "classify_periodic_failure: quota exhausted → quota"

printf 'billing_hard_limit_reached: spend limit exceeded\n' > "${tmp}/pf-billing"
assert_eq "quota" "$(classify_periodic_failure "${tmp}/pf-billing")" \
  "classify_periodic_failure: billing_hard_limit_reached → quota"

printf 'You have exhausted your capacity for this month\n' > "${tmp}/pf-capacity"
assert_eq "quota" "$(classify_periodic_failure "${tmp}/pf-capacity")" \
  "classify_periodic_failure: You have exhausted your capacity → quota"

printf 'RESOURCE_EXHAUSTED: daily compute quota exceeded\n' > "${tmp}/pf-resource-exhausted"
assert_eq "quota" "$(classify_periodic_failure "${tmp}/pf-resource-exhausted")" \
  "classify_periodic_failure: RESOURCE_EXHAUSTED → quota"

# case-insensitive quota match
printf 'terminalquotaerror\n' > "${tmp}/pf-quota-lower"
assert_eq "quota" "$(classify_periodic_failure "${tmp}/pf-quota-lower")" \
  "classify_periodic_failure: lower-case TerminalQuotaError → quota"

# --- rate_limited patterns ---

printf 'HTTP/1.1 429 Too Many Requests\n' > "${tmp}/pf-429"
assert_eq "rate_limited" "$(classify_periodic_failure "${tmp}/pf-429")" \
  "classify_periodic_failure: 429 Too Many Requests → rate_limited"

printf 'error: rate_limit_exceeded on this endpoint\n' > "${tmp}/pf-rle"
assert_eq "rate_limited" "$(classify_periodic_failure "${tmp}/pf-rle")" \
  "classify_periodic_failure: rate_limit_exceeded → rate_limited"

printf 'rate_limit_error: too many requests\n' > "${tmp}/pf-rle2"
assert_eq "rate_limited" "$(classify_periodic_failure "${tmp}/pf-rle2")" \
  "classify_periodic_failure: rate_limit_error → rate_limited"

printf 'overloaded_error: server overloaded\n' > "${tmp}/pf-overloaded"
assert_eq "rate_limited" "$(classify_periodic_failure "${tmp}/pf-overloaded")" \
  "classify_periodic_failure: overloaded_error → rate_limited"

# case-insensitive rate_limited match
printf 'OVERLOADED_ERROR\n' > "${tmp}/pf-overloaded-upper"
assert_eq "rate_limited" "$(classify_periodic_failure "${tmp}/pf-overloaded-upper")" \
  "classify_periodic_failure: upper-case OVERLOADED_ERROR → rate_limited"

# --- quota takes priority over rate_limited ---
# A log that contains both a quota pattern and a rate-limit pattern must
# produce quota, because quota is checked first.

printf 'TerminalQuotaError\n429 Too Many Requests\n' > "${tmp}/pf-both"
assert_eq "quota" "$(classify_periodic_failure "${tmp}/pf-both")" \
  "classify_periodic_failure: quota pattern takes priority over rate_limited"

# --- unknown pattern → empty ---

printf 'Some unexpected failure message\n' > "${tmp}/pf-unknown"
assert_eq "" "$(classify_periodic_failure "${tmp}/pf-unknown")" \
  "classify_periodic_failure: unknown pattern → empty"

echo "All lib-classify.sh tests passed."
