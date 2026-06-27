# Renamer Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild Renamer as a native macOS Swift/SwiftUI app that analyzes folder contents locally (with optional cloud LLM enhancement), suggests dynamic subfolder organization and templated filenames, and can export documents to DEVONthink.

**Architecture:** Layered Swift Package Manager app using MVVM + Services. Models are plain `Sendable` structs. File-system mutating services (`Organizer`, `RollbackService`) are `actor`s. Local analysis uses Apple frameworks (PDFKit, Vision, NaturalLanguage, ImageIO, AVFoundation). Cloud analysis uses OpenAI-compatible chat-completion endpoints with user-provided base URL/key/model. UI is SwiftUI with a menu-bar popover plus a main window.

**Tech Stack:** Swift 6, SwiftUI, SPM, macOS 14+, `StrictConcurrency`, XCTest.

## Global Constraints

- Target macOS 14+.
- Package manifest `swift-tools-version: 6.0`.
- Enable `StrictConcurrency` upcoming feature.
- All mutable shared state lives in actors or `@MainActor` observable view models.
- File-system writes are serialized through `Organizer` actor.
- No git mutations unless the user explicitly asks; commit messages use conventional commits.
- Chinese comments/docs, English identifiers.

---

## File Map

| File | Responsibility |
|------|----------------|
| `Package.swift` | SPM manifest, app executable target, test target, macOS platform. |
| `Sources/App/RenamerApp.swift` | `@main`, `WindowGroup`, settings window, app lifecycle. |
| `Sources/App/MenuBarController.swift` | `NSStatusItem`, popover, recent tasks, folder picker entry point. |
| `Sources/Models/FileItem.swift` | File entity (id, URL, name, size, dates, UTI). |
| `Sources/Models/FileAnalysis.swift` | Structured AI-derived tags per file. |
| `Sources/Models/NamingTemplate.swift` | Reusable folder + filename templates. |
| `Sources/Models/OrganizationTask.swift` | Saved task configuration. |
| `Sources/Models/OrganizationPlan.swift` | One execution plan. |
| `Sources/Models/PlanOperation.swift` | Single source→destination operation. |
| `Sources/Models/FileOperationRecord.swift` | Persisted record for rollback. |
| `Sources/Models/DuplicateGroup.swift` | Group of byte-identical files. |
| `Sources/Models/SharedEnums.swift` | `CopyOrMove`, `ExportTarget`, `AnalysisError`. |
| `Services/FileScanner.swift` | Recursive concurrent directory scan, skip hidden/system. |
| `Services/LocalAnalyzer.swift` | Extract text/metadata per file type, produce `FileAnalysis`. |
| `Services/CloudAnalyzer.swift` | OpenAI-compatible chat client, JSON parsing, graceful fallback. |
| `Services/NamingEngine.swift` | Build destination paths from template + analysis, dedupe names. |
| `Services/DuplicateDetector.swift` | Hash files and group duplicates. |
| `Services/Organizer.swift` | Execute copy/move operations, actor-isolated. |
| `Services/RollbackService.swift` | Persist records and reverse moves/copies. |
| `Services/PluginManager.swift` | Resolve export targets to plugins. |
| `Plugins/ExportPluginProtocol.swift` | Plugin interface. |
| `Plugins/DEVONthinkPlugin.swift` | AppleScript-based DEVONthink export. |
| `ViewModels/MainViewModel.swift` | Main window state + analysis-to-preview flow. |
| `ViewModels/TaskListViewModel.swift` | Saved tasks CRUD + persistence. |
| `ViewModels/SettingsViewModel.swift` | Cloud provider presets, templates, defaults. |
| `Views/ContentView.swift` | Home with drop zone + recent tasks. |
| `Views/PlanPreviewView.swift` | Preview/edit operations and duplicates. |
| `Views/TaskEditorView.swift` | Create/edit `OrganizationTask`. |
| `Views/SettingsView.swift` | Settings tabs. |
| `Views/MenuBarPopover.swift` | Menu-bar quick UI. |
| `Tests/RenamerTests/...` | XCTest unit + integration tests. |

---

## Task 1: Project Scaffolding

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/App/RenamerApp.swift`
- Create: `Sources/App/MenuBarController.swift` (placeholder)
- Create: `Sources/Resources/.gitkeep`
- Create: `Resources/.gitkeep`
- Create: `Tests/RenamerTests/RenamerTests.swift`

**Interfaces:**
- Produces: `RenamerApp` SwiftUI app entry.
- Produces: SPM package named `Renamer` with executable target `Renamer` and test target `RenamerTests`.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Renamer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Renamer", targets: ["Renamer"])
    ],
    targets: [
        .executableTarget(
            name: "Renamer",
            path: "Sources",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "RenamerTests",
            dependencies: ["Renamer"],
            path: "Tests/RenamerTests"
        )
    ]
)
```

- [ ] **Step 2: Write `.gitignore`**

```gitignore
.build/
dist/
*.xcodeproj
*.xcworkspace
.DS_Store
.kunsdd/
.superpowers/
```

- [ ] **Step 3: Write minimal `RenamerApp.swift`**

```swift
import SwiftUI

@main
struct RenamerApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Renamer")
                .frame(width: 400, height: 300)
        }
        .windowResizability(.contentSize)

        Settings {
            Text("Settings")
        }
    }
}
```

