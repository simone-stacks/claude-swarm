#!/bin/bash
set -euo pipefail

# Unit tests for publish.sh and lib/publish-github.sh.
# Uses a local git repo and a mock `gh` CLI on PATH; no API
# token or network access required.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLISH_SH="$REPO_ROOT/publish.sh"
LIB_SH="$REPO_ROOT/lib/publish-github.sh"

cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        expected: ${expected}"
        echo "        actual:   ${actual}"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        needle:   ${needle}"
        echo "        haystack: ${haystack}"
        FAIL=$((FAIL + 1))
    fi
}

# Write a mock `gh` CLI to a directory and prepend that
# directory to PATH.  The mock logs every invocation (argv +
# stdin) to $1/call.log and returns canned responses:
#   gh api repos/.../git/ref/heads/<branch>   -> 404 (exit 1)
#   gh api -X POST repos/.../git/refs ...     -> 0 (silent)
#   gh api graphql --input -                  -> canned oid
make_mock_gh() {
    local dir="$1"
    mkdir -p "$dir/bin"
    cat > "$dir/bin/gh" <<'MOCK'
#!/bin/bash
LOG="${MOCK_GH_LOG:-/dev/null}"
printf 'ARGS:' >> "$LOG"
for a in "$@"; do printf ' %q' "$a" >> "$LOG"; done
printf '\n' >> "$LOG"

# Detect: graphql vs REST ref/heads vs REST -X POST refs.
case "$*" in
    *"graphql"*)
        # Drain stdin so the caller's pipe closes cleanly.
        cat >> "$LOG"
        printf '\nEND\n' >> "$LOG"
        echo '{"data":{"createCommitOnBranch":{"commit":{"oid":"deadbeefcafe1234567890abcdef00000000abcd"}}}}'
        exit 0
        ;;
    *"-X POST"*"git/refs"*)
        echo "POST_REFS" >> "$LOG"
        exit 0
        ;;
    *"git/ref/heads/"*)
        # Simulate branch missing (404).  gh's -X behaviour: exit
        # non-zero on 4xx and emit the body on stdout; --jq still
        # parses but yields nothing useful.  Mirror by emitting
        # an empty stdout (jq-friendly) and exiting non-zero.
        echo "GET_REF_404" >> "$LOG"
        exit 1
        ;;
    *)
        echo "UNHANDLED_GH_CALL: $*" >&2
        exit 99
        ;;
esac
MOCK
    chmod +x "$dir/bin/gh"
}

# Seed a fresh local repo with two commits on a feature
# branch that descend from a known base SHA.  Echoes the
# four values "<workdir> <base_sha> <head_sha> <branch>".
seed_repo() {
    local work="$1/work"
    rm -rf "$work"
    git init -q "$work"
    cd "$work"
    git -c user.name=test -c user.email=t@t -c commit.gpgsign=false \
        commit -q --allow-empty -m "init"
    local base
    base=$(git rev-parse HEAD)
    git checkout -q -b feature

    mkdir -p src
    echo "hello" > src/a.txt
    git add src/a.txt
    git -c user.name=test -c user.email=t@t -c commit.gpgsign=false \
        commit -q -m "Add a.txt"

    echo "world" > src/b.txt
    git add src/b.txt
    git -c user.name=test -c user.email=t@t -c commit.gpgsign=false \
        commit -q -m "Add b.txt"

    local head
    head=$(git rev-parse HEAD)
    echo "$work $base $head feature"
}

# ============================================================
echo "=== 1. Structural pins on publish.sh ==="

publish_src=$(cat "$PUBLISH_SH")

assert_contains "sources lib/publish-github.sh" \
    "source \"\$SWARM_DIR/lib/publish-github.sh\"" "$publish_src"
assert_contains "sources lib/check-deps.sh" \
    "source \"\$SWARM_DIR/lib/check-deps.sh\"" "$publish_src"
assert_contains "calls check_deps with git gh jq base64" \
    "check_deps git gh jq base64" "$publish_src"
assert_contains "parses --branch" "--branch)" "$publish_src"
assert_contains "parses --base"   "--base)"   "$publish_src"
assert_contains "parses --head"   "--head)"   "$publish_src"
assert_contains "parses --dry"    "--dry)"    "$publish_src"
assert_contains "validates GH_TOKEN" \
    "GH_TOKEN is required" "$publish_src"
assert_contains "validates GITHUB_REPOSITORY" \
    "GITHUB_REPOSITORY is required" "$publish_src"
assert_contains "calls gh_preflight_blob_size" \
    "gh_preflight_blob_size" "$publish_src"
assert_contains "calls gh_ensure_branch" \
    "gh_ensure_branch" "$publish_src"
