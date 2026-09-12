import SwiftUI
import DiskCore

struct StorageItemMenu: View {
    @EnvironmentObject var m: ExplorerModel
    let node: DiskNode
    var body: some View {
        Button("Inspect") { m.selected = node.id; m.openStorage(.explore) }
        if node.isDirectory { Button("Open Folder") { m.open(node); m.openStorage(.explore) } }
        Button("Reveal in Finder") { m.reveal(node.id) }
        if node.isDirectory {
            Button("Copy Ask AI Prompt", systemImage: "sparkles") { m.copyFolderPrompt(node.id) }
        }
        Divider()
        if let provider = m.sessionProvider(for: node.id) {
            Button("Archive older conversations…") { m.openConversationArchive(provider: provider) }
        }
        Button(m.staged.contains(node.id) ? "Added to Cleanup" : "Add to Cleanup") { m.stage(node.id) }
            .disabled(m.busy || m.monitoring || m.staged.contains(node.id) || node.parent == nil)
        if node.parent == nil { Text("The scan root is protected") }
    }
}
