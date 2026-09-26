import Charts
import ContextCore
import SwiftUI

/// CodeVetter's history desk, expressed in ContextDaddy's existing visual system.
/// The chart and exact-value inspector always use the same daily-ledger projection.
struct UnifiedUsageHistoryView: View {
    @Environment(ContextDaddyModel.self) private var model
    @State private var selectedPeriod: String?
    @State private var showAllBreakdown = false

    var body: some View {
        @Bindable var model = model
        let history = model.usageHistory
        let agents = model.usageReport?.provenance.detectedAgents ?? []
        return Panel(padding: 20) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LOCAL HISTORY · NOT PROVIDER ALLOWANCE")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1).foregroundStyle(DaddyTheme.mint)
                        Text("Local History").font(.title3.weight(.semibold))
                        Text(model.usageHistorySource == .devin
                             ? "Devin's read-only session index · tokens only. Its totals are separate from other agents."
                             : model.usageHistoryGrouping == .project
                             ? "Project identities from agent sessions · bucketed by last activity, separate from daily accounting."
                             : "Generated tokens, cache reads, and estimated cost from local agent logs.")
                            .font(.caption).foregroundStyle(DaddyTheme.muted)
                    }
                    Spacer(minLength: 0)
                    Button(model.isUsageLoading ? "Reading…" : "Refresh") {
                        Task { await model.refreshUsage(force: true) }
                    }.disabled(model.isUsageLoading)
                }

                controls

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 160), spacing: 7)],
                          alignment: .leading, spacing: 7) {
                    Button {
                        model.usageHistorySource = .agentLogs
                        model.usageHistoryAgents = []
                    } label: {
                        Text("All logs")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).frame(height: 32)
                            .background(model.usageHistorySource == .agentLogs && model.usageHistoryAgents.isEmpty
                                        ? DaddyTheme.mint.opacity(0.1) : DaddyTheme.raised,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show all agent logs")
                    .accessibilityValue(model.usageHistorySource == .agentLogs && model.usageHistoryAgents.isEmpty
                                        ? "Selected" : "Not selected")
                    ForEach(agents, id: \.self) { agent in
                        let included = model.usageHistorySource == .agentLogs &&
                            (model.usageHistoryAgents.isEmpty || model.usageHistoryAgents.contains(agent))
                        Button { select(agent, among: agents) } label: {
                            HStack(spacing: 5) {
                                Circle().fill(included ? DaddyTheme.mint : DaddyTheme.muted).frame(width: 6, height: 6)
                                Text(agent.capitalized)
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).frame(height: 32)
                            .background(included ? DaddyTheme.mint.opacity(0.1) : DaddyTheme.raised,
                                        in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Filter \(agent.capitalized)")
                        .accessibilityValue(included ? "Included" : "Excluded")
                    }
                    Button {
                        model.usageHistorySource = .devin
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(model.usageHistorySource == .devin ? DaddyTheme.mint : DaddyTheme.muted)
                                .frame(width: 6, height: 6)
                            Text("Devin")
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).frame(height: 32)
                        .background(model.usageHistorySource == .devin ? DaddyTheme.mint.opacity(0.1) : DaddyTheme.raised,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show Devin indexed history")
                    .accessibilityValue(model.usageHistorySource == .devin ? "Selected" : "Not selected")
                }

                if let history, !history.buckets.isEmpty {
                    legend(history)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            chart(history).frame(minWidth: 330)
                            Rectangle().fill(DaddyTheme.line).frame(width: 1)
                            breakdown(history).frame(width: 220)
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            chart(history)
                            Rectangle().fill(DaddyTheme.line).frame(height: 1)
                            breakdown(history)
                        }
                    }
                    if model.usageHistorySource == .devin {
                        Text(model.usageHistoryGrouping == .provider
                             ? "Devin model providers are inferred from model names; unknown aliases stay unknown. Devin is never added to ccusage totals."
                             : "Devin history is indexed locally and never added to ccusage totals. Cost and project attribution are unavailable.")
                            .font(.caption2).foregroundStyle(DaddyTheme.amber)
                    } else if model.usageHistoryGrouping == .project {
                        Text(history.unattributed > 0
                             ? "Session-project ledger: \(format(history.unattributed)) unattributed. Sessions are bucketed by last activity; these totals may not reconcile to daily usage."
                             : "Session-project ledger: project identities come from agent session reports. Buckets use last activity, so totals may not reconcile to daily usage.")
                            .font(.caption2).foregroundStyle(DaddyTheme.amber)
                    } else if model.usageHistoryGrouping == .provider {
                        Text("Model providers are inferred from reported model names; unknown or private aliases stay unknown. This is not a billing-provider claim.")
                            .font(.caption2).foregroundStyle(DaddyTheme.amber)
                    }
                    if model.usageMetric == .estimatedCost,
                       model.usageReport?.provenance.pricingComplete == false {
                        Text("Pricing incomplete · known estimated costs only")
                            .font(.caption2).foregroundStyle(DaddyTheme.amber)
                    }
                } else {
                    Text(model.usageError ?? "No local activity in this time range. The other Usage panels remain available.")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 130)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.usageHistoryGrouping) { selectedPeriod = nil; showAllBreakdown = false }
        .onChange(of: model.usageMetric) { selectedPeriod = nil }
        .onChange(of: model.usageRange) { selectedPeriod = nil }
        .onChange(of: model.usageScale) { selectedPeriod = nil }
        .onChange(of: model.usageHistoryAgents) { selectedPeriod = nil }
        .onChange(of: model.usageHistorySource) { selectedPeriod = nil; showAllBreakdown = false }
    }

    private var controls: some View {
        @Bindable var model = model
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 210), spacing: 7)],
                         alignment: .leading, spacing: 7) {
            ContextChoiceMenu(title: "Range", selection: $model.usageRange,
                              choices: UsageRange.allCases.map { ContextChoice($0, $0.title) }, width: 165)
            ContextChoiceMenu(title: "Scale", selection: $model.usageScale,
                              choices: UsageChartScale.allCases.map { ContextChoice($0, $0.rawValue) }, width: 165)
            ContextChoiceMenu(title: "Group", selection: $model.usageHistoryGrouping,
                              choices: (model.usageHistorySource == .devin
                                  ? [UsageHistoryGrouping.model, .provider] : UsageHistoryGrouping.allCases)
                                .map { ContextChoice($0, $0.rawValue) }, width: 165)
            ContextChoiceMenu(title: "Metric", selection: $model.usageMetric,
                              choices: (model.usageHistorySource == .devin
                                  ? [UsageChartMetric.generated, .cacheRead] : UsageChartMetric.allCases)
                                .map { ContextChoice($0, $0.rawValue) }, width: 165)
        }
    }

    private func legend(_ history: UsageHistoryProjection) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 8)],
                  alignment: .leading, spacing: 8) {
            ForEach(Array(history.visibleSeries.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(tone(index)).frame(width: 7, height: 7)
                    Text(item.label).lineLimit(1).help(item.label)
                }.font(.caption2).foregroundStyle(DaddyTheme.muted)
            }
        }
    }

    private func chart(_ history: UsageHistoryProjection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(history.buckets) { bucket in
                    ForEach(Array(history.visibleSeries.enumerated()), id: \.element.id) { index, item in
                        BarMark(x: .value("Period", bucket.period),
                                y: .value("Usage", history.value(in: bucket, series: item)), stacking: .standard)
                            .foregroundStyle(tone(index))
                            .accessibilityLabel("\(UsageDisplayDate.period(bucket.period, scale: model.usageScale)) · \(item.label)")
                    }
                }
            }
            .chartXSelection(value: $selectedPeriod)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(DaddyTheme.line)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(format(amount)).foregroundStyle(DaddyTheme.muted) }
                    }
                }
            }
            .frame(height: 190)
            .accessibilityLabel("Historical usage by \(model.usageHistoryGrouping.rawValue.lowercased())")
            HStack {
                Text(history.buckets.first.map { UsageDisplayDate.period($0.period, scale: model.usageScale) } ?? "")
                Spacer()
                Text(history.buckets.last.map { UsageDisplayDate.period($0.period, scale: model.usageScale) } ?? "")
            }.font(.caption2.monospaced()).foregroundStyle(DaddyTheme.muted)
            Menu {
                Button("Entire selected range") { selectedPeriod = nil }
                ForEach(history.buckets) { bucket in
                    Button(UsageDisplayDate.period(bucket.period, scale: model.usageScale)) { selectedPeriod = bucket.period }
                }
            } label: {
                Text(selectedPeriod.map { UsageDisplayDate.period($0, scale: model.usageScale) } ?? "Entire selected range")
            }
            .accessibilityLabel("Inspect usage period")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func breakdown(_ history: UsageHistoryProjection) -> some View {
        let selected = history.buckets.first { $0.period == selectedPeriod }
        let rows: [(UsageHistorySeries, Double)] = history.series.map { item in
            (item, selected == nil ? item.value : (selected?.values[item.id] ?? 0))
        }.filter { $0.1 > 0 }.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
        let total = selected?.total ?? history.total
        let visibleCount = showAllBreakdown ? rows.count : min(rows.count, 6)
        return VStack(alignment: .leading, spacing: 10) {
            Text(selected.map { UsageDisplayDate.period($0.period, scale: model.usageScale) } ?? "SELECTED RANGE")
                .font(.caption2.weight(.semibold)).foregroundStyle(DaddyTheme.muted)
            Text(format(total)).font(.title2.bold()).monospacedDigit()
            ForEach(0..<visibleCount, id: \.self) { index in
                let row = rows[index]
                HStack(spacing: 6) {
                    Rectangle().fill(tone(min(history.series.firstIndex { $0.id == row.0.id } ?? 4, 4)))
                        .frame(width: 6, height: 6)
                    Text(row.0.label).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 3)
                    Text(format(row.1)).monospacedDigit()
                }.font(.caption2)
            }
            if rows.count > 6 {
                Button(showAllBreakdown ? "Show fewer" : "Show all \(rows.count) \(model.usageHistoryGrouping.rawValue.lowercased())s") {
                    showAllBreakdown.toggle()
                }.font(.caption2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func select(_ agent: String, among agents: [String]) {
        if model.usageHistorySource == .devin {
            model.usageHistorySource = .agentLogs
            model.usageHistoryAgents = [agent]
            return
        }
        let all = Set(agents)
        var chosen = model.usageHistoryAgents.isEmpty ? all : model.usageHistoryAgents
        if chosen.contains(agent) { chosen.remove(agent) } else { chosen.insert(agent) }
        model.usageHistoryAgents = chosen.isEmpty || chosen == all ? [] : chosen
    }

    private func tone(_ index: Int) -> Color {
        [DaddyTheme.mint, DaddyTheme.blue, DaddyTheme.amber, DaddyTheme.muted, DaddyTheme.coral][min(index, 4)]
    }

    private func format(_ value: Double) -> String {
        if model.usageMetric == .estimatedCost { return value.formatted(.currency(code: "USD")) }
        if value >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
}
