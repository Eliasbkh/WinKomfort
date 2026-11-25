# Graph Report - scratch-2026-11-22-0c997a  (2026-11-25)

## Corpus Check
- 232 files · ~134,324 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 7 file(s) not represented in the graph (top: (none) 3, .strings 2, .icns 1)

## Summary
- 4083 nodes · 9565 edges · 213 communities (123 shown, 90 thin omitted)
- Extraction: 94% EXTRACTED · 6% INFERRED · 0% AMBIGUOUS · INFERRED: 545 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `341b2e08`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- WinKomfort.swift
- Remote
- String
- QuickNote
- ObservableObject
- L
- Table
- AppUsage
- PinnedWindow
- WinKomfort
- windows-features.sh
- build.sh script
- Snippets
- SearchField
- CellId
- parser-utils/src/errors.rs
- HotAction
- .run
- RemoteChannel
- PropertyType
- NoteTagShape
- FileNodeData
- ObjectSpaceRef
- simple.rs
- Image
- .applicationDidFinishLaunching
- CompactId
- LayoutAlignment
- ExplorerModel
- ObjectType
- Guid
- SystemAction
- fsshttpb_onestore/object.rs
- MathNode
- page/note_tag.rs
- PropertySetId
- ParagraphStyling
- PropertyValue
- AIChat
- ExGuid
- LayoutAlignment
- InkStroke
- DiceModel
- RichText
- Buds
- NSObject
- wasm_driver.rs
- FileBlob
- FileNodeDataIterator
- Studio.swift
- ErrorKind
- FileNodeDataRef
- GridMouseView
- ParagraphStyling
- object_group.rs
- ClipHistory
- Parse
- Charset
- GameMode
- FileChunkReference
- fs_driver
- Result
- parser/src/lib.rs
- openExplorer
- View
- .reload
- Launcher
- PageSize
- ApiResult
- NoteTagIcon
- SPSession
- src/notebook.rs
- reader.rs
- WindowSwitcher
- one_store_file.rs
- renderer/src/lib.rs
- EmbeddedFile
- SearchSlash
- FileNodeDataIterator<'a>
- .handle
- OutlineElement
- FileApiDriverImpl
- Reader<'a>
- SearchModel
- .export
- objects/parse_context.rs
- StyleSet
- PropertySet
- node_functions.js
- FileApiDriverImpl
- inspect.rs
- parser-macros/src/lib.rs
- String
- MouseScroll
- Outline
- FileHandle
- Double
- TaskModel
- native_driver.rs
- remote-crypto.js
- Development requirements:
- Color
- ColorRef
- Repair
- SchoolLogic
- macros.rs
- .seek
- SketchTool
- KeyPanel
- SearchActions
- Pane
- Bool
- object_space_reference.rs
- ActionItemType
- Parser
- objects/object_space.rs
- Foundation
- Shortcut
- ink_stroke_node.rs
- DockModel
- parser
- embedded_ink_container.rs
- Problem
- .handle
- DebugOutput<'a>
- toc_container.rs
- ObjectHeader
- ClickView
- Section
- .fmt
- .perform
- objects/object.rs
- PDFQuality
- .openSelected
- Parser
- onenote/outline.rs
- DockIcon
- NSObject
- SlashLogic
- Kind
- WKWebView
- PageRenderer
- .startLid
- FileDataLoader
- templates/section.rs
- SearchView
- object_data_blob.rs
- CryptoKit
- Data
- Convert
- FolderSize
- log.rs
- BinaryItem
- String
- object_stream_header.rs
- .render
- derive_parse.rs

## God Nodes (most connected - your core abstractions)
1. `PropertyType` - 255 edges
2. `ExGuid` - 190 edges
3. `NoteTagShape` - 156 edges
4. `L()` - 150 edges
5. `Result` - 131 edges
6. `FileNodeData` - 90 edges
7. `ErrorKind` - 87 edges
8. `ExplorerModel` - 81 edges
9. `PropertySetId` - 66 edges
10. `MathNode` - 56 edges

## Surprising Connections (you probably didn't know these)
- `.title` --calls--> `L()`  [INFERRED]
  Launcher.swift → Explorer.swift
- `.title` --calls--> `L()`  [INFERRED]
  OneNoteCloud.swift → Explorer.swift
- `.placeholder` --calls--> `L()`  [INFERRED]
  Search.swift → Explorer.swift
