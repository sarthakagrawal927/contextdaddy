import SwiftUI
import DiskCore

private struct DeveloperStorageFamily: Identifiable, CaseIterable {
    let title: String
    let symbol: String
    let color: Color
    let categories: Set<DeveloperCategory>
    var bytes: Int64 = 0
    var id: String { title }

    func with(bytes: Int64) -> Self {
        Self(title: title, symbol: symbol, color: color, categories: categories, bytes: bytes)
    }

    static let allCases: [Self] = [
        Self(title: "AI storage", symbol: "sparkles", color: Tints.cyan,
             categories: [.claudeSessions, .codexSessions, .aiCaches, .modelCaches]),
        Self(title: "Builds & caches", symbol: "hammer.fill", color: Tints.electricBlue,
             categories: [.buildOutputs, .temporary]),
        Self(title: "Docker & VMs", symbol: "externaldrive.fill", color: Tints.yellow,
             categories: [.containerStorage]),
        Self(title: "Packages", symbol: "shippingbox.fill", color: Tints.mint,
             categories: [.installedModules, .pythonEnvironments, .packageCaches]),
        Self(title: "node_modules", symbol: "shippingbox", color: Color(red: 0.69, green: 0.79, blue: 0.35),
             categories: [.nodeModules]),
        Self(title: ".git", symbol: "arrow.triangle.branch", color: Tints.coral,
             categories: [.gitRepositories])
    ]
}

extension DeveloperCategory {
    var title: String {
        switch self {
        case .claudeSessions: "Claude sessions"
        case .codexSessions: "Codex sessions"
        case .aiCaches: "AI caches"
        case .gitRepositories: ".git repositories"
        case .nodeModules: "node_modules"
        case .installedModules: "Installed modules"
        case .buildOutputs: "Build outputs"
        case .temporary: "Temporary files"
        case .pythonEnvironments: "Python environments"
        case .packageCaches: "Package caches"
        case .containerStorage: "Containers & VMs"
        case .modelCaches: "Local AI models"
        }
    }
    var symbol: String {
        switch self {
        case .claudeSessions: "sparkle"
        case .codexSessions: "terminal"
        case .aiCaches: "cpu"
        case .gitRepositories: "arrow.triangle.branch"
        case .nodeModules: "shippingbox"
        case .installedModules: "shippingbox.fill"
        case .buildOutputs: "hammer"
        case .temporary: "hourglass"
        case .pythonEnvironments: "shippingbox"
        case .packageCaches: "archivebox"
        case .containerStorage: "externaldrive"
        case .modelCaches: "brain"
        }
    }
    var color: Color {
        switch self {
        case .claudeSessions: Tints.coral
        case .codexSessions: Tints.mint
        case .aiCaches: Tints.cyan
        case .gitRepositories: Tints.coral
        case .nodeModules: Color(red: 0.69, green: 0.79, blue: 0.35)
        case .installedModules: Tints.mint
        case .buildOutputs: Tints.electricBlue
        case .temporary: Tints.yellow
        case .pythonEnvironments: Tints.cyan
        case .packageCaches: Tints.yellow
        case .containerStorage: Tints.electricBlue
        case .modelCaches: Tints.coral
        }
    }
    var detail: String {
        switch self {
        case .claudeSessions: "Local Claude session records. Classification uses file metadata."
        case .codexSessions: "Local Codex session records, including archived sessions."
        case .aiCaches: "Recognized AI cache paths in this scan."
        case .gitRepositories: "Git object databases and repository metadata, grouped by project. This is not an automatic cleanup category."
        case .nodeModules: "Dependency trees. Nested installations are counted once."
        case .installedModules: "Recognized Composer, Bundler, CocoaPods and Bower dependency folders."
        case .buildOutputs: "Likely build artifacts, matched by folder name. Review before cleanup."
        case .temporary: "Files present now. This is not a record of historical bytes written."
        case .pythonEnvironments: "Recognized Python environments and installed packages."
        case .packageCaches: "Recognized package-manager caches across development ecosystems."
        case .containerStorage: "Recognized container and virtual-machine storage. It may contain valuable databases and volumes."
        case .modelCaches: "Recognized local model storage. Removing models can require large downloads."
        }
    }
}

struct DeveloperView: View {
    @EnvironmentObject var m: ExplorerModel
    @State private var showsCategories = false
    @State private var category: DeveloperCategory = .claudeSessions
    private var group: DeveloperGroup? { m.developerGroups.first { $0.category == category } }
    private var total: Int64 { m.developerGroups.reduce(0) { $0 + $1.allocatedBytes } }
    private var storageFamilies: [DeveloperStorageFamily] {
        DeveloperStorageFamily.allCases.map { family in
            var value: Int64 = 0
            for group in m.developerGroups where family.categories.contains(group.category) {
                let (next, overflow) = value.addingReportingOverflow(group.allocatedBytes)
                value = overflow ? Int64.max : next
            }
            return family.with(bytes: value)
        }
    }
    private func change(_ category: DeveloperCategory) -> Int64? {
        guard let previous = m.previousDeveloperGroups?.first(where: { $0.category == category }),
              let current = m.developerGroups.first(where: { $0.category == category }) else { return nil }
        return current.allocatedBytes - previous.allocatedBytes
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                overview
                storageFamilyGrid
                cleanupOpportunities
                DeveloperReportView()
                Button { showsCategories.toggle() } label: {
                    Label(showsCategories ? "Hide category breakdown" : "Show category breakdown", systemImage: showsCategories ? "chevron.up" : "chevron.down")
                }.buttonStyle(StorageButtonStyle())
                if showsCategories {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(m.developerGroups, id: \.category) { item in categoryButton(item) }
                    }
                    details
                }
                Text("Matches cover only the selected folder. Zero means no recognized files here, not zero usage across your Mac. Skipped items are excluded. Session counts describe files, not active contexts or tokens.")
                    .font(.callout).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
            }.padding(28)
        }.background(Color.black).buttonStyle(StorageButtonStyle())
    }
    private var storageFamilyGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Developer storage by type").font(.title2.weight(.semibold))
            Text("Six useful groups first. Open the category breakdown for the underlying tools and folders.")
                .font(.callout).foregroundStyle(Tints.secondaryText)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(storageFamilies) { family in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: family.symbol).foregroundStyle(family.color)
                            Text(family.title).font(.system(size: 13, weight: .semibold))
                            Spacer(minLength: 0)
                        }
                        Text(DiskFormat.bytes(family.bytes))
                            .font(.system(size: 25, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(family.color)
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(family.color.opacity(0.28)))
                }
            }
        }
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text("SCAN RESULTS").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(Tints.secondaryText)
                Text("Developer Insights").font(.system(size: 31, weight: .bold, design: .rounded)).tracking(-0.7)
                Text("Know what belongs to each project—and what removing it would change.").foregroundStyle(Tints.secondaryText)
            }
            DoodleArt(topic: .overview).frame(width: 90, height: 90)
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 8) {
            Button("Rescan", action: m.rescan).buttonStyle(StorageButtonStyle()).disabled(m.busy)
            Button("Scan Home") { m.start(FileManager.default.homeDirectoryForCurrentUser) }
                .buttonStyle(StorageButtonStyle()).disabled(m.busy)
                .help("Scan your home folder to include hidden Claude and Codex storage. Sensitive paths remain excluded.")
            Button("Scan Temp") { m.start(FileManager.default.temporaryDirectory) }.buttonStyle(StorageButtonStyle()).disabled(m.busy)
                .help("Scan the current user’s macOS temporary directory. This replaces the current scope.")
            }
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(DiskFormat.bytes(m.scan?.nodes.first?.allocatedBytes ?? 0)).font(.system(size: 48, weight: .semibold, design: .rounded)).tracking(-2).monospacedDigit()
                Text("total scanned · on disk").foregroundStyle(Tints.secondaryText)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(SpeedFormat.duration(m.analysisElapsed)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Tints.mint)
                    Text("scan + insights").font(.caption).foregroundStyle(Tints.secondaryText)
                    if let rss = m.scanPeakRSS { Text("\(DiskFormat.bytes(Int64(clamping: rss))) sampled peak RSS").font(.caption).foregroundStyle(Tints.secondaryText) }
                }.help("Scan: \(SpeedFormat.duration(m.scan?.elapsed ?? 0)) · Analysis: \(SpeedFormat.duration(m.insightsElapsed)). Excludes view rendering. RSS is sampled every 50 ms plus start/end, includes UI and retained scan data, and may miss brief spikes.")
            }
            HStack {
                Text("Developer & AI storage").font(.headline)
                Text(DiskFormat.bytes(total)).monospacedDigit().foregroundStyle(Tints.mint)
                Spacer()
                Text("Included in total").font(.caption).foregroundStyle(Tints.secondaryText)
            }
            Text("The categories below cover recognized developer files. Other files are included in the total above. Neither total is an estimate of space safe to reclaim.")
                .font(.caption).foregroundStyle(Tints.secondaryText)
            GeometryReader { proxy in
                HStack(spacing: 3) {
                    ForEach(m.developerGroups.filter { $0.allocatedBytes > 0 }, id: \.category) { item in
                        Rectangle().fill(item.category.color)
                            .frame(width: max(0, (proxy.size.width - CGFloat(max(0, m.developerGroups.filter { $0.allocatedBytes > 0 }.count - 1)) * 3) * CGFloat(item.allocatedBytes) / CGFloat(max(1, total))))
                    }
                }
            }.frame(height: 12).background(Tints.mint.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("Recognized developer storage: \(DiskFormat.bytes(total)). Category totals below.")
            HStack {
                Label("Metadata only · no AI calls", systemImage: "lock.shield").foregroundStyle(Tints.secondaryText)
                Spacer()
                if let date = m.previousDeveloperDate {
                    Text("Changes since \(date.formatted(date: .omitted, time: .shortened))").foregroundStyle(Tints.secondaryText)
                } else { Text("Rescan to measure growth").foregroundStyle(Tints.secondaryText) }
            }.font(.caption)
        }.padding(.vertical, 4)
    }
    private var cleanupOpportunities: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Worth reviewing").font(.title2.weight(.semibold))
                Spacer()
                Button("Review Cleanup (\(m.staged.count))") { m.openStorage(.cleanup) }
            }
            Text("Largest recognized caches and builds. Check what each belongs to before removing it; tools may need to rebuild or download it again.")
                .font(.callout).foregroundStyle(Tints.secondaryText)
            Button("Add Downloadable Caches for Review…", action: m.stageSuggestedCaches)
                .disabled(m.busy || m.monitoring || m.suggestedCacheIDs.isEmpty)
            let findings = Array((m.developerReport?.findings ?? []).lazy.filter {
                [.buildOutputs, .packageCaches, .aiCaches].contains($0.category)
            }.prefix(5))
            if findings.isEmpty {
                Text("No recognized cache or build candidates in this scan. Explore the largest folders to review other files.").foregroundStyle(Tints.secondaryText)
                Button("Explore files") { m.openStorage(.explore) }
            }
            ForEach(findings) { finding in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Image(systemName: finding.category.symbol).foregroundStyle(finding.category.color)
                        Text(finding.tool + " · " + finding.category.title).fontWeight(.medium)
                        Spacer()
                        Text(DiskFormat.bytes(finding.allocatedBytes)).monospacedDigit()
                        Button("Inspect") {
                            if let scan = m.scan, scan.nodes.indices.contains(finding.id) { m.openStorage(.explore); m.open(scan.nodes[finding.id]) }
                        }
                        Button(m.staged.contains(finding.id) ? "Added" : "Add to Cleanup") { m.stage(finding.id) }
                            .disabled(m.busy || m.monitoring || m.staged.contains(finding.id))
                    }
                    CleanupFlag(category: finding.category)
                    Text(finding.consequence).font(.caption).foregroundStyle(Tints.secondaryText)
                }.padding(.vertical, 7)
                    .contextMenu {
                        if let scan = m.scan, scan.nodes.indices.contains(finding.id) { StorageItemMenu(node: scan.nodes[finding.id]) }
                    }
            }
        }
    }
    private func categoryButton(_ item: DeveloperGroup) -> some View {
        Button { category = item.category } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Image(systemName: item.category.symbol).foregroundStyle(item.category.color); Text(item.category.title).font(.system(size: 13, weight: .semibold)); Spacer(minLength: 0) }
                Text(DiskFormat.bytes(item.allocatedBytes)).font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(item.category.color)
                HStack {
                    Text("\(item.fileCount.formatted()) \(item.fileCount == 1 ? "file" : "files")")
                    Spacer(minLength: 2)
                    if let delta = change(item.category) { Text(delta == 0 ? "No change" : (delta > 0 ? "+" : "") + DiskFormat.bytes(delta)) }
                }.font(.caption).foregroundStyle(Tints.secondaryText).lineLimit(1)
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .background(item.category == category ? item.category.color.opacity(0.08) : Color.black, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(item.category == category ? item.category.color : item.category.color.opacity(0.22), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(.plain).accessibilityAddTraits(item.category == category ? .isSelected : [])
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(category.title).font(.title2.weight(.semibold)); Spacer(); Text("LARGEST FIRST").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(Tints.secondaryText) }
            Text(category.detail).font(.callout).foregroundStyle(Tints.secondaryText)
            if let scan = m.scan, let group, !group.rootIDs.isEmpty {
                ForEach(Array(group.rootIDs.prefix(30)), id: \.self) { id in
                    HStack(spacing: 12) {
                        Image(systemName: scan.nodes[id].isDirectory ? "folder.fill" : "doc.text.fill").foregroundStyle(category.color)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(category == .claudeSessions || category == .codexSessions ? StorageLabels.session(scan.nodes[id].name) : StorageLabels.name(scan.nodes[id])).fontWeight(.medium).lineLimit(1)
                            Text(StorageLabels.location(scan.url(for: id).deletingLastPathComponent().path)).help(scan.url(for: id).path).font(.caption).foregroundStyle(Tints.secondaryText).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(DiskFormat.bytes(group.rootAllocatedBytes[id] ?? scan.nodes[id].allocatedBytes)).monospacedDigit()
                        Button("Inspect") { m.openStorage(.explore); m.open(scan.nodes[id]) }
                        Button { m.reveal(id) } label: { Image(systemName: "arrow.up.forward.square") }.help("Reveal in Finder").accessibilityLabel("Reveal \(scan.nodes[id].name) in Finder")
                    }.padding(.vertical, 10).contextMenu { StorageItemMenu(node: scan.nodes[id]) }
                    Divider().overlay(Tints.mint.opacity(0.15))
                }
                if group.rootIDs.count > 30 { Text("Showing the 30 largest of \(group.rootIDs.count.formatted()) matches.").font(.caption).foregroundStyle(Tints.secondaryText) }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: category.symbol).font(.title).foregroundStyle(category.color)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No matches in this folder").fontWeight(.medium)
                        Text("Scan Home for AI sessions, or choose a project folder for dependencies and builds.").font(.callout).foregroundStyle(Tints.secondaryText)
                    }
                }.padding(.vertical, 24)
            }
        }
    }
}

/// Keeps fast scans visible rather than rounding them to 0.00 seconds.
enum SpeedFormat {
    static func duration(_ seconds: Double) -> String {
        if seconds < 0.001 { return "<1 ms" }
        if seconds < 0.1 { return String(format: "%.1f ms", seconds * 1000) }
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        return String(format: "%.2f s", seconds)
    }

    static func entriesPerSecond(entries: Int, elapsed: Double) -> String {
        guard elapsed > 0, elapsed.isFinite else { return "Speed unavailable" }
        return "\(Int((Double(entries) / elapsed).rounded()).formatted()) entries/s"
    }
}

struct CleanupFlag: View {
    let category: DeveloperCategory?
    var body: some View {
        Text(CleanupGuidance.label(for: category))
            .font(.caption.weight(.medium))
            .foregroundStyle(category == .packageCaches ? Tints.mint : Tints.yellow)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(Capsule().stroke((category == .packageCaches ? Tints.mint : Tints.yellow).opacity(0.35)))
            .help("Describes potential recovery, not whether this item is unused. Review contents and stop tools using it before cleanup.")
    }
}
