import Foundation
import CryptoKit

public struct SkillChangePlan: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let destination: String
    public let detail: String
    public let before: String
    public let after: String
    public let fileChanges: [String]
    fileprivate let operation: Operation
    fileprivate let expected: String?
    fileprivate let files: [String: Data]
    fileprivate let source: String?
    fileprivate let permissions: [String: Int]
    fileprivate enum Operation: Sendable { case create, edit, update, archive, link, unlink }
}

public struct SkillChangeReceipt: Identifiable, Codable, Sendable {
    public let id: UUID
    public let title: String
    public let destination: String
    public let date: Date
    public let backupPath: String?
    public let resultingFingerprint: String?
    public let kind: String
    public var restored: Bool
    public var completed: Bool
}

public struct SkillManagementError: LocalizedError, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// All writes are explicit, previewed, serialized and restricted to skill definitions or links.
/// Backups live outside discovery roots. This does not execute imported scripts or modify agent configuration.
public actor SkillLibraryManager {
    private let storage: URL
    private let fm = FileManager.default
    private var plans: [UUID: SkillChangePlan] = [:]
    public init(storage: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ContextDaddy/SkillHistory")) {
        self.storage = storage
    }

    public func history() throws -> [SkillChangeReceipt] {
        guard fm.fileExists(atPath: storage.path) else { return [] }
        try safePath(storage)
        return try fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(SkillChangeReceipt.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    public func prepareEdit(skill: URL, text: String) throws -> SkillChangePlan {
        try editable(skill)
        let before = try document(skill)
        try validate(text)
        return remember(.init(id: UUID(), title: "Save skill content", destination: skill.path,
            detail: "Updates this physical definition and every agent link pointing to it. A copy of the current document is retained.",
            before: before, after: text, fileChanges: ["Modified: SKILL.md"], operation: .edit, expected: digest(Data(before.utf8)),
            files: ["SKILL.md": Data(text.utf8)], source: nil, permissions: [:]))
    }

    public func prepareCreate(parent: URL, name: String, text: String) throws -> SkillChangePlan {
        guard name.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil else {
            throw failure("Use a skill folder name of 1–64 lowercase letters, numbers, or hyphens.")
        }
        try validate(text)
        return try prepareInstall(destination: parent.appendingPathComponent(name), files: ["SKILL.md": Data(text.utf8)], update: false)
    }

    public func prepareImport(source: URL, parent: URL) throws -> SkillChangePlan {
        let files = try tree(source)
        return try prepareInstall(destination: parent.appendingPathComponent(source.lastPathComponent), files: files, update: false, permissions: try filePermissions(source, names: Array(files.keys)))
    }

    public func prepareUpdate(skill: URL, source: URL) throws -> SkillChangePlan {
        try editable(skill)
        let files = try tree(source)
        return try prepareInstall(destination: skill.deletingLastPathComponent(), files: files, update: true, permissions: try filePermissions(source, names: Array(files.keys)))
    }

    public func prepareArchive(skill: URL) throws -> SkillChangePlan {
        try editable(skill)
        let folder = skill.deletingLastPathComponent()
        let files = try tree(folder)
        return remember(.init(id: UUID(), title: "Archive skill", destination: folder.path,
            detail: "Moves the entire definition folder into recoverable history. Existing links to this source will stop resolving until it is restored. Review every location first.",
            before: try document(skill), after: "", fileChanges: files.keys.sorted().map { "Archive: \($0)" }, operation: .archive, expected: fingerprint(files), files: [:], source: nil, permissions: [:]))
    }

    public func prepareLink(skill: URL, parent: URL) throws -> SkillChangePlan {
        try editable(skill)
        let folder = skill.deletingLastPathComponent()
        let destination = parent.appendingPathComponent(folder.lastPathComponent)
        try writable(destination)
        guard !exists(destination) else { throw failure("The destination already exists. Nothing will be overwritten.") }
        guard !destination.path.hasPrefix(folder.path + "/") else { throw failure("A skill cannot be linked inside itself.") }
        let before = try document(skill)
        return remember(.init(id: UUID(), title: "Share skill by link", destination: destination.path,
            detail: "Creates one directory link to \(folder.path). No second copy. Invocation remains governed by the receiving agent.",
            before: "", after: folder.path, fileChanges: ["New directory link"], operation: .link, expected: digest(Data(before.utf8)), files: [:], source: folder.path, permissions: [:]))
    }

    public func prepareUnlink(path: URL) throws -> SkillChangePlan {
        try writable(path.deletingLastPathComponent())
        guard try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true else {
            throw failure("Only a directory link can be removed here. The physical source is never removed by this action.")
        }
        let target = try fm.destinationOfSymbolicLink(atPath: path.path)
        return remember(.init(id: UUID(), title: "Remove exposure link", destination: path.path,
            detail: "Moves only this link into recoverable history; other exposures and the physical skill remain in place.",
            before: target, after: "", fileChanges: ["Remove directory link only"], operation: .unlink, expected: target, files: [:], source: nil, permissions: [:]))
    }

    public func apply(_ id: UUID) throws -> SkillChangeReceipt {
        guard let plan = plans.removeValue(forKey: id) else { throw failure("This preview has expired. Prepare it again.") }
        let destination = URL(fileURLWithPath: plan.destination)
        try safePath(storage)
        try fm.createDirectory(at: storage, withIntermediateDirectories: true)
        let backup = storage.appendingPathComponent(plan.id.uuidString)
        var backupPath: String?
        var result: String?
        // Persist intent before the first mutation. Interrupted operations remain visible
        // with their recovery location rather than silently losing their provenance.
        let willBackUp = [.edit, .update, .archive, .unlink].contains(plan.operation)
        let intent = SkillChangeReceipt(id: plan.id, title: plan.title, destination: plan.destination, date: Date(),
            backupPath: willBackUp ? backup.path : nil, resultingFingerprint: nil,
            kind: String(describing: plan.operation), restored: false, completed: false)
        try save(intent)
        switch plan.operation {
        case .edit:
            try editable(destination)
            guard digest(Data(try document(destination).utf8)) == plan.expected else { throw failure("The skill changed since preview. Reload before saving.") }
            try fm.copyItem(at: destination, to: backup)
            backupPath = backup.path
            try plan.files["SKILL.md"]!.write(to: destination, options: .atomic)
            result = digest(plan.files["SKILL.md"]!)
        case .create, .update:
            try writable(destination)
            if plan.operation == .update {
                guard fingerprint(try tree(destination)) == plan.expected else { throw failure("The folder changed since preview. Review the update again.") }
            } else if exists(destination) { throw failure("The destination appeared after preview. Nothing was overwritten.") }
            let stage = storage.appendingPathComponent("stage-\(plan.id)")
            try writeTree(plan.files, to: stage, permissions: plan.permissions)
            if plan.operation == .update {
                try fm.moveItem(at: destination, to: backup)
                backupPath = backup.path
            }
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: stage, to: destination)
            } catch {
                if backupPath != nil { try fm.moveItem(at: backup, to: destination) }
                throw error
            }
            result = fingerprint(plan.files)
        case .archive:
            try writable(destination)
            guard fingerprint(try tree(destination)) == plan.expected else { throw failure("The folder changed since preview. Review it again.") }
            try fm.moveItem(at: destination, to: backup)
            backupPath = backup.path
        case .link:
            try writable(destination)
            let source = URL(fileURLWithPath: plan.source!)
            try editable(source.appendingPathComponent("SKILL.md"))
            guard digest(Data(try document(source.appendingPathComponent("SKILL.md")).utf8)) == plan.expected else { throw failure("The source changed since preview.") }
            guard !exists(destination) else { throw failure("The destination already exists.") }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: destination, withDestinationURL: source)
            result = source.path
        case .unlink:
            try writable(destination.deletingLastPathComponent())
            guard try fm.destinationOfSymbolicLink(atPath: destination.path) == plan.expected else { throw failure("The link changed since preview.") }
            try fm.moveItem(at: destination, to: backup)
            backupPath = backup.path
        }
        let receipt = SkillChangeReceipt(id: plan.id, title: plan.title, destination: plan.destination, date: Date(),
            backupPath: backupPath, resultingFingerprint: result, kind: String(describing: plan.operation), restored: false, completed: true)
        try save(receipt)
        return receipt
    }

    /// Restores only if the applied result is still intact. New work is never overwritten.
    public func restore(_ id: UUID) throws {
        guard var receipt = try history().first(where: { $0.id == id }), !receipt.restored, receipt.completed else { throw failure("This change is no longer available to restore.") }
        let destination = URL(fileURLWithPath: receipt.destination)
        try writable(destination.deletingLastPathComponent())
        let displaced = storage.appendingPathComponent("replaced-\(UUID())")
        if receipt.kind == "archive" || receipt.kind == "unlink" {
            guard !exists(destination) else { throw failure("The original location is occupied. Move that item before restoring.") }
        } else if receipt.kind == "link" {
            guard try fm.destinationOfSymbolicLink(atPath: destination.path) == receipt.resultingFingerprint else { throw failure("The link changed after this action.") }
            try fm.moveItem(at: destination, to: displaced)
        } else {
            try writable(destination)
            let current = receipt.kind == "edit" ? digest(Data(try document(destination).utf8)) : fingerprint(try tree(destination))
            guard current == receipt.resultingFingerprint else { throw failure("The skill changed after this action. Restore would overwrite newer work.") }
            try fm.moveItem(at: destination, to: displaced)
        }
        if let path = receipt.backupPath {
            let backup = URL(fileURLWithPath: path)
            guard backup.deletingLastPathComponent().path == storage.path else { throw failure("Invalid recovery location.") }
            do { try fm.moveItem(at: backup, to: destination) }
            catch {
                if exists(displaced) { try fm.moveItem(at: displaced, to: destination) }
                throw error
            }
        }
        receipt.restored = true
        try save(receipt)
    }

    private func prepareInstall(destination: URL, files: [String: Data], update: Bool, permissions: [String: Int] = [:]) throws -> SkillChangePlan {
        try writable(destination)
        guard let data = files["SKILL.md"], let text = String(data: data, encoding: .utf8) else { throw failure("Select a folder containing SKILL.md.") }
        try validate(text)
        let original = update ? try tree(destination) : [:]
        if !update && exists(destination) { throw failure("That skill folder already exists. Select it in the library to update it.") }
        let added = files.keys.filter { original[$0] == nil }.count
        let removed = original.keys.filter { files[$0] == nil }.count
        let changed = files.keys.filter { original[$0] != nil && original[$0] != files[$0] }.count
        let changes = Set(files.keys).union(original.keys).sorted().compactMap { name -> String? in
            if original[name] == files[name] { return nil }
            return "\(original[name] == nil ? "Added" : files[name] == nil ? "Removed" : "Modified"): \(name)"
        }
        return remember(.init(id: UUID(), title: update ? "Update from folder" : "Install local skill", destination: destination.path,
            detail: "\(files.count) files · \(added) added · \(changed) changed · \(removed) removed. \(update ? "The previous folder is retained for recovery. Existing links continue to point here." : "Imported scripts are not executed.")",
            before: original["SKILL.md"].flatMap { String(data: $0, encoding: .utf8) } ?? "", after: text, fileChanges: changes,
            operation: update ? .update : .create, expected: update ? fingerprint(original) : nil, files: files, source: nil, permissions: permissions))
    }

    private func tree(_ root: URL) throws -> [String: Data] {
        try safePath(root)
        guard root.lastPathComponent != "/", fm.fileExists(atPath: root.appendingPathComponent("SKILL.md").path) else { throw failure("Select one skill folder containing SKILL.md.") }
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], errorHandler: { _, error in enumerationError = error; return false }) else { throw failure("Cannot read this skill folder.") }
        var files: [String: Data] = [:]
        var bytes = 0
        var entries = 0
        for case let file as URL in enumerator {
            entries += 1
            guard entries <= 2_000 else { throw failure("This folder exceeds the 2,000-entry management limit.") }
            try safePath(file)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw failure("Only regular files and folders can be imported or archived.") }
            bytes += values.fileSize ?? 0
            guard bytes <= 16 * 1024 * 1024 else { throw failure("This folder exceeds the 16 MiB management limit.") }
            let data = try Data(contentsOf: file)
            let relative = String(file.path.dropFirst(root.path.count + 1))
            files[relative] = data
        }
        if let enumerationError { throw enumerationError }
        guard let skill = files["SKILL.md"], let text = String(data: skill, encoding: .utf8) else { throw failure("SKILL.md must be UTF-8 text.") }
        try validate(text)
        return files
    }

    private func writeTree(_ files: [String: Data], to root: URL, permissions: [String: Int]) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, data) in files {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .withoutOverwriting)
            if let mode = permissions[name] { try fm.setAttributes([.posixPermissions: mode & 0o777], ofItemAtPath: url.path) }
        }
    }
    private func filePermissions(_ root: URL, names: [String]) throws -> [String: Int] {
        try Dictionary(uniqueKeysWithValues: names.map { name in
            let url = root.appendingPathComponent(name)
            try safePath(url)
            let mode = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            return (name, mode?.intValue ?? 0o644)
        })
    }
    private func document(_ url: URL) throws -> String {
        let doc = try SkillDocumentReader.read(url: url)
        guard !doc.truncated else { throw failure("This document exceeds the editable size limit.") }
        return doc.text
    }
    private func validate(_ text: String) throws {
        guard !text.utf8.contains(0), text.utf8.count <= SkillDocumentReader.maximumBytes else { throw failure("Skill content must be UTF-8 text under 256 KiB.") }
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { throw failure("SKILL.md needs a closed YAML frontmatter block.") }
        let metadata = lines[1..<end]
        for key in ["name:", "description:"] {
            guard metadata.contains(where: { $0.hasPrefix(key) && !$0.dropFirst(key.count).trimmingCharacters(in: .whitespaces).isEmpty }) else {
                throw failure("Frontmatter needs a non-empty \(key.dropLast()) field.")
            }
        }
    }
    private func editable(_ url: URL) throws {
        guard url.lastPathComponent == "SKILL.md" else { throw failure("Only SKILL.md can be edited.") }
        try writable(url)
    }
    private func writable(_ url: URL) throws {
        guard SkillOwnership.classify(path: url.path) == .local else { throw failure("This skill is managed by its plugin or system owner. Use that owner to change it.") }
        try safePath(url)
    }
    private func safePath(_ url: URL) throws {
        guard url.isFileURL, !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { throw failure("Use a normalized absolute path.") }
        let forbidden: Set<String> = [".ssh", ".aws", ".kube", ".git", "credentials", "credentials.json", "secrets", "secrets.json", "auth.json", "config.toml", "settings.json", ".dev.vars"]
        var current = URL(fileURLWithPath: "/")
        for part in url.pathComponents.dropFirst() {
            let name = part.lowercased()
            guard !forbidden.contains(name), name != ".env", !name.hasPrefix(".env."), !name.hasSuffix(".pem"), !name.hasSuffix(".key") else { throw failure("This folder includes protected configuration or credential files. Select a self-contained skill folder.") }
            current.appendPathComponent(part)
            if let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw failure("The path contains a symbolic link at \(current.path). Select its physical source from the library.")
            }
        }
    }
    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func fingerprint(_ files: [String: Data]) -> String {
        digest(Data(files.keys.sorted().map { "\($0):\(digest(files[$0]!))" }.joined(separator: "\n").utf8))
    }
    private func remember(_ plan: SkillChangePlan) -> SkillChangePlan {
        if plans.count > 20 { plans.removeAll() }
        plans[plan.id] = plan
        return plan
    }
    private func save(_ receipt: SkillChangeReceipt) throws {
        try JSONEncoder().encode(receipt).write(to: storage.appendingPathComponent("\(receipt.id).json"), options: .atomic)
    }
    private func failure(_ message: String) -> SkillManagementError { .init(message: message) }
}
