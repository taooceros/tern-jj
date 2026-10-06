# tern-jj

English | [日本語](README.ja.md)

A Luau plugin development environment for adding Jujutsu support to Tern.
It renders `jj status` and `jj st` output as native cards, and adds a native
**Jujutsu** block that lists changes and shows their diffs, like Tern's Git block.
It does not replace Tern's existing Git UI.

## Requirements

- macOS, a desktop session, and access to a Tern account
- Tern installed at `/Applications/Tern.app`
- `mise`, `jj`, and Python 3 (for the smoke check)

Verified with Tern 0.4.1, jj 0.45.1, and luau-lsp 1.70.1.
If Tern is installed elsewhere, override its path, for example:
`TERN=/path/to/tern mise run dev`.

## Getting started

```sh
mise trust
mise install github:JohnnyMorganz/luau-lsp@1.70.1
mise run setup
mise run check
mise run dev
```

Tern executes Luau directly; no compilation or bundling is required.
`check` performs static type checking, and `dev` launches Tern.
Run `jj status` in the opened pane to display a "Jujutsu status" card.
The card colors additions green, modifications/renames yellow, and deletions red.
Change IDs use the accent color, commit IDs use the info color, and a clean
working copy uses green. Colors follow the active Tern theme; unrecognized lines stay unchanged.
Errors, empty output, and output exceeding 5,000 lines remain in Raw view.
Status commands with additional arguments, `jj diff`, and other commands are not
captured by this lens and retain their normal output.

### Log lens

`jj` and `jj log` (with any revset or limit) render as a native "Jujutsu log" card:
the commit graph drawn natively (see below) with author-initial avatars on the nodes (where the author changes; dots elsewhere), a lane
color bar, change ID, flags (conflict, divergent, empty), bookmark and tag pills,
description, muted date and commit ID, one row per change.
Click a row to copy its change ID.
Output in another format (`-T`/`--template`, `--no-graph`, `-p`, `-s`, `--stat`, …),
errors, and output the lens can't read stay raw.

### Jujutsu block

Run **Open Jujutsu changes** from the palette (⌥⌘J) in a pane inside a jj repository.
The block opens beside it, or focuses the one already open in the tab, and shows:

- a toolbar (pinned with the column header while the graph scrolls): the working copy and
  icon buttons for refresh, fetch (`jj git fetch`), undo, redo, new, edit and diff. In a pane
  too narrow for the columns (or for a wide graph), the rows and the column header scroll
  sideways together, as in Tern's Git block; the toolbar and the dock stay put.
- every visible change (`jj log -r 'all()'`, the latest 200), not just jj's default log revset, as a native commit graph in the look of Tern's
  Git block: columns Bookmarks / Graph / Description / Date / Change, bookmark and tag pills
  on the left joined to their node by a hairline (the bookmark on the working copy is filled),
  round avatars on the lanes where the authors change and at the top of every branch, dots for
  the rest; an avatar shows the author's GitHub picture when GitHub knows their email, else
  their initials. A change with several authors (`Co-authored-by:` trailers, or a merge
  whose other parents are by someone else) adds a small badge on the avatar's corner: the
  other author's face or initial, or `+N` for several; hovering the avatar and the dock list
  everyone. A lane-colored bar before the description,
  muted dates, monospace change IDs with the unique prefix highlighted, a Working copy
  row with file-count pills, and a footer. Forks, merges and elided revisions follow jj's layout;
  the working copy is a ring, immutable changes diamonds, conflicts and divergence pills in red.
