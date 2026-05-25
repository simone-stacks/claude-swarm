#!/bin/bash
# Replay local commits onto a remote branch as GitHub-signed
# commits via the GraphQL createCommitOnBranch mutation.
# Source this file; do not exec.
#
# Why API replay instead of `git push`: when a commit is created
# via the GraphQL API and authenticated as a GitHub App
# installation, GitHub signs the commit with its own key and
# marks it Verified.  `git push` does not get this treatment
# regardless of the token used.  Replacing push with API replay
# is what lets a runner drop its local SSH signing key.
#
# Limitations of createCommitOnBranch:
#   - Single-parent only -- merge commits in the range are
#     skipped (the loop uses git log --no-merges).  Fine for
#     the typical agent flow: agent-work is a linear rebase
#     chain, and the harvest merge commit has no content of
#     its own.
#   - File mode (executable bit) is not preserved -- all files
#     land as 100644.  Acceptable when scripts can be invoked
#     via `bash script.sh`.
#   - Per-blob ceiling ~40 MiB (preflight at 35 MiB by default).
#     Workaround if ever needed: regular `git push` to a
#     throwaway ref, then createCommitOnBranch referencing the
#     uploaded tree.
#   - One commit per API call -- replaying N commits = N round
#     trips.
#
# Public functions (all require GH_TOKEN and GITHUB_REPOSITORY=
# owner/repo in the environment):
#   gh_publish_range BRANCH BASE HEAD
#       Facade: preflight + ensure branch + replay commits in
#       one call.  Returns 0 on success.
#   gh_preflight_blob_size BASE HEAD [MAX_BYTES]
#   gh_ensure_branch BRANCH OID
#   gh_replay_commits BRANCH BASE HEAD

# Defensive: the lib runs inside `git show ... | base64` pipes
# that must fail loudly if either side dies.  Callers set this
# too, but a sourced lib cannot depend on its caller's options.
set -o pipefail

MAX_BLOB_BYTES_DEFAULT=36700160  # 35 MiB.
GH_REPLAY_RETRIES=3
GH_REPLAY_RETRY_SLEEP=30

gh_publish_range() {
    local branch="$1" base="$2" head="$3"
    gh_preflight_blob_size "$base" "$head" || return 1
    gh_ensure_branch "$branch" "$base" || return 1
    gh_replay_commits "$branch" "$base" "$head" || return 1
}

# Walk only objects new in BASE..HEAD (rev-list --objects emits
# the union reachable from HEAD but unreachable from BASE), then
# cat-file --batch-check resolves type+size.  Pre-existing
# oversize blobs reachable only from BASE are irrelevant:
# createCommitOnBranch references parent trees by oid, no
# re-upload.
gh_preflight_blob_size() {
    local base="$1" head="$2" max="${3:-$MAX_BLOB_BYTES_DEFAULT}"
    local sha objtype objsize objpath bad=0

    # Materialise the object list to a tempfile so we can detect
    # bad SHAs (would silently yield an empty list under process
    # substitution).
    local objs
    objs=$(mktemp)
    trap 'rm -f "$objs"' RETURN
    if ! git rev-list --objects "$base..$head" > "$objs"; then
        echo "ERROR: git rev-list failed for $base..$head -- bad SHA?" >&2
        return 1
    fi

    while read -r sha objtype objsize objpath; do
        [ "$objtype" = "blob" ] || continue
        if [ "$objsize" -gt "$max" ]; then
            echo "ERROR: Blob ${sha:0:12} (${objpath:-<unnamed>}) is" \
                "${objsize} bytes; createCommitOnBranch ceiling is" \
                "~${max} bytes.  Externalise (artifact / release" \
                "asset) and commit a pointer instead." >&2
            bad=1
        fi
    done < <(git cat-file \
        --batch-check='%(objectname) %(objecttype) %(objectsize) %(rest)' \
        < "$objs")
    return $bad
}

gh_ensure_branch() {
    local branch="$1" oid="$2"
    local existing
    # On 404, gh CLI exits non-zero but with --jq still emits the
    # response body (the {"message":"Not Found"...} JSON) on
    # stdout -- not the empty string one might expect.  So drive
    # the branch-exists check off the exit code, not off whether
    # $existing is non-empty.
    if existing=$(gh api \
        "repos/$GITHUB_REPOSITORY/git/ref/heads/$branch" \
        --jq '.object.sha' 2>/dev/null); then
        if [ "$existing" = "$oid" ]; then
            return 0
        fi
        echo "ERROR: Branch $branch exists on origin at $existing," \
            "expected $oid.  Aborting to avoid clobber." >&2
        return 1
    fi
    gh api -X POST "repos/$GITHUB_REPOSITORY/git/refs" \
        -f ref="refs/heads/$branch" \
        -f sha="$oid" \
        --silent
}

