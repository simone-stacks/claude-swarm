#!/bin/bash
set -euo pipefail

# Replay local commits onto a remote branch as GitHub-signed
# commits via the createCommitOnBranch GraphQL mutation.
# Usage: ./publish.sh --branch <name> --base <sha> [--head <sha>]
#                     [--dry] [--help]

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/check-deps.sh
source "$SWARM_DIR/lib/check-deps.sh"
# shellcheck source=lib/publish-github.sh
source "$SWARM_DIR/lib/publish-github.sh"
check_deps git gh jq base64

BRANCH=""
BASE=""
HEAD_REF=""
DRY_RUN=false

usage() {
    cat <<HELP
Usage: $0 --branch <name> --base <sha> [--head <sha>] [--dry]

Replay local commits in BASE..HEAD onto remote branch BRANCH as
GitHub-App-signed commits via the createCommitOnBranch GraphQL
mutation.  Commits land on the remote signed by GitHub's key and
marked Verified, which a plain \`git push\` cannot achieve.

Required environment:
  GH_TOKEN            GitHub App installation token (or PAT with
                      contents:write on the target repo).
  GITHUB_REPOSITORY   owner/repo of the publication target.

Options:
  --branch NAME    Remote branch to publish to.  Created if missing;
                   must already point at BASE if it exists.
  --base SHA       Parent commit on the remote.  BRANCH must be at
                   this SHA before the replay begins.
  --head SHA       Local commit at the tip of the range to replay.
                   Defaults to HEAD.
  --dry            Run preflight (blob-size check) only; make no API
                   calls.
  -h, --help       Show this help message.

Limitations: single-parent commits only (merges are skipped);
file mode is not preserved; per-blob ceiling is ~35 MiB; one API
call per commit.  See lib/publish-github.sh for details.
HELP
}

while [ $# -gt 0 ]; do
    case "$1" in
        --branch)
            BRANCH="${2:-}"
            if [ -z "$BRANCH" ]; then
                echo "ERROR: --branch requires a value." >&2
                exit 1
            fi
            shift 2
            ;;
        --base)
            BASE="${2:-}"
            if [ -z "$BASE" ]; then
                echo "ERROR: --base requires a value." >&2
                exit 1
            fi
            shift 2
            ;;
        --head)
            HEAD_REF="${2:-}"
            if [ -z "$HEAD_REF" ]; then
                echo "ERROR: --head requires a value." >&2
                exit 1
            fi
            shift 2
            ;;
        --dry)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1 (try --help)" >&2
            exit 1
            ;;
    esac
done

if [ -z "$BRANCH" ]; then
    echo "ERROR: --branch is required (try --help)." >&2
    exit 1
fi
if [ -z "$BASE" ]; then
    echo "ERROR: --base is required (try --help)." >&2
    exit 1
fi
if [ -z "${GH_TOKEN:-}" ]; then
    echo "ERROR: GH_TOKEN is required in the environment." >&2
    exit 1
fi
if [ -z "${GITHUB_REPOSITORY:-}" ]; then
    echo "ERROR: GITHUB_REPOSITORY is required (owner/repo)." >&2
    exit 1
fi

# Resolve --head against the current working tree so callers can
# pass a branch name, tag, or short SHA and we still feed full
# oids to the API.
HEAD_SHA=$(git rev-parse "${HEAD_REF:-HEAD}")
BASE_SHA=$(git rev-parse "$BASE")

echo "--- Preflight ---"
gh_preflight_blob_size "$BASE_SHA" "$HEAD_SHA"

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "(dry run -- skipping branch ensure and replay)"
    exit 0
fi

echo ""
echo "--- Ensuring remote branch ---"
gh_ensure_branch "$BRANCH" "$BASE_SHA"

echo ""
echo "--- Replaying commits ---"
gh_replay_commits "$BRANCH" "$BASE_SHA" "$HEAD_SHA"

echo ""
echo "--- Done ---"
echo "Published $BASE_SHA..$HEAD_SHA to" \
    "$GITHUB_REPOSITORY:$BRANCH as signed commits."