- `.title` --calls--> `L()`  [INFERRED]
  Sketch.swift → Explorer.swift
- `.body` --calls--> `L()`  [INFERRED]
  WinKomfort.swift → Explorer.swift

## Import Cycles
- 1-file cycle: `onenote/parser-utils/src/file_api/mod.rs -> onenote/parser-utils/src/file_api/mod.rs`
- 1-file cycle: `onenote/parser/src/shared/property.rs -> onenote/parser/src/shared/property.rs`
- 1-file cycle: `onenote/parser/src/local_onestore/one_store_file.rs -> onenote/parser/src/local_onestore/one_store_file.rs`
- 1-file cycle: `onenote/parser/src/shared/guid.rs -> onenote/parser/src/shared/guid.rs`
- 1-file cycle: `onenote/renderer/src/utils.rs -> onenote/renderer/src/utils.rs`
- 1-file cycle: `onenote/parser/src/shared/compact_u64.rs -> onenote/parser/src/shared/compact_u64.rs`
- 2-file cycle: `onenote/renderer/src/notebook.rs -> onenote/renderer/src/templates/notebook.rs -> onenote/renderer/src/notebook.rs`
- 2-file cycle: `onenote/parser/src/onenote/rich_text.rs -> onenote/parser/src/onenote/text_region.rs -> onenote/parser/src/onenote/rich_text.rs`
- 2-file cycle: `onenote/parser/src/shared/prop_set.rs -> onenote/parser/src/shared/property.rs -> onenote/parser/src/shared/prop_set.rs`
- 2-file cycle: `onenote/parser/src/local_onestore/one_store_file.rs -> onenote/parser/src/onestore/mod.rs -> onenote/parser/src/local_onestore/one_store_file.rs`
- 2-file cycle: `onenote/parser/src/fsshttpb/data_element/mod.rs -> onenote/parser/src/fsshttpb/data_element/storage_manifest.rs -> onenote/parser/src/fsshttpb/data_element/mod.rs`
- 2-file cycle: `onenote/parser/src/fsshttpb/data_element/mod.rs -> onenote/parser/src/fsshttpb/data_element/object_group.rs -> onenote/parser/src/fsshttpb/data_element/mod.rs`
- 2-file cycle: `onenote/parser/src/fsshttpb/data_element/mod.rs -> onenote/parser/src/fsshttpb/data_element/revision_manifest.rs -> onenote/parser/src/fsshttpb/data_element/mod.rs`
- 2-file cycle: `onenote/parser/src/fsshttpb/data_element/mod.rs -> onenote/parser/src/fsshttpb/data_element/storage_index.rs -> onenote/parser/src/fsshttpb/data_element/mod.rs`
- 2-file cycle: `onenote/parser/src/fsshttpb/data_element/mod.rs -> onenote/parser/src/fsshttpb/data_element/object_data_blob.rs -> onenote/parser/src/fsshttpb/data_element/mod.rs`
- 2-file cycle: `onenote/parser/src/local_onestore/file_node/file_node.rs -> onenote/parser/src/local_onestore/file_structure/file_node_list.rs -> onenote/parser/src/local_onestore/file_node/file_node.rs`
- 2-file cycle: `onenote/parser/src/fsshttpb/data_element/data_element_fragment.rs -> onenote/parser/src/fsshttpb/data_element/mod.rs -> onenote/parser/src/fsshttpb/data_element/data_element_fragment.rs`
- 3-file cycle: `onenote/parser/src/local_onestore/file_node/file_node.rs -> onenote/parser/src/local_onestore/file_structure/file_node_list.rs -> onenote/parser/src/local_onestore/file_structure/file_node_list_fragment.rs -> onenote/parser/src/local_onestore/file_node/file_node.rs`
- 3-file cycle: `onenote/parser/src/onenote/content.rs -> onenote/parser/src/onenote/table.rs -> onenote/parser/src/onenote/outline.rs -> onenote/parser/src/onenote/content.rs`

## Communities (213 total, 90 thin omitted)

### Community 0 - "WinKomfort.swift"
Cohesion: 0.06
Nodes (52): ExplorerTab, IOKit.pwr_mgt, MouseSettings, .body, PDFKit, BudsMenu, .body, .title (+44 more)

