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
    private static let infoPath = ".cbrain-sync/info.json"
    private static let syncVersion = 5
    private static let tombstonesPath = ".cbrain-sync/tombstones.json"
    private static let deletionsPrefix = ".cbrain-sync/deletions/"
    private static let localTombstonesPath = ".cbrain-tombstones.json"
    private static let localGraphBasePath = ".cbrain-sync/ios-graph-base.json"
    private static let localDrawingsBasePath = ".cbrain-sync/ios-drawings-base.json"
    private static let localRemoteDeltaPath = ".cbrain-sync/ios-remote-delta.json"
    private static let lockPrefix = ".cbrain-sync/locks/"
    private static let syncLockType = "sync"
    private static let exclusiveLockType = "exclusive"
    private static let lockClientType = "mobile"
    private static let lockTimeoutMS: Int64 = 3 * 60 * 1000
    private static let lockRefreshIntervalMS: Int64 = 60 * 1000
    private static let deleteFailSafePercent = 90
    private static let deleteFailSafeMinimum = 10

    private let store: LibraryStore
    private let config: S3Config
    private let s3: S3StorageClient
    private let progress: (String) -> Void
    private let clientId: String
    private let stateKey: String
    private var lastLockRefresh: Int64 = 0
    private var activeLockType = "sync"

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
        try await upgradeSyncTargetVersionIfNeeded()
        activeLockType = Self.syncLockType
        try await acquireLock()
        do {
            try await ensureSyncTargetVersion()
            progress("Scanning local files...")
            var local = try scanLocal()
            let previous = try Self.parseManifest(UserDefaults.standard.string(forKey: stateKey) ?? "")
            progress("Reading remote manifest...")
            var remote = try await readRemoteManifest()
            let tombstones = try await readMergedTombstones()
            let tombstoneData = try tombstonesJSON(tombstones)
            try store.writeData(Self.localTombstonesPath, tombstoneData)
            try await uploadDeletionEvents(tombstones)
            try await applyTombstones(
                local: &local,
                remote: &remote,
                previous: previous,
                tombstones: tombstones,
                result: &result
            )
            try await syncFiles(local: local, remote: remote, previous: previous, result: &result)

            try saveGraphBase()
            try saveDrawingsBase()

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
        try await upgradeSyncTargetVersionIfNeeded()
        activeLockType = Self.syncLockType
        try await acquireLock()
        do {
            try await ensureSyncTargetVersion()
            progress("Reading remote manifest...")
            let remote = try await readRemoteManifest()
            let paths = remote.keys.sorted()
            for (index, path) in paths.enumerated() {
                try await refreshLockIfNeeded()
                if (index + 1) % 10 == 0 {
                    progress("Downloading files \(index + 1)/\(paths.count)...")
                }
                try await download(path, remote: remote[path])
                result.downloaded += 1
            }
            try saveGraphBase()
            try saveDrawingsBase()
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
        var localState = local
        var remoteState = remote
        var checkpointState = previous
        let paths = Set(local.keys).union(remote.keys).union(previous.keys)
        let sortedPaths = paths.sorted()
        let firstSyncFromPopulatedRemote = previous.isEmpty && !remote.isEmpty
        let remoteMissingDeletes = sortedPaths.reduce(into: 0) { count, path in
            if !Self.isContainerPath(path), local[path] != nil, remote[path] == nil, previous[path] != nil,
               Self.same(local[path], previous[path]) {
                count += 1
            }
        }
        try Self.assertDeletionSafe(side: "local after remote deletion", deletes: remoteMissingDeletes, total: local.count)

        progress("Uploading local changes...")
        for (index, path) in sortedPaths.enumerated() {
            try await refreshLockIfNeeded()
            if (index + 1) % 10 == 0 {
                progress("Uploading changes \(index + 1)/\(sortedPaths.count)...")
            }
            let l = localState[path]
            let r = remoteState[path]
            let p = previous[path]
            let localChanged = !Self.same(l, p)
            let remoteChanged = !Self.same(r, p)

            if Self.isContainerPath(path) { continue }
            if let l, let r {
                if firstSyncFromPopulatedRemote && p == nil && !Self.same(l, r) {
                    try await preserveLocalAndDownload(path, remote: r, result: &result)
                    localState[path] = r
                    try checkpoint(&checkpointState, path: path, meta: r)
                } else if localChanged && remoteChanged && !Self.same(l, r) {
                    try await resolveConcurrentChange(path, local: l, remote: r, result: &result)
                    localState[path] = r
                    try checkpoint(&checkpointState, path: path, meta: r)
                } else if localChanged && !remoteChanged && !Self.same(l, r) {
                    try await uploadConditional(path, expectedRemote: r)
                    result.uploaded += 1
                    remoteState[path] = l
                    try checkpoint(&checkpointState, path: path, meta: l)
                }
            } else if let l = l, p == nil {
                try await uploadConditional(path, expectedRemote: nil)
                result.uploaded += 1
                remoteState[path] = l
                try checkpoint(&checkpointState, path: path, meta: l)
            }
        }

        progress("Fetching remote delta...")
        for (index, path) in sortedPaths.enumerated() {
            try await refreshLockIfNeeded()
            if (index + 1) % 10 == 0 {
                progress("Fetching changes \(index + 1)/\(sortedPaths.count)...")
            }
            let l = localState[path]
            let r = remoteState[path]
            let p = previous[path]
            let localChanged = !Self.same(l, p)
            let remoteChanged = !Self.same(r, p)

            if let l, let r {
                if path == "graph.json" && !Self.same(l, r) {
                    try await mergeGraphWithRemote(r, result: &result)
                    let mergedMeta = try scanLocal()[path]
                    try checkpoint(&checkpointState, path: path, meta: mergedMeta)
                } else if path == "drawings.json" && !Self.same(l, r) {
                    try await mergeDrawingsWithRemote(r, result: &result)
                    let mergedMeta = try scanLocal()[path]
                    try checkpoint(&checkpointState, path: path, meta: mergedMeta)
                } else if remoteChanged && !localChanged && !Self.same(l, r) {
                    try await download(path, remote: r)
                    result.downloaded += 1
                    try checkpoint(&checkpointState, path: path, meta: r)
                }
            } else if l != nil && r == nil {
                if Self.isContainerPath(path) {
                    try await uploadConditional(path, expectedRemote: nil)
                    result.uploaded += 1
                    try checkpoint(&checkpointState, path: path, meta: l)
                } else if p != nil && !localChanged {
                    store.delete(path)
                    store.deleteMarkdownAliases(path)
                    result.deletedLocal += 1
                    try checkpoint(&checkpointState, path: path, meta: nil)
                } else if p != nil {
                    try await preserveLocalForDeletion(path, result: &result)
                    store.delete(path)
                    store.deleteMarkdownAliases(path)
                    result.deletedLocal += 1
                    try checkpoint(&checkpointState, path: path, meta: nil)
                }
            } else if l == nil, let r = r {
                try await download(path, remote: r)
                result.downloaded += 1
                try checkpoint(&checkpointState, path: path, meta: r)
            }
        }
    }

    private func readMergedTombstones() async throws -> [String: Tombstone] {
        var output: [String: Tombstone] = [:]
        if store.exists(Self.localTombstonesPath) {
            Self.mergeTombstones(target: &output, source: try Self.parseTombstones(store.readData(Self.localTombstonesPath)))
        }
        if let remote = try await s3.getObject(config.rootKey(Self.tombstonesPath)), !remote.isEmpty {
            Self.mergeTombstones(target: &output, source: try Self.parseTombstones(remote))
        }
        var prefix = config.rootKey(Self.deletionsPrefix)
        if !prefix.isEmpty && !prefix.hasSuffix("/") { prefix += "/" }
        for object in try await s3.listObjects(prefix: prefix) {
            try await refreshLockIfNeeded()
            guard let data = try await s3.getObject(object.key), !data.isEmpty,
                  let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let path = event["path"] as? String ?? ""
            let deletedTime = int64(event["deletedTime"])
            if !path.isEmpty && deletedTime > 0 {
                Self.mergeTombstones(target: &output, source: [path: Tombstone(path: path, deletedTime: deletedTime)])
            }
        }
        return output
    }

    private func uploadDeletionEvents(_ tombstones: [String: Tombstone]) async throws {
        for tombstone in tombstones.values {
            try await refreshLockIfNeeded()
            let event: [String: Any] = [
                "path": tombstone.path,
                "deletedTime": tombstone.deletedTime,
                "clientId": clientId
            ]
            let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            let id = S3StorageClient.sha256Hex(Data(tombstone.path.utf8))
            let key = Self.deletionsPrefix + id + "-\(tombstone.deletedTime).json"
            try await s3.putObject(config.rootKey(key), body: data)
        }
    }

    private func ensureSyncTargetVersion() async throws {
        if let body = try await s3.getObject(config.rootKey(Self.infoPath)), !body.isEmpty,
           let info = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let version = Int(int64(info["version"]))
            let minimumVersion = Int(int64(info["minimumVersion"]))
            if version > Self.syncVersion || minimumVersion > Self.syncVersion {
                throw CBrainError.message("Sync target requires protocol version \(max(version, minimumVersion))")
            }
            if version == Self.syncVersion && minimumVersion == Self.syncVersion { return }
        }
        let info: [String: Any] = [
            "version": Self.syncVersion,
            "minimumVersion": Self.syncVersion,
            "updatedTime": Self.nowMS(),
            "clientId": clientId
        ]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        try await s3.putObject(config.rootKey(Self.infoPath), body: data)
    }

    private func upgradeSyncTargetVersionIfNeeded() async throws {
        if let body = try await s3.getObject(config.rootKey(Self.infoPath)), !body.isEmpty,
           let info = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let version = Int(int64(info["version"]))
            let minimumVersion = Int(int64(info["minimumVersion"]))
            if version > Self.syncVersion || minimumVersion > Self.syncVersion {
                throw CBrainError.message("Sync target requires protocol version \(max(version, minimumVersion))")
            }
            if version == Self.syncVersion && minimumVersion == Self.syncVersion { return }
        }
        activeLockType = Self.exclusiveLockType
        try await acquireLock()
        do {
            try await ensureSyncTargetVersion()
            try? await releaseLock()
            activeLockType = Self.syncLockType
        } catch {
            try? await releaseLock()
            activeLockType = Self.syncLockType
            throw error
        }
    }

    private func applyTombstones(
        local: inout [String: FileMeta],
        remote: inout [String: FileMeta],
        previous: [String: FileMeta],
        tombstones: [String: Tombstone],
        result: inout CBrainSyncResult
    ) async throws {
        var localDeletes = 0
        var remoteDeletes = 0
        for tombstone in tombstones.values where tombstone.path != "graph.json" {
            if Self.tombstoneWins(tombstone, meta: local[tombstone.path]) { localDeletes += 1 }
            if Self.tombstoneWins(tombstone, meta: remote[tombstone.path]) { remoteDeletes += 1 }
        }
        try Self.assertDeletionSafe(side: "local", deletes: localDeletes, total: local.count)
        try Self.assertDeletionSafe(side: "remote", deletes: remoteDeletes, total: remote.count)

        for tombstone in tombstones.values {
            try await refreshLockIfNeeded()
            if tombstone.path == "graph.json" { continue }
            let l = local[tombstone.path]
            let r = remote[tombstone.path]
            let p = previous[tombstone.path]
            let deleteLocal = Self.tombstoneWins(tombstone, meta: l)
            let deleteRemote = Self.tombstoneWins(tombstone, meta: r)
            if !deleteLocal && !deleteRemote { continue }

            if deleteLocal, let l, !Self.same(l, p) {
                try await preserveLocalForDeletion(tombstone.path, result: &result)
            }
            if deleteRemote, let r, !Self.same(r, p) {
                try await preserveRemoteForDeletion(tombstone.path, result: &result)
            }
            if deleteLocal {
                store.delete(tombstone.path)
                store.deleteMarkdownAliases(tombstone.path)
                local.removeValue(forKey: tombstone.path)
                result.deletedLocal += 1
            }
            if deleteRemote {
                try await deleteRemoteConditional(tombstone.path, expectedRemote: r)
                remote.removeValue(forKey: tombstone.path)
                result.deletedRemote += 1
            }
        }
    }

    private func deleteRemoteConditional(_ path: String, expectedRemote: FileMeta?) async throws {
        let key = config.rootKey(path)
        guard let version = try await s3.getObjectVersion(key) else { return }
        guard let expectedRemote,
              S3StorageClient.sha256Hex(version.body) == expectedRemote.sha256 else {
            throw S3PreconditionFailedError(key: key)
        }
        try await s3.deleteObjectConditional(key, expectedETag: version.eTag)
    }

    private func preserveLocalForDeletion(_ path: String, result: inout CBrainSyncResult) async throws {
        let conflict = conflictPath(path, source: "local")
        try store.writeData(conflict, store.readData(path))
        try await upload(conflict)
        result.conflicts += 1
        result.uploaded += 1
    }

    private func preserveRemoteForDeletion(_ path: String, result: inout CBrainSyncResult) async throws {
        guard let bytes = try await s3.getObject(config.rootKey(path)) else { return }
        let conflict = conflictPath(path, source: "remote")
        try store.writeData(conflict, bytes)
        try await upload(conflict)
        result.conflicts += 1
        result.uploaded += 1
    }

    private static func tombstoneWins(_ tombstone: Tombstone, meta: FileMeta?) -> Bool {
        guard let meta else { return false }
        return tombstone.deletedTime >= meta.modifiedTime
    }

    private static func assertDeletionSafe(side: String, deletes: Int, total: Int) throws {
        if deletes >= deleteFailSafeMinimum && deletes * 100 >= max(1, total) * deleteFailSafePercent {
            throw CBrainError.message("Sync fail-safe stopped deletion of \(deletes)/\(total) \(side) files")
        }
    }

    private func resolveConcurrentChange(_ path: String, local: FileMeta, remote: FileMeta, result: inout CBrainSyncResult) async throws {
        try await preserveLocalAndDownload(path, remote: remote, result: &result)
    }

    private func preserveLocalAndDownload(_ path: String, remote: FileMeta, result: inout CBrainSyncResult) async throws {
        let conflict = conflictPath(path, source: "local")
        try store.writeData(conflict, try store.readData(path))
        try await upload(conflict)
        try await download(path, remote: remote)
        result.conflicts += 1
        result.uploaded += 1
        result.downloaded += 1
    }

    private func preserveRemoteAndUpload(_ path: String, result: inout CBrainSyncResult) async throws {
        if let remoteBytes = try await s3.getObject(config.rootKey(path)) {
            let conflict = conflictPath(path, source: "remote")
            try store.writeData(conflict, remoteBytes)
            try await upload(conflict)
            result.uploaded += 1
        }
        try await upload(path)
        result.conflicts += 1
        result.uploaded += 1
    }

    private func upload(_ path: String) async throws {
        progress("Uploading \(path)")
        try await s3.putObject(config.rootKey(path), body: try store.readData(path))
    }

    private func uploadConditional(_ path: String, expectedRemote: FileMeta?) async throws {
        progress("Uploading \(path)")
        let key = config.rootKey(path)
        let version = try await s3.getObjectVersion(key)
        if let expectedRemote {
            guard let version,
                  S3StorageClient.sha256Hex(version.body) == expectedRemote.sha256 else {
                throw S3PreconditionFailedError(key: key)
            }
        } else if version != nil {
            throw S3PreconditionFailedError(key: key)
        }
        try await s3.putObjectConditional(key, body: try store.readData(path), expectedETag: version?.eTag)
    }

    private func mergeGraphWithRemote(_ remote: FileMeta, result: inout CBrainSyncResult) async throws {
        progress("Merging graph.json")
        guard let remoteVersion = try await s3.getObjectVersion(config.rootKey("graph.json")) else { return }
        let remoteBytes = remoteVersion.body
        let localBytes = try store.readData("graph.json")
        let baseBytes: Data?
        if store.exists(Self.localGraphBasePath) {
            baseBytes = try store.readData(Self.localGraphBasePath)
        } else {
            baseBytes = nil
        }
        let merged = try Self.mergeGraphData(local: localBytes, remote: remoteBytes, base: baseBytes)
        if merged.conflicts > 0 {
            let conflict = conflictPath("graph.json", source: "local")
            try store.writeData(conflict, localBytes)
            try await upload(conflict)
            result.uploaded += 1
        }
        try store.writeData("graph.json", merged.data)
        store.setModifiedTime("graph.json", modifiedTime: max(Self.nowMS(), remote.modifiedTime))
        try await s3.putObjectConditional(
            config.rootKey("graph.json"),
            body: try store.readData("graph.json"),
            expectedETag: remoteVersion.eTag
        )
        result.uploaded += 1
        result.conflicts += merged.conflicts
    }

    private func mergeDrawingsWithRemote(_ remote: FileMeta, result: inout CBrainSyncResult) async throws {
        progress("Merging drawings.json")
        guard let remoteVersion = try await s3.getObjectVersion(config.rootKey("drawings.json")) else { return }
        let remoteBytes = remoteVersion.body
        let localBytes = try store.readData("drawings.json")
        let baseBytes: Data?
        if store.exists(Self.localDrawingsBasePath) {
            baseBytes = try store.readData(Self.localDrawingsBasePath)
        } else {
            baseBytes = nil
        }
        let merged = try Self.mergeDrawingsData(local: localBytes, remote: remoteBytes, base: baseBytes)
        if merged.conflicts > 0 {
            let conflict = conflictPath("drawings.json", source: "local")
            try store.writeData(conflict, localBytes)
            try await upload(conflict)
            result.uploaded += 1
        }
        try store.writeData("drawings.json", merged.data)
        store.setModifiedTime("drawings.json", modifiedTime: max(Self.nowMS(), remote.modifiedTime))
        try await s3.putObjectConditional(
            config.rootKey("drawings.json"),
            body: try store.readData("drawings.json"),
            expectedETag: remoteVersion.eTag
        )
        result.uploaded += 1
        result.conflicts += merged.conflicts
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
        let logicalTimes = localLogicalTimes()
        for file in store.listFilesRecursive() {
            if Self.skipLocal(file.path) { continue }
            let bytes = try store.readData(file.path)
            var modifiedTime = Self.effectiveModifiedTime(path: file.path, bytes: bytes, fallback: file.modifiedTime)
            if let logicalTime = logicalTimes[file.path], logicalTime > 0 {
                modifiedTime = logicalTime
            }
            output[file.path] = FileMeta(
                path: file.path,
                sha256: S3StorageClient.sha256Hex(bytes),
                size: Int64(bytes.count),
                modifiedTime: modifiedTime
            )
        }
        return output
    }

    private func localLogicalTimes() -> [String: Int64] {
        guard store.exists("graph.json"),
              let data = try? store.readData("graph.json"),
              let object = try? JSONSerialization.jsonObject(with: data),
              let graph = object as? [String: Any],
              let nodes = graph["nodes"] as? [String: Any] else {
            return [:]
        }
        var output: [String: Int64] = [:]
        for value in nodes.values {
            guard let node = value as? [String: Any],
                  let rawName = node["fileName"] as? String else { continue }
            let fileName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if fileName.isEmpty { continue }
            let noteName = fileName.lowercased().hasSuffix(".md") ? fileName : fileName + ".md"
            let time = Self.graphItemTime(node)
            if time > 0 { output["notes/" + noteName] = time }
        }
        return output
    }

    private func readRemoteManifest() async throws -> [String: FileMeta] {
        var cached: [String: FileMeta] = [:]
        if let body = try await s3.getObject(config.rootKey(Self.manifestPath)), !body.isEmpty {
            cached = try Self.parseManifest(String(decoding: body, as: UTF8.self))
        } else {
            progress("No remote manifest. Building one from S3 objects...")
        }
        if store.exists(Self.localRemoteDeltaPath) {
            let localDelta = try Self.parseManifest(String(decoding: store.readData(Self.localRemoteDeltaPath), as: UTF8.self))
            for (path, meta) in localDelta where !meta.eTag.isEmpty {
                cached[path] = meta
            }
        }
        let output = try await scanRemoteObjects(cached: cached)
        try store.writeData(Self.localRemoteDeltaPath, Data(try manifestJSON(output).utf8))
        return output
    }

    private func scanRemoteObjects(cached: [String: FileMeta]) async throws -> [String: FileMeta] {
        var output: [String: FileMeta] = [:]
        let root = config.rootKey("")
        let listPrefix = root.isEmpty ? "" : root + "/"
        let objects = try await s3.listObjects(prefix: listPrefix)
        try await ensureSyncTargetVersion()
        var fetched = 0
        var processed = 0
        var changed: [(S3ObjectInfo, String, FileMeta?)] = []
        for object in objects {
            try await refreshLockIfNeeded()
            guard let path = remotePath(key: object.key, root: root), !Self.skipLocal(path) else { continue }
            let cachedMeta = cached[path]
            if let cachedMeta, !cachedMeta.eTag.isEmpty,
               cachedMeta.eTag == object.eTag, cachedMeta.size == object.size {
                output[path] = cachedMeta
                processed += 1
                if processed % 50 == 0 {
                    try store.writeData(Self.localRemoteDeltaPath, Data(try manifestJSON(output).utf8))
                }
                continue
            }
            changed.append((object, path, cachedMeta))
        }
        for start in stride(from: 0, to: changed.count, by: 4) {
            try await refreshLockIfNeeded()
            let end = min(start + 4, changed.count)
            let batch = Array(changed[start..<end])
            let results = try await withThrowingTaskGroup(of: RemoteFetchedFile?.self) { group in
                for (object, path, cachedMeta) in batch {
                    group.addTask {
                        guard let bytes = try await self.s3.getObject(object.key) else { return nil }
                        let sha256 = S3StorageClient.sha256Hex(bytes)
                        let fallback = cachedMeta?.sha256 == sha256 ? cachedMeta!.modifiedTime : object.lastModified
                        return RemoteFetchedFile(meta: FileMeta(
                            path: path,
                            sha256: sha256,
                            size: Int64(bytes.count),
                            modifiedTime: Self.effectiveModifiedTime(path: path, bytes: bytes, fallback: fallback),
                            eTag: object.eTag
                        ))
                    }
                }
                var files: [RemoteFetchedFile] = []
                for try await result in group {
                    if let result { files.append(result) }
                }
                return files
            }
            for result in results {
                output[result.meta.path] = result.meta
                fetched += 1
                processed += 1
                if fetched % 10 == 0 { progress("Fetching changed remote files \(fetched)...") }
                if processed % 50 == 0 {
                    try store.writeData(Self.localRemoteDeltaPath, Data(try manifestJSON(output).utf8))
                }
            }
        }
        return output
    }

    private func remotePath(key: String, root: String) -> String? {
        if root.isEmpty { return key }
        guard key.hasPrefix(root + "/") else { return nil }
        return String(key.dropFirst(root.count + 1))
    }

    private func acquireLock() async throws {
        if activeLockType != Self.exclusiveLockType {
            try await acquireLockOnce()
            return
        }
        var lastError: Error?
        for attempt in 0..<30 {
            do {
                try await acquireLockOnce()
                return
            } catch {
                lastError = error
                if attempt == 29 { throw error }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw lastError ?? CBrainError.message("Could not acquire exclusive lock")
    }

    private func acquireLockOnce() async throws {
        progress("Acquiring \(activeLockType) lock...")
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
            if lock.key == legacyLockKey() {
                try await s3.deleteObject(lock.key)
                continue
            }
            if activeLockType == Self.syncLockType {
                if Self.isLockType(lock.key, type: Self.exclusiveLockType) {
                    throw CBrainError.message("Sync target is being upgraded")
                }
            } else if lock.key != lockKey() {
                throw CBrainError.message("Cannot acquire exclusive lock while sync target is active")
            }
        }
        try await writeLock(now)

        let verifiedLocks = try await s3.listObjects(prefix: lockPrefix)
        var ownLockActive = false
        var winningExclusive: S3ObjectInfo?
        for lock in verifiedLocks where now - lock.lastModified <= Self.lockTimeoutMS {
            if lock.key == lockKey() { ownLockActive = true }
            if activeLockType == Self.syncLockType,
               Self.isLockType(lock.key, type: Self.exclusiveLockType) {
                try await s3.deleteObject(lockKey())
                throw CBrainError.message("Exclusive lock appeared while acquiring sync lock")
            }
            if activeLockType == Self.exclusiveLockType {
                if Self.isLockType(lock.key, type: Self.syncLockType) {
                    try await s3.deleteObject(lockKey())
                    throw CBrainError.message("Sync lock appeared while acquiring exclusive lock")
                }
                if Self.isLockType(lock.key, type: Self.exclusiveLockType) {
                    if winningExclusive == nil
                        || lock.lastModified < winningExclusive!.lastModified
                        || (lock.lastModified == winningExclusive!.lastModified && lock.key < winningExclusive!.key) {
                        winningExclusive = lock
                    }
                }
            }
        }
        if !ownLockActive || (winningExclusive != nil && winningExclusive!.key != lockKey()) {
            try await s3.deleteObject(lockKey())
            throw CBrainError.message("Another client acquired the lock first")
        }
    }

    private func refreshLockIfNeeded() async throws {
        let now = Self.nowMS()
        if now - lastLockRefresh < Self.lockRefreshIntervalMS { return }
        var prefix = config.rootKey(Self.lockPrefix)
        if !prefix.isEmpty && !prefix.hasSuffix("/") { prefix += "/" }
        var ownLockActive = false
        for lock in try await s3.listObjects(prefix: prefix) where now - lock.lastModified <= Self.lockTimeoutMS {
            if lock.key == lockKey() {
                ownLockActive = true
            } else if activeLockType == Self.syncLockType,
                      Self.isLockType(lock.key, type: Self.exclusiveLockType) {
                throw CBrainError.message("Exclusive lock appeared during sync")
            } else if activeLockType == Self.exclusiveLockType {
                throw CBrainError.message("Another lock appeared during exclusive operation")
            }
        }
        if !ownLockActive { throw CBrainError.message("Sync lock expired") }
        try await writeLock(now)
    }

    private func writeLock(_ now: Int64) async throws {
        let body: [String: Any] = [
            "clientId": clientId,
            "type": activeLockType,
            "clientType": Self.lockClientType,
            "updatedTime": now
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
        try await s3.putObject(lockKey(), body: data)
        lastLockRefresh = now
    }

    private func releaseLock() async throws {
        try await s3.deleteObject(lockKey())
    }

    private func lockKey() -> String {
        config.rootKey(Self.lockPrefix + activeLockType + "_" + Self.lockClientType + "_" + clientId + ".json")
    }

    private func legacyLockKey() -> String {
        config.rootKey(Self.lockPrefix + clientId + ".json")
    }

    private static func isLockType(_ key: String, type: String) -> Bool {
        let name = (key as NSString).lastPathComponent
        return name.hasPrefix(type + "_")
    }

    private func conflictPath(_ path: String, source: String) -> String {
        let stamp = Self.conflictStamp()
        let owner = String(clientId.prefix(8))
        let ns = path as NSString
        let folder = ns.deletingLastPathComponent
        let name = ns.lastPathComponent
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let conflictName = ext.isEmpty
            ? "\(base).\(source)-conflict-\(stamp)-\(owner)"
            : "\(base).\(source)-conflict-\(stamp)-\(owner).\(ext)"
        return folder.isEmpty || folder == "." ? conflictName : folder + "/" + conflictName
    }

    private func saveGraphBase() throws {
        if store.exists("graph.json") {
            try store.writeData(Self.localGraphBasePath, store.readData("graph.json"))
        }
    }

    private func saveDrawingsBase() throws {
        if store.exists("drawings.json") {
            try store.writeData(Self.localDrawingsBasePath, store.readData("drawings.json"))
        }
    }

    private func checkpoint(_ state: inout [String: FileMeta], path: String, meta: FileMeta?) throws {
        state[path] = meta
        UserDefaults.standard.set(try manifestJSON(state), forKey: stateKey)
    }

    private func manifestJSON(_ files: [String: FileMeta]) throws -> String {
        var fileJSON: [String: Any] = [:]
        for path in files.keys.sorted() {
            guard let meta = files[path] else { continue }
            fileJSON[path] = [
                "sha256": meta.sha256,
                "size": meta.size,
                "modifiedTime": meta.modifiedTime,
                "eTag": meta.eTag
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
                modifiedTime: int64(item["modifiedTime"]),
                eTag: item["eTag"] as? String ?? ""
            )
        }
        return output
    }

    private static func skipLocal(_ path: String?) -> Bool {
        guard let path else { return true }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        return normalized == localTombstonesPath
            || normalized == ".cbrain-sync" || normalized.hasPrefix(".cbrain-sync/")
    }

    private static func isContainerPath(_ path: String) -> Bool {
        path == "graph.json" || path == "drawings.json"
    }

    private static func parseTombstones(_ data: Data) throws -> [String: Tombstone] {
        var output: [String: Tombstone] = [:]
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["tombstones"] as? [String: Any] else {
            return output
        }
        for (path, value) in items {
            guard let item = value as? [String: Any] else { continue }
            let deletedTime = int64(item["deletedTime"])
            if deletedTime > 0 { output[path] = Tombstone(path: path, deletedTime: deletedTime) }
        }
        return output
    }

    private static func mergeTombstones(target: inout [String: Tombstone], source: [String: Tombstone]) {
        for candidate in source.values {
            if target[candidate.path] == nil || candidate.deletedTime > target[candidate.path]!.deletedTime {
                target[candidate.path] = candidate
            }
        }
    }

    private func tombstonesJSON(_ tombstones: [String: Tombstone]) throws -> Data {
        var items: [String: Any] = [:]
        for path in tombstones.keys.sorted() {
            guard let tombstone = tombstones[path] else { continue }
            items[path] = ["deletedTime": tombstone.deletedTime]
        }
        let root: [String: Any] = [
            "version": 1,
            "updatedTime": Self.nowMS(),
            "tombstones": items
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func same(_ a: FileMeta?, _ b: FileMeta?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.sha256 == b.sha256
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

    private static func mergeGraphData(local localData: Data, remote remoteData: Data, base baseData: Data?) throws -> GraphMergeResult {
        guard var local = try JSONSerialization.jsonObject(with: localData) as? [String: Any],
              let remote = try JSONSerialization.jsonObject(with: remoteData) as? [String: Any] else {
            throw CBrainError.invalidLibrary
        }
        let base: [String: Any]?
        if let baseData = baseData {
            base = try JSONSerialization.jsonObject(with: baseData) as? [String: Any]
        } else {
            base = nil
        }
        var conflicts = 0
        conflicts += mergeGraphSection(target: &local, source: remote, base: base, name: "nodes")
        conflicts += mergeGraphSection(target: &local, source: remote, base: base, name: "links")
        let data = try JSONSerialization.data(withJSONObject: local, options: [.prettyPrinted, .sortedKeys])
        return GraphMergeResult(data: data, conflicts: conflicts)
    }

    private static func mergeGraphSection(target: inout [String: Any], source: [String: Any], base: [String: Any]?, name: String) -> Int {
        var targetItems = target[name] as? [String: Any] ?? [:]
        let sourceItems = source[name] as? [String: Any] ?? [:]
        let baseItems = base?[name] as? [String: Any] ?? [:]
        var conflicts = 0
        for id in Set(targetItems.keys).union(sourceItems.keys) {
            let localItem = targetItems[id] as? [String: Any]
            let remoteItem = sourceItems[id] as? [String: Any]
            let baseItem = baseItems[id] as? [String: Any]
            if localItem == nil, let remoteItem {
                targetItems[id] = remoteItem
            } else if let localItem, let remoteItem, canonicalJSON(localItem) != canonicalJSON(remoteItem) {
                let localChanged = baseItem == nil || canonicalJSON(localItem) != canonicalJSON(baseItem!)
                let remoteChanged = baseItem == nil || canonicalJSON(remoteItem) != canonicalJSON(baseItem!)
                if !localChanged && remoteChanged {
                    targetItems[id] = remoteItem
                } else if localChanged && remoteChanged {
                    conflicts += 1
                    if graphItemWins(candidate: remoteItem, current: localItem) {
                        targetItems[id] = remoteItem
                    }
                }
            }
        }
        target[name] = targetItems
        return conflicts
    }

    private static func mergeDrawingsData(local localData: Data, remote remoteData: Data, base baseData: Data?) throws -> GraphMergeResult {
        var local = try parseDrawingIndex(localData)
        let remote = try parseDrawingIndex(remoteData)
        let base: DrawingIndex?
        if let baseData = baseData {
            base = try parseDrawingIndex(baseData)
        } else {
            base = nil
        }
        var localItems = drawingMap(local.items)
        let remoteItems = drawingMap(remote.items)
        let baseItems = drawingMap(base?.items ?? [])
        var conflicts = 0
        for id in Set(localItems.keys).union(remoteItems.keys).union(baseItems.keys) {
            let localItem = localItems[id]
            let remoteItem = remoteItems[id]
            let baseItem = baseItems[id]
            if sameJSONItem(localItem, remoteItem) { continue }
            if base == nil {
                if localItem == nil, let remoteItem {
                    localItems[id] = remoteItem
                } else if let localItem, let remoteItem {
                    conflicts += 1
                    if graphItemWins(candidate: remoteItem, current: localItem) {
                        localItems[id] = remoteItem
                    }
                }
                continue
            }
            let localChanged = base == nil || !sameJSONItem(localItem, baseItem)
            let remoteChanged = base == nil || !sameJSONItem(remoteItem, baseItem)
            if !localChanged && remoteChanged {
                localItems[id] = remoteItem
            } else if localChanged && remoteChanged {
                conflicts += 1
                if localItem == nil, let remoteItem {
                    localItems[id] = remoteItem
                } else if let localItem, let remoteItem, graphItemWins(candidate: remoteItem, current: localItem) {
                    localItems[id] = remoteItem
                }
            }
        }
        local.items = localItems.keys.sorted().compactMap { localItems[$0] }
        let payload: Any
        if local.arrayFormat {
            payload = local.items
        } else {
            local.wrapper["value"] = local.items
            local.wrapper["Count"] = local.items.count
            payload = local.wrapper
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return GraphMergeResult(data: data, conflicts: conflicts)
    }

    private static func parseDrawingIndex(_ data: Data) throws -> DrawingIndex {
        let value = try JSONSerialization.jsonObject(with: data)
        if let items = value as? [[String: Any]] {
            return DrawingIndex(arrayFormat: true, wrapper: [:], items: items)
        }
        if let wrapper = value as? [String: Any] {
            return DrawingIndex(arrayFormat: false, wrapper: wrapper, items: wrapper["value"] as? [[String: Any]] ?? [])
        }
        throw CBrainError.message("drawings.json must be an array or object")
    }

    private static func drawingMap(_ items: [[String: Any]]) -> [String: [String: Any]] {
        var output: [String: [String: Any]] = [:]
        for item in items {
            let id = item["id"] as? String ?? ""
            if !id.isEmpty { output[id] = item }
        }
        return output
    }

    private static func sameJSONItem(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return canonicalJSON(a) == canonicalJSON(b)
    }

    private static func graphItemWins(candidate: [String: Any], current: [String: Any]) -> Bool {
        let candidateTime = graphItemTime(candidate)
        let currentTime = graphItemTime(current)
        if candidateTime != currentTime { return candidateTime > currentTime }
        return canonicalJSON(candidate) > canonicalJSON(current)
    }

    private static func graphItemTime(_ item: [String: Any]) -> Int64 {
        max(
            parseGraphTime(item["updateTime"] as? String ?? ""),
            parseGraphTime(item["createTime"] as? String ?? "")
        )
    }

    private static func canonicalJSON(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
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
    var eTag: String = ""
}

private struct RemoteFetchedFile {
    var meta: FileMeta
}

private struct Tombstone {
    var path: String
    var deletedTime: Int64
}

private struct GraphMergeResult {
    var data: Data
    var conflicts: Int
}

private struct DrawingIndex {
    var arrayFormat: Bool
    var wrapper: [String: Any]
    var items: [[String: Any]]
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
