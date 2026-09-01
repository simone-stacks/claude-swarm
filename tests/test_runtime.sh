#!/bin/bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SWARM_DIR="$(cd "$TESTS_DIR/.." && pwd)"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/swarm-runtime-test.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
assert_eq() {
    [ "$2" = "$3" ] || {
        echo "  FAIL: $1" >&2
        echo "        expected: $2" >&2
        echo "        actual:   $3" >&2
        exit 1
    }
    ok "$1"
}

# shellcheck source=../lib/project.sh
source "$SWARM_DIR/lib/project.sh"

echo "=== Private runtime paths ==="
runtime="$TMPROOT/private-runtime"
paths=$(CLAUDE_SWARM_RUNTIME_DIR="$runtime" \
    CLAUDE_SWARM_MIGRATE_LEGACY=0 swarm_runtime_paths fixture)
assert_eq "runtime override" "$runtime" \
    "$(sed -n 's/^runtime_dir=//p' <<< "$paths")"
assert_eq "bare stays below runtime" "$runtime/upstream.git" \
    "$(sed -n 's/^bare_repo=//p' <<< "$paths")"
CLAUDE_SWARM_RUNTIME_DIR="$runtime" CLAUDE_SWARM_MIGRATE_LEGACY=0 \
    swarm_runtime_init fixture >/dev/null
assert_eq "runtime mode" 700 "$(stat -c %a "$runtime")"

default_state="$TMPROOT/default-state"
default_runtime=$(HOME="$TMPROOT/home" XDG_STATE_HOME="$default_state" \
    env -u CLAUDE_SWARM_RUNTIME_DIR bash -c \
    'source "$1/lib/project.sh"; swarm_runtime_dir fixture' _ "$SWARM_DIR")
assert_eq "default runtime is persistent XDG state" \
    "$default_state/claude-swarm/fixture" "$default_runtime"

echo ""
echo "=== Legacy state migration is preserving and private ==="
legacy_tmp="$TMPROOT/legacy-tmp"
mkdir -p "$legacy_tmp"
project="migration-$RANDOM"
legacy_bare="$legacy_tmp/${project}-upstream.git"
legacy_state="$legacy_tmp/${project}-swarm.env"
legacy_lock="$legacy_tmp/${project}-engagement.lock"
legacy_mirror="$legacy_tmp/${project}-mirror-nested.git"
legacy_source="$TMPROOT/legacy-source"
# Migration fsck-gates the legacy bare, so the fixture must be a real
# repository rather than a plain directory.
git init -q "$legacy_source"
git -C "$legacy_source" -c user.name=test -c user.email=t@t \
    -c commit.gpgsign=false commit -q --allow-empty -m init
git clone -q --bare "$legacy_source" "$legacy_bare"
mkdir -p "$legacy_mirror"
printf 'state\n' > "$legacy_state"
: > "$legacy_lock"
migrated="$TMPROOT/migrated"
TMPDIR="$legacy_tmp" CLAUDE_SWARM_RUNTIME_DIR="$migrated" \
    swarm_runtime_init "$project" >/dev/null
git -C "$migrated/upstream.git" rev-parse --git-dir >/dev/null \
    && ok "bare repository preserved"
[ -f "$migrated/legacy/swarm.env" ] && ok "legacy state retained without sourcing"
[ -f "$migrated/engagement.lock" ] && ok "unlocked lock migrated"
[ -d "$migrated/legacy/$(basename "$legacy_mirror")" ] \
    && ok "legacy mirror retained for inspection"
assert_eq "migrated bare private" 700 \
    "$(stat -c %a "$migrated/upstream.git")"

echo ""
echo "=== Runtime path attacks fail closed ==="
link="$TMPROOT/runtime-link"
ln -s "$TMPROOT/elsewhere" "$link"
if CLAUDE_SWARM_RUNTIME_DIR="$link" CLAUDE_SWARM_MIGRATE_LEGACY=0 \
        swarm_runtime_init unsafe >/dev/null 2>&1; then
    echo "  FAIL: symlink runtime accepted" >&2
    exit 1
fi
ok "symlink runtime refused"

echo ""
echo "==============================="
echo "  ${PASS} passed, 0 failed"
echo "==============================="
