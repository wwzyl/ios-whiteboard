import Foundation

struct CBrainSyncResult {
    var uploaded = 0
    var downloaded = 0
    var deletedLocal = 0
    var deletedRemote = 0
    var conflicts = 0

    var summary: String {
        "S3 sync done. Uploaded \(uploaded), downloaded \(downloaded), local deleted \(deletedLocal), remote deleted \(deletedRemote), conflicts \(conflicts)"
    }
}

final class CBrainSyncService {
    private static let manifestPath = ".cbrain-sync/manifest.json"
    private static let lockPrefix = ".cbrain-sync/locks/"
    private static let lockTimeoutMS: Int64 = 2 * 60 * 1000

    private let store: LibraryStore
    private let config: S3Config
    private let s3: S3StorageClient
    private let progress: (String) -> Void
    private let clientId: String
    private let stateKey: String

    init(store: LibraryStore, config: S3Config, progress: @escaping (String) -> Void) throws {
        self.store = store
        self.config = config
        self.s3 = try S3StorageClient(config: config)
        self.progress = progress
        self.clientId = Self.clientId()
        self.stateKey = "s3_state_" + String(S3StorageClient.sha256Hex(Data(store.rootURL.path.utf8)).prefix(16))
    }

    func sync() async throws -> CBrainSyncResult {
        var result = CBrainSyncResult()
        progress("Checking S3 bucket...")
        try await s3.checkBucket()
        try await acquireLock()
        do {
            progress("Scanning local files...")
            let local = try scanLocal()
            let previous = try Self.parseManifest(UserDefaults.standard.string(forKey: stateKey) ?? "")
            progress("Reading remote manifest...")
            let remote = try await readRemoteManifest()
            try await syncFiles(local: local, remote: remote, previous: previous, result: &result)

            let imported = try importOrphanNotes()
            if imported > 0 {
                try await upload("graph.json")
                result.uploaded += 1
            }

            progress("Writing manifest...")
            let finalLocal = try scanLocal()
            let manifest = try manifestJSON(finalLocal)
            try await s3.putObject(config.rootKey(Self.manifestPath), body: Data(manifest.utf8))
            UserDefaults.standard.set(manifest, forKey: stateKey)
            try? await releaseLock()
            return result
        } catch {
            try? await releaseLock()
            throw error
        }
    }

    func downloadAll() async throws -> CBrainSyncResult {
        var result = CBrainSyncResult()
        progress("Checking S3 bucket...")
        try await s3.checkBucket()
        try await acquireLock()
        do {
            progress("Reading remote manifest...")
            let remote = try await readRemoteManifest()
            let paths = remote.keys.sorted()
            for (index, path) in paths.enumerated() {
                if (index + 1) % 10 == 0 {
                    progress("Downloading files \(index + 1)/\(paths.count)...")
                }
                try await download(path, remote: remote[path])
                result.downloaded += 1
            }
            let manifest = try manifestJSON(remote)
            try await s3.putObject(config.rootKey(Self.manifestPath), body: Data(manifest.utf8))
            UserDefaults.standard.set(manifest, forKey: stateKey)
            try? await releaseLock()
            return result
        } catch {
            try? await releaseLock()
            throw error
        }
    }

    private func syncFiles(local: [String: FileMeta], remote: [String: FileMeta], previous: [String: FileMeta], result: inout CBrainSyncResult) async throws {
        let paths = Set(local.keys).union(remote.keys).union(previous.keys)
        let sortedPaths = paths.sorted()
        let firstSyncFromPopulatedRemote = previous.isEmpty && !remote.isEmpty

        for (index, path) in sortedPaths.enumerated() {
            if (index + 1) % 10 == 0 {
                progress("Syncing files \(index + 1)/\(sortedPaths.count)...")
            }
            let l = local[path]
            let r = remote[path]
            let p = previous[path]
            let localChanged = !Self.same(l, p)
            let remoteChanged = !Self.same(r, p)

            if let l, let r {
                if firstSyncFromPopulatedRemote && p == nil && !Self.same(l, r) {
                    try await download(path, remote: r)
                    result.downloaded += 1
                } else if localChanged && remoteChanged && !Self.same(l, r) {
                    if Self.isRemoteNewer(remote: r, local: l) {
                        try await download(path, remote: r)
                        result.downloaded += 1
                    } else if Self.isLocalNewer(local: l, remote: r) {
                        try await upload(path)
                        result.uploaded += 1
                    } else {
                        let conflict = conflictPath(path)
                        if let remoteBytes = try await s3.getObject(config.rootKey(path)) {
                            try store.writeData(conflict, remoteBytes)
                            result.conflicts += 1
                        }
                        try await upload(path)
                        result.uploaded += 1
                    }
                } else if remoteChanged && !Self.same(l, r) {
                    try await download(path, remote: r)
                    result.downloaded += 1
                } else if localChanged && !Self.same(l, r) {
                    try await upload(path)
                    result.uploaded += 1
                }
            } else if let _ = l {
                if firstSyncFromPopulatedRemote && p == nil {
                    store.delete(path)
                    result.deletedLocal += 1
                } else if p != nil && !localChanged {
                    store.delete(path)
                    result.deletedLocal += 1
                } else {
                    try await upload(path)
                    result.uploaded += 1
                }
            } else if let r {
                if p != nil && !remoteChanged {
                    try await s3.deleteObject(config.rootKey(path))
                    result.deletedRemote += 1
                } else if p != nil && remoteChanged {
                    let conflict = conflictPath(path)
                    if let remoteBytes = try await s3.getObject(config.rootKey(path)) {
                        try store.writeData(conflict, remoteBytes)
                        result.conflicts += 1
                    }
                } else {
                    try await download(path, remote: r)
                    result.downloaded += 1
                }
            }
        }
    }

