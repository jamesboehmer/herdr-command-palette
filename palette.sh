#!/usr/bin/env bash
# Pane `jamesboehmer.command-palette.palette`: the interactive fzf picker.
#
# Runs inside an overlay pane (real TTY). Lists herdr's own built-in actions plus
# every action from every installed plugin, lets the user fuzzy-pick one, and runs
# it. When this script exits the overlay closes on its own.
#
# Two kinds of entries:
#   plugin.action <title>   → dispatched with `herdr plugin action invoke`
#   herdr:group.action …    → run here against the herdr CLI (socket API)
#
# Built-in entries whose title ends in `…` prompt for input (a name, a path) or
# open a second fzf picker (which tab, which workspace) before running.
set -uo pipefail

herdr_bin="${HERDR_BIN_PATH:-herdr}"
self_plugin="${HERDR_PLUGIN_ID:-jamesboehmer.command-palette}"

# ── plumbing ────────────────────────────────────────────────────────────────

# Brief pause + message helper so failures don't vanish when the overlay closes.
pause() {
  printf '\nPress any key to close…' >&2
  read -r -n1 _ </dev/tty 2>/dev/null || sleep 2
}

# Most herdr calls happen inside command substitutions, where a plain `exit` would
# only end the subshell and let the caller carry on with an empty value. Signal the
# top-level shell instead so a failed call always ends the palette.
main_pid=$$
trap 'exit 1' TERM

die() {
  printf '%s\n' "$*" >&2
  pause
  kill -TERM "$main_pid" 2>/dev/null
  exit 1
}

command -v fzf >/dev/null 2>&1 || die "command-palette: fzf is not installed or not on PATH."
command -v jq  >/dev/null 2>&1 || die "command-palette: jq is not installed or not on PATH."

# Run a herdr CLI command, echoing its output. The CLI reports socket API errors
# as `{"error":{…}}` on stdout while still exiting 0, so a zero exit is not enough
# — we check for an error object too, and abort loudly either way.
run_herdr() {
  local out rc err
  out="$("$herdr_bin" "$@" 2>&1)"
  rc=$?
  err="$(
    printf '%s' "$out" \
      | jq -r 'if type == "object" and has("error")
               then (.error.message // .error.code // "error")
               else empty end' 2>/dev/null
  )"
  if [ "$rc" -ne 0 ] || [ -n "$err" ]; then
    die "command-palette: \`herdr $*\` failed
${err:-$out}"
  fi
  printf '%s' "$out"
}

# Show read-only output and wait, so the overlay doesn't close before it's read.
page() {
  if command -v less >/dev/null 2>&1; then
    printf '%s\n' "$1" | less -R -X
  else
    printf '%s\n' "$1" >&2
    pause
  fi
}

# `read -i`, which puts an editable default on the input line, is bash 4+. macOS
# still ships bash 3.2 as /bin/bash, where it fails as an invalid option — and a
# failed `read` looks exactly like "the user cancelled", so every defaulted prompt
# would quietly drop its action. Detect it once and offer the default in the label
# instead, where pressing enter accepts it.
if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
  readline_default=true
else
  readline_default=false
fi

# Read one line from the overlay's TTY. Empty input means "cancel"; where a default
# is offered, enter accepts it instead (true of both branches — with `read -i` the
# default is already on the line, so enter returns it). To cancel a defaulted
# prompt, clear the line first, or press ctrl-c.
prompt() {
  local label="$1" default="${2:-}" ans
  if [ -n "$default" ] && [ "$readline_default" = true ]; then
    IFS= read -r -e -i "$default" -p "$label ▸ " ans </dev/tty || return 1
  elif [ -n "$default" ]; then
    IFS= read -r -e -p "$label [$default] ▸ " ans </dev/tty || return 1
    [ -n "$ans" ] || ans="$default"
  else
    IFS= read -r -e -p "$label ▸ " ans </dev/tty || return 1
  fi
  [ -n "$ans" ] || return 1
  printf '%s' "$ans"
}

