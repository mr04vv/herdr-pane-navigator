#!/usr/bin/env bash
# Self-check for the row builders: collect_rows must place a pane's name where
# the list can show it, and the agents-only filter must keep plain shells out --
# a named shell is not an agent, however much metadata it carries.
#
# herdr is stubbed, so these run anywhere; each fixture is the pane shape the
# real CLI returns, trimmed to the fields the row builders read.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pane-navigator.sh
NAV_SOURCED_FOR_TEST=1 . "$HERE/pane-navigator.sh"
# The script sets -e for its own run; re-clear it so a failing check reports and
# the suite carries on to the rest rather than aborting with no counts.
set +e

pass=0 fail=0

# Stub herdr for one run. $PANES is the pane-list payload under test; the
# workspace and tab wrappers around it stay fixed, since these tests are about
# what happens to a pane row.
herdr() {
  case "$1 $2" in
    "workspace list")
      printf '%s' '{"result":{"workspaces":[{"workspace_id":"w1","label":"ws",
        "number":1,"tab_count":1,"pane_count":1,"agent_status":"idle"}]}}' ;;
    "tab list")
      printf '%s' '{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1",
        "label":"1","number":1,"pane_count":1,"agent_status":"idle"}]}}' ;;
    "pane list") printf '%s' "$PANES" ;;
    "pane read") printf '%s\n' "${PANE_SCREEN:-}" ;;
  esac
}

check() {
  local name="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$name" "$want" "$got"
  fi
}

field() { collect_rows | awk -F'\t' -v n="$1" '$1 == "pane" { print $n }'; }

tab_field() { collect_rows | awk -F'\t' -v n="$1" '$1 == "tab" { print $n }'; }

pane() { printf '{"result":{"panes":[%s]}}' "$1"; }

BASE='"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","cwd":"/srv/app"'

# --- the label column ------------------------------------------------------

PANES="$(pane "{$BASE,\"agent_status\":\"unknown\",\"label\":\"dev-server\"}")"
check 'a name shows instead of the cwd' 'dev-server' "$(field 5)"

PANES="$(pane "{$BASE,\"agent_status\":\"unknown\"}")"
check 'no name falls back to the cwd' 'app' "$(field 5)"

PANES="$(pane "{$BASE,\"agent_status\":\"idle\",\"agent\":\"claude\",
  \"terminal_title_stripped\":\"fix the parser\",\"label\":\"build\"}")"
check 'a title outranks a name' 'fix the parser' "$(field 5)"

check 'a displaced name lands in meta' 'claude · build' "$(field 6)"

# --- a tab borrowing from its panes -----------------------------------------

# Asserted on the tab row because every other check reads pane rows, where
# dropping the borrow's name fallback shows up nowhere.
PANES="$(pane "{$BASE,\"agent_status\":\"unknown\",\"label\":\"dev-server\"}")"
check 'an unnamed tab borrows a name when no pane has a title' 'dev-server' \
  "$(tab_field 5)"

