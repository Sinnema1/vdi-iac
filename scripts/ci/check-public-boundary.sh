#!/usr/bin/env bash
#
# Public-repository boundary check.
#
# Enforces the constraint in Agent_Handoff.md section 2: this repository is a
# public reference implementation and must not carry values copied from a
# non-public environment.
#
# This check is deliberately structural. It looks for shapes that are
# org-identifying regardless of the specific organization -- email addresses,
# address literals, internal hostnames, UNC paths, private keys. It does not
# contain a list of any organization's names, because committing such a list to
# a public repository would republish the exact strings it is meant to keep out.
#
# Organization-specific words belong in an untracked local denylist:
#
#   .public-boundary-denylist    one entry per line, '#' comments allowed
#
# Entries are matched as literal fixed strings, case-insensitively, and may
# contain spaces and punctuation. That path is git-ignored, so CI enforces the
# structural rules while a working copy additionally enforces words that must
# never be written down here.
#
# Usage:
#   scripts/ci/check-public-boundary.sh            # scan all tracked files
#   scripts/ci/check-public-boundary.sh FILE...    # scan specific files
#
# The second form is what the hooks use: pre-commit passes the staged blobs and
# commit-msg passes the message file, so both are covered by the same rules.
#
# Exit codes:
#   0  no findings
#   1  findings reported
#   2  the check could not run, or a scan failed
#
# This check fails closed. A grep error is treated as a failed scan, never as a
# clean one.

set -euo pipefail

readonly DENYLIST_FILE=".public-boundary-denylist"

# Paths exempt from scanning. Exact file names only -- never directory prefixes,
# which would create a hiding place for prohibited content.
#
# Both entries define the rules themselves, so scanning them reports their own
# patterns as findings. Nothing else is exempt: the regression tests assemble
# their violating values from fragments precisely so that tests/ stays covered.
readonly -a EXEMPT=(
  ".gitignore"
  "scripts/ci/check-public-boundary.sh"
)

is_exempt() {
  local candidate="$1" exempt
  for exempt in "${EXEMPT[@]}"; do
    [[ "$candidate" == "$exempt" ]] && return 0
  done
  return 1
}

