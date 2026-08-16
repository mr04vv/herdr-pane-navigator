#!/usr/bin/env bash
# Self-check for blocked_reason: given a pane's visible screen on stdin, it must
# pull out the question the agent is waiting on -- and stay silent when there is
# no question, so a working pane never grows a spurious "waiting:" note.
#
# Fixtures are real agent screens: a Claude permission prompt, a Codex approval,
# a plain (y/n), and a busy pane whose tail is nothing but a status line.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pane-navigator.sh
NAV_SOURCED_FOR_TEST=1 . "$HERE/pane-navigator.sh"

pass=0 fail=0

check() {
  local name="$1" want="$2" got
  got="$(blocked_reason)"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$name" "$want" "$got"
  fi
}

# Claude's tool-permission prompt. The question sits above the option list, and
# the pane's status line is below all of it.
check 'claude permission' 'Do you want to make this edit to config.toml?' <<'EOF'
⏺ Update(config.toml)

╭──────────────────────────────────────────────────────╮
│ Do you want to make this edit to config.toml?        │
│                                                      │
│ ❯ 1. Yes                                             │
│   2. Yes, allow all edits during this session        │
│   3. No, and tell Claude what to do differently      │
╰──────────────────────────────────────────────────────╯
  [Opus 5(1M)] | 🌿 main | 📁 herdr | 💬 12 | 💰 $0.12
  Context: ██▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒ [7%] 66.6K/1.0M
EOF

# Bash-command approval names the command, which is the useful half.
check 'claude bash approval' 'Do you want to proceed?' <<'EOF'
⏺ Bash(rm -rf build/)
  ⎿  Running…

╭──────────────────────────────────────────────────────╮
│ Bash command                                         │
│                                                      │
│   rm -rf build/                                      │
│   Remove the build directory                         │
│                                                      │
│ Do you want to proceed?                              │
│ ❯ 1. Yes                                             │
│   2. No, and tell Claude what to do differently      │
╰──────────────────────────────────────────────────────╯
EOF

# Codex phrases it as "Allow ...?" with a y/n rather than a numbered list.
check 'codex approval' 'Allow command to run? [y/N]' <<'EOF'
codex wants to run: git push origin main

Allow command to run? [y/N]
EOF

# A bare (y/n) with the question on the same line.
check 'plain y/n' 'Overwrite existing file? (y/n)' <<'EOF'
Writing output...
Overwrite existing file? (y/n)
EOF

# A working pane: no question anywhere, only a prompt caret and a status line.
# This is the important negative -- the whole feature is worthless if it
# hallucinates a reason for every busy agent.
check 'working pane, no question' '' <<'EOF'
✽ Sketching… (55s · ↓ 1.9k tokens)
  ⎿  Tip: Press Shift+Enter to send a multi-line message

───────────────────────────────────────────────────────
❯
───────────────────────────────────────────────────────
  [Opus 5(1M)] | 🌿 main | 📁 herdr | 💬 23 | 💰 $0.687
  Context: ██▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒ [6%] 60.7K/1.0M
  Session: ▁▁▁█▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁ [0%] 748K token (3pm-8pm)
  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents
EOF

# An idle pane whose recap text happens to contain a question mark should not
# be mistaken for a prompt: recaps are prose, not a pending decision.
check 'idle recap is not a prompt' '' <<'EOF'
※ recap: レポートを作成しました。次はレポートを読んで判断材料が足りているか確認してください。 (disable recaps in /config)

───────────────────────────────────────────────────────
❯
───────────────────────────────────────────────────────
  Context: ██████▒▒▒▒▒▒▒▒▒▒▒▒▒▒ [29%] 294.4K/1.0M
EOF

# Box-drawing borders and the leading │ must be stripped, and a question
# wrapped in ANSI color still has to match.
check 'ansi and box glyphs stripped' 'Do you want to proceed?' < <(
  printf '\xe2\x94\x82 \033[1mDo you want to proceed?\033[0m \xe2\x94\x82\n\xe2\x94\x82 \xe2\x9d\xaf 1. Yes           \xe2\x94\x82\n'
)

# --- annotate_blocked ------------------------------------------------------
#
# The row pipeline is six tab-separated columns and the agent view deliberately
# leaves column 4 empty, so the adjacent tabs there are load-bearing: an earlier
# version split rows with `read -r` under IFS=tab, which collapsed the pair and
# shifted the agent name into the label. These check the column count survives.

# Stub the screen read so a row can be driven down the blocked path without an
# agent actually being stuck.
herdr() {
  [ "$1" = pane ] && [ "$2" = read ] &&
    printf '%s\n' '│ Do you want to make this edit to config.toml? │' '│ ❯ 1. Yes │'
}

check_row() {
  local name="$1" want="$2" row="$3" got
  got="$(printf '%s\n' "$row" | annotate_blocked)"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  want: %q\n  got:  %q\n' "$name" "$want" "$got"
  fi
}

check_row 'blocked pane gains a reason' \
  "$(printf 'pane\tw9:p1\tblocked\t   └─ \tfix the parser\twaiting: Do you want to make this edit to config.toml?')" \
  "$(printf 'pane\tw9:p1\tblocked\t   └─ \tfix the parser\tclaude')"

