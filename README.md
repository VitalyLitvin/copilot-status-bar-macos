# Copilot Statusbar for macOS

Native macOS menu bar app for [GitHub Copilot CLI](https://github.com/github/copilot-cli).

It shows one of three states in the menu bar, based on the `copilot` CLI process:

- **Waiting for a task** (gray icon) — Copilot CLI is not running
- **Needs your input** (amber icon) — Copilot CLI is running and idle at the prompt
- **working 3m**, **working 1h 12m**, etc. (blue icon) — Copilot CLI is actively generating a response / running a tool

Click the menu bar item for details (PID, CPU usage, current command) and quick actions.

## Build

```bash
make build
```

## Run during development

```bash
make run
```

## Create `.app`

```bash
make app
open "dist/Copilot Statusbar.app"
```

## Install locally

```bash
make install
open "/Applications/Copilot Statusbar.app"
```

## Homebrew packaging later

This project intentionally uses only Swift Package Manager and AppKit, so it can be packaged with a simple Homebrew formula/cask:

- `swift build -c release` for a CLI-style binary
- `make app` for a macOS `.app` bundle

Linux should be a separate implementation later, likely using AppIndicator/GTK or Qt tray APIs.