### Community 1 - "Remote"
Cohesion: 0.06
Nodes (16): CoreImage.CIFilterBuiltins, Network, Remote, .pos, State, asking, connected, off (+8 more)

### Community 3 - "String"
Cohesion: 0.13
Nodes (12): OneNotePDF, Failure, Scope, notebook, page, section, Release, Asset (+4 more)

### Community 4 - "QuickNote"
Cohesion: 0.20
Nodes (6): QuickNote, .current, .notes, .text, QuickNoteView, .body

### Community 5 - "ObservableObject"
Cohesion: 0.14
Nodes (16): Autostarts, .body, Candidate, .id, Cleaner, .body, LaunchItem, .id (+8 more)

### Community 6 - "L"
Cohesion: 0.09
Nodes (15): AIView, .body, Assistant, .available, SiriSection, .body, SiriShortcuts, Item (+7 more)

### Community 7 - "Table"
Cohesion: 0.12
Nodes (6): Table, Table, TableCell, TableRow, calc_locked_cols(), Renderer<'a>

### Community 8 - "AppUsage"
Cohesion: 0.11
Nodes (8): AppUsage, Use, SearchRank, AppEntry, .file, .id, StartModel, .results

### Community 9 - "PinnedWindow"
Cohesion: 0.10
Nodes (4): CloseWatcher, PinnedWindow, Pins, .closeQuits

### Community 10 - "WinKomfort"
Cohesion: 0.40
Nodes (4): Bauen / testen / veröffentlichen, Installieren, Update-Sicherheit, WinKomfort

### Community 11 - "windows-features.sh"
Cohesion: 0.80
Nodes (4): an(), aus(), neustart(), windows-features.sh script

### Community 13 - "Snippets"
Cohesion: 0.17
Nodes (5): Snippet, Snippets, SnippetsSection, .body, SnippetStore

### Community 16 - "CellId"
Cohesion: 0.12
Nodes (13): find_data_root_cell_id(), find_header_cell_id(), FssHttpbOneStore, parse_object_space(), parse_store(), OneStorePackaging, Revision, RevisionRole (+5 more)

### Community 17 - "parser-utils/src/errors.rs"
Cohesion: 0.25
Nodes (4): Result, Reader, &[u8], Utf16ToString

### Community 19 - "HotAction"
Cohesion: 0.08
Nodes (23): HotAction, aiText, ask, clipboard, .current, explorer, gameMode, .id (+15 more)

### Community 20 - ".run"
Cohesion: 0.19
Nodes (7): CoreGraphics, SnapMath, Dir, left, max, right, Snap

### Community 22 - "PropertyType"
Cohesion: 0.01
Nodes (177): PropertyType, ActionItemSchemaVersion, ActionItemStatus, ActionItemType, Author, AuthorMostRecent, AuthorOriginal, BodyTextAlignment (+169 more)

### Community 23 - "NoteTagShape"
Cohesion: 0.01
Nodes (145): NoteTagShape, AwardRibbon, Binoculars, BlankPaperWithLines, BlueCheckBox, BlueCheckBox1, BlueCheckBox2, BlueCheckBox3 (+137 more)

### Community 24 - "FileNodeData"
Cohesion: 0.04
Nodes (84): DataSignatureGroupDefinitionFND, FileDataStoreListReferenceFND, FileDataStoreObject, FileDataStoreObjectReferenceFND, FileNodeData, ChunkTerminatorFND, DataSignatureGroupDefinitionFND, FileDataStoreListReferenceFND (+76 more)

### Community 25 - "ObjectSpaceRef"
Cohesion: 0.09
Nodes (34): parse_content(), parse_embedded_file(), parse_iframe(), parse_image(), Ink, InkBoundingBox, InkContent, InkGroup (+26 more)

### Community 26 - "simple.rs"
Cohesion: 0.10
Nodes (28): Author, InkDimension, parse(), Data, parse(), parse(), parse(), parse() (+20 more)

### Community 27 - "Image"
Cohesion: 0.06
Nodes (6): IFrame, Image, NoteTag, read_file_start(), Renderer<'a>, detect_png()

### Community 28 - ".applicationDidFinishLaunching"
Cohesion: 0.13
Nodes (11): Animations, AnimSpeed, apply(), defaults(), Feature, FinderCut, isOn(), Pref (+3 more)

