#!/bin/bash
set -euo pipefail

# Create bare repos, build image, launch N agent containers.
# Usage: ./launch.sh {start|stop|cleanup|logs N|status|wait|post-process|interactive}

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<HELP
Usage: $0 [COMMAND] [OPTIONS]

Orchestrate coding agents in Docker containers.
Default command is 'start' when none is specified.

Commands:
  validate             Validate swarmfile, prompts, drivers, and auth.
  start [OPTIONS]      Build image, create bare repo, launch agents.
  stop                 Stop all running agent containers.
  cleanup              Remove stopped project containers once no
                       unharvested bare refs remain.
  logs N               Tail logs for agent N (default: 1).
  status               Show running/stopped state for each agent.
  wait                 Wait for already-started numbered agents,
                       then post-process and harvest. Does not
                       start agents.
  post-process         Run only the post-processing agent, then
                       harvest.
  interactive PROFILE  Start an interactive driver session from a
                       named agent profile.
  chat PROFILE         Alias for interactive PROFILE.
  shell PROFILE        Start an interactive shell from a named
                       agent profile.

Start options:
  --dashboard          Open the TUI dashboard after launch.

Interactive options:
  --agent NAME         Select agents[].name explicitly.
  --agent-index N      Select the Nth agents[] entry.
  --shell              Open a shell instead of the driver UI.
  --chat               Open the driver UI (default).

Environment:
  ANTHROPIC_API_KEY         API key (required unless OAuth).
  CLAUDE_CODE_OAUTH_TOKEN   OAuth token for subscription auth.
  SWARM_CONFIG              Path to swarmfile (or place swarm.json in repo root).
  SWARM_TITLE               Dashboard title override.
  SWARM_SKIP_DEP_CHECK      Set to 1 to silence version warnings.
HELP
    exit 0
fi

source "$SWARM_DIR/lib/check-deps.sh"
check_deps git jq docker
# shellcheck source=lib/project.sh
source "$SWARM_DIR/lib/project.sh"
# shellcheck source=lib/target.sh
source "$SWARM_DIR/lib/target.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT_RAW="$(basename "$REPO_ROOT")"
PROJECT="$(swarm_project_resolve "$REPO_ROOT")"
SWARM_RUN_HASH="$(git -C "$REPO_ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")"
SWARM_RUN_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
SWARM_RUN_CONTEXT="${PROJECT_RAW}@${SWARM_RUN_HASH} (${SWARM_RUN_BRANCH})"
RUNTIME_DIR="$(swarm_runtime_init "$PROJECT" "$REPO_ROOT")"
BARE_REPO="$RUNTIME_DIR/upstream.git"
MIRROR_DIR="$RUNTIME_DIR/mirrors"
TARGET_MIRROR_DIR="$RUNTIME_DIR/target.git"
TARGET_BASE_MIRROR_DIR="$RUNTIME_DIR/target-base.git"
STATE_FILE="$RUNTIME_DIR/swarm-state.json"
IMAGE_NAME="${PROJECT}-agent"

# Expand a single $VAR reference from the host environment.
# Supports "$VAR" (entire value is a reference) only -- not inline
# interpolation.  Returns the original string if no match.
expand_env_ref() {
    local val="$1"
    if [[ "$val" =~ ^\$([A-Za-z_][A-Za-z_0-9]*)$ ]]; then
        local varname="${BASH_REMATCH[1]}"
        printf '%s' "${!varname:-}"
    else
        printf '%s' "$val"
    fi
}

