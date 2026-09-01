#!/bin/bash

# Host-side target snapshot: clone TARGET_REPO@TARGET_REV (and the optional
# TARGET_REV_BASE) into private mirrors mounted read-only into every
# container, and pin the resolved commits.
#
# Sourced by launch.sh after lib/project.sh (for safe_runtime_remove).
# The functions rely on the caller-set globals RUNTIME_DIR,
# TARGET_MIRROR_DIR, TARGET_BASE_MIRROR_DIR, and STATE_FILE, and they
# set/export TARGET_REV, TARGET_REV_BASE, and TARGET_MIRROR_ARGS.

clone_repo_authenticated() {
    local source="$1" destination="$2" askpass="" rc=0
    if [ -n "${SWARM_READER_TOKEN:-}" ] && [[ "$source" == https://* ]]; then
        askpass=$(mktemp "$RUNTIME_DIR/reader-askpass.XXXXXX")
        cat > "$askpass" <<'EOF'
#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' x-access-token ;;
  *Password*) printf '%s\n' "${SWARM_READER_TOKEN:-}" ;;
  *) printf '\n' ;;
esac
EOF
        chmod 700 "$askpass"
        GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$askpass" \
            git clone --mirror --no-hardlinks -- "$source" "$destination" \
            || rc=$?
        rm -f "$askpass"
        return "$rc"
    fi
    GIT_TERMINAL_PROMPT=0 git clone --mirror --no-hardlinks -- \
        "$source" "$destination"
}

prepare_repo_mirror() {
    local source="$1" revision="$2" destination="$3" label="$4"
    local new old had_old=0 resolved
    # A later phase reuses the engagement's immutable snapshot: when the
    # mirror already holds the pinned commit on disk there is nothing to
    # re-resolve, so skip the clone entirely.
    if [[ "$revision" =~ ^[0-9a-f]{40}$ ]] && [ ! -L "$destination" ] \
            && [ -d "$destination" ] \
            && git -C "$destination" rev-parse --git-dir >/dev/null 2>&1; then
        if resolved=$(git -C "$destination" rev-parse --verify \
                "${revision}^{commit}" 2>/dev/null); then
            printf '%s' "$resolved"
            return 0
        fi
    fi
    new="$RUNTIME_DIR/.${label}.new.$$"
    old="$RUNTIME_DIR/.${label}.previous.$$"
    [ ! -e "$new" ] && [ ! -e "$old" ] || {
        echo "ERROR: ${label} mirror transaction path already exists." >&2
        return 1
    }
    echo "--- Resolving ${label}: ${source} # ${revision} ---" >&2
    if ! clone_repo_authenticated "$source" "$new"; then
        safe_runtime_remove "$new" 2>/dev/null || true
        echo "ERROR: cannot clone ${label} repository." >&2
        return 1
    fi
    resolved=$(git -C "$new" rev-parse --verify "${revision}^{commit}" \
        2>/dev/null) || {
        safe_runtime_remove "$new"
        echo "ERROR: ${label} revision does not resolve to a commit: $revision" >&2
        return 1
    }
    git -C "$new" fsck --no-dangling >/dev/null || {
        safe_runtime_remove "$new"
        echo "ERROR: ${label} mirror failed fsck." >&2
        return 1
    }
    chmod -R u+rwX,go-rwx "$new"
    if [ -e "$destination" ]; then
        [ ! -L "$destination" ] && [ -d "$destination" ] || {
            safe_runtime_remove "$new"
            echo "ERROR: existing ${label} mirror is not a directory." >&2
            return 1
        }
        mv "$destination" "$old"
        had_old=1
    fi
    if ! mv "$new" "$destination"; then
        [ "$had_old" -eq 0 ] || mv "$old" "$destination"
        safe_runtime_remove "$new" 2>/dev/null || true
        return 1
    fi
    [ "$had_old" -eq 0 ] || safe_runtime_remove "$old"
    printf '%s' "$resolved"
}

# Reconcile one caller-supplied revision against the snapshot revision the
# engagement recorded at start. A moving ref (or an empty value) yields to
# the recorded commit; a pinned commit that disagrees fails closed. Prints
# the effective revision, possibly empty.
swarm_target_reuse_rev() {
    local requested="$1" recorded="$2" label="$3"
    if [[ ! "$recorded" =~ ^[0-9a-f]{40}$ ]]; then
        printf '%s' "$requested"
        return 0
    fi
    if [ -z "$requested" ] || [[ ! "$requested" =~ ^[0-9a-f]{40}$ ]]; then
        printf '%s' "$recorded"
        return 0
    fi
    if [ "$requested" != "$recorded" ]; then
        echo "ERROR: requested ${label} ${requested} conflicts with" \
            "the engagement snapshot ${recorded}." >&2
        return 1
    fi
    printf '%s' "$requested"
}

