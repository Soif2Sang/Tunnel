# Tunnel

Native macOS menu bar app to manage `kubectl port-forward` sessions across multiple
Kubernetes clusters. Replaces a wall of `pf-*` shell aliases with a real UI:
fuzzy-search any service across every context, forward it to a local port,
auto-restart on disconnects, and see live status at a glance.

![status: alpha](https://img.shields.io/badge/status-alpha-orange)

## Features

- **Fuzzy service search across all contexts.** Type "goldgard" → see every
  matching service in every namespace in every cluster, grouped by `cluster › namespace`.
- **Service-based port-forwards.** Targets `services/<name>` so kubectl picks a
  healthy pod automatically — no fragile `kubectl get pods | grep | awk` dance.
- **Auto-restart on disconnect** with exponential backoff (1s, 2s, 5s, 10s, …, 60s, capped at 10 attempts).
- **Pre-flight port-conflict detection** via `lsof`.
- **OIDC-aware.** Spawns kubectl with the right `PATH` so the `oidc-login` exec plugin works.
- **Live state machine per forward** — idle, connecting, running, reconnecting, failed.
- **One-time import** of existing `pf-*` aliases from `~/.zshrc`.
- **Auto-start at launch** — opt-in per forward.
- **Menu bar status icon** with running-count badge, plus a full management window.

## Requirements

- macOS 14.0+
- Xcode 16.0+
- `kubectl` on `PATH` (auto-detected at `/usr/local/bin/kubectl` or `/opt/homebrew/bin/kubectl`).
- For OIDC clusters: `kubelogin` (`oidc-login`) installed at `/opt/homebrew/bin/oidc-login`
  (or set the "Extra PATH" in Settings to wherever yours lives).

## Build & run

```sh
brew install xcodegen          # if you don't have it
xcodegen generate
open Berth.xcodeproj
```

In Xcode: select the `Berth` scheme and ⌘R. The app has `LSUIElement: true`,
so it lives in the menu bar and doesn't show a Dock icon.

To build from CLI:

```sh
xcodebuild -project Berth.xcodeproj -scheme Berth -configuration Debug build
```

To run the unit tests:

```sh
xcodebuild -project Berth.xcodeproj -scheme Berth -destination 'platform=macOS' test
```

## How it works

```
┌──────────────────────────┐
│  MenuBarView (popover)   │   AppDelegate owns NSStatusItem
└────────────┬─────────────┘
             │
             ▼
       ┌───────────┐
       │ AppState  │   @MainActor @Observable, single source of truth
       └─────┬─────┘
             │
   ┌─────────┼──────────────────────────────┐
   ▼         ▼                              ▼
┌──────┐  ┌────────────────┐    ┌────────────────────────┐
│Store │  │ ServiceCatalog │    │  PortForwardManager    │  actor
└──────┘  └────────┬───────┘    └────────────┬───────────┘
                   │                         │
                   ▼                         ▼
              ┌────────────────────────────────┐
              │       KubectlClient            │  actor, spawns Process
              └────────────────────────────────┘
```

`KubectlClient` spawns `kubectl` with a curated environment
(`PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`) so the OIDC plugin is
always findable. Each port-forward is a long-running `Process` whose stderr is
parsed line-by-line for state transitions (`Forwarding from 127.0.0.1:…` →
running; `lost connection` / non-zero exit → reconnect).

## Project layout

```
Berth/
  project.yml                      XcodeGen spec
  SPEC.md                          Design document
  Berth/
    App/                           Entry point + AppDelegate (status item)
    Models/                        Plain data types
    Services/                      Side-effecting actors / classes
    State/                         AppState (@Observable) + ConfigStore
    Views/                         SwiftUI screens
    Resources/                     Info.plist, Assets.xcassets
  BerthTests/                      Unit tests
```

## Configuration

Saved forwards live at `~/Library/Application Support/Berth/forwards.json`
(JSON, version-stamped, atomic writes).

The app does **not** modify your `~/.kube/config`; it only reads it through
`kubectl`. Likewise it never modifies your `~/.zshrc`; the importer is read-only.

## Known limitations

- v1 only forwards to `services/<name>` (not raw pods or selectors).
- No code signing — run from Xcode or `xattr -dr com.apple.quarantine` the
  build product.
- Local ports must be ≥ 1024 (privileged ports unsupported in v1).
- No iCloud sync; configuration is per-machine.