# Compute the comma-separated SWARM_AGENTS build-arg from a config:
# the union of every agent group's driver and the post-process driver.
# Used as a Dockerfile build-arg to gate per-CLI install layers; missing
# a driver here is what produces "command not found" inside the agent.
compute_swarm_agents() {
    local cfg="$1"
    local default_drv seen=" " out="" drv
    default_drv=$(jq -r '.driver // "claude-code"' "$cfg")
    while IFS= read -r drv; do
        [ -z "$drv" ] && drv="$default_drv"
        [[ "$seen" == *" $drv "* ]] && continue
        seen+="$drv "
        out="${out:+${out},}${drv}"
    done < <(jq -r '.agents[]? | (.driver // "")' "$cfg")
    local pp_drv
    pp_drv=$(jq -r '
        if .post_process == null then ""
        else (.post_process.driver // .driver // "claude-code")
        end' "$cfg")
    if [ -n "$pp_drv" ] && [[ "$seen" != *" $pp_drv "* ]]; then
        out="${out:+${out},}${pp_drv}"
    fi
    printf '%s' "$out"
}

# Build (or rebuild) the agent image with build-args derived from the current
# config.  Docker's layer cache makes this a no-op when the args and Dockerfile
# haven't changed; when the driver set or pinned CLI versions change the cache
# invalidates correctly and the right install layer re-runs.  Called by
# cmd_start *and* cmd_post_process so a standalone post-process invocation
# never reuses an image built for a different driver set (which silently
# produces exit-127 on first session -- see harness's `agent exited with code
# 127` retry path).
build_image() {
    local swarm_agents cc_version codex_version kimi_version qwen_version
    swarm_agents=$(compute_swarm_agents "$CONFIG_FILE")
    cc_version=$(jq -r '.claude_code_version // empty' "$CONFIG_FILE" 2>/dev/null || true)
    codex_version=$(jq -r '.codex_cli_version // empty' "$CONFIG_FILE" 2>/dev/null || true)
    kimi_version=$(jq -r '.kimi_cli_version // empty' "$CONFIG_FILE" 2>/dev/null || true)
    qwen_version=$(jq -r '.qwen_cli_version // empty' "$CONFIG_FILE" 2>/dev/null || true)
    echo "--- Building agent image (agents: ${swarm_agents}) ---"
    # Pin the container's agent uid/gid to the host so the owner-only
    # bind-mounted runtime stays writable on native Linux; Docker
    # Desktop remaps ownership, so the pin is a no-op there.
    docker build -t "$IMAGE_NAME" \
        --build-arg "SWARM_AGENTS=${swarm_agents}" \
        --build-arg "AGENT_UID=$(id -u)" \
        --build-arg "AGENT_GID=$(id -g)" \
        ${cc_version:+--build-arg "CLAUDE_CODE_VERSION=${cc_version}"} \
        ${codex_version:+--build-arg "CODEX_CLI_VERSION=${codex_version}"} \
        ${kimi_version:+--build-arg "KIMI_CLI_VERSION=${kimi_version}"} \
        ${qwen_version:+--build-arg "QWEN_CLI_VERSION=${qwen_version}"} \
        -f "$SWARM_DIR/Dockerfile" "$SWARM_DIR"
}

assert_existing_bare_contained() {
    [ -e "$BARE_REPO" ] || return 0
    [ ! -L "$BARE_REPO" ] && [ -d "$BARE_REPO" ] \
        && git -C "$BARE_REPO" rev-parse --git-dir >/dev/null 2>&1 || {
        echo "ERROR: existing bare path is not a readable repository." >&2
        return 1
    }

    local ref tip
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        tip=$(git -C "$BARE_REPO" rev-parse --verify "${ref}^{commit}") \
            || return 1
        if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$tip" HEAD \
                2>/dev/null; then
            echo "ERROR: existing bare repository has an unharvested ref:" \
                >&2
            echo "       $ref (${tip:0:12}); harvest or rescue it first." >&2
            return 1
        fi
    done < <(git -C "$BARE_REPO" for-each-ref --format='%(refname)' \
        refs/heads/agent-work refs/heads/swarm)

    # refs/heads/agent-parked/* are the harness's emergency salvage refs:
    # they are not expected to be merged, so an ancestry check would
    # refuse forever. They are safe to drop only once their objects
    # exist in the local repo -- a completed harvest fetches
    # +refs/heads/* into the checkout.
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        tip=$(git -C "$BARE_REPO" rev-parse --verify "${ref}^{commit}") \
            || return 1
        if ! git -C "$REPO_ROOT" cat-file -e "${tip}^{commit}" \
                2>/dev/null; then
            echo "ERROR: existing bare repository holds a salvage ref:" \
                >&2
            echo "       $ref (${tip:0:12}); harvest or rescue it first." >&2
            return 1
        fi
    done < <(git -C "$BARE_REPO" for-each-ref --format='%(refname)' \
        refs/heads/agent-parked)
}

create_bare_repo() {
    local label="${1:-bare repo}" new old had_old=0
    assert_existing_bare_contained || return 1
    echo "--- Creating ${label} ---"
    new="$RUNTIME_DIR/.upstream.new.$$"
    old="$RUNTIME_DIR/.upstream.previous.$$"
    [ ! -e "$new" ] && [ ! -e "$old" ] || {
        echo "ERROR: bare-repo transaction path already exists." >&2
        return 1
    }
    # Local clones hardlink packed objects by default. The bare repo is mounted
    # through Docker Desktop while the source stays on the host. Keep its
    # object storage independent so receive-pack does not depend on inodes
    # shared across the bind-mount boundary.
    git clone --bare --no-hardlinks "$REPO_ROOT" "$new"
    git -C "$new" branch agent-work HEAD 2>/dev/null || true
    git -C "$new" symbolic-ref HEAD refs/heads/agent-work
    git -C "$new" config core.sharedRepository false
    chmod -R u+rwX,go-rwx "$new"
    git -C "$new" fsck --no-dangling >/dev/null || {
        safe_runtime_remove "$new"
        echo "ERROR: new bare repository failed fsck." >&2
        return 1
    }
    if [ -e "$BARE_REPO" ]; then
        [ ! -L "$BARE_REPO" ] && [ -d "$BARE_REPO" ] || {
            safe_runtime_remove "$new"
            echo "ERROR: existing bare path is not a directory." >&2
            return 1
        }
        mv "$BARE_REPO" "$old"
        had_old=1
    fi
    if ! mv "$new" "$BARE_REPO"; then
        [ "$had_old" -eq 0 ] || mv "$old" "$BARE_REPO"
        safe_runtime_remove "$new" 2>/dev/null || true
        return 1
    fi
    [ "$had_old" -eq 0 ] || safe_runtime_remove "$old"
}

ensure_bare_repo_for_interactive() {
    if [ ! -d "$BARE_REPO" ]; then
        create_bare_repo "bare repo for interactive session"
        return
    fi

    local bare_head local_head
    bare_head=$(git -C "$BARE_REPO" rev-parse --verify --quiet \
        refs/heads/agent-work 2>/dev/null || true)
    local_head=$(git rev-parse HEAD 2>/dev/null || true)
    if [ -n "$bare_head" ] && [ "$bare_head" != "$local_head" ] \
            && git merge-base --is-ancestor "$bare_head" HEAD 2>/dev/null; then
        echo "--- Refreshing contained bare repo from current HEAD ---"
        create_bare_repo "bare repo for interactive session"
        return
    fi
}

mirror_submodules() {
    local status new old had_old=0 idx=0 display gitdir mirror
    status=$(git -C "$REPO_ROOT" submodule status --recursive) || return 1
    if printf '%s\n' "$status" | grep -qE '^[+-U]'; then
        echo "ERROR: every recursive submodule must be initialized at its pinned gitlink." >&2
        printf '%s\n' "$status" >&2
        return 1
    fi
    new="$RUNTIME_DIR/.mirrors.new.$$"
    old="$RUNTIME_DIR/.mirrors.previous.$$"
    [ ! -e "$new" ] && [ ! -e "$old" ] || {
        echo "ERROR: mirror transaction path already exists." >&2
        return 1
    }
    mkdir -m 700 "$new" "$new/repos"
    : > "$new/manifest.tsv"
    while IFS=$'\t' read -r display gitdir; do
        [ -n "$display" ] || continue
        case "$display" in *$'\n'*|*$'\t'*)
            echo "ERROR: unsupported control character in submodule path." >&2
            safe_runtime_remove "$new"
            return 1;;
        esac
        idx=$((idx + 1))
        mirror="repos/repo-${idx}.git"
        echo "--- Mirroring submodule: ${display} ---"
        git clone --bare --no-hardlinks "$gitdir" "$new/$mirror"
        git -C "$new/$mirror" fsck --no-dangling >/dev/null || {
            safe_runtime_remove "$new"
            echo "ERROR: mirror failed fsck: ${display}" >&2
            return 1
        }
        chmod -R u+rwX,go-rwx "$new/$mirror"
        printf '%s\t%s\n' "$display" "$mirror" >> "$new/manifest.tsv"
    done < <(git -C "$REPO_ROOT" submodule foreach --quiet --recursive \
        'printf "%s\t" "$displaypath"; git rev-parse --absolute-git-dir')
    chmod 600 "$new/manifest.tsv"
    if [ -e "$MIRROR_DIR" ]; then
        [ ! -L "$MIRROR_DIR" ] && [ -d "$MIRROR_DIR" ] || {
            safe_runtime_remove "$new"
            echo "ERROR: existing mirror path is not a directory." >&2
            return 1
        }
        mv "$MIRROR_DIR" "$old"
        had_old=1
    fi
    if ! mv "$new" "$MIRROR_DIR"; then
        [ "$had_old" -eq 0 ] || mv "$old" "$MIRROR_DIR"
        safe_runtime_remove "$new" 2>/dev/null || true
        return 1
    fi
    [ "$had_old" -eq 0 ] || safe_runtime_remove "$old"
}

load_mirror_args() {
    MIRROR_ARGS=()
    if [ -f "$MIRROR_DIR/manifest.tsv" ]; then
        MIRROR_ARGS=(-v "${MIRROR_DIR}:/mirrors:ro")
    fi
}

available_drivers() {
    find "$SWARM_DIR/lib/drivers" -type f -name '*.sh' \
        -exec basename {} .sh \; | tr '\n' ' '
}

CONFIG_FILE="${SWARM_CONFIG:-}"
if [ -z "$CONFIG_FILE" ] && [ -f "$REPO_ROOT/swarm.json" ]; then
    CONFIG_FILE="$REPO_ROOT/swarm.json"
fi

if [ -z "$CONFIG_FILE" ]; then
    echo "ERROR: No swarmfile found.  Create swarm.json in your repo root or set SWARM_CONFIG." >&2
    exit 1
fi
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Swarmfile ${CONFIG_FILE} not found." >&2
    exit 1
fi

SWARM_PROMPT=$(jq -r '.prompt // empty' "$CONFIG_FILE")
SWARM_SETUP=$(jq -r '.setup // empty' "$CONFIG_FILE")
MAX_IDLE=$(jq -r '.max_idle // 3' "$CONFIG_FILE")
INJECT_GIT_RULES=$(jq -r 'if has("inject_git_rules") then .inject_git_rules else true end' "$CONFIG_FILE")
GIT_USER_NAME=$(jq -r '.git_user.name // "swarm-agent"' "$CONFIG_FILE")
GIT_USER_EMAIL=$(jq -r '.git_user.email // "agent@swarm.local"' "$CONFIG_FILE")
GIT_SIGNING_KEY=$(jq -r '.git_user.signing_key // empty' "$CONFIG_FILE")
GIT_SIGNING_KEY="$(expand_env_ref "$GIT_SIGNING_KEY")"

# Resolve signing key path and build volume mount.
SIGNING_KEY_ARGS=()
if [ -n "$GIT_SIGNING_KEY" ]; then
    GIT_SIGNING_KEY="${GIT_SIGNING_KEY/#\~/$HOME}"
    if [ ! -f "$GIT_SIGNING_KEY" ]; then
        echo "ERROR: signing key not found: $GIT_SIGNING_KEY" >&2
        exit 1
    fi
    SIGNING_KEY_ARGS=(-v "${GIT_SIGNING_KEY}:/etc/swarm/signing_key:ro")
fi
NUM_AGENTS=$(jq '[.agents[]? | (.count // 0)] | add // 0' "$CONFIG_FILE")
SWARM_DRIVER_DEFAULT=$(jq -r '.driver // "claude-code"' "$CONFIG_FILE")
MAX_RETRY_WAIT=$(jq -r '.max_retry_wait // 0' "$CONFIG_FILE")

DOCKER_EXTRA_ARGS=()
while IFS= read -r _da; do
    [ -n "$_da" ] && DOCKER_EXTRA_ARGS+=("$_da")
done < <(jq -r '.docker_args[]?' "$CONFIG_FILE" 2>/dev/null)

# Target provenance and the reader token are owned by the host-side snapshot.
# Never allow a swarmfile to override them in Docker Config.Env. Preserve every
# unrelated operator-supplied Docker argument.
reserved_target_env() {
    case "${1%%=*}" in
        SWARM_READER_TOKEN|SWARM_TARGET_MIRROR|SWARM_TARGET_BASE_MIRROR|\
        TARGET_REPO|TARGET_REV|TARGET_REV_BASE|TARGET_REV_BASE_REPO) return 0 ;;
        *) return 1 ;;
    esac
}
FILTERED_DOCKER_ARGS=()
for ((i = 0; i < ${#DOCKER_EXTRA_ARGS[@]}; i++)); do
    case "${DOCKER_EXTRA_ARGS[$i]}" in
        -e|--env)
            if reserved_target_env \
                    "${DOCKER_EXTRA_ARGS[$((i + 1))]:-}"; then
                i=$((i + 1))
                continue
            fi
            ;;
        -e*|--env=*)
            inline_env="${DOCKER_EXTRA_ARGS[$i]#-e}"
            inline_env="${inline_env#--env=}"
            reserved_target_env "$inline_env" && continue
            ;;
    esac
    FILTERED_DOCKER_ARGS+=("${DOCKER_EXTRA_ARGS[$i]}")
done
DOCKER_EXTRA_ARGS=("${FILTERED_DOCKER_ARGS[@]}")

parse_start_args() {
    OPEN_DASHBOARD=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --dashboard)
                OPEN_DASHBOARD=true
                shift ;;
            *)
                echo "Unknown start option: $1" >&2
                echo "Try '$0 --help' for more." >&2
                exit 1 ;;
        esac
    done
}