### Community 29 - "CompactId"
Cohesion: 0.04
Nodes (20): MappingTable, ObjectDeclarationWithRefCountBody, HashedChunkDescriptor, ObjectDeclaration2Body, ObjectDeclaration2RefCount, ObjectDeclaration2RefCount<RefSize>, ObjectDeclarationFileDataRefCount, ObjectDeclarationFileDataRefCount<RefSize> (+12 more)

### Community 30 - "LayoutAlignment"
Cohesion: 0.09
Nodes (16): HorizontalAlignment, BiDiNormal, BiDiReverse, Center, Left, Right, Unknown, HorizontalAlignmentMargin (+8 more)

### Community 31 - "ExplorerModel"
Cohesion: 0.06
Nodes (19): BatchRenameSheet, .body, Box, .old, ExplorerModel, .crumbs, .folderSizes, .query (+11 more)

### Community 32 - "ObjectType"
Cohesion: 0.07
Nodes (24): ObjectType, CellManifest, DataElement, DataElementFragment, DataElementPackage, ObjectDataBlob, ObjectGroupBlobReference, ObjectGroupData (+16 more)

### Community 33 - "Guid"
Cohesion: 0.05
Nodes (16): StoreHeader, IdMapping, Data, parse(), Data, Data, parse(), Data (+8 more)

### Community 34 - "SystemAction"
Cohesion: 0.06
Nodes (28): SystemAction, appWindows, cleaning, closeWindow, dark, displayOff, fullscreen, hide (+20 more)

### Community 35 - "fsshttpb_onestore/object.rs"
Cohesion: 0.26
Nodes (7): Object, Partition, FileData, Metadata, ObjectData, SharedObject, GroupData

### Community 36 - "MathNode"
Cohesion: 0.09
Nodes (22): MathExpr, Tok, cmd, num, sym, word, MathNode, accent (+14 more)

### Community 37 - "page/note_tag.rs"
Cohesion: 0.05
Nodes (37): COLOR_BLUE, COLOR_GREEN, COLOR_RED, COLOR_YELLOW, ICON_ARROW_RIGHT, ICON_AWARD, ICON_BOOK, ICON_BUBBLE (+29 more)

### Community 38 - "PropertySetId"
Cohesion: 0.05
Nodes (37): PropertySetId, AuthorContainer, EmbeddedFileContainer, EmbeddedFileNode, IFrameNode, ImageNode, InkContainer, InkDataNode (+29 more)

### Community 39 - "ParagraphStyling"
Cohesion: 0.21
Nodes (4): Hyperlink, MathExpression, TextRegion, TextRegionParser

### Community 40 - "PropertyValue"
Cohesion: 0.08
Nodes (17): PropertyValue, Bool, ContextId, ContextIds, Empty, ObjectId, ObjectIds, ObjectSpaceId (+9 more)

### Community 41 - "AIChat"
Cohesion: 0.11
Nodes (8): AI, .vision, AIChat, .answer, Message, Selection, AILogic, AITask

### Community 42 - "ExGuid"
Cohesion: 0.05
Nodes (29): DataElement, DataElement, DataElementFragment, DataElementFragmentChunkReference, DataElement, DataElementPackage, DebugSize, ObjectGroup (+21 more)

### Community 43 - "LayoutAlignment"
Cohesion: 0.06
Nodes (22): LayoutAlignment, ObjectReference, OutlineIndentDistance, Data, Data, Data, parse(), Data (+14 more)

### Community 44 - "InkStroke"
Cohesion: 0.12
Nodes (9): InkPoint, InkStroke, get_boundary(), InkBuilder, .SVG_SCALING_FACTOR, InkPart, round_svg_value(), round_svg_vec() (+1 more)

### Community 45 - "DiceModel"
Cohesion: 0.10
Nodes (11): CoinModel, CoinView, .body, DiceModel, DiceView, .body, WheelModel, WheelView (+3 more)

### Community 46 - "RichText"
Cohesion: 0.09
Nodes (10): EmbeddedInkSpace, EmbeddedObject, Ink, InkLineBreak, InkSpace, RichText, fix_newlines(), font_with_fallback() (+2 more)

### Community 47 - "Buds"
Cohesion: 0.08
Nodes (9): Buds, .enabled, BudsMic, BudsProtocol, BudsStatus, CoreAudio, CoreBluetooth, IOBluetooth (+1 more)

### Community 48 - "NSObject"
Cohesion: 0.17
Nodes (4): .body, openExplorer(), FolderHandler, Reveal