# Same, but an empty answer is a legitimate "leave it unset" rather than a cancel.
prompt_optional() {
  local ans
  IFS= read -r -e -p "$1 ▸ " ans </dev/tty || return 1
  printf '%s' "$ans"
}

confirm() {
  local ans
  printf '%s [y/N] ' "$1" >&2
  IFS= read -r -n1 ans </dev/tty || return 1
  printf '\n' >&2
  case "$ans" in y | Y) return 0 ;; *) return 1 ;; esac
}

# Second-level picker. Input is TSV lines: field 1 is the value, field 2 the label.
# Sorting is left on for the same reason as the main picker below: with an empty
# query fzf keeps the order we fed it, and once you type it ranks by match quality.
pick() {
  local label="$1" lines="$2" sel
  [ -n "$lines" ] || die "command-palette: nothing to pick from."
  sel="$(
    printf '%s\n' "$lines" \
      | fzf --delimiter=$'\t' --with-nth=2 --prompt="$label ▸ " \
            --reverse --cycle --no-multi
  )" || return 1
  [ -n "$sel" ] || return 1
  printf '%s' "${sel%%$'\t'*}"
}

# ── origin context ──────────────────────────────────────────────────────────
#
# Built-in actions need an explicit target, because the palette overlay is itself a
# pane: `herdr pane current` returns the OVERLAY, so anything relying on "the
# focused pane" would act on the palette instead of on the pane it was opened from.
#
# Two independent sources, in order of preference:
#   1. HERDR_PALETTE_ORIGIN_* — forwarded explicitly by open.sh.
#   2. HERDR_PLUGIN_CONTEXT_JSON — set by herdr in every plugin pane, and its
#      `focused_pane_id` is the origin pane (the one the overlay covers), not us.
#      This keeps the palette working when the pane is opened directly, e.g.
#      `herdr plugin pane open --plugin jamesboehmer.command-palette
#       --entrypoint palette`.
ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}"
ctx_field() {
  [ -n "$ctx" ] || return 0
  printf '%s' "$ctx" | jq -r ".$1 // empty" 2>/dev/null
}

origin_pane="${HERDR_PALETTE_ORIGIN_PANE:-$(ctx_field focused_pane_id)}"
origin_tab="${HERDR_PALETTE_ORIGIN_TAB:-$(ctx_field tab_id)}"
origin_workspace="${HERDR_PALETTE_ORIGIN_WORKSPACE:-$(ctx_field workspace_id)}"
origin_cwd="${HERDR_PALETTE_ORIGIN_CWD:-}"
[ -n "$origin_cwd" ] || origin_cwd="$(ctx_field focused_pane_cwd)"
[ -n "$origin_cwd" ] || origin_cwd="$PWD"

# HERDR_TAB_ID / HERDR_WORKSPACE_ID are set in the pane's own env and, for an
# overlay, still name the origin tab and workspace — a last resort for those two.
[ -n "$origin_tab" ] || origin_tab="${HERDR_TAB_ID:-}"
[ -n "$origin_workspace" ] || origin_workspace="${HERDR_WORKSPACE_ID:-}"

require() { # <value> <what>
  [ -n "$1" ] || die "command-palette: could not work out which $2 to act on."
  printf '%s' "$1"
}

target_pane() { require "$origin_pane" "pane"; }
target_tab() { require "$origin_tab" "tab"; }
target_workspace() { require "$origin_workspace" "workspace"; }

