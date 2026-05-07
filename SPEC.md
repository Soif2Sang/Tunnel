# Berth — Spec

Native macOS app that replaces ad-hoc `kubectl port-forward` shell aliases with a menu bar tool: fuzzy-find any service across all your Kubernetes clusters, forward it to a local port, monitor the connection, auto-restart on drops.

---

## 1. Goals & non-goals

### Goals (v1)

1. Discover all Kubernetes services across all configured contexts and namespaces, fuzzy-searchable by name.
2. Start, stop, and persist `kubectl port-forward` sessions backed by `services/<name>` (not raw pod names).
3. Show live status (idle, connecting, running, reconnecting, failed) for each saved forward.
4. Auto-restart forwards when kubectl exits unexpectedly, with bounded exponential backoff.
5. Auto-start designated forwards at app launch (per-forward opt-in).
6. One-time import of existing `pf-*` aliases from `~/.zshrc`.
7. Menu bar quick-access + main window for management.

### Non-goals (v1)

- No Kubernetes API client (we shell out to `kubectl` to inherit OIDC auth via `oidc-login`).
- No write operations against the cluster (no apply, no exec, no delete).
- No multi-machine sync; all state is local.
- No code signing / notarization; this is a personal-use app, run-from-Xcode or unsigned local build.
- No support for `kubectl proxy`, port-forwarding to raw pods (only services), or UDP forwarding.

---

## 2. Background — what we're replacing

User's current `~/.zshrc` aliases:

```
pf-goldgard-staging    → kubectl port-forward services/goldgard-api 3100:3000 -n 271-goldgard-staging
pf-goldgard-production → kubectl port-forward services/goldgard-api 3100:3000 -n 271-goldgard-production
pf-adstxt-staging      → kubectl port-forward services/adstxt-checker-api 3100:3000 -n 183-adstxt-checker-staging
pf-adstxt-production   → kubectl port-forward services/adstxt-checker-api 3100:3000 -n 183-adstxt-checker-production
pf-adsleuth-staging    → kubectl port-forward -n 224-adsleuth-staging $(kubectl get pods ... | grep adsleuth-api | awk '{print $1}') 3001:3000
```

Pain points:
- Have to open a terminal and remember alias names.
- All target the currently active context (`oidc@sparteo`); nothing for `actirise` / `meetscale` / `viously`.
- The `adsleuth` alias does a fragile pod-name dance; will fail or attach to a stale pod.
- No visibility when a forward dies silently.
- No simultaneous forwards without juggling terminal tabs.

User's environment:
- `kubectl` 1.31.4 at `/usr/local/bin/kubectl`.
- Auth: `kubectl oidc-login get-token` (kubelogin plugin), located at `/opt/homebrew/bin/oidc-login`. Issuer = `https://portal.sparteo.com`.
- Contexts: `oidc@sparteo` (current), `oidc@actirise`, `oidc@meetscale`, `oidc@viously`. All four use the same OIDC user `oidc`.
- One context (`oidc@sparteo`) also references an `infra` exec plugin at `/opt/homebrew/bin/infra` for cluster-info.

---

## 3. User stories

1. **Quick start a saved forward** — Click menu bar icon → see "goldgard staging (sparteo)" → click play → status flips to green.
2. **Find a new service to forward** — Open main window → type `adsleuth` → see all matching services across clusters → pick one → set local port `3001` → save and start.
3. **See why a forward is broken** — Status icon turns red → click the forward → see stderr panel: "error: lease lost".
4. **Switch all forwards on/off in bulk** — Menu bar has "Stop all" / "Start auto-start group".
5. **First launch onboarding** — App imports existing `pf-*` aliases, shows them in main window, asks which to mark auto-start.
6. **OIDC re-auth** — A forward needs auth refresh → app shows "authenticating…" state, lets `oidc-login` open the browser, recovers when auth completes.

---

## 4. Architecture