### Community 49 - "wasm_driver.rs"
Cohesion: 0.13
Nodes (19): append_file(), close(), exists(), get_dir_name(), get_file_extension(), get_file_name(), get_output_path(), is_directory() (+11 more)

### Community 50 - "FileBlob"
Cohesion: 0.19
Nodes (3): Data, parse(), FileBlob

### Community 51 - "FileNodeDataIterator"
Cohesion: 0.10
Nodes (9): FileNodeDataIterator, GlobalIdTable, IdReferenceMapping, ObjectGroupList, Revision, RootRole, DefaultContent, MetadataRoot (+1 more)

### Community 52 - "Studio.swift"
Cohesion: 0.10
Nodes (22): Charts, ChartKind, bar, line, pie, ChartView, .body, P (+14 more)

### Community 53 - "ErrorKind"
Cohesion: 0.10
Nodes (22): Error, ErrorKind, InvalidUuid, IO, MalformedData, MalformedFssHttpBData, MalformedOneNoteData, MalformedOneNoteFileData (+14 more)

### Community 54 - "FileNodeDataRef"
Cohesion: 0.18
Nodes (7): FileNodeDataRef, ElementList, InvalidData, NoData, SingleElement, HashedChunkDescriptor<Hash>, read_property_set()

### Community 55 - "GridMouseView"
Cohesion: 0.10
Nodes (5): FileDrag, GridMouse, GridMouseView, .isFlipped, TileFrames

### Community 56 - "ParagraphStyling"
Cohesion: 0.08
Nodes (6): ParagraphAlignment, Center, Left, Right, Unknown, ParagraphStyling

### Community 57 - "object_group.rs"
Cohesion: 0.22
Nodes (8): DataElement, ObjectChangeFrequency, Custom, Frequent, Independent, Infrequent, Unknown, ObjectGroupMetadata

### Community 58 - "ClipHistory"
Cohesion: 0.11
Nodes (12): Awake, .lidActive, Mode, display, system, .ruleInstalled, .sleepDisabled, .status (+4 more)

### Community 59 - "Parse"
Cohesion: 0.11
Nodes (11): ObjectSpaceObjectStreamHeader, OneStoreFormatGuid, OneStoreHeader, RgbReserved, f32, Parse, u128, u16 (+3 more)

### Community 60 - "Charset"
Cohesion: 0.09
Nodes (20): Charset, Ansi, Arabic, Baltic, ChineseBig5, Default, EastEurope, Gb2312 (+12 more)

### Community 61 - "GameMode"
Cohesion: 0.15
Nodes (6): GameMode, .auto, .dnd, .extraGames, .hideDock, .throttle

### Community 62 - "FileChunkReference"
Cohesion: 0.08
Nodes (4): FileChunkReference, FileChunkReference32, FileChunkReference64, FileNodeChunkReference

### Community 63 - "fs_driver"
Cohesion: 0.31
Nodes (4): fs_driver(), ERRORS_NOTE_NAME, RenderedSection, Renderer

### Community 64 - "Result"
Cohesion: 0.05
Nodes (11): References, CompactU64, (), Error, ErrorKind, IoError, OnePkgImportFailure, OtherError (+3 more)

### Community 65 - "parser/src/lib.rs"
Cohesion: 0.16
Nodes (8): Parser, Notebook, Section, SectionEntry, Section, SectionGroup, SectionGroup, parse_onestore()

### Community 66 - "openExplorer"
Cohesion: 0.17
Nodes (4): ExplorerWindow, .gridWidth, QLSource, v

### Community 67 - "View"
Cohesion: 0.16
Nodes (14): .cards, ExplorerView, .content, .dolphin, .gnome, .gridView, .searchField, .searching (+6 more)

### Community 68 - ".reload"
Cohesion: 0.17
Nodes (9): .showHidden, ExplorerStyle, .current, dolphin, gnome, .hint, .id, .title (+1 more)

### Community 69 - "Launcher"
Cohesion: 0.08
Nodes (20): Launcher, .keys, LauncherSection, .body, LaunchKey, LaunchKind, action, app (+12 more)

### Community 70 - "PageSize"
Cohesion: 0.11
Nodes (17): PageSize, AnsiLetter, AnsiTabloid, Auto, Billfold, Custom, IndexCard, IsoA3 (+9 more)

