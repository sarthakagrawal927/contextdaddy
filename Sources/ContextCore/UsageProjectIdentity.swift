import Foundation

public enum UsageProjectIdentity {
    public static func name(_ identity: String) -> String {
        if identity.hasPrefix("-") {
            let parts = identity.split(separator: "-")
            return parts.suffix(2).joined(separator: "-")
        }
        return URL(fileURLWithPath: identity).lastPathComponent
    }

    public static func detail(_ identity: String?) -> String {
        guard let identity else { return "No project identity recorded" }
        return identity.hasPrefix("-") ? "Claude project slug · \(identity)" : identity
    }
}