validate_config() {
    local all_groups_have_prompt profile encoded index=0 label driver
    local api_key auth_token auth base_url auth_output auth_label prompt
    [ "$NUM_AGENTS" -gt 0 ] || {
        echo "ERROR: swarmfile must configure at least one agent." >&2
        return 1
    }

    all_groups_have_prompt=$(jq \
        '[.agents[] | has("prompt") and (.prompt | length > 0)] | all' \
        "$CONFIG_FILE")
    if [ -z "$SWARM_PROMPT" ] && [ "$all_groups_have_prompt" != true ]; then
        echo "ERROR: 'prompt' is missing in ${CONFIG_FILE}." >&2
        return 1
    fi
    if [ -n "$SWARM_PROMPT" ] && [ ! -f "$REPO_ROOT/$SWARM_PROMPT" ]; then
        echo "ERROR: prompt '${SWARM_PROMPT}' not found." >&2
        return 1
    fi

    while IFS= read -r encoded; do
        [ -n "$encoded" ] || continue
        index=$((index + 1))
        profile=$(printf '%s' "$encoded" | base64 -d) || return 1
        label=$(jq -r --argjson i "$index" \
            '.name // ("profile-" + ($i | tostring))' <<< "$profile")
        driver=$(jq -r --arg default "$SWARM_DRIVER_DEFAULT" \
            '.driver // $default' <<< "$profile")
        [ -f "$SWARM_DIR/lib/drivers/${driver}.sh" ] || {
            echo "ERROR: unknown driver '${driver}' in ${label}." >&2
            echo "Available drivers: $(available_drivers)" >&2
            return 1
        }
        prompt=$(jq -r '.prompt // empty' <<< "$profile")
        if [ -n "$prompt" ] && [ ! -f "$REPO_ROOT/$prompt" ]; then
            echo "ERROR: prompt '${prompt}' for ${label} not found." >&2
            return 1
        fi
        api_key=$(expand_env_ref "$(jq -r '.api_key // empty' <<< "$profile")")
        auth_token=$(expand_env_ref "$(jq -r '.auth_token // empty' <<< "$profile")")
        auth=$(jq -r '.auth // empty' <<< "$profile")
        base_url=$(jq -r '.base_url // empty' <<< "$profile")
        # shellcheck source=lib/drivers/claude-code.sh
        source "$SWARM_DIR/lib/drivers/${driver}.sh"
        auth_output=$(agent_docker_auth "$api_key" "$auth_token" \
            "$auth" "$base_url") || return 1
        auth_label=$(sed -n 's/^SWARM_AUTH_MODE=//p' \
            <<< "$auth_output" | tail -1)
        if [ "$driver" != fake ] && [ -z "$auth_label" ]; then
            echo "ERROR: no usable credentials for ${label} (${driver}/${auth:-default})." >&2
            return 1
        fi
    done < <(jq -r '
        ([.agents[]?] + ([.post_process] | map(select(. != null))))[]
        | @base64' "$CONFIG_FILE")
}

cmd_validate() {
    validate_config
    echo "Swarm configuration and credentials validated: $CONFIG_FILE"
}

print_interactive_profiles() {
    jq -r '.driver as $dd | .agents | to_entries[] |
        "\(.key + 1)|\(.value.name // "")|\(.value.model // "")|" +
        "\(.value.driver // $dd // "claude-code")"' \
        "$CONFIG_FILE" | while IFS='|' read -r idx name model driver; do
        if [ -n "$name" ]; then
            printf '  - %s (index %s, %s, %s)\n' \
                "$name" "$idx" "${model:-model unset}" "$driver"
        else
            printf '  - --agent-index %s (%s, %s)\n' \
                "$idx" "${model:-model unset}" "$driver"
        fi
    done >&2
}

select_interactive_profile() {
    local selector="$1" selector_index="$2" output_file="$3"
    local selected count

    if [ -n "$selector_index" ]; then
        if ! [[ "$selector_index" =~ ^[0-9]+$ ]] \
                || [ "$selector_index" -lt 1 ]; then
            echo "ERROR: --agent-index must be a positive integer." >&2
            exit 1
        fi
        selected=$(jq -c --argjson idx "$((selector_index - 1))" \
            '.agents[$idx] // empty' "$CONFIG_FILE")
        if [ -z "$selected" ] || [ "$selected" = "null" ]; then
            echo "ERROR: no agent at index ${selector_index}." >&2
            print_interactive_profiles
            exit 1
        fi
        printf '%s\n' "$selected" > "$output_file"
        return
    fi

    if [ -z "$selector" ]; then
        local named_count agent_count
        named_count=$(jq '[.agents[] | select(.name? and (.name | length > 0))] | length' \
            "$CONFIG_FILE")
        agent_count=$(jq '.agents | length' "$CONFIG_FILE")
        if [ "$named_count" -eq 1 ]; then
            selector=$(jq -r '.agents[] | select(.name? and (.name | length > 0)) | .name' \
                "$CONFIG_FILE")
        elif [ "$agent_count" -eq 1 ]; then
            selector_index=1
            select_interactive_profile "$selector" "$selector_index" "$output_file"
            return
        else
            echo "ERROR: choose an interactive profile." >&2
            echo "Use '$0 interactive NAME' or '$0 interactive --agent-index N'." >&2
            echo "Available profiles:" >&2
            print_interactive_profiles
            exit 1
        fi
    fi

    count=$(jq --arg name "$selector" \
        '[.agents[] | select((.name // "") == $name)] | length' \
        "$CONFIG_FILE")
    if [ "$count" -eq 0 ]; then
        echo "ERROR: no agent profile named '${selector}'." >&2
        echo "Available profiles:" >&2
        print_interactive_profiles
        exit 1
    fi
    if [ "$count" -gt 1 ]; then
        echo "ERROR: agent profile name '${selector}' is not unique." >&2
        exit 1
    fi

    jq -c --arg name "$selector" \
        '.agents[] | select((.name // "") == $name)' \
        "$CONFIG_FILE" > "$output_file"
}

cmd_interactive() {
    local mode="$1"; shift
    local selector="" selector_index=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --agent)
                selector="${2:-}"
                if [ -z "$selector" ]; then
                    echo "ERROR: --agent requires a name." >&2
                    exit 1
                fi
                shift 2 ;;
            --agent-index)
                selector_index="${2:-}"
                if [ -z "$selector_index" ]; then
                    echo "ERROR: --agent-index requires a number." >&2
                    exit 1
                fi
                shift 2 ;;
            --shell)
                mode="shell"
                shift ;;
            --chat)
                mode="chat"
                shift ;;
            -h|--help)
                cat <<HELP