# ── built-in action catalog ─────────────────────────────────────────────────
#
# herdr's built-ins are not exposed by `plugin action list` — they're the commands
# behind its prefix keybindings, reachable over the socket API via the herdr CLI.
#
# Two families are deliberately absent:
#
#   * UI-only commands (help, settings, resize mode, sidebar, goto, detach,
#     scrollback editor, the pickers) have no socket API entry point at all, so
#     nothing can invoke them from here. Where an equivalent exists the palette
#     offers it — "Switch to workspace…" stands in for the workspace picker.
#   * Zoom and the `--direction` pane commands (focus/swap/resize) are broken from
#     inside a palette overlay, so including them would ship entries that quietly
#     do the wrong thing. The overlay is not a floating window: it's a real,
#     zoomed pane inserted into the origin tab's split tree. So the tab is always
#     already zoomed (a zoom toggle just cancels the overlay's own zoom), a
#     direction resolves against the overlay's rect as often as not (`pane focus
#     --direction left` was observed returning the overlay's own pane id), and a
#     focus or swap that does land leaves the tab zoomed on the target once the
#     overlay tears down. All of these are natively keybound anyway — prefix+z,
#     prefix+h/j/k/l, prefix+r.
builtin_catalog() {
  cat <<'EOF'
herdr:pane.split-right	Split pane right
herdr:pane.split-down	Split pane down
herdr:pane.rename	Rename pane…
herdr:pane.rename-clear	Clear pane name
herdr:pane.close	Close pane
herdr:pane.move-to-tab	Move pane to another tab…
herdr:pane.move-to-new-tab	Move pane to a new tab
herdr:pane.move-to-new-workspace	Move pane to a new workspace
herdr:tab.new	New tab
herdr:tab.new-named	New tab, named…
herdr:tab.rename	Rename tab…
herdr:tab.close	Close tab
herdr:tab.next	Next tab
herdr:tab.previous	Previous tab
herdr:tab.switch	Switch to tab…
herdr:workspace.new	New workspace here
herdr:workspace.new-path	New workspace in another directory…
herdr:workspace.rename	Rename workspace…
herdr:workspace.close	Close workspace
herdr:workspace.switch	Switch to workspace…
herdr:workspace.next	Next workspace
herdr:workspace.previous	Previous workspace
herdr:worktree.create	New git worktree…
herdr:worktree.open	Open an existing git worktree…
herdr:worktree.remove	Remove this workspace's git worktree
herdr:worktree.list	List git worktrees
herdr:agent.start	Start an agent…
herdr:agent.focus	Focus an agent…
herdr:agent.rename	Rename an agent…
herdr:server.reload-config	Reload herdr config
herdr:server.stop	Stop the herdr server
herdr:integration.status	Agent integration status
herdr:integration.install	Install an agent integration…
herdr:integration.uninstall	Uninstall an agent integration…
herdr:channel.show	Show the update channel
herdr:channel.set	Set the update channel…
herdr:config.reset-keys	Reset custom keybindings
herdr:session.list	List herdr sessions
EOF
}

# ── built-in helpers ────────────────────────────────────────────────────────

# Neighbour of $2 in the newline-separated list $1, $3 positions away, wrapping.
# Prints nothing when the current id isn't in the list.
sibling() {
  local list="$1" current="$2" offset="$3"
  printf '%s\n' "$list" | awk -v cur="$current" -v off="$offset" '
    NF { n++; ids[n] = $0; if ($0 == cur) idx = n }
    END { if (idx) print ids[((idx - 1 + off) % n + n) % n + 1] }
  '
}

workspace_rows() { # value = workspace_id, label = "label (id)"
  run_herdr workspace list \
    | jq -r '.result.workspaces[] | [.workspace_id, ((.label // .workspace_id) + " (" + .workspace_id + ")")] | @tsv'
}

