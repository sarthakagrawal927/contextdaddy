import SwiftUI
import DiskCore

private enum ProjectContextSort: String, CaseIterable {
    case name = "Name"
    case sources = "Files"
    case size = "Context size"
}

struct AIContextFoldersView: View {
    let projects: [AIContextProject]
    let rankings: [AIContextFolderRanking]
    let loading: Bool
    let error: String?
    let filter: String
    let retry: () -> Void
    let openGlobals: () -> Void
    let openPreview: (AIContextItem) -> Void
    @State private var provider = "All agents"
    @State private var sort = ProjectContextSort.sources
    @State private var ascending = false
    @State private var selected: String?
    @State private var page = 0

    private var rows: [AIContextProject] {
        projects.filter { project in
            let agentMatches = provider == "All agents" || project.providers.contains { $0.rawValue == provider }
            let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
            let textMatches = query.isEmpty || project.path.localizedCaseInsensitiveContains(query)
                || project.providers.contains { $0.rawValue.localizedCaseInsensitiveContains(query) }
                || project.locations.contains { location in
                    location.path.localizedCaseInsensitiveContains(query)
                    || location.items.contains { $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
                }
            return agentMatches && textMatches
        }.sorted { a, b in
            let comparison: ComparisonResult
            switch sort {
            case .name: comparison = a.name.localizedStandardCompare(b.name)
            case .sources: comparison = compare(Int64(a.projectItemCount), Int64(b.projectItemCount))
            case .size: comparison = compare(a.projectLogicalBytes, b.projectLogicalBytes)
            }
            if comparison == .orderedSame { return a.path < b.path }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
                Text("Each project has its own context").font(.title2.bold())
                Text("See where instructions, rules, skills and agent files live. Only projects with their own context files appear here.")
                    .foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Image(systemName: "globe").foregroundStyle(Tints.mint)
                    Text("Global sources are shared, so we list them once.")
                        .font(.callout).foregroundStyle(Tints.secondaryText)
                    Spacer()
                    Button("Global Skills", action: openGlobals)
                }.padding(12).overlay(RoundedRectangle(cornerRadius: 10).stroke(Tints.mint.opacity(0.22)))
                HStack(spacing: 10) {
                    Menu("Agent: \(provider)") {
                        Button("All agents") { provider = "All agents" }
                        ForEach(AIContextProvider.allCases.filter { $0 != .project }, id: \.self) { agent in
                            Button(agent.rawValue) { provider = agent.rawValue }
                        }
                    }.fixedSize()
                    Menu("Sort: \(sort.rawValue)") {
                        ForEach(ProjectContextSort.allCases, id: \.self) { key in
                            Button(key.rawValue) { sort = key; ascending = key == .name }
                        }
                    }.fixedSize()
                    Button(ascending ? "Ascending" : "Descending", systemImage: ascending ? "arrow.up" : "arrow.down") { ascending.toggle() }
                    Spacer(minLength: 0)
                    Text("\(rows.count.formatted()) projects").font(.caption).foregroundStyle(Tints.secondaryText)
                }
                if let error, projects.isEmpty, !loading {
                    Text(error).foregroundStyle(Tints.yellow)
                    Button("Try Again", action: retry)
                } else if rows.isEmpty {
                    Text(loading ? "Finding project context…" : "No matching project context. Add a project folder or clear your filters.")
                        .foregroundStyle(Tints.secondaryText).padding(.vertical, 20)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.dropFirst(page * 10).prefix(10))) { project in
                            Button { selected = selected == project.id ? nil : project.id } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "folder.fill").foregroundStyle(Tints.mint)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(project.name).font(.headline).foregroundStyle(.white)
                                        Text(StorageLabels.location(project.path)).font(.caption).foregroundStyle(Tints.secondaryText)
                                            .lineLimit(1).truncationMode(.middle)
                                        Text(project.providers.map(\.rawValue).joined(separator: " · "))
                                            .font(.caption).foregroundStyle(Tints.mint)
                                    }
                                    Spacer(minLength: 12)
                                    VStack(alignment: .trailing, spacing: 6) {
                                        Text("\(project.projectItemCount.formatted()) project files").fontWeight(.medium)
                                        Text("\(project.locations.filter { $0.scope == .project }.count) locations · \(DiskFormat.bytes(project.projectLogicalBytes)) of text")
                                            .font(.caption).foregroundStyle(Tints.secondaryText)
                                    }
                                    Image(systemName: selected == project.id ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(Tints.mint)
                                }.padding(.vertical, 14).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("\(selected == project.id ? "Collapse" : "Expand") \(project.name)")
                            if selected == project.id {
                                AIContextProjectDetail(project: project,
                                    loads: AIContextProjectCatalog.agentLoads(in: project.path, rankings: rankings),
                                    openGlobals: openGlobals, openPreview: openPreview,
                                    back: { selected = nil })
                                    .padding(16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tints.mint.opacity(0.25)))
                                    .padding(.bottom, 14).id(project.id + "-expanded")
                            }
                            Divider().overlay(Tints.mint.opacity(0.18))
                        }
                    }
                    AIContextPagination(page: $page, total: rows.count, pageSize: 10, noun: "projects")
                }
        }
        .onChange(of: filter) { _, _ in page = 0; selected = nil }
        .onChange(of: provider) { _, _ in page = 0 }
        .onChange(of: sort) { _, _ in page = 0 }
        .onChange(of: ascending) { _, _ in page = 0 }
        .onChange(of: projects.map(\.id)) { _, _ in page = 0 }
        .onChange(of: page) { _, _ in selected = nil }
    }

    private func compare(_ a: Int64, _ b: Int64) -> ComparisonResult {
        a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
    }
}

