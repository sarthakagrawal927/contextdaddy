import DiskCore
import SwiftUI
import AppKit
import Darwin

enum DoodleTopic: Int {
    case overview, explore, applications, duplicates, snapshots, monitor, cleanup, thanks, agents
}

/// One cached sprite sheet supplies all decorative page artwork.
struct DoodleArt: View {
    let topic: DoodleTopic
    private static let image = Bundle.main.url(forResource: "PageDoodles", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        GeometryReader { g in
            if let image = Self.image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: g.size.width * 3, height: g.size.height * 3)
                    .offset(x: -CGFloat(topic.rawValue % 3) * g.size.width,
                            y: -CGFloat(topic.rawValue / 3) * g.size.height)
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct ContextIllustration: View {
    private static let image = Bundle.main.url(forResource: "AIContext", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        if let image = Self.image { Image(nsImage: image).resizable().scaledToFit().accessibilityHidden(true) }
    }
}

struct ScanWelcomeView: View {
    let scanDisk: () -> Void
    let scanFolder: () -> Void
    let scanCaches: () -> Void
    var later: (() -> Void)? = nil
    @State private var accessDetails = false
    @State private var accessStatus: FullDiskAccessStatus = .unknown
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Label("Welcome to storagedaddy", systemImage: "sparkle")
                        .font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(Tints.mint)
                    Spacer()
                    if let later { Button("Explore tools first", action: later).font(.caption) }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        introduction.frame(width: 330, alignment: .leading)
                        ContextIllustration().frame(width: 260, height: 190)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ContextIllustration().frame(width: 220, height: 135)
                        introduction
                    }
                }
                Text("Find bulky builds, forgotten caches, installed modules and AI sessions. Your results appear as the scan runs.")
                    .font(.system(size: 15)).foregroundStyle(Tints.secondaryText).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield").foregroundStyle(Tints.mint).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(accessStatusTitle).font(.headline)
                        Text(accessStatusDescription)
                            .font(.callout).foregroundStyle(Tints.secondaryText)
                        if accessStatus != .accessible {
                            HStack(spacing: 12) {
                                Button("Set up Full Disk Access") { accessDetails.toggle() }
                                Text("Or scan just one folder below").font(.caption).foregroundStyle(Tints.secondaryText)
                            }
                        }
                        Text(accessCoverageNote)
                            .font(.caption).foregroundStyle(Tints.secondaryText)
                        if accessDetails && accessStatus != .accessible {
                            Text("Open Privacy & Security → Full Disk Access, add storagedaddy with + and enable it. Reopen the app if macOS asks. This grants broad access to your files; protected and excluded items can still be skipped.")
                                .font(.callout).foregroundStyle(Tints.secondaryText)
                            HStack {
                                Button("Open System Settings") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                                }
                                Button("Show app in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                            }
                        }
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Tints.mint.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tints.mint.opacity(0.2)))
                HStack(spacing: 12) {
                    Button("Scan a Disk…", systemImage: "internaldrive.fill", action: scanDisk)
                        .buttonStyle(StorageButtonStyle(prominent: true)).controlSize(.large)
                    Button("Quick Cache Scan", systemImage: "archivebox", action: scanCaches).controlSize(.large)
                    Button("Scan a Folder…", systemImage: "folder.badge.plus", action: scanFolder)
                        .controlSize(.large)
                }
                Text("Scan a disk for the complete storage picture. Quick Cache Scan checks only your user cache folder; Scan a Folder limits the result to one place.")
                    .font(.callout).foregroundStyle(Tints.secondaryText)
                HStack(alignment: .top, spacing: 20) {
                    step(.overview, "1. Scan", "Choose your storage")
                    step(.explore, "2. Explore", "See what takes space")
                    step(.cleanup, "3. Review", "You decide what goes")
                }
                .padding(.top, 2)
                Text("On your Mac. No uploads. Nothing deleted by a scan.")
                    .font(.system(size: 13)).foregroundStyle(Tints.mint)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color.black).buttonStyle(StorageButtonStyle())
        .onAppear { accessStatus = FullDiskAccessProbe.status() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { accessStatus = FullDiskAccessProbe.status() }
        }
    }

    private var accessStatusTitle: String {
        switch accessStatus {
        case .accessible: "Ready to scan"
        case .limited: "Protected-folder access is limited"
        case .unknown: "Protected-folder access is unknown"
        }
    }

    private var accessStatusDescription: String {
        switch accessStatus {
        case .accessible:
            "Protected-folder access is available. Choose what to scan below."
        case .limited:
            "A protected location was blocked by macOS. Enable storagedaddy in System Settings for broader coverage."
        case .unknown:
            "Access could not be confirmed from the available protected locations. Review the setting before a Mac-wide scan."
        }
    }

    private var accessCoverageNote: String {
        switch accessStatus {
        case .accessible:
            "Some protected or excluded items can still be skipped by macOS."
        case .limited, .unknown:
            "Without Full Disk Access, some locations are skipped and macOS may ask for permission when you scan other protected folders."
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("See what’s taking space.\nStart with a scan.")
                .font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-0.7)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func step(_ topic: DoodleTopic, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            DoodleArt(topic: topic).frame(width: 62, height: 62)
            Text(title).font(.headline)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Tints.secondaryText)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