### Community 72 - "NoteTagIcon"
Cohesion: 0.19
Nodes (6): ActionItemStatus, IconSize, Large, Normal, NoteTagIcon, Renderer<'a>

### Community 74 - "src/notebook.rs"
Cohesion: 0.15
Nodes (8): prepare_color(), RgbColor, NotebookTemplate, render(), Section, Toc, Section, SectionGroup

### Community 75 - "reader.rs"
Cohesion: 0.17
Nodes (9): Reader, ReaderData, BufferRef, File, ReaderDataRef, FilePointer, Vec, ReaderFileHandle (+1 more)

### Community 76 - "WindowSwitcher"
Cohesion: 0.09
Nodes (7): afterTrust(), MenuTarget, StartKey, .startMenu, SwitchWin, TapDragFix, WindowSwitcher

### Community 77 - "one_store_file.rs"
Cohesion: 0.05
Nodes (17): FileChunkReference64x32, FileNode, FileNodeList, FileNodeListBuilder, FileNodeListFragment, FileNodeListHeader, FreeChunkListFragment, ParseContext (+9 more)

### Community 78 - "renderer/src/lib.rs"
Cohesion: 0.29
Nodes (4): convert(), convert_onepkg(), _main(), oneNoteConverter()

### Community 79 - "EmbeddedFile"
Cohesion: 0.06
Nodes (18): FileType, Audio, Unknown, Video, Content, EmbeddedFile, Image, Ink (+10 more)

### Community 80 - "SearchSlash"
Cohesion: 0.17
Nodes (7): SearchSlash, Act, copy, run, .clip, Command, Row

### Community 83 - ".handle"
Cohesion: 0.11
Nodes (4): CleaningMode, InputExtras, Tools, Vision

### Community 84 - "OutlineElement"
Cohesion: 0.09
Nodes (10): List, OutlineElement, OutlineGroup, OutlineItem, Element, Group, Renderer<'a>, flatten_outline_items() (+2 more)

### Community 85 - "FileApiDriverImpl"
Cohesion: 0.18
Nodes (3): FileApiDriverImpl, handle_error(), is_windows()

### Community 86 - "Reader<'a>"
Cohesion: 0.19
Nodes (3): try_get!, Reader<'a>, ReaderOffset

### Community 87 - "SearchModel"
Cohesion: 0.19
Nodes (14): Carbon.HIToolbox, QRView, SearchAction, .id, SearchHit, .id, SearchModel, .actions (+6 more)

### Community 89 - "objects/parse_context.rs"
Cohesion: 0.08
Nodes (11): AttachmentInfo, FileData, File, FileDataStore, GlobalFileData, ParseContext, ParseContextIdMapping, UnresolvedFileData (+3 more)

### Community 90 - "StyleSet"
Cohesion: 0.06
Nodes (15): Renderer<'a>, Renderer, Renderer<'a>, PageTemplate, PageTimestamps, render(), AttributeSet, html_entities() (+7 more)

### Community 91 - "PropertySet"
Cohesion: 0.11
Nodes (3): text_region_to_latex(), PropertySet, PropertyId

### Community 92 - "node_functions.js"
Cohesion: 0.14
Nodes (3): fs, mkdirSyncRecursive(), path

### Community 94 - "inspect.rs"
Cohesion: 0.23
Nodes (8): Config, ConfigParseError, handle_parse_error(), main(), OutputMode, FileContent, Section, print_help_text()

### Community 96 - "String"
Cohesion: 0.14
Nodes (13): .infoPanel, FileIcon, .body, .key, .thumb, IconCache, RenameSheet, .body (+5 more)

### Community 97 - "MouseScroll"
Cohesion: 0.16
Nodes (8): AppKit, CoreServices, FoundationModels, MouseScroll, .needed, .reverse, .speed, SwiftUI

### Community 99 - "Outline"
Cohesion: 0.06
Nodes (5): Outline, Outline, Page, PageSeries, Title

### Community 100 - "FileHandle"
Cohesion: 0.20
Nodes (3): FileHandle, BufReader<fs::File>, BufReader<SeekableFileHandle>

### Community 101 - "Double"
Cohesion: 0.12
Nodes (19): Double, .nonZero, TapDragLogic, Action, none, press, release, Point (+11 more)

