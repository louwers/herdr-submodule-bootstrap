#!/usr/bin/env bash
# Initialise the submodules of a new Git worktree.
#
# Each submodule is cloned from the same submodule in the repository's main
# checkout, borrowing its objects (git clone --reference) instead of copying
# them, so nothing goes over the network. A submodule whose pinned commit the
# main checkout doesn't have is cloned from its real remote instead, still
# borrowing whatever objects the main checkout does have. Already-populated
# submodules are left alone, so re-running on an existing worktree is safe.
#
# Usage:
#   bootstrap.sh <worktree-path>   # run in the foreground (also for backfill)
#   bootstrap.sh                   # herdr worktree.created hook: reads the
#                                  # event from HERDR_PLUGIN_EVENT_JSON
set -euo pipefail

JOBS=8

# submodule_paths <checkout>: the paths of its submodules, NUL-terminated
submodule_paths() {
  local entry
  [[ -f $1/.gitmodules ]] || return 0
  git -C "$1" config -z --file .gitmodules --get-regexp '^submodule\..*\.path$' |
    while IFS= read -r -d '' entry; do printf '%s\0' "${entry#*$'\n'}"; done
}

# submodule_url <checkout> <path>: the URL registered for the submodule at <path>
submodule_url() {
  local key
  key=$(git -C "$1" config --file .gitmodules --name-only --fixed-value \
    --get-regexp '^submodule\..*\.path$' "$2") || return
  key=${key%%$'\n'*}
  git -C "$1" config "${key%.path}.url"
}

# reachable <git-dir> <commit>: whether one of the repository's refs reaches <commit>
reachable() {
  local unreached
  unreached=$(git --git-dir="$1" rev-list -n 1 "$2" --not --all 2>/dev/null) && [[ -z $unreached ]]
}

# init_one <reference-checkout> <checkout> <path>: one submodule and its nested ones
init_one() {
  local ref_root=$1 root=$2 path=$3 ref_git url src head nested
  if [[ -e $root/$path/.git ]]; then
    :
  elif [[ -e $ref_root/$path/.git ]]; then
    ref_git=$(git -C "$ref_root/$path" rev-parse --absolute-git-dir) || return
    url=$(submodule_url "$root" "$path") || url=
    if [[ -n $url ]] && reachable "$ref_git" "$(git -C "$root" rev-parse ":$path")"; then
      echo "==> $root/$path (from $ref_root/$path)"
      # Git percent-decodes file:// URLs, and -c splits at the first "=".
      src=${ref_git//%/%25}
      src=file://${src//=/%3D}
      # Redirect the clone to the main checkout's copy. The clone still
      # records the real URL as its origin, and --no-fetch keeps the checkout
      # from going back to that remote for a commit it already has.
      git -C "$root" -c protocol.file.allow=always -c "url.$src.insteadOf=$url" \
        submodule update --init --no-fetch --reference "$ref_root/$path" -- "$path" || return
      # The clone took the main checkout's local branches as its
      # remote-tracking branches; mirror its remote-tracking branches instead.
      git -C "$root/$path" -c protocol.file.allow=always fetch --quiet --prune --no-tags "$src" \
        '+refs/remotes/origin/*:refs/remotes/origin/*' '^refs/remotes/origin/HEAD' || return
      head=$(git --git-dir="$ref_git" symbolic-ref -q refs/remotes/origin/HEAD) &&
        git -C "$root/$path" symbolic-ref refs/remotes/origin/HEAD "$head"
    else
      echo "==> $root/$path (reference: $ref_root/$path)"
      git -C "$root" submodule update --init --reference "$ref_root/$path" -- "$path" || return
    fi
  else
    echo "==> $root/$path"
    git -C "$root" submodule update --init -- "$path" || return
  fi
  [[ -f $root/$path/.gitmodules ]] || return 0
  # Register the nested submodules first, so that their URLs are known.
  git -C "$root/$path" submodule init || return
  while IFS= read -r -d '' nested <&3; do
    init_one "$ref_root/$path" "$root/$path" "$nested" || return
  done 3< <(submodule_paths "$root/$path")
}
export -f init_one submodule_paths submodule_url reachable

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
  submodule_paths "$worktree" |
  xargs -0 -P "$JOBS" -I{} bash -c 'init_one "$@"' _ "$main_checkout" "$worktree" {} >>"$log" 2>&1; then
  echo "Submodules ready in $((SECONDS - start))s" | tee -a "$log"
else
  echo "Submodule setup failed, see $log" | tee -a "$log" >&2
  exit 1
fi