assert_contains "calls gh_replay_commits" \
    "gh_replay_commits" "$publish_src"

# ============================================================
echo ""
echo "=== 2. Behavioural: replays N commits via mock gh ==="

MOCK_DIR="$TMPDIR/case2"
make_mock_gh "$MOCK_DIR"
MOCK_LOG="$MOCK_DIR/call.log"
: > "$MOCK_LOG"

read -r workdir base head branch < <(seed_repo "$MOCK_DIR")
cd "$workdir"

set +e
output=$(
    PATH="$MOCK_DIR/bin:$PATH" \
    MOCK_GH_LOG="$MOCK_LOG" \
    GH_TOKEN=fake-token \
    GITHUB_REPOSITORY=owner/repo \
        bash "$PUBLISH_SH" \
            --branch "$branch" --base "$base" --head "$head" 2>&1
)
rc=$?
set -e

assert_eq "publish.sh exits 0 on happy path" "0" "$rc"
assert_contains "output mentions branch ensure" \
    "Ensuring remote branch" "$output"
assert_contains "output mentions replay step" \
    "Replaying commits" "$output"
assert_contains "output names target repo:branch" \
    "owner/repo:feature" "$output"

# Mock recorded the branch-ensure GET then the POST refs create.
assert_contains "ref-heads GET happened" \
    "git/ref/heads/feature" "$(cat "$MOCK_LOG")"
assert_contains "ref create POST happened" \
    "POST_REFS" "$(cat "$MOCK_LOG")"

# Two graphql calls, one per commit in the range.
graphql_calls=$(grep -c '^ARGS:.*graphql' "$MOCK_LOG" || true)
assert_eq "one graphql call per commit" "2" "$graphql_calls"

# ============================================================
echo ""
echo "=== 3. --dry skips API calls ==="

MOCK_DIR="$TMPDIR/case3"
make_mock_gh "$MOCK_DIR"
MOCK_LOG="$MOCK_DIR/call.log"
: > "$MOCK_LOG"

read -r workdir base head branch < <(seed_repo "$MOCK_DIR")
cd "$workdir"

set +e
output=$(
    PATH="$MOCK_DIR/bin:$PATH" \
    MOCK_GH_LOG="$MOCK_LOG" \
    GH_TOKEN=fake-token \
    GITHUB_REPOSITORY=owner/repo \
        bash "$PUBLISH_SH" \
            --branch "$branch" --base "$base" --dry 2>&1
)
rc=$?
set -e

assert_eq "--dry exits 0" "0" "$rc"
assert_contains "--dry mentions dry-run" "dry run" "$output"
assert_eq "--dry made no gh calls" "0" \
    "$(grep -c '^ARGS:' "$MOCK_LOG" || true)"

# ============================================================
echo ""
echo "=== 4. Preflight rejects oversize blob ==="

MOCK_DIR="$TMPDIR/case4"
make_mock_gh "$MOCK_DIR"
MOCK_LOG="$MOCK_DIR/call.log"
: > "$MOCK_LOG"

# Seed a repo, then add a 36 MiB blob (above the 35 MiB
# default ceiling).  Use dd over /dev/zero for a stable size
# and quick generation; the file's contents do not matter.
read -r workdir base head branch < <(seed_repo "$MOCK_DIR")
cd "$workdir"
dd if=/dev/zero of=big.bin bs=1M count=36 status=none
git add big.bin
git -c user.name=test -c user.email=t@t -c commit.gpgsign=false \
    commit -q -m "Add oversize blob"
head=$(git rev-parse HEAD)

set +e
output=$(
    PATH="$MOCK_DIR/bin:$PATH" \
    MOCK_GH_LOG="$MOCK_LOG" \
    GH_TOKEN=fake-token \
    GITHUB_REPOSITORY=owner/repo \
        bash "$PUBLISH_SH" \
            --branch "$branch" --base "$base" --head "$head" 2>&1
)
rc=$?
set -e

assert_eq "oversize blob causes non-zero exit" "true" \
    "$([ "$rc" -ne 0 ] && echo true || echo false)"
assert_contains "error names the offending path" \
    "big.bin" "$output"
assert_contains "error mentions the ceiling" \
    "ceiling" "$output"

# ============================================================
echo ""
echo "=== 5. Empty range exits 0 with no graphql calls ==="

MOCK_DIR="$TMPDIR/case5"
make_mock_gh "$MOCK_DIR"
MOCK_LOG="$MOCK_DIR/call.log"
: > "$MOCK_LOG"