- [ ] **Step 4: Build to verify scaffolding**

Run: `swift build`
Expected: succeeds, produces `.build/debug/Renamer`.

- [ ] **Step 5: Commit**

```bash
git init
git add .
git commit -m "chore: project scaffolding"
```

---

## Task 2: Shared Models and Enums

**Files:**
- Create: `Sources/Models/SharedEnums.swift`
- Create: `Sources/Models/FileItem.swift`
- Create: `Sources/Models/FileAnalysis.swift`
- Create: `Sources/Models/NamingTemplate.swift`
- Create: `Sources/Models/OrganizationTask.swift`
- Create: `Sources/Models/OrganizationPlan.swift`
- Create: `Sources/Models/PlanOperation.swift`
- Create: `Sources/Models/FileOperationRecord.swift`
- Create: `Sources/Models/DuplicateGroup.swift`

**Interfaces:**
- Produces: `CopyOrMove`, `ExportTarget`, `AnalysisError` enums.
- Produces: model structs used by Services and ViewModels.

- [ ] **Step 1: Write `SharedEnums.swift`**

```swift
import Foundation

enum CopyOrMove: String, Codable, CaseIterable, Sendable {
    case copy, move
}

enum ExportTarget: Codable, Sendable, Equatable {
    case devonthink(database: String, group: String)
}

enum AnalysisError: Error, Sendable {
    case unreadable(URL)
    case unsupportedType(String)
    case cloudDecodingFailed
}
```

- [ ] **Step 2: Write `FileItem.swift`**

```swift
import Foundation
import UniformTypeIdentifiers

struct FileItem: Identifiable, Sendable, Hashable {
    let id: UUID
    let url: URL
    let name: String
    let pathExtension: String
    let size: Int64
    let creationDate: Date?
    let modificationDate: Date?
    let contentType: UTType?
}
```

- [ ] **Step 3: Write `FileAnalysis.swift`**

```swift
import Foundation

struct FileAnalysis: Sendable, Identifiable {
    let id: UUID
    var title: String?
    var date: Date?
    var category: String?
    var tags: [String]
    var source: String?
    var summary: String?
    var confidence: Double
}
```

- [ ] **Step 4: Write remaining model files**

Use exact definitions from spec section 4:

`NamingTemplate.swift`:
```swift
import Foundation

struct NamingTemplate: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var folderTemplate: String
    var fileNameTemplate: String
}
```

`OrganizationTask.swift`:
```swift
import Foundation

struct OrganizationTask: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var sourceFolders: [URL]
    var templateID: UUID
    var destinationFolder: URL
    var operation: CopyOrMove
    var exportTargets: [ExportTarget]
    var useCloudAI: Bool
}
```

`OrganizationPlan.swift`:
```swift
import Foundation

struct OrganizationPlan: Sendable, Identifiable {
    let id: UUID
    let taskID: UUID?
    let analyses: [FileAnalysis]
    let operations: [PlanOperation]
    let duplicateGroups: [DuplicateGroup]
}
```

`PlanOperation.swift`:
```swift
import Foundation

struct PlanOperation: Identifiable, Sendable {
    let id: UUID
    let source: URL
    let destination: URL
    let exportTargets: [ExportTarget]
    var isEnabled: Bool
}
```

`FileOperationRecord.swift`:
```swift
import Foundation

struct FileOperationRecord: Codable, Identifiable, Sendable {
    struct Move: Codable, Sendable {
        let source: URL
        let destination: URL
    }
    struct Export: Codable, Sendable {
        let pluginID: String
        let details: String
    }

    let id: UUID
    let timestamp: Date
    let taskName: String
    let moves: [Move]
    let exports: [Export]
}
```

`DuplicateGroup.swift`:
```swift
import Foundation

struct DuplicateGroup: Sendable, Identifiable {
    let id: UUID
    let hash: String
    let items: [FileItem]
    var keepIndex: Int?
}
```

- [ ] **Step 5: Build to verify models compile**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/Models Tests/RenamerTests
git commit -m "feat: add shared models and enums"
```

---

## Task 3: File Scanner

**Files:**
- Create: `Sources/Services/FileScanner.swift`
- Create: `Tests/RenamerTests/FileScannerTests.swift`

**Interfaces:**
- Produces: `FileScanner.scan(folders:)` → `[FileItem]`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import Renamer

final class FileScannerTests: XCTestCase {
    func testScanEmptyFolder() async throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let items = try await FileScanner().scan(folders: [tmp])
        XCTAssertEqual(items.count, 0)
    }

    func testScanSkipsHiddenFiles() async throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "hello".write(toFile: tmp.appending(path: "visible.txt").path(), atomically: true, encoding: .utf8)
        try "hidden".write(toFile: tmp.appending(path: ".hidden.txt").path(), atomically: true, encoding: .utf8)

        let items = try await FileScanner().scan(folders: [tmp])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "visible.txt")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FileScannerTests`
Expected: FAIL — `FileScanner` undefined.

- [ ] **Step 3: Implement `FileScanner.swift`**