- the selected change's summary, files (kind, path, `+`/`−` counts) and key hints in the dock.
- its diff in a full-height sheet (`Enter`, `d`, the toolbar's diff button or a double-click), one
  collapsible card per file; `↑`/`↓` move to the next change with the sheet open, `Esc` closes it.
- keys: `↑`/`↓` (or `k`/`j`), `g`/`G`, `@` (jump to the working copy), `n` (`jj new` on the
  selected change), `e` (`jj edit`), `u` (`jj undo`), `r` (refresh). The toolbar has buttons for the same operations.

The `jj log` lens draws jj's own layout (`ui.graph.style=curved`): `graph.luau` reads each graph
character as strokes from its cell's center, and `jj.css` draws them, so lanes stay
continuous whatever the row height. A branch leaves its lane at a right angle and turns in one
curve into the lane it joins: from the side of the change's node when the fork or merge is next
to it, else from a dot on the lane. The Jujutsu block lays the lanes out itself, as Tern's Git
block does: it follows jj's strokes to find each change's parents, keeps every edge on its own
lane down to its parent, and turns it into the parent's row there, so a parent's children stem
from it at different lengths and jj's junction rows go away.

Every operation is a plain `jj` command, so `u` reverts any of them. The block reloads
after every `jj` command that finishes in a Tern pane. Outside a repository it shows
jj's error and a Retry button. jj is looked up on the daemon's `PATH`, then in the usual
Homebrew, Cargo, Nix and zerobrew locations.

## Editing and verification

- `host.luau`: host-side lens implementation; loads the block from `changes.luau`. Saving reloads it automatically.
- `changes.luau`: the Jujutsu block.
- `avatars.luau`: the authors' GitHub pictures for the block. It sends each author's email to
  GitHub once per daemon: a noreply address to its account's picture, any other through
  GitHub's email lookup (`avatars.githubusercontent.com/u/e?email=…`). GitHub's placeholder for
  an unknown email, or no network, keeps the initials. The `jj log` lens has no images and
  always shows initials.
- `graph.luau` and `jj.css`: the native commit graph shared by the block and the log lens.
- `loglens.luau`: the `jj`/`jj log` lens.
- `window.luau`: the palette command and its ⌥⌘J binding.
- `plugin.toml`: declares the entry points, the block and the command patterns to capture.
- `mise run reload`: manually reloads the development daemon's plugins; requires `dev` to be running.
- `mise run smoke`: uses a temporary jj repository and an independent Tern window
  to verify clean output, added/modified/deleted/renamed file colors, change/commit
  ID colors, and error output outside a repository. Stops the test window and daemon on exit.
- `mise run graphshot` (or `python3 tests/graphshot.py [ROOT]`): opens the Jujutsu block on a
  temporary repo with a fork and a merge in an independent Tern window, prints how many curved
  corners and junction dots it drew, and writes `.dev/shots/live/graph.png` and the graph column
  crop `graph-crop.png`. Pass another checkout as `ROOT` (e.g. `jj workspace add -r @-`) to
  compare before and after.
- Screenshot: `.dev/shots/live/jj-status.png`
- Rendered element snapshot: `.dev/status-tree.json`
- Development logs: `.dev/logs/`
- Smoke check logs: `.dev/smoke-process.log` and `.dev/smoke-logs/`

For VS Code, install the recommended **Luau Language Server** extension.
`.vscode/settings.json` disables the Roblox environment and loads Tern's type definitions.
Run `mise run types` to regenerate `tern.d.luau` from the installed Tern.
This generated file is not tracked; regenerate it after updating Tern.
`types/luau.d.luau` declares the nominal `userdata` base type missing from the
standard environment so that Tern's `extern` types can be checked.
It does not bypass type checking with `any`.

## Isolation from the normal environment

Development environment variables are scoped to the `mise` tasks, not exported
when mise activates this directory. Running `tern plugin install` from the repository
therefore targets normal Tern. In an already-open shell, let the next mise prompt
hook refresh the environment, or run `eval "$(mise hook-env -s zsh)"` for zsh.

The tasks use:

- Settings, plugin links, and plugin data: `.dev/config/`
- Session daemon socket: `.dev/daemon.sock`
- Window control socket: `.dev/control.sock`
- zsh startup configuration: `dev/zsh/` (does not load personal rc files or aliases)

`dev/settings.json` is copied to `.dev/config/settings.json` only on first setup.
Existing development settings are not overwritten. Automatic updates are disabled
in the development profile.
The repository root is linked as the plugin package.
`tern-sdk/` is retained unchanged as the distributed SDK and examples.

The development zsh profile uses the official shell integration cached by Tern.
The plugin injects `JJ_PAGER=cat` when Tern spawns a new shell to prevent interactive
pagers from aborting lens capture. Personal shell and Jujutsu configuration files
are not modified.

## Loading in production (normal Tern)

Use `install` rather than `link` to deploy a copy in production.
This prevents edits saved during development from immediately affecting your
normal Tern session.
luau-lsp, Python, and the development zsh configuration are not required to run
the plugin in production.

### Initial installation

The subshell clears any inherited configuration, socket, and window overrides
(for example, from a development Tern pane).
It does not change the parent shell's environment variables.

```sh
(
  unset TERN_CONFIG_DIR TERN_DAEMON_SOCKET TERN_WINDOW_KEY TERN_WINDOW_SOCKET
  /Applications/Tern.app/Contents/MacOS/tern plugin install github.com/resYuto/tern-jj &&
  /Applications/Tern.app/Contents/MacOS/tern plugin list
)
```

GitHub installation requires `plugin.toml` and its entry point at the repository
root. No local checkout is needed.

On macOS, the installation directory is normally
`~/Library/Application Support/Tern/plugins/jj/`.
If the normal daemon is running, installation automatically reloads its plugins.
If you see `no daemon running; changes apply at next start`, start normal Tern.
In that case, `ready` in `list` only indicates a valid manifest; it does not
confirm that the Lua code has run.

If you previously used `link` in the normal environment, run `tern plugin unlink jj`
in a subshell with the same environment overrides cleared before installing.
Even `install --force` cannot replace a linked package.

### Verifying loading and rendering

In normal Tern, confirm that Jujutsu is Ready under Preferences › Plugins,
that the plugin is enabled, and that Settings › Terminal › Native command output
is enabled. Open a new pane with shell integration active after loading the plugin,
change to a jj repository and run:

```sh
jj status
```

A "Jujutsu status" card confirms that the host-side plugin loaded and the lens works.
The Raw toggle shows the original output. The plugin sets `JJ_PAGER=cat` for all jj
commands in new panes, replacing any inherited value. Existing panes are unchanged;
open a new pane after installing or reloading the plugin. Shell startup files or
explicit command-local assignments can override the injected value.

### Updating

Editing local source does not update the installed copy.
After publishing the checked changes to GitHub, explicitly replace it:

```sh
(
  unset TERN_CONFIG_DIR TERN_DAEMON_SOCKET TERN_WINDOW_KEY TERN_WINDOW_SOCKET
  /Applications/Tern.app/Contents/MacOS/tern plugin install github.com/resYuto/tern-jj --force &&
  /Applications/Tern.app/Contents/MacOS/tern plugin list
)
```

### Disabling or removing

Temporarily disable the plugin under Preferences › Plugins.
To remove the installed copy, run the following. The development source is retained.

```sh
(
  unset TERN_CONFIG_DIR TERN_DAEMON_SOCKET TERN_WINDOW_KEY TERN_WINDOW_SOCKET
  /Applications/Tern.app/Contents/MacOS/tern plugin remove jj
)
```

If you deployed with `link`, use `unlink jj` instead of `remove`.

## Official documentation

- [Getting Started](https://docs.stencil.so/tern/guides/getting-started.html)
- [Command Lenses](https://docs.stencil.so/tern/guides/lenses.html)
- [Debugging / control endpoint](https://docs.stencil.so/tern/guides/debugging.html)
- [Plugin CLI](https://docs.stencil.so/tern/reference/cli.html)