PANES="$(pane "{\"pane_id\":\"w1:p1\",\"tab_id\":\"w1:t1\",\"workspace_id\":\"w1\",
  \"cwd\":\"/a\",\"agent_status\":\"idle\",\"agent\":\"claude\",\"label\":\"agent-named\"},
  {\"pane_id\":\"w1:p2\",\"tab_id\":\"w1:t1\",\"workspace_id\":\"w1\",\"cwd\":\"/b\",
  \"agent_status\":\"unknown\",\"terminal_title_stripped\":\"shell-title\"}")"
check 'an agent pane wins the borrow even by name' 'agent-named' "$(tab_field 5)"

# --- the agents-only view --------------------------------------------------

# The regression this file exists for. Shells do set terminal titles, so a named
# one carries both fields -- and must still not read as an agent.
#
# cmd_list_agents itself, not a copy of its filter: a re-implementation here
# would keep passing after the real one regressed.
agents() { cmd_list_agents | sed 's/\x1b\[[0-9;]*m//g'; }

PANES="$(pane "{$BASE,\"agent_status\":\"unknown\",
  \"terminal_title_stripped\":\"zsh\",\"label\":\"logs\"}")"
check 'a named shell stays out of the agent view' '' "$(agents)"

PANES="$(pane "{$BASE,\"agent_status\":\"idle\",\"agent\":\"claude\",
  \"terminal_title_stripped\":\"real work\"}")"
check 'an agent is still in it' 'yes' \
  "$(agents | grep -q 'real work' && echo yes || echo no)"

# `herdr pane report-agent` requires --agent and accepts --state unknown, so a
# named agent reads as "unknown" until it reports.
PANES="$(pane "{$BASE,\"agent_status\":\"unknown\",\"agent\":\"claude\",
  \"terminal_title_stripped\":\"starting up\"}")"
check 'an agent with an unreported state is still in it' 'yes' \
  "$(agents | grep -q 'starting up' && echo yes || echo no)"

# --- a blocked pane --------------------------------------------------------

# The question replaces the agent name, but not the pane's own name -- losing it
# here would blank the name on exactly the rows the navigator is used for most.
PANE_SCREEN='Do you want to proceed?'
PANES="$(pane "{$BASE,\"agent_status\":\"blocked\",\"agent\":\"claude\",
  \"terminal_title_stripped\":\"deploy\",\"label\":\"prod\"}")"
check 'a blocked pane keeps its name' 'waiting: Do you want to proceed? · prod' \
  "$(collect_rows | annotate_blocked | awk -F'\t' '$1 == "pane" { print $6 }')"

# --- free-form names -------------------------------------------------------

# A name is user input and the row separator is a tab, so an interior one would
# split the row and shift every later column.
PANES="$(pane "{$BASE,\"agent_status\":\"unknown\",\"label\":\"evil\\tname\"}")"
check 'a tab in a name does not split the row' '7' \
  "$(collect_rows | awk -F'\t' '$1 == "pane" { print NF }')"
check 'a tab in a name renders as a space' 'evil name' "$(field 5)"

# format_rows pads by counting characters, so an escape left in the name would
# be counted as visible width and shift every later column.
PANES="$(pane "{$BASE,\"agent_status\":\"unknown\",\"label\":\"\\u001b[31mred\\u001b[0m\"}")"
check 'an escape in a name is stripped' '[31mred[0m' "$(field 5)"

# --- what fzf actually searches ----------------------------------------------

# fzf is given the rendered row with --with-nth=3.., so the searchable text is
# field 3 of format_rows' output, not the raw columns collect_rows built.
searchable() { cmd_list | sed 's/\x1b\[[0-9;]*m//g' | awk -F'\t' '$1 == "pane" { print $3 }'; }

PANES="$(pane "{$BASE,\"agent_status\":\"unknown\",\"label\":\"dev-server\"}")"
check 'a name reaches the searchable field' 'yes' \
  "$(searchable | grep -q 'dev-server' && echo yes || echo no)"

PANES="$(pane "{$BASE,\"agent_status\":\"idle\",\"agent\":\"claude\",
  \"terminal_title_stripped\":\"fix the parser\",\"label\":\"api\"}")"
check 'a displaced name is searchable too' 'yes' \
  "$(searchable | grep -q 'api' && echo yes || echo no)"

# The agent field is appended past the six columns format_rows renders. The meta
# column carries the agent name only when a title displaced a pane's own name, so
# a blocked pane -- whose question replaces that column -- leaves the agent name
# reachable from the seventh field alone. It must still not reach fzf.
PANE_SCREEN='Do you want to proceed?'
PANES="$(pane "{$BASE,\"agent_status\":\"blocked\",\"agent\":\"zzagentzz\"}")"
check 'the agent field stays out of the searchable text' 'no' \
  "$(cmd_list | sed 's/\x1b\[[0-9;]*m//g' | awk -F'\t' '$1 == "pane" { print $3 }' \
     | grep -q 'zzagentzz' && echo yes || echo no)"
check 'that agent name is in the seventh field' 'zzagentzz' "$(field 7)"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
