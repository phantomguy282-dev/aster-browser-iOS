import Foundation

struct SavedPage: Codable, Identifiable {
    var id = UUID()
    var title: String
    var url: String
    var date = Date()
    var folder = ""
}
struct BrowserPreferences: Codable {
    var searchEngine = "google"
    var appearance = "system"
    var accent = "violet"
    var homepage = ""
    var shieldMode = "standard"
    var threatDomains: [String] = []
    var trackerDomains: [String] = []
    var adultDomains: [String] = []
    var exceptions: [String] = []
}
struct BrowserProfile: Codable {
    var version = 1
    var preferences = BrowserPreferences()
    var bookmarks: [SavedPage] = []
    var history: [SavedPage] = []
    var session: [String] = []
    var downloads: [DownloadRecord] = []
}

/// Owns app-local data only. No accounts, tokens, passwords or website cookies are serialized here.
final class BrowserStore {
    let directory: URL
    private let file: URL
    private(set) var profile = BrowserProfile()
    private(set) var warning: String?
    init(directory: URL? = nil) {
        let support = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aster", isDirectory: true)
        self.directory = support
        file = support.appendingPathComponent("profile.json")
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var protected = support
            var flags = URLResourceValues(); flags.isExcludedFromBackup = true
            try protected.setResourceValues(flags)
            if FileManager.default.fileExists(atPath: file.path) {
                let info = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? 0) < 8 * 1024 * 1024 else { throw BrowserFailure(message: "Profile is invalid or too large.") }
                let loaded = try JSONDecoder().decode(BrowserProfile.self, from: Data(contentsOf: file))
                guard loaded.version == 1, loaded.bookmarks.count <= 5000, loaded.history.count <= 5000, loaded.session.count <= 20, loaded.downloads.count <= 200 else { throw BrowserFailure(message: "Unsupported profile limits.") }
                profile = loaded
                profile.bookmarks = loaded.bookmarks.filter { (try? WebPolicy.webURL($0.url)) != nil }
                profile.history = loaded.history.filter { (try? WebPolicy.webURL($0.url)) != nil }
                profile.session = loaded.session.filter { (try? WebPolicy.webURL($0)) != nil }
            }
        } catch {
            warning = "Local profile could not be loaded. The original is preserved. \(error.localizedDescription)"
            if FileManager.default.fileExists(atPath: file.path) {
                let backup = support.appendingPathComponent("profile-recovery-\(UUID().uuidString).json")
                do { try FileManager.default.copyItem(at: file, to: backup) }
                catch { warning = "Profile recovery backup failed; changes will not be saved until storage is repaired."; writesDisabled = true }
            }
        }
    }
    private var writesDisabled = false
    func update(_ change: (inout BrowserProfile) -> Void) throws {
        guard !writesDisabled else { throw BrowserFailure(message: warning ?? "Profile writes unavailable.") }
        var next = profile
        change(&next)
        next.history = Array(next.history.prefix(5000))
        next.session = Array(next.session.prefix(20))
        next.downloads = Array(next.downloads.prefix(200))
        let bytes = try JSONEncoder().encode(next)
        guard bytes.count < 8 * 1024 * 1024 else { throw BrowserFailure(message: "Profile storage limit reached.") }
        try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        profile = next
    }
    func visit(_ url: URL, title: String) throws {
        guard (try? WebPolicy.webURL(url.absoluteString)) != nil else { return }
        try update { $0.history.insert(SavedPage(title: String(title.prefix(200)), url: url.absoluteString), at: 0) }
    }
    func bookmark(_ url: URL, title: String, folder: String) throws {
        _ = try WebPolicy.webURL(url.absoluteString)
        guard profile.bookmarks.count < 5000 else { throw BrowserFailure(message: "Bookmark limit reached.") }
        try update { data in
            if let index = data.bookmarks.firstIndex(where: { $0.url == url.absoluteString }) {
                data.bookmarks[index].title = String(title.prefix(200)); data.bookmarks[index].folder = String(folder.prefix(80))
            } else { data.bookmarks.append(SavedPage(title: String(title.prefix(200)), url: url.absoluteString, folder: String(folder.prefix(80)))) }
        }
    }
}

enum MobileShield {
    static let modes = ["standard", "enhanced", "strict"]
    enum Category: String { case threat = "Threat list", adult = "Content filter", tracker = "Tracker list" }
    static func domain(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count <= 253, !text.contains(where: { "/:@?#%\\".contains($0) || $0.isWhitespace }),
              let host = try WebPolicy.webURL("https://" + text + "/").host?.lowercased(), host == text,
              text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              }) else { throw BrowserFailure(message: "Use an ASCII domain or its Punycode form, without paths or schemes.") }
        return text
    }
    static func parse(_ input: String) throws -> [String] {
        guard input.utf8.count <= 65536 else { throw BrowserFailure(message: "Domain input exceeds 64 KiB.") }
        let rows = input.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard rows.count <= 500 else { throw BrowserFailure(message: "Limit: 500 domains per list.") }
        return Array(Set(try rows.map(domain))).sorted()
    }
    static func matches(_ host: String, _ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
    static func blocked(_ url: URL, preferences p: BrowserPreferences) -> Category? {
        guard let host = url.host?.lowercased() else { return .threat }
        if p.exceptions.contains(where: { matches(host, $0) }) { return nil }
        if p.threatDomains.contains(where: { matches(host, $0) }) { return .threat }
        if p.shieldMode != "standard", p.trackerDomains.contains(where: { matches(host, $0) }) { return .tracker }
        if p.shieldMode == "strict", p.adultDomains.contains(where: { matches(host, $0) }) { return .adult }
        return nil
    }
    /// Network content blocking only; no script injection, no remote list fetch or fabricated threat reputation.
    static func contentRules(_ p: BrowserPreferences) throws -> String {
        var domains = p.threatDomains
        if p.shieldMode != "standard" { domains += p.trackerDomains }
        if p.shieldMode == "strict" { domains += p.adultDomains }
        var rules: [[String: Any]] = []
        for host in Set(domains) {
            _ = try domain(host)
            let escaped = NSRegularExpression.escapedPattern(for: host)
            rules.append(["trigger": ["url-filter": "^https?://([^/]+\\.)?" + escaped + "([/:]|$)"], "action": ["type": "block"]])
        }
        for host in p.exceptions {
            _ = try domain(host)
            rules.append(["trigger": ["url-filter": "^https?://([^/]+\\.)?" + NSRegularExpression.escapedPattern(for: host) + "([/:]|$)"], "action": ["type": "ignore-previous-rules"]])
        }
        guard rules.count <= 2000 else { throw BrowserFailure(message: "Content-rule limit exceeded.") }
        if rules.isEmpty { rules = [["trigger": ["url-filter": "^https://never-match.invalid/", "if-domain": ["impossible.invalid"]], "action": ["type": "block"]]] }
        return String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
    }
}
