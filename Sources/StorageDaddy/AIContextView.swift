import SwiftUI
import DiskCore

struct AIContextBetaBadge: View {
    var body: some View {
        Text("Beta")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Tints.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(Capsule().stroke(Tints.mint.opacity(0.25)))
            .fixedSize()
    }
}

private struct SkillPreview: Identifiable {
    let id = UUID()
    let item: AIContextItem
    let document: SkillDocument?
    let error: String?
    let loading: Bool
}

@MainActor final class AIContextModel: ObservableObject {
    @Published var inventory: [AIContextItem] = []
    @Published var report: AIContextDiscoveryReport?
    @Published var projects: [AIContextProject] = []
    @Published var errorMessage: String?
    @Published var extraRoots: [String] = UserDefaults.standard.stringArray(forKey: "aiContextSearchRoots") ?? [] {
        didSet { UserDefaults.standard.set(extraRoots, forKey: "aiContextSearchRoots") }
    }
    @Published var loading = false
    @Published var loadStarted = Date()
    @Published var status = ""

    private var generation = UUID()

    func load() async {
        let request = UUID()
        generation = request
        loading = true
        loadStarted = Date()
        errorMessage = nil
        status = "Reading local context metadata…"
        defer { if generation == request { loading = false } }
        let roots = extraRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let worker = Task.detached(priority: .utility) {
            let report = try AIContextDiscovery.discover(scan: nil, configuration: .init(additionalRoots: roots))
            return (report, AIContextProjectCatalog.projects(from: report))
        }
        do {
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard generation == request else { return }
            report = result.0; inventory = result.0.items; projects = result.1
            status = "\(projects.count.formatted()) projects · \(inventory.count.formatted()) file locations · \(String(format: "%.1f", result.0.elapsed)) s"
        } catch {
            guard generation == request else { return }
            if Task.isCancelled {
                status = "Context discovery paused"
            } else {
                errorMessage = "storagedaddy couldn’t finish checking agent context. Review coverage or try again."
                status = "Context discovery needs attention"
            }
        }
    }
}

enum AIContextSection: String, CaseIterable { case folders = "Projects", skills = "Global Skills" }

struct AIContextView: View {
    @EnvironmentObject private var m: ExplorerModel
    @StateObject private var model = AIContextModel()
    @State private var filter = ""
    @State private var providerFilter = "All"
    @State private var kindFilter = "All"
    @State private var skillPreview: SkillPreview?
    @State private var previewRequestID = UUID()
    @State private var refreshID = UUID()
    @State private var showCoverage = false
    @State private var expandedGroups: Set<String> = []
    @State private var sourcePage = 0
    @State private var fileSort = AIContextFileSort.name
    @State private var fileAscending = true

    private var query: String { filter.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasContextFilters: Bool { !query.isEmpty || providerFilter != "All" || kindFilter != "All" }
    private func clearFilters() { filter = ""; providerFilter = "All"; kindFilter = "All" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Text("AI Context").font(.largeTitle.weight(.semibold))
                            AIContextBetaBadge()
                        }
                        Text("Know what your agents carry.").foregroundStyle(Tints.secondaryText)
                    }
                    DoodleArt(topic: .agents).frame(width: 100, height: 100)
                    Spacer()

