#!/usr/bin/env bash
#
# Regression tests for scripts/ci/check-public-boundary.sh.
#
# Fixtures are generated into a temporary directory at run time, and the
# violating values are assembled from fragments that do not match any rule on
# their own. That is deliberate: it means this file is scanned by the very check
# it tests, with no exemption, so tests/ cannot become a hiding place for
# prohibited content.
#
# When adding a case, keep prohibited values fragmented. If you paste a whole
# violating value as a literal, the boundary check will report this file -- that
# is the guardrail working, not a false positive.
#
# Usage: tests/test-public-boundary.sh
# Exit codes: 0 all tests passed, 1 one or more failed

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly CHECK="$REPO_ROOT/scripts/ci/check-public-boundary.sh"

WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "$WORK"' EXIT

# --- fragmented fixture values ---------------------------------------------
# Each is inert until concatenated. None of the fragments matches a rule alone.
#
# Backslashes come from octal escapes rather than literals, so this file does
# not itself contain a UNC-shaped string. Declaration and assignment are kept
# separate because a command substitution in a 'readonly' assignment masks its
# exit status.

BS="$(printf '\134')"
readonly BS

BAD_EMAIL="admin@acme-$(printf 'internal').test"
readonly BAD_EMAIL

BAD_IP="10.42$(printf '.')7.19"
readonly BAD_IP

BAD_HOST="vc01$(printf '.')corp"
readonly BAD_HOST

BAD_UNC="${BS}${BS}fileserver01${BS}images"
readonly BAD_UNC

BAD_KEY="-----BEGIN $(printf 'RSA') PRIVATE KEY-----"
readonly BAD_KEY

passed=0
failed=0

# assert_exit EXPECTED_CODE DESCRIPTION FILE...
assert_exit() {
  local expected="$1" desc="$2"; shift 2
  local status=0
  "$CHECK" "$@" >"$WORK/.out" 2>&1 || status=$?
  if (( status == expected )); then
    echo "  ok    $desc"
    passed=$(( passed + 1 ))
  else
    echo "  FAIL  $desc (expected exit $expected, got $status)"
    sed 's/^/          /' "$WORK/.out"
    failed=$(( failed + 1 ))
  fi
}

# assert_reports RULE DESCRIPTION FILE...
# Requires exit 1 and the named rule in the output.
assert_reports() {
  local rule="$1" desc="$2"; shift 2
  local status=0
  "$CHECK" "$@" >"$WORK/.out" 2>&1 || status=$?
  if (( status == 1 )) && grep -q -- "--- $rule ---" "$WORK/.out"; then
    echo "  ok    $desc"
    passed=$(( passed + 1 ))
  else
    echo "  FAIL  $desc (exit $status, rule '$rule' not reported)"
    sed 's/^/          /' "$WORK/.out"
    failed=$(( failed + 1 ))
  fi
}

echo "public-boundary regression tests"

# --- structural rules fire -------------------------------------------------

printf 'Contact ops at %s for access.\n' "$BAD_EMAIL" > "$WORK/email.md"
assert_reports "email address" "email address is reported" "$WORK/email.md"

printf 'The build host is %s in the lab.\n' "$BAD_IP" > "$WORK/ip.md"
assert_reports "address literal" "address literal is reported" "$WORK/ip.md"

printf 'Connect to %s for the catalog.\n' "$BAD_HOST" > "$WORK/host.md"
assert_reports "internal hostname" "internal hostname is reported" "$WORK/host.md"

printf 'Packages live on %s.\n' "$BAD_UNC" > "$WORK/unc.md"
assert_reports "UNC path" "UNC path is reported" "$WORK/unc.md"

printf '%s\n' "$BAD_KEY" > "$WORK/key.md"
assert_reports "private key" "private key header is reported" "$WORK/key.md"

# --- permitted values do not fire ------------------------------------------