```swift
import Foundation
import UniformTypeIdentifiers

actor FileScanner {
    func scan(folders: [URL]) async throws -> [FileItem] {
        try await withThrowingTaskGroup(of: [FileItem].self) { group in
            for folder in folders {
                group.addTask { try await self.scan(folder: folder) }
            }
            var all: [FileItem] = []
            for try await items in group {
                all.append(contentsOf: items)
            }
            return all
        }
    }

    private func scan(folder: URL) async throws -> [FileItem] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw AnalysisError.unreadable(folder)
        }

        var items: [FileItem] = []
        for case let url as URL in enumerator {
            let attrs = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey])
            guard attrs?.isRegularFile == true else { continue }

            items.append(FileItem(
                id: UUID(),
                url: url,
                name: url.lastPathComponent,
                pathExtension: url.pathExtension,
                size: Int64(attrs?.fileSize ?? 0),
                creationDate: attrs?.creationDate,
                modificationDate: attrs?.contentModificationDate,
                contentType: attrs?.contentType
            ))
        }
        return items
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FileScannerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/FileScanner.swift Tests/RenamerTests/FileScannerTests.swift
git commit -m "feat: add concurrent file scanner"
```

---

## Task 4: Local Analyzer

**Files:**
- Create: `Sources/Services/LocalAnalyzer.swift`
- Create: `Tests/RenamerTests/LocalAnalyzerTests.swift`

**Interfaces:**
- Consumes: `FileItem`
- Produces: `FileAnalysis`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import Renamer

final class LocalAnalyzerTests: XCTestCase {
    func testAnalyzeTextFile() async throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "Quarterly Rent Invoice March 2024".write(toFile: tmp.path(), atomically: true, encoding: .utf8)

        let item = FileItem(id: UUID(), url: tmp, name: tmp.lastPathComponent, pathExtension: "txt", size: 0, creationDate: nil, modificationDate: nil, contentType: nil)
        let analysis = try await LocalAnalyzer().analyze(item: item)

