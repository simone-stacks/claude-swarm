#!/usr/bin/env bash
# Stable, machine-readable control plane for hosts embedding claude-swarm.
set -euo pipefail

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/project.sh
source "$SWARM_DIR/lib/project.sh"

usage() {
    cat <<'HELP'
Usage: control.sh <capabilities|paths|project-id|containers|init|validate|start|stop|harvest|status|dashboard|post-process|cleanup>

The query commands (capabilities, paths, project-id, containers) are
side-effect free. init is the documented exception: it creates the
runtime directory and may migrate legacy /tmp state. Lifecycle commands
delegate to the engine version that owns this control script.
HELP
}

repo_root() {
    local super
    if [ -n "${CLAUDE_SWARM_REPO_ROOT:-}" ]; then
        git -C "$CLAUDE_SWARM_REPO_ROOT" rev-parse --show-toplevel
        return
    fi
    super=$(git -C "$SWARM_DIR" rev-parse \
        --show-superproject-working-tree 2>/dev/null || true)
    if [ -n "$super" ]; then
        printf '%s\n' "$super"
    else
        git -C "$SWARM_DIR" rev-parse --show-toplevel
    fi
}

project_id() {
    swarm_project_resolve "$(repo_root)"
}

json_paths() {
    local initialize="${1:-0}" project runtime engagement=""
    project=$(project_id)
    if [ "$initialize" = 1 ]; then
        runtime=$(swarm_runtime_init "$project" "$(repo_root)")
    else
        runtime=$(swarm_runtime_dir "$project")
    fi
    # Pure read: a missing or unreadable state file reports null.
    if [ -r "$runtime/swarm-state.json" ]; then
        engagement=$(jq -r '.engagement // empty' \
            "$runtime/swarm-state.json" 2>/dev/null || true)
    fi
    jq -n \
        --arg schema "claude-swarm.control/v1" \
        --arg project "$project" \
        --arg runtime "$runtime" \
        --arg bare "$runtime/upstream.git" \
        --arg lock "$runtime/engagement.lock" \
        --arg state "$runtime/swarm-state.json" \
        --arg mirrors "$runtime/mirrors" \
        --arg image "${project}-agent" \
        --arg control "$SWARM_DIR/control.sh" \
        --arg engine "$SWARM_DIR" \
        --arg engagement "$engagement" \
        '{schema:$schema, project:$project, runtime_dir:$runtime,
          bare_repo:$bare, lock_file:$lock, state_file:$state,
          mirror_dir:$mirrors, image_name:$image,
          container_prefix:($image + "-"), control_path:$control,
          engine_dir:$engine,
          engagement:($engagement | if length > 0 then . else null end)}'
}

project_containers() {
    local project="$1" image names
    image="${project}-agent"
    names=$({
        docker ps -a --filter "label=org.claude-swarm.project=${project}" \
            --format '{{.Names}}' 2>/dev/null || true
        docker ps -a --filter "name=^${image}-" \
            --format '{{.Names}}' 2>/dev/null || true
    } | awk 'NF && !seen[$0]++')
    printf '%s\n' "$names" | sed '/^$/d'
}

stop_project() {
    local project timeout name state
    project=$(project_id)
    timeout="${SWARM_STOP_TIMEOUT:-60}"
    echo "--- Stopping ${project} agents (grace ${timeout}s) ---"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        state=$(docker inspect -f '{{.State.Status}}' "$name" \
            2>/dev/null || echo missing)
        if [ "$state" = running ]; then
            docker stop -t "$timeout" "$name" >/dev/null
            echo "  stopped $name"
        else
            echo "  $name $state"
        fi
    done < <(project_containers "$project")
}

status_project() {
    local project name state code
    project=$(project_id)
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        state=$(docker inspect -f '{{.State.Status}}' "$name" \
            2>/dev/null || echo missing)
        code=$(docker inspect -f '{{.State.ExitCode}}' "$name" \
            2>/dev/null || echo unknown)
        printf '%-36s %s exit=%s\n' "$name" "$state" "$code"
    done < <(project_containers "$project")
}

