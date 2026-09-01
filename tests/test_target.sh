#!/bin/bash
# shellcheck disable=SC2034
set -euo pipefail

# Unit tests for lib/target.sh: the recorded target snapshot must be
# reused by every later phase instead of re-resolving a moving ref.
# Local bare fixtures only -- no network, no Docker.

# Isolate from host gitconfig (signing keys, hooks, templates).
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# shellcheck source=../lib/project.sh
source "$TESTS_DIR/../lib/project.sh"
# shellcheck source=../lib/target.sh
source "$TESTS_DIR/../lib/target.sh"

# --- Fixture: a bare remote whose main moves from A to B. ---

REMOTE_SRC="$TMPDIR/remote-src"
REMOTE_GIT="$TMPDIR/remote.git"
git init -q -b main "$REMOTE_SRC"
git -C "$REMOTE_SRC" -c user.name=t -c user.email=t@t \
    -c commit.gpgsign=false commit -q --allow-empty -m A
SHA_A=$(git -C "$REMOTE_SRC" rev-parse HEAD)
git clone -q --bare "$REMOTE_SRC" "$REMOTE_GIT"
git -C "$REMOTE_SRC" -c user.name=t -c user.email=t@t \
    -c commit.gpgsign=false commit -q --allow-empty -m B
SHA_B=$(git -C "$REMOTE_SRC" rev-parse HEAD)
git -C "$REMOTE_SRC" push -q "$REMOTE_GIT" main

RUNTIME_DIR="$TMPDIR/runtime"
mkdir -p "$RUNTIME_DIR"
TARGET_MIRROR_DIR="$RUNTIME_DIR/target.git"
TARGET_BASE_MIRROR_DIR="$RUNTIME_DIR/target-base.git"
STATE_FILE="$RUNTIME_DIR/swarm-state.json"

write_state() {
    jq -n --arg repo "$1" --arg rev "$2" \
        '{schema:"claude-swarm.state/v1", target_repo:$repo,
          target_rev:$rev, target_rev_base:"",
          target_rev_base_repo:""}' > "$STATE_FILE"
}

reset_target_env() {
    unset TARGET_REPO TARGET_REV TARGET_REV_BASE TARGET_REV_BASE_REPO
    TARGET_MIRROR_ARGS=()
}

echo "=== 1. Moving ref yields to the recorded snapshot ==="

# The state file pins A while main now points at B: a later phase must
# reuse A instead of re-resolving the branch.
write_state "$REMOTE_GIT" "$SHA_A"
TARGET_REPO="$REMOTE_GIT"
TARGET_REV=main
prepare_target_mirrors >/dev/null
assert_eq "recorded sha wins over the moved branch" "$SHA_A" "$TARGET_REV"
assert_eq "mirror holds the pinned commit" "$SHA_A" \
    "$(git -C "$TARGET_MIRROR_DIR" rev-parse "${SHA_A}^{commit}")"
reset_target_env

echo ""
echo "=== 2. A conflicting pinned sha fails closed ==="

write_state "$REMOTE_GIT" "$SHA_A"
_err="$TMPDIR/conflict.err"
TARGET_REPO="$REMOTE_GIT"
TARGET_REV="$SHA_B"
if prepare_target_mirrors >/dev/null 2>"$_err"; then
    echo "  FAIL: conflicting pinned sha accepted"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: conflicting pinned sha refused"
    PASS=$((PASS + 1))
fi
assert_eq "conflict error names the snapshot" "1" \
    "$(grep -c "conflicts with the engagement snapshot $SHA_A" "$_err")"
reset_target_env

echo ""
echo "=== 3. A different target repo fails closed ==="

write_state "$REMOTE_GIT" "$SHA_A"
TARGET_REPO="$TMPDIR/other.git"
TARGET_REV=main
if prepare_target_mirrors >/dev/null 2>"$_err"; then
    echo "  FAIL: conflicting target repo accepted"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: conflicting target repo refused"
    PASS=$((PASS + 1))
fi
reset_target_env

echo ""
echo "=== 4. Empty env adopts the recorded snapshot ==="

write_state "$REMOTE_GIT" "$SHA_A"
prepare_target_mirrors >/dev/null
assert_eq "target repo adopted from state" "$REMOTE_GIT" "$TARGET_REPO"
assert_eq "target rev adopted from state" "$SHA_A" "$TARGET_REV"
reset_target_env

echo ""
echo "=== 5. Existing mirror skips the clone ==="

# The mirror already holds the pinned commit; make the remote
# unavailable so any clone attempt fails loudly.
mv "$REMOTE_GIT" "$REMOTE_GIT.gone"
write_state "$REMOTE_GIT" "$SHA_A"
prepare_target_mirrors >/dev/null
assert_eq "snapshot reused without the remote" "$SHA_A" "$TARGET_REV"
reset_target_env
mv "$REMOTE_GIT.gone" "$REMOTE_GIT"

echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
