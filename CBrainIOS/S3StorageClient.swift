import CryptoKit
import Foundation

struct S3ObjectInfo {
    var key: String
    var size: Int64
    var lastModified: Int64
}

final class S3StorageClient {
    private var config: S3Config
    private let endpoint: Endpoint
    private let session: URLSession

    init(config: S3Config) throws {
        var validated = config
        try validated.validate()
        self.config = validated
        self.endpoint = try Endpoint.parse(endpoint: validated.endpoint, bucket: validated.bucket, configuredPathStyle: validated.pathStyle)
        self.session = URLSession(configuration: .default)
    }

    func checkBucket() async throws {
        let response = try await execute(S3Request(method: "HEAD", key: "", query: nil, body: Data()))
        guard (200..<300).contains(response.code) else {
            throw CBrainError.message(errorMessage(action: "HEAD bucket", response: response))
        }
    }

    func getObject(_ key: String) async throws -> Data? {
        let response = try await execute(S3Request(method: "GET", key: key, query: nil, body: Data()))
        if response.code == 404 {
            return nil
        }
        guard (200..<300).contains(response.code) else {
            throw CBrainError.message(errorMessage(action: "GET \(key)", response: response))
        }
        return response.body
    }

    func putObject(_ key: String, body: Data) async throws {
        let response = try await execute(S3Request(method: "PUT", key: key, query: nil, body: body))
        guard (200..<300).contains(response.code) else {
            throw CBrainError.message(errorMessage(action: "PUT \(key)", response: response))
        }
    }

    func deleteObject(_ key: String) async throws {
        let response = try await execute(S3Request(method: "DELETE", key: key, query: nil, body: Data()))
        if response.code == 404 {
            return
        }
        guard (200..<300).contains(response.code) else {
            throw CBrainError.message(errorMessage(action: "DELETE \(key)", response: response))
        }
    }

    func listObjects(prefix: String) async throws -> [S3ObjectInfo] {
        var output: [S3ObjectInfo] = []
        var token: String?
        repeat {
            var query = [
                "list-type": "2",
                "prefix": prefix
            ]
            if let token, !token.isEmpty {
                query["continuation-token"] = token
            }
            let response = try await execute(S3Request(method: "GET", key: "", query: query, body: Data()))
            guard (200..<300).contains(response.code) else {
                throw CBrainError.message(errorMessage(action: "LIST \(prefix)", response: response))
            }
            let result = try ListXMLParser.parse(response.body)
            output.append(contentsOf: result.objects)
            token = result.nextContinuationToken
        } while token?.isEmpty == false
        return output
    }

    private func execute(_ request: S3Request) async throws -> S3Response {
        let payloadHash = Self.sha256Hex(request.body)
        let amzDate = Self.amzDate()
        let dateStamp = String(amzDate.prefix(8))
        let host = endpoint.hostHeader(bucket: config.bucket)
        let canonicalURI = endpoint.canonicalURI(bucket: config.bucket, key: request.key)
        let canonicalQuery = Self.canonicalQuery(request.query)
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalHeaders = "host:\(host)\n"
            + "x-amz-content-sha256:\(payloadHash)\n"
            + "x-amz-date:\(amzDate)\n"
        let canonicalRequest = "\(request.method)\n\(canonicalURI)\n\(canonicalQuery)\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let scope = "\(dateStamp)/\(config.region)/s3/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n\(Self.sha256Hex(Data(canonicalRequest.utf8)))"
        let signature = Self.hmacHex(key: signingKey(dateStamp: dateStamp), value: stringToSign)
        let authorization = "AWS4-HMAC-SHA256 Credential=\(config.accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var urlRequest = URLRequest(url: try endpoint.url(bucket: config.bucket, key: request.key, query: canonicalQuery))
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.method == "PUT" ? 60 : 30
        urlRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
        urlRequest.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        urlRequest.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        if request.method == "PUT" {
            urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = request.body
        }

        let (data, response) = try await session.data(for: urlRequest)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        return S3Response(code: code, body: data)
    }

    private func signingKey(dateStamp: String) -> Data {
        let kDate = Self.hmac(key: Data(("AWS4" + config.secretKey).utf8), value: dateStamp)
        let kRegion = Self.hmac(key: kDate, value: config.region)
        let kService = Self.hmac(key: kRegion, value: "s3")
        return Self.hmac(key: kService, value: "aws4_request")
    }