    private func upload(_ path: String) async throws {
        progress("Uploading \(path)")
        try await s3.putObject(config.rootKey(path), body: try store.readData(path))
    }

    private func download(_ path: String, remote: FileMeta?) async throws {
        progress("Downloading \(path)")
        guard let bytes = try await s3.getObject(config.rootKey(path)) else { return }
        try store.writeData(path, bytes)
        if let remote {
            store.setModifiedTime(path, modifiedTime: remote.modifiedTime)
        }
    }

    private func scanLocal() throws -> [String: FileMeta] {
        var output: [String: FileMeta] = [:]
        for file in store.listFilesRecursive() {
            if Self.skipLocal(file.path) { continue }
            let bytes = try store.readData(file.path)
            let modifiedTime = Self.effectiveModifiedTime(path: file.path, bytes: bytes, fallback: file.modifiedTime)
            output[file.path] = FileMeta(
                path: file.path,
                sha256: S3StorageClient.sha256Hex(bytes),
                size: Int64(bytes.count),
                modifiedTime: modifiedTime
            )
        }
        return output
    }

    private func readRemoteManifest() async throws -> [String: FileMeta] {
        if let body = try await s3.getObject(config.rootKey(Self.manifestPath)), !body.isEmpty {
            var manifest = try Self.parseManifest(String(decoding: body, as: UTF8.self))
            await refreshRemoteGraphMeta(&manifest)
            return manifest
        }
        progress("No remote manifest. Building one from S3 objects...")
        return try await scanRemoteObjects()
    }

    private func scanRemoteObjects() async throws -> [String: FileMeta] {
        var output: [String: FileMeta] = [:]
        let root = config.rootKey("")
        let listPrefix = root.isEmpty ? "" : root + "/"
        let objects = try await s3.listObjects(prefix: listPrefix)
        for object in objects {
            guard let path = remotePath(key: object.key, root: root), !Self.skipLocal(path) else { continue }
            guard let bytes = try await s3.getObject(object.key) else { continue }
            let modifiedTime = Self.effectiveModifiedTime(path: path, bytes: bytes, fallback: object.lastModified)
            output[path] = FileMeta(
                path: path,
                sha256: S3StorageClient.sha256Hex(bytes),
                size: Int64(bytes.count),
                modifiedTime: modifiedTime
            )
        }
        return output
    }

    private func refreshRemoteGraphMeta(_ manifest: inout [String: FileMeta]) async {
        guard let graphMeta = manifest["graph.json"] else { return }
        do {
            guard let bytes = try await s3.getObject(config.rootKey("graph.json")) else { return }
            let modifiedTime = Self.effectiveModifiedTime(path: "graph.json", bytes: bytes, fallback: graphMeta.modifiedTime)
            manifest["graph.json"] = FileMeta(
                path: "graph.json",
                sha256: S3StorageClient.sha256Hex(bytes),
                size: Int64(bytes.count),
                modifiedTime: modifiedTime
            )
        } catch {
        }
    }

    private func remotePath(key: String, root: String) -> String? {
        if root.isEmpty { return key }
        guard key.hasPrefix(root + "/") else { return nil }
        return String(key.dropFirst(root.count + 1))
    }

