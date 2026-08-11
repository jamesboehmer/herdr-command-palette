# herdr-command-palette

An [fzf](https://github.com/junegunn/fzf) **command palette** for [herdr](https://herdr.dev).

Press a key, get a fuzzy-searchable popup of **herdr's own built-in actions** plus
**every action exposed by every installed plugin**, pick one, and it runs. No more
remembering which key is bound to what.

```
herdr action ▸ tab
┌────────────────────────────────────────────────┐
│ ↑↓ select · enter run · esc cancel · “…” asks  │
│ > herdr:tab.new New tab                        │
│   herdr:tab.new-named New tab, named…          │
│   herdr:tab.rename Rename tab…                 │
│   herdr:tab.switch Switch to tab…              │
│   herdr:pane.move-to-tab Move pane to another…│
└────────────────────────────────────────────────┘
```

Built-in entries are prefixed `herdr:`; plugin actions keep their
`plugin.action` id. A title ending in `…` asks for something first — a name or a
path at a text prompt (pre-filled with the current value, so you can edit it), or
a second fzf picker to choose which tab, workspace, worktree or agent.

## Built-in actions

| Group | Actions |
|---|---|
| Pane | split right/down, rename, clear name, close, move to another tab / a new tab / a new workspace |
| Tab | new, new named, rename, close, next, previous, switch to… |
| Workspace | new here, new in another directory…, rename, close, switch to…, next, previous |
| Worktree | new…, open existing…, remove this workspace's, list |
| Agent | start…, focus…, rename… |
| Server | reload config, stop server, integration status/install/uninstall, update channel show/set, reset keybindings, list sessions |

Anything that closes or destroys something asks for confirmation first (`server
stop` wants you to type `stop`), and a built-in that fails shows herdr's own error
instead of the overlay just vanishing.

### What's deliberately not there

Two families of built-in can't work from a palette, so they're left out rather
than shipped broken:

- **UI-only commands** — help, settings, resize mode, the sidebar toggle, goto,
  detach, the scrollback editor, the built-in pickers. These exist only as
  interactive UI in herdr's client; the socket API has no entry point for them, so
  nothing outside herdr can trigger them. Where an equivalent was possible the
  palette provides one — "Switch to workspace…" stands in for the workspace picker.
- **Zoom and the directional pane commands** (`focus`/`swap`/`resize` left, down,
  up, right). The overlay the palette runs in is not a floating window — it's a
  real, *zoomed* pane inserted into the origin tab's split tree. So the tab is
  always already zoomed (a zoom toggle just cancels the overlay's own zoom), a
  direction resolves against the overlay's own rectangle as often as against the
  pane you meant, and a focus or swap that does land leaves the tab zoomed on the
  target once the overlay tears down. Use the native keys for these: `prefix+z`,
  `prefix+h/j/k/l`, `prefix+r`.

## Requirements

- [herdr](https://herdr.dev) ≥ 0.7.0
- [`fzf`](https://github.com/junegunn/fzf)
- [`jq`](https://jqlang.github.io/jq/)

`less` and `column`, if present, are used to page and align the read-only built-ins
(worktree list, integration status…); without them the output is printed as-is.

## Install

```bash
herdr plugin install JanTvrdik/herdr-command-palette
```

…or, for local development:

```bash
git clone https://github.com/JanTvrdik/herdr-command-palette
herdr plugin link ./herdr-command-palette
```

## Bind a key

herdr 0.7 does not bind keys declared in a plugin manifest, so add a binding to
your `~/.config/herdr/config.toml` and reload:

```toml
[[keys.command]]
key = "prefix+p"
type = "plugin_action"
command = "jt.command-palette.open"
description = "Command palette"
```

```bash
herdr server reload-config
```

Now `prefix` (Ctrl+B by default) then `p` opens the palette.

## How it works

herdr actions run on the server with **no TTY**, so an action can't run fzf
directly. Instead:

1. The `jt.command-palette.open` action opens an **overlay pane** — a temporary
   popup over the active pane, which *does* get a TTY. The originating workspace's
   cwd is forwarded via `--cwd`, and the origin pane, tab and workspace ids are
   forwarded as `HERDR_PALETTE_ORIGIN_*` env vars.
2. Inside the overlay, [`palette.sh`](palette.sh) merges its own catalog of herdr
   built-ins with `herdr plugin action list`, formats each entry as
   `<id> <title>`, and pipes it to `fzf`.
3. On selection:
   - a **built-in** runs against the herdr CLI right there — `herdr tab create`,
     `herdr worktree open`, and so on — prompting or opening a sub-picker first if
     the command needs an argument;
   - a **plugin action** is dispatched with `herdr plugin action invoke <id>`, then
     the plugin log is polled until the run finishes, so a plugin whose script
     fails reports its error instead of closing silently.
4. When the script exits, herdr tears the overlay down and restores your previous
   pane and zoom state — nothing is left behind.

Those forwarded ids are what make built-ins act on the right place. The overlay is
itself a pane, so `herdr pane current` returns *the palette*; without an explicit
target, "split pane" would split the popup. If the env vars are missing (the pane
was opened by hand, say) `palette.sh` falls back to `HERDR_PLUGIN_CONTEXT_JSON`,
which herdr sets in every plugin pane and whose `focused_pane_id` is the pane the
overlay is covering.

The palette hides its own `open` action from the list.

## License

[MIT](LICENSE) © Jan Tvrdík