private struct AIContextProjectDetail: View {
    let project: AIContextProject
    let loads: [AIContextFolderRanking]
    let openGlobals: () -> Void
    let openPreview: (AIContextItem) -> Void
    let back: () -> Void
    @State private var expandedLocation: String?
    @State private var fileSort = AIContextFileSort.name
    @State private var fileAscending = true
    @State private var locationSort = ProjectContextSort.name
    @State private var locationAscending = true
    @State private var page = 0

    private var localLocations: [AIContextProjectLocation] {
        project.locations.filter { $0.scope == .project }.sorted { a, b in
            let comparison: ComparisonResult
            switch locationSort {
            case .name: comparison = a.path.localizedStandardCompare(b.path)
            case .sources: comparison = compare(Int64(a.items.count), Int64(b.items.count))
            case .size: comparison = compare(a.logicalBytes, b.logicalBytes)
            }
            if comparison == .orderedSame { return a.path < b.path }
            return locationAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
    private var inheritedLocations: [AIContextProjectLocation] { project.locations.filter { $0.scope == .inherited } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Context in this directory").font(.title2.weight(.semibold))
                Spacer()
                Button("Collapse", systemImage: "chevron.up", action: back)
            }
            Text(StorageLabels.location(project.path)).foregroundStyle(Tints.secondaryText).textSelection(.enabled)
            AIContextAgentLoadView(loads: loads)
            HStack(spacing: 20) {
                summary("Project files", value: project.projectItemCount.formatted())
                summary("Stored in", value: "\(localLocations.count) locations")
                summary("Context text", value: DiskFormat.bytes(project.projectLogicalBytes))
                Spacer()
            }.padding(.vertical, 8)
            Text("Project files below are grouped by their actual location. Linked files can live elsewhere; these sizes describe documents, not an agent’s loaded prompt.")
                .font(.callout).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Menu("Locations: \(locationSort.rawValue)") {
                    ForEach(ProjectContextSort.allCases, id: \.self) { key in
                        Button(key.rawValue) { locationSort = key; locationAscending = key == .name }
                    }
                }.fixedSize()
                Button(locationAscending ? "Ascending" : "Descending", systemImage: locationAscending ? "arrow.up" : "arrow.down") { locationAscending.toggle() }
                Spacer()
            }
            AIContextFileSortControls(sort: $fileSort, ascending: $fileAscending)
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(localLocations.dropFirst(page * 8).prefix(8))) { location in
                    locationCard(location)
                }
            }
            if !localLocations.isEmpty { AIContextPagination(page: $page, total: localLocations.count, pageSize: 8, noun: "locations") }
            if !inheritedLocations.isEmpty {
                DisclosureGroup("Also inherits from \(inheritedLocations.count) parent locations") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(inheritedLocations) { location in
                            HStack {
                                Image(systemName: "arrow.turn.down.right").foregroundStyle(Tints.mint)
                                Text(StorageLabels.location(location.path)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("\(location.items.count) files").font(.caption).foregroundStyle(Tints.secondaryText)
                            }
                        }
                        Text("Shared parent files are referenced here and excluded from this project’s totals.")
                            .font(.caption).foregroundStyle(Tints.secondaryText)
                    }.padding(.vertical, 10)
                }.tint(Tints.mint)
            }
            HStack {
                Text("Global skills and instructions are shared across projects.").font(.caption).foregroundStyle(Tints.secondaryText)
                Spacer()
                Button("Global Skills", action: openGlobals)
            }.padding(.top, 8)
        }
        .onChange(of: locationSort) { _, _ in page = 0; expandedLocation = nil }
        .onChange(of: locationAscending) { _, _ in page = 0; expandedLocation = nil }
        .onChange(of: page) { _, _ in expandedLocation = nil }
    }

    private func locationCard(_ location: AIContextProjectLocation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expandedLocation = expandedLocation == location.id ? nil : location.id } label: {
                HStack(spacing: 12) {
                    Image(systemName: expandedLocation == location.id ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(Tints.mint).frame(width: 14)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(location.path == project.path ? "Project root" : String(location.path.dropFirst(project.path.count + 1)))
                            .font(.headline).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                        Text(location.providers.map(\.rawValue).joined(separator: " · ") + " · " + location.items.map(\.kind.rawValue).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(Tints.secondaryText).lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text("\(location.items.count.formatted()) files")
                        Text(DiskFormat.bytes(location.logicalBytes)).font(.caption).foregroundStyle(Tints.secondaryText)
                    }
                }.padding(14).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expandedLocation == location.id {
                AIContextSourceItems(items: AIContextFileSort.sorted(location.items, by: fileSort, ascending: fileAscending)) { item in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.kind == .skill ? item.name + " / SKILL.md" : item.name).fontWeight(.medium)
                            Text(item.kind.rawValue + " · " + item.provider.rawValue).font(.caption).foregroundStyle(Tints.secondaryText)
                            if let resolved = item.resolvedPath, resolved != item.path {
                                Label("Linked · " + StorageLabels.location(resolved), systemImage: "link")
                                    .font(.caption).foregroundStyle(Tints.secondaryText).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(DiskFormat.bytes(item.logicalBytes)).monospacedDigit()
                            Text(item.modified.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Tints.secondaryText)
                        }
                        Button("View") { openPreview(item) }.accessibilityLabel("View \(item.name)")
                    }.padding(.vertical, 9)
                }.padding(.horizontal, 14)
            }
        }.overlay(RoundedRectangle(cornerRadius: 12).stroke(Tints.mint.opacity(0.25)))
    }

    private func summary(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.title2.weight(.semibold)).foregroundStyle(Tints.mint)
            Text(title).font(.caption).foregroundStyle(Tints.secondaryText)
        }
    }
    private func compare(_ a: Int64, _ b: Int64) -> ComparisonResult {
        a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
    }
}
