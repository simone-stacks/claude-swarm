#!/bin/bash

# Clone through Git's transport instead of copying object files across a
# host bind mount and the container filesystem. Retry transient mount errors
# during bootstrap without consuming the agent session's retry budget.
swarm_clone_upstream() {
    local source="$1" destination="$2"
    local log_fn="$3" log_err_fn="$4"
    local max_attempts=5 attempt=1 delay=1

    "$log_fn" "cloning upstream"
    while true; do
        if git clone -q --no-local "$source" "$destination"; then
            return 0
        fi

        if [ "$attempt" -ge "$max_attempts" ]; then
            "$log_err_fn" \
                "upstream clone failed after ${attempt} attempts"
            return 1
        fi

        "$log_err_fn" \
            "upstream clone attempt ${attempt}/${max_attempts} failed;" \
            "retrying in ${delay}s"
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
}

# Initialize every mirrored submodule, including nested ones. The host writes
# /mirrors/manifest.tsv as "display-path<TAB>repo-relative-mirror". Walking
# initialized repositories breadth-first lets each nested .gitmodules file be
# interpreted by the repository that owns it instead of assuming top-level
# names or .git/modules layout.
swarm_init_mirrored_submodules() {
    local root="${1:-/workspace}" mirror_root="${2:-/mirrors}"
    local manifest="$mirror_root/manifest.tsv"
    [ -f "$manifest" ] || return 0

    local queue=("") cursor=0 prefix repo key path name display mirror
    while [ "$cursor" -lt "${#queue[@]}" ]; do
        prefix="${queue[$cursor]}"
        cursor=$((cursor + 1))
        repo="$root${prefix:+/$prefix}"
        [ -f "$repo/.gitmodules" ] || continue
        while read -r key path; do
            [ -n "$path" ] || continue
            name="${key#submodule.}"
            name="${name%.path}"
            display="${prefix:+$prefix/}$path"
            mirror=$(awk -F '\t' -v p="$display" \
                '$1 == p {print $2; exit}' "$manifest")
            [ -n "$mirror" ] || continue
            [ -d "$mirror_root/$mirror" ] || {
                echo "ERROR: mirror manifest entry is missing: $display" >&2
                return 1
            }
            git -C "$repo" config "submodule.${name}.url" \
                "$mirror_root/$mirror"
            git -C "$repo" submodule update --init -q -- "$path"
            queue+=("$display")
        done < <(git -C "$repo" config --file .gitmodules \
            --get-regexp 'submodule\..*\.path' || true)
    done
}