Usage: $0 interactive [--agent NAME | --agent-index N] [--shell]
       $0 chat        [--agent NAME | --agent-index N]
       $0 shell       [--agent NAME | --agent-index N]

Start one human-guided container from an agents[] profile.
HELP
                exit 0 ;;
            *)
                if [ -n "$selector" ]; then
                    echo "ERROR: multiple interactive profiles supplied." >&2
                    exit 1
                fi
                selector="$1"
                shift ;;
        esac
    done

    local profile_file
    profile_file=$(mktemp "$RUNTIME_DIR/interactive-profile.XXXXXX.json")
    select_interactive_profile "$selector" "$selector_index" "$profile_file"

    local profile_name profile_label safe_profile short_id branch name
    local agent_model agent_base_url agent_api_key agent_effort agent_auth
    local agent_context agent_prompt agent_auth_token agent_tag agent_driver

    profile_name=$(jq -r '.name // empty' "$profile_file")
    profile_label="$profile_name"
    if [ -z "$profile_label" ]; then
        profile_label="agent-${selector_index:-1}"
    fi
    safe_profile="$(swarm_project_id "$profile_label")"
    safe_profile="${safe_profile:0:32}"
    short_id="$(date -u +%Y%m%d%H%M%S)-${RANDOM}"
    branch="swarm/${SWARM_RUN_HASH}/interactive-${safe_profile}-${short_id}"
    name="${IMAGE_NAME}-interactive-${safe_profile}-${short_id}"

    if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
        echo "ERROR: invalid interactive branch name: ${branch}" >&2
        exit 1
    fi

    agent_model=$(jq -r '.model // empty' "$profile_file")
    agent_base_url=$(jq -r '.base_url // empty' "$profile_file")
    agent_api_key=$(jq -r '.api_key // empty' "$profile_file")
    agent_api_key="$(expand_env_ref "$agent_api_key")"
    agent_effort=$(jq -r '.effort // empty' "$profile_file")
    agent_auth=$(jq -r '.auth // empty' "$profile_file")
    agent_context=$(jq -r '.context // empty' "$profile_file")
    agent_context="${agent_context:-full}"
    agent_prompt=$(jq -r '.prompt // empty' "$profile_file")
    agent_auth_token=$(jq -r '.auth_token // empty' "$profile_file")
    agent_auth_token="$(expand_env_ref "$agent_auth_token")"
    agent_tag=$(jq -r '.tag // empty' "$profile_file")
    if [ -z "$agent_tag" ]; then
        agent_tag=$(jq -r '.tag // empty' "$CONFIG_FILE")
    fi
    agent_tag="$(expand_env_ref "$agent_tag")"
    agent_driver=$(jq -r --arg dd "$SWARM_DRIVER_DEFAULT" \
        '.driver // $dd // "claude-code"' "$profile_file")
    agent_driver="${agent_driver:-$SWARM_DRIVER_DEFAULT}"

    if [ ! -f "$SWARM_DIR/lib/drivers/${agent_driver}.sh" ]; then
        echo "ERROR: unknown driver: ${agent_driver}" >&2
        echo "Available drivers: $(available_drivers)" >&2
        exit 1
    fi

    # shellcheck source=lib/drivers/claude-code.sh
    source "$SWARM_DIR/lib/drivers/${agent_driver}.sh"
    agent_model="${agent_model:-$(agent_default_model)}"

    local effective_prompt="${agent_prompt:-$SWARM_PROMPT}"
    if [ -n "$effective_prompt" ] && [ ! -f "$REPO_ROOT/$effective_prompt" ]; then
        echo "ERROR: prompt '${effective_prompt}' not found." >&2
        exit 1
    fi

    prepare_target_mirrors
    ensure_bare_repo_for_interactive
    mirror_submodules
    build_image

    load_mirror_args
    rm -f "$profile_file"

    local EXTRA_ENV=()
    while IFS= read -r _ae; do
        [ -n "$_ae" ] && EXTRA_ENV+=("$_ae")
    done < <(agent_docker_auth "$agent_api_key" "$agent_auth_token" \
        "$agent_auth" "$agent_base_url")

    if [ -n "$agent_effort" ]; then
        while IFS= read -r _de; do
            [ -n "$_de" ] && EXTRA_ENV+=("$_de")
        done < <(agent_docker_env "$agent_effort")
    fi

    if docker inspect "$name" >/dev/null 2>&1; then
        echo "ERROR: container $name already exists; rescue and remove it explicitly." >&2
        exit 1
    fi

    echo "--- Starting interactive ${profile_label} (${agent_model}) ---"
    echo "Branch: ${branch}"
    docker run -it \
        --name "$name" \
        --label "org.claude-swarm.managed=true" \
        --label "org.claude-swarm.project=${PROJECT}" \
        --label "org.claude-swarm.engagement=${ENGAGEMENT_ID:-interactive}" \
        --label "org.claude-swarm.role=interactive" \
        -v "${BARE_REPO}:/upstream:rw" \
        "${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}" \
        "${TARGET_MIRROR_ARGS[@]+"${TARGET_MIRROR_ARGS[@]}"}" \
        "${SIGNING_KEY_ARGS[@]+"${SIGNING_KEY_ARGS[@]}"}" \
        "${DOCKER_EXTRA_ARGS[@]+"${DOCKER_EXTRA_ARGS[@]}"}" \
        "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
        -e "SWARM_MODEL=${agent_model}" \
        -e "SWARM_EFFORT=${agent_effort}" \
        -e "CLAUDE_MODEL=${agent_model}" \
        -e "SWARM_PROMPT=${effective_prompt}" \
        -e "SWARM_SETUP=${SWARM_SETUP}" \
        -e "GIT_USER_NAME=${GIT_USER_NAME}" \
        -e "GIT_USER_EMAIL=${GIT_USER_EMAIL}" \
        -e "INJECT_GIT_RULES=${INJECT_GIT_RULES}" \
        -e "AGENT_ID=interactive-${safe_profile}" \
        -e "SWARM_TAG=${agent_tag}" \
        -e "SWARM_CONTEXT=${agent_context}" \
        -e "SWARM_DRIVER=${agent_driver}" \
        -e "SWARM_RUN_CONTEXT=${SWARM_RUN_CONTEXT}" \
        -e "SWARM_CFG_PROMPT=${effective_prompt}" \
        -e "SWARM_CFG_SETUP=${SWARM_SETUP}" \
        -e "SWARM_INTERACTIVE_BRANCH=${branch}" \
        -e "SWARM_INTERACTIVE_PROFILE=${profile_label}" \
        -e "SWARM_INTERACTIVE_MODE=${mode}" \
        --entrypoint /interactive.sh \
        "$IMAGE_NAME"
}