prepare_target_mirrors() {
    TARGET_MIRROR_ARGS=()

    # Reuse the snapshot recorded in the state file when a later phase
    # re-runs with no target coordinates or with a moving ref: every phase
    # of one engagement works on the commit resolved at start.
    local state_repo="" state_rev="" state_base="" state_base_repo=""
    if [ -r "${STATE_FILE:-}" ]; then
        state_repo=$(jq -r '.target_repo // empty' "$STATE_FILE" \
            2>/dev/null || true)
        state_rev=$(jq -r '.target_rev // empty' "$STATE_FILE" \
            2>/dev/null || true)
        state_base=$(jq -r '.target_rev_base // empty' "$STATE_FILE" \
            2>/dev/null || true)
        state_base_repo=$(jq -r '.target_rev_base_repo // empty' \
            "$STATE_FILE" 2>/dev/null || true)
    fi

    if [ -z "${TARGET_REPO:-}" ]; then
        if [ -n "$state_repo" ]; then
            # No env coordinates: adopt the recorded snapshot verbatim.
            TARGET_REPO="$state_repo"
            TARGET_REV="$state_rev"
            TARGET_REV_BASE="${TARGET_REV_BASE:-$state_base}"
            TARGET_REV_BASE_REPO="${TARGET_REV_BASE_REPO:-$state_base_repo}"
        fi
    elif [ -n "$state_repo" ]; then
        [ "$TARGET_REPO" = "$state_repo" ] || {
            echo "ERROR: requested target ${TARGET_REPO} conflicts with" \
                "the engagement snapshot ${state_repo}." >&2
            return 1
        }
        TARGET_REV=$(swarm_target_reuse_rev "${TARGET_REV:-}" \
            "$state_rev" target) || return 1
        if [ -n "$state_base" ]; then
            local state_base_eff="${state_base_repo:-$state_repo}"
            if [ -n "${TARGET_REV_BASE_REPO:-}" ] \
                    && [ "$TARGET_REV_BASE_REPO" != "$state_base_eff" ]; then
                echo "ERROR: requested target base ${TARGET_REV_BASE_REPO}" \
                    "conflicts with the engagement snapshot" \
                    "${state_base_eff}." >&2
                return 1
            fi
            TARGET_REV_BASE_REPO="${TARGET_REV_BASE_REPO:-$state_base_repo}"
            TARGET_REV_BASE=$(swarm_target_reuse_rev "${TARGET_REV_BASE:-}" \
                "$state_base" "target base") || return 1
        fi
    fi

    if [ -z "${TARGET_REPO:-}" ] && [ -z "${TARGET_REV:-}" ]; then
        return 0
    fi
    [ -n "${TARGET_REPO:-}" ] && [ -n "${TARGET_REV:-}" ] || {
        echo "ERROR: TARGET_REPO and TARGET_REV are required." >&2
        return 1
    }
    TARGET_REV=$(prepare_repo_mirror "$TARGET_REPO" "$TARGET_REV" \
        "$TARGET_MIRROR_DIR" target)
    export TARGET_REV
    TARGET_MIRROR_ARGS=(-v "${TARGET_MIRROR_DIR}:/target-upstream:ro" \
        -e "SWARM_TARGET_MIRROR=/target-upstream" \
        -e "TARGET_REPO=${TARGET_REPO}" \
        -e "TARGET_REV=${TARGET_REV}")

    if [ -n "${TARGET_REV_BASE:-}" ] \
            && [ "${TARGET_REV_BASE_REPO:-$TARGET_REPO}" != "$TARGET_REPO" ]; then
        TARGET_REV_BASE=$(prepare_repo_mirror "$TARGET_REV_BASE_REPO" \
            "$TARGET_REV_BASE" "$TARGET_BASE_MIRROR_DIR" target-base)
        export TARGET_REV_BASE
        TARGET_MIRROR_ARGS+=(
            -v "${TARGET_BASE_MIRROR_DIR}:/target-base-upstream:ro"
            -e "SWARM_TARGET_BASE_MIRROR=/target-base-upstream")
    elif [ -n "${TARGET_REV_BASE:-}" ]; then
        TARGET_REV_BASE=$(git -C "$TARGET_MIRROR_DIR" rev-parse --verify \
            "${TARGET_REV_BASE}^{commit}") || {
            echo "ERROR: target base revision does not resolve to a commit." \
                >&2
            return 1
        }
        export TARGET_REV_BASE
    fi
    TARGET_MIRROR_ARGS+=(
        -e "TARGET_REV_BASE=${TARGET_REV_BASE:-}"
        -e "TARGET_REV_BASE_REPO=${TARGET_REV_BASE_REPO:-$TARGET_REPO}")
    echo "--- Target snapshot: ${TARGET_REV} ---"
}
