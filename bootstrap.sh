#!/usr/bin/env bash
# Initialise the submodules of a new Git worktree.
#
# Objects are borrowed (git clone --reference) from the same submodule in the
# repository's main checkout, so nothing that is already on disk gets
# downloaded again; anything missing there is fetched from the submodule's
# real remote. Already-populated submodules are left alone, so re-running on
# an existing worktree is safe.
#
# Usage:
#   bootstrap.sh <worktree-path>   # run in the foreground (also for backfill)
#   bootstrap.sh                   # herdr worktree.created hook: reads the
#                                  # event from HERDR_PLUGIN_EVENT_JSON
set -euo pipefail

JOBS=8

# submodule_paths <checkout>: one submodule path per line
submodule_paths() {
  [[ -f $1/.gitmodules ]] || return 0
  git -C "$1" config --file .gitmodules --get-regexp '^submodule\..*\.path$' | cut -d' ' -f2-
}

# init_one <reference-checkout> <checkout> <path>: one submodule and its nested ones
init_one() {
  local ref_root=$1 root=$2 path=$3 nested
  if [[ -e $root/$path/.git ]]; then
    :
  elif [[ -e $ref_root/$path/.git ]]; then
    echo "==> $root/$path (reference: $ref_root/$path)"
    git -C "$root" submodule update --init --reference "$ref_root/$path" -- "$path" || return
  else
    echo "==> $root/$path"
    git -C "$root" submodule update --init -- "$path" || return
  fi
  while read -r nested <&3; do
    init_one "$ref_root/$path" "$root/$path" "$nested" || return
  done 3< <(submodule_paths "$root/$path")
}
export -f init_one submodule_paths

quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

worktree=${1:-}
if [[ -z $worktree ]]; then
  event=${HERDR_PLUGIN_EVENT_JSON:-null}
  worktree=$(jq -r 'first(.. | objects | .worktree?.path? // empty)' <<<"$event")
  if [[ -z $worktree || ! -f $worktree/.gitmodules ]]; then
    exit 0
  fi
  # Hand the work to the new workspace's first pane: its prompt only returns
  # once the submodules are ready, and anything typed there queues behind it.
  # Without a pane, fall through and run in the background instead.
  pane=$(jq -r 'first(.. | objects | .root_pane?.pane_id? // empty)' <<<"$event")
  if [[ -z $pane ]]; then
    workspace=$(jq -r 'first(.. | objects | .workspace?.workspace_id? // empty)' <<<"$event")
    [[ -n $workspace ]] && pane=$("${HERDR_BIN_PATH:-herdr}" pane list --workspace "$workspace" 2>/dev/null |
      jq -r 'first(.. | objects | .pane_id? // empty)' || true)
  fi
  script=${HERDR_PLUGIN_ROOT:-$(dirname "$0")}/bootstrap.sh
  # The leading space keeps the command out of shell history where supported.
  if [[ -n $pane ]] &&
    "${HERDR_BIN_PATH:-herdr}" pane run "$pane" " bash $(quote "$script") $(quote "$worktree")" >/dev/null; then
    exit 0
  fi
fi
if [[ ! -d $worktree ]]; then
  echo "not a directory: $worktree" >&2
  exit 1
fi
worktree=$(cd "$worktree" && pwd -P)
[[ -f $worktree/.gitmodules ]] || exit 0

main_checkout=$(git -C "$worktree" worktree list --porcelain | sed -n '1s/^worktree //p')
log=$(git -C "$worktree" rev-parse --absolute-git-dir)/submodule-bootstrap.log

start=$SECONDS
echo "Initialising submodules from $main_checkout (log: $log)" | tee "$log"
# Register the top-level submodules once, up front: the parallel updates below
# would otherwise race for the lock on the shared .git/config.
if git -C "$worktree" submodule init >>"$log" 2>&1 &&
  submodule_paths "$worktree" | tr '\n' '\0' |
  xargs -0 -P "$JOBS" -I{} bash -c 'init_one "$@"' _ "$main_checkout" "$worktree" {} >>"$log" 2>&1; then
  echo "Submodules ready in $((SECONDS - start))s" | tee -a "$log"
else
  echo "Submodule setup failed, see $log" | tee -a "$log" >&2
  exit 1
fi
