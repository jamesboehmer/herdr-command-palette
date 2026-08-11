#!/usr/bin/env bash
# Action `jt.command-palette.open`: open the fzf command-palette overlay.
#
# This runs on the herdr server (no TTY), so it can't run fzf directly. It opens
# the `palette` overlay pane (see herdr-plugin.toml), which gets a real terminal
# and runs palette.sh.
#
# We forward the ORIGIN workspace's cwd to the overlay via `--cwd`. That matters
# because when palette.sh later runs `herdr plugin action invoke <id>`, the server
# resolves the action's context from the focused pane — which is now this overlay.
# Setting the overlay's cwd to the origin repo makes context-aware actions (e.g.
# gitlab-ci-status.open, which reads `.focused_pane_cwd`) resolve the right repo.
#
# We also forward the origin pane/tab/workspace IDS as env vars. The palette's
# built-in herdr actions (split pane, rename tab, close workspace…) need an
# explicit target: the herdr CLI defaults to "the focused pane", which is the
# overlay itself once the palette is up, so without these the built-ins would
# operate on the palette instead of on the pane the user opened it from.
set -uo pipefail

herdr_bin="${HERDR_BIN_PATH:-herdr}"
ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}"

# Resolve the repo/dir and the ids of the pane/tab/workspace we were invoked from.
repo=""
origin_pane=""
origin_tab=""
origin_workspace=""
if [ -n "$ctx" ] && command -v jq >/dev/null 2>&1; then
  repo="$(printf '%s' "$ctx" | jq -r '.focused_pane_cwd // .workspace_cwd // empty' 2>/dev/null || true)"
  origin_pane="$(printf '%s' "$ctx" | jq -r '.focused_pane_id // empty' 2>/dev/null || true)"
  origin_tab="$(printf '%s' "$ctx" | jq -r '.tab_id // empty' 2>/dev/null || true)"
  origin_workspace="$(printf '%s' "$ctx" | jq -r '.workspace_id // empty' 2>/dev/null || true)"
fi
[ -n "$repo" ] || repo="${HERDR_WORKSPACE_CWD:-}"

set -- plugin pane open \
  --plugin jt.command-palette \
  --entrypoint palette \
  --placement overlay \
  --focus

# Forward whatever context we managed to resolve. palette.sh falls back to the
# focused pane when a value is missing, so partial context is still useful.
[ -n "$origin_pane" ]      && set -- "$@" --env "HERDR_PALETTE_ORIGIN_PANE=$origin_pane"
[ -n "$origin_tab" ]       && set -- "$@" --env "HERDR_PALETTE_ORIGIN_TAB=$origin_tab"
[ -n "$origin_workspace" ] && set -- "$@" --env "HERDR_PALETTE_ORIGIN_WORKSPACE=$origin_workspace"
[ -n "$repo" ]             && set -- "$@" --env "HERDR_PALETTE_ORIGIN_CWD=$repo"

# Only forward --cwd when it's a real directory; otherwise the overlay falls back
# to the plugin root (the pane command uses $HERDR_PLUGIN_ROOT, so it resolves
# either way).
if [ -n "$repo" ] && [ -d "$repo" ]; then
  set -- "$@" --cwd "$repo"
fi

exec "$herdr_bin" "$@"
