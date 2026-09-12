import Foundation
import Darwin

public enum FullDiskAccessStatus: Equatable, Sendable {
    case accessible
    case limited
    case unknown
}

public enum FullDiskAccessProbe {
    // These locations are commonly present and protected by macOS privacy controls.
    // The probe opens and immediately closes a directory handle only; it never
    // enumerates or reads the directory contents.
    private static let protectedLocations = ["Library/Mail", "Library/Messages", "Library/Safari"]

    public static func status(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> FullDiskAccessStatus {
        var foundAccessibleLocation = false
        var foundBlockedLocation = false

        for relativePath in protectedLocations {
            let path = homeDirectory.appendingPathComponent(relativePath).path
            let descriptor = path.withCString { pointer in
                open(pointer, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if descriptor >= 0 {
                close(descriptor)
                foundAccessibleLocation = true
            } else if errno == EACCES || errno == EPERM {
                foundBlockedLocation = true
            }
        }

        if foundBlockedLocation {
            return .limited
        } else if foundAccessibleLocation {
            return .accessible
        } else {
            return .unknown
        }
    }
}