### Community 102 - "TaskModel"
Cohesion: 0.06
Nodes (28): Darwin, SystemMonitor, .enabled, Audio, AutoQuit, .kept, .minutes, MemoryInfo (+20 more)

### Community 104 - "remote-crypto.js"
Cohesion: 0.40
Nodes (6): cat(), chacha(), Channel, hmac(), K256, sha256()

### Community 105 - "Development requirements:"
Cohesion: 0.17
Nodes (11): Building, Debugging tests, Developing, Development requirements:, How the OneNote Importer Process Works, Inspecting `.one` files, OneNote Converter, Project structure: (+3 more)

### Community 107 - "ColorRef"
Cohesion: 0.09
Nodes (7): ColorRef, Auto, Manual, NoteTagPropertyStatus, Data, parse(), NoteTagDefinition

### Community 108 - "Repair"
Cohesion: 0.20
Nodes (7): Repair, Check, RepairModel, RepairSection, .body, SMAppServiceStatusIsEnabled(), ServiceManagement

### Community 109 - "SchoolLogic"
Cohesion: 0.14
Nodes (13): SchoolLogic, Bool3, and, const, eq, imp, not, or (+5 more)

### Community 110 - "macros.rs"
Cohesion: 0.28
Nodes (8): exguid!, guid!, iterator_skip_if_matching!, onestore_parse_error!, parser_error!, unexpected_object_type_error!, parse_exguid(), parse_guid()

### Community 112 - "SketchTool"
Cohesion: 0.11
Nodes (16): SketchCanvas, .body, SketchModel, SketchStroke, SketchTool, arrow, eraser, line (+8 more)

### Community 113 - "KeyPanel"
Cohesion: 0.17
Nodes (9): AskModel, AskPanel, AskView, .body, fixedHost(), KeyPanel, .canBecomeKey, StartMenu (+1 more)

### Community 114 - "SearchActions"
Cohesion: 0.19
Nodes (5): SearchActions, .entries, Entry, .suggested, SearchTimer

### Community 115 - "Pane"
Cohesion: 0.10
Nodes (21): Pane, animations, autostarts, cleanup, desktop, explorer, finder, gamemode (+13 more)

### Community 116 - "Bool"
Cohesion: 0.22
Nodes (9): alert(), .body, .body, NotifApp, .id, .body, Notifs, tr() (+1 more)

### Community 118 - "ActionItemType"
Cohesion: 0.20
Nodes (9): ActionItemType, CustomDueDate, DueNextWeek, DueThisWeek, DueToday, DueTomorrow, NoDueDate, Numeric (+1 more)

### Community 119 - "Parser"
Cohesion: 0.24
Nodes (4): Parser, .closing, .peek, .starts

### Community 120 - "objects/object_space.rs"
Cohesion: 0.19
Nodes (3): ExportedObject, ObjectSpace, RevisionManifestList

### Community 121 - "Foundation"
Cohesion: 0.13
Nodes (4): Emoji, Foundation, OneNoteOrder, TimeParse

### Community 122 - "Shortcut"
Cohesion: 0.36
Nodes (3): Shortcut, .display, .isValid

### Community 123 - "ink_stroke_node.rs"
Cohesion: 0.26
Nodes (9): Data, InkBias, Both, Drawing, Handwriting, parse(), decode(), decode_signed() (+1 more)

### Community 124 - "DockModel"
Cohesion: 0.17
Nodes (4): DockModel, DockSettings, .body, DockReveal

### Community 125 - "parser"
Cohesion: 0.60
Nodes (5): onenote-html, parser, parser-macros, parser-utils, renderer

### Community 127 - "Problem"
Cohesion: 0.15
Nodes (11): .new, .problem, RenameLogic, Mode, number, replace, Problem, empty (+3 more)

### Community 130 - "toc_container.rs"
Cohesion: 0.48
Nodes (4): Data, parse(), parse_toc(), parse_toc_entry()

### Community 132 - "ClickView"
Cohesion: 0.24
Nodes (3): ClickView, ClipPanel, .body

### Community 133 - "Section"
Cohesion: 0.27
Nodes (7): Data, parse(), parse_page_series(), parse_content(), parse_metadata(), parse_section(), OneStore

### Community 147 - "PDFQuality"
Cohesion: 0.17
Nodes (11): ImageIO, PDFQuality, balanced, compact, .current, high, .id, .jpeg (+3 more)