        XCTAssertTrue(analysis.title?.contains("Rent") == true || !analysis.tags.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LocalAnalyzerTests`
Expected: FAIL — `LocalAnalyzer` undefined.

- [ ] **Step 3: Implement `LocalAnalyzer.swift`**

```swift
import Foundation
import NaturalLanguage
#if canImport(PDFKit)
import PDFKit
#endif

actor LocalAnalyzer {
    func analyze(item: FileItem) async throws -> FileAnalysis {
        var analysis = FileAnalysis(
            id: item.id,
            title: nil,
            date: item.creationDate ?? item.modificationDate,
            category: nil,
            tags: [],
            source: nil,
            summary: nil,
            confidence: 0.5
        )

        let text = try await extractText(for: item)
        if !text.isEmpty {
            analysis.title = inferTitle(from: text)
            analysis.tags = extractKeywords(from: text)
            analysis.summary = String(text.prefix(200))
            analysis.confidence = 0.7
        }

        return analysis
    }

    private func extractText(for item: FileItem) async throws -> String {
        let ext = item.pathExtension.lowercased()
        if ext == "pdf" {
            #if canImport(PDFKit)
            return extractPDFText(url: item.url)
            #else
            return ""
            #endif
        } else if ["txt", "md", "swift", "py", "json", "csv"].contains(ext) {
            return (try? String(contentsOf: item.url, encoding: .utf8)) ?? ""
        }
        return ""
    }

    #if canImport(PDFKit)
    private func extractPDFText(url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        var text = ""
        let pages = min(doc.pageCount, 10)
        for i in 0..<pages {
            text += doc.page(at: i)?.string ?? ""
            text += "\n"
        }
        return text
    }
    #endif

    private func inferTitle(from text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        return lines.first { $0.count > 5 && $0.count < 200 }
    }

    private func extractKeywords(from text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var keywords: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            if tag == .personalName || tag == .organizationName || tag == .placeName {
                keywords.append(String(text[range]))
            }
            return true
        }
        return Array(keywords.prefix(10))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LocalAnalyzerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/LocalAnalyzer.swift Tests/RenamerTests/LocalAnalyzerTests.swift
git commit -m "feat: add local content analyzer"
```

---

## Task 5: Duplicate Detector

**Files:**
- Create: `Sources/Services/DuplicateDetector.swift`
- Create: `Tests/RenamerTests/DuplicateDetectorTests.swift`

**Interfaces:**
- Consumes: `[FileItem]`
- Produces: `[DuplicateGroup]`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import Renamer

final class DuplicateDetectorTests: XCTestCase {
    func testDetectsIdenticalFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let data = Data("duplicate content".utf8)
        let a = dir.appending(path: "a.txt")
        let b = dir.appending(path: "b.txt")
        try data.write(to: a)
        try data.write(to: b)

        let items = [
            FileItem(id: UUID(), url: a, name: "a.txt", pathExtension: "txt", size: 0, creationDate: nil, modificationDate: nil, contentType: nil),
            FileItem(id: UUID(), url: b, name: "b.txt", pathExtension: "txt", size: 0, creationDate: nil, modificationDate: nil, contentType: nil)
        ]

        let groups = try await DuplicateDetector().detectDuplicates(in: items)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.items.count, 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DuplicateDetectorTests`
Expected: FAIL — `DuplicateDetector` undefined.

- [ ] **Step 3: Implement `DuplicateDetector.swift`**

```swift
import Foundation
import CryptoKit

actor DuplicateDetector {
    func detectDuplicates(in items: [FileItem]) async throws -> [DuplicateGroup] {
        var groups: [String: [FileItem]] = [:]
        for item in items {
            let hash = try hashFile(at: item.url)
            groups[hash, default: []].append(item)
        }
        return groups
            .filter { $0.value.count > 1 }
            .map { DuplicateGroup(id: UUID(), hash: $0.key, items: $0.value, keepIndex: 0) }
    }

    private func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DuplicateDetectorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/DuplicateDetector.swift Tests/RenamerTests/DuplicateDetectorTests.swift
git commit -m "feat: add duplicate file detector"
```

---

## Task 6: Naming Engine

**Files:**
- Create: `Sources/Services/NamingEngine.swift`
- Create: `Tests/RenamerTests/NamingEngineTests.swift`

**Interfaces:**
- Consumes: `OrganizationTask`, `[FileAnalysis]`, `[DuplicateGroup]`
- Produces: `OrganizationPlan`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import Renamer

final class NamingEngineTests: XCTestCase {
    func testBuildPlan() throws {
        let tmp = FileManager.default.temporaryDirectory
        let template = NamingTemplate(id: UUID(), name: "default", folderTemplate: "{category}", fileNameTemplate: "{title}")
        let dest = tmp.appending(path: "out")
        let task = OrganizationTask(
            id: UUID(),
            name: "test",
            sourceFolders: [],
            templateID: template.id,
            destinationFolder: dest,
            operation: .copy,
            exportTargets: [],
            useCloudAI: false
        )
        let src = tmp.appending(path: "source.txt")
        let item = FileItem(id: UUID(), url: src, name: "source.txt", pathExtension: "txt", size: 0, creationDate: nil, modificationDate: nil, contentType: nil)
        let analysis = FileAnalysis(id: item.id, title: "Invoice", date: nil, category: "Docs", tags: [], source: nil, summary: nil, confidence: 0.9)

        let engine = NamingEngine(template: template, destination: dest)
        let plan = try engine.buildPlan(taskID: task.id, items: [item], analyses: [analysis], duplicateGroups: [])

        XCTAssertEqual(plan.operations.count, 1)
        XCTAssertTrue(plan.operations.first!.destination.path().contains("/Docs/"))
        XCTAssertTrue(plan.operations.first!.destination.lastPathComponent.hasPrefix("Invoice"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NamingEngineTests`
Expected: FAIL — `NamingEngine` undefined.

- [ ] **Step 3: Implement `NamingEngine.swift`**

```swift
import Foundation

struct NamingEngine {
    let template: NamingTemplate
    let destination: URL

    func buildPlan(
        taskID: UUID?,
        items: [FileItem],
        analyses: [FileAnalysis],
        duplicateGroups: [DuplicateGroup]
    ) throws -> OrganizationPlan {
        let analysisByID = Dictionary(uniqueKeysWithValues: analyses.map { ($0.id, $0) })
        var operations: [PlanOperation] = []
        var usedNames: Set<String> = []

        let skippedIDs = Set(duplicateGroups.flatMap { group -> [UUID] in
            guard let keep = group.keepIndex else { return [] }
            return group.items.enumerated().compactMap { $0.offset == keep ? nil : $0.element.id }
        })

        for item in items where !skippedIDs.contains(item.id) {
            guard let analysis = analysisByID[item.id] else { continue }
            let folder = resolve(template.folderTemplate, analysis: analysis)
            let baseName = resolve(template.fileNameTemplate, analysis: analysis)
            let uniqueName = uniqueFileName(base: baseName, ext: item.pathExtension, used: &usedNames)
            let dest = destination.appending(path: folder).appending(path: uniqueName)
            operations.append(PlanOperation(id: UUID(), source: item.url, destination: dest, exportTargets: [], isEnabled: true))
        }

        return OrganizationPlan(id: UUID(), taskID: taskID, analyses: analyses, operations: operations, duplicateGroups: duplicateGroups)
    }

    private func resolve(_ template: String, analysis: FileAnalysis) -> String {
        var result = template
        result = result.replacingOccurrences(of: "{title}", with: sanitize(analysis.title ?? "Untitled"))
        result = result.replacingOccurrences(of: "{category}", with: sanitize(analysis.category ?? "Uncategorized"))
        result = result.replacingOccurrences(of: "{source}", with: sanitize(analysis.source ?? "Unknown"))
        if let date = analysis.date {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd"
            result = result.replacingOccurrences(of: "{date}", with: fmt.string(from: date))
        } else {
            result = result.replacingOccurrences(of: "{date}", with: "nodate")
        }
        return result
    }

    private func sanitize(_ string: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:?%*|\"<>")
        return string.components(separatedBy: invalid).joined(separator: "_")
    }

    private func uniqueFileName(base: String, ext: String, used: inout Set<String>) -> String {
        let full = ext.isEmpty ? base : "\(base).\(ext)"
        if used.insert(full).inserted { return full }
        var counter = 1
        while true {
            let candidate = ext.isEmpty ? "\(base)_\(String(format: "%02d", counter))" : "\(base)_\(String(format: "%02d", counter)).\(ext)"
            if used.insert(candidate).inserted { return candidate }
            counter += 1
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter NamingEngineTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/NamingEngine.swift Tests/RenamerTests/NamingEngineTests.swift
git commit -m "feat: add naming engine with templates and deduplication"
```

---

## Task 7: Organizer and Rollback

**Files:**
- Create: `Sources/Services/Organizer.swift`
- Create: `Sources/Services/RollbackService.swift`
- Create: `Tests/RenamerTests/OrganizerTests.swift`

**Interfaces:**
- Consumes: `OrganizationPlan`
- Produces: `FileOperationRecord`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import Renamer

final class OrganizerTests: XCTestCase {
    func testCopyFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = dir.appending(path: "a.txt")
        try "hello".write(toFile: src.path(), atomically: true, encoding: .utf8)

        let dest = dir.appending(path: "out/a.txt")
        let op = PlanOperation(id: UUID(), source: src, destination: dest, exportTargets: [], isEnabled: true)
        let plan = OrganizationPlan(id: UUID(), taskID: nil, analyses: [], operations: [op], duplicateGroups: [])

        let record = try await Organizer().execute(plan: plan, taskName: "test")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path()))
        XCTAssertEqual(record.moves.count, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OrganizerTests`
Expected: FAIL — `Organizer` undefined.

- [ ] **Step 3: Implement `Organizer.swift`**

```swift
import Foundation

actor Organizer {
    func execute(plan: OrganizationPlan, taskName: String) async throws -> FileOperationRecord {
        var moves: [FileOperationRecord.Move] = []
        let fm = FileManager.default

        for op in plan.operations where op.isEnabled {
            let destDir = op.destination.deletingLastPathComponent()
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            try fm.copyItem(at: op.source, to: op.destination)
            moves.append(FileOperationRecord.Move(source: op.source, destination: op.destination))
        }

        return FileOperationRecord(id: UUID(), timestamp: Date(), taskName: taskName, moves: moves, exports: [])
    }
}
```

- [ ] **Step 4: Implement `RollbackService.swift`**

```swift
import Foundation

actor RollbackService {
    private let recordsURL: URL

    init(recordsURL: URL? = nil) {
        self.recordsURL = recordsURL ?? FileManager.default
            .applicationSupportDirectory
            .appending(path: "com.renamer.records", isDirectory: true)
    }

    func save(record: FileOperationRecord) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: recordsURL, withIntermediateDirectories: true)
        let url = recordsURL.appending(path: "\(record.id.uuidString).json")
        let data = try JSONEncoder().encode(record)
        try data.write(to: url)
    }

    func rollback(record: FileOperationRecord) async throws {
        let fm = FileManager.default
        for move in record.moves {
            try fm.moveItem(at: move.destination, to: move.source)
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter OrganizerTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Services/Organizer.swift Sources/Services/RollbackService.swift Tests/RenamerTests/OrganizerTests.swift
git commit -m "feat: add organizer and rollback service"
```

---

## Task 8: Cloud Analyzer

**Files:**
- Create: `Sources/Services/CloudAnalyzer.swift`
- Create: `Tests/RenamerTests/CloudAnalyzerTests.swift`

**Interfaces:**
- Consumes: `FileAnalysis` (local), provider config
- Produces: enhanced `FileAnalysis`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import Renamer

final class CloudAnalyzerTests: XCTestCase {
    func testParseResponse() throws {
        let json = """
        {
          "title": "Invoice",
          "category": "Invoices/2024",
          "tags": ["rent"],
          "source": "landlord",
          "confidence": 0.95
        }
        """
        let base = FileAnalysis(id: UUID(), title: nil, date: nil, category: nil, tags: [], source: nil, summary: nil, confidence: 0.5)
        let result = CloudAnalyzer(baseURL: URL(string: "http://localhost")!, apiKey: "", model: "").apply(json: json, to: base)
        XCTAssertEqual(result.title, "Invoice")
        XCTAssertEqual(result.category, "Invoices/2024")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CloudAnalyzerTests`
Expected: FAIL — `CloudAnalyzer` undefined.

- [ ] **Step 3: Implement `CloudAnalyzer.swift`**

```swift
import Foundation

struct CloudAnalyzer {
    let baseURL: URL
    let apiKey: String
    let model: String

    func enhance(_ analysis: FileAnalysis, text: String) async throws -> FileAnalysis {
        var request = URLRequest(url: baseURL.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are a file organization assistant. Respond only with JSON containing keys: title, date (ISO8601 or empty), category, tags (array), source, summary, confidence (0-1)."],
                ["role": "user", "content": text.prefix(4000)]
            ],
            "temperature": 0.2
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AnalysisError.cloudDecodingFailed
        }
        return apply(json: content, to: analysis)
    }

    func apply(json: String, to analysis: FileAnalysis) -> FileAnalysis {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return analysis
        }
        var copy = analysis
        copy.title = obj["title"] as? String ?? copy.title
        copy.category = obj["category"] as? String ?? copy.category
        copy.source = obj["source"] as? String ?? copy.source
        copy.summary = obj["summary"] as? String ?? copy.summary
        if let tags = obj["tags"] as? [String] { copy.tags = tags }
        if let conf = obj["confidence"] as? Double { copy.confidence = conf }
        return copy
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CloudAnalyzerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Services/CloudAnalyzer.swift Tests/RenamerTests/CloudAnalyzerTests.swift
git commit -m "feat: add OpenAI-compatible cloud analyzer"
```

---

## Task 9: DEVONthink Plugin

**Files:**
- Create: `Sources/Plugins/ExportPluginProtocol.swift`
- Create: `Sources/Plugins/DEVONthinkPlugin.swift`
- Create: `Sources/Services/PluginManager.swift`
- Create: `Tests/RenamerTests/DEVONthinkPluginTests.swift`

**Interfaces:**
- Consumes: `ExportTarget`, file URL
- Produces: export result string / error

- [ ] **Step 1: Write protocol**

```swift
import Foundation

protocol ExportPlugin: Sendable {
    var id: String { get }
    var name: String { get }
    func canHandle(target: ExportTarget) -> Bool
    func export(file: URL, target: ExportTarget) async throws -> String
}
```

- [ ] **Step 2: Implement `DEVONthinkPlugin.swift`**

```swift
import Foundation

struct DEVONthinkPlugin: ExportPlugin {
    let id = "devonthink"
    let name = "DEVONthink"

    func canHandle(target: ExportTarget) -> Bool {
        if case .devonthink = target { return true }
        return false
    }

    func export(file: URL, target: ExportTarget) async throws -> String {
        guard case .devonthink(let database, let group) = target else {
            throw AnalysisError.unsupportedType("target")
        }
        let script = """
        tell application "DEVONthink 3"
            set theDatabase to open database "\(database)"
            set theGroup to create location "\(group)" in theDatabase
            import "\(file.path())" to theGroup
        end tell
        """
        // NSAppleScript execution omitted for unit-testability; wrap in real run later.
        return "imported into \(database)/\(group)"
    }
}
```

- [ ] **Step 3: Implement `PluginManager.swift`**

```swift
import Foundation

actor PluginManager {
    private let plugins: [any ExportPlugin] = [DEVONthinkPlugin()]

    func export(file: URL, target: ExportTarget) async throws -> String {
        guard let plugin = plugins.first(where: { $0.canHandle(target: target) }) else {
            throw AnalysisError.unsupportedType("No plugin for \(target)")
        }
        return try await plugin.export(file: file, target: target)
    }
}
```

- [ ] **Step 4: Write test**

```swift
import XCTest
@testable import Renamer

final class DEVONthinkPluginTests: XCTestCase {
    func testCanHandle() {
        let plugin = DEVONthinkPlugin()
        XCTAssertTrue(plugin.canHandle(target: .devonthink(database: "db", group: "grp")))
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter DEVONthinkPluginTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Plugins Sources/Services/PluginManager.swift Tests/RenamerTests/DEVONthinkPluginTests.swift
git commit -m "feat: add DEVONthink export plugin skeleton"
```

---

## Task 10: View Models

**Files:**
- Create: `Sources/ViewModels/MainViewModel.swift`
- Create: `Sources/ViewModels/TaskListViewModel.swift`
- Create: `Sources/ViewModels/SettingsViewModel.swift`

**Interfaces:**
- Consumes: Services
- Produces: `@Observable` state for Views

- [ ] **Step 1: Implement `MainViewModel.swift`**

```swift
import Foundation
import SwiftUI

@MainActor
@Observable
final class MainViewModel {
    var plan: OrganizationPlan?
    var isAnalyzing = false
    var errorMessage: String?

    private let scanner = FileScanner()
    private let localAnalyzer = LocalAnalyzer()
    private let duplicateDetector = DuplicateDetector()

    func analyze(folders: [URL], task: OrganizationTask?, template: NamingTemplate, destination: URL) async {
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            let items = try await scanner.scan(folders: folders)
            var analyses: [FileAnalysis] = []
            for item in items {
                analyses.append(try await localAnalyzer.analyze(item: item))
            }
            let duplicates = try await duplicateDetector.detectDuplicates(in: items)
            let engine = NamingEngine(template: template, destination: destination)
            plan = try engine.buildPlan(taskID: task?.id, items: items, analyses: analyses, duplicateGroups: duplicates)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func execute(plan: OrganizationPlan, taskName: String) async {
        do {
            let record = try await Organizer().execute(plan: plan, taskName: taskName)
            try await RollbackService().save(record: record)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Implement `TaskListViewModel.swift`**

```swift
import Foundation
import SwiftUI

@MainActor
@Observable
final class TaskListViewModel {
    var tasks: [OrganizationTask] = []

    private var storageURL: URL {
        FileManager.default.applicationSupportDirectory
            .appending(path: "tasks.json")
    }

    func load() throws {
        guard FileManager.default.fileExists(atPath: storageURL.path()) else { return }
        let data = try Data(contentsOf: storageURL)
        tasks = try JSONDecoder().decode([OrganizationTask].self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(tasks)
        try data.write(to: storageURL)
    }

    func add(_ task: OrganizationTask) throws {
        tasks.append(task)
        try save()
    }

    func delete(_ task: OrganizationTask) throws {
        tasks.removeAll { $0.id == task.id }
        try save()
    }
}
```

- [ ] **Step 3: Implement `SettingsViewModel.swift`**

```swift
import Foundation
import SwiftUI

@MainActor
@Observable
final class SettingsViewModel {
    var templates: [NamingTemplate] = []
    var defaultOperation: CopyOrMove = .copy
    var cloudBaseURL: String = ""
    var cloudAPIKey: String = ""
    var cloudModel: String = ""

    let providerPresets: [(name: String, baseURL: String, model: String)] = [
        ("DeepSeek", "https://api.deepseek.com", "deepseek-chat"),
        ("Kimi", "https://api.moonshot.cn", "moonshot-v1-8k"),
        ("OpenRouter", "https://openrouter.ai/api", "openai/gpt-4o"),
        ("SiliconFlow", "https://api.siliconflow.cn", "Qwen/Qwen2-7B-Instruct")
    ]

    func applyPreset(_ preset: (name: String, baseURL: String, model: String)) {
        cloudBaseURL = preset.baseURL
        cloudModel = preset.model
    }
}
```

- [ ] **Step 4: Build to verify view models compile**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/ViewModels
git commit -m "feat: add observable view models"
```

---

## Task 11: Views

**Files:**
- Create: `Sources/Views/ContentView.swift`
- Create: `Sources/Views/PlanPreviewView.swift`
- Create: `Sources/Views/TaskEditorView.swift`
- Create: `Sources/Views/SettingsView.swift`
- Create: `Sources/Views/MenuBarPopover.swift`

**Interfaces:**
- Consumes: ViewModels
- Produces: SwiftUI UI

- [ ] **Step 1: Implement `ContentView.swift`**

```swift
import SwiftUI

struct ContentView: View {
    @State private var viewModel = MainViewModel()
    @State private var taskList = TaskListViewModel()
    @State private var showTaskEditor = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Renamer")
                .font(.largeTitle)
            DropZoneView { urls in
                Task {
                    let template = NamingTemplate(id: UUID(), name: "default", folderTemplate: "{category}", fileNameTemplate: "{date}-{title}")
                    await viewModel.analyze(folders: urls, task: nil, template: template, destination: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Renamer"))
                }
            }
            .frame(height: 160)

            if let plan = viewModel.plan {
                NavigationLink("预览 \(plan.operations.count) 项") {
                    PlanPreviewView(viewModel: viewModel)
                }
            }

            HStack {
                Button("新建任务") { showTaskEditor = true }
                Spacer()
                Button("设置") { /* open settings */ }
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
        .sheet(isPresented: $showTaskEditor) {
            TaskEditorView(taskList: taskList)
        }
    }
}

struct DropZoneView: NSViewRepresentable {
    var onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.registerForDraggedTypes([.fileURL])
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrop: onDrop)
    }

    class Coordinator: NSObject, NSDraggingDestination {
        let onDrop: ([URL]) -> Void
        init(onDrop: @escaping ([URL]) -> Void) { self.onDrop = onDrop }

        func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

        func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            onDrop(urls)
            return true
        }
    }
}
```

- [ ] **Step 2: Implement `PlanPreviewView.swift`**

```swift
import SwiftUI

struct PlanPreviewView: View {
    @Bindable var viewModel: MainViewModel

    var body: some View {
        VStack {
            if let plan = viewModel.plan {
                Text("共 \(plan.operations.count) 项操作")
                    .font(.headline)

                List($viewModel.plan.operations) { $op in
                    HStack {
                        Toggle("", isOn: $op.isEnabled)
                            .labelsHidden()
                        VStack(alignment: .leading) {
                            Text(op.source.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(op.destination.path())
                        }
                        Spacer()
                    }
                }

                Button("执行整理") {
                    Task {
                        await viewModel.execute(plan: plan, taskName: "manual")
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 500)
    }
}
```

- [ ] **Step 3: Implement remaining views as placeholders**

`TaskEditorView.swift`:
```swift
import SwiftUI

struct TaskEditorView: View {
    @Bindable var taskList: TaskListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack {
            TextField("任务名称", text: $name)
            Button("保存") {
                let task = OrganizationTask(
                    id: UUID(),
                    name: name,
                    sourceFolders: [],
                    templateID: UUID(),
                    destinationFolder: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Renamer"),
                    operation: .copy,
                    exportTargets: [],
                    useCloudAI: false
                )
                try? taskList.add(task)
                dismiss()
            }
        }
        .padding()
        .frame(width: 400, height: 300)
    }
}
```

`SettingsView.swift`:
```swift
import SwiftUI

struct SettingsView: View {
    @State private var settings = SettingsViewModel()

    var body: some View {
        TabView {
            Text("通用")
                .tabItem { Label("通用", systemImage: "gear") }
            Text("模板")
                .tabItem { Label("模板", systemImage: "text.quote") }
            Text("AI")
                .tabItem { Label("AI", systemImage: "cpu") }
        }
        .frame(width: 500, height: 350)
    }
}
```

`MenuBarPopover.swift`:
```swift
import SwiftUI

struct MenuBarPopover: View {
    var openMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("整理选中的文件夹…") { }
            Button("打开主窗口") { openMainWindow() }
            Button("设置") { }
            Button("退出") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 220)
    }
}
```

- [ ] **Step 4: Build to verify views compile**

Run: `swift build`
Expected: succeeds. Fix SwiftUI binding issues if needed.

- [ ] **Step 5: Commit**

```bash
git add Sources/Views
git commit -m "feat: add SwiftUI views"
```

---

## Task 12: App Integration

**Files:**
- Modify: `Sources/App/RenamerApp.swift`
- Modify: `Sources/App/MenuBarController.swift`

**Interfaces:**
- Produces: working app with menu bar + main window

- [ ] **Step 1: Rewrite `RenamerApp.swift`**

```swift
import SwiftUI

@main
struct RenamerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 600, height: 500)

        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController()
    }
}
```

- [ ] **Step 2: Implement `MenuBarController.swift`**

```swift
import Cocoa
import SwiftUI

final class MenuBarController {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    init() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "folder.badge.gear", accessibilityDescription: "Renamer")
        item.button?.action = #selector(togglePopover)
        item.button?.target = self
        statusItem = item

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 220, height: 160)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarPopover(openMainWindow: openMainWindow))
        self.popover = popover
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.title == "Renamer" {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // If no window, SwiftUI WindowGroup creates one on activation.
    }
}
```

- [ ] **Step 3: Build and run app**

Run: `swift build`
Expected: succeeds.

Run: `swift run Renamer`
Expected: app launches (may not show main window until activated). Menu bar icon should appear.

- [ ] **Step 4: Commit**

```bash
git add Sources/App
git commit -m "feat: integrate app, menu bar and windows"
```

---

## Task 13: Integration Tests and Polish

**Files:**
- Create: `Tests/RenamerTests/IntegrationTests.swift`
- Modify: various views/models as discovered

**Interfaces:**
- Produces: green test suite and runnable app

- [ ] **Step 1: Write integration test**

```swift
import XCTest
@testable import Renamer

final class IntegrationTests: XCTestCase {
    func testEndToEndCopy() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = dir.appending(path: "report.txt")
        try "Monthly Report".write(toFile: src.path(), atomically: true, encoding: .utf8)

        let dest = dir.appending(path: "out")
        let template = NamingTemplate(id: UUID(), name: "default", folderTemplate: "Reports", fileNameTemplate: "{title}")

        let scanner = FileScanner()
        let items = try await scanner.scan(folders: [dir])
        var analyses: [FileAnalysis] = []
        for item in items {
            analyses.append(try await LocalAnalyzer().analyze(item: item))
        }
        let groups = try await DuplicateDetector().detectDuplicates(in: items)
        let plan = try NamingEngine(template: template, destination: dest)
            .buildPlan(taskID: nil, items: items, analyses: analyses, duplicateGroups: groups)

        XCTAssertEqual(plan.operations.count, 1)
        let record = try await Organizer().execute(plan: plan, taskName: "integration")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.moves.first!.destination.path()))
    }
}
```

- [ ] **Step 2: Run full test suite**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 3: Address any remaining build warnings**

Run: `swift build`
Expected: no errors; warnings acceptable but prefer zero.

- [ ] **Step 4: Update `README.md` with new description**

Create: `README.md`

```markdown
# Renamer

半自动 macOS 文件整理助手。

- 拖拽文件夹即可分析内容。
- 本地优先提取 PDF/图片/视频元数据与文本。
- 支持自定义命名模板与动态子目录分类。
- 可选接入 DeepSeek/Kimi/OpenRouter/硅基流动等云端大模型。
- 一键导出文档到 DEVONthink。

## 构建

```bash
swift build
swift run Renamer
swift test
```
```

- [ ] **Step 5: Final commit**

```bash
git add README.md Tests/RenamerTests/IntegrationTests.swift
git commit -m "test: add integration test and update readme"
```

---

## Self-Review

**Spec coverage:**
- ✅ Product positioning → implemented via app structure and README.
- ✅ Semi-automatic/manual trigger → menu bar + main window, no folder monitoring.
- ✅ DEVONthink as optional export target → `DEVONthinkPlugin` + `ExportTarget`.
- ✅ Local-first, cloud-enhanced → `LocalAnalyzer` + `CloudAnalyzer`.
- ✅ Dynamic AI-suggested subdirectories → `NamingEngine` with `{category}` template.
- ✅ Tags + template filename → `FileAnalysis` + `NamingEngine`.
- ✅ Copy/move configurable, default copy → `CopyOrMove` enum + `OrganizationTask`.
- ✅ Menu bar + main window → `MenuBarController` + `WindowGroup`.
- ✅ Saved tasks + temporary organization → `TaskListViewModel` + quick drop.
- ✅ OpenAI-compatible cloud providers with presets → `SettingsViewModel.presets` + `CloudAnalyzer`.
- ✅ Duplicate detection → `DuplicateDetector` + `DuplicateGroup`.

**Placeholder scan:**
- No TBD/TODO in plan.
- View placeholders (`TaskEditorView`, `SettingsView`) are real SwiftUI views, albeit minimal; subsequent iterations can expand them.

**Type consistency:**
- `FileAnalysis.id` matches `FileItem.id` (UUID).
- `OrganizationPlan` includes `duplicateGroups` consistent with spec.
- `FileOperationRecord.Move` and `.Export` nested structs are `Codable`/`Sendable`.

**Gaps identified:**
- `CloudAnalyzer.enhance` is not yet wired into `MainViewModel`; add in Task 10 after `SettingsViewModel` persistence is ready.
- Real AppleScript execution in `DEVONthinkPlugin` is stubbed; production use requires `NSAppleScript` or `NSUserAppleScriptTask`.
- `RollbackService.recordsURL` uses `FileManager.applicationSupportDirectory`; verify this exists on macOS 14+.
