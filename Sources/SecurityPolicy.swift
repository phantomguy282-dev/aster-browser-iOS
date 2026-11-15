import Foundation
import CryptoKit

struct BrowserFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum WebPolicy {
    static let searches = ["google": "https://www.google.com/search?q=", "bing": "https://www.bing.com/search?q=", "duckduckgo": "https://duckduckgo.com/?q="]
    static func webURL(_ text: String) throws -> URL {
        guard text.utf8.count <= 8192, !text.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 || $0.value == 92 }),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.port == nil || (1...65535).contains(url.port!) else {
            throw BrowserFailure(message: "Only valid HTTP and HTTPS addresses without embedded credentials are supported.")
        }
        return url
    }
    static func resolve(_ input: String, engine: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 8192,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || $0.value == 92 }) else {
            throw BrowserFailure(message: "Enter a website address or search query.")
        }
        if value.hasPrefix("//") { return try webURL("https:" + value) }
        let authority = String(value.prefix { !"/?#".contains($0) })
        let hostPort = authority.range(of: #"^(localhost|[^\s/:]+\.[^\s/:]+|\[[0-9a-fA-F:]+\]):[0-9]+$"#, options: .regularExpression) != nil
        if value.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil && !hostPort { return try webURL(value) }
        if !value.contains(where: { $0.isWhitespace }) && (authority.contains(".") || authority.hasPrefix("[") || authority.lowercased().hasPrefix("localhost")) {
            let local = authority == "localhost" || authority.hasPrefix("localhost:") || authority.hasPrefix("127.") || authority == "[::1]" || authority.hasPrefix("[::1]:")
            return try webURL((local ? "http://" : "https://") + value)
        }
        var components = URLComponents(string: searches[engine] ?? searches["google"]!)!
        components.queryItems = [URLQueryItem(name: "q", value: value)]
        guard let url = components.url else { throw BrowserFailure(message: "Could not encode search query.") }
        return url
    }
    static func origin(_ url: URL?) -> String? {
        guard let url = url, (try? webURL(url.absoluteString)) != nil, let host = url.host else { return nil }
        return "\(url.scheme!.lowercased())://\(host.lowercased())" + (url.port.map { ":\($0)" } ?? "")
    }
    static func filename(_ input: String) -> String {
        let name = input.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? "download"
        let invalid = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters).union(CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"))
        let clean = String(String.UnicodeScalarView(name.unicodeScalars.map { invalid.contains($0) ? UnicodeScalar(95)! : $0 })).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return clean.isEmpty ? "download" : String(clean.prefix(120))
    }
}

struct LocalScan: Codable {
    let verdict: String
    let sha256: String
    let bytes: Int64
    let reasons: [String]
    let malwareScanned: Bool
}

enum DownloadInspector {
    static let maximumBytes: Int64 = 100 * 1024 * 1024
    static let executableExtensions: Set<String> = ["exe", "msi", "apk", "aab", "ipa", "dmg", "pkg", "js", "vbs", "ps1", "bat", "cmd", "sh", "jar", "scr", "dll"]
    static func inspect(file: URL, name: String, mime: String?, expectedHash: String? = nil) throws -> LocalScan {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? 0) <= maximumBytes else { throw BrowserFailure(message: "File is invalid or exceeds the 100 MiB inspection limit.") }
        if let expected = expectedHash, expected.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) == nil { throw BrowserFailure(message: "Invalid expected SHA-256.") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256(), prefix = Data(), count: Int64 = 0
        while let chunk = try handle.read(upToCount: 32768), !chunk.isEmpty {
            count += Int64(chunk.count)
            guard count <= maximumBytes else { throw BrowserFailure(message: "Download exceeded the local inspection limit.") }
            if prefix.count < 16 { prefix.append(chunk.prefix(16 - prefix.count)) }
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let ext = (name as NSString).pathExtension.lowercased()
        var reasons = ["No antivirus engine scanned this file. A SHA-256 hash is not proof of safety."]
        var suspicious = executableExtensions.contains(ext)
        if suspicious { reasons.append("Filename indicates an executable or active-content file.") }
        if prefix.starts(with: [0x4d, 0x5a]) { suspicious = true; reasons.append("Windows executable signature detected.") }
        if (ext == "png" && !prefix.starts(with: [137,80,78,71,13,10,26,10])) || (ext == "pdf" && !prefix.starts(with: Data("%PDF-".utf8))) {
            suspicious = true; reasons.append("Filename and format signature do not match.")
        }
        if mime?.lowercased().hasPrefix("image/") == true && executableExtensions.contains(ext) { suspicious = true; reasons.append("Declared image MIME conflicts with an executable filename.") }
        if let expected = expectedHash {
            if digest != expected.lowercased() { suspicious = true; reasons.append("SHA-256 differs from the supplied expected value.") }
            else { reasons.append("Hash matches the supplied value, but this does not establish safety.") }
        }
        return LocalScan(verdict: suspicious ? "SUSPICIOUS" : "UNVERIFIED", sha256: digest, bytes: count, reasons: reasons, malwareScanned: false)
    }
}
