import ContextCore
import SwiftUI

struct SkillsGovernanceView: View {
    @State private var showsRuleDetails = false
    let runtime: AgentRuntime
    let summary: SkillGovernanceSummary?
    let sharing: SkillSharingSummary?
    let selectedFilter: SkillFilter
    let selectFilter: (SkillFilter) -> Void
    let compact: Bool

    var body: some View {
        Panel(padding: compact ? 12 : 18) {
            VStack(alignment: .leading, spacing: compact ? 10 : 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("The short answer").font(.headline)
                        if !compact {
                            Text("These are local definitions \(runtime.rawValue) can discover. Open a count to inspect the exact files and access rules.")
                                .font(.caption).foregroundStyle(DaddyTheme.muted)
                        }
                    }
                    Spacer()
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 150), spacing: 10), count: 3), spacing: 10) {
                    metric(filter: .available, title: "Can discover", value: summary?.exposedCount,
                           detail: "Found in \(runtime.rawValue)'s active scope", color: DaddyTheme.mint, compact: compact)
                    metric(filter: .review, title: "Needs review", value: summary?.reviewCount,
                           detail: summary.map { "\($0.defaultAutomaticCount) use a default rule; inspect others below" } ?? "Waiting for inventory",
                           color: DaddyTheme.amber, compact: compact)
                    metric(filter: .notExposed, title: "Out of scope", value: summary?.notExposedCount,
                           detail: "Present elsewhere; \(runtime.rawValue) cannot discover it", color: DaddyTheme.blue, compact: compact)
                }
                Text("\(summary?.defaultAutomaticCount.formatted() ?? "—") use default rules. Review overlaps the discoverability counts.")
                    .font(.caption2).foregroundStyle(DaddyTheme.muted)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { invocationSummary; Spacer(minLength: 0) }
                    invocationSummary
                }
                Text("Preload is not measured. Auto-invocable means allowed without your command; Projects estimates startup instructions separately and excludes skill bodies.")
                    .font(.caption2).foregroundStyle(DaddyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup("Across agents and rule details", isExpanded: $showsRuleDetails) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let sharing {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 18) {
                                    sharingFact("All five agents", sharing.everyRuntimeCount)
                                    sharingFact("Several agents", sharing.multipleRuntimeCount)
                                    sharingFact("One agent only", sharing.singleRuntimeCount)
                                    sharingFact("Definition conflicts", sharing.definitionConflictCount, warning: sharing.definitionConflictCount > 0)
                                    Spacer()
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    sharingFact("All five agents", sharing.everyRuntimeCount)
                                    sharingFact("Several agents", sharing.multipleRuntimeCount)
                                    sharingFact("One agent only", sharing.singleRuntimeCount)
                                    sharingFact("Definition conflicts", sharing.definitionConflictCount, warning: sharing.definitionConflictCount > 0)
                                }
                            }
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
                            guide("Auto-invocable", "Agent may invoke it without a command", DaddyTheme.mint)
                            guide("Manual only", "Use the shown invocation", DaddyTheme.amber)
                            guide("Model only", "No direct user invocation", DaddyTheme.blue)
                            guide("Cannot discover", "The agent cannot see it", DaddyTheme.muted)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.caption)
                .foregroundStyle(DaddyTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var invocationSummary: some View {
        HStack(spacing: 8) {
            Text("Invocation rules").font(.caption.weight(.semibold)).foregroundStyle(DaddyTheme.muted)
            invocationButton(.automatic, "\(summary?.automaticCount.formatted() ?? "—") auto-invocable", DaddyTheme.mint)
            invocationButton(.manual, "\(summary?.manualOnlyCount.formatted() ?? "—") manual-only", DaddyTheme.amber)
            invocationButton(.model, "\(summary?.modelOnlyCount.formatted() ?? "—") model only", DaddyTheme.blue)
            invocationButton(.disabled, "\(summary?.disabledCount.formatted() ?? "—") disabled", DaddyTheme.coral)
        }
    }

    private func invocationButton(_ filter: SkillFilter, _ title: String, _ color: Color) -> some View {
        Button { selectFilter(filter) } label: {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(color)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(color.opacity(selectedFilter == filter ? 0.15 : 0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func metric(filter: SkillFilter, title: String, value: Int?, detail: String, color: Color, compact: Bool) -> some View {
        Button { selectFilter(filter) } label: {
            VStack(alignment: .leading, spacing: compact ? 3 : 6) {
                HStack {
                    Text(value?.formatted() ?? "—")
                        .font(.system(size: compact ? 18 : 24, weight: .semibold, design: .rounded)).monospacedDigit()
                    Spacer()
                    if selectedFilter == filter {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(color)
                    }
                }
                Text(title).font((compact ? Font.caption : Font.subheadline).weight(.semibold)).lineLimit(1)
                if !compact {
                    Text(detail).font(.caption2).foregroundStyle(DaddyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(compact ? 8 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(selectedFilter == filter ? 0.13 : 0.05), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(color.opacity(selectedFilter == filter ? 0.55 : 0.16)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Filter the ledger to \(title.lowercased()) skills for \(runtime.rawValue).")
    }

    private func sharingFact(_ label: String, _ value: Int, warning: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(value.formatted()).font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(warning ? DaddyTheme.amber : DaddyTheme.mint)
            Text(label).font(.caption).foregroundStyle(DaddyTheme.muted)
        }
    }

    private func guide(_ title: String, _ detail: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(color).frame(width: 6, height: 6).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(DaddyTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
