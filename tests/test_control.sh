#!/bin/bash
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SWARM_DIR="$(cd "$TESTS_DIR/.." && pwd)"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/swarm-control-test.XXXXXX")
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

echo "=== Versioned control contract ==="
caps=$(CLAUDE_SWARM_MIGRATE_LEGACY=0 "$SWARM_DIR/control.sh" capabilities)
assert_eq "schema" claude-swarm.control/v1 \
    "$(jq -r .schema <<< "$caps")"
jq -e '.operations | index("validate") and index("start") and index("harvest")' \
    >/dev/null <<< "$caps"
ok "required lifecycle operations advertised"

runtime="$TMPROOT/private-runtime"
paths=$(CLAUDE_SWARM_RUNTIME_DIR="$runtime" \
    CLAUDE_SWARM_MIGRATE_LEGACY=0 "$SWARM_DIR/control.sh" paths)
assert_eq "paths schema" claude-swarm.control/v1 \
    "$(jq -r .schema <<< "$paths")"

echo ""
echo "=== Engine-owned driver validation ==="
validate_root="$TMPROOT/validate-root"
git init -q "$validate_root"
mkdir -p "$validate_root/prompts"
printf 'fixture\n' > "$validate_root/prompts/p.md"
cfg="$TMPROOT/fake.json"
cat > "$cfg" <<'EOF'
{
  "prompt": "prompts/p.md",
  "agents": [{"name":"fixture","driver":"fake","model":"fake","count":1}]
}
EOF
SWARM_CONFIG="$cfg" CLAUDE_SWARM_REPO_ROOT="$validate_root" \
    CLAUDE_SWARM_RUNTIME_DIR="$runtime" \
    CLAUDE_SWARM_MIGRATE_LEGACY=0 "$SWARM_DIR/control.sh" validate \
    >/dev/null
ok "fake-driver config validates without credentials"

bad="$TMPROOT/missing-auth.json"
cat > "$bad" <<'EOF'
{
  "prompt": "prompts/p.md",
  "agents": [{"name":"fixture","driver":"gemini-cli","model":"fake","count":1}]
}
EOF
if env -u GEMINI_API_KEY SWARM_CONFIG="$bad" \
        CLAUDE_SWARM_REPO_ROOT="$validate_root" \
        CLAUDE_SWARM_RUNTIME_DIR="$runtime" \
        CLAUDE_SWARM_MIGRATE_LEGACY=0 "$SWARM_DIR/control.sh" validate \
        >/dev/null 2>&1; then
    echo "  FAIL: missing driver credentials accepted" >&2
    exit 1
fi
ok "missing driver credentials refused"

echo ""
echo "=== One host snapshot feeds every container without the reader token ==="
coord="$TMPROOT/coord"
target="$TMPROOT/target"
mkdir -p "$coord" "$target"
git init -q "$coord"
git -C "$coord" -c user.name=test -c user.email=test@example.invalid \
    -c commit.gpgsign=false commit -q --allow-empty -m base
printf 'fixture\n' > "$coord/prompt.md"
git -C "$coord" add prompt.md
git -C "$coord" -c user.name=test -c user.email=test@example.invalid \
    -c commit.gpgsign=false commit -q -m prompt
git init -q "$target"
printf 'target\n' > "$target/target.txt"
git -C "$target" add target.txt
git -C "$target" -c user.name=test -c user.email=test@example.invalid \
    -c commit.gpgsign=false commit -q -m target
git -C "$target" branch -M main
target_sha=$(git -C "$target" rev-parse HEAD)
start_cfg="$TMPROOT/start.json"
cat > "$start_cfg" <<'EOF'
{
  "prompt": "prompt.md",
  "docker_args": [
    "-e", "TARGET_REV=attacker-override",
    "-eTARGET_REPO=attacker-override",
    "-e", "SWARM_READER_TOKEN"
  ],
  "agents": [{"name":"fixture","driver":"fake","model":"fake","count":1}]
}
EOF
mockbin="$TMPROOT/bin"
mkdir -p "$mockbin"
cat > "$mockbin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS"
case "$1" in
  ps) exit 0;;
  inspect) exit 1;;
  build) exit 0;;
  run)
    printf '%s\n' "${TARGET_REV:-}" > "$DOCKER_TARGET_REV"
    echo fixture-container
    exit 0;;
  *) exit 0;;
esac
EOF
chmod +x "$mockbin/docker"
calls="$TMPROOT/docker.calls"
resolved="$TMPROOT/docker.target-rev"
: > "$calls"
start_runtime="$TMPROOT/start-runtime"
PATH="$mockbin:$PATH" DOCKER_CALLS="$calls" DOCKER_TARGET_REV="$resolved" \
    SWARM_CONFIG="$start_cfg" TARGET_REPO="$target" TARGET_REV=main \
    SWARM_READER_TOKEN=reader-secret CLAUDE_SWARM_REPO_ROOT="$coord" \
    CLAUDE_SWARM_RUNTIME_DIR="$start_runtime" \
    CLAUDE_SWARM_MIGRATE_LEGACY=0 "$SWARM_DIR/control.sh" start \
    >/dev/null
assert_eq "target revision resolved once" "$target_sha" "$(cat "$resolved")"
grep -q -- "$start_runtime/target.git:/target-upstream:ro" "$calls"
ok "read-only target mirror mounted"
grep -q 'SWARM_TARGET_MIRROR=/target-upstream' "$calls"
ok "containers clone from the shared mirror"
grep -q -- "TARGET_REV=$target_sha" "$calls"
ok "resolved target commit is engine-owned"
if grep -q 'attacker-override' "$calls"; then
    echo "  FAIL: swarmfile overrode engine target provenance" >&2
    exit 1
fi
ok "conflicting target Docker arguments removed"
if grep -q 'SWARM_READER_TOKEN' "$calls"; then
    echo "  FAIL: reader token forwarding survived Docker-arg filtering" >&2
    exit 1
fi
ok "reader token omitted from Docker configuration"
[ "$(stat -c %a "$start_runtime/target.git")" = 700 ] \
    && ok "target mirror is private"

echo ""
echo "=== Bare replacement checks every engine-owned branch ==="
stranded="$TMPROOT/stranded"
git clone -q "$start_runtime/upstream.git" "$stranded"
git -C "$stranded" checkout -q -b swarm/unique
printf 'stranded\n' > "$stranded/stranded.txt"
git -C "$stranded" add stranded.txt
git -C "$stranded" -c user.name=test -c user.email=test@example.invalid \
    -c commit.gpgsign=false commit -q -m stranded
stranded_tip=$(git -C "$stranded" rev-parse HEAD)
git -C "$stranded" push -q origin HEAD:refs/heads/swarm/unique
if PATH="$mockbin:$PATH" DOCKER_CALLS="$calls" \
    DOCKER_TARGET_REV="$resolved" SWARM_CONFIG="$start_cfg" \
    TARGET_REPO="$target" TARGET_REV=main \
    CLAUDE_SWARM_REPO_ROOT="$coord" \
    CLAUDE_SWARM_RUNTIME_DIR="$start_runtime" \
    CLAUDE_SWARM_MIGRATE_LEGACY=0 "$SWARM_DIR/control.sh" start \
    >/dev/null 2>&1; then
    echo "  FAIL: unique swarm branch was replaced" >&2
    exit 1
fi
assert_eq "unique swarm ref survives refused replacement" "$stranded_tip" \
    "$(git -C "$start_runtime/upstream.git" rev-parse \
      refs/heads/swarm/unique)"

echo ""
echo "==============================="
echo "  ${PASS} passed, 0 failed"
echo "==============================="
