import Foundation

/// Recoverability guidance, never proof that a folder is unused or safe to delete.
public enum CleanupGuidance {
    public static func label(for category: DeveloperCategory?) -> String {
        switch category {
        case .packageCaches: "Usually downloadable"
        case .buildOutputs: "Possible rebuild"
        case .nodeModules, .installedModules: "Reinstallable dependencies"
        case .claudeSessions, .codexSessions: "Archive first"
        default: "Review first"
        }
    }

    /// Batch suggestions deliberately exclude broad stores, local repositories,
    /// environments and name-only build matches. Existing preflight still applies.
    public static func isSuggestedCache(category: DeveloperCategory, path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        guard category == .packageCaches else { return false }
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let base = URL(fileURLWithPath: home).standardizedFileURL
        let roots = [base.appendingPathComponent("Library/Caches").path, base.appendingPathComponent(".cache").path]
        let aliases = roots.map { "/System/Volumes/Data" + $0 }
        let tool = url.lastPathComponent.lowercased()
        return (roots + aliases).contains(parent)
            && ["npm", "pnpm", "yarn", "pip", "uv", "go-build", "cocoapods", "composer"].contains(tool)
    }
}