                    Button("Add Folder…", systemImage: "folder.badge.plus") { addSearchFolder() }.disabled(model.loading)
                    Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }.disabled(model.loading)
                }
                if !model.loading { Text(model.status).font(.caption).foregroundStyle(Tints.secondaryText) }
                HStack(spacing: 10) {
                    ForEach(AIContextSection.allCases, id: \.self) { item in
                        Button(item.rawValue) { m.aiContextSection = item }.buttonStyle(StorageButtonStyle(prominent: m.aiContextSection == item))
                    }
                    Spacer()
                    TextField(m.aiContextSection == .skills ? "Search shared skills or files" : "Search projects, agents or locations", text: $filter).textFieldStyle(.plain)
                        .padding(8).frame(minWidth: 120, maxWidth: 220)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tints.mint.opacity(0.4)))
                        .accessibilityLabel("Search AI context")
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("Clear context search")
                    }
                }
                if let error = model.errorMessage {
                    Label((model.report == nil ? "" : "Refresh failed. Showing the previous inventory. ") + error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Tints.yellow)
                }
                if let report = model.report,
                   report.coverage.isPartial {
                    HStack(spacing: 10) {
                        Label("Some locations could not be fully checked", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Tints.yellow)
                        Button("View coverage") { showCoverage = true }.font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Tints.yellow.opacity(0.25)))
                }
                if model.loading {
                    discoveryProgress
                }
                if model.report != nil || !model.loading {
                switch m.aiContextSection {
                case .folders:
                    AIContextFoldersView(projects: model.projects, rankings: model.report?.folderRankings ?? [], loading: model.loading, error: model.errorMessage,
                                         filter: query, retry: { refreshID = UUID() },
                                         openGlobals: { m.aiContextSection = .skills; filter = "" }, openPreview: openPreview)
                case .skills: contextFiles
                }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .background(Color.black).buttonStyle(StorageButtonStyle())
        .task(id: refreshID) { await model.load() }
        .onChange(of: contextGroups.map(\.source)) { _, _ in sourcePage = 0; expandedGroups = [] }
        .onChange(of: filter) { _, _ in sourcePage = 0; expandedGroups = [] }
        .onChange(of: model.inventory) { _, _ in sourcePage = 0; expandedGroups = [] }
        .sheet(isPresented: $showCoverage) { coverageSheet }
        .sheet(item: $skillPreview, onDismiss: { previewRequestID = UUID() }) { preview in
            SkillPreviewSheet(preview: preview)
        }
    }

    private var discoveryProgress: some View {
        HStack(alignment: .center, spacing: 18) {
            ProgressView().controlSize(.regular).tint(Tints.mint)
            VStack(alignment: .leading, spacing: 7) {
                Text(model.report == nil ? "Finding your skills & agent files" : "Refreshing your context inventory")
                    .font(.headline)
                Text(model.report == nil
                     ? "Checking personal skills, project instructions and installed Claude & Codex plugins."
                     : "Your previous results stay available while we check for changes.")
                    .foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
                Text("Local file metadata only. No AI calls or uploads.")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
            }
            Spacer(minLength: 0)
            TimelineView(.periodic(from: model.loadStarted, by: 1)) { timeline in
                Text("\(max(0, Int(timeline.date.timeIntervalSince(model.loadStarted)))) s")
                    .font(.callout.monospacedDigit()).foregroundStyle(Tints.secondaryText)
                    .accessibilityLabel("Discovery elapsed time")
            }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Tints.mint.opacity(0.3)))
        .accessibilityElement(children: .combine)
    }

    private var contextFiles: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shared across your projects").font(.title2.bold())
            Text("Personal skills, global instructions and installed plugins live here once. Cached plugins may include multiple versions; finding a file does not prove an agent loads it.")
                .foregroundStyle(Tints.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Menu("Provider: \(providerFilter)") {
                    Button("All") { providerFilter = "All" }
                    ForEach(AIContextProvider.allCases, id: \.self) { provider in
                        Button(provider.rawValue) { providerFilter = provider.rawValue }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
                Menu("Kind: \(kindFilter)") {
                    Button("All") { kindFilter = "All" }
                    ForEach(AIContextKind.allCases, id: \.self) { kind in
                        Button(kind.rawValue) { kindFilter = kind.rawValue }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            AIContextFileSortControls(sort: $fileSort, ascending: $fileAscending)
            let rows = filteredContextItems
            let groups = contextGroups
            let uniqueSkills = Set(rows.filter { $0.kind == .skill }.map { $0.resolvedPath ?? $0.path }).count
            let uniqueAgents = Set(rows.filter { $0.kind == .agentDefinition }.map { $0.resolvedPath ?? $0.path }).count
            HStack(spacing: 12) {
                Text("\(rows.count.formatted()) file locations · \(uniqueSkills.formatted()) unique skill files · \(uniqueAgents.formatted()) agent definitions")
                    .help("Linked copies remain visible under each source. Unique counts remove links to the same file; cached versions remain separate. These counts do not prove activation.")
                    .font(.caption).foregroundStyle(Tints.secondaryText)
                Spacer()
                if hasContextFilters { Button("Clear filters", action: clearFilters).font(.caption) }

            }
            if rows.isEmpty {
                StorageEmptyView(model.loading ? "Finding context files…" : "No matching context files", systemImage: "doc.text.magnifyingglass",
                                 description: Text(hasContextFilters ? "Clear the filters or try another skill name." : "No shared skills or agent files were found in the standard locations. Project-local context appears under Projects."))
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(groups.dropFirst(sourcePage * 8).prefix(8)), id: \.source) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                if expandedGroups.contains(group.source) { expandedGroups.remove(group.source) }
                                else { expandedGroups = [group.source] }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: expandedGroups.contains(group.source) ? "chevron.down" : "chevron.right")
                                        .font(.caption.weight(.semibold)).frame(width: 14).foregroundStyle(Tints.mint)
                                    Text(group.source).font(.headline).foregroundStyle(.white)
                                    Spacer()
                                    Text("\(group.items.count) \(group.items.count == 1 ? "file" : "files")").font(.caption).foregroundStyle(Tints.secondaryText)
                                    Text(DiskFormat.bytes(group.items.reduce(0) { $0 + $1.logicalBytes }))
                                        .font(.caption).monospacedDigit().foregroundStyle(Tints.secondaryText)
                                }.padding(12).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("\(expandedGroups.contains(group.source) ? "Collapse" : "Expand") \(group.source), \(group.items.count) \(group.items.count == 1 ? "file" : "files")")
                            if expandedGroups.contains(group.source) {
                                AIContextSourceItems(items: group.items, row: contextRow)
                                    .padding(.horizontal, 12)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tints.mint.opacity(0.22)))
                    }
                }
            }
            if !groups.isEmpty {
                AIContextPagination(page: $sourcePage, total: groups.count, pageSize: 8, noun: "sources")
                    .onChange(of: sourcePage) { _, _ in expandedGroups = [] }
            }
            Button("Discovery coverage and limits", systemImage: "info.circle") { showCoverage = true }
                .font(.caption)
        }
    }

    private func addSearchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose project folders to include in context discovery. No storage scan or cleanup is started."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !model.extraRoots.contains(url.path) { model.extraRoots.append(url.path) }
        refreshID = UUID()
    }

    private var coverageSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Discovery coverage").font(.title2.bold()); Spacer(); Button("Done") { showCoverage = false } }
            Text("Searches known agent locations and common project folders automatically. Add Folder includes other locations. This is an inventory of potential context, not a capture of a live agent prompt.").foregroundStyle(Tints.secondaryText)
            if let report = model.report {
                Text("\(report.coverage.visitedEntries.formatted()) entries checked · \(report.coverage.unreadableCount) unreadable · \(report.coverage.skippedLinks) links skipped")
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(report.coverage.roots, id: \.self) { Text(StorageLabels.location($0)).textSelection(.enabled) }
                        ForEach(report.coverage.limitReasons, id: \.self) { Text($0).foregroundStyle(Tints.yellow) }
                        ForEach(report.coverage.notes, id: \.self) { Text($0).foregroundStyle(Tints.secondaryText) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !model.extraRoots.isEmpty {
                Text("Added folders").font(.headline)
                ForEach(model.extraRoots, id: \.self) { path in
                    HStack { Text(StorageLabels.location(path)).lineLimit(1).truncationMode(.middle); Spacer(); Button("Remove") { model.extraRoots.removeAll { $0 == path }; refreshID = UUID() } }
                }
            }
            Text("No configuration bodies, credentials or session messages are read by this inventory. Plugin activation, imports and custom agent settings may change actual context.").font(.caption).foregroundStyle(Tints.secondaryText)
        }.padding(24).frame(width: 680, height: 520).background(Color.black).buttonStyle(StorageButtonStyle())
    }

    private var filteredContextItems: [AIContextItem] {
        model.inventory.filter {
            $0.scope == .global &&
            (providerFilter == "All" || $0.provider.rawValue == providerFilter) &&
            (kindFilter == "All" || $0.kind.rawValue == kindFilter) &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) || $0.source.localizedCaseInsensitiveContains(query) || $0.provider.rawValue.localizedCaseInsensitiveContains(query) || $0.kind.rawValue.localizedCaseInsensitiveContains(query))
        }
    }

    private var contextGroups: [(source: String, items: [AIContextItem])] {
        Dictionary(grouping: filteredContextItems, by: \.source)
            .map { (source: $0.key, items: AIContextFileSort.sorted($0.value, by: fileSort, ascending: fileAscending)) }
            .sorted { $0.source.localizedStandardCompare($1.source) == .orderedAscending }
    }

    @ViewBuilder private func contextRow(_ item: AIContextItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == .skill ? "sparkles.square.fill" : "doc.text.fill").foregroundStyle(Tints.electricBlue)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(item.name).fontWeight(.semibold)
                    if item.applicability == .installedOnly {
                        Text("Installed only").font(.caption2).foregroundStyle(Tints.secondaryText)
                    }
                    if let resolved = item.resolvedPath, resolved != item.path {
                        Image(systemName: "link").font(.caption2).help("Linked to " + StorageLabels.location(resolved))
                    }
                }
                Text(StorageLabels.location(item.path)).font(.caption).foregroundStyle(Tints.secondaryText).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(item.provider.rawValue + " · " + item.kind.rawValue).font(.caption).foregroundStyle(Tints.secondaryText)
            Text(DiskFormat.bytes(item.logicalBytes)).monospacedDigit().frame(width: 85, alignment: .trailing)
            if item.kind != .mcpConfig {
                Button("View") { openPreview(item) }
                    .accessibilityLabel("View \(item.name)")
                    .buttonStyle(StorageButtonStyle())
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } label: { Image(systemName: "arrow.up.forward.square") }
                .accessibilityLabel("Reveal \(item.name) in Finder")
                .help("Reveal in Finder")
        }.padding(.vertical, 10)
        Divider().overlay(Tints.mint.opacity(0.15))
    }

    private func openPreview(_ item: AIContextItem) {
        guard item.kind != .mcpConfig else { return }
        let requestID = UUID()
        previewRequestID = requestID
        skillPreview = SkillPreview(item: item, document: nil, error: nil, loading: true)
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                Result { try SkillDocumentReader.read(url: URL(fileURLWithPath: item.resolvedPath ?? item.path), documentKind: item.kind) }
            }.value
            guard previewRequestID == requestID else { return }
            switch result {
            case .success(let document):
                skillPreview = SkillPreview(item: item, document: document, error: nil, loading: false)
            case .failure(let error):
                skillPreview = SkillPreview(item: item, document: nil, error: (error as? LocalizedError)?.errorDescription ?? "Unable to read this file.", loading: false)
            }
        }
    }
}

private struct SkillPreviewSheet: View {
    let preview: SkillPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.item.name).font(.title2.weight(.semibold))
                    Text(preview.item.source + " · " + preview.item.kind.rawValue).font(.caption).foregroundStyle(Tints.secondaryText)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(StorageButtonStyle(prominent: true))
            }
            Text(StorageLabels.location(preview.item.path)).font(.caption).foregroundStyle(Tints.secondaryText).textSelection(.enabled)
            if let resolved = preview.item.resolvedPath, resolved != preview.item.path {
                Text("Linked source: " + StorageLabels.location(resolved)).font(.caption).foregroundStyle(Tints.mint).textSelection(.enabled)
            }
            if preview.loading {
                ProgressView("Reading selected text…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = preview.error {
                StorageEmptyView(error, systemImage: "exclamationmark.triangle")
            } else if let document = preview.document {
                if document.text.isEmpty {
                    StorageEmptyView("This file is empty", systemImage: "doc.text")
                } else if document.truncated {
                    Text("Preview truncated at 256 KiB.").font(.caption).foregroundStyle(Tints.yellow)
                }
                if !document.text.isEmpty {
                    ScrollView {
                        Text(document.text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }.background(Color.black).overlay(RoundedRectangle(cornerRadius: 8).stroke(Tints.mint.opacity(0.22)))
                }
            }
        }.padding(22).frame(minWidth: 720, minHeight: 520).background(Color.black).foregroundStyle(.white)
    }
}
