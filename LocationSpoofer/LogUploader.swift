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

    private var uploadTimer: DispatchSourceTimer?
    private let uploadQueue = DispatchQueue(label: "com.locationspoofer.logupload", qos: .background)
    private var isUploading = false

    private init() {}

    // MARK: - Auto-upload timer

    func startAutoUpload(intervalSeconds: Double = 60.0) {
        stopAutoUpload()
        let timer = DispatchSource.makeTimerSource(queue: uploadQueue)
        timer.schedule(deadline: .now() + 5, repeating: intervalSeconds, leeway: .seconds(5))
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
            guard !self.isUploading else { completion?("Already uploading…"); return }
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

            let result = self.putFile(base64Content: base64Content,
                                      message: "device log \(timestamp)",
                                      token: token,
                                      retryOn409: true)

            // On success, wipe both log files so the next session starts clean.
            if result == "Sent successfully." {
                self.clearLogs()
            }

            completion?(result)
        }
    }

    // MARK: - Clear logs

    private func clearLogs() {
        let fm = FileManager.default
        for path in [mirrorLogPath, primaryLogPath] {
            // Truncate to empty rather than delete, so the file descriptor in
            // FileLogger stays valid and new log lines keep appending correctly.
            if fm.fileExists(atPath: path) {
                try? "".write(toFile: path, atomically: false, encoding: .utf8)
            }
        }
    }

    // MARK: - PUT with optional 409 retry

    @discardableResult
    private func putFile(base64Content: String,
                         message: String,
                         token: String,
                         retryOn409: Bool) -> String {
        let sha = fetchSHA(token: token)

        var body: [String: Any] = ["message": message, "content": base64Content]
        if let sha { body["sha"] = sha }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return "Failed to encode request body."
        }

        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/contents/\(remotePath)"
        guard let url = URL(string: urlString) else { return "Bad URL." }

        var request = URLRequest(url: url)
        request.httpMethod  = "PUT"
        request.setValue("Bearer \(token)",             forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json",            forHTTPHeaderField: "Content-Type")
        request.httpBody        = bodyData
        request.timeoutInterval = 30

        let sem    = DispatchSemaphore(value: 0)
        var result = "Unknown error."
        var statusCode = 0

        URLSession.shared.dataTask(with: request) { data, response, error in
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

        // 409 = stale SHA. Re-fetch and retry once.
        if statusCode == 409 && retryOn409 {
            return putFile(base64Content: base64Content,
                           message: message,
                           token: token,
                           retryOn409: false)
        }

        return result
    }

    // MARK: - Helpers

    private func fetchSHA(token: String) -> String? {
        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/contents/\(remotePath)"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)",             forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        let sem  = DispatchSemaphore(value: 0)
        var sha: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let s    = json["sha"] as? String { sha = s }
            sem.signal()
        }.resume()
        sem.wait()
        return sha
    }
}