```
┌──────────────────────────────┐         ┌──────────────────────────────┐
│  MenuBarView (NSStatusItem)  │         │   MainWindowView (SwiftUI)   │
│  - Status icon (color)       │         │   - Search bar + results     │
│  - Saved forwards list       │         │   - Saved forwards table     │
│  - Start/stop toggles        │         │   - Per-forward log panel    │
└──────────────┬───────────────┘         └──────────────┬───────────────┘
               │                                        │
               └────────────────┬───────────────────────┘
                                ▼
                      ┌──────────────────┐
                      │    AppState      │  @Observable, single source of truth
                      │  (forwards,      │
                      │   sessions,      │
                      │   catalog)       │
                      └─┬─────────┬──────┘
                        │         │
            ┌───────────┘         └───────────┐
            ▼                                 ▼
  ┌────────────────────┐            ┌──────────────────────┐
  │ PortForwardManager │            │   ServiceCatalog     │
  │  - sessions[id]    │            │  - services[ctx]     │
  │  - start / stop    │            │  - refresh(ctx)      │
  │  - auto-restart    │            │  - fuzzy(query)      │
  └─────────┬──────────┘            └──────────┬───────────┘
            │                                  │
            └──────────────┬───────────────────┘
                           ▼
                ┌──────────────────────┐
                │    KubectlClient     │
                │  spawn(args) -> Pipe │
                │  env: PATH curated   │
                └──────────┬───────────┘
                           ▼
                ┌──────────────────────┐
                │     Process          │
                │  /usr/local/bin/kub… │
                └──────────────────────┘
```

### Layer responsibilities