# Collect the files to scan.
#
# Explicit targets and discovered targets are treated differently on purpose. A
# caller naming a path that is missing, unreadable, or a directory has made an
# error, and silently skipping it would report a clean scan of nothing. A path
# from 'git ls-files' may simply be a tracked file deleted in the working tree,
# which is not an error.
declare -a files=()
explicit=0
if (( $# > 0 )); then
  explicit=1
  files=("$@")
else
  command -v git >/dev/null 2>&1 || { echo "error: git not found" >&2; exit 2; }
  while IFS= read -r tracked; do
    files+=("$tracked")
  done < <(git ls-files)
fi

# The ${arr[@]+"${arr[@]}"} form is required because bash 3.2, still the system
# bash on macOS, treats an empty array expansion as an unbound variable under
# 'set -u'.
declare -a scan=()
for file in ${files[@]+"${files[@]}"}; do
  if (( explicit )); then
    if [[ -d "$file" ]]; then
      echo "public-boundary: '$file' is a directory, not a file" >&2
      exit 2
    fi
    if [[ ! -e "$file" ]]; then
      echo "public-boundary: '$file' does not exist" >&2
      exit 2
    fi
    if [[ ! -r "$file" ]]; then
      echo "public-boundary: '$file' is not readable" >&2
      exit 2
    fi
  else
    # A tracked path deleted in the working tree is skipped, not an error.
    [[ -f "$file" ]] || continue
  fi
  is_exempt "$file" && continue
  scan+=("$file")
done

if (( ${#scan[@]} == 0 )); then
  echo "public-boundary: no files to scan"
  exit 0
fi

findings=0

# run_grep VAR_NAME ARGS...
# Runs grep, storing output in the named variable. Distinguishes no-match from
# scanner failure: grep exits 0 on match, 1 on no match, 2+ on error. Anything
# above 1 aborts the check rather than being reported as clean.
run_grep() {
  local __var="$1"; shift
  local __out __status
  set +e
  __out="$(grep "$@" 2>&1)"
  __status=$?
  set -e
  if (( __status > 1 )); then
    echo "public-boundary: scan failed (grep exit $__status)" >&2
    echo "$__out" >&2
    exit 2
  fi
  printf -v "$__var" '%s' "$__out"
}

# emit RULE FINDING_LINES
emit() {
  local rule="$1" hits="$2"
  [[ -z "$hits" ]] && return 0
  echo "--- $rule ---"
  echo "$hits"
  echo
  findings=$(( findings + $(printf '%s\n' "$hits" | wc -l | tr -d ' ') ))
}

# scan_rule RULE PATTERN [ALLOW_PATTERN]
#
# Extracts each individual match with -o and tests that match against
# ALLOW_PATTERN on its own. Filtering whole lines would let a prohibited value
# ride along beside a permitted example on the same line.
scan_rule() {
  local rule="$1" pattern="$2" allow="${3:-}"
  local raw candidate value kept=""

  run_grep raw -noEIi -e "$pattern" -- "${scan[@]}"
  [[ -z "$raw" ]] && return 0

  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    # candidate is FILE:LINE:MATCH -- strip the two leading fields.
    value="${candidate#*:}"
    value="${value#*:}"
    if [[ -n "$allow" ]]; then
      if printf '%s' "$value" | grep -qEi -e "$allow"; then
        continue
      fi
    fi
    kept+="${candidate}"$'\n'
  done <<< "$raw"

  emit "$rule" "${kept%$'\n'}"
}

# Email addresses. Reserved example domains and GitHub noreply are permitted.
scan_rule "email address" \
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
  '@example\.(com|org|net)$|@[A-Za-z0-9.-]*\.example$|@users\.noreply\.github\.com$'

# IPv4 literals. Unspecified, loopback, broadcast and the RFC 5737
# documentation ranges are permitted.
scan_rule "address literal" \
  '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' \
  '^(0\.0\.0\.0|127\.0\.0\.1|255\.255\.255\.255|192\.0\.2\.[0-9]{1,3}|198\.51\.100\.[0-9]{1,3}|203\.0\.113\.[0-9]{1,3})$'

# Hostnames in internal-only namespaces.
scan_rule "internal hostname" \
  '\b[A-Za-z0-9-]+\.(local|corp|internal|intranet|lan|ad|domain)\b'

# UNC paths, which name a real file server and share.
scan_rule "UNC path" \
  '\\\\[A-Za-z0-9._-]+\\'

# Private key material.
scan_rule "private key" \
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'

# Optional local denylist. Entries are literal strings, so punctuation and
# spaces are matched as written rather than interpreted as regex.
if [[ -f "$DENYLIST_FILE" ]]; then
  declare -a term_args=()
  term_count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    # Trim leading and trailing whitespace only; internal spaces are meaningful.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -n "$line" ]]; then
      term_args+=(-e "$line")
      term_count=$(( term_count + 1 ))
    fi
  done < "$DENYLIST_FILE"

  if (( term_count > 0 )); then
    run_grep denyhits -nFIi "${term_args[@]}" -- "${scan[@]}"
    emit "local denylist term" "$denyhits"
  fi

  echo "public-boundary: local denylist applied ($term_count entries)"
else
  echo "public-boundary: no local denylist present, structural rules only"
fi

if (( findings > 0 )); then
  echo "public-boundary: FAILED with $findings finding(s) across ${#scan[@]} file(s)" >&2
  echo "Replace each value with an obviously fictional placeholder before committing." >&2
  exit 1
fi

echo "public-boundary: passed, ${#scan[@]} file(s) scanned"
exit 0