# Init a repo with a single commit; pass HEAD as both base and
# head.  Branch ensure still happens because the script does
# preflight + ensure + replay in order, and the empty range is
# only detected inside gh_replay_commits.  This is intentional:
# ensuring the branch at BASE is a useful side effect even when
# nothing is replayed.
empty_dir="$MOCK_DIR/empty"
git init -q "$empty_dir"
cd "$empty_dir"
git -c user.name=test -c user.email=t@t -c commit.gpgsign=false \
    commit -q --allow-empty -m "init"
empty_sha=$(git rev-parse HEAD)

set +e
output=$(
    PATH="$MOCK_DIR/bin:$PATH" \
    MOCK_GH_LOG="$MOCK_LOG" \
    GH_TOKEN=fake-token \
    GITHUB_REPOSITORY=owner/repo \
        bash "$PUBLISH_SH" \
            --branch any --base "$empty_sha" --head "$empty_sha" 2>&1
)
rc=$?
set -e

assert_eq "empty range exits 0" "0" "$rc"
assert_contains "empty range reports no commits" \
    "No non-merge commits" "$output"
assert_eq "empty range made no graphql calls" "0" \
    "$(grep -c '^ARGS:.*graphql' "$MOCK_LOG" || true)"

# ============================================================
echo ""
echo "=== 6. Missing required env / args ==="

# Missing GH_TOKEN.
set +e
output=$(
    PATH="$TMPDIR:$PATH" \
    GITHUB_REPOSITORY=owner/repo \
        bash "$PUBLISH_SH" --branch x --base y 2>&1
)
rc=$?
set -e
assert_eq "missing GH_TOKEN exits non-zero" "true" \
    "$([ "$rc" -ne 0 ] && echo true || echo false)"
assert_contains "missing GH_TOKEN names it" \
    "GH_TOKEN" "$output"

# Missing GITHUB_REPOSITORY.
set +e
output=$(
    PATH="$TMPDIR:$PATH" \
    GH_TOKEN=fake \
        bash "$PUBLISH_SH" --branch x --base y 2>&1
)
rc=$?
set -e
assert_eq "missing GITHUB_REPOSITORY exits non-zero" "true" \
    "$([ "$rc" -ne 0 ] && echo true || echo false)"
assert_contains "missing GITHUB_REPOSITORY names it" \
    "GITHUB_REPOSITORY" "$output"

# Missing --branch.
set +e
output=$(
    PATH="$TMPDIR:$PATH" \
    GH_TOKEN=fake GITHUB_REPOSITORY=o/r \
        bash "$PUBLISH_SH" --base y 2>&1
)
rc=$?
set -e
assert_eq "missing --branch exits non-zero" "true" \
    "$([ "$rc" -ne 0 ] && echo true || echo false)"
assert_contains "missing --branch names it" \
    "--branch" "$output"

# Missing --base.
set +e
output=$(
    PATH="$TMPDIR:$PATH" \
    GH_TOKEN=fake GITHUB_REPOSITORY=o/r \
        bash "$PUBLISH_SH" --branch x 2>&1
)
rc=$?
set -e
assert_eq "missing --base exits non-zero" "true" \
    "$([ "$rc" -ne 0 ] && echo true || echo false)"
assert_contains "missing --base names it" \
    "--base" "$output"

# Unknown flag.
set +e
output=$(
    PATH="$TMPDIR:$PATH" \
    GH_TOKEN=fake GITHUB_REPOSITORY=o/r \
        bash "$PUBLISH_SH" --branch x --base y --bogus 2>&1
)
rc=$?
set -e
assert_eq "unknown flag exits non-zero" "true" \
    "$([ "$rc" -ne 0 ] && echo true || echo false)"
assert_contains "unknown flag mentions --help" \
    "--help" "$output"

# --help exits 0.
set +e
help_output=$(bash "$PUBLISH_SH" --help 2>&1)
rc=$?
set -e
assert_eq "--help exits 0" "0" "$rc"
assert_contains "--help describes branch flag" \
    "--branch" "$help_output"
assert_contains "--help names GH_TOKEN" \
    "GH_TOKEN" "$help_output"

# ============================================================
echo ""
echo "=== 7. Library public surface is sourceable ==="

# Sourcing the lib alone (without publish.sh) should not error
# and should expose the four documented public functions.
set +e
src_check=$(
    bash -c '
        set -e
        source "$1"
        declare -F gh_publish_range >/dev/null
        declare -F gh_preflight_blob_size >/dev/null
        declare -F gh_ensure_branch >/dev/null
        declare -F gh_replay_commits >/dev/null
        echo OK
    ' _ "$LIB_SH" 2>&1
)
rc=$?
set -e
assert_eq "library sources cleanly" "0" "$rc"
assert_contains "library exports public functions" "OK" "$src_check"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
