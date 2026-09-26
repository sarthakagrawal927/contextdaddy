import AppKit
import ContextCore
import SwiftUI

/// One row is one physical SKILL.md. Its routes can span agent roots and
/// project folders without creating another physical definition.
struct SharedGlobalSkillsView: View {
    @Environment(ContextDaddyModel.self) private var model
    @State private var search = ""
    @State private var page = 0
    var initiallyExpandsFirst = false
    private let pageSize = 8

    private var placement: SkillPlacementSummary? { model.catalog?.placement }

    private var matches: [SkillRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return placement?.sharedGlobalRecords ?? [] }
        return (placement?.sharedGlobalRecords ?? []).filter { record in
            record.name.localizedCaseInsensitiveContains(query)
                || record.id.localizedCaseInsensitiveContains(query)
                || record.activeExposures.contains { $0.logicalPath.localizedCaseInsensitiveContains(query) }
                || record.exposedRuntimes.contains { $0.rawValue.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Panel(padding: 14) {
                VStack(alignment: .leading, spacing: 11) {
                    Text("Global skill sharing").font(.headline)
                    Text("A global route can be discovered across project folders by its named agents; the invocation rule may still restrict it. One physical SKILL.md can have several links; those links are not duplicate files or proof of use.")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 130), spacing: 10), count: 3), spacing: 10) {
                        fact("Global definitions", placement?.globalCount, DaddyTheme.mint)
                        fact("Across agents", placement?.crossAgentCount, DaddyTheme.blue)
                        fact("Multiple paths", placement?.multiPathCount, DaddyTheme.amber)
                    }
                    Text("Across agents and multiple paths can overlap. Expand a row to see every discovered route and the rule for each agent.")
                        .font(.caption2).foregroundStyle(DaddyTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            TextField("Find a shared global skill, agent, or path", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)

            LazyVStack(spacing: 8) {
                ForEach(Array(matches.dropFirst(page * pageSize).prefix(pageSize).enumerated()), id: \.element.id) { pair in
                    SharedGlobalSkillRow(record: pair.element, expanded: initiallyExpandsFirst && page == 0 && pair.offset == 0)
                }
                if matches.isEmpty {
                    ContentUnavailableView(model.catalog == nil ? "Scanning skills…" : "No matching shared global skills",
                                           systemImage: "link",
                                           description: Text(model.catalog == nil
                                                             ? "The bounded inventory has not finished."
                                                             : "Change the search. A global file with only one agent and one path is not a sharing case."))
                }
            }
            ContextPagination(page: $page, total: matches.count, pageSize: pageSize, noun: "shared global skills")
        }
        .onChange(of: search) { _, _ in page = 0 }
        .onChange(of: matches.count) { _, count in page = min(page, max(0, (count - 1) / pageSize)) }
    }

    private func fact(_ title: String, _ value: Int?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value?.formatted() ?? "—").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(DaddyTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SharedGlobalSkillRow: View {
    let record: SkillRecord
    @State var expanded = false
    @State private var showShare = false

    var body: some View {
        Panel(padding: 13) {
            VStack(alignment: .leading, spacing: 10) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption).foregroundStyle(DaddyTheme.muted)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.name).font(.subheadline.weight(.semibold))
                            Text("Global: " + record.globalRuntimes.map(\.rawValue).joined(separator: " · "))
                                .font(.caption).foregroundStyle(DaddyTheme.blue)
                        }
                        Spacer(minLength: 8)
                        Text("\(record.activePathCount) \(record.activePathCount == 1 ? "path" : "paths")")
                            .font(.caption.monospacedDigit()).foregroundStyle(DaddyTheme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    Divider().overlay(DaddyTheme.line)
                    HStack(alignment: .firstTextBaseline) {
                        Text("One physical file").font(.caption.weight(.semibold))
                        Text((record.id as NSString).abbreviatingWithTildeInPath)
                            .font(.caption.monospaced()).foregroundStyle(DaddyTheme.blue)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button("Copy path", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(record.id, forType: .string)
                        }
                        .font(.caption)
                    }
                    Button("Share with another agent…", systemImage: "link.badge.plus") { showShare = true }
                        .font(.caption).foregroundStyle(DaddyTheme.mint)
                    ForEach(record.activeExposures) { exposure in
                        HStack(alignment: .top, spacing: 9) {
                            Text(exposure.provider.rawValue).font(.caption.weight(.semibold))
                                .frame(width: 58, alignment: .leading)
                            Text(exposure.scope.rawValue).font(.caption2).foregroundStyle(DaddyTheme.mint)
                                .frame(width: 45, alignment: .leading)
                            Text((exposure.logicalPath as NSString).abbreviatingWithTildeInPath)
                                .font(.caption.monospaced()).foregroundStyle(DaddyTheme.muted)
                                .textSelection(.enabled)
                        }
                    }
                    Divider().overlay(DaddyTheme.line)
                    ForEach(record.policies.filter(\.isExposed)) { policy in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(policy.runtime.rawValue).font(.caption.weight(.semibold)).frame(width: 58, alignment: .leading)
                            Text(policy.mode.rawValue).font(.caption).foregroundStyle(DaddyTheme.color(for: policy.mode))
                            Text(policy.explicit ? "Explicit rule" : "Assumed default")
                                .font(.caption2).foregroundStyle(DaddyTheme.muted)
                        }
                    }
                    Text("Auto-invocable means eligible for model invocation. This inventory cannot tell whether a skill body was preloaded or used in a run.")
                        .font(.caption2).foregroundStyle(DaddyTheme.muted)
                }
            }
        }
        .sheet(isPresented: $showShare) { SkillShareSheet(record: record) }
    }
}