tab_rows() { # tabs of workspace $1
  run_herdr tab list --workspace "$1" \
    | jq -r '.result.tabs[]
             | [ .tab_id,
                 ((.label // (.number | tostring)) + "  ·  " + (.pane_count | tostring) + " pane(s)")
               ] | @tsv'
}

agent_rows() {
  run_herdr agent list \
    | jq -r '.result.agents[]
             | [ .pane_id,
                 ((.agent // "agent") + "  ·  " + (.agent_status // "unknown")
                  + "  ·  " + (.cwd // "") + "  [" + .pane_id + "]")
               ] | @tsv'
}

integration_rows() {
  # `integration status` prints "<name>: <state> (<path>)" per line.
  run_herdr integration status \
    | awk -F': ' 'NF > 1 { printf "%s\t%s — %s\n", $1, $1, $2 }'
}

# Align tab-separated columns when `column` is available, otherwise pass through.
tabulate() {
  if command -v column >/dev/null 2>&1; then
    column -t -s$'\t'
  else
    cat
  fi
}

expand_path() { # ~/foo → $HOME/foo
  # The tildes here are literal glob patterns being matched, not expansions.
  # shellcheck disable=SC2088
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ── built-in dispatch ───────────────────────────────────────────────────────
#
# Every branch either runs its action (and exits 0, letting the overlay close),
# pages read-only output, or returns non-zero when the user cancels a prompt.
run_builtin() {
  local id="$1"
  case "$id" in
    # panes
    herdr:pane.split-right)
      run_herdr pane split "$(target_pane)" --direction right --focus >/dev/null ;;
    herdr:pane.split-down)
      run_herdr pane split "$(target_pane)" --direction down --focus >/dev/null ;;
    herdr:pane.rename)
      local pane label current
      pane="$(target_pane)"
      current="$(run_herdr pane get "$pane" | jq -r '.result.pane.label // empty')"
      label="$(prompt 'pane name' "$current")" || return 1
      run_herdr pane rename "$pane" "$label" >/dev/null ;;
    herdr:pane.rename-clear)
      run_herdr pane rename "$(target_pane)" --clear >/dev/null ;;
    herdr:pane.close)
      local pane
      pane="$(target_pane)"
      confirm "Close pane ${pane}?" || return 1
      run_herdr pane close "$pane" >/dev/null ;;
    herdr:pane.move-to-tab)
      local pane tab rows
      pane="$(target_pane)"
      # Tabs across every workspace, so a pane can be moved out of its workspace.
      rows="$(
        while IFS=$'\t' read -r ws label; do
          [ -n "$ws" ] || continue
          tab_rows "$ws" | awk -F'\t' -v w="$label" '{ printf "%s\t%s  ·  %s\n", $1, w, $2 }'
        done <<< "$(workspace_rows)"
      )"
      tab="$(pick 'move pane to tab' "$rows")" || return 1
      run_herdr pane move "$pane" --tab "$tab" --split right --focus >/dev/null ;;
    herdr:pane.move-to-new-tab)
      run_herdr pane move "$(target_pane)" --new-tab --workspace "$(target_workspace)" --focus >/dev/null ;;
    herdr:pane.move-to-new-workspace)
      run_herdr pane move "$(target_pane)" --new-workspace --focus >/dev/null ;;

    # tabs
    herdr:tab.new)
      run_herdr tab create --workspace "$(target_workspace)" --cwd "$origin_cwd" --focus >/dev/null ;;
    herdr:tab.new-named)
      local ws label
      ws="$(target_workspace)"
      label="$(prompt 'new tab name')" || return 1
      run_herdr tab create --workspace "$ws" --cwd "$origin_cwd" --label "$label" --focus >/dev/null ;;
    herdr:tab.rename)
      local tab label current
      tab="$(target_tab)"
      current="$(run_herdr tab get "$tab" | jq -r '.result.tab.label // empty')"
      label="$(prompt 'tab name' "$current")" || return 1
      run_herdr tab rename "$tab" "$label" >/dev/null ;;
    herdr:tab.close)
      local tab
      tab="$(target_tab)"
      confirm "Close tab ${tab} and every pane in it?" || return 1
      run_herdr tab close "$tab" >/dev/null ;;
    herdr:tab.next | herdr:tab.previous)
      local tab next offset=1
      [ "$id" = "herdr:tab.previous" ] && offset=-1
      tab="$(target_tab)"
      next="$(
        sibling "$(run_herdr tab list --workspace "$(target_workspace)" | jq -r '.result.tabs[].tab_id')" \
                "$tab" "$offset"
      )"
      [ -n "$next" ] || die "command-palette: could not resolve a sibling tab of ${tab}."
      run_herdr tab focus "$next" >/dev/null ;;
    herdr:tab.switch)
      local tab
      tab="$(pick 'switch to tab' "$(tab_rows "$(target_workspace)")")" || return 1
      run_herdr tab focus "$tab" >/dev/null ;;

    # workspaces
    herdr:workspace.new)
      run_herdr workspace create --cwd "$origin_cwd" --focus >/dev/null ;;
    herdr:workspace.new-path)
      local path
      path="$(prompt 'new workspace directory' "$origin_cwd")" || return 1
      path="$(expand_path "$path")"
      [ -d "$path" ] || die "command-palette: not a directory: ${path}"
      run_herdr workspace create --cwd "$path" --focus >/dev/null ;;
    herdr:workspace.rename)
      local ws label current
      ws="$(target_workspace)"
      current="$(run_herdr workspace get "$ws" | jq -r '.result.workspace.label // empty')"
      label="$(prompt 'workspace name' "$current")" || return 1
      run_herdr workspace rename "$ws" "$label" >/dev/null ;;
    herdr:workspace.close)
      local ws
      ws="$(target_workspace)"
      confirm "Close workspace ${ws} and every tab in it?" || return 1
      run_herdr workspace close "$ws" >/dev/null ;;
    herdr:workspace.switch)
      local ws
      ws="$(pick 'switch to workspace' "$(workspace_rows)")" || return 1
      run_herdr workspace focus "$ws" >/dev/null ;;
    herdr:workspace.next | herdr:workspace.previous)
      local ws next offset=1
      [ "$id" = "herdr:workspace.previous" ] && offset=-1
      ws="$(target_workspace)"
      next="$(
        sibling "$(run_herdr workspace list | jq -r '.result.workspaces[].workspace_id')" "$ws" "$offset"
      )"
      [ -n "$next" ] || die "command-palette: could not resolve a sibling workspace of ${ws}."
      run_herdr workspace focus "$next" >/dev/null ;;

    # git worktrees
    herdr:worktree.create)
      local ws branch base
      ws="$(target_workspace)"
      branch="$(prompt 'new worktree branch')" || return 1
      base="$(prompt_optional 'base ref (blank = current HEAD)')" || return 1
      set -- worktree create --workspace "$ws" --branch "$branch" --focus
      [ -n "$base" ] && set -- "$@" --base "$base"
      run_herdr "$@" >/dev/null ;;
    herdr:worktree.open)
      local ws path rows
      ws="$(target_workspace)"
      rows="$(
        run_herdr worktree list --workspace "$ws" --json \
          | jq -r '.result.worktrees[]
                   | [ .path,
                       ((.branch // "(detached)")
                        + (if .open_workspace_id then "  ·  already open" else "" end)
                        + "  ·  " + .path)
                     ] | @tsv'
      )"
      path="$(pick 'open worktree' "$rows")" || return 1
      run_herdr worktree open --workspace "$ws" --path "$path" --focus >/dev/null ;;
    herdr:worktree.remove)
      local ws branch
      ws="$(target_workspace)"
      branch="$(
        run_herdr worktree list --workspace "$ws" --json \
          | jq -r --arg ws "$ws" '.result.worktrees[] | select(.open_workspace_id == $ws) | .branch // .path' \
          | head -n1
      )"
      [ -n "$branch" ] || die "command-palette: workspace ${ws} is not a git worktree."
      confirm "Remove the worktree for '${branch}' (workspace ${ws})?" || return 1
      run_herdr worktree remove --workspace "$ws" >/dev/null ;;
    herdr:worktree.list)
      # `worktree list` prints JSON with or without --json, so render it ourselves.
      page "$(
        run_herdr worktree list --workspace "$(target_workspace)" --json \
          | jq -r '.result as $r
                   | "repo: \($r.source.repo_name)  (\($r.source.repo_root))", "",
                     ( $r.worktrees[]
                       | "\(.branch // "(detached)")\t\(if .open_workspace_id then "open as " + .open_workspace_id else "not open" end)\t\(.path)" )' \
          | tabulate
      )" ;;

    # agents
    herdr:agent.start)
      local pane cmd new_pane
      pane="$(target_pane)"
      cmd="$(prompt 'agent command' 'claude')" || return 1
      # Deliberately NOT `herdr agent start`. That command's contract changed in
      # herdr 0.8 — it now activates an existing pane (`--kind KIND --pane ID`) and
      # no longer accepts --cwd/--workspace/--split — whereas `pane split` followed
      # by `pane run` behaves the same on 0.7 and 0.8. It also hands the answer to
      # the new pane's own shell as a command line, so quotes and globs mean what
      # the user typed instead of being word-split and glob-expanded by us. herdr
      # picks the agent up on its own once it's running.
      new_pane="$(
        run_herdr pane split "$pane" --direction right --cwd "$origin_cwd" --focus \
          | jq -r '.result.pane.pane_id // empty'
      )"
      [ -n "$new_pane" ] || die "command-palette: herdr did not report a new pane id."
      run_herdr pane run "$new_pane" "$cmd" >/dev/null ;;
    herdr:agent.focus)
      local pane
      pane="$(pick 'focus agent' "$(agent_rows)")" || return 1
      run_herdr agent focus "$pane" >/dev/null ;;
    herdr:agent.rename)
      local pane name
      pane="$(pick 'rename agent' "$(agent_rows)")" || return 1
      name="$(prompt 'agent name')" || return 1
      run_herdr agent rename "$pane" "$name" >/dev/null ;;

    # server & maintenance
    herdr:server.reload-config)
      run_herdr server reload-config >/dev/null ;;
    herdr:server.stop)
      local answer
      answer="$(prompt "Stop the herdr server? Every pane in every workspace will be killed. Type 'stop' to confirm")" || return 1
      [ "$answer" = "stop" ] || return 1
      run_herdr server stop >/dev/null ;;
    herdr:integration.status)
      page "$(run_herdr integration status)" ;;
    herdr:integration.install)
      local name
      name="$(pick 'install integration' "$(integration_rows)")" || return 1
      page "$(run_herdr integration install "$name")" ;;
    herdr:integration.uninstall)
      local name
      name="$(pick 'uninstall integration' "$(integration_rows)")" || return 1
      confirm "Uninstall the ${name} integration?" || return 1
      page "$(run_herdr integration uninstall "$name")" ;;
    herdr:channel.show)
      page "$(run_herdr channel show)" ;;
    herdr:channel.set)
      local channel
      channel="$(
        pick 'update channel' "$(printf 'stable\tstable — normal releases\npreview\tpreview — opt-in preview builds\n')"
      )" || return 1
      page "$(run_herdr channel set "$channel")" ;;
    herdr:config.reset-keys)
      confirm 'Back up config.toml and remove all custom keybindings?' || return 1
      page "$(run_herdr config reset-keys)" ;;
    herdr:session.list)
      page "$(run_herdr session list)" ;;

    *)
      die "command-palette: unknown built-in action '${id}'." ;;
  esac
}

