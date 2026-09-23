import AppKit
import ContextCore
import SwiftUI

struct ContextPagination: View {
    @Binding var page: Int
    let total: Int
    let pageSize: Int
    let noun: String

    private var lastPage: Int { max(0, (total - 1) / pageSize) }

    var body: some View {
        HStack(spacing: 12) {
            Text(total == 0 ? "No \(noun)" : "\(min(total, page * pageSize + 1))–\(min(total, (page + 1) * pageSize)) of \(total.formatted()) \(noun)")
                .font(.caption.monospacedDigit()).foregroundStyle(DaddyTheme.muted)
            Spacer()
            if total > pageSize {
                Button("Previous", systemImage: "chevron.left") { page = max(0, page - 1) }
                    .disabled(page == 0)
                Button("Next", systemImage: "chevron.right") { page = min(lastPage, page + 1) }
                    .disabled(page >= lastPage)
            }
        }
    }
}

struct ContextFileRow: View {
    let item: AIContextItem
    let preview: (AIContextItem) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideRow
            compactRow
        }
        .padding(.vertical, 9)
    }

    private var wideRow: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(item.kind == .skill ? DaddyTheme.blue : DaddyTheme.mint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(item.name).font(.subheadline.weight(.semibold))
                    if item.applicability == .installedOnly {
                        Text("Installed only").font(.caption2).foregroundStyle(DaddyTheme.muted)
                    }
                    if item.resolvedPath != nil, item.resolvedPath != item.path {
                        Image(systemName: "link").font(.caption2).foregroundStyle(DaddyTheme.blue)
                    }
                }
                Text(item.path).font(.caption2.monospaced()).foregroundStyle(DaddyTheme.muted)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer(minLength: 10)
            Text(item.provider.rawValue).font(.caption).foregroundStyle(DaddyTheme.muted)
            Text(ByteCountFormatter.string(fromByteCount: item.logicalBytes, countStyle: .file))
                .font(.caption.monospacedDigit()).foregroundStyle(DaddyTheme.muted).frame(width: 70, alignment: .trailing)
            if item.kind != .mcpConfig {
                Button("Preview") { preview(item) }.controlSize(.small)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.plain).foregroundStyle(DaddyTheme.muted)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(item.name) in Finder")
        }
    }

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .foregroundStyle(item.kind == .skill ? DaddyTheme.blue : DaddyTheme.mint)
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(ByteCountFormatter.string(fromByteCount: item.logicalBytes, countStyle: .file))
                    .font(.caption.monospacedDigit()).foregroundStyle(DaddyTheme.muted)
            }
            Text(item.path).font(.caption2.monospaced()).foregroundStyle(DaddyTheme.muted)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            HStack(spacing: 10) {
                Text(item.provider.rawValue).font(.caption).foregroundStyle(DaddyTheme.muted)
                if item.applicability == .installedOnly {
                    Text("Installed only").font(.caption2).foregroundStyle(DaddyTheme.muted)
                }
                Spacer()
                if item.kind != .mcpConfig {
                    Button("Preview") { preview(item) }.controlSize(.small)
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.plain).foregroundStyle(DaddyTheme.muted)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(item.name) in Finder")
            }
        }
    }

    private var icon: String {
        switch item.kind {
        case .skill: "sparkles.square.fill"
        case .instruction: "text.book.closed.fill"
        case .rule: "checklist"
        case .agentDefinition: "person.crop.square.filled.and.at.rectangle"
        case .mcpConfig: "server.rack"
        }
    }
}

struct PaginatedContextFiles: View {
    let items: [AIContextItem]
    let preview: (AIContextItem) -> Void
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.dropFirst(page * 10).prefix(10))) { item in
                ContextFileRow(item: item, preview: preview)
                if item.id != items.dropFirst(page * 10).prefix(10).last?.id {
                    Divider().overlay(DaddyTheme.line)
                }
            }
            ContextPagination(page: $page, total: items.count, pageSize: 10, noun: "files")
                .padding(.top, 8)
        }
        .onChange(of: items.map(\.id)) { _, _ in page = 0 }
    }
}

struct ContextDocumentPreviewSheet: View {
    let item: AIContextItem
    @Environment(\.dismiss) private var dismiss
    @State private var state: PreviewState = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.title2.bold())
                    Text("\(item.source) · \(item.kind.rawValue) · \(item.provider.rawValue)")
                        .font(.caption).foregroundStyle(DaddyTheme.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(item.path).font(.caption.monospaced()).foregroundStyle(DaddyTheme.muted).textSelection(.enabled)
            if let resolved = item.resolvedPath, resolved != item.path {
                Label(resolved, systemImage: "link")
                    .font(.caption.monospaced()).foregroundStyle(DaddyTheme.blue).textSelection(.enabled)
            }
            Group {
                switch state {
                case .loading:
                    ProgressView("Reading the selected local text…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
                case .loaded(let document):
                    VStack(alignment: .leading, spacing: 8) {
                        if document.truncated {
                            Label("Preview truncated at 256 KiB", systemImage: "scissors")
                                .font(.caption).foregroundStyle(DaddyTheme.amber)
                        }
                        if document.text.isEmpty {
                            ContentUnavailableView("This file is empty", systemImage: "doc.text")
                        } else {
                            ScrollView([.vertical, .horizontal]) {
                                Text(document.text)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                            }
                            .background(DaddyTheme.canvas)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(DaddyTheme.line))
                        }
                    }
                }
            }
        }
        .padding(22).frame(minWidth: 720, minHeight: 520)
        .background(DaddyTheme.panel).preferredColorScheme(.dark)
        .task(id: item.id) {
            state = await Task.detached(priority: .utility) {
                do {
                    return PreviewState.loaded(try SkillDocumentReader.read(
                        url: URL(fileURLWithPath: item.resolvedPath ?? item.path),
                        documentKind: item.kind
                    ))
                } catch {
                    return PreviewState.failed((error as? LocalizedError)?.errorDescription ?? "The file could not be read safely.")
                }
            }.value
        }
    }
}

private enum PreviewState: Sendable {
    case loading
    case loaded(SkillDocument)
    case failed(String)
}
