# Graph Report - scratch-2026-11-22-0c997a  (2026-11-23)

## Corpus Check
- 11 files · ~21,905 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 2 file(s) not represented in the graph (top: (none) 1, .icns 1)

## Summary
- 497 nodes · 1235 edges · 23 communities (16 shown, 7 thin omitted)
- Extraction: 95% EXTRACTED · 5% INFERRED · 0% AMBIGUOUS · INFERRED: 63 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `4e454b40`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- WinKomfort.swift
- Bool
- TaskModel
- String
- ObservableObject
- ObservableObject
- KeyPanel
- ClipHistory
- Parser
- PinnedWindow
- WinKomfort
- windows-features.sh
- build.sh script
- TapDragLogic
- SearchField
- Pane
- HotAction
- .run

## God Nodes (most connected - your core abstractions)
1. `HotAction` - 30 edges
2. `Pane` - 25 edges
3. `PinnedWindow` - 24 edges
4. `KeyPanel` - 21 edges
5. `Notifs` - 19 edges
6. `WindowSwitcher` - 17 edges
7. `ClipHistory` - 17 edges
8. `sh()` - 16 edges
9. `Store` - 15 edges
10. `Animations` - 15 edges

## Surprising Connections (you probably didn't know these)
- `run()` --calls--> `TapDragLogic`  [INFERRED]
  Tests/main.swift → TapDragLogic.swift
- `TapDragFix` --calls--> `TapDragLogic`  [INFERRED]
  WinKomfort.swift → TapDragLogic.swift
- `HotAction` --references--> `Shortcut`  [EXTRACTED]
  WinKomfort.swift → Shortcut.swift
- `release.sh script` --calls--> `build.sh script`  [EXTRACTED]
  release.sh → build.sh

## Import Cycles
- None detected.

## Communities (23 total, 7 thin omitted)

### Community 0 - "WinKomfort.swift"
Cohesion: 0.08
Nodes (39): AppKit, Carbon.HIToolbox, IOKit.pwr_mgt, ScreenCaptureKit, ServiceManagement, SwiftUI, AnimationTab, .body (+31 more)

### Community 1 - "Bool"
Cohesion: 0.07
Nodes (19): afterTrust(), alert(), Animations, AnimSpeed, apply(), defaults(), DockReveal, Feature (+11 more)

### Community 2 - "TaskModel"
Cohesion: 0.21
Nodes (5): CloseWatcher, TaskModel, .background, .sorted, TaskRow

### Community 3 - "String"
Cohesion: 0.14
Nodes (9): NotifApp, .id, Notifs, Release, Asset, SettingsSwitches, SysSwitch, UIAuto (+1 more)

### Community 4 - "ObservableObject"
Cohesion: 0.12
Nodes (14): AppEntry, .file, .id, SearchHit, .id, Kind, app, calc (+6 more)

### Community 5 - "ObservableObject"
Cohesion: 0.12
Nodes (18): Autostarts, .body, Candidate, .id, Cleaner, .body, LaunchItem, .id (+10 more)

### Community 6 - "KeyPanel"
Cohesion: 0.08
Nodes (14): fixedHost(), KeyPanel, .canBecomeKey, newTextFile(), openTaskManager(), QuickNote, .text, SearchPanel (+6 more)

### Community 7 - "ClipHistory"
Cohesion: 0.13
Nodes (13): Awake, Mode, display, system, .status, ClipHistory, .enabled, ClipItem (+5 more)

### Community 8 - "Parser"
Cohesion: 0.18
Nodes (6): Calc, Parser, CryptoKit, Foundation, fail(), loadKey()

### Community 10 - "WinKomfort"
Cohesion: 0.40
Nodes (4): Bauen / testen / veröffentlichen, Installieren, Update-Sicherheit, WinKomfort

### Community 11 - "windows-features.sh"
Cohesion: 0.80
Nodes (4): an(), aus(), neustart(), windows-features.sh script

### Community 13 - "TapDragLogic"
Cohesion: 0.09
Nodes (15): CoreGraphics, Shortcut, .display, .isValid, TapDragLogic, Action, none, press (+7 more)

### Community 14 - "SearchField"
Cohesion: 0.12
Nodes (4): AppDelegate, SearchField, Coordinator, .body

### Community 18 - "Pane"
Cohesion: 0.08
Nodes (23): ClickView, openWelcome(), Pane, animations, autostarts, cleanup, finder, general (+15 more)

### Community 19 - "HotAction"
Cohesion: 0.10
Nodes (19): HotAction, clipboard, .current, .id, newFile, note, pin, search (+11 more)

### Community 20 - ".run"
Cohesion: 0.22
Nodes (6): SnapMath, Dir, left, max, right, Snap

## Knowledge Gaps
- **71 isolated node(s):** `left`, `right`, `max`, `SwiftUI`, `AppKit` (+66 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 127 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **7 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `HotAction` connect `HotAction` to `WinKomfort.swift`, `String`, `ObservableObject`, `KeyPanel`, `TapDragLogic`, `Pane`?**
  _High betweenness centrality (0.115) - this node is a cross-community bridge._
- **What connects `left`, `right`, `max` to the rest of the system?**
  _71 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `WinKomfort.swift` be split into smaller, more focused modules?**
  _Cohesion score 0.08305647840531562 - nodes in this community are weakly interconnected._
- **Why does `TapDragFix` connect `Bool` to `WinKomfort.swift`, `TapDragLogic`?**
  _High betweenness centrality (0.080) - this node is a cross-community bridge._
- **Should `Bool` be split into smaller, more focused modules?**
  _Cohesion score 0.07288135593220339 - nodes in this community are weakly interconnected._
- **Why does `PinnedWindow` connect `PinnedWindow` to `WinKomfort.swift`, `TaskModel`, `String`, `KeyPanel`, `SearchField`?**
  _High betweenness centrality (0.075) - this node is a cross-community bridge._
- **Should `String` be split into smaller, more focused modules?**
  _Cohesion score 0.14390243902439023 - nodes in this community are weakly interconnected._