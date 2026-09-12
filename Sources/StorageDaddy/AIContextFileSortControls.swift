import SwiftUI
import DiskCore

struct AIContextFileSortControls: View {
    @Binding var sort: AIContextFileSort
    @Binding var ascending: Bool
    var body: some View {
        HStack(spacing: 10) {
            Text("Files").font(.caption).foregroundStyle(Tints.secondaryText)
            Menu(sort.rawValue) {
                ForEach(AIContextFileSort.allCases, id: \.self) { key in
                    Button(key.rawValue) { sort = key; ascending = key == .name || key == .kind }
                }
            }.fixedSize().accessibilityLabel("Sort files by \(sort.rawValue)")
            Button(ascending ? "Ascending" : "Descending", systemImage: ascending ? "arrow.up" : "arrow.down") { ascending.toggle() }
                .accessibilityLabel("File sort order: \(ascending ? "ascending" : "descending")")
            Spacer(minLength: 0)
        }
    }
}