# ── the picker ──────────────────────────────────────────────────────────────

# Each line: "<id>\t<id> <title>". Field 1 is what we dispatch on; field 2 is what
# fzf displays. We hide our own plugin's actions (opening the palette from the
# palette is noise). Plugin discovery failing is not fatal — the built-ins alone
# are still a usable palette.
plugin_lines="$(
  "$herdr_bin" plugin action list 2>/dev/null \
    | jq -r --arg self "$self_plugin" '
        .result.actions[]
        | select(.plugin_id != $self)
        | (.plugin_id + "." + .action_id) as $qid
        | [ $qid, ($qid + " " + .title) ]
        | @tsv
      ' 2>/dev/null
)"

# Built-ins first, in catalog order — grouped by pane/tab/workspace/worktree/agent/
# server, with the plain form of an action ahead of its variants. That order is what
# you see with an empty query, and it's the final tiebreak between two entries fzf
# scores identically; sorting the list alphabetically instead would put "New tab,
# named…" above "New tab". Plugin actions follow, sorted, as before.
lines="$(
  builtin_catalog | awk -F'\t' 'NF > 1 { printf "%s\t%s %s\n", $1, $1, $2 }'
  [ -n "$plugin_lines" ] && printf '%s\n' "$plugin_lines" | sort -t$'\t' -k2,2
)"

