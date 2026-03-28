#!/usr/bin/env bash
# Guard that gh auth setup-git runs after the HOME isolation switch in
# run-once.sh. If the order is reversed the credential helper is written
# into the container HOME, so authenticated git operations under the
# isolated job HOME silently fail.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/run-once.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Find the line numbers for the two anchors.
# shellcheck disable=SC2016  # single-quoted pattern is intentional: grep sees \$ as literal $
home_line="$(grep -n 'export HOME="\$job_home"' "$script" | head -1 | cut -d: -f1)"
setup_git_line="$(grep -n 'gh auth setup-git' "$script" | head -1 | cut -d: -f1)"

[ -n "$home_line" ] || fail "could not find 'export HOME=\"\$job_home\"' in $script"
[ -n "$setup_git_line" ] || fail "could not find 'gh auth setup-git' in $script"

if [ "$home_line" -ge "$setup_git_line" ]; then
  fail "'gh auth setup-git' (line $setup_git_line) must appear after 'export HOME=\"\$job_home\"' (line $home_line) in run-once.sh"
fi

echo "PASS: gh auth setup-git (line $setup_git_line) is after HOME switch (line $home_line)"
