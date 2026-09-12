import SwiftUI
import DiskCore

/// Keeps large metadata inventories browsable without expanding every matching file.
struct AIContextPagination: View {
    @Binding var page: Int
    let total: Int
    let pageSize: Int
    let noun: String

    private var lastPage: Int { max(0, (total - 1) / pageSize) }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(min(total, page * pageSize + 1))–\(min(total, (page + 1) * pageSize)) of \(total.formatted()) \(noun)")
                .font(.caption).monospacedDigit().foregroundStyle(Tints.secondaryText)
            Spacer(minLength: 8)
            if total > pageSize {
                Button("Previous", systemImage: "chevron.left") { page = max(0, page - 1) }
                    .disabled(page == 0).accessibilityLabel("Previous page of \(noun)")
                Button("Next", systemImage: "chevron.right") { page = min(lastPage, page + 1) }
                    .disabled(page >= lastPage).accessibilityLabel("Next page of \(noun)")
            }
        }.padding(.vertical, 8)
    }
}

struct AIContextSourceItems<Row: View>: View {
    let items: [AIContextItem]
    let row: (AIContextItem) -> Row
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.dropFirst(page * 10).prefix(10))) { item in row(item) }
            AIContextPagination(page: $page, total: items.count, pageSize: 10, noun: "files")
        }
        .onChange(of: items.map(\.id)) { _, _ in page = 0 }
    }
}