| Layer | File | Responsibility |
|---|---|---|
| **Models** | `PortForward.swift` | Saved-forward record (id, name, context, namespace, service, localPort, remotePort, autoStart). Codable. |
| | `KubeService.swift` | Discovered service (context, namespace, name, ports, labels). |
| | `KubeContext.swift` | (name, cluster, namespace, isCurrent). |
| | `SessionState.swift` | Enum: `idle`, `connecting`, `running(since: Date)`, `reconnecting(attempt: Int, nextAt: Date)`, `failed(reason: String)`. |
| **Services** | `KubectlClient.swift` | One process-spawning helper. Builds env (`PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`, `HOME` inherited). Two flavors: `runJSON()` (one-shot, parse JSON), `streaming()` (long-running, returns AsyncStream of stderr lines + termination). |
| | `ServiceCatalog.swift` | Refreshes `kubectl get services -A -o json` per context, in parallel. Caches in-memory (TTL 60s). Exposes fuzzy search using simple subsequence + score. |
| | `KubeContextLoader.swift` | One-shot `kubectl config get-contexts -o name` to enumerate the 4 contexts. |
| | `PortForwardManager.swift` | Owns `[UUID: PortForwardSession]`. Each session wraps a `Process`. State transitions, backoff scheduling. |
| | `PortForwardSession.swift` | One running forward. Reads stderr line-by-line (`Forwarding from 127.0.0.1:3100 -> 3000` → running, `lost connection` / non-zero exit → reconnecting). |
| | `LocalPortChecker.swift` | `lsof -nP -iTCP:<port> -sTCP:LISTEN` to detect conflicts before starting. |
| | `ZshrcImporter.swift` | Parses `~/.zshrc` for `alias pf-...="kubectl port-forward services/X Y:Z -n N"`. Returns draft `PortForward` records. |
| **State** | `AppState.swift` | `@Observable`. Holds `[PortForward]`, `[UUID: SessionState]`, `ServiceCatalog`, `[KubeContext]`. Mediates between views and services. |
| | `ConfigStore.swift` | Persists `[PortForward]` to `~/Library/Application Support/Berth/forwards.json`. Atomic writes, schema version. |
| **Views** | `MenuBarView.swift` | NSStatusItem with custom SwiftUI menu. Counter badge of running forwards on the icon. |
| | `MainWindowView.swift` | Tabs: Search, Forwards, Settings. |
| | `SearchView.swift` | TextField + grouped results (`cluster › namespace`). On select, opens `AddForwardSheet`. |
| | `AddForwardSheet.swift` | Form: name, local port (validated), remote port (default = service's first port), auto-start toggle. |
| | `ForwardsListView.swift` | Table of saved forwards: name, target, status badge, play/stop, edit, delete. |
| | `ForwardDetailView.swift` | Shows live state, recent stderr (last 200 lines), uptime, "force restart" button. |
| | `SettingsView.swift` | Refresh-context-list, re-import zshrc, choose kubectl path. |
| **App** | `BerthApp.swift` | `@main`, owns `AppState`, sets up `MenuBarExtra` + window. |

### Concurrency

- All Process spawns use `Task` + structured concurrency.
- `KubectlClient.streaming()` returns an `AsyncStream<KubectlEvent>` that yields stderr lines + a final `terminated(status: Int32)`. The session's reconnect logic awaits the stream end.
- `PortForwardManager` is an `actor` to serialize state mutations across forwards.
- Catalog refresh fans out per context via `withTaskGroup`.

---

## 5. Data model

```swift
struct PortForward: Codable, Identifiable {
    let id: UUID
    var displayName: String          // "goldgard-api (staging)"
    var context: String              // "oidc@sparteo"
    var namespace: String            // "271-goldgard-staging"
    var serviceName: String          // "goldgard-api"
    var localPort: Int               // 3100
    var remotePort: Int              // 3000
    var autoStart: Bool              // false
    var createdAt: Date
}

enum SessionState: Equatable {
    case idle
    case connecting
    case running(since: Date, localBinding: String)   // "127.0.0.1:3100"
    case reconnecting(attempt: Int, nextAttemptAt: Date, lastError: String)
    case failed(reason: FailureReason)
}

enum FailureReason: Equatable {
    case localPortInUse(Int)
    case authenticationFailed       // oidc-login non-zero exit
    case kubectlNotFound
    case serviceNotFound
    case maxRetriesExceeded
    case userStopped
    case other(String)
}
```

`forwards.json` schema:

```json
{
  "version": 1,
  "forwards": [ { ... PortForward ... } ]
}
```

---

## 6. State machine — port-forward lifecycle

```
                   user stops or app quits
                  ┌─────────────────────────────────────────────────────┐
                  │                                                     │
              start│                                                     ▼
   ┌────┐ ────────┐│           ┌──────────────┐    stderr: "Forwarding"   ┌──────────────┐
   │Idle│         ▼│           │  Connecting  │ ────────────────────────▶ │   Running    │
   └────┘  ┌──────────┐ spawn  │              │                           │              │
           │  Idle    │ ─────▶ └──────┬───────┘                           └──────┬───────┘
           └──────────┘                │                                          │
                                       │ exit≠0 OR oidc-login fail                │ process exits OR
                                       │                                          │ stderr "lost connection"
                                       ▼                                          │
                                 ┌──────────────┐  backoff [1,2,5,10,10s]          │
                                 │ Reconnecting │ ◀──────────────────────────────┘
                                 │  attempt=N   │
                                 └──────┬───────┘
                                        │ attempt > 10
                                        ▼
                                 ┌──────────────┐
                                 │   Failed     │
                                 └──────────────┘
```

Transitions:
- `idle → connecting`: user clicks play, or auto-start at launch, or auto-restart.
- `connecting → running`: stderr line matches `Forwarding from`.
- `connecting → reconnecting`: process exits before `Forwarding from` appears (transient: oidc-login retry, network blip).
- `running → reconnecting`: stderr matches `lost connection|error|E\d{4}` OR process exits with non-zero status.
- `reconnecting → connecting`: backoff timer fires.
- `reconnecting → failed`: attempt > 10. (User can manually retry to reset.)
- `* → idle`: user stops.
- `* → failed(localPortInUse)`: pre-flight `lsof` check fails.
- `connecting → failed(authenticationFailed)`: stderr matches `error: oidc-login.*token` or specific kubelogin failure pattern.

Backoff schedule (seconds): `[1, 2, 5, 10, 10, 10, 30, 30, 60, 60]` — capped, no jitter (single-user, single-machine).

---

## 7. UI flows

### Menu bar (always visible)

```
┌─────────────────────────────────┐
│ ● Berth        2 active   ▼     │
├─────────────────────────────────┤
│ ● goldgard-api (staging)        │
│   sparteo / 271-goldgard-staging│
│   :3100  →  3000      [stop]    │
│                                 │
│ ● adsleuth-api (staging)        │
│   sparteo / 224-adsleuth-staging│
│   :3001  →  3000      [stop]    │
│                                 │
│ ○ goldgard-api (production)     │
│   sparteo / 271-goldgard-prod   │
│   :3100  →  3000      [start]   │
├─────────────────────────────────┤
│ Open Berth…                     │
│ Stop all                        │
│ Quit                            │
└─────────────────────────────────┘
```

Status icon color: green = ≥1 running and 0 failed; yellow = ≥1 connecting/reconnecting; red = ≥1 failed; grey = all idle.

### Main window — Search tab

Type "goldgard" → results grouped:

```
sparteo › 271-goldgard-staging
   ● goldgard-api          :3000     [+ forward]
   ● goldgard-worker       :8080     [+ forward]

sparteo › 271-goldgard-production
   ● goldgard-api          :3000     [+ forward]

actirise › 099-shared
   ● goldgard-bridge       :3000     [+ forward]
```

### Main window — Forwards tab

Table of all saved forwards with: name, target, local port, status pill, actions (play/stop, edit, delete, auto-start toggle).

### Main window — Settings

- "Refresh context list" button (re-runs `kubectl config get-contexts`).
- "Re-import from .zshrc" button.
- "Default kubectl path" (auto-detected, editable).
- "Default extra PATH" (auto-detected to `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`, editable).

---

## 8. zshrc importer — parsing rules

Match per line:

```
^alias\s+(pf-[\w-]+)\s*=\s*['"]?kubectl\s+port-forward\s+services/(\S+)\s+(\d+):(\d+)\s+-n\s+(\S+)['"]?
```

Capture groups: `displayName-stem`, `serviceName`, `localPort`, `remotePort`, `namespace`. Context is inferred as the currently active context at import time, with a UI confirmation step letting the user reassign per-row.

Lines that don't match (e.g. the `adsleuth` `$(get pods | grep | awk)` form) are surfaced as "couldn't auto-import — found X, please configure manually" with the raw alias body shown.

---

## 9. Edge cases & decisions

| # | Case | Decision |
|---|---|---|
| 1 | OIDC token expired → kubectl spawns `oidc-login` which opens browser | Treat first 10s of stderr silence in `connecting` as "auth pending"; surface a yellow "Authenticating…" state. Don't time out until 60s. |
| 2 | User has two clusters with services of the same name | Search results group by `cluster › namespace`, fully qualifying every entry. |
| 3 | Two saved forwards bind the same local port | Pre-flight `lsof` blocks the second one starting; show clear error. Optional: auto-pick next free port (off by default). |
| 4 | User edits `~/.kube/config` after launch (new context) | Settings panel "Refresh context list" button. Auto-watch is out-of-scope for v1. |
| 5 | Service has multiple ports | `AddForwardSheet` shows port picker with names ("http", "grpc", etc.). Default = first port. |
| 6 | Service exists in catalog but is later deleted | When session fails to start, surface `serviceNotFound`. Catalog refresh on next open will drop it from suggestions. The saved forward remains (user can edit/delete manually). |
| 7 | Network completely down | Backoff hits cap and stays there indefinitely; eventually `failed`. User-initiated retry resets attempt count. |
| 8 | App quits with running forwards | Send SIGTERM to all kubectl processes, await up to 2s, then SIGKILL. Persist last known auto-start set to `forwards.json`. |
| 9 | App relaunched while previous instance still alive | Use `NSRunningApplication` check on bundle id at startup; if duplicate, focus existing and exit. |
| 10 | Local port < 1024 | Reject in form validation (would need root, not supporting privileged ports in v1). |
| 11 | `kubectl` missing or path wrong | Surface as `kubectlNotFound`; Settings lets user set explicit path. Auto-detect order: `/usr/local/bin/kubectl`, `/opt/homebrew/bin/kubectl`, `which kubectl`. |
| 12 | OIDC plugin missing from PATH | Same: surface auth failure with hint to add `/opt/homebrew/bin` to extra PATH. |
| 13 | User starts a forward, then changes context in their shell | Irrelevant — Berth's spawned kubectl uses the explicit `--context` flag, not the global current context. |
| 14 | Catalog refresh of an unreachable cluster (VPN down) | Per-context fetch has a 10s timeout; failed contexts show a "couldn't reach" indicator next to their group header but don't block other contexts. |
| 15 | Restart after macOS reboot with auto-start forwards | App opens menu bar at login (LaunchAgent registered via `SMAppService.mainApp.register()`), starts forwards marked `autoStart: true`. Opt-in via Settings. |

---

## 10. Security & permissions

- No code signing in v1 → run from Xcode or `xattr -dr com.apple.quarantine`.
- App Sandbox: **disabled** (we need to spawn `kubectl` and read `~/.kube/config` & `~/.zshrc`).
- Hardened Runtime: not required.
- No keychain access; OIDC tokens stay in `~/.kube/cache/oidc-login/` managed by kubelogin.
- No network calls from the app itself; everything tunnels through kubectl.

---

## 11. Out of scope (v1) / future ideas

- Direct k8s API client (skip the `kubectl` shellout).
- Forwards backed by raw pod selectors with label queries.
- Sharing forward configs across machines (iCloud sync, Git).
- Notifications when a forward dies.
- Floating "always on top" mini-window.
- Other resources: `deployments/`, `pods/`, headless services.
- Multiple local ports per forward (e.g. forward both 3000 and 9090 of the same service).
- "Profiles" / forward groups (e.g. "goldgard dev set" = 3 forwards started together).
- TouchBar / Stage Manager integration.

---

## 12. Open questions

1. **Login Item / launch at login**: register via `SMAppService.mainApp` automatically on first auto-start enable, or expose as separate Settings toggle? *Proposed: separate toggle in Settings, default off; explicit consent.*
2. **Telemetry**: any usage logging? *Proposed: none. Personal app.*
3. **Crash log handling**: enable macOS standard reporter only (`os_log`)?  *Proposed: yes — `os_log` for diagnostics, no remote upload.*
4. **Updates**: sparkle/auto-update? *Proposed: no — built locally, user pulls and rebuilds.*

---

## 13. Tech stack & project layout

Mirroring the most recent personal-app convention (Axon):

- macOS 14.0 deployment target, Xcode 16, Swift 6, `SWIFT_STRICT_CONCURRENCY: minimal`.
- SwiftUI + AppKit (`NSStatusItem` for menu bar; `MenuBarExtra` is acceptable for the dropdown but the icon-with-badge is easier with `NSStatusItem`).
- XcodeGen `project.yml` (no `.xcodeproj` in git).
- No code signing, `LSUIElement: true` (no Dock icon).
- Bundle id: `com.soif2sang.berth`.
- Layout:
  ```
  Berth/
    project.yml
    .gitignore
    README.md
    Berth/
      App/
        BerthApp.swift
        AppDelegate.swift
      Models/
        PortForward.swift
        KubeService.swift
        KubeContext.swift
        SessionState.swift
      Services/
        KubectlClient.swift
        ServiceCatalog.swift
        KubeContextLoader.swift
        PortForwardManager.swift
        PortForwardSession.swift
        LocalPortChecker.swift
        ZshrcImporter.swift
      State/
        AppState.swift
        ConfigStore.swift
      Views/
        MenuBarView.swift
        MainWindowView.swift
        SearchView.swift
        AddForwardSheet.swift
        ForwardsListView.swift
        ForwardDetailView.swift
        SettingsView.swift
      Resources/
        Info.plist
        Assets.xcassets/
    BerthTests/
      KubectlClientTests.swift
      ServiceCatalogTests.swift
      ZshrcImporterTests.swift
      PortForwardSessionTests.swift
  ```

---

## 14. Build sequence (informs the implementation plan, not part of the spec contract)

Rough order of work, smallest viable slice first:

1. Project skeleton (project.yml, BerthApp, empty AppState, empty MenuBarView).
2. `KubectlClient` — spawn + run-once + JSON decode. Unit-tested with a fake `kubectl` script in `BerthTests/Fixtures/`.
3. `KubeContextLoader` + `ServiceCatalog` — parallel fetch, fuzzy search.
4. `MainWindowView` + `SearchView` — see services, no forwarding yet.
5. `PortForwardSession` + `PortForwardManager` — actually spawn forwards, state machine, manual start/stop only.
6. `AddForwardSheet` + `ConfigStore` — persist saved forwards.
7. `MenuBarView` — full status icon + menu list.
8. `LocalPortChecker`, error states, `ForwardDetailView` (logs).
9. Auto-restart with backoff.
10. `ZshrcImporter` + first-run experience.
11. Auto-start at launch, Login Item registration.
12. Settings tab, polish, README.

---

*End of spec — ready for review before implementation.*
