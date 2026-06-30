import Foundation

final class LibraryStore {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    var displayName: String {
        rootURL.lastPathComponent
    }

    var hasCbrainFiles: Bool {
        exists("graph.json") && isDirectory("notes")
    }

    static var appLibraryURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("CBrain Library", isDirectory: true)
    }

    static func appStore() -> LibraryStore? {
        let store = LibraryStore(rootURL: appLibraryURL)
        return store.hasCbrainFiles ? store : nil
    }

    static func ensureAppStore() throws -> LibraryStore {
        let url = appLibraryURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return LibraryStore(rootURL: url)
    }

    static func importLibrary(from sourceURL: URL) throws -> LibraryStore {
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let candidate = LibraryStore(rootURL: sourceURL)
        guard candidate.hasCbrainFiles else {
            throw CBrainError.invalidLibrary
        }

        let destination = appLibraryURL
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceURL, to: destination)
        return LibraryStore(rootURL: destination)
    }

    func readText(_ relativePath: String) throws -> String {
        let data = try readData(relativePath)
        return String(decoding: data, as: UTF8.self)
    }

    func readMarkdownText(_ relativePath: String) throws -> String {
        let exact = url(relativePath)
        if FileManager.default.fileExists(atPath: exact.path) {
            return try readText(relativePath)
        }
        for alias in markdownAliases(relativePath) where FileManager.default.fileExists(atPath: alias.path) {
            let text = String(decoding: try Data(contentsOf: alias), as: UTF8.self)
            try writeText(relativePath, text)
            try? FileManager.default.removeItem(at: alias)
            return text
        }
        return ""
    }

    func readData(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }

    func writeText(_ relativePath: String, _ text: String) throws {
        try writeData(relativePath, Data(text.utf8))
    }

    func writeMarkdownText(_ relativePath: String, _ text: String) throws {
        try writeText(relativePath, text)
        for alias in markdownAliases(relativePath) {
            try? FileManager.default.removeItem(at: alias)
        }
    }

    func writeData(_ relativePath: String, _ data: Data) throws {
        let target = url(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    func delete(_ relativePath: String) {
        try? FileManager.default.removeItem(at: url(relativePath))
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(relativePath).path)
    }

    func isDirectory(_ relativePath: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url(relativePath).path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func listMarkdownFiles(_ relativePath: String) -> [String] {
        let folder = url(relativePath)
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return children
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { $0.lastPathComponent }
            .sorted()
    }

    func listFilesRecursive() -> [CBrainFileRecord] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var records: [CBrainFileRecord] = []
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let path = relativePath(for: fileURL)
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            records.append(CBrainFileRecord(
                path: path,
                size: Int64(values?.fileSize ?? 0),
                modifiedTime: Int64((values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
            ))
        }
        return records
    }

    func setModifiedTime(_ relativePath: String, modifiedTime: Int64) {
        guard modifiedTime > 0 else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(modifiedTime) / 1000)], ofItemAtPath: url(relativePath).path)
    }

    func url(_ relativePath: String) -> URL {
        let parts = normalize(relativePath).split(separator: "/").map(String.init)
        return parts.reduce(rootURL) { partial, part in
            partial.appendingPathComponent(part)
        }
    }

    private func relativePath(for fileURL: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let file = fileURL.standardizedFileURL.path
        guard file.hasPrefix(root) else {
            return fileURL.lastPathComponent
        }
        return String(file.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func markdownAliases(_ relativePath: String) -> [URL] {
        let normalized = normalize(relativePath)
        guard normalized.lowercased().hasSuffix(".md") else { return [] }
        let exact = url(normalized)
        let base = exact.deletingPathExtension().lastPathComponent
        let parent = exact.deletingLastPathComponent()
        return [
            parent.appendingPathComponent(exact.lastPathComponent + ".txt"),
            parent.appendingPathComponent(base + ".txt")
        ]
    }

    private func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