cmd_start() {
    validate_config

    # An embedder-set ENGAGEMENT_ID wins; otherwise the engine assigns
    # one so container labels and the state file never say "unknown".
    ENGAGEMENT_ID="${ENGAGEMENT_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM}"
    export ENGAGEMENT_ID

    local existing_containers
    existing_containers=$(docker ps -a \
        --filter "label=org.claude-swarm.project=${PROJECT}" \
        --format '{{.Names}}' 2>/dev/null || true)
    # Backward-compatible detection protects containers made before labels
    # existed as well. No start path is allowed to erase forensic state.
    if [ -z "$existing_containers" ]; then
        existing_containers=$(docker ps -a \
            --filter "name=^${IMAGE_NAME}-" --format '{{.Names}}' \
            2>/dev/null || true)
    fi
    if [ -n "$existing_containers" ]; then
        echo "ERROR: existing project containers must be rescued and removed explicitly:" >&2
        printf '%s\n' "$existing_containers" | sed 's/^/  /' >&2
        exit 1
    fi

    prepare_target_mirrors
    create_bare_repo "bare repo"

    # Mirror each submodule so containers can init without network.
    mirror_submodules

    # Build per-agent config (model|base_url|api_key|effort|auth|context|prompt|auth_token|tag|driver per line).
    # Uses pipe delimiter because bash IFS=$'\t' collapses consecutive tabs.
    AGENTS_CFG="$RUNTIME_DIR/agents.cfg"
    jq -r '.tag as $dt | .driver as $dd |
        .agents[] | range(.count // 0) as $i |
        [.model, (.base_url // ""), (.api_key // ""), (.effort // ""), (.auth // ""), (.context // ""), (.prompt // ""), (.auth_token // ""), (.tag // $dt // ""), (.driver // $dd // "")] | join("|")' \
        "$CONFIG_FILE" > "$AGENTS_CFG"

    build_image

    # Mount the read-only mirror tree (shared across all containers).
    load_mirror_args

    AGENT_IDX=0
    while IFS='|' read -r agent_model agent_base_url agent_api_key agent_effort agent_auth agent_context agent_prompt agent_auth_token agent_tag agent_driver; do
        AGENT_IDX=$((AGENT_IDX + 1))
        NAME="${IMAGE_NAME}-${AGENT_IDX}"
        if docker inspect "$NAME" >/dev/null 2>&1; then
            echo "ERROR: container $NAME already exists; rescue and remove it explicitly." >&2
            exit 1
        fi
        agent_api_key="$(expand_env_ref "$agent_api_key")"
        agent_auth_token="$(expand_env_ref "$agent_auth_token")"
        agent_tag="$(expand_env_ref "$agent_tag")"
        agent_context="${agent_context:-full}"
        agent_driver="${agent_driver:-${SWARM_DRIVER_DEFAULT}}"

        # Source the driver to access agent_docker_env.
        # shellcheck source=lib/drivers/claude-code.sh
        source "$SWARM_DIR/lib/drivers/${agent_driver}.sh"
        local effective_prompt="${agent_prompt:-$SWARM_PROMPT}"

        local ctx_label="" prompt_label="" driver_label=""
        [ "$agent_context" != "full" ] && ctx_label=" context=${agent_context}"
        [ -n "$agent_prompt" ] && prompt_label=" prompt=${agent_prompt}"
        [ "$agent_driver" != "claude-code" ] && driver_label=" driver=${agent_driver}"
        echo "--- Launching ${NAME} (${agent_model}${agent_effort:+ effort=${agent_effort}}${ctx_label}${prompt_label}${driver_label}) ---"
        EXTRA_ENV=()

        # Delegate auth credential resolution to the driver.
        while IFS= read -r _ae; do
            [ -n "$_ae" ] && EXTRA_ENV+=("$_ae")
        done < <(agent_docker_auth "$agent_api_key" "$agent_auth_token" "$agent_auth" "$agent_base_url")

        local eff="${agent_effort:-}"
        if [ -n "$eff" ]; then
            while IFS= read -r _de; do
                [ -n "$_de" ] && EXTRA_ENV+=("$_de")
            done < <(agent_docker_env "$eff")
        fi

        local price_input="" price_output="" price_cached=""
        local _price
        _price=$(jq -r --arg m "$agent_model" \
            '.pricing[$m] // empty | "\(.input + 0) \(.output + 0) \((.cached // 0) + 0)"' \
            "$CONFIG_FILE" 2>/dev/null || true)
        if [ -n "$_price" ]; then
            read -r price_input price_output price_cached <<< "$_price"
        fi

        docker run -d \
            --name "$NAME" \
            --label "org.claude-swarm.managed=true" \
            --label "org.claude-swarm.project=${PROJECT}" \
            --label "org.claude-swarm.engagement=${ENGAGEMENT_ID:-unknown}" \
            --label "org.claude-swarm.role=agent" \
            --label "org.claude-swarm.agent-index=${AGENT_IDX}" \
            -v "${BARE_REPO}:/upstream:rw" \
            "${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}" \
            "${TARGET_MIRROR_ARGS[@]+"${TARGET_MIRROR_ARGS[@]}"}" \
            "${SIGNING_KEY_ARGS[@]+"${SIGNING_KEY_ARGS[@]}"}" \
            "${DOCKER_EXTRA_ARGS[@]+"${DOCKER_EXTRA_ARGS[@]}"}" \
            "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
            -e "SWARM_MODEL=${agent_model}" \
            -e "SWARM_EFFORT=${eff}" \
            -e "CLAUDE_MODEL=${agent_model}" \
            -e "SWARM_PROMPT=${effective_prompt}" \
            -e "SWARM_SETUP=${SWARM_SETUP}" \
            -e "MAX_IDLE=${MAX_IDLE}" \
            -e "MAX_RETRY_WAIT=${MAX_RETRY_WAIT}" \
            -e "GIT_USER_NAME=${GIT_USER_NAME}" \
            -e "GIT_USER_EMAIL=${GIT_USER_EMAIL}" \
            -e "INJECT_GIT_RULES=${INJECT_GIT_RULES}" \
            -e "AGENT_ID=${AGENT_IDX}" \
            -e "SWARM_TAG=${agent_tag}" \
            -e "SWARM_CONTEXT=${agent_context}" \
            -e "SWARM_DRIVER=${agent_driver}" \
            -e "SWARM_RUN_CONTEXT=${SWARM_RUN_CONTEXT}" \
            -e "SWARM_CFG_PROMPT=${effective_prompt}" \
            -e "SWARM_CFG_SETUP=${SWARM_SETUP}" \
            -e "SWARM_ACTIVITY_TIMEOUT=${SWARM_ACTIVITY_TIMEOUT:-0}" \
            -e "SWARM_ACTIVITY_POLL=${SWARM_ACTIVITY_POLL:-10}" \
            -e "SWARM_WATCHDOG_GRACE=${SWARM_WATCHDOG_GRACE:-10}" \
            ${price_input:+-e "SWARM_PRICE_INPUT=${price_input}"} \
            ${price_output:+-e "SWARM_PRICE_OUTPUT=${price_output}"} \
            ${price_cached:+-e "SWARM_PRICE_CACHED=${price_cached}"} \
            "$IMAGE_NAME"
    done < "$AGENTS_CFG"

    rm -f "$AGENTS_CFG"

    # Write state file so a standalone dashboard can pick up config.
    local state_model_summary state_config_label
    state_model_summary=$(jq -r \
        '(.prompt // "") as $dp | ($dp | split("/") | .[-1] // "" | rtrimstr(".md")) as $dp_stem |
        [.agents[] | (.count // 0) as $count | select($count > 0) |
          "\($count)x \(.model | split("/") | .[-1])" +
          (if .context == "none" then " ctx:bare"
           elif .context == "slim" then " ctx:slim"
           else "" end) +
          (if .prompt and .prompt != $dp then
            ":" + (.prompt | split("/") | .[-1] | rtrimstr(".md") |
              if startswith($dp_stem + "-") then .[$dp_stem | length + 1:] else . end)
           else "" end)] | join(", ")' \
        "$CONFIG_FILE")
    state_config_label=$(basename "$CONFIG_FILE")
    local config_title
    config_title=$(jq -r '.title // empty' "$CONFIG_FILE" 2>/dev/null || true)
    local state_tmp
    state_tmp=$(mktemp "$RUNTIME_DIR/swarm-state.XXXXXX.json")
    jq -n \
        --arg title "${SWARM_TITLE:-${config_title}}" \
        --arg config "$CONFIG_FILE" \
        --argjson num_agents "$NUM_AGENTS" \
        --arg model_summary "$state_model_summary" \
        --arg config_label "$state_config_label" \
        --arg engagement "$ENGAGEMENT_ID" \
        --arg target_repo "${TARGET_REPO:-}" \
        --arg target_rev "${TARGET_REV:-}" \
        --arg target_rev_base "${TARGET_REV_BASE:-}" \
        --arg target_rev_base_repo "${TARGET_REV_BASE_REPO:-}" \
        '{schema:"claude-swarm.state/v1", title:$title, config:$config,
          num_agents:$num_agents, model_summary:$model_summary,
          config_label:$config_label, engagement:$engagement,
          target_repo:$target_repo, target_rev:$target_rev,
          target_rev_base:$target_rev_base,
          target_rev_base_repo:$target_rev_base_repo}' > "$state_tmp"
    chmod 600 "$state_tmp"
    mv "$state_tmp" "$STATE_FILE"

    echo ""
    echo "--- ${NUM_AGENTS} agents launched ---"
    echo ""
    echo "Monitor:"
    echo "  $0 status"
    echo "  $0 logs 1"
    echo ""
    echo "Stop:"
    echo "  $0 stop"
    echo ""
    echo "Bare repo: ${BARE_REPO}"
}

cmd_stop() {
    # Default to a 60s grace so the harness's SIGTERM trap has
    # time to ship any in-flight local commits via
    # `_session_end_push` before docker forces SIGKILL.  The 10s
    # default that docker ships with cuts the emergency push
    # mid-rebase on a busy bare repo.  Override via env:
    #   SWARM_STOP_TIMEOUT=120 ./launch.sh stop
    local stop_timeout="${SWARM_STOP_TIMEOUT:-60}"
    echo "--- Stopping agents (grace ${stop_timeout}s) ---"
    for i in $(seq 1 "$NUM_AGENTS"); do
        NAME="${IMAGE_NAME}-${i}"
        docker stop -t "$stop_timeout" "$NAME" 2>/dev/null \
            && echo "  stopped ${NAME}" \
            || echo "  ${NAME} not running"
    done
    while IFS= read -r NAME; do
        [ -n "$NAME" ] || continue
        docker stop -t "$stop_timeout" "$NAME" 2>/dev/null \
            && echo "  stopped ${NAME}" \
            || echo "  ${NAME} not running"
    done < <(docker ps -a --format '{{.Names}}' 2>/dev/null \
        | grep -E "^${IMAGE_NAME}-interactive-" \
        | sort || true)
    NAME="${IMAGE_NAME}-post"
    docker stop -t "$stop_timeout" "$NAME" 2>/dev/null \
        && echo "  stopped ${NAME}" \
        || echo "  ${NAME} not running"
    # Preserve the last-run state for dashboards and forensics. A future start
    # replaces it atomically after the new roster has launched.
}

# Remove stopped project containers once their work is provably safe:
# a running container or an unharvested bare ref refuses the removal.
cmd_cleanup() {
    local existing_containers
    existing_containers=$(docker ps -a \
        --filter "label=org.claude-swarm.project=${PROJECT}" \
        --format '{{.Names}}' 2>/dev/null || true)
    # Backward-compatible detection protects containers made before labels
    # existed as well. Same fallback as cmd_start.
    if [ -z "$existing_containers" ]; then
        existing_containers=$(docker ps -a \
            --filter "name=^${IMAGE_NAME}-" --format '{{.Names}}' \
            2>/dev/null || true)
    fi
    if [ -z "$existing_containers" ]; then
        echo "No project containers to remove."
        return 0
    fi

    local name state
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        state=$(docker inspect -f '{{.State.Status}}' "$name" \
            2>/dev/null || echo unknown)
        if [ "$state" = "running" ]; then
            echo "ERROR: container $name is running; stop it first." >&2
            return 1
        fi
    done <<< "$existing_containers"

    assert_existing_bare_contained || return 1

    while IFS= read -r name; do
        [ -n "$name" ] || continue
        docker rm "$name" >/dev/null
        echo "  removed $name"
    done <<< "$existing_containers"
}

cmd_logs() {
    local n="${1:-1}"
    docker logs -f "${IMAGE_NAME}-${n}"
}

cmd_status() {
    for i in $(seq 1 "$NUM_AGENTS"); do
        NAME="${IMAGE_NAME}-${i}"
        printf "%-30s " "${NAME}:"
        docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null \
            || echo "not found"
    done

    while read -r NAME; do
        [ -n "$NAME" ] || continue
        local env_dump branch profile state
        env_dump=$(docker inspect -f \
            '{{range .Config.Env}}{{println .}}{{end}}' \
            "$NAME" 2>/dev/null || true)
        branch=$(printf '%s' "$env_dump" \
            | grep '^SWARM_INTERACTIVE_BRANCH=' \
            | head -1 | cut -d= -f2- || true)
        profile=$(printf '%s' "$env_dump" \
            | grep '^SWARM_INTERACTIVE_PROFILE=' \
            | head -1 | cut -d= -f2- || true)
        state=$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null \
            || echo "not found")
        printf "%-30s " "${NAME}:"
        printf "%s" "$state"
        [ -n "$profile" ] && printf "  profile=%s" "$profile"
        [ -n "$branch" ] && printf "  branch=%s" "$branch"
        printf "\n"
    done < <(docker ps -a --format '{{.Names}}' 2>/dev/null \
        | grep -E "^${IMAGE_NAME}-interactive-" \
        | sort || true)
}

cmd_wait() {
    echo "--- Waiting for all agents to finish ---"

    while true; do
        sleep 10
        local all_done=true running=0 exited=0
        for i in $(seq 1 "$NUM_AGENTS"); do
            local state
            state=$(docker inspect -f '{{.State.Status}}' "${IMAGE_NAME}-${i}" 2>/dev/null || echo "not found")
            case "$state" in
                running) running=$((running + 1)); all_done=false ;;
                exited)  exited=$((exited + 1)) ;;
            esac
        done

        printf "\r  %d running, %d exited " "$running" "$exited"

        if $all_done; then
            echo ""
            echo "All agents finished."
            break
        fi
    done

    local pp_prompt
    pp_prompt=$(jq -r '.post_process.prompt // empty' "$CONFIG_FILE")
    if [ -n "$pp_prompt" ]; then
        echo ""
        cmd_post_process
        return
    fi

    echo ""
    echo "--- Harvesting results ---"
    "$SWARM_DIR/harvest.sh"
}

cmd_post_process() {
    local pp_prompt pp_model pp_base_url pp_api_key pp_effort pp_auth pp_auth_token pp_tag pp_driver pp_max_idle pp_setup
    pp_prompt=$(jq -r '.post_process.prompt // empty' "$CONFIG_FILE")
    pp_max_idle=$(jq -r '.post_process.max_idle // .max_idle // 3' "$CONFIG_FILE")
    pp_model=$(jq -r '.post_process.model // "claude-opus-4-6"' "$CONFIG_FILE")
    pp_base_url=$(jq -r '.post_process.base_url // empty' "$CONFIG_FILE")
    pp_api_key=$(jq -r '.post_process.api_key // empty' "$CONFIG_FILE")
    pp_api_key="$(expand_env_ref "$pp_api_key")"
    pp_auth_token=$(jq -r '.post_process.auth_token // empty' "$CONFIG_FILE")
    pp_auth_token="$(expand_env_ref "$pp_auth_token")"
    pp_effort=$(jq -r '.post_process.effort // empty' "$CONFIG_FILE")
    pp_auth=$(jq -r '.post_process.auth // empty' "$CONFIG_FILE")
    pp_tag=$(jq -r '.post_process.tag // .tag // empty' "$CONFIG_FILE")
    pp_tag="$(expand_env_ref "$pp_tag")"
    pp_driver=$(jq -r '.post_process.driver // .driver // "claude-code"' "$CONFIG_FILE")

    # Resolve the post-process setup script.  An explicit
    # post_process.setup wins (a path runs it, false/empty skips it so a
    # heavy top-level setup is not redone); omitting the key inherits
    # the top-level setup.
    if jq -e '(.post_process // {}) | has("setup")' "$CONFIG_FILE" \
            >/dev/null 2>&1; then
        pp_setup=$(jq -r '.post_process.setup // ""' "$CONFIG_FILE")
        [ "$pp_setup" = "false" ] && pp_setup=""
    else
        pp_setup="${SWARM_SETUP:-}"
    fi

    if [ -z "$pp_prompt" ]; then
        echo "ERROR: post_process.prompt is not set in ${CONFIG_FILE}." >&2
        exit 1
    fi

    if [ ! -d "$BARE_REPO" ]; then
        create_bare_repo "bare repo for post-process"
    fi

    prepare_target_mirrors
    build_image

    local NAME="${IMAGE_NAME}-post"
    if docker inspect "$NAME" >/dev/null 2>&1; then
        echo "ERROR: container $NAME already exists; rescue and remove it explicitly." >&2
        return 1
    fi

    # Mount the read-only mirror tree from existing mirrors.
    local MIRROR_ARGS=()
    load_mirror_args

    # Source the driver to access agent_docker_auth / agent_docker_env.
    # shellcheck source=lib/drivers/claude-code.sh
    source "$SWARM_DIR/lib/drivers/${pp_driver}.sh"

    local EXTRA_ENV=()
    while IFS= read -r _ae; do
        [ -n "$_ae" ] && EXTRA_ENV+=("$_ae")
    done < <(agent_docker_auth "$pp_api_key" "$pp_auth_token" "$pp_auth" "$pp_base_url")

    if [ -n "$pp_effort" ]; then
        while IFS= read -r _de; do
            [ -n "$_de" ] && EXTRA_ENV+=("$_de")
        done < <(agent_docker_env "$pp_effort")
    fi

    local price_input="" price_output="" price_cached=""
    local _price
    _price=$(jq -r --arg m "$pp_model" \
        '.pricing[$m] // empty | "\(.input + 0) \(.output + 0) \((.cached // 0) + 0)"' \
        "$CONFIG_FILE" 2>/dev/null || true)
    if [ -n "$_price" ]; then
        read -r price_input price_output price_cached <<< "$_price"
    fi

    # A standalone post-process carries the engagement's identity from
    # the state file written at start; "unknown" remains the final
    # fallback in the container label.
    if [ -z "${ENGAGEMENT_ID:-}" ] && [ -f "$STATE_FILE" ]; then
        ENGAGEMENT_ID=$(jq -r '.engagement // empty' "$STATE_FILE" \
            2>/dev/null || true)
        export ENGAGEMENT_ID
    fi

    echo "--- Starting post-processing (${pp_model}) ---"
    docker run -d \
        --name "$NAME" \
        --label "org.claude-swarm.managed=true" \
        --label "org.claude-swarm.project=${PROJECT}" \
        --label "org.claude-swarm.engagement=${ENGAGEMENT_ID:-unknown}" \
        --label "org.claude-swarm.role=post-process" \
        -v "${BARE_REPO}:/upstream:rw" \
        "${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"}" \
        "${TARGET_MIRROR_ARGS[@]+"${TARGET_MIRROR_ARGS[@]}"}" \
        "${SIGNING_KEY_ARGS[@]+"${SIGNING_KEY_ARGS[@]}"}" \
        "${DOCKER_EXTRA_ARGS[@]+"${DOCKER_EXTRA_ARGS[@]}"}" \
        "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
        -e "SWARM_MODEL=${pp_model}" \
        -e "SWARM_EFFORT=${pp_effort}" \
        -e "CLAUDE_MODEL=${pp_model}" \
        -e "SWARM_PROMPT=${pp_prompt}" \
        -e "SWARM_SETUP=${pp_setup}" \
        -e "MAX_IDLE=${pp_max_idle}" \
        -e "MAX_RETRY_WAIT=${MAX_RETRY_WAIT}" \
        -e "GIT_USER_NAME=${GIT_USER_NAME}" \
        -e "GIT_USER_EMAIL=${GIT_USER_EMAIL}" \
        -e "INJECT_GIT_RULES=${INJECT_GIT_RULES}" \
        -e "AGENT_ID=post" \
        -e "SWARM_TAG=${pp_tag}" \
        -e "SWARM_DRIVER=${pp_driver}" \
        -e "SWARM_RUN_CONTEXT=${SWARM_RUN_CONTEXT}" \
        -e "SWARM_CFG_PROMPT=${pp_prompt}" \
        -e "SWARM_CFG_SETUP=${pp_setup}" \
        -e "SWARM_ACTIVITY_TIMEOUT=${SWARM_ACTIVITY_TIMEOUT:-0}" \
        -e "SWARM_ACTIVITY_POLL=${SWARM_ACTIVITY_POLL:-10}" \
        -e "SWARM_WATCHDOG_GRACE=${SWARM_WATCHDOG_GRACE:-10}" \
        ${price_input:+-e "SWARM_PRICE_INPUT=${price_input}"} \
        ${price_output:+-e "SWARM_PRICE_OUTPUT=${price_output}"} \
        ${price_cached:+-e "SWARM_PRICE_CACHED=${price_cached}"} \
        "$IMAGE_NAME"

    echo "Post-processing agent launched: ${NAME}"
    echo "Waiting for completion..."

    while true; do
        sleep 10
        local state
        state=$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo "not found")
        if [ "$state" = "running" ]; then
            printf "."
            continue
        fi
        echo ""
        echo "Post-processing agent finished (${state})."
        break
    done

    # Capture container exit code BEFORE harvest. Harvest runs unconditionally
    # so a crashed agent's in-flight commits still land locally (best-effort
    # recovery), but we propagate the failure upward so callers (CI workflows,
    # daemons) can refuse to publish partial state.
    local exit_code
    exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$NAME" 2>/dev/null || echo "1")

    echo ""
    echo "--- Harvesting results ---"
    "$SWARM_DIR/harvest.sh"

    if [ "$exit_code" -ne 0 ]; then
        echo "WARNING: post-process container exited with code ${exit_code};" \
             "any commits harvested may represent partial state." >&2
        return "$exit_code"
    fi
}

