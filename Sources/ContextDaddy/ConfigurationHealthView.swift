import AppKit
import ContextCore
import SwiftUI

struct ConfigurationHealthView: View {
    @Environment(ContextDaddyModel.self) private var model
    let report: ConfigurationHealthReport

    var body: some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Configuration health").font(.headline)
                        Text("Settings this app cannot use and enabled tool connections that may fail to start. Repeated reports are grouped together.")
                            .font(.caption).foregroundStyle(DaddyTheme.muted)
                    }
                    Spacer()
                    if !report.issues.isEmpty {
                        Button("Copy all \(report.issues.count) \(report.issues.count == 1 ? "issue" : "issues")", systemImage: "doc.on.doc", action: copyAll)
                            .font(.caption)
                    }
                    statusBadge
                }

                if model.configurationIssueBaseline != nil {
                    HStack(spacing: 12) {
                        if let result = model.configurationIssueVerification {
                            Text("\(result.cleared.count) detector-cleared · \(result.stillDetected.count) still detected · \(result.unverified.count) unverified")
                                .font(.caption).foregroundStyle(DaddyTheme.muted)
                        } else {
                            Text("Agent handoff copied. Rescan after changes; missing config files remain unverified.")
                                .font(.caption).foregroundStyle(DaddyTheme.muted)
                        }
                        Spacer()
                        Button(model.isVerifyingConfigurationIssues ? "Checking…" : "Verify after changes",
                               systemImage: "arrow.clockwise") {
                            Task { await model.verifyConfigurationIssues() }
                        }
                        .disabled(model.isVerifyingConfigurationIssues)
                        .font(.caption)
                    }
                    if let result = model.configurationIssueVerification {
                        ForEach(result.cleared) { issue in issueStatus(issue, "CLEARED", DaddyTheme.mint) }
                        ForEach(result.stillDetected) { issue in issueStatus(issue, "STILL DETECTED", DaddyTheme.amber) }
                        ForEach(result.unverified) { issue in issueStatus(issue, "UNVERIFIED", DaddyTheme.muted) }
                    }
                }

                if report.scannedFiles.isEmpty {
                    Label("No readable supported agent configuration was found.", systemImage: "questionmark.folder")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                } else if report.issues.isEmpty {
                    Label("No structural configuration problems detected.", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(DaddyTheme.mint)
                } else {
                    ForEach(report.issues) { issue in
                        Divider().overlay(DaddyTheme.line)
                        issueRow(issue)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Label("This scans supported configuration files, not launch-time session flags. A warning such as `session-flags.token_budget` must be traced to the Codex launcher that supplied it.", systemImage: "info.circle")
                    Label("Read-only check: credential, header, environment, and MCP argument values are ignored.", systemImage: "lock.shield")
                }
                .font(.caption2).foregroundStyle(DaddyTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(IssueBriefFormatter.configuration(report.issues), forType: .string) else { return }
        model.captureConfigurationIssues()
    }

    private func issueStatus(_ issue: ConfigurationHealthIssue, _ status: String, _ color: Color) -> some View {
        HStack(spacing: 9) {
            Text(status).font(.caption2.weight(.bold)).foregroundStyle(color).frame(width: 110, alignment: .leading)
            Text(issue.title).font(.caption)
            Spacer()
            Text("\(issue.runtime.rawValue) · line \(issue.line)")
                .font(.caption2).foregroundStyle(DaddyTheme.muted)
        }
    }

    private var statusBadge: some View {
        let color = report.errorCount > 0 ? DaddyTheme.coral : report.warningCount > 0 ? DaddyTheme.amber : DaddyTheme.mint
        let label = report.issues.isEmpty ? "NO FILE ISSUES" : "\(report.issues.count) FILE \(report.issues.count == 1 ? "ISSUE" : "ISSUES")"
        return Text(label)
            .font(.system(size: 9, weight: .bold, design: .rounded)).tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(color.opacity(0.11), in: Capsule())
    }

    private func issueRow(_ issue: ConfigurationHealthIssue) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 11) {
                issueIcon(issue)
                issueCopy(issue)
                Spacer(minLength: 12)
                actions(issue)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 10) {
                    issueIcon(issue)
                    issueCopy(issue)
                }
                actions(issue)
            }
        }
    }

    private func issueIcon(_ issue: ConfigurationHealthIssue) -> some View {
        Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(issue.severity == .error ? DaddyTheme.coral : DaddyTheme.amber)
            .frame(width: 18)
    }

    private func issueCopy(_ issue: ConfigurationHealthIssue) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(issue.title).font(.subheadline.weight(.semibold))
            Text(issue.detail).font(.caption).foregroundStyle(DaddyTheme.muted)
            Text("\((issue.path as NSString).abbreviatingWithTildeInPath):\(issue.line)")
                .font(.caption2.monospaced()).foregroundStyle(DaddyTheme.blue).textSelection(.enabled)
            Text(issue.remediation).font(.caption2).foregroundStyle(DaddyTheme.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func actions(_ issue: ConfigurationHealthIssue) -> some View {
        HStack(spacing: 8) {
            Button("Copy fix", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(issue.remediation, forType: .string)
            }
            Button("Reveal", systemImage: "arrow.up.forward.square") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: issue.path)])
            }
        }
        .controlSize(.small)
        .fixedSize()
    }
}