    private func acquireLock() async throws {
        progress("Acquiring sync lock...")
        let root = config.rootKey("")
        var lockPrefix = config.rootKey(Self.lockPrefix)
        if !lockPrefix.isEmpty && !lockPrefix.hasSuffix("/") {
            lockPrefix += "/"
        }
        let locks = try await s3.listObjects(prefix: lockPrefix)
        let now = Self.nowMS()
        for lock in locks {
            if now - lock.lastModified > Self.lockTimeoutMS {
                try await s3.deleteObject(lock.key)
                continue
            }
            if !lock.key.hasSuffix(clientId + ".json") {
                let relative = remotePath(key: lock.key, root: root) ?? lock.key
                throw CBrainError.message("Another client is syncing: \(relative)")
            }
        }
        let body: [String: Any] = [
            "clientId": clientId,
            "updatedTime": now
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
        try await s3.putObject(lockKey(), body: data)
    }

    private func releaseLock() async throws {
        try await s3.deleteObject(lockKey())
    }

    private func lockKey() -> String {
        config.rootKey(Self.lockPrefix + clientId + ".json")
    }

    private func conflictPath(_ path: String) -> String {
        let stamp = Self.conflictStamp()
        let ns = path as NSString
        let folder = ns.deletingLastPathComponent
        let name = ns.lastPathComponent
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let conflictName = ext.isEmpty ? "\(base).remote-conflict-\(stamp)" : "\(base).remote-conflict-\(stamp).\(ext)"
        return folder.isEmpty || folder == "." ? conflictName : folder + "/" + conflictName
    }

    private func importOrphanNotes() throws -> Int {
        guard store.exists("graph.json") && store.exists("notes") else { return 0 }
        let repo = CBrainRepository(store: store)
        try repo.load()
        return try repo.importOrphanMarkdownNotes()
    }

    private func manifestJSON(_ files: [String: FileMeta]) throws -> String {
        var fileJSON: [String: Any] = [:]
        for path in files.keys.sorted() {
            guard let meta = files[path] else { continue }
            fileJSON[path] = [
                "sha256": meta.sha256,
                "size": meta.size,
                "modifiedTime": meta.modifiedTime
            ]
        }
        let root: [String: Any] = [
            "version": 1,
            "updatedTime": Self.nowMS(),
            "clientId": clientId,
            "files": fileJSON
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseManifest(_ json: String) throws -> [String: FileMeta] {
        var output: [String: FileMeta] = [:]
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return output
        }
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = root["files"] as? [String: Any] else {
            return output
        }
        for (path, value) in files {
            guard let item = value as? [String: Any] else { continue }
            output[path] = FileMeta(
                path: path,
                sha256: item["sha256"] as? String ?? "",
                size: int64(item["size"]),
                modifiedTime: int64(item["modifiedTime"])
            )
        }
        return output
    }

    private static func skipLocal(_ path: String?) -> Bool {
        guard let path else { return true }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        return normalized == ".cbrain-sync" || normalized.hasPrefix(".cbrain-sync/")
    }

    private static func same(_ a: FileMeta?, _ b: FileMeta?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.sha256 == b.sha256
    }

    private static func isRemoteNewer(remote: FileMeta, local: FileMeta) -> Bool {
        remote.modifiedTime > local.modifiedTime
    }

    private static func isLocalNewer(local: FileMeta, remote: FileMeta) -> Bool {
        local.modifiedTime > remote.modifiedTime
    }

    private static func effectiveModifiedTime(path: String, bytes: Data, fallback: Int64) -> Int64 {
        guard path == "graph.json" else { return fallback }
        do {
            guard let graph = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                return fallback
            }
            var maxTime: Int64 = 0
            maxTime = maxJSONObjectTime(graph["nodes"], initial: maxTime)
            maxTime = maxJSONObjectTime(graph["links"], initial: maxTime)
            return maxTime > 0 ? maxTime : fallback
        } catch {
            return fallback
        }
    }

    private static func maxJSONObjectTime(_ object: Any?, initial: Int64) -> Int64 {
        guard let dictionary = object as? [String: Any] else { return initial }
        var maxTime = initial
        for value in dictionary.values {
            guard let item = value as? [String: Any] else { continue }
            maxTime = max(maxTime, parseGraphTime(item["updateTime"] as? String ?? ""))
            maxTime = max(maxTime, parseGraphTime(item["createTime"] as? String ?? ""))
        }
        return maxTime
    }

    private static func parseGraphTime(_ value: String) -> Int64 {
        guard !value.isEmpty else { return 0 }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return Int64((formatter.date(from: value)?.timeIntervalSince1970 ?? 0) * 1000)
    }

    private static func nowMS() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func conflictStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func clientId() -> String {
        let key = "s3_client_id"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}

private struct FileMeta: Equatable {
    var path: String
    var sha256: String
    var size: Int64
    var modifiedTime: Int64
}

private func int64(_ value: Any?) -> Int64 {
    if let int = value as? Int64 {
        return int
    }
    if let int = value as? Int {
        return Int64(int)
    }
    if let number = value as? NSNumber {
        return number.int64Value
    }
    if let text = value as? String {
        return Int64(text) ?? 0
    }
    return 0
}
