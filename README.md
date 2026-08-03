# herdr-pane-navigator

![Demo](https://raw.githubusercontent.com/mr04vv/herdr-pane-navigator/main/docs/assets/demo.gif)

One fuzzy tree over every workspace, tab, and pane in [herdr](https://herdr.dev),
led by what each pane is actually doing. Coding agents put the current task in
their terminal title; this navigator makes that the thing you read, so three
Claude panes stop looking like three rows that all say `claude`.

Rows are ordered `blocked > done > working > idle`, and a workspace or tab
inherits the urgency of its most urgent descendant — so the workspace holding a
blocked agent floats to the top without the tree coming apart. The pane you are
currently in sorts last, so `enter` takes you somewhere else.

Press `a` inside the navigator to flip to a flat, agent-only list, and `s` to go
back to the full tree.

## Requirements

`herdr` ≥ 0.7.3, `fzf` ≥ 0.45, `jq`, `bash` ≥ 4, `python3`, `nc`.

`python3` only measures display width, so that full-width CJK titles do not
break column alignment; `nc` reaches herdr's socket for `pane.focus`, which the
CLI does not expose by id. macOS ships bash 3.2 — install a newer one if you are
on a stock system.

## Install

```sh
herdr plugin install mr04vv/herdr-pane-navigator   # from GitHub
# or, from a local checkout:
herdr plugin link /path/to/herdr-pane-navigator
```

Then bind a key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+p"
type = "plugin_action"
command = "pane-navigator.open"
description = "navigate workspaces, tabs, and panes by title"
```

and `herdr server reload-config`.

## Keys

The navigator opens in normal mode, so single letters are commands rather than
query text.

| Key | Action |
| --- | --- |
| `j` / `k` | move down / up |
| `g` / `G` | first / last |
| `enter` | focus the selected workspace, tab, or pane |
| `/` | search |
| `esc` | leave search, back to normal mode |
| `a` / `s` | agents only / everything |
| `r` | reload |
| `p` | toggle preview |
| `q` | quit |

`ctrl-a`, `ctrl-s`, `ctrl-r`, and `ctrl-/` do the same as their unprefixed
counterparts and keep working while you type a search.

## Tab titles

An unnamed tab is just `1`, `2`, … in herdr, which says nothing about what is in
it. Here a tab with no name of its own borrows a title from a pane inside it,
preferring an agent pane, and keeps its number in the right-hand column as `#1`.

## Preview

`p` shows the pane's recent output — the exact permission prompt a `blocked`
agent is stuck on, for instance — so you can decide before jumping. `r` refreshes
everything.

## Status icons

| Icon | Meaning |
| --- | --- |
| `!` red | `blocked`, waiting on you |
| `*` cyan | `done`, just finished a turn |
| `*` yellow | `working` |
| `*` green | `idle` |
| `-` dim | no agent detected |

## License

MIT
