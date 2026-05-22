import Foundation

final class LogUploader {
    static let shared = LogUploader()

    private static let githubToken: String = {
        let a = "ghp_WGsPayJTc1z8Mize"
        let b = "tbqeZ9NeJ2DMqQ42Azk6"
        return a + b
    }()

    private let owner      = "clogan9019-dotcom"
    private let repo       = "ios-location-spoofer"
    private let remotePath = "device-logs/logs.txt"

    private var mirrorLogPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("SpooferLogs/logs.txt").path
    }
    private let primaryLogPath = "/private/var/mobile/Documents/LocationSpooferLogs/logs.txt"

    // Dedicated session with ALL caching disabled.
    // This is the root cause of 409 errors: URLSession.shared caches the
    // GET /contents response, so fetchSHA returns a stale SHA after an upload
    // and every subsequent PUT is rejected by GitHub.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy     = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache               = nil
        cfg.timeoutIntervalForRequest  = 30
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    private var uploadTimer: DispatchSourceTimer?
    // Serial queue — only one upload runs at a time, no concurrent SHA races.
    private let uploadQueue = DispatchQueue(label: "com.locationspoofer.logupload", qos: .background)
    private var isUploading = false

    private init() {}

    // MARK: - Auto-upload timer

    func startAutoUpload(intervalSeconds: Double = 60.0) {
        stopAutoUpload()
        let timer = DispatchSource.makeTimerSource(queue: uploadQueue)
        timer.schedule(deadline: .now() + 10, repeating: intervalSeconds, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.uploadLog() }
        timer.resume()
        uploadTimer = timer
    }

    func stopAutoUpload() {
        uploadTimer?.cancel()
        uploadTimer = nil
    }

    // MARK: - Upload

    func uploadLog(completion: ((String) -> Void)? = nil) {
        uploadQueue.async { [weak self] in
            guard let self else { return }
            // Serial guard: if an upload is already running on this queue, skip.
            guard !self.isUploading else {
                completion?("Already uploading — skipped.")
                return
            }
            self.isUploading = true
            defer { self.isUploading = false }

            let token = LogUploader.githubToken
            guard !token.isEmpty else { completion?("Token not configured."); return }

            // Prefer sandbox mirror (always readable); fall back to primary after sandbox escape.
            let logData: Data
            if let d = FileManager.default.contents(atPath: self.mirrorLogPath), !d.isEmpty {
                logData = d
            } else if let d = FileManager.default.contents(atPath: self.primaryLogPath), !d.isEmpty {
                logData = d
            } else {
                completion?("Log file not found — run the exploit first so logs are written.")
                return
            }

            let base64Content = logData.base64EncodedString()
            let timestamp     = ISO8601DateFormatter().string(from: Date())

            // Always fetch a fresh SHA immediately before the PUT (cache disabled).
            let result = self.putFile(base64Content: base64Content,
                                      message: "device log \(timestamp)",
                                      token: token)
            if result == "Sent successfully." {
                self.clearLogs()
            }
            completion?(result)
        }
    }

    // MARK: - Clear logs

    private func clearLogs() {
        for path in [mirrorLogPath, primaryLogPath] where FileManager.default.fileExists(atPath: path) {
            try? "".write(toFile: path, atomically: false, encoding: .utf8)
        }
    }

    // MARK: - PUT (fetches fresh SHA each call, retries once on 409)

    private func putFile(base64Content: String,
                         message: String,
                         token: String,
                         isRetry: Bool = false) -> String {
        // Fetch SHA right now, with caching disabled, so it's always current.
        let sha = fetchSHA(token: token)

        var body: [String: Any] = ["message": message, "content": base64Content]
        if let sha { body["sha"] = sha }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return "Failed to encode request body."
        }

        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/contents/\(remotePath)"
        guard let url = URL(string: urlString) else { return "Bad URL." }

        var req = URLRequest(url: url)
        req.httpMethod   = "PUT"
        req.cachePolicy  = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue("Bearer \(token)",             forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json",            forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        let sem    = DispatchSemaphore(value: 0)
        var result = "Unknown error."
        var statusCode = 0

        session.dataTask(with: req) { data, response, error in
            if let error = error {
                result = "Network error: \(error.localizedDescription)"
            } else if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
                if http.statusCode == 200 || http.statusCode == 201 {
                    result = "Sent successfully."
                } else {
                    var detail = ""
                    if let data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let msg  = json["message"] as? String {
                        detail = " — \(msg)"
                    }
                    result = "GitHub returned \(http.statusCode)\(detail)"
                }
            }
            sem.signal()
        }.resume()
        sem.wait()

        // 409 means our SHA was still stale despite the fresh fetch.
        // Wait 1 second for any in-flight GitHub write to settle, then retry once.
        if statusCode == 409 && !isRetry {
            Thread.sleep(forTimeInterval: 1.0)
            return putFile(base64Content: base64Content,
                           message: message,
                           token: token,
                           isRetry: true)
        }

        return result
    }

    // MARK: - SHA fetch (always bypasses cache)

    private func fetchSHA(token: String) -> String? {
        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/contents/\(remotePath)"
        guard let url = URL(string: urlString) else { return nil }

        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue("Bearer \(token)",             forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let sem  = DispatchSemaphore(value: 0)
        var sha: String?
        session.dataTask(with: req) { data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let s    = json["sha"] as? String { sha = s }
            sem.signal()
        }.resume()
        sem.wait()
        return sha
    }
}
