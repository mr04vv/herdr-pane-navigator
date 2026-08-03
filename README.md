# Herdr Pane Navigator

One fuzzy tree over every workspace, tab, and pane in [Herdr](https://herdr.dev) — led by
what each pane is actually **doing**, not just where it lives.

```
WS  * dotfiles                                        2 tabs, 3 panes
TAB * ├─ monoweb                                      2 panes
PN  * │  ├─ Fix the flaky auth test                   claude
PN  - │  └─ ~/src/api
TAB - └─ ~/dotfiles                                   #1 · 1 panes
PN  -    └─ ~/dotfiles

WS  ! api                                             1 tabs, 2 panes
TAB ! └─ server                                       2 panes
PN  !    ├─ Add rate limiting to /v1/search           claude
PN  -    └─ ~/src/api
```

## Why

Herdr's built-in navigator lists `workspace → tab → agent`, but never shows an agent's
terminal title. With three Claude panes open you get three rows that all say `claude`,
and the only way to tell them apart is to visit each one.

Coding agents set their terminal title to a summary of the current task. This navigator
puts that front and center, so you can see at a glance which pane is doing what.

## Features

- **One tree, not two views.** Workspaces, tabs, and panes in a single list — no toggling
  between a "workspace view" and an "agent view" to find what you want.
- **Urgency-aware ordering.** Rows sort `blocked > done > working > idle`, and a parent
  inherits the urgency of its most urgent descendant, so a workspace holding a blocked
  agent floats to the top *without* breaking the nesting. The pane you are currently in
  sorts last — `enter` should take you somewhere else.
- **Borrowed tab titles.** An unnamed tab shows as `1`, `2`, … in Herdr. Here it borrows a
  title from a pane inside it (preferring an agent pane), keeping the number as `#1`.
- **Vim-modal.** `j`/`k` to move, `/` to search, `esc` back to normal mode.
- **Live preview.** `p` shows the pane's recent output — read the permission prompt a
  blocked agent is stuck on before you jump.
- **Correct CJK alignment.** Columns line up even when titles are Japanese, Chinese, or
  Korean. Wide characters are measured as two cells rather than by byte count.

## Requirements

`herdr` ≥ 0.7.3, `fzf` ≥ 0.45, `jq`, `bash` ≥ 4, `python3`, and `nc`.

`python3` is used for one thing: measuring display width so that full-width characters do
not break column alignment. `nc` talks to Herdr's socket for `pane.focus`, which the CLI
does not expose by id.

macOS ships bash 3.2 — install a newer one (`brew install bash`, or via Nix) if you are
on stock macOS.

## Install

```sh
herdr plugin install mr04vv/herdr-pane-navigator --yes
```

Or from a local checkout:

```sh
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

```sh
herdr server reload-config
```

## Keys

The navigator opens in normal mode, so single letters are commands rather than query text.

| Key | Action |
| --- | --- |
| `j` / `k` | move down / up |
| `g` / `G` | jump to first / last |
| `enter` | focus the selected workspace, tab, or pane |
| `/` | enter search mode |
| `esc` | leave search mode (back to normal) |
| `a` | agents only |
| `s` | show everything |
| `r` | reload |
| `p` | toggle preview |
| `q` | quit |

`ctrl-a`, `ctrl-s`, `ctrl-r`, and `ctrl-/` do the same as their unprefixed counterparts,
and keep working while you are typing a search.

## Status icons

| Icon | Meaning |
| --- | --- |
| `!` red | `blocked` — waiting on you |
| `*` cyan | `done` — just finished a turn |
| `*` yellow | `working` |
| `*` green | `idle` |
| `-` dim | no agent detected |

## License

MIT
