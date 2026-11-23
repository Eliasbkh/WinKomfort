# Graph Report - scratch-2026-11-22-0c997a  (2026-11-23)

## Corpus Check
- 6 files · ~7,205 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 1 file(s) not represented in the graph (top: (none) 1)

## Summary
- 168 nodes · 395 edges · 13 communities (12 shown, 1 thin omitted)
- Extraction: 93% EXTRACTED · 7% INFERRED · 0% AMBIGUOUS · INFERRED: 29 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `d0563f96`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- WinKomfort.swift
- Bool
- TaskModel
- String
- StartModel
- Cleaner
- KeyPanel
- .start
- sign.swift
- Autostarts
- WinKomfort
- windows-features.sh
- build.sh script

## God Nodes (most connected - your core abstractions)
1. `TaskModel` - 17 edges
2. `Store` - 14 edges
3. `CloseWatcher` - 14 edges
4. `Cleaner` - 14 edges
5. `StartModel` - 12 edges
6. `sh()` - 11 edges
7. `AppEntry` - 11 edges
8. `Removed` - 11 edges
9. `TaskRow` - 10 edges
10. `Autostarts` - 10 edges

## Surprising Connections (you probably didn't know these)
- `release.sh script` --calls--> `build.sh script`  [EXTRACTED]
  release.sh → build.sh

## Import Cycles
- None detected.

## Communities (13 total, 1 thin omitted)

### Community 0 - "WinKomfort.swift"
Cohesion: 0.13
Nodes (22): AppKit, Carbon.HIToolbox, ServiceManagement, SwiftUI, afterTrust(), AutostartView, .body, CleanupView (+14 more)

### Community 1 - "Bool"
Cohesion: 0.11
Nodes (7): alert(), AppDelegate, HotKey, Store, .login, TapDragFix, Updater

### Community 2 - "TaskModel"
Cohesion: 0.15
Nodes (7): CloseWatcher, .closeQuits, TaskModel, .background, .sorted, TaskRow, .body

### Community 3 - "String"
Cohesion: 0.28
Nodes (9): apply(), defaults(), Feature, isOn(), Pref, Release, Asset, sh() (+1 more)

### Community 4 - "StartModel"
Cohesion: 0.22
Nodes (8): AppCell, .body, AppEntry, .file, .id, HoverBox, StartModel, .results

### Community 5 - "Cleaner"
Cohesion: 0.33
Nodes (6): Candidate, .id, Cleaner, .body, Removed, .id

### Community 6 - "KeyPanel"
Cohesion: 0.35
Nodes (5): KeyPanel, .canBecomeKey, StartMenu, StartView, .body

### Community 7 - ".start"
Cohesion: 0.31
Nodes (3): dbg(), StartKey, .startMenu

### Community 8 - "sign.swift"
Cohesion: 0.29
Nodes (4): CryptoKit, Foundation, fail(), loadKey()

### Community 9 - "Autostarts"
Cohesion: 0.60
Nodes (3): Autostarts, LaunchItem, .id

### Community 10 - "WinKomfort"
Cohesion: 0.40
Nodes (4): Bauen / veröffentlichen, Installieren, Update-Sicherheit, WinKomfort

### Community 11 - "windows-features.sh"
Cohesion: 0.80
Nodes (4): an(), aus(), neustart(), windows-features.sh script

## Knowledge Gaps
- **11 isolated node(s):** `SwiftUI`, `AppKit`, `ServiceManagement`, `Carbon.HIToolbox`, `.login` (+6 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 39 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **1 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `CloseWatcher` connect `TaskModel` to `WinKomfort.swift`, `String`?**
  _High betweenness centrality (0.079) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `TaskModel` (e.g. with `.body` and `.body`) actually correct?**
  _`TaskModel` has 2 INFERRED edges - model-reasoned connections that need verification._
- **What connects `SwiftUI`, `AppKit`, `ServiceManagement` to the rest of the system?**
  _11 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `WinKomfort.swift` be split into smaller, more focused modules?**
  _Cohesion score 0.12698412698412698 - nodes in this community are weakly interconnected._
- **Why does `CryptoKit` connect `sign.swift` to `WinKomfort.swift`?**
  _High betweenness centrality (0.074) - this node is a cross-community bridge._
- **Should `Bool` be split into smaller, more focused modules?**
  _Cohesion score 0.11384615384615385 - nodes in this community are weakly interconnected._
- **Why does `TaskModel` connect `TaskModel` to `WinKomfort.swift`, `StartModel`, `KeyPanel`?**
  _High betweenness centrality (0.057) - this node is a cross-community bridge._