#!/usr/bin/env bash
# Navigate herdr's workspaces, tabs, and panes as one tree.
#
# herdr's built-in navigator lists workspace -> tab -> agent, but never the
# pane's terminal title. With several agent panes open that title is the only
# thing telling them apart, so this navigator leads with it.
#
# Rows are built from `herdr workspace|tab|pane list` and piped through fzf; the
# selection is dispatched back through the matching herdr focus call.
set -euo pipefail

# Absolute, because fzf's reload and preview bindings re-invoke this script from
# a working directory we do not control.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
readonly SELF

# Field separator for row payloads. Tab is safe here because herdr labels come
# from workspace/tab names and terminal titles, none of which can contain one.
readonly SEP=$'\t'

die() {
  printf 'pane-navigator: %s\n' "$*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# Emit "<kind> <id> <status> <prefix> <label> <meta>" rows, tab separated.
#
# Rows come out as a workspace -> tab -> pane tree. Structure wins over urgency
# for placement, but urgency still decides order *within* each level, and a
# parent inherits the urgency of its most urgent descendant -- so a workspace
# holding a blocked agent still floats to the top without breaking the nesting.
#
# The leaf level is panes rather than agents: `herdr pane list` is a superset of
# `herdr agent list` (agent panes come back with their titles either way), so
# using it keeps plain shells visible instead of silently dropping them.
collect_rows() {
  local ws_json tab_json pane_json

  ws_json="$(herdr workspace list 2>/dev/null)" ||
    die 'herdr workspace list failed; is the server running?'
  tab_json="$(herdr tab list 2>/dev/null)" || tab_json='{"result":{"tabs":[]}}'
  pane_json="$(herdr pane list 2>/dev/null)" || pane_json='{"result":{"panes":[]}}'

  jq -rn \
    --arg sep "$SEP" \
    --argjson ws "$ws_json" \
    --argjson tabs "$tab_json" \
    --argjson panes "$pane_json" '
    def urgency:
      { "blocked": 0, "done": 1, "working": 2, "idle": 3 }[.] // 4;

    # Box-drawing prefixes. The last child of a level gets the corner glyph and
    # its descendants indent with blanks, so vertical bars only continue where
    # another sibling actually follows.
    def branch(is_last): if is_last then "└─ " else "├─ " end;
    def spine(is_last):  if is_last then "   "  else "│  " end;

    # Display title for a pane. The terminal title is usually right, but agents
    # that never set one leave something useless there -- Codex prints the raw
    # session UUID -- so a summary reported into pane metadata (the codex-title
    # Stop hook fills tokens.codex_title) takes precedence when present.
    def pane_title:
      ((.tokens.codex_title? // .terminal_title_stripped // "")
       | gsub("^\\s+|\\s+$"; ""));

    # Drop the navigator'\''s own pane. When prefix+p opens this over a tab, herdr
    # lists the overlay pane too -- so the picker would show a "Pane Navigator"
    # row pointing back at itself. It is identified by its label, which herdr
    # sets from the plugin manifest.
    ( ($panes.result.panes // [])
      | map(select(.label != "Pane Navigator")) ) as $all_panes
    | ($tabs.result.tabs // []) as $all_tabs

    # Only panes carry a real status; tabs and workspaces borrow the minimum
    # urgency of whatever lives inside them.
    | ( [ $all_panes[] | { key: .tab_id, value: (.agent_status // "unknown" | urgency) } ]
        | group_by(.key)
        | map({ key: .[0].key, value: (map(.value) | min) })
        | from_entries ) as $tab_urgency
    | ( [ $all_panes[] | { key: .workspace_id, value: (.agent_status // "unknown" | urgency) } ]
        | group_by(.key)
        | map({ key: .[0].key, value: (map(.value) | min) })
        | from_entries ) as $ws_urgency

    | [ ($ws.result.workspaces // [])[]
        | { sort: [ ($ws_urgency[.workspace_id] // 5), (.number // 0) ], w: . } ]
    | sort_by(.sort)
    | to_entries[]
    | (.key > 0) as $needs_spacer
    | .value.w as $w
    | (
        # A blank spacer above every workspace but the first. fzf keeps these as
        # selectable rows, so they carry the "spacer" kind and the dispatcher
        # ignores them rather than trying to focus something.
        if $needs_spacer then ([ "spacer", "", "", "", "", "" ] | join($sep)) else empty end
      ),
      (
        [ "workspace", $w.workspace_id, ($w.agent_status // "unknown"), "",
          $w.label,
          (($w.tab_count | tostring) + " tabs, " + ($w.pane_count | tostring) + " panes")
        ] | join($sep)
      ),
      (
        [ $all_tabs[] | select(.workspace_id == $w.workspace_id)
          | { sort: [ ($tab_urgency[.tab_id] // 5), (.number // 0) ], t: . } ]
        | sort_by(.sort)
        | . as $sorted
        | to_entries[]
        | (.key == ($sorted | length - 1)) as $tab_last
        | .value.t as $t
        | (
            # An unnamed tab falls back to its own number ("1", "2", ...), which
            # says nothing. Borrow a title from inside it instead, preferring an
            # agent pane since that describes actual work; the number is kept as
            # the meta column so the tab is still identifiable.
            ( [ $all_panes[]
                | select(.tab_id == $t.tab_id)
                | select(pane_title != "")
                | { rank: (if (.agent_status // "unknown") != "unknown" then 0 else 1 end),
                    title: pane_title } ]
              | sort_by(.rank) | first | .title // "" ) as $borrowed
            | (if ($t.label | test("^[0-9]+$")) and $borrowed != ""
               then $borrowed else $t.label end) as $tab_label
            | [ "tab", $t.tab_id, ($t.agent_status // "unknown"), branch($tab_last),
              $tab_label,
              (if ($t.label | test("^[0-9]+$")) and $borrowed != ""
               then ("#" + $t.label + " · " + ($t.pane_count | tostring) + " panes")
               else (($t.pane_count | tostring) + " panes") end)
            ] | join($sep)
          ),
          (
            [ $all_panes[] | select(.tab_id == $t.tab_id)
              | { sort: [ (if .focused then 1 else 0 end),
                          (.agent_status // "unknown" | urgency),
                          (.pane_id // "") ], p: . } ]
            | sort_by(.sort)
            | . as $sorted_panes
            | to_entries[]
            | (.key == ($sorted_panes | length - 1)) as $pane_last
            | .value.p as $p
            | ($p | pane_title) as $title
            | [ "pane", $p.pane_id, ($p.agent_status // "unknown"),
                (spine($tab_last) + branch($pane_last)),
                (if $title == "" then (($p.cwd // "/") | split("/") | last) else $title end),
                ($p.agent // "")
              ] | join($sep)
          )
      )
  '
}

# Width of the label column, in terminal cells. Exported rather than readonly so
# the formatter below can receive it as an environment variable.
LABEL_WIDTH=52
export LABEL_WIDTH

# Render rows for display, keeping the dispatch prefix intact for fzf.
#
# This is Python rather than shell because the label column has to be padded by
# display width: shell printf pads by bytes and macOS awk indexes by bytes, so
# both misalign every row containing CJK -- which is most of them, since Claude
# titles are usually Japanese. unicodedata gives the real cell count.
format_rows() {
  python3 -c '
import os, sys, unicodedata

WIDTH = int(os.environ["LABEL_WIDTH"])
RESET = "\033[0m"
TAGS = {
    "workspace": ("\033[1;35m", "WS "),
    "tab":       ("\033[36m",   "TAB"),
    "pane":      ("\033[33m",   "PN "),
}
ICONS = {
    "working": ("\033[33m", "*"),
    "idle":    ("\033[32m", "*"),
    "done":    ("\033[36m", "*"),
    "blocked": ("\033[31m", "!"),
}

def cells(text):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)

def pad(text, width):
    out, used = [], 0
    for ch in text:
        w = 2 if unicodedata.east_asian_width(ch) in "WF" else 1
        if used + w > width - 1:
            out.append("~")
            used += 1
            break
        out.append(ch)
        used += w
    return "".join(out) + " " * max(0, width - used)

DIM = "\033[90m"

for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 6:
        continue
    kind, ident, status, prefix, label, meta = parts[:6]

    # Spacers separate workspaces; they render as an empty row and are never
    # dispatched, so they need no tag, icon, or padding.
    if kind == "spacer":
        sys.stdout.write(f"spacer\t\t\n")
        continue

    tag_color, tag_text = TAGS.get(kind, ("", "    "))
    icon_color, icon_text = ICONS.get(status, (DIM, "-"))

    # Workspace rows are the tree roots, so they are bolded to stand out from
    # their children -- with several workspaces open the boundary between them
    # is otherwise easy to lose.
    label_style = "\033[1m" if kind == "workspace" else ""

    # The tree prefix is padded together with the label, otherwise the meta
    # column would step right on nested rows. Padding is computed on the plain
    # text and the color is applied after, so the escape codes never count
    # toward the width.
    body = pad(prefix + label, WIDTH)
    if prefix:
        # Re-split at the prefix boundary to dim the glyphs only.
        body = f"{DIM}{prefix}{RESET}{label_style}{body[len(prefix):]}{RESET}"
    else:
        body = f"{label_style}{body}{RESET}"

    sys.stdout.write(
        f"{kind}\t{ident}\t{tag_color}{tag_text}{RESET} "
        f"{icon_color}{icon_text}{RESET} {body} "
        f"{DIM}{meta}{RESET}\n"
    )
'
}

cmd_list() {
  collect_rows | format_rows
}

# Agent-only view, for the toggle bound below. Panes without a detected agent
# carry an empty meta field, which is what distinguishes them here; the tree
# prefixes are dropped since a flat list has no parents to connect to.
cmd_list_agents() {
  collect_rows \
    | awk -F'\t' 'BEGIN { OFS = FS } $1 == "pane" && $6 != "" { $4 = ""; print }' \
    | format_rows
}

# Dispatch a chosen row. Exposed as a subcommand so fzf can call back into this
# same script for reload and preview without duplicating the mapping.
cmd_focus() {
  local kind="${1:-}" id="${2:-}"

  # Spacers are layout only -- selecting one is a no-op rather than an error.
  [ "$kind" = spacer ] && return 0

  [ -n "$kind" ] && [ -n "$id" ] || die 'focus requires <kind> <id>'

  case "$kind" in
    workspace) herdr workspace focus "$id" >/dev/null ;;
    tab)       herdr tab focus "$id" >/dev/null ;;
    pane)      api_call pane.focus "{\"pane_id\":\"$id\"}" >/dev/null ;;
    *)         die "unknown row kind: $kind" ;;
  esac
}

# Call a herdr socket API method directly.
#
# The CLI's `pane focus` only moves to a *neighboring* pane and takes a
# direction rather than an id, and `agent focus` rejects panes with no detected
# agent. The socket exposes a `pane.focus` that accepts a pane id outright --
# which is how the built-in navigator jumps straight to any pane -- so this
# reaches past the CLI to use it.
api_call() {
  local method="$1" params="$2" socket="${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}"

  [ -S "$socket" ] || die "herdr socket not found at $socket"
  require nc

  printf '{"id":"pane-navigator","method":"%s","params":%s}\n' "$method" "$params" |
    nc -U "$socket" 2>/dev/null |
    head -1
}

# Colors for preview, matching the icon palette in format_rows so the list and
# the preview read as one thing: blocked red, working yellow, idle green, done
# cyan, everything else dim.
readonly C_RESET=$'\033[0m'
readonly C_DIM=$'\033[90m'
readonly C_BOLD=$'\033[1m'

# Status dot + color for a given agent_status, emitted as "<color>●".
status_dot() {
  case "$1" in
    blocked) printf '\033[31m!'  ;;
    working) printf '\033[33m●'  ;;
    idle)    printf '\033[32m●'  ;;
    done)    printf '\033[36m●'  ;;
    *)       printf '\033[90m○'  ;;
  esac
}

# cwd shortened to ~ for readability in a header.
short_cwd() { printf '%s' "${1/#$HOME/\~}"; }

# A full-width rule under the header. 60 cells is a touch under the 50%%-wide
# preview pane at typical widths, and wrap handles the rest.
rule() { printf '%s%s%s\n' "$C_DIM" "────────────────────────────────────────────────────────────" "$C_RESET"; }

# One "<dot> <agent/shell> <status> <title|cwd>" line for a pane, used by the
# tab/workspace previews to list what lives inside.
pane_line() {
  local indent="$1" pane_json="$2"
  printf '%s' "$pane_json" | jq -r '
    def kind: if (.agent // "") != "" then .agent else "shell" end;
    def title:
      ((.tokens.codex_title? // .terminal_title_stripped // "") | gsub("^\\s+|\\s+$"; ""));
    def line: if title != "" then title else (.cwd // "/") end;
    "\(.agent_status // "unknown")\t\(kind)\t\(line)"
  ' 2>/dev/null | while IFS=$'\t' read -r status kind line; do
    printf '%s%s%s %s%-6s%s %s\n' \
      "$indent" "$(status_dot "$status")" "$C_RESET" \
      "$C_DIM" "$kind" "$C_RESET" "$line"
  done
}

# Header block shared by all three preview kinds: a status dot, a bold summary
# line, an optional second line, then a rule. Keeps the previews visually aligned.
preview_header() {
  local status="$1" summary="$2" second="$3"
  printf '%s %s%s%s\n' "$(status_dot "$status")$C_RESET" "$C_BOLD" "$summary" "$C_RESET"
  [ -n "$second" ] && printf '  %s\n' "$second"
  rule
}

# Preview: for a pane, a header plus its live (colored) screen; for a tab or
# workspace, a header plus the tree of what lives inside it -- not raw JSON.
cmd_preview() {
  local kind="${1:-}" id="${2:-}"
  case "$kind" in
    spacer) : ;;
    pane)
      local p
      p="$(herdr pane list 2>/dev/null | jq -c --arg id "$id" '.result.panes[] | select(.pane_id == $id)' 2>/dev/null)"
      if [ -n "$p" ]; then
        local status kind_label title cwd
        status="$(printf '%s' "$p" | jq -r '.agent_status // "unknown"')"
        kind_label="$(printf '%s' "$p" | jq -r 'if (.agent // "") != "" then .agent else "shell" end')"
        title="$(printf '%s' "$p" | jq -r '((.tokens.codex_title? // .terminal_title_stripped // "") | gsub("^\\s+|\\s+$"; ""))')"
        cwd="$(short_cwd "$(printf '%s' "$p" | jq -r '.cwd // "/"')")"
        # Second line is the conversation title. A shell pane usually has none,
        # or its terminal title is just the cwd -- already in the header, so drop
        # it rather than print the path twice.
        [ "$title" = "$cwd" ] && title=""
        preview_header "$status" "$kind_label · $status · $cwd" "$title"
      fi
      # --format ansi keeps the pane's own colors; --source visible so an idle
      # shell pane (no newly scrolled output) still previews what is on screen.
      herdr pane read "$id" --source visible --format ansi --lines 40 2>/dev/null || echo '(no output)'
      ;;
    tab)
      local t
      t="$(herdr tab list 2>/dev/null | jq -c --arg id "$id" '.result.tabs[] | select(.tab_id == $id)' 2>/dev/null)"
      if [ -n "$t" ]; then
        local status label num pc
        status="$(printf '%s' "$t" | jq -r '.agent_status // "unknown"')"
        num="$(printf '%s' "$t" | jq -r '.number // 0')"
        pc="$(printf '%s' "$t" | jq -r '.pane_count // 0')"
        # An unnamed tab's label is just its number, which "#N" already shows;
        # only append a real name.
        label="$(printf '%s' "$t" | jq -r 'if (.label // "" | test("^[0-9]*$")) then "" else " · " + .label end')"
        preview_header "$status" "TAB #$num$label · $pc panes" ""
      else
        echo '(no detail)'
      fi
      herdr pane list 2>/dev/null \
        | jq -c --arg id "$id" '.result.panes[] | select(.tab_id == $id)' 2>/dev/null \
        | while IFS= read -r pane; do pane_line "  " "$pane"; done
      ;;
    workspace)
      local w
      w="$(herdr workspace list 2>/dev/null | jq -c --arg id "$id" '.result.workspaces[] | select(.workspace_id == $id)' 2>/dev/null)"
      if [ -n "$w" ]; then
        local status label tc pc
        status="$(printf '%s' "$w" | jq -r '.agent_status // "unknown"')"
        label="$(printf '%s' "$w" | jq -r '.label // ""')"
        tc="$(printf '%s' "$w" | jq -r '.tab_count // 0')"
        pc="$(printf '%s' "$w" | jq -r '.pane_count // 0')"
        preview_header "$status" "WS · $label · $tc tabs, $pc panes" ""
      else
        echo '(no detail)'
      fi
      # Each tab in the workspace, with its panes nested under it.
      local panes_json tabs_json
      panes_json="$(herdr pane list 2>/dev/null)"
      tabs_json="$(herdr tab list 2>/dev/null)"
      printf '%s' "$tabs_json" \
        | jq -c --arg id "$id" '.result.tabs[] | select(.workspace_id == $id)' 2>/dev/null \
        | while IFS= read -r tab; do
            local tid tlabel tnum
            tid="$(printf '%s' "$tab" | jq -r '.tab_id')"
            tnum="$(printf '%s' "$tab" | jq -r '.number // 0')"
            tlabel="$(printf '%s' "$tab" | jq -r 'if (.label // "" | test("^[0-9]*$")) then "" else .label end')"
            printf '%s#%s%s %s\n' "$C_DIM" "$tnum" "$C_RESET" "$tlabel"
            printf '%s' "$panes_json" \
              | jq -c --arg tid "$tid" '.result.panes[] | select(.tab_id == $tid)' 2>/dev/null \
              | while IFS= read -r pane; do pane_line "    " "$pane"; done
          done
      ;;
  esac
}

# The "open" action is what a keybinding invokes, and herdr runs actions
# headless -- no terminal is attached, so fzf would have nowhere to draw and the
# process would hang forever. Actions therefore only ask herdr to open the pane
# entrypoint, which does get a real terminal; cmd_ui is what actually renders.
cmd_open() {
  exec herdr plugin pane open \
    --plugin pane-navigator \
    --entrypoint navigator \
    --placement overlay >/dev/null
}

cmd_ui() {
  require fzf
  require jq

  local self selection kind id
  self="$(printf '%q' "$SELF")"

  # Cursor style marks the mode, editor-style. fzf never emits a DECSCUSR
  # sequence of its own, so a style set here (or via the mode binds below)
  # persists until changed: steady block in normal mode so the caret does not
  # blink when it is not an input, blinking block in search mode to signal "you
  # are typing now". Restored to the terminal default on the way out, including
  # on ctrl-c, via the trap.
  printf '\033[2 q'
  trap 'printf "\033[0 q"' EXIT

  # Modal, vim style. Normal mode is the default: --disabled turns off filtering
  # so j/k/g/G move the cursor, and "/" switches to search. Leaving search with
  # esc drops back to normal mode instead of quitting, so esc only exits search.
  #
  # --disabled turns off *filtering*, not typing: an unbound printable key still
  # lands in the query. So normal mode binds `change` to clear-query -- a stray
  # character is wiped the instant it is typed, keeping normal mode from quietly
  # accumulating a hidden query. Search mode unbinds `change` so the query grows,
  # and the caret (steady, set above) marks where the text goes.
  #
  # Leaving search with esc keeps the query and the filtered result -- it does
  # NOT disable-search or clear-query -- so the text you typed stays visible and
  # the list stays narrowed after you drop back to moving with j/k. The query is
  # only wiped when you actually type a stray key in normal mode (change fires
  # clear-query again), which is the deliberate way to clear a search.
  #
  # Every single-letter binding has to be released while searching or it would be
  # swallowed instead of reaching the query; leaving search rebinds them all. esc
  # is the inverse -- live only while searching -- so normal mode exits on q.
  #
  # enter_search runs when "/" switches into search mode; enter_normal when esc
  # returns. (Named for the mode they enter, not the keys they map.) Each also
  # sets the caret: blinking block (1 q) while typing, steady block (2 q) back
  # in normal mode. The escape must go to /dev/tty -- execute-silent discards a
  # command's stdout, so writing to the controlling terminal directly is the only
  # way the DECSCUSR sequence actually reaches the screen.
  local enter_search='enable-search+change-prompt(search > )+unbind(j,k,g,G,/,q,a,s,r,p)+unbind(change)+rebind(esc)+execute-silent(printf "\033[1 q" > /dev/tty)'
  local enter_normal='change-prompt(herdr | )+rebind(j,k,g,G,/,q,a,s,r,p)+rebind(change)+unbind(esc)+execute-silent(printf "\033[2 q" > /dev/tty)'

  # --with-nth=3.. hides the dispatch prefix while leaving it in the output.
  # ctrl-a swaps the source to agents only and ctrl-s swaps it back, which is
  # cheaper than filtering on the tag text and keeps the counter honest.
  selection="$(
    cmd_list | fzf \
      --ansi \
      --delimiter="$SEP" \
      --with-nth='3..' \
      --disabled \
      --prompt='herdr | ' \
      --header='[j/k] move  [/] search  [enter] focus  [a] agents  [s] all  [r] reload  [p] preview  [q] quit' \
      --info=inline \
      --layout=reverse \
      --border=rounded \
      --height=100% \
      --preview="$self preview {1} {2}" \
      --preview-window='right,50%,border-left,wrap,hidden' \
      --bind="start:unbind(esc)" \
      --bind="change:clear-query" \
      --bind="j:down" \
      --bind="k:up" \
      --bind="g:first" \
      --bind="G:last" \
      --bind="q:abort" \
      --bind="p:toggle-preview" \
      --bind="/:$enter_search" \
      --bind="esc:$enter_normal" \
      --bind="ctrl-/:toggle-preview" \
      --bind="a:change-prompt(agents | )+reload($self list-agents)" \
      --bind="s:change-prompt(herdr | )+reload($self list)" \
      --bind="r:reload($self list)" \
      --bind="ctrl-a:change-prompt(agents | )+reload($self list-agents)" \
      --bind="ctrl-s:change-prompt(herdr | )+reload($self list)" \
      --bind="ctrl-r:reload($self list)"
  )" || exit 0

  [ -n "$selection" ] || exit 0

  IFS="$SEP" read -r kind id _ <<<"$selection"

  # Focus first, then close this pane.
  #
  # The order matters and the obvious one is wrong: an overlay pane zooms the
  # tab it covers, so closing first would look right -- but herdr kills the
  # pane's whole process group, taking any backgrounded follow-up with it
  # (nohup does not escape that, and macOS has no setsid). Focusing first keeps
  # the dispatch inside this process, and the close that follows releases the
  # overlay's zoom on its way out.
  cmd_focus "$kind" "$id"

  # HERDR_PANE_ID is set by herdr for the pane a plugin runs in. When the navigator
  # is run outside herdr there is nothing to close.
  if [ -n "${HERDR_PANE_ID:-}" ]; then
    herdr pane close "$HERDR_PANE_ID" >/dev/null 2>&1 || true
  fi
}



main() {
  case "${1:-open}" in
    open)        cmd_open ;;
    ui)          cmd_ui ;;
    list)        cmd_list ;;
    list-agents) cmd_list_agents ;;
    preview)     shift; cmd_preview "$@" ;;
    focus)       shift; cmd_focus "$@" ;;
    *)           die "unknown subcommand: ${1:-}" ;;
  esac
}

main "$@"
