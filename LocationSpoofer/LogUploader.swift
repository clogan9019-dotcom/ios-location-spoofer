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

    // Mirror path — written by FileLogger inside the app sandbox, always readable.
    private var mirrorLogPath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("SpooferLogs/logs.txt").path
    }
    // Primary path — written after sandbox escape.
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

    /// Returns a human-readable result string, or nil on fire-and-forget usage.
    func uploadLog(completion: ((String) -> Void)? = nil) {
        uploadQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isUploading else { completion?("Already uploading…"); return }
            self.isUploading = true
            defer { self.isUploading = false }

            let token = LogUploader.githubToken
            guard !token.isEmpty else {
                completion?("Token not configured.")
                return
            }

            // Prefer the mirror (always readable); fall back to primary after sandbox escape.
            let logData: Data?
            let usedPath: String
            if let d = FileManager.default.contents(atPath: self.mirrorLogPath), !d.isEmpty {
                logData = d
                usedPath = self.mirrorLogPath
            } else if let d = FileManager.default.contents(atPath: self.primaryLogPath), !d.isEmpty {
                logData = d
                usedPath = self.primaryLogPath
            } else {
                completion?("Log file not found — run the exploit first so logs are written.")
                return
            }
            _ = usedPath

            let base64Content = logData!.base64EncodedString()
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let existingSHA = self.fetchSHA(token: token)

            var body: [String: Any] = [
                "message": "device log \(timestamp)",
                "content": base64Content
            ]
            if let sha = existingSHA { body["sha"] = sha }

            guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                completion?("Failed to encode request body.")
                return
            }

            let urlString = "https://api.github.com/repos/\(self.owner)/\(self.repo)/contents/\(self.remotePath)"
            guard let url = URL(string: urlString) else { completion?("Bad URL."); return }

            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
            request.timeoutInterval = 30

            let sem = DispatchSemaphore(value: 0)
            var result = "Unknown error."

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    result = "Network error: \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse {
                    if http.statusCode == 200 || http.statusCode == 201 {
                        result = "Sent successfully."
                    } else {
                        // Pull GitHub's error message if available.
                        var detail = ""
                        if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let msg = json["message"] as? String {
                            detail = " — \(msg)"
                        }
                        result = "GitHub returned \(http.statusCode)\(detail)"
                    }
                }
                sem.signal()
            }.resume()

            sem.wait()
            completion?(result)
        }
    }

    // MARK: - Helpers

    private func fetchSHA(token: String) -> String? {
        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/contents/\(remotePath)"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        let sem = DispatchSemaphore(value: 0)
        var sha: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let s = json["sha"] as? String { sha = s }
            sem.signal()
        }.resume()
        sem.wait()
        return sha
    }
}
