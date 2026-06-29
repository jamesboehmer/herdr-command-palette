# herdr-command-palette

An [fzf](https://github.com/junegunn/fzf) **command palette** for [herdr](https://herdr.dev).

Press a key, get a fuzzy-searchable popup of **every action exposed by every
installed plugin**, pick one, and it runs. No more remembering which key is bound
to which plugin action.

```
herdr action ▸ ci
┌──────────────────────────────────────────────┐
│ ↑↓ select · enter run · esc cancel             │
│ > gitlab-ci-status.open Open CI status pane    │
│   gitlab-ci-status.start Start CI status dots  │
│   gitlab-ci-status.toggle Toggle CI status dots│
└──────────────────────────────────────────────┘
```

## Requirements

- [herdr](https://herdr.dev) ≥ 0.7.0
- [`fzf`](https://github.com/junegunn/fzf)
- [`jq`](https://jqlang.github.io/jq/)

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
   popup over the active pane, which *does* get a TTY. The originating
   workspace's cwd is forwarded to the overlay via `--cwd`.
2. Inside the overlay, [`palette.sh`](palette.sh) runs
   `herdr plugin action list`, formats each entry as `plugin.action <title>`,
   and pipes it to `fzf`.
3. On selection it runs `herdr plugin action invoke <plugin.action>`. Because the
   overlay carries the origin cwd, context-aware actions (e.g. opening a pane for
   "the current repo") resolve correctly.
4. When the script exits, herdr tears the overlay down and restores your previous
   pane and zoom state — nothing is left behind.

The palette hides its own `open` action from the list.

## License

[MIT](LICENSE) © Jan Tvrdík