    private static func canonicalQuery(_ query: [String: String]?) -> String {
        guard let query, !query.isEmpty else { return "" }
        return query.keys.sorted().map { key in
            "\(uriEncode(key, encodeSlash: true))=\(uriEncode(query[key] ?? "", encodeSlash: true))"
        }.joined(separator: "&")
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    private static func hmac(key: Data, value: String) -> Data {
        let code = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key))
        return Data(code)
    }

    private static func hmacHex(key: Data, value: String) -> String {
        hex(hmac(key: key, value: value))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func amzDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }

    private static func uriEncode(_ input: String, encodeSlash: Bool) -> String {
        var output = ""
        for byte in input.data(using: .utf8) ?? Data() {
            let unreserved = (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57)
                || byte == 45 || byte == 95 || byte == 46 || byte == 126
            if unreserved || (byte == 47 && !encodeSlash) {
                output.append(Character(UnicodeScalar(byte)))
            } else {
                output.append(String(format: "%%%02X", byte))
            }
        }
        return output
    }

    private func errorMessage(action: String, response: S3Response) -> String {
        let body = String(decoding: response.body, as: UTF8.self)
        let code = Self.xmlText(body, tag: "Code")
        let message = Self.xmlText(body, tag: "Message")
        var detail = message.isEmpty ? body : message
        if !code.isEmpty {
            detail = "\(code): \(detail)"
        }
        if detail.count > 300 {
            detail = String(detail.prefix(300))
        }
        return "\(action) failed with HTTP \(response.code)" + (detail.isEmpty ? "" : " - \(detail)")
    }

    private static func xmlText(_ xml: String, tag: String) -> String {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>"),
              start.upperBound <= end.lowerBound else {
            return ""
        }
        return String(xml[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct S3Request {
    var method: String
    var key: String
    var query: [String: String]?
    var body: Data
}

private struct S3Response {
    var code: Int
    var body: Data
}

private struct S3ListResult {
    var objects: [S3ObjectInfo] = []
    var nextContinuationToken: String?
}

private final class ListXMLParser: NSObject, XMLParserDelegate {
    private var result = S3ListResult()
    private var currentElement = ""
    private var currentText = ""
    private var inContents = false
    private var key = ""
    private var size: Int64 = 0
    private var lastModified: Int64 = 0

    static func parse(_ data: Data) throws -> S3ListResult {
        let delegate = ListXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? CBrainError.message("无法解析 S3 listObjects 响应")
        }
        return delegate.result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "Contents" {
            inContents = true
            key = ""
            size = 0
            lastModified = 0
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if inContents {
            if elementName == "Key" {
                key = text
            } else if elementName == "Size" {
                size = Int64(text) ?? 0
            } else if elementName == "LastModified" {
                lastModified = Self.parseS3Date(text)
            } else if elementName == "Contents" {
                if !key.isEmpty && !key.hasSuffix("/") {
                    result.objects.append(S3ObjectInfo(key: key, size: size, lastModified: lastModified))
                }
                inContents = false
            }
        } else if elementName == "NextContinuationToken" {
            result.nextContinuationToken = text
        }
        currentText = ""
    }

    private static func parseS3Date(_ value: String) -> Int64 {
        guard !value.isEmpty else { return 0 }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        }
        return 0
    }
}

private struct Endpoint {
    var scheme: String
    var host: String
    var port: Int?
    var basePath: String
    var pathStyle: Bool

    static func parse(endpoint: String, bucket: String, configuredPathStyle: Bool) throws -> Endpoint {
        var raw = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.hasPrefix("http://") && !raw.hasPrefix("https://") {
            raw = "https://" + raw
        }
        guard let components = URLComponents(string: raw),
              let host = components.host else {
            throw CBrainError.message("Invalid S3 endpoint: \(endpoint)")
        }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") && !basePath.isEmpty {
            basePath.removeLast()
        }
        var pathStyle = configuredPathStyle
        if host.hasPrefix(bucket + ".") {
            pathStyle = false
        }
        return Endpoint(
            scheme: components.scheme ?? "https",
            host: host,
            port: components.port,
            basePath: basePath,
            pathStyle: pathStyle
        )
    }

    func hostHeader(bucket: String) -> String {
        guard let port, !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) else {
            return requestHost(bucket: bucket)
        }
        return "\(requestHost(bucket: bucket)):\(port)"
    }

    func requestHost(bucket: String) -> String {
        if pathStyle || host.hasPrefix(bucket + ".") {
            return host
        }
        return bucket + "." + host
    }

    func canonicalURI(bucket: String, key: String) -> String {
        var path = basePath
        if pathStyle {
            path += "/" + S3StorageClientUri.encode(bucket, encodeSlash: true)
        }
        var cleanKey = key
        while cleanKey.hasPrefix("/") {
            cleanKey.removeFirst()
        }
        if !cleanKey.isEmpty {
            path += "/" + S3StorageClientUri.encode(cleanKey, encodeSlash: false)
        }
        return path.isEmpty ? "/" : path
    }

    func url(bucket: String, key: String, query: String) throws -> URL {
        var output = "\(scheme)://\(requestHost(bucket: bucket))"
        if let port, !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
            output += ":\(port)"
        }
        output += canonicalURI(bucket: bucket, key: key)
        if !query.isEmpty {
            output += "?\(query)"
        }
        guard let url = URL(string: output) else {
            throw CBrainError.message("Invalid S3 URL: \(output)")
        }
        return url
    }
}

private enum S3StorageClientUri {
    static func encode(_ input: String, encodeSlash: Bool) -> String {
        var output = ""
        for byte in input.data(using: .utf8) ?? Data() {
            let unreserved = (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57)
                || byte == 45 || byte == 95 || byte == 46 || byte == 126
            if unreserved || (byte == 47 && !encodeSlash) {
                output.append(Character(UnicodeScalar(byte)))
            } else {
                output.append(String(format: "%%%02X", byte))
            }
        }
        return output
    }
}

