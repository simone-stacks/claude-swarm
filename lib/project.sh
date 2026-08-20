#!/bin/bash

# Shared project-name derivation for Docker, containers, and runtime paths.
# User-facing labels should keep the raw repository basename; internal
# Docker identifiers must be lowercase and separator-safe.

swarm_project_id() {
    local raw="${1:-}" lower out="" c last_sep=false i
    lower="$(printf '%s' "$raw" | LC_ALL=C tr '[:upper:]' '[:lower:]')"

    for ((i = 0; i < ${#lower}; i++)); do
        c="${lower:i:1}"
        case "$c" in
            [a-z0-9])
                out+="$c"
                last_sep=false
                ;;
            .|_|-)
                if [ -n "$out" ] && [ "$last_sep" = false ]; then
                    out+="$c"
                    last_sep=true
                fi
                ;;
            *)
                if [ -n "$out" ] && [ "$last_sep" = false ]; then
                    out+="-"
                    last_sep=true
                fi
                ;;
        esac
    done

    while [ -n "$out" ]; do
        case "${out: -1}" in
            [a-z0-9]) break ;;
            *) out="${out%?}" ;;
        esac
    done

    printf '%s' "${out:-swarm}"
}

# Private host-side state for one project. Keeping every coordination artifact
# below one owner-only directory avoids predictable world-writable objects in
# /tmp while preserving a deterministic path that independent lifecycle tools
# can discover.
swarm_runtime_dir() {
    local project="$1"
    if [ -n "${CLAUDE_SWARM_RUNTIME_DIR:-}" ]; then
        case "$CLAUDE_SWARM_RUNTIME_DIR" in
            /*) printf '%s' "$CLAUDE_SWARM_RUNTIME_DIR" ;;
            *) return 1 ;;
        esac
    else
        local state_home="${XDG_STATE_HOME:-${HOME:+$HOME/.local/state}}"
        if [ -n "$state_home" ]; then
            printf '%s/claude-swarm/%s' "$state_home" "$project"
        else
            printf '%s/%s-swarm-runtime' "${TMPDIR:-/tmp}" "$project"
        fi
    fi
}

swarm_runtime_init() {
    local project="$1" runtime owner mode uid
    runtime=$(swarm_runtime_dir "$project") || {
        echo "ERROR: CLAUDE_SWARM_RUNTIME_DIR must be absolute." >&2
        return 1
    }
    if [ -L "$runtime" ]; then
        echo "ERROR: swarm runtime path is a symlink: $runtime" >&2
        return 1
    fi
    if [ ! -e "$runtime" ]; then
        (umask 077; mkdir -p "$runtime") || return 1
    fi
    [ -d "$runtime" ] || {
        echo "ERROR: swarm runtime path is not a directory: $runtime" >&2
        return 1
    }
    uid=$(id -u)
    owner=$(stat -c '%u' "$runtime" 2>/dev/null \
        || stat -f '%u' "$runtime" 2>/dev/null) || return 1
    [ "$owner" = "$uid" ] || {
        echo "ERROR: swarm runtime path is not owned by uid $uid: $runtime" >&2
        return 1
    }
    chmod 700 "$runtime" || return 1
    mode=$(stat -c '%a' "$runtime" 2>/dev/null \
        || stat -f '%Lp' "$runtime" 2>/dev/null) || return 1
    [ "$mode" = 700 ] || {
        echo "ERROR: swarm runtime path must be mode 0700: $runtime" >&2
        return 1
    }
    swarm_runtime_migrate_legacy "$project" "$runtime" || return 1
    printf '%s' "$runtime"
}

# Preserve state created by releases that used predictable top-level /tmp
# paths. Migration is a same-owner move, never a delete: the bare repository,
# state file, and unlocked lock become the active private runtime; old mirrors
# are retained below legacy/ for inspection and rebuilt transactionally by the
# next start. A held legacy lock or any destination collision fails closed.
swarm_runtime_migrate_legacy() {
    local project="$1" runtime="$2" base="${TMPDIR:-/tmp}"
    local uid source destination legacy_dir item owner i
    local sources=() destinations=()
    [ "${CLAUDE_SWARM_MIGRATE_LEGACY:-1}" = 1 ] || return 0
    uid=$(id -u)

    source="$base/${project}-engagement.lock"
    if [ -e "$source" ]; then
        [ ! -L "$source" ] || {
            echo "ERROR: refusing legacy symlink lock: $source" >&2
            return 1
        }
        if ! (exec 9<>"$source"; flock -n 9); then
            echo "ERROR: legacy engagement lock is held: $source" >&2
            return 1
        fi
    fi

    for item in upstream.git engagement.lock; do
        source="$base/${project}-${item}"
        [ -e "$source" ] || continue
        sources+=("$source")
        destinations+=("$runtime/$item")
    done
    source="$base/${project}-swarm.env"
    if [ -e "$source" ]; then
        sources+=("$source")
        destinations+=("$runtime/legacy/swarm.env")
    fi

    legacy_dir="$runtime/legacy"
    for item in "$base/${project}-mirror-"*.git; do
        [ -e "$item" ] || continue
        sources+=("$item")
        destinations+=("$legacy_dir/$(basename "$item")")
    done

    # Validate the complete move set before changing any legacy path. This
    # makes collisions and ownership failures atomic from the operator's view.
    for ((i = 0; i < ${#sources[@]}; i++)); do
        source="${sources[$i]}" destination="${destinations[$i]}"
        [ ! -L "$source" ] || {
            echo "ERROR: refusing legacy symlink: $source" >&2
            return 1
        }
        owner=$(stat -c '%u' "$source" 2>/dev/null \
            || stat -f '%u' "$source" 2>/dev/null) || return 1
        [ "$owner" = "$uid" ] || {
            echo "ERROR: refusing legacy state not owned by uid $uid: $source" >&2
            return 1
        }
        [ ! -e "$destination" ] || {
            echo "ERROR: both legacy and private swarm state exist; preserve and resolve them explicitly:" >&2
            echo "  legacy: $source" >&2
            echo "  private: $destination" >&2
            return 1
        }
    done
    for ((i = 0; i < ${#sources[@]}; i++)); do
        source="${sources[$i]}" destination="${destinations[$i]}"
        [ "$(dirname "$destination")" = "$runtime" ] \
            || install -d -m 700 "$(dirname "$destination")"
        mv -- "$source" "$destination"
        chmod -R u+rwX,go-rwx "$destination"
        echo "Migrated legacy swarm state into private runtime: $source" >&2
    done
}

swarm_runtime_paths() {
    local project="$1" runtime
    runtime=$(swarm_runtime_dir "$project") || return 1
    printf 'runtime_dir=%s\n' "$runtime"
    printf 'bare_repo=%s/upstream.git\n' "$runtime"
    printf 'lock_file=%s/engagement.lock\n' "$runtime"
    printf 'state_file=%s/swarm-state.json\n' "$runtime"
    printf 'mirror_dir=%s/mirrors\n' "$runtime"
    printf 'agents_file=%s/agents.cfg\n' "$runtime"
    printf 'image_name=%s-agent\n' "$project"
    printf 'container_prefix=%s-agent-\n' "$project"
}
