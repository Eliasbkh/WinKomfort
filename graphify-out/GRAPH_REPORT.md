# Graph Report - scratch-2026-11-22-0c997a  (2026-11-23)

## Corpus Check
- 9 files · ~16,063 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 1 file(s) not represented in the graph (top: (none) 1)

## Summary
- 360 nodes · 889 edges · 18 communities (13 shown, 5 thin omitted)
- Extraction: 95% EXTRACTED · 5% INFERRED · 0% AMBIGUOUS · INFERRED: 42 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `439a6c2d`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- WinKomfort.swift
- Store
- TaskModel
- String
- ObservableObject
- Cleaner
- KeyPanel
- Awake
- Parser
- PinnedWindow
- WinKomfort
- windows-features.sh
- build.sh script
- TapDragLogic
- SearchField

## God Nodes (most connected - your core abstractions)
1. `PinnedWindow` - 24 edges
2. `Notifs` - 17 edges
3. `Store` - 16 edges
4. `KeyPanel` - 15 edges
5. `TaskModel` - 15 edges
6. `CloseWatcher` - 14 edges
7. `SearchModel` - 14 edges
8. `Cleaner` - 14 edges
9. `StartModel` - 13 edges
10. `Awake` - 13 edges

## Surprising Connections (you probably didn't know these)
- `run()` --calls--> `TapDragLogic`  [INFERRED]
  Tests/main.swift → TapDragLogic.swift
- `TapDragFix` --calls--> `TapDragLogic`  [INFERRED]
  WinKomfort.swift → TapDragLogic.swift
- `release.sh script` --calls--> `build.sh script`  [EXTRACTED]
  release.sh → build.sh

## Import Cycles
- None detected.

## Communities (18 total, 5 thin omitted)

### Community 0 - "WinKomfort.swift"
Cohesion: 0.07
Nodes (37): AppKit, Carbon.HIToolbox, IOKit.pwr_mgt, ScreenCaptureKit, ServiceManagement, SwiftUI, alert(), Autostarts (+29 more)

### Community 1 - "Store"
Cohesion: 0.14
Nodes (11): apply(), defaults(), Feature, FeatureTab, .body, HotKey, isOn(), Pref (+3 more)

### Community 2 - "TaskModel"
Cohesion: 0.17
Nodes (6): CloseWatcher, .closeQuits, TaskModel, .background, .sorted, TaskRow

### Community 3 - "String"
Cohesion: 0.21
Nodes (6): NotifApp, .id, Notifs, SettingsSwitches, SysSwitch, UIAuto

### Community 4 - "ObservableObject"
Cohesion: 0.11
Nodes (17): AppCell, .body, AppEntry, .file, .id, HoverBox, SearchHit, .id (+9 more)

### Community 5 - "Cleaner"
Cohesion: 0.19
Nodes (10): Candidate, .id, Cleaner, .body, LoginApp, .id, LoginItems, .removed (+2 more)

### Community 6 - "KeyPanel"
Cohesion: 0.11
Nodes (12): fixedHost(), KeyPanel, .canBecomeKey, QuickNote, .text, SearchPanel, SearchView, .body (+4 more)

### Community 7 - "Awake"
Cohesion: 0.08
Nodes (10): afterTrust(), Awake, Mode, display, system, .status, ClickView, DockReveal (+2 more)

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
Cohesion: 0.15
Nodes (10): TapDragLogic, Action, none, press, release, Point, calc(), check() (+2 more)

### Community 14 - "SearchField"
Cohesion: 0.12
Nodes (3): AppDelegate, SearchField, Coordinator

## Knowledge Gaps
- **31 isolated node(s):** `none`, `press`, `release`, `SwiftUI`, `AppKit` (+26 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 82 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **5 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `TapDragFix` connect `Store` to `WinKomfort.swift`, `TapDragLogic`, `Awake`?**
  _High betweenness centrality (0.114) - this node is a cross-community bridge._
- **What connects `none`, `press`, `release` to the rest of the system?**
  _31 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `WinKomfort.swift` be split into smaller, more focused modules?**
  _Cohesion score 0.06988120195667366 - nodes in this community are weakly interconnected._
- **Why does `PinnedWindow` connect `PinnedWindow` to `WinKomfort.swift`, `TaskModel`, `String`, `KeyPanel`, `SearchField`?**
  _High betweenness centrality (0.105) - this node is a cross-community bridge._
- **Should `Store` be split into smaller, more focused modules?**
  _Cohesion score 0.13846153846153847 - nodes in this community are weakly interconnected._
- **Why does `TapDragLogic` connect `TapDragLogic` to `Store`?**
  _High betweenness centrality (0.087) - this node is a cross-community bridge._
- **Should `ObservableObject` be split into smaller, more focused modules?**
  _Cohesion score 0.1103448275862069 - nodes in this community are weakly interconnected._