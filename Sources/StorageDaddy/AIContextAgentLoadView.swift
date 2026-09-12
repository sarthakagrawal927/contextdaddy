import SwiftUI
import DiskCore

struct AIContextAgentLoadView: View {
    let loads: [AIContextFolderRanking]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Per-agent context load").font(.headline)
            if loads.isEmpty {
                Text("No agent-specific instruction estimate is available for this directory.")
                    .foregroundStyle(Tints.secondaryText)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(loads) { load in agentCard(load) }
                }
            }
            Text("Approximate instruction tokens, using four bytes per token. Skills are listed separately because their full text usually loads on demand. Rules, skill descriptions, tools, memory and conversation history can add more; this is not a measurement of a live agent prompt.")
                .font(.caption).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func agentCard(_ load: AIContextFolderRanking) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if load.provider == .codex { AIProviderIcon(provider: .codex, size: 22) }
                else if load.provider == .claude { AIProviderIcon(provider: .claude, size: 22) }
                else { Image(systemName: "terminal").foregroundStyle(Tints.mint) }
                Text(load.provider.rawValue).font(.headline)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(load.automaticInstructionSourceCount == 0 ? "Not measured" : tokens(load.estimatedStartupTokens))
                    .font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(Tints.mint)
                Text("Instruction estimate").font(.caption).foregroundStyle(Tints.secondaryText)
            }
            VStack(spacing: 6) {
                contribution("Global · shared", bytes: load.globalBytes)
                contribution("Parent folders", bytes: load.inheritedBytes)
                contribution("This directory", bytes: load.localBytes)
            }
            Divider().overlay(Tints.mint.opacity(0.18))
            HStack {
                Text("Available skills").font(.caption).foregroundStyle(Tints.secondaryText)
                Spacer()
                Text(load.skillCount.formatted()).monospacedDigit()
            }
            let conditional = load.sources.filter { $0.origin == .conditional && $0.item.kind != .skill }.count
            Text("\(load.automaticInstructionSourceCount) instruction files · \(conditional) other conditional files")
                .font(.caption2).foregroundStyle(Tints.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tints.mint.opacity(0.25)))
    }

    private func contribution(_ name: String, bytes: Int64) -> some View {
        HStack {
            Text(name).font(.caption).foregroundStyle(Tints.secondaryText)
            Spacer()
            Text(DiskFormat.bytes(bytes)).font(.caption).monospacedDigit()
        }
    }

    private func tokens(_ count: Int) -> String {
        if count >= 1_000 { return "≈ " + String(format: "%.1fK", Double(count) / 1_000) + " tokens" }
        return "≈ \(count.formatted()) tokens"
    }
}