json_containers() {
    local project name state code oom engagement role index
    project=$(project_id)
    {
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            state=$(docker inspect -f '{{.State.Status}}' "$name" \
                2>/dev/null || echo unknown)
            code=$(docker inspect -f '{{.State.ExitCode}}' "$name" \
                2>/dev/null || echo 125)
            oom=$(docker inspect -f '{{.State.OOMKilled}}' "$name" \
                2>/dev/null || echo true)
            [[ "$code" =~ ^[0-9]+$ ]] || code=125
            case "$oom" in true|false) ;; *) oom=true;; esac
            engagement=$(docker inspect -f \
                '{{index .Config.Labels "org.claude-swarm.engagement"}}' \
                "$name" 2>/dev/null || true)
            role=$(docker inspect -f \
                '{{index .Config.Labels "org.claude-swarm.role"}}' \
                "$name" 2>/dev/null || true)
            index=$(docker inspect -f \
                '{{index .Config.Labels "org.claude-swarm.agent-index"}}' \
                "$name" 2>/dev/null || true)
            if [ -z "$role" ]; then
                case "$name" in
                    *-agent-post) role=post-process ;;
                    *-agent-interactive-*) role=interactive ;;
                    *-agent-[0-9]*) role=agent; index="${name##*-}" ;;
                    *) role=unknown ;;
                esac
            fi
            jq -nc --arg name "$name" --arg status "$state" \
                --argjson exit_code "${code:-125}" \
                --argjson oom "${oom:-true}" \
                --arg engagement "$engagement" --arg role "$role" \
                --arg index "$index" \
                '{name:$name,status:$status,exit_code:$exit_code,
                  oom_killed:$oom,engagement:$engagement,role:$role,
                  agent_index:($index | if length > 0 then . else null end)}'
        done < <(project_containers "$project")
    } | jq -s --arg schema "claude-swarm.containers/v1" \
        --arg project "$project" \
        '{schema:$schema,project:$project,containers:.}'
}

case "${1:-}" in
    capabilities)
        jq -n \
            --arg schema "claude-swarm.control/v1" \
            --arg version "$(cat "$SWARM_DIR/VERSION")" \
            '{schema:$schema, version:$version,
              operations:["paths","init","project-id","containers","start","stop",
                          "validate","harvest","status","dashboard",
                          "post-process","cleanup"],
              features:["private-runtime-v1","recursive-submodules-v1",
                        "signed-agent-commits-v1","rescue-first-replace-v1",
                        "shared-target-snapshot-v1","reader-token-host-only-v1",
                        "json-state-v1"]}'
        ;;
    paths) json_paths ;;
    init) json_paths 1 ;;
    project-id) project_id; printf '\n' ;;
    containers) json_containers ;;
    validate) shift; cd "$(repo_root)"; exec "$SWARM_DIR/launch.sh" validate "$@" ;;
    start) shift; cd "$(repo_root)"; exec "$SWARM_DIR/launch.sh" start "$@" ;;
    stop) shift; stop_project "$@" ;;
    harvest) shift; cd "$(repo_root)"; exec "$SWARM_DIR/harvest.sh" "$@" ;;
    status) shift; status_project "$@" ;;
    dashboard) shift; cd "$(repo_root)"; exec "$SWARM_DIR/dashboard.sh" "$@" ;;
    post-process) shift; cd "$(repo_root)"; exec "$SWARM_DIR/launch.sh" post-process "$@" ;;
    cleanup) shift; cd "$(repo_root)"; exec "$SWARM_DIR/launch.sh" cleanup "$@" ;;
    -h|--help|"") usage ;;
    *) echo "control.sh: unknown operation: $1" >&2; usage >&2; exit 2 ;;
esac
