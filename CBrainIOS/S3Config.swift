import Foundation

struct S3Config: Equatable {
    var endpoint = ""
    var bucket = ""
    var region = "us-east-1"
    var accessKey = ""
    var secretKey = ""
    var prefix = "cbrain-sync"
    var pathStyle = true

    enum ConfigError: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .missing(let name):
                return "\(name) 不能为空"
            }
        }
    }

    static let storageKey = "cbrain.s3.config"

    static func load() -> S3Config {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return S3Config()
        }
        return S3Config(
            endpoint: decoded.endpoint,
            bucket: decoded.bucket,
            region: decoded.region.isEmpty ? "us-east-1" : decoded.region,
            accessKey: decoded.accessKey,
            secretKey: decoded.secretKey,
            prefix: decoded.prefix.isEmpty ? "cbrain-sync" : decoded.prefix,
            pathStyle: decoded.pathStyle
        )
    }

    func save() {
        let persisted = Persisted(
            endpoint: endpoint,
            bucket: bucket,
            region: region,
            accessKey: accessKey,
            secretKey: secretKey,
            prefix: prefix,
            pathStyle: pathStyle
        )
        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    mutating func validate() throws {
        endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        region = region.trimmingCharacters(in: .whitespacesAndNewlines)
        accessKey = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        secretKey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        prefix = Self.normalizePrefix(prefix)

        if endpoint.isEmpty { throw ConfigError.missing("S3 endpoint") }
        if bucket.isEmpty { throw ConfigError.missing("S3 bucket") }
        if accessKey.isEmpty { throw ConfigError.missing("S3 access key") }
        if secretKey.isEmpty { throw ConfigError.missing("S3 secret key") }
        if region.isEmpty { region = "us-east-1" }
    }

    func rootKey(_ relativePath: String) -> String {
        let cleanPath = Self.normalizePrefix(relativePath)
        let cleanPrefix = Self.normalizePrefix(prefix)
        if cleanPrefix.isEmpty { return cleanPath }
        if cleanPath.isEmpty { return cleanPrefix }
        return cleanPrefix + "/" + cleanPath
    }

    private static func normalizePrefix(_ path: String) -> String {
        var output = path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while output.hasPrefix("/") {
            output.removeFirst()
        }
        while output.hasSuffix("/") {
            output.removeLast()
        }
        return output
    }

    private struct Persisted: Codable {
        var endpoint: String
        var bucket: String
        var region: String
        var accessKey: String
        var secretKey: String
        var prefix: String
        var pathStyle: Bool
    }
}
