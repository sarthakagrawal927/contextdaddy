import AppKit
import DiskCore
import SwiftUI

struct AIProviderIcon: View {
    let provider: AISessionProvider
    var size: CGFloat = 24

    private static let claude = load("ClaudeOfficial")
    private static let codex = load("ChatGPTOfficial")

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: provider == .claude ? "sparkles" : "terminal.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.18)
                    .foregroundStyle(provider == .claude ? Tints.coral : Tints.electricBlue)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var image: NSImage? {
        provider == .claude ? Self.claude : Self.codex
    }

    private static func load(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }
}
