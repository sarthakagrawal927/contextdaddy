import ContextCore
import SwiftUI

struct SkillsGovernanceView: View {
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
                        Text("How \(runtime.rawValue) can use skills").font(.headline)
                        if !compact {
                            Text("Installed is not the same as invocable. These counts use the selected agent’s effective exposure and policy.")
                                .font(.caption).foregroundStyle(DaddyTheme.muted)
                        }
                    }
                    Spacer()
                    if let summary {
                        Text("\(summary.exposedCount.formatted()) of \(summary.totalCount.formatted()) exposed")
                            .font(.caption.monospacedDigit()).foregroundStyle(DaddyTheme.muted)
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 150 : 190), spacing: 10)], spacing: 10) {
                    metric(
                        filter: .automatic,
                        title: "Automatic",
                        value: summary?.automaticCount,
                        detail: summary.map { "\($0.defaultAutomaticCount.formatted()) rely on defaults" } ?? "Waiting for inventory",
                        color: DaddyTheme.mint,
                        compact: compact
                    )
                    metric(
                        filter: .manual,
                        title: "Manual only",
                        value: summary?.manualOnlyCount,
                        detail: "You invoke these directly",
                        color: DaddyTheme.amber,
                        compact: compact
                    )
                    metric(
                        filter: .notExposed,
                        title: "Cannot discover",
                        value: summary?.notExposedCount,
                        detail: "\(runtime.rawValue) cannot discover these",
                        color: DaddyTheme.muted,
                        compact: compact
                    )
                }

                Button { selectFilter(.review) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.magnifyingglass")
                            .foregroundStyle(DaddyTheme.coral)
                        Text("\(summary?.reviewCount.formatted() ?? "—") need review")
                            .font(.subheadline.weight(.semibold))
                        Text("Cross-cutting: these also appear in the invocation counts above.")
                            .font(.caption).foregroundStyle(DaddyTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(DaddyTheme.coral)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DaddyTheme.coral.opacity(selectedFilter == .review ? 0.13 : 0.05), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(DaddyTheme.coral.opacity(selectedFilter == .review ? 0.55 : 0.16)))
                }
                .buttonStyle(.plain)
                .help("Filter to skills with default-policy or definition conflicts; this count overlaps the invocation statuses.")

                Divider().overlay(DaddyTheme.line)

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

                if !compact {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 110), spacing: 14), count: 4), alignment: .leading, spacing: 10) {
                        guide("Automatic", "The model may load it", DaddyTheme.mint)
                        guide("Manual only", "Use the shown invocation", DaddyTheme.amber)
                        guide("Model only", "No direct user invocation", DaddyTheme.blue)
                        guide("Cannot discover", "The agent cannot see it", DaddyTheme.muted)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                    Text(detail).font(.caption2).foregroundStyle(DaddyTheme.muted).lineLimit(1)
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
