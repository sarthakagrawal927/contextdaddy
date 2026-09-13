import AppKit
import DiskCore
import SwiftUI

/// Shared, read-only inspection. This view never stages links or their targets.
struct FolderSymlinksView: View {
    let scan: ScanResult
    let folderID: Int
    var cleanupReview = false

    @State private var expanded = false
    @State private var index: FolderSymlinkIndex?
    @State private var details: [FolderSymlinkDetail] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var page = 0
    @State private var revision = 0
    @State private var indexRevision = -1
    @State private var detailRequestID = UUID()
    private let pageSize = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(Tints.mint)
                    Text("Symlinks").fontWeight(.medium)
                    if let index { Text(index.totalCount.formatted()).foregroundStyle(Tints.secondaryText).monospacedDigit() }
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                }.frame(minHeight: 36).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("Symlinks\(index.map { ", \($0.totalCount) found" } ?? "")")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .help("Review symbolic links found inside this folder, including subfolders")

            if expanded {
                if cleanupReview {
                    Text("Links move with the folder. A link does not add an outside target to cleanup.")
                        .font(.caption).foregroundStyle(Tints.secondaryText)
                }
                if let failure {
                    Text(failure).font(.caption).foregroundStyle(Tints.yellow)
                    Button("Try again") { revision += 1 }.font(.caption)
                } else if index == nil {
                    Label("Finding links in the scan…", systemImage: "ellipsis").font(.caption).foregroundStyle(Tints.secondaryText)
                } else if let index {
                    if index.incompleteScan {
                        Text("Some locations were skipped by the scan. Only discovered links are shown.")
                            .font(.caption).foregroundStyle(Tints.yellow)
                    }
                    if index.totalCount == 0 {
                        Text("No symlinks found in this folder’s scanned contents.").font(.caption).foregroundStyle(Tints.secondaryText)
                    } else if loading {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking link targets…").font(.caption) }
                    } else {
                        ForEach(details) { detail in
                            linkRow(detail)
                            if detail.id != details.last?.id { Divider().overlay(Tints.secondaryText.opacity(0.12)) }
                        }
                        if index.candidates.count > pageSize {
                            HStack {
                                Button { page -= 1 } label: { Image(systemName: "chevron.left") }
                                    .disabled(page == 0).accessibilityLabel("Previous symlinks")
                                Spacer()
                                Text("\(page * pageSize + 1)–\(min((page + 1) * pageSize, index.candidates.count)) of \(index.candidates.count)")
                                    .font(.caption).foregroundStyle(Tints.secondaryText).monospacedDigit()
                                Spacer()
                                Button { page += 1 } label: { Image(systemName: "chevron.right") }
                                    .disabled((page + 1) * pageSize >= index.candidates.count).accessibilityLabel("Next symlinks")
                            }
                        }
                        if index.truncated {
                            Text("Showing the first \(index.candidates.count.formatted()) links of \(index.totalCount.formatted()). Explore a smaller folder to see the rest.")
                                .font(.caption).foregroundStyle(Tints.secondaryText)
                        }
                        HStack {
                            Text("Target status is checked when viewed.").font(.caption2).foregroundStyle(Tints.secondaryText)
                            Spacer()
                            Button("Refresh") { revision += 1 }.font(.caption)
                        }
                    }
                }
            }
        }
        .task(id: revision) { await loadIndex() }
        .task(id: DetailRequest(expanded: expanded, page: page, revision: revision, ready: index != nil && indexRevision == revision)) {
            await loadDetails()
        }
    }

    private func linkRow(_ detail: FolderSymlinkDetail) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(readable(detail.relativePath)).font(.caption.weight(.semibold)).lineLimit(2)
                .truncationMode(.middle).textSelection(.enabled).help(detail.path)
            Text(statusLabel(detail.status)).font(.caption2.weight(.medium)).foregroundStyle(statusColor(detail.status))
            if let target = detail.rawTarget ?? detail.targetPath {
                Text("Points to \(readable(target))").font(.caption).foregroundStyle(Tints.secondaryText)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .help(detail.targetPath.map { "\(detail.status == .broken ? "Unresolved target" : "Resolved target"): \($0)" } ?? target)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .contextMenu {
                Button("Copy Link Path") { copy(detail.path) }
                if let target = detail.targetPath { Button("Copy Target Path") { copy(target) } }
            }
    }

    private func readable(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let display = path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        return display.replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\r", with: "↵").replacingOccurrences(of: "\t", with: "⇥")
    }

    private func statusLabel(_ status: FolderSymlinkStatus) -> String {
        switch status {
        case .inside: "Inside this folder"
        case .outside: "Outside this folder"
        case .broken: "Broken link · target missing"
        case .unavailable: "Target could not be checked"
        case .changed: "Changed since scan · rescan folder"
        }
    }

    private func statusColor(_ status: FolderSymlinkStatus) -> Color {
        switch status {
        case .inside: Tints.mint
        case .outside: Tints.yellow
        case .broken: Tints.coral
        case .unavailable, .changed: Tints.secondaryText
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func loadIndex() async {
        index = nil; indexRevision = -1; failure = nil; details = []; page = 0
        let requestedRevision = revision
        let work = Task.detached(priority: .utility) { try FolderSymlinks.index(in: scan, folderID: folderID) }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try Task.checkCancellation()
            guard requestedRevision == revision else { return }
            index = result; indexRevision = requestedRevision
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, requestedRevision == revision else { return }
            failure = "These links couldn’t be checked. Rescan this folder or try again."
        }
    }

    private func loadDetails() async {
        let requestID = UUID()
        detailRequestID = requestID
        guard expanded, indexRevision == revision, let index else { loading = false; return }
        loading = true; details = []
        defer { if detailRequestID == requestID { loading = false } }
        let candidates = Array(index.candidates.dropFirst(page * pageSize).prefix(pageSize))
        let folder = scan.url(for: folderID)
        let work = Task.detached(priority: .utility) {
            try candidates.map { candidate in
                try Task.checkCancellation()
                return try FolderSymlinks.resolve(candidate, folder: folder)
            }
        }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try Task.checkCancellation()
            guard detailRequestID == requestID else { return }
            details = result; loading = false
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, detailRequestID == requestID else { return }
            failure = "These targets couldn’t be checked. Try refreshing the list."
        }
    }

    private struct DetailRequest: Equatable {
        let expanded: Bool
        let page: Int
        let revision: Int
        let ready: Bool
    }
}