gh_replay_commits() {
    local branch="$1" base="$2" head="$3"
    local expected="$base"
    local commit subject body changes payload response new_oid

    local commits=()
    while IFS= read -r commit; do
        [ -n "$commit" ] && commits+=("$commit")
    done < <(git log --reverse --no-merges --format='%H' \
        "$base..$head")

    if [ "${#commits[@]}" -eq 0 ]; then
        echo "No non-merge commits to replay in $base..$head"
        return 0
    fi

    echo "Replaying ${#commits[@]} commit(s) onto $branch via" \
        "createCommitOnBranch..."

    for commit in "${commits[@]}"; do
        subject=$(git log -1 --format='%s' "$commit")
        body=$(git log -1 --format='%b' "$commit")
        changes=$(_gh_replay_collect_changes "$commit") || return 1

        local change_count
        change_count=$(jq -r \
            '(.additions | length) + (.deletions | length)' \
            <<<"$changes")
        if [ "$change_count" = "0" ]; then
            echo "  ${commit:0:12} -- skipped (no file changes)"
            continue
        fi

        payload=$(jq -n \
            --arg owner_repo "$GITHUB_REPOSITORY" \
            --arg branch "$branch" \
            --arg expected "$expected" \
            --arg subject "$subject" \
            --arg body "$body" \
            --argjson changes "$changes" \
            '{
               query: "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
               variables: {
                 input: {
                   branch: { repositoryNameWithOwner: $owner_repo, branchName: $branch },
                   expectedHeadOid: $expected,
                   message: { headline: $subject, body: $body },
                   fileChanges: $changes
                 }
               }
             }')

        response=$(_gh_api_graphql_with_retry "$payload") || {
            echo "ERROR: createCommitOnBranch failed for" \
                "${commit:0:12}" >&2
            return 1
        }

        new_oid=$(jq -r \
            '.data.createCommitOnBranch.commit.oid // empty' \
            <<<"$response" 2>/dev/null)
        if [ -z "$new_oid" ]; then
            echo "ERROR: createCommitOnBranch returned no oid for" \
                "${commit:0:12}: $response" >&2
            return 1
        fi

        echo "  ${commit:0:12} -> ${new_oid:0:12}  $subject"
        expected="$new_oid"
    done
}

# Walk diff-tree once per commit.  Emit one NDJSON line per file
# change, then slurp into {additions, deletions} in a single jq
# pass.  Avoids the O(n^2) accumulator-rewriting cost of per-file
# jq calls re-emitting the whole array.
#
# diff-tree --name-status status codes handled:
#   A/M/T  -> addition (file content at $commit)
#   D      -> deletion
#   R*     -> deletion of old path + addition of new path
#   C*     -> addition of new path (source unchanged)
_gh_replay_collect_changes() {
    local commit="$1"
    local stream tmp status rest path old new
    stream=$(mktemp)
    tmp=$(mktemp)
    # Funnel file content through a temp file (jq --rawfile)
    # instead of --arg to dodge ARG_MAX: a 1.5 MiB raw file
    # becomes ~2 MiB base64, exceeding the typical argv ceiling
    # on Linux.
    trap 'rm -f "$stream" "$tmp"' RETURN

    while IFS=$'\t' read -r status rest; do
        case "$status" in
            A|M|T)
                path="$rest"
                git show "$commit:$path" | base64 -w0 > "$tmp"
                jq -nc --arg p "$path" --rawfile c "$tmp" \
                    '{op:"add", path:$p, contents:$c}' >> "$stream"
                ;;
            D)
                path="$rest"
                jq -nc --arg p "$path" \
                    '{op:"del", path:$p}' >> "$stream"
                ;;
            R*)
                old="${rest%%$'\t'*}"
                new="${rest##*$'\t'}"
                git show "$commit:$new" | base64 -w0 > "$tmp"
                jq -nc --arg p "$old" \
                    '{op:"del", path:$p}' >> "$stream"
                jq -nc --arg p "$new" --rawfile c "$tmp" \
                    '{op:"add", path:$p, contents:$c}' >> "$stream"
                ;;
            C*)
                new="${rest##*$'\t'}"
                git show "$commit:$new" | base64 -w0 > "$tmp"
                jq -nc --arg p "$new" --rawfile c "$tmp" \
                    '{op:"add", path:$p, contents:$c}' >> "$stream"
                ;;
        esac
    done < <(git diff-tree --no-commit-id -r --name-status "$commit")

    jq -s '{
        additions: [ .[] | select(.op == "add") | {path, contents} ],
        deletions: [ .[] | select(.op == "del") | {path} ]
    }' "$stream"
}

# Retry transient GraphQL failures (5xx, network blips) with a
# fixed 3-attempt / 30 s cadence.  Bails immediately on errors
# that will not self-heal: stale expectedHeadOid (concurrent
# push), auth failure.  Rate limits surface as 403/429, not 422,
# so they DO get the retry budget.
_gh_api_graphql_with_retry() {
    local payload="$1"
    local attempt=1 response
    while true; do
        if response=$(echo "$payload" \
            | gh api graphql --input - 2>&1); then
            printf '%s' "$response"
            return 0
        fi
        # Fail fast on errors retrying will not fix.
        case "$response" in
            *expectedHeadOid*|*"Bad credentials"*|*"Resource not accessible"*)
                echo "$response" >&2
                return 1
                ;;
        esac
        if [ "$attempt" -ge "$GH_REPLAY_RETRIES" ]; then
            echo "$response" >&2
            return 1
        fi
        echo "WARNING: createCommitOnBranch attempt $attempt" \
            "failed; retrying in ${GH_REPLAY_RETRY_SLEEP}s" >&2
        sleep "$GH_REPLAY_RETRY_SLEEP"
        attempt=$((attempt + 1))
    done
}
