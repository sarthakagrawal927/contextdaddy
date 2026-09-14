import SwiftUI
import AppKit
import DiskCore

@main
struct DiskBuddyApp: App {
    @NSApplicationDelegateAdaptor(StorageDaddyAppDelegate.self) private var appDelegate
    @StateObject private var model = ExplorerModel()
    @StateObject private var updates = AppUpdates()
    var body: some Scene {
        WindowGroup("storagedaddy") { ExplorerView().environmentObject(model).frame(minWidth: 880, minHeight: 600).onAppear { updates.start(model: model) } }
            .defaultSize(width: 1320, height: 850)
            .windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("About storagedaddy") { model.showAbout = true }
                }
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…", action: updates.check).disabled(!updates.canCheck || !updates.isIdle)
                    Toggle("Automatically Check for Updates", isOn: $updates.automaticallyChecks)
                    if updates.waitingForIdle { Text("Update waiting for current work to finish") }
                    Divider()

                    Button("Getting Started…") { model.showWelcome = true }.disabled(model.busy)
                    Button("Acknowledgments…") { model.workspace = .acknowledgments; model.showWelcome = false }
                }
                CommandGroup(after: .newItem) {
                    Button("Scan Folder…") { model.chooseFolder() }.keyboardShortcut("o")
                    Button("Rescan") { model.rescan() }.keyboardShortcut("r").disabled(model.scan == nil || model.busy)
                    Button("Cancel Scan") { model.cancel() }.keyboardShortcut(".").disabled(!model.busy)
                }
            }
        Settings {
            StorageSettingsView(updates: updates).environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor final class StorageDaddyAppDelegate: NSObject, NSApplicationDelegate {
    static let brandIcon: NSImage? = Bundle.main.url(forResource: "StorageDaddy", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    static func applyIcon() {
        if let icon = brandIcon { NSApplication.shared.applicationIconImage = icon }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.applyIcon()
    }
    func applicationDidBecomeActive(_ notification: Notification) { Self.applyIcon() }
}

enum Workspace: String, CaseIterable, Identifiable {
    case aiSessions = "AI Sessions", aiContext = "AI Context", developer = "Developer Insights", explore = "Explore", applications = "Applications", snapshots = "Snapshots", cleanup = "Cleanup", acknowledgments = "Acknowledgments"
    var id: String { rawValue }
    var title: String { switch self { case .explore: "Storage"; case .cleanup: "Review Cleanup"; case .snapshots: "History"; default: rawValue } }
    var requiresScan: Bool { [.developer, .cleanup].contains(self) }
    var icon: String { switch self { case .aiSessions: "bubble.left.and.text.bubble.right.fill"; case .aiContext: "sparkles.rectangle.stack"; case .developer: "terminal"; case .explore: "internaldrive.fill"; case .applications: "app.badge"; case .snapshots: "clock.arrow.circlepath"; case .cleanup: "trash"; case .acknowledgments: "heart.text.square" } }
}

enum StorageSection: String, CaseIterable, Identifiable {
    case explore = "Explore"
    case developer = "Developer Insights"
    case cleanup = "Cleanup"
    var id: String { rawValue }
    var icon: String { switch self { case .explore: "square.grid.2x2"; case .developer: "terminal"; case .cleanup: "trash" } }
}
enum MapMode: String, CaseIterable, Identifiable {
    case folders = "Folders", sunburst = "Sunburst", flame = "Flame", bubbles = "Bubbles", mindMap = "Mind Map", top = "Top Sizes", age = "Age Map", treemap = "Treemap"
    var id: String { rawValue }
    var icon: String { switch self { case .folders: "folder"; case .sunburst: "circle.dotted.circle"; case .flame: "chart.bar.xaxis"; case .bubbles: "circle.grid.3x3"; case .mindMap: "point.3.connected.trianglepath.dotted"; case .top: "chart.bar.fill"; case .age: "calendar"; case .treemap: "rectangle.split.3x3" } }
}
struct AgeSummary: Sendable {
    var count = 0
    var bytes: Int64 = 0
    var largest: NodeRanking
    init(allocated: Bool = true) { largest = NodeRanking(limit: 4, allocated: allocated) }
}

@MainActor final class ExplorerModel: ObservableObject {
    @Published private(set) var excludedFolders: [String] = UserDefaults.standard.stringArray(forKey: "excludedFolders") ?? [] {
        didSet {
            UserDefaults.standard.set(excludedFolders, forKey: "excludedFolders")
            // Existing results remain historical; clear prior cleanup approvals.
            staged.removeAll()
            incompleteCleanup.removeAll()
            exclusionResultsStale = scan != nil
            progress = "Exclusions updated · Cleanup queue cleared · Nothing moved"
        }
    }

    @Published private(set) var exclusionResultsStale = false

    func addExcludedFolders(_ urls: [URL]) {
        guard !busy else { return }
        let paths = FolderExclusions(paths: excludedFolders + urls.map { $0.standardizedFileURL.path }).paths
        if paths != excludedFolders { excludedFolders = paths }
    }

    func removeExcludedFolder(_ path: String) {
        guard !busy else { return }
        excludedFolders.removeAll { $0 == path }
    }

    @Published var cleanupRefreshPaths: [String] = UserDefaults.standard.stringArray(forKey: "cleanupRefreshPaths") ?? [] {
        didSet { UserDefaults.standard.set(cleanupRefreshPaths, forKey: "cleanupRefreshPaths") }
    }
    func rescanAfterCleanup() {
        guard !busy, staged.isEmpty, let path = cleanupRefreshPaths.first else { return }
        guard FileManager.default.isReadableFile(atPath: path) else {
            message = "The previous scan location is unavailable. Reconnect the disk or use Scan Folder to grant access again."
            return
        }
        start(URL(fileURLWithPath: path))
    }
    @Published var showAbout = false
    @Published var showWelcome = false
    @Published var lastTrashedURLs: [URL] = []
    @Published var scan: ScanResult?
    let installedApplications = InstalledApplicationsModel()
    lazy var conversationArchive = ConversationArchiveModel { [weak self] in
        self?.requestAISessionsRefresh()
    }
    @Published private(set) var aiSessionsRefreshID = UUID()
    @Published var aiContextSection: AIContextSection = .folders
    @Published var aiSessionsSection: AISessionsSection = .sessions
    @Published var workspace: Workspace = .explore
    @Published var storageSection: StorageSection = .explore
    @Published var mode: MapMode = .treemap { didSet { refreshFocus() } }
    @Published var focus = 0 { didSet { refreshFocus() } }
    @Published var selected: Int?
    @Published var search = "" { didSet { refreshFocus() } }
    @Published var allocated = true { didSet { refreshFocus() } }
    @Published var liveProgress: ScanProgress?
    @Published var busy = false
    @Published var progress = "Choose what to scan to begin"
    @Published var message: String?
    @Published var staged: Set<Int> = []
    @Published private(set) var incompleteCleanup: [Int: CleanupIncompleteReview] = [:]
    @Published var showCleanup = false
    // No background monitoring in the current product flow.
    let monitoring = false
    @Published var savedSnapshots: [SavedScanSnapshot] = []
    @Published var snapshotHistoryLoading = false
    @Published var snapshotHistoryWarning: String?
    @Published var snapshotNotice: String?
    @Published var lastSavedSnapshotStarted: Date?
    private var snapshotHistoryGeneration = UUID()
    private var snapshotDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StorageDaddy/Scan History", isDirectory: true)
    }
    @Published var visible: [DiskNode] = []
    @Published var ranked: [DiskNode] = []
    @Published var aged: [AgeSummary] = (0..<4).map { _ in AgeSummary() }
    @Published var quickWinNodes: [DiskNode] = []
    @Published var appNodes: [DiskNode] = []
    @Published var fileCount = 0
    @Published var snapshotBusy = false
    @Published var projectGrowth: [Int: Int64] = [:]
    @Published var reportFindingsByID: [Int: DeveloperFinding] = [:]
    @Published var reportProjectNames: [Int: String] = [:]
    @Published var developerReport: DeveloperReport?
    @Published var developerGroups: [DeveloperGroup] = []
    @Published var previousDeveloperGroups: [DeveloperGroup]?
    @Published var previousDeveloperDate: Date?
    @Published var analysisElapsed: Double = 0
    @Published var insightsElapsed: Double = 0
    @Published var scanPeakRSS: UInt64?
    private var priorScanPeakRSS: UInt64?
    private var memoryTask: Task<Void, Never>?
    private var scanVersion = UUID()
    private var activeScanVersion: UUID?
    private var focusTask: Task<Void, Never>?
    private var focusVersion = UUID()
    private var task: Task<Void, Never>?
    private var scopedURL: URL?
    var node: DiskNode? { guard let scan, let id = selected, scan.nodes.indices.contains(id) else { return nil }; return scan.nodes[id] }
    func bytes(_ node: DiskNode) -> Int64 { allocated ? node.allocatedBytes : node.logicalBytes }
    func refreshFocus() {
        focusTask?.cancel()
        guard let scan, scan.nodes.indices.contains(focus) else { visible = []; return }
        let version = UUID(); focusVersion = version
        let focus = focus, search = search, allocated = allocated, mode = mode
        focusTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                func size(_ n: DiskNode) -> Int64 { allocated ? n.allocatedBytes : n.logicalBytes }
                let visible = scan.nodes[focus].children.map { scan.nodes[$0] }.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.sorted { size($0) > size($1) }
                var files = NodeRanking(limit: 250, allocated: allocated)
                var aged = (0..<4).map { _ in AgeSummary(allocated: allocated) }
                guard mode == .top || mode == .age else { return (visible, files.sorted, aged) }
                var stack = [focus]
                let now = Date()
                while let id = stack.popLast() {
                    if Task.isCancelled { break }
                    let n = scan.nodes[id]
                    if n.isDirectory { stack.append(contentsOf: n.children) }
                    else if search.isEmpty || n.name.localizedCaseInsensitiveContains(search) {
                        if mode == .top { files.insert(n); continue }
                        let days = now.timeIntervalSince(n.modified) / 86400
                        let bucket = days < 30 ? 0 : days < 180 ? 1 : days < 365 ? 2 : 3
                        aged[bucket].count += 1; aged[bucket].bytes += size(n); aged[bucket].largest.insert(n)
                    }
                }
                return (visible, files.sorted, aged)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, focusVersion == version else { return }
            visible = result.0; ranked = result.1; aged = result.2
        }
    }
    func scanUserCaches() {
        start(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches"), destination: .explore)
    }
    func openStorage(_ section: StorageSection) {
        storageSection = section
        showWelcome = false
        workspace = .explore
    }
    func requestAISessionsRefresh() { aiSessionsRefreshID = UUID() }
    func chooseFolder() { chooseFolder(destination: nil) }
    private func chooseFolder(destination: Workspace?) {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false; p.prompt = "Scan Folder"
        if p.runModal() == .OK, let url = p.url { start(url, destination: destination) }
    }
    func rescan() { if let scan { start(URL(fileURLWithPath: scan.rootPath)) } }
    func start(_ url: URL, destination: Workspace? = nil) {
        guard !busy else { return }
        showWelcome = false
        lastTrashedURLs = []
        task?.cancel(); scanVersion = UUID(); staged = []; incompleteCleanup = [:]; busy = true; message = nil
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = url; _ = url.startAccessingSecurityScopedResource()
        liveProgress = nil
        progress = "Scanning \(StorageLabels.location(url.path))…"
        let priorRSS = scanPeakRSS
        priorScanPeakRSS = priorRSS
        memoryTask?.cancel(); scanPeakRSS = ProcessMemory.residentBytes()
        memoryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
                self?.sampleMemory()
            }
        }
        let version = scanVersion
        activeScanVersion = version
        task = Task { [self] in
            let clock = ContinuousClock(); let analysisStart = clock.now
            var didPublish = false
            defer {
                if scanVersion == version {
                    sampleMemory(); memoryTask?.cancel(); memoryTask = nil
                    if !didPublish { scanPeakRSS = priorRSS }
                    activeScanVersion = nil
                }
            }
            do {
                let result = try await DiskScanner.scan(root: url, excludedFolders: excludedFolders, progress: { [weak self] p in
                    Task { @MainActor [weak self] in guard let self, self.scanVersion == version, self.busy else { return }; self.liveProgress = p; self.progress = "\(p.entries.formatted()) entries · \(StorageLabels.location(p.path))" }
                })
                try Task.checkCancellation()
                guard !result.nodes.isEmpty else { throw NSError(domain: "Scan", code: 1, userInfo: [NSLocalizedDescriptionKey: "This folder is excluded by folder settings or the sensitive-path policy. Choose a different folder."]) }
                let summaryStart = clock.now
                let priorScan = self.scan?.rootPath == result.rootPath ? self.scan : nil
                let priorReport = priorScan == nil ? nil : developerReport
                let worker = Task.detached(priority: .utility) {
                    var quick = NodeRanking(limit: 6, allocated: true)
                    var apps: [DiskNode] = []; var fileCount = 0
                    for node in result.nodes {
                        if node.id & 255 == 0 { try Task.checkCancellation() }
                        if !node.isDirectory { fileCount += 1; continue }
                        if ["Downloads", "node_modules", "DerivedData", "Caches", "build", "Logs"].contains(node.name) { quick.insert(node) }
                        if node.name.hasSuffix(".app") { apps.append(node) }
                    }
                    apps.sort { $0.allocatedBytes > $1.allocatedBytes }
                    let groups = try DeveloperInsights.analyze(result, cancellationCheck: { try Task.checkCancellation() })
                    let report = try DeveloperReport.build(scan: result, groups: groups, cancellationCheck: { try Task.checkCancellation() })
                    var growth: [Int: Int64] = [:]
                    if let priorScan, let priorReport {
                        let before = Dictionary(uniqueKeysWithValues: priorReport.projects.map { (priorScan.url(for: $0.id).path, $0.allocatedBytes) })
                        for project in report.projects {
                            try Task.checkCancellation()
                            if let previous = before[result.url(for: project.id).path] { growth[project.id] = project.allocatedBytes - previous }
                        }
                    }
                    let findingIndex = Dictionary(uniqueKeysWithValues: report.findings.map { ($0.id, $0) })
                    let projectNames = Dictionary(uniqueKeysWithValues: report.projects.map { ($0.id, $0.name) })
                    return (quick.sorted, apps, fileCount, groups, report, growth, findingIndex, projectNames)
                }
                let summary = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }

                try Task.checkCancellation()
                if self.scan?.rootPath == result.rootPath {
                    previousDeveloperGroups = developerGroups; previousDeveloperDate = self.scan?.started
                } else { previousDeveloperGroups = nil; previousDeveloperDate = nil }
                developerGroups = summary.3
                developerReport = summary.4
                projectGrowth = summary.5
                reportFindingsByID = summary.6; reportProjectNames = summary.7
                let summaryTime = summaryStart.duration(to: clock.now).components
                insightsElapsed = Double(summaryTime.seconds) + Double(summaryTime.attoseconds) / 1e18
                let readyTime = analysisStart.duration(to: clock.now).components
                analysisElapsed = Double(readyTime.seconds) + Double(readyTime.attoseconds) / 1e18
                didPublish = true
                if result.nodes.count > 1 || result.skipped == 0 { cleanupRefreshPaths.removeAll { $0 == result.rootPath } }
                self.scan = result; exclusionResultsStale = false; quickWinNodes = summary.0; appNodes = summary.1; fileCount = summary.2; focus = 0; selected = nil
                // A manual scan must land on results, even when launched from credits or another utility page.
                if let destination {
                    if destination == .explore { openStorage(.explore) }
                    else { workspace = destination }
                } else { openStorage(.explore) }
                snapshotNotice = nil
                progress = "\(fileCount.formatted()) files · \(SpeedFormat.duration(result.elapsed)) scan · \(result.skipped) skipped"
            } catch is CancellationError { if scanVersion == version { progress = scan == nil ? "Scan cancelled · Choose a disk or folder to try again" : "Scan cancelled · Showing previous results" } }
            catch { if scanVersion == version { message = error.localizedDescription; progress = scan == nil ? "Scan failed · Choose another disk or folder" : "Scan failed · Showing previous results" } }
            guard scanVersion == version else { return }
            liveProgress = nil; busy = false
        }
    }
    private func sampleMemory() {
        if let rss = ProcessMemory.residentBytes() { scanPeakRSS = max(scanPeakRSS ?? 0, rss) }
    }
    func cancel() {
        task?.cancel()
        if activeScanVersion != nil {
            // A filesystem access request can wait inside macOS. Detach its UI
            // immediately; a cancelled scan can never publish later results.
            scanVersion = UUID(); activeScanVersion = nil
            memoryTask?.cancel(); memoryTask = nil
            scanPeakRSS = priorScanPeakRSS
            liveProgress = nil; busy = false
            progress = scan == nil ? "Scan cancelled · Choose a folder to grant access" : "Scan cancelled · Showing previous results"
        }
    }
    func open(_ n: DiskNode) { selected = n.id; if n.isDirectory { focus = n.id; search = "" } }
    func goUp() { guard let scan else { return }; focus = scan.nodes[focus].parent ?? 0; selected = nil }
    func reveal(_ id: Int) { if let scan { NSWorkspace.shared.activateFileViewerSelecting([scan.url(for: id)]) } }
    func copyPath(_ id: Int) { if let scan { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(scan.url(for: id).path, forType: .string) } }
    func copyFolderPrompt(_ id: Int) {
        guard let scan, scan.nodes.indices.contains(id) else { return }
        let node = scan.nodes[id]
        guard node.isDirectory else { return }
        let prompt = """
        Help me understand this folder on my Mac before I change anything.

        Folder: \(scan.url(for: id).path)
        storagedaddy measured:
        - On disk: \(DiskFormat.bytes(node.allocatedBytes))
        - Logical size: \(DiskFormat.bytes(node.logicalBytes))
        - Immediate items: \(node.children.count.formatted())
        - Modified: \(node.modified.formatted(date: .abbreviated, time: .shortened))

        Explain:
        1. What usually creates and uses this folder.
        2. Whether it is normally safe to remove or clean.
        3. What could stop working or need to be downloaded or rebuilt afterward.
        4. The safest way to reduce its size.
        5. What I should inspect before acting.

        Do not delete or modify anything. If the path is app-specific or ambiguous, say what evidence would confirm it.
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        progress = "Copied a folder-explanation prompt · Paste it into your AI assistant"
    }
    func openConversationArchive(provider: ConversationArchiveModel.Provider = .all) {
        if !conversationArchive.busy { conversationArchive.provider = provider }
        aiSessionsSection = .archive
        showCleanup = false
        workspace = .aiSessions
    }
    func sessionProvider(for id: Int) -> ConversationArchiveModel.Provider? {
        for group in developerGroups where group.rootIDs.contains(id) {
            if group.category == .codexSessions { return .codex }
            if group.category == .claudeSessions { return .claude }
        }
        return nil
    }
    func stage(_ id: Int) {
        guard let scan, !busy, !monitoring, scan.nodes.indices.contains(id) else { return }
        if let provider = sessionProvider(for: id) {
            let alert = NSAlert()
            alert.messageText = "Keep the conversation before cleaning up?"
            alert.informativeText = "Archive older conversations to keep prompts and replies in a compact export. Tool output and other session data are omitted, so it cannot restore a resumable session. Exporting alone does not free space."
            alert.addButton(withTitle: "Archive Conversations…")
            alert.addButton(withTitle: "Review for Cleanup")
            alert.addButton(withTitle: "Cancel")
            let choice = alert.runModal()
            if choice == .alertFirstButtonReturn { openConversationArchive(provider: provider); return }
            guard choice == .alertSecondButtonReturn else { return }
        }
        let version = scanVersion
        busy = true
        progress = "Checking \(StorageLabels.name(scan.nodes[id]))…"
        task = Task {
            defer { busy = false }
            do {
                var acknowledgement: CleanupIncompleteReview?
                do {
                    try await CleanupPreflight.validate(ids: [id], in: scan, excludedFolders: excludedFolders)
                } catch let CleanupPreflightError.incompleteRescan(_, review) {
                    try Task.checkCancellation()
                    guard scanVersion == version else { return }
                    guard review.canAcknowledge else { throw CleanupPreflightError.incompleteRescan(path: scan.url(for: id).path, review: review) }
                    guard showIncompleteReview(review, name: StorageLabels.name(scan.nodes[id]), allowsOverride: true) else {
                        progress = "Nothing added · Keep exploring"
                        return
                    }
                    try await CleanupPreflight.validate(ids: [id], in: scan, acknowledgedIncomplete: [id: review], excludedFolders: excludedFolders)
                    acknowledgement = review
                }
                try Task.checkCancellation()
                guard scanVersion == version else { return }
                let path = scan.url(for: id).path
                for other in Array(staged) where other != id {
                    let otherPath = scan.url(for: other).path
                    if path.hasPrefix(otherPath + "/") {
                        throw NSError(domain: "Cleanup", code: 1, userInfo: [NSLocalizedDescriptionKey: "A parent folder is already in your cleanup list."])
                    }
                    if otherPath.hasPrefix(path + "/") { unstage(other) }
                }
                staged.insert(id)
                incompleteCleanup[id] = acknowledgement
                progress = "Added \(StorageLabels.name(scan.nodes[id])) to Cleanup · Nothing moved yet"
            } catch is CancellationError {
                progress = "Check cancelled · Nothing added"
            } catch {
                message = "Could not add \(StorageLabels.name(scan.nodes[id])) to cleanup. \(error.localizedDescription)"
                progress = "Item needs attention · Nothing added"
            }
        }
    }
    var suggestedCacheIDs: [Int] {
        guard let scan else { return [] }
        return (developerReport?.findings ?? []).filter {
            scan.nodes.indices.contains($0.id) && !staged.contains($0.id)
                && CleanupGuidance.isSuggestedCache(category: $0.category, path: scan.url(for: $0.id).path)
        }.map(\.id)
    }

    func stageSuggestedCaches() {
        guard let scan, !busy, !monitoring else { return }
        let ids = suggestedCacheIDs
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Add \(ids.count) cache folders for review?"
        alert.informativeText = "Package tools usually download these contents again. Stop active installs and builds first. This does not check whether a tool is using them. Incomplete or changed folders will be skipped. Nothing moves until you review the list and confirm Move to Trash."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Add for Review")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let version = scanVersion
        busy = true
        task = Task {
            defer { busy = false }
            var added = 0
            var skipped: [String] = []
            for id in ids {
                do {
                    try Task.checkCancellation()
                    guard scanVersion == version else { return }
                    let path = scan.url(for: id).path
                    if staged.contains(where: { let parent = scan.url(for: $0).path; return path == parent || path.hasPrefix(parent + "/") }) { continue }
                    progress = "Checking \(StorageLabels.name(scan.nodes[id]))…"
                    try await CleanupPreflight.validate(ids: [id], in: scan, excludedFolders: excludedFolders)
                    try Task.checkCancellation()
                    guard scanVersion == version else { return }
                    for other in Array(staged) where scan.url(for: other).path.hasPrefix(path + "/") { unstage(other) }
                    staged.insert(id)
                    added += 1
                } catch is CancellationError {
                    progress = "Check cancelled · \(added) added for review · Nothing moved"
                    return
                } catch {
                    skipped.append(StorageLabels.name(scan.nodes[id]))
                }
            }
            progress = "\(added) added for review · \(skipped.count) skipped · Nothing moved"
            if !skipped.isEmpty {
                message = "Added \(added) cache folders for review. Could not fully verify: \(skipped.joined(separator: ", ")). Inspect these individually in Explore. Nothing was moved."
            }
        }
    }

    func cleanupCategory(_ id: Int) -> DeveloperCategory? {
        developerReport?.findings.first(where: { $0.id == id })?.category
    }

    func unstage(_ id: Int) {
        staged.remove(id)
        incompleteCleanup.removeValue(forKey: id)
    }

    func reviewIncompleteCleanup(_ id: Int) {
        guard let review = incompleteCleanup[id], let scan, scan.nodes.indices.contains(id) else { return }
        _ = showIncompleteReview(review, name: StorageLabels.name(scan.nodes[id]), allowsOverride: false)
    }

    private func showIncompleteReview(_ review: CleanupIncompleteReview, name: String, allowsOverride: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(name) couldn’t be fully checked"
        alert.informativeText = "\(review.skipped) unreadable or excluded \(review.skipped == 1 ? "item was" : "items were") skipped. Adding this folder includes those contents, which may contain important data. The displayed size may be incomplete.\n\nNothing moves now. Moving to Trash requires a separate confirmation, and unverified contents will move with the folder."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 12)
        text.textColor = .labelColor
        text.string = review.details.joined(separator: "\n\n")
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: allowsOverride ? "Cancel" : "Done")
        if allowsOverride { alert.addButton(withTitle: "Add Anyway") }
        return alert.runModal() == .alertSecondButtonReturn
    }

    func trashStaged() {
        guard let scan, !busy, !monitoring, !staged.isEmpty else { return }
        let ids = staged.sorted()
        let version = scanVersion
        let acknowledgements = incompleteCleanup.filter { staged.contains($0.key) }
        let alert = NSAlert()
        alert.messageText = "Move \(ids.count) \(ids.count == 1 ? "item" : "items") to Trash?"
        alert.informativeText = "Entire folders and their contents are included. Developer categories are descriptions, not recommendations to delete. Active environments, models and container volumes may be needed by your tools. We will check for changes again after you confirm."
        if !acknowledgements.isEmpty {
            let names = acknowledgements.keys.sorted().map { StorageLabels.name(scan.nodes[$0]) }.joined(separator: ", ")
            alert.informativeText += "\n\nAdded with an incomplete-check override: \(names). Their unreadable or excluded contents WILL also move to Trash. Those contents have not been verified."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Move to Trash")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true; progress = "Checking cleanup candidates…"
        task = Task {
            defer { busy = false }
            do {
                // Confirmation can remain open indefinitely. Rescan afterward,
                // using exactly the candidates that the user approved.
                try await CleanupPreflight.validate(ids: ids, in: scan, acknowledgedIncomplete: acknowledgements, excludedFolders: excludedFolders)
                try Task.checkCancellation()
                guard scanVersion == version, staged == Set(ids) else {
                    throw NSError(domain: "Cleanup", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selection changed. Review it again."])
                }
                var moved = 0
                lastTrashedURLs = []
                do {
                    for id in ids {
                        try Task.checkCancellation()
                        let url = scan.url(for: id)
                        if FolderExclusions(paths: excludedFolders).blocksCleanup(url) {
                            throw CleanupPreflightError.excludedFolder(url.path)
                        }
                        try CleanupSafety.validate(url: url, expected: scan.nodes[id], root: URL(fileURLWithPath: scan.rootPath))
                        var trashedURL: NSURL?
                        try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
                        if !cleanupRefreshPaths.contains(scan.rootPath) { cleanupRefreshPaths.append(scan.rootPath) }
                        if let trashedURL { lastTrashedURLs.append(trashedURL as URL) }
                        unstage(id); moved += 1
                    }
                } catch {
                    if moved > 0 { requestAISessionsRefresh() }
                    message = "Stopped after moving \(moved) items to Trash. \(error.localizedDescription)"
                    progress = "Cleanup stopped · Rescan to refresh totals"
                    return
                }
                requestAISessionsRefresh()
                showCleanup = false
                openStorage(.cleanup)
                progress = "Cleanup complete · Rescan to refresh totals"
            } catch {
                message = "Nothing moved: \(error.localizedDescription)"; progress = "Cleanup stopped"
            }
        }
    }
    var snapshotAlreadySaved: Bool {
        guard let scan else { return false }
        return lastSavedSnapshotStarted == scan.started
    }

    func saveSnapshot() {
        guard let scan, !busy, !snapshotBusy, !snapshotAlreadySaved else { return }
        let directory = snapshotDirectory
        snapshotBusy = true
        snapshotNotice = nil
        Task {
            defer { snapshotBusy = false }
            do {
                let saved = try await Task.detached(priority: .utility) {
                    try SnapshotHistoryStore.save(scan: scan, directory: directory)
                }.value
                lastSavedSnapshotStarted = saved.scan.started
                // Saving a completed scan never changes the selected workspace.
                snapshotNotice = "Snapshot saved to History"
                await refreshSnapshotHistory()
            } catch {
                snapshotNotice = "Couldn’t save this snapshot. Try again."
            }
        }
    }

    func refreshSnapshotHistory() async {
        let request = UUID()
        snapshotHistoryGeneration = request
        snapshotHistoryLoading = true
        let directory = snapshotDirectory
        defer { if snapshotHistoryGeneration == request { snapshotHistoryLoading = false } }
        do {
            let listing = try await Task.detached(priority: .utility) {
                try SnapshotHistoryStore.load(directory: directory)
            }.value
            guard snapshotHistoryGeneration == request else { return }
            savedSnapshots = listing.snapshots
            var warnings: [String] = []
            if listing.unreadableCount > 0 { warnings.append("\(listing.unreadableCount) saved snapshots couldn’t be read.") }
            if listing.limitReached { warnings.append("The saved-history display limit was reached.") }
            snapshotHistoryWarning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        } catch {
            guard snapshotHistoryGeneration == request else { return }
            snapshotHistoryWarning = "Couldn’t load saved history. Try refreshing. Your saved files remain on this Mac."
        }
    }
}