### Community 161 - ".openSelected"
Cohesion: 0.23
Nodes (5): Mode, clip, emoji, root, .body

### Community 171 - "onenote/outline.rs"
Cohesion: 0.24
Nodes (8): Data, parse(), Data, parse(), parse_list(), parse_outline_element(), parse_outline_group(), parse_outline_item()

### Community 173 - "DockIcon"
Cohesion: 0.18
Nodes (3): DockIcon, .appWindows, AppDelegate

### Community 179 - "Kind"
Cohesion: 0.18
Nodes (11): Kind, action, ai, app, calc, clip, emoji, file (+3 more)

### Community 180 - "WKWebView"
Cohesion: 0.29
Nodes (3): MathPreview, PassWeb, .acceptsFirstResponder

### Community 183 - "FileDataLoader"
Cohesion: 0.28
Nodes (3): FileDataLoader, ReaderDataRef, Vec<u8>

### Community 184 - "templates/section.rs"
Cohesion: 0.31
Nodes (5): ErrorPageTemplate, render(), NotebookTemplate, render(), TocEntry

### Community 185 - "SearchView"
Cohesion: 0.31
Nodes (3): SearchView, .footer, .list

### Community 187 - "CryptoKit"
Cohesion: 0.33
Nodes (3): CryptoKit, fail(), loadKey()

### Community 192 - "log.rs"
Cohesion: 0.33
Nodes (3): log!, log_warn!, set_current_page()

## Knowledge Gaps
- **795 isolated node(s):** `.vision`, `Quartz`, `QuickLookThumbnailing`, `gnome`, `dolphin` (+790 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 1415 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **90 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `L()` connect `L` to `.handle`, `WinKomfort.swift`, `Remote`, `String`, `QuickNote`, `AppUsage`, `PinnedWindow`, `Snippets`, `PDFQuality`, `ExplorerModel`, `.openSelected`, `SystemAction`, `AIChat`, `DiceModel`, `Buds`, `NSObject`, `Studio.swift`, `PageRenderer`, `.startLid`, `SearchView`, `ClipHistory`, `GameMode`, `String`, `View`, `.reload`, `Launcher`, `SearchSlash`, `.handle`, `SearchModel`, `.export`, `String`, `TaskModel`, `Repair`, `SchoolLogic`, `SketchTool`, `KeyPanel`, `SearchActions`, `DockModel`, `Problem`?**
  _High betweenness centrality (0.241) - this node is a cross-community bridge._
- **Are the 118 inferred relationships involving `L()` (e.g. with `.chat()` and `.file()`) actually correct?**
  _`L()` has 118 INFERRED edges - model-reasoned connections that need verification._
- **What connects `.vision`, `Quartz`, `QuickLookThumbnailing` to the rest of the system?**
  _795 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `WinKomfort.swift` be split into smaller, more focused modules?**
  _Cohesion score 0.06246799795186892 - nodes in this community are weakly interconnected._
- **Why does `Result` connect `Result` to `toc_container.rs`, `Section`, `Table`, `CellId`, `objects/object.rs`, `FileNodeData`, `ObjectSpaceRef`, `simple.rs`, `Image`, `CompactId`, `LayoutAlignment`, `Guid`, `fsshttpb_onestore/object.rs`, `PropertySetId`, `ExGuid`, `LayoutAlignment`, `onenote/outline.rs`, `RichText`, `FileBlob`, `FileNodeDataIterator`, `templates/section.rs`, `object_data_blob.rs`, `Parse`, `FileChunkReference`, `stream_object.rs`, `fs_driver`, `parser/src/lib.rs`, `object_stream_header.rs`, `src/notebook.rs`, `one_store_file.rs`, `renderer/src/lib.rs`, `EmbeddedFile`, `OutlineElement`, `objects/parse_context.rs`, `StyleSet`, `PropertySet`, `ColorRef`, `objects/object_space.rs`, `ink_stroke_node.rs`?**
  _High betweenness centrality (0.189) - this node is a cross-community bridge._
- **Should `Remote` be split into smaller, more focused modules?**
  _Cohesion score 0.05824561403508772 - nodes in this community are weakly interconnected._
- **Why does `SPSession` connect `SPSession` to `Remote`, `String`, `NSObject`, `PDFQuality`, `WKWebView`, `PageRenderer`, `.export`?**
  _High betweenness centrality (0.167) - this node is a cross-community bridge._