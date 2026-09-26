import ContextCore
import SwiftUI

private enum ProjectSort: String, CaseIterable, Identifiable {
    case name = "Name"
    case files = "Files"
    case size = "Startup estimate"
    var id: String { rawValue }
}

struct ProjectsContextView: View {
    @Environment(ContextDaddyModel.self) private var model
    @State private var search = ""
    @State private var provider = "All agents"
    @State private var sort: ProjectSort = .size
    @State private var ascending = false
    @State private var page = 0
    @State private var selectedProjectID: String?
    @State private var previewItem: AIContextItem?
    private let pageSize = 12

    init(initiallySelectedProjectID: String? = nil) {
        _selectedProjectID = State(initialValue: initiallySelectedProjectID)
    }

    private var rows: [AIContextProject] {
        let grouped = Dictionary(grouping: model.folderRankings, by: \.path)
        let scopedLoads = grouped.mapValues { rankings in
            let loads = AIContextProjectCatalog.agentLoads(in: rankings.first?.path ?? "", rankings: rankings)
            return provider == "All agents" ? loads : loads.filter { $0.provider.rawValue == provider }
        }
        let startupBytes = scopedLoads.mapValues { $0.map(\.instructionBytes).max() ?? 0 }
        return model.projects.filter { project in
            let loads = scopedLoads[project.path] ?? []
            let providerMatch = provider == "All agents" || loads.contains { $0.provider.rawValue == provider }
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let textMatch = query.isEmpty || project.path.localizedCaseInsensitiveContains(query)
                || project.providers.contains { $0.rawValue.localizedCaseInsensitiveContains(query) }
                || project.locations.contains { location in
                    location.path.localizedCaseInsensitiveContains(query)
                    || location.items.contains { $0.name.localizedCaseInsensitiveContains(query) }
                }
            return providerMatch && textMatch
        }.sorted { left, right in
            let comparison: ComparisonResult
            switch sort {
            case .name: comparison = left.name.localizedStandardCompare(right.name)
            case .files: comparison = compare(Int64(left.projectItemCount), Int64(right.projectItemCount))
            case .size: comparison = compare(startupBytes[left.path] ?? 0, startupBytes[right.path] ?? 0)
            }
            if comparison == .orderedSame { return left.path < right.path }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private var visibleRows: [AIContextProject] {
        Array(rows.dropFirst(page * pageSize).prefix(pageSize))
    }

    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(
                eyebrow: "Project context",
                title: "How much context could load in each checked folder?",
                subtitle: "Compare potential startup instructions by folder and agent. Open a folder for global, parent, and local sources; actual prompt loading is not measured.",
                art: .projects
            )
            Panel(padding: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Text(model.discoveryReport == nil ? "—" : model.projects.count.formatted())
                        .font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(DaddyTheme.mint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Folders assessed").font(.subheadline.weight(.semibold))
                        Text("Includes folders that inherit context even when they contain no local files. Filter by agent or sort by startup estimate to find the largest potential loads.")
                            .font(.caption).foregroundStyle(DaddyTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    projectSearch
                    projectFilters
                    Spacer(minLength: 8)
                    projectCount
                }
                VStack(alignment: .leading, spacing: 8) {
                    projectSearch
                    HStack(spacing: 10) {
                        projectFilters
                        Spacer(minLength: 8)
                        projectCount
                    }
                }
            }
            if model.isLoading {
                RefreshContinuityBanner(started: model.loadStarted, hasPreviousResults: model.discoveryReport != nil)
            }
                LazyVStack(spacing: 9) {
                    ForEach(visibleRows) { project in
                        ProjectRow(
                            project: project,
                            loads: visibleLoads(for: project),
                            expanded: selectedProjectID == project.id,
                            toggle: { selectedProjectID = selectedProjectID == project.id ? nil : project.id },
                            preview: { previewItem = $0 }
                        )
                    }
                    if rows.isEmpty {
                        ContentUnavailableView(
                            model.isLoading ? "Finding project context…" : "No matching project context",
                            systemImage: "folder.badge.questionmark",
                            description: Text(model.isLoading ? "Previous results will stay visible during later refreshes." : "Add a folder in Diagnostics or change the filters.")
                        ).padding(.top, 60)
                    }
                }
                .id("project-results")
                ContextPagination(page: $page, total: rows.count, pageSize: pageSize, noun: "projects")
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: page) { _, _ in
            selectedProjectID = nil
            withAnimation(.easeInOut(duration: 0.15)) { scroll.scrollTo("project-results", anchor: .top) }
        }
        }
        .onChange(of: search) { _, _ in resetPage() }
        .onChange(of: provider) { _, _ in resetPage() }
        .onChange(of: sort) { _, _ in resetPage() }
        .onChange(of: ascending) { _, _ in resetPage() }
        .onChange(of: model.projects.count) { _, _ in resetPage() }
        .sheet(item: $previewItem) { ContextDocumentPreviewSheet(item: $0) }
    }

    private func resetPage() { page = 0; selectedProjectID = nil }
    private func compare(_ a: Int64, _ b: Int64) -> ComparisonResult { a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending) }
    private func visibleLoads(for project: AIContextProject) -> [AIContextFolderRanking] {
        let loads = AIContextProjectCatalog.agentLoads(in: project.path, rankings: model.folderRankings)
        return provider == "All agents" ? loads : loads.filter { $0.provider.rawValue == provider }
    }

    private var projectSearch: some View {
        TextField("Search folders, files, or paths", text: $search)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 240, maxWidth: 380)
    }

    private var projectFilters: some View {
        HStack(spacing: 8) {
            ContextChoiceMenu(
                title: "Agent",
                selection: $provider,
                choices: [ContextChoice("All agents", "All agents")]
                    + AIContextProvider.allCases.filter { $0 != .project }.map { ContextChoice($0.rawValue, $0.rawValue) },
                width: 145
            )
            ContextChoiceMenu(
                title: "Sort",
                selection: $sort,
                choices: ProjectSort.allCases.map { ContextChoice($0, $0.rawValue) },
                width: 180
            )
            Button { ascending.toggle() } label: {
                Image(systemName: ascending ? "arrow.up" : "arrow.down")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .background(DaddyTheme.raised, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DaddyTheme.line))
            .help(ascending ? "Ascending" : "Descending")
            .accessibilityLabel(ascending ? "Sort ascending" : "Sort descending")
        }
    }

    private var projectCount: some View {
        Text("\(rows.count.formatted()) matching folders")
            .font(.caption).foregroundStyle(DaddyTheme.muted).fixedSize()
    }
}

private struct ProjectRow: View {
    let project: AIContextProject
    let loads: [AIContextFolderRanking]
    let expanded: Bool
    let toggle: () -> Void
    let preview: (AIContextItem) -> Void

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                Button(action: toggle) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.bold)).foregroundStyle(DaddyTheme.muted).frame(width: 12)
                        Image(systemName: "folder.fill").foregroundStyle(DaddyTheme.mint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.name).font(.headline)
                            Text(project.path).font(.caption2.monospaced()).foregroundStyle(DaddyTheme.muted)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 14) {
                                providerNames
                                projectSize
                            }
                            projectSize
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)

                if expanded {
                    Divider().overlay(DaddyTheme.line)
                    ProjectDetail(project: project, loads: loads, preview: preview)
                }
            }
        }
    }

    private var providerNames: some View {
        Text(project.providers.map(\.rawValue).joined(separator: " · "))
            .font(.caption).foregroundStyle(DaddyTheme.blue).fixedSize()
    }

    private var projectSize: some View {
        let leadingLoad = loads.max { $0.instructionBytes < $1.instructionBytes }
        return VStack(alignment: .trailing, spacing: 3) {
            Text(leadingLoad.map { "≈ \($0.estimatedStartupTokens.formatted()) tokens" } ?? "No estimate")
                .font(.subheadline.weight(.semibold))
            Text(leadingLoad.map { "\($0.provider.rawValue) potential startup" } ?? "No active agent sources found")
                .font(.caption).foregroundStyle(DaddyTheme.muted)
        }
        .fixedSize()
    }
}

private struct ProjectDetail: View {
    let project: AIContextProject
    let loads: [AIContextFolderRanking]
    let preview: (AIContextItem) -> Void
    @State private var expandedLocation: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Potential startup instructions by agent").font(.headline)
            if loads.isEmpty {
                Text("No agent-specific instruction estimate is available for this directory.")
                    .font(.caption).foregroundStyle(DaddyTheme.muted)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                    ForEach(loads) { AgentLoadCard(load: $0) }
                }
            }
            Text("Estimates use four bytes per token. They exclude skill bodies, rules, tools, memory, and conversation history. The scan shows possible instruction inputs, not what an agent actually loaded.")
                .font(.caption2).foregroundStyle(DaddyTheme.muted).fixedSize(horizontal: false, vertical: true)
            Text("Attributed locations").font(.headline)
            ForEach(project.locations) { location in
                VStack(spacing: 0) {
                    Button {
                        expandedLocation = expandedLocation == location.id ? nil : location.id
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: expandedLocation == location.id ? "chevron.down" : "chevron.right")
                                .font(.caption).frame(width: 12)
                            Text(location.scope.rawValue).font(.caption2.weight(.bold)).foregroundStyle(DaddyTheme.color(for: location.scope))
                                .frame(width: 64, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(location.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                Text(location.providers.map(\.rawValue).joined(separator: " · ")).font(.caption2).foregroundStyle(DaddyTheme.muted)
                            }
                            Spacer()
                            Text("\(location.items.count) files").font(.caption)
                        }.padding(.vertical, 9).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if expandedLocation == location.id {
                        Divider().overlay(DaddyTheme.line)
                        ForEach(location.items) { item in
                            ContextFileRow(item: item, preview: preview)
                            if item.id != location.items.last?.id { Divider().overlay(DaddyTheme.line) }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(DaddyTheme.raised.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

private struct AgentLoadCard: View {
    let load: AIContextFolderRanking

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(load.provider.rawValue).font(.subheadline.weight(.semibold))
                Spacer()
                Text(load.pressure.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(DaddyTheme.color(for: load.pressure))
            }
            Text(tokens(load.estimatedStartupTokens))
                .font(.title3.bold()).monospacedDigit().foregroundStyle(DaddyTheme.color(for: load.pressure))
            contribution("Global", load.globalBytes)
            contribution("Parent folders", load.inheritedBytes)
            contribution("This directory", load.localBytes)
            Divider().overlay(DaddyTheme.line)
            HStack { Text("Available skills"); Spacer(); Text(load.skillCount.formatted()).monospacedDigit() }
                .font(.caption).foregroundStyle(DaddyTheme.muted)
            if load.automaticInstructionSourceCount == 0 {
                Text("No startup instruction files found for this agent.")
                    .font(.caption2).foregroundStyle(DaddyTheme.muted)
            } else {
                DisclosureGroup("Show \(load.automaticInstructionSourceCount) instruction files") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(load.sources.filter { $0.item.kind == .instruction && [.global, .inherited, .local].contains($0.origin) }) { source in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(source.origin.rawValue) · \(ByteCountFormatter.string(fromByteCount: source.item.logicalBytes, countStyle: .file))")
                                    .font(.caption2.weight(.semibold)).foregroundStyle(DaddyTheme.mint)
                                Text(source.item.path).font(.caption2.monospaced())
                                    .foregroundStyle(DaddyTheme.muted).textSelection(.enabled)
                            }
                        }
                    }
                }
                .font(.caption2)
            }
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(DaddyTheme.raised).clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private func contribution(_ label: String, _ bytes: Int64) -> some View {
        HStack { Text(label); Spacer(); Text(bytes == 0 ? "0 bytes" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).monospacedDigit() }
            .font(.caption2).foregroundStyle(DaddyTheme.muted)
    }

    private func tokens(_ value: Int) -> String {
        value >= 1_000 ? "≈ \(String(format: "%.1fK", Double(value) / 1_000)) tokens" : "≈ \(value.formatted()) tokens"
    }
}

struct RefreshContinuityBanner: View {
    let started: Date
    let hasPreviousResults: Bool

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(DaddyTheme.mint)
            Text(hasPreviousResults ? "Refreshing · previous results remain available" : "Discovering local agent context")
                .font(.caption.weight(.semibold))
            Spacer()
            TimelineView(.periodic(from: started, by: 1)) { context in
                Text("\(max(0, Int(context.date.timeIntervalSince(started)))) s")
                    .font(.caption.monospacedDigit()).foregroundStyle(DaddyTheme.muted)
            }
        }
        .padding(10).background(DaddyTheme.mint.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private extension DaddyTheme {
    static func color(for scope: AIContextProjectLocationScope) -> Color {
        switch scope {
        case .project: mint
        case .inherited: blue
        case .global: amber
        case .installed: muted
        }
    }
}