{
  printf 'Mail someone@example.com for questions.\n'
  printf 'Loopback is 127.0.0.1 and unspecified is 0.0.0.0.\n'
  printf 'Documentation ranges 192.0.2.15, 198.51.100.4, 203.0.113.7.\n'
  printf 'Commits use 1234567+someone@users.noreply.github.com here.\n'
} > "$WORK/allowed.md"
assert_exit 0 "permitted example values pass" "$WORK/allowed.md"

# --- the regression that matters -------------------------------------------
#
# A prohibited value beside a permitted one on the SAME line must still be
# reported. Filtering whole lines silently dropped these.

printf 'Write to someone@example.com or to %s today.\n' "$BAD_EMAIL" \
  > "$WORK/mixed-email.md"
assert_reports "email address" \
  "prohibited email beside a permitted one is still reported" \
  "$WORK/mixed-email.md"

printf 'Loopback 127.0.0.1 forwards to %s on the lab network.\n' "$BAD_IP" \
  > "$WORK/mixed-ip.md"
assert_reports "address literal" \
  "prohibited address beside a permitted one is still reported" \
  "$WORK/mixed-ip.md"

# --- denylist behavior ------------------------------------------------------

clean_file="$WORK/deny-target.md"
printf 'This document mentions Northwind Trading Co. in passing.\n' > "$clean_file"

run_with_denylist() {
  local content="$1"; shift
  local dir="$WORK/denyrun"
  rm -rf "$dir"; mkdir -p "$dir"
  printf '%s' "$content" > "$dir/.public-boundary-denylist"
  local status=0
  ( cd "$dir" && "$CHECK" "$@" ) >"$WORK/.out" 2>&1 || status=$?
  return $status
}

assert_denylist() {
  local expected="$1" desc="$2" content="$3"; shift 3
  local status=0
  run_with_denylist "$content" "$@" || status=$?
  if (( status == expected )); then
    echo "  ok    $desc"
    passed=$(( passed + 1 ))
  else
    echo "  FAIL  $desc (expected exit $expected, got $status)"
    sed 's/^/          /' "$WORK/.out"
    failed=$(( failed + 1 ))
  fi
}

# A multiword phrase must survive with its internal spaces intact.
assert_denylist 1 "multiword denylist entry is matched" \
  $'# local\nNorthwind Trading\n' "$clean_file"

# Punctuation is literal, not regex: 'a.c' must not match 'abc'.
printf 'The abc baseline is unrelated.\n' > "$WORK/literal.md"
assert_denylist 0 "denylist entries match literally, not as regex" \
  $'a.c\n' "$WORK/literal.md"

# Comments and blank lines are ignored.
assert_denylist 0 "comment-only denylist yields no findings" \
  $'# only a comment\n\n' "$clean_file"

# --- fail-closed behavior ---------------------------------------------------

# An unreadable file is a failed scan, not a clean one.
printf 'placeholder\n' > "$WORK/unreadable.md"
chmod 000 "$WORK/unreadable.md"
if [[ -r "$WORK/unreadable.md" ]]; then
  echo "  skip  unreadable file fails closed (user bypasses mode bits)"
else
  assert_exit 2 "unreadable file fails closed" "$WORK/unreadable.md"
fi
chmod 644 "$WORK/unreadable.md"

# An explicitly named target that does not exist is a caller error, not a pass.
assert_exit 2 "explicitly named missing target fails closed" \
  "$WORK/does-not-exist.md"

# A directory passed as an explicit target is likewise a caller error.
mkdir -p "$WORK/adir"
assert_exit 2 "explicitly named directory fails closed" "$WORK/adir"

# --- edge cases -------------------------------------------------------------

printf 'Nothing to see here.\n' > "$WORK/clean.md"
assert_exit 0 "clean file passes" "$WORK/clean.md"

echo
echo "passed: $passed  failed: $failed"
(( failed == 0 )) || exit 1
