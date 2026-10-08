# herdr-submodule-bootstrap

A [Herdr](https://herdr.dev) plugin that initialises Git submodules in the
worktrees Herdr creates.

`git worktree add` only checks out the superproject, so every submodule in a
new worktree starts out as an empty directory, and
`git submodule update --init --recursive` would clone each of them from the
network again. This plugin hooks Herdr's `worktree.created` event and fills
them in. It borrows objects from the repository's main checkout, so usually
almost nothing needs to be downloaded.

## Install

```sh
herdr plugin install louwers/herdr-submodule-bootstrap
```

Needs `bash`, `git` and `jq` on the `PATH` of the Herdr server. Tested on
Linux.

## What it does

When you create a worktree from Herdr (**New worktree** in the sidebar, or
`herdr worktree create`) in a repository that has a `.gitmodules` file:

1. The plugin runs the setup in the new workspace's first pane. The prompt
   comes back once the submodules are ready, so anything you type there in the
   meantime, such as starting an agent or a build, runs after the setup.
   Other panes you open in that workspace don't wait.
2. Each submodule is cloned with
   `git submodule update --init --reference <main checkout>/<path>`, nested
   submodules included, with up to 8 top-level submodules cloning at once.
   Objects that the main checkout's copy of the submodule already has are
   shared through Git alternates instead of copied. Anything else, such as a
   newer pinned commit, is fetched from the submodule's own remote. Submodules
   that aren't checked out in the main checkout are cloned normally.
3. Submodules that are already checked out are left alone, so running the
   setup again is harmless.

Git's output goes to `submodule-bootstrap.log` in the worktree's Git directory
(`git rev-parse --absolute-git-dir`). Git deletes that directory along with
the worktree. Repositories without a `.gitmodules` file are skipped.

For [MapLibre Native](https://github.com/maplibre/maplibre-native), with 62
submodules and 1.4 GB of submodule history, a new worktree is ready in about 20
seconds.

## Existing worktrees

The script also works on its own. To fill in a worktree that was created
before you installed the plugin, or by another tool:

```sh
plugin_root=$(herdr plugin list --json |
  jq -r '.result.plugins[] | select(.plugin_id == "louwers.submodule-bootstrap") | .plugin_root')
bash "$plugin_root/bootstrap.sh" /path/to/worktree
```

## Caveats

- The borrowed objects stay in the main checkout's `.git/modules`. Every
  linked worktree already depends on the main checkout's `.git` directory, so
  this adds little risk. Still, avoid deleting the main checkout's submodules
  or pruning their history while worktrees depend on them.
- `git worktree remove` refuses to remove a worktree that contains
  submodules. Herdr's **Delete worktree checkout** therefore always asks
  whether to force the removal, so check for uncommitted work before you
  confirm.

## License

[MIT](LICENSE)
