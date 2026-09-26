import ContextCore
import SwiftUI

/// A direct route to the local OTEL evidence. This is deliberately independent
/// of Usage's allowance, model, source, and date-range controls.
struct TelemetryView: View {
    @Environment(ContextDaddyModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GeometryReader { proxy in
            let compact = proxy.size.width < 850 || proxy.size.height < 700
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 13 : 19) {
                    ScreenHeader(
                        eyebrow: "OpenTelemetry · last 24 hours",
                        title: "Live agent activity",
                        subtitle: "Codex and Claude signals from the local collector. These readings are separate from usage history.",
                        art: .telemetry,
                        compact: compact
                    )

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            agentPicker
                            Spacer(minLength: 8)
                            refreshButton
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            agentPicker
                            refreshButton
                        }
                    }

                    connectionStatus

                    if model.telemetry.collectorReachable && model.selectedTelemetryRuntime == .claude && !selectedAgentConnected {
                        missingClaudeTelemetry
                    } else if model.telemetry.collectorReachable {
                        OTelDashboardView(snapshot: model.telemetry, runtime: model.selectedTelemetryRuntime)
                    }

                    Panel {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("What this view cannot prove", systemImage: "info.circle")
                                .font(.headline)
                            Text("Network calls are logical events, not internet bytes. A named skill injection does not prove the skill completed useful work. Claude tool and API calls are unavailable without a verified adapter.")
                                .font(.caption)
                                .foregroundStyle(DaddyTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(compact ? 18 : 28)
                .frame(maxWidth: 1220, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var agentPicker: some View {
        ContextChoiceMenu(
            title: "Agent",
            selection: Bindable(model).selectedTelemetryRuntime,
            choices: [AgentRuntime.codex, .claude].map { ContextChoice($0, $0.rawValue) },
            width: 180
        )
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refreshTelemetry() }
        } label: {
            Label(model.isTelemetryLoading ? "Checking…" : "Check telemetry", systemImage: "arrow.clockwise")
        }
        .disabled(model.isTelemetryLoading)
    }

    private var selectedAgentConnected: Bool {
        model.telemetry.agents.first { $0.runtime == model.selectedTelemetryRuntime }?.connected == true
    }

    private var missingClaudeTelemetry: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Label("Claude telemetry unavailable", systemImage: "waveform.path.ecg")
                    .font(.headline)
                    .foregroundStyle(DaddyTheme.amber)
                Text("The local collector is running, but no verified Claude Code OTLP metrics were returned. This is missing coverage, not zero usage.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Check that Claude Code exports OTLP metrics to this collector, then use Check telemetry above. Local Claude history remains available separately on Usage.")
                    .font(.caption)
                    .foregroundStyle(DaddyTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Usage history", systemImage: "chart.bar.xaxis") {
                    model.usageService = .claude
                    model.show(.overview)
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connectionStatus: some View {
        let collectorReachable = model.telemetry.collectorReachable
        let claudeMissing = collectorReachable && model.selectedTelemetryRuntime == .claude && !selectedAgentConnected
        return Panel(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: collectorReachable && !claudeMissing ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(collectorReachable && !claudeMissing ? DaddyTheme.mint : DaddyTheme.amber)
                VStack(alignment: .leading, spacing: 4) {
                    Text(claudeMissing ? "Collector reachable · Claude data unavailable" :
                         collectorReachable ? "Local OTEL source reachable" : "Local OTEL source unavailable")
                        .font(.subheadline.weight(.semibold))
                    Text(claudeMissing
                         ? "No verified Claude Code OTLP metrics were returned. Codex telemetry can be available while Claude telemetry is not."
                         : collectorReachable
                         ? "Last checked \(model.telemetry.generatedAt.formatted(date: .abbreviated, time: .shortened)). Codex and Claude evidence may still differ."
                         : "ContextDaddy cannot reach its read-only local telemetry endpoint at 127.0.0.1:3000. Start or repair the local stack, then check again. No activity is inferred from this outage.")
                        .font(.caption)
                        .foregroundStyle(DaddyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.telemetry.collectorReachable, let detail = model.telemetry.notes.first {
                        Text(detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(DaddyTheme.amber)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
                EvidenceBadge(quality: collectorReachable && !claudeMissing ? .measured : .unavailable)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