case "${1:-start}" in
    validate)      cmd_validate ;;
    start)
        shift
        parse_start_args "$@"
        swarm_engagement_lock "$RUNTIME_DIR"
        cmd_start
        if $OPEN_DASHBOARD; then
            exec "$SWARM_DIR/dashboard.sh"
        fi
        ;;
    # stop is the emergency brake and must never block behind a stuck
    # lifecycle lock, so it (like the read-only logs/status) stays
    # lock-free.
    stop)          cmd_stop ;;
    cleanup)
        swarm_engagement_lock "$RUNTIME_DIR"
        cmd_cleanup
        ;;
    logs)          cmd_logs "${2:-1}" ;;
    status)        cmd_status ;;
    wait)
        swarm_engagement_lock "$RUNTIME_DIR"
        cmd_wait
        ;;
    post-process)
        swarm_engagement_lock "$RUNTIME_DIR"
        cmd_post_process
        ;;
    interactive)
        shift
        swarm_engagement_lock "$RUNTIME_DIR"
        cmd_interactive chat "$@"
        ;;
    chat)
        shift
        swarm_engagement_lock "$RUNTIME_DIR"
        cmd_interactive chat "$@"
        ;;
    shell)
        shift
        swarm_engagement_lock "$RUNTIME_DIR"
        cmd_interactive shell "$@"
        ;;
    *)
        echo "Usage: $0 {validate|start|stop|cleanup|logs N|status|wait|post-process|interactive}" >&2
        echo "Try '$0 --help' for more information." >&2
        exit 1
        ;;
esac