# The regression: empty prefix column must stay empty, not swallow a separator.
check_row 'empty prefix column does not shift' \
  "$(printf 'pane\tw9:p1\tblocked\t\tfix the parser\twaiting: Do you want to make this edit to config.toml?')" \
  "$(printf 'pane\tw9:p1\tblocked\t\tfix the parser\tclaude')"

# Non-blocked rows must pass through byte for byte -- most rows are these, and
# rewriting them would cost a pane read each.
check_row 'idle pane untouched' \
  "$(printf 'pane\tw9:p2\tidle\t   └─ \tsomething\tclaude')" \
  "$(printf 'pane\tw9:p2\tidle\t   └─ \tsomething\tclaude')"

check_row 'workspace row untouched' \
  "$(printf 'workspace\tw9\tblocked\t\tmy project\t2 tabs, 3 panes')" \
  "$(printf 'workspace\tw9\tblocked\t\tmy project\t2 tabs, 3 panes')"

# --- pane id unquoting -----------------------------------------------------
#
# fzf single-quotes every placeholder expansion, so a `{+2}` in a transform
# binding arrives as 'wZ:p1' 'wZ:p2' -- quotes included, as literal characters.
# Passing those straight to `herdr pane send-keys` fails with pane_not_found,
# which is exactly how y/n silently did nothing.

check_ids() {
  local name="$1" want="$2"
  shift 2
  local got
  got="$(unquote_ids "$@")"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  want: %q\n  got:  %q\n' "$name" "$want" "$got"
  fi
}

check_ids 'strips the quotes fzf adds' 'wZ:p1' "'wZ:p1'"
check_ids 'multi selection' 'wZ:p1 wZ:p2' "'wZ:p1'" "'wZ:p2'"
check_ids 'bare ids pass through' 'wZ:p1 wZ:p2' 'wZ:p1' 'wZ:p2'
check_ids 'empty args drop out' 'wZ:p1' '' "'wZ:p1'" ''
check_ids 'nothing selected' '' ''

# --- render_layout ---------------------------------------------------------
#
# The tab preview reproduces the arrangement you would see on screen, so what
# matters is geometry: the drawing must land inside the requested box, and panes
# that sit side by side on the real screen must sit side by side here.

plain() { sed $'s/\033\\[[0-9;]*m//g'; }

# Widest row in terminal cells. awk counts characters, which is the wrong unit
# here -- a CJK title fits half as many glyphs into the same box.
widest() {
  plain | python3 -c '
import sys, unicodedata
print(max((sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in l.rstrip("\n"))
           for l in sys.stdin), default=0))'
}

# The real shape herdr reports for a tab split down, then the lower half split
# right: one full-width pane on top, two beneath it.
NESTED='{"width":40,"height":12,
 "area":{"x":35,"y":1,"width":202,"height":114},
 "panes":[
  {"pane_id":"p1","rect":{"x":35,"y":1,"width":202,"height":57},"status":"idle","title":"top","lines":["alpha"]},
  {"pane_id":"p2","rect":{"x":35,"y":58,"width":101,"height":57},"status":"working","title":"left","lines":["beta"]},
  {"pane_id":"p3","rect":{"x":136,"y":58,"width":101,"height":57},"status":"blocked","title":"right","lines":["gamma"]}
 ]}'

out="$(printf '%s' "$NESTED" | render_layout | plain)"

check_render() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n%s\n' "$name" "$out"
  fi
}

check_render 'never exceeds the requested width' \
  '[ "$(printf "%s\n" "$out" | widest)" -le 40 ]'

check_render 'never exceeds the requested height' \
  '[ "$(printf "%s\n" "$out" | wc -l | tr -d " ")" -le 12 ]'

# Side-by-side panes must share rows: the row holding one title holds the other.
check_render 'split-right panes share a row' \
  'printf "%s" "$out" | grep -q "left.*right"'

# The top pane spans the full width, so its title row must not also carry a
# sibling -- that would mean the vertical split was flattened.
check_render 'full-width pane owns its row' \
  '! (printf "%s" "$out" | grep -q "top.*left")'

check_render 'each pane contributes its content' \
  'printf "%s" "$out" | grep -q alpha && printf "%s" "$out" | grep -q beta && printf "%s" "$out" | grep -q gamma'

# A pane scaled below a drawable size is skipped rather than drawn as debris.
TINY='{"width":40,"height":12,"area":{"x":0,"y":0,"width":2000,"height":1140},
 "panes":[{"pane_id":"p1","rect":{"x":0,"y":0,"width":8,"height":8},"status":"idle","title":"x","lines":["y"]}]}'
check_render 'a pane too small to draw is dropped' \
  '[ -z "$(printf "%s" "$TINY" | render_layout | plain | tr -d " \n")" ]'

# Full-width CJK must not push the border past the box -- the whole reason the
# renderer measures in cells rather than characters.
CJK='{"width":30,"height":6,"area":{"x":0,"y":0,"width":100,"height":50},
 "panes":[{"pane_id":"p1","rect":{"x":0,"y":0,"width":100,"height":50},"status":"idle",
   "title":"日本語のタイトルがとても長い場合","lines":["日本語の本文がここに入ります"]}]}'
check_render 'CJK stays inside the box' \
  '[ "$(printf "%s" "$CJK" | render_layout | widest)" -le 30 ]'

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
