import ContextCore
import SwiftUI

struct SkillShareSheet: View {
    @Environment(ContextDaddyModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: SkillRecord
    @State private var target: SkillShareTarget
    @State private var result: String?
    @State private var failed = false

    init(record: SkillRecord) {
        self.record = record
        let firstAvailable = SkillShareTarget.allCases.first {
            SkillSharing.plan(for: record, target: $0).status == .available
        }
        _target = State(initialValue: firstAvailable ?? .codex)
    }

    private var plan: SkillSharePlan { SkillSharing.plan(for: record, target: target) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share \(record.name)").font(.title2.weight(.semibold))
            Text("Create one link to the existing skill directory. The source stays where it is; the target agent can discover the same files in its global skills folder.")
                .font(.subheadline).foregroundStyle(DaddyTheme.muted)
            path("Source", plan.sourceDirectory.path)
            Picker("Target agent", selection: $target) {
                ForEach(SkillShareTarget.allCases) { agent in
                    Text(agent.rawValue).tag(agent)
                }
            }
            .pickerStyle(.menu)
            path("New route", plan.destination.path)
            Label(statusText, systemImage: plan.status == .available ? "checkmark.circle" : "info.circle")
                .font(.caption)
                .foregroundStyle(plan.status == .available ? DaddyTheme.mint : DaddyTheme.amber)
                .fixedSize(horizontal: false, vertical: true)
            Text("Global exposure makes this skill discoverable across folders. It does not prove automatic invocation or preload. An occupied destination is never replaced.")
                .font(.caption2).foregroundStyle(DaddyTheme.muted)
            if target == .devin {
                Text("Devin's local skills folder is discovered here, but acceptance by a running Devin session is unverified.")
                    .font(.caption2).foregroundStyle(DaddyTheme.amber)
            }
            if let result {
                Text(result).font(.caption).foregroundStyle(failed ? DaddyTheme.coral : DaddyTheme.mint)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                Button("Create shared link") { createLink() }
                    .disabled(plan.status != .available)
            }
        }
        .padding(24)
        .frame(width: 570)
        .buttonStyle(ContextDaddyButtonStyle())
    }

    private var statusText: String {
        switch plan.status {
        case .available: "Ready to create a link at an empty destination."
        case .alreadyShared: "Already shared with \(target.rawValue) through this destination."
        case .occupied: "A different item already uses this destination. Review it before changing anything."
        case .unavailable(let reason): reason
        }
    }

    private func path(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(DaddyTheme.muted)
            Text((value as NSString).abbreviatingWithTildeInPath)
                .font(.caption.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func createLink() {
        do {
            let destination = try SkillSharing.createLink(for: record, target: target)
            failed = false
            result = "Shared at \(destination.path). Refreshing the inventory…"
            Task { await model.refresh() }
        } catch {
            failed = true
            result = error.localizedDescription
        }
    }
}