[ -n "$lines" ] || die "command-palette: no actions available."

# fzf: display only field 2, but match against the whole line (so typing a plugin
# id works too).
#
# Sorting is deliberately left ON. `--no-sort` makes fzf list matches in input
# order, so a query is only ever a filter: typing "rename pane" ranked "Move pane
# to a new tab" (which merely holds those letters, scattered) above "Rename pane…"
# whenever the loose match sat earlier in the catalog. With sorting on, fzf's own
# scoring — which rewards contiguous, word-boundary matches and, all else equal,
# the shorter entry — floats the complete match to the top, and input order still
# decides an exact tie. An empty query is unaffected: fzf shows catalog order.
#
# Esc/Ctrl-C abort → empty selection → silent close.
choice="$(
  printf '%s\n' "$lines" \
    | fzf --delimiter=$'\t' \
          --with-nth=2 \
          --prompt='herdr action ▸ ' \
          --header='↑↓ select · enter run · esc cancel · “…” asks for input' \
          --reverse \
          --cycle \
          --no-multi
)" || true

[ -n "$choice" ] || exit 0

action_id="${choice%%$'\t'*}"

# Built-in herdr actions run right here against the CLI; run_builtin aborts loudly
# on failure and returns non-zero when the user cancels a prompt.
case "$action_id" in
  herdr:*)
    run_builtin "$action_id"
    exit 0
    ;;
