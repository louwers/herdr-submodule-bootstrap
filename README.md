# herdr-submodule-bootstrap

A [Herdr](https://herdr.dev) plugin that initialises Git submodules in the
worktrees Herdr creates.

`git worktree add` only checks out the superproject, so every submodule in a
new worktree starts out as an empty directory, and
`git submodule update --init --recursive` would clone each of them from the
network again. This plugin hooks Herdr's `worktree.created` event and fills
them in. It clones each submodule from the repository's main checkout and
shares that checkout's objects, so usually nothing needs to be downloaded.

## Install

```sh
herdr plugin install louwers/herdr-submodule-bootstrap
```

Needs `bash`, `git` (2.30 or later) and `jq` on the `PATH` of the Herdr
server. Tested on Linux.

## What it does

When you create a worktree from Herdr (**New worktree** in the sidebar, or
`herdr worktree create`) in a repository that has a `.gitmodules` file:

1. The plugin runs the setup in the new workspace's first pane. The prompt
   comes back once the submodules are ready, so anything you type there in the
   meantime, such as starting an agent or a build, runs after the setup.
   Other panes you open in that workspace don't wait.
2. Each submodule, nested submodules included, is cloned from the same
   submodule in the main checkout, with up to 8 top-level submodules cloning
   at once. The clone shares the main checkout's objects through Git
   alternates instead of copying them, and doesn't touch the network. It still
   gets the submodule's real URL as `origin`, and its remote-tracking branches
   match the main checkout's, as of that checkout's last fetch.
3. If the main checkout doesn't have the commit a submodule is pinned to, such
   as a submodule bump on a branch that you haven't checked out yet, that
   submodule is cloned from its own remote with
   `git submodule update --init --reference <main checkout>/<path>`. Only
   objects that the main checkout lacks are downloaded. Submodules that aren't
   checked out in the main checkout are cloned normally.
4. Submodules that are already checked out are left alone, so running the
   setup again is harmless.

Git's output goes to `submodule-bootstrap.log` in the worktree's Git directory
(`git rev-parse --absolute-git-dir`). Git deletes that directory along with
the worktree. Repositories without a `.gitmodules` file are skipped.

For [MapLibre Native](https://github.com/maplibre/maplibre-native), with 62
submodules and 1.4 GB of submodule history, a new worktree is ready in about 2
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
