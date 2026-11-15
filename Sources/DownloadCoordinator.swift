import Foundation

struct DownloadRecord: Codable, Identifiable {
    var id: UUID
    var name: String
    var source: String
    var mime: String
    var date = Date()
    var received: Int64 = 0
    var expected: Int64 = -1
    var state = "Queued"
    var scan: LocalScan?
    var error: String?
    var isPrivate = false
}

/// A separate ephemeral session starts only after the native Download Guard confirmation.
/// No credentials are forwarded on redirects: all redirects are refused and reported.
final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate {
    let store: BrowserStore
    let folder: URL
    var changed: (() -> Void)?
    private(set) var records: [DownloadRecord]
    private var tasks: [Int: UUID] = [:]
    private var active: [UUID: URLSessionDownloadTask] = [:]
    private var blocked: [UUID: String] = [:]
    private let inspectionQueue = DispatchQueue(label: "app.aster.download-inspection")
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()
    init(store: BrowserStore) throws {
        self.store = store
        folder = store.directory.appendingPathComponent("GuardedDownloads", isDirectory: true)
        records = store.profile.downloads
        super.init()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        for index in records.indices where records[index].state == "Downloading" || records[index].state == "Checking" { records[index].state = "Interrupted" }
    }
    func fileURL(_ record: DownloadRecord) -> URL {
        folder.appendingPathComponent(record.id.uuidString + "-" + WebPolicy.filename(record.name))
    }
    private func notify() {
        do { try store.update { $0.downloads = Array(records.filter { !$0.isPrivate }.prefix(200)) } }
        catch { /* Do not emit credentials or private source URLs in logs. Keep current records in memory. */ }
        changed?()
    }
    @discardableResult
    func start(url: URL, name: String, mime: String, size: Int64, cookies: [HTTPCookie], privateMode: Bool) throws -> UUID {
        guard url.scheme == "https", (try? WebPolicy.webURL(url.absoluteString)) != nil else { throw BrowserFailure(message: "Download Guard requires an HTTPS source. HTTP downloads are not supported in this preview.") }
        guard size <= DownloadInspector.maximumBytes, active.count < 3, records.count < 200 else { throw BrowserFailure(message: "Limit: 100 MiB per file, 3 simultaneous downloads, 200 retained records.") }
        let id = UUID()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // WebKit has already selected cookies for this approved origin. No cross-origin forwarding occurs.
        if !cookies.isEmpty { request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: cookies) }
        let task = session.downloadTask(with: request)
        tasks[task.taskIdentifier] = id; active[id] = task
        records.insert(DownloadRecord(id: id, name: WebPolicy.filename(name), source: url.absoluteString, mime: mime, expected: size, state: "Downloading", isPrivate: privateMode), at: 0)
        notify(); task.resume()
        return id
    }
    func cancel(_ id: UUID) {
        guard let task = active[id] else { return }
        blocked[id] = "Cancelled by you."
        task.cancel()
    }
    func remove(_ id: UUID) throws {
        guard active[id] == nil, let record = records.first(where: { $0.id == id }), record.state != "Checking" else { throw BrowserFailure(message: "Cancel or finish the download before deleting it.") }
        let file = fileURL(record)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        records.removeAll { $0.id == id }; notify()
    }
    func reportURL(_ id: UUID) throws -> URL {
        guard let record = records.first(where: { $0.id == id }) else { throw BrowserFailure(message: "Download not found.") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Aster-report-\(id.uuidString).json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return file
    }
    func inspectAgain(_ id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state == "Completed" else { throw BrowserFailure(message: "Only completed files can be checked again.") }
        records[index].state = "Checking"; let record = records[index]; notify(); inspect(record)
    }
    private func inspect(_ record: DownloadRecord) {
        let file = fileURL(record)
        inspectionQueue.async { [weak self] in
            let result = Result { try DownloadInspector.inspect(file: file, name: record.name, mime: record.mime) }
            DispatchQueue.main.async {
                guard let self = self, let index = self.records.firstIndex(where: { $0.id == record.id }) else { return }
                switch result {
                case .success(let report): self.records[index].scan = report; self.records[index].state = "Completed"
                case .failure(let error): self.records[index].state = "Check failed"; self.records[index].error = error.localizedDescription
                }
                self.notify()
            }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let id = tasks[task.taskIdentifier] { blocked[id] = "Redirect blocked. Open the final HTTPS destination and confirm a new download." }
        completionHandler(nil); task.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = tasks[downloadTask.taskIdentifier], let index = records.firstIndex(where: { $0.id == id }) else { return }
        if totalBytesWritten > DownloadInspector.maximumBytes || totalBytesExpectedToWrite > DownloadInspector.maximumBytes {
            blocked[id] = "Download exceeds the 100 MiB limit."; downloadTask.cancel(); return
        }
        records[index].received = totalBytesWritten; records[index].expected = totalBytesExpectedToWrite; changed?()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = tasks[downloadTask.taskIdentifier], let index = records.firstIndex(where: { $0.id == id }), blocked[id] == nil else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode), response.url?.scheme == "https" else { throw BrowserFailure(message: "Server returned an unsuccessful or insecure download response.") }
            let values = try location.resourceValues(forKeys: [.fileSizeKey])
            guard Int64(values.fileSize ?? 0) <= DownloadInspector.maximumBytes else { throw BrowserFailure(message: "File exceeds the download limit.") }
            records[index].mime = response.mimeType ?? records[index].mime
            let destination = fileURL(records[index])
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            records[index].received = Int64(values.fileSize ?? 0); records[index].state = "Checking"
            notify(); inspect(records[index])
        } catch { records[index].state = "Failed"; records[index].error = error.localizedDescription; notify() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = tasks.removeValue(forKey: task.taskIdentifier) else { return }
        active.removeValue(forKey: id)
        if let index = records.firstIndex(where: { $0.id == id }), records[index].state == "Downloading" {
            records[index].state = blocked[id] == "Cancelled by you." ? "Cancelled" : "Failed"
            records[index].error = blocked[id] ?? error?.localizedDescription ?? "Transfer ended without a file."
        }
        blocked.removeValue(forKey: id); notify()
    }
    func dispose() { session.invalidateAndCancel() }
}