esac

# Invoke the action. `herdr plugin action invoke` is fire-and-forget: it returns
# as soon as the action is DISPATCHED, so a zero exit only means "accepted" — the
# action's command can still fail afterwards (e.g. a moved/missing script exits
# 127). The response carries the dispatched run's log_id; we poll the plugin log
# until it reaches a terminal state so a failed action surfaces its error instead
# of the overlay vanishing on a silent no-op.
resp="$("$herdr_bin" plugin action invoke "$action_id" 2>&1)"
if [ $? -ne 0 ]; then
  die "command-palette: failed to invoke ${action_id}
${resp}"
fi

# Pull the run's log_id and owning plugin straight from the invoke response (the
# plugin_id is taken from the response rather than split off the action_id, which
# can itself contain dots, e.g. jamesboehmer.command-palette). If the response
# isn't the shape we expect (older herdr), skip polling and exit cleanly — never
# make a working invoke look broken.
log_id="$(printf '%s' "$resp" | jq -r '.result.log.log_id // empty' 2>/dev/null)"
plugin_id="$(printf '%s' "$resp" | jq -r '.result.log.plugin_id // empty' 2>/dev/null)"
[ -n "$log_id" ] && [ -n "$plugin_id" ] || exit 0

# Poll that run's log entry until it finishes (or we hit the deadline). Most
# actions complete in well under a second; one still "running" at the deadline is
# assumed to be a healthy long-running action and left alone.
i=0
while [ "$i" -lt 25 ]; do  # ~5s at 0.2s/iteration
  i=$((i + 1))
  entry="$(
    "$herdr_bin" plugin log list --plugin "$plugin_id" --limit 20 2>/dev/null \
      | jq -c --arg id "$log_id" '.result.logs[]? | select(.log_id == $id)' 2>/dev/null
  )"
  case "$(printf '%s' "$entry" | jq -r '.status // empty' 2>/dev/null)" in
    succeeded) exit 0 ;;
    failed)
      code="$(printf '%s' "$entry" | jq -r '.exit_code // "?"' 2>/dev/null)"
      err="$(printf '%s' "$entry" | jq -r '.stderr // empty' 2>/dev/null)"
      die "command-palette: ${action_id} failed (exit ${code})
${err}"
      ;;
  esac
  sleep 0.2
done
