#!/usr/bin/env bash
# Pane `jt.command-palette.palette`: the interactive fzf picker.
#
# Runs inside an overlay pane (real TTY). Lists every action from every installed
# plugin, lets the user fuzzy-pick one, and invokes it. When this script exits the
# overlay closes on its own.
set -uo pipefail

herdr_bin="${HERDR_BIN_PATH:-herdr}"
self_plugin="${HERDR_PLUGIN_ID:-jt.command-palette}"

# Brief pause + message helper so failures don't vanish when the overlay closes.
die() {
  printf '%s\n' "$*" >&2
  printf 'Press any key to close…' >&2
  read -r -n1 _ 2>/dev/null || sleep 2
  exit 1
}

command -v fzf >/dev/null 2>&1 || die "command-palette: fzf is not installed or not on PATH."
command -v jq  >/dev/null 2>&1 || die "command-palette: jq is not installed or not on PATH."

# Each line: "<plugin_id>.<action_id>\t<plugin_id>.<action_id> <title>"
# Field 1 is the fully-qualified id we invoke; field 2 is what fzf displays.
# We hide our own plugin's actions (opening the palette from the palette is noise).
lines="$(
  "$herdr_bin" plugin action list 2>/dev/null \
    | jq -r --arg self "$self_plugin" '
        .result.actions[]
        | select(.plugin_id != $self)
        | (.plugin_id + "." + .action_id) as $qid
        | [ $qid, ($qid + " " + .title) ]
        | @tsv
      ' 2>/dev/null \
    | sort -t$'\t' -k2,2
)"

[ -n "$lines" ] || die "command-palette: no plugin actions available."

# fzf: display only field 2, but match against the whole line (so typing a plugin
# id works too). Esc/Ctrl-C abort → empty selection → silent close.
choice="$(
  printf '%s\n' "$lines" \
    | fzf --delimiter=$'\t' \
          --with-nth=2 \
          --prompt='herdr action ▸ ' \
          --header='↑↓ select · enter run · esc cancel' \
          --reverse \
          --cycle \
          --no-multi \
          --no-sort
)" || true

[ -n "$choice" ] || exit 0

action_id="${choice%%$'\t'*}"

# Invoke. Capture output so a failure is visible before the overlay closes;
# on success, just exit and let the overlay disappear.
if ! out="$("$herdr_bin" plugin action invoke "$action_id" 2>&1)"; then
  die "command-palette: failed to invoke ${action_id}
${out}"
fi
