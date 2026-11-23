# Graph Report - scratch-2026-11-22-0c997a  (2026-11-23)

## Corpus Check
- 6 files · ~7,151 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 1 file(s) not represented in the graph (top: (none) 1)

## Summary
- 168 nodes · 390 edges · 12 communities (10 shown, 2 thin omitted)
- Extraction: 93% EXTRACTED · 7% INFERRED · 0% AMBIGUOUS · INFERRED: 29 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `2635afc9`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- WinKomfort.swift
- Bool
- TaskModel
- String
- Cleaner
- KeyPanel
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

## Communities (12 total, 2 thin omitted)

### Community 0 - "WinKomfort.swift"
Cohesion: 0.10
Nodes (28): AppKit, Carbon.HIToolbox, ServiceManagement, SwiftUI, AppDelegate, apply(), AutostartView, .body (+20 more)

### Community 1 - "Bool"
Cohesion: 0.10
Nodes (9): afterTrust(), alert(), HotKey, StartKey, Store, .closeQuits, .login, .startMenu (+1 more)

### Community 2 - "TaskModel"
Cohesion: 0.18
Nodes (6): CloseWatcher, TaskModel, .background, .sorted, TaskRow, .body

### Community 4 - "String"
Cohesion: 0.16
Nodes (9): AppEntry, .file, .id, Release, Asset, StartModel, .results, UpdateError (+1 more)

### Community 5 - "Cleaner"
Cohesion: 0.33
Nodes (6): Candidate, .id, Cleaner, .body, Removed, .id

### Community 6 - "KeyPanel"
Cohesion: 0.35
Nodes (5): KeyPanel, .canBecomeKey, StartMenu, StartView, .body

### Community 8 - "sign.swift"
Cohesion: 0.29
Nodes (4): CryptoKit, Foundation, fail(), loadKey()

### Community 9 - "Autostarts"
Cohesion: 0.29
Nodes (6): AppCell, .body, Autostarts, HoverBox, LaunchItem, .id

### Community 10 - "WinKomfort"
Cohesion: 0.40
Nodes (4): Bauen / veröffentlichen, Installieren, Update-Sicherheit, WinKomfort

### Community 11 - "windows-features.sh"
Cohesion: 0.80
Nodes (4): an(), aus(), neustart(), windows-features.sh script

## Knowledge Gaps
- **11 isolated node(s):** `SwiftUI`, `AppKit`, `ServiceManagement`, `Carbon.HIToolbox`, `.login` (+6 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 40 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `CloseWatcher` connect `TaskModel` to `WinKomfort.swift`, `Bool`, `String`?**
  _High betweenness centrality (0.078) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `TaskModel` (e.g. with `.body` and `.body`) actually correct?**
  _`TaskModel` has 2 INFERRED edges - model-reasoned connections that need verification._
- **What connects `SwiftUI`, `AppKit`, `ServiceManagement` to the rest of the system?**
  _11 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `WinKomfort.swift` be split into smaller, more focused modules?**
  _Cohesion score 0.1006006006006006 - nodes in this community are weakly interconnected._
- **Why does `CryptoKit` connect `sign.swift` to `WinKomfort.swift`?**
  _High betweenness centrality (0.073) - this node is a cross-community bridge._
- **Should `Bool` be split into smaller, more focused modules?**
  _Cohesion score 0.1010752688172043 - nodes in this community are weakly interconnected._
- **Why does `TaskModel` connect `TaskModel` to `WinKomfort.swift`, `Autostarts`, `KeyPanel`?**
  _High betweenness centrality (0.056) - this node is a cross-community bridge._