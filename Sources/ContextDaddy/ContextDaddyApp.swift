import AppKit
import SwiftUI

@main
struct ContextDaddyApp: App {
    @NSApplicationDelegateAdaptor(ContextDaddyAppDelegate.self) private var appDelegate
    @State private var model = ContextDaddyModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 740)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
final class ContextDaddyAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = ContextDoodleArt.appIcon()
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first,
                  let screen = window.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame.insetBy(dx: 18, dy: 18)
            guard !visible.contains(window.frame) else { return }

            var frame = window.frame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = ContextDoodleArt.appIcon()
    }
}
