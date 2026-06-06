<div align="center">

<h1>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="logo_dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="logo_light.svg">
  <img alt="Volute" height="128" src="logo_light.svg">
</picture>
</h1>

**Volute** is an out-of-the-box TUI editor inspired by Helix.

</div>

## What is Volute?

Volute is a terminal-first editor focused on being immediately usable, fast to start, and comfortable for modal editing.

It takes clear inspiration from Helix — modal workflows, composable motions, a clean full-screen interface, and modern code-editing ergonomics — while shaping them into its own TUI editing experience.

## Inspired by Helix

Helix is one of the main design references for Volute:

- the editing model and modal workflow
- the terminal-first interaction style
- the general shape of editor commands and navigation
- the emphasis on modern, language-aware text editing

This repository still includes upstream Helix material for reference. The active editor implementation for Volute lives under `src/`, builds with Zig, and currently produces the `vx` binary.

## Current direction

Volute already includes a growing slice of the editor core:

- modal normal / insert / select workflows
- file open, save, buffer switching, and window splits
- search, surround operations, yank / paste, undo / redo
- syntax highlighting and terminal rendering
- multiple text storage strategies, including gap buffer and tree rope backends

It is still an early-stage project, but the direction is clear: a practical TUI editor with a familiar modal workflow and a clean default experience.

## Build

```sh
zig build
./zig-out/bin/vx
```

To open a file directly:

```sh
zig build run -- path/to/file
```

## Test

```sh
zig build test
```

## Terminal compatibility (pure Zig backend)

Volute now uses a pure Zig terminal backend (`src/tui`) and applies capability-based fallbacks by terminal family.

**Phase 1 validated targets**

- kitty
- wezterm
- iTerm2
- Windows Terminal
- tmux on top of kitty/wezterm/iTerm2

**Behavior notes**

- Interactive TUI mode requires both stdin/stdout to be TTY; otherwise `vx` exits with a clear error.
- VSCode integrated terminal defaults to non-alt-screen mode for visibility/stability.
- In tmux/screen, capabilities are intentionally conservative for stability.
- Unsupported style/color features gracefully downgrade (e.g. truecolor -> 256-color -> 16-color).

**Capability override env vars**

| Variable | Example | Effect |
| --- | --- | --- |
| `VX_TUI_COLOR_DEPTH` | `truecolor` / `ansi256` / `ansi16` / `mono` | Force color depth |
| `VX_TUI_NO_ITALIC` | `1` | Disable italic style emission |
| `VX_TUI_NO_UNDERLINE` | `1` | Disable underline style emission |
| `VX_TUI_DISABLE_MOUSE` | `1` | Disable SGR mouse handling |
| `VX_TUI_DISABLE_CURSOR_SHAPE` | `1` | Disable cursor shape sequence emission |
| `VX_TUI_FORCE_FOCUS_EVENTS` | `1` | Force-enable focus event capability |

## Repository layout

| Path | Purpose |
| --- | --- |
| `src/` | The Zig implementation of the editor core and terminal UI |
| `build.zig` | Zig build entry point for `vx` |
| `helix-*`, `runtime/`, `docs/`, `xtask/` | Helix-related upstream material kept as reference |

## Why the name?

A *volute* is a spiral form — a shape that fits the editor's flowing, terminal-native identity.

## License

This repository is distributed under the terms of the [MPL-2.0](./LICENSE).
