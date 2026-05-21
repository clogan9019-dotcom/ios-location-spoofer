import Foundation

/// Automatically uploads the on-device log file to the GitHub repo.
/// Reads /private/var/mobile/Documents/LocationSpooferLogs/logs.txt
/// and commits it to device-logs/logs.txt in the repo via the GitHub API.
final class LogUploader {
    static let shared = LogUploader()

    private let owner      = "clogan9019-dotcom"
    private let repo       = "ios-location-spoofer"
    private let remotePath = "device-logs/logs.txt"
    private let logPath    = "/private/var/mobile/Documents/LocationSpooferLogs/logs.txt"

    private var uploadTimer: DispatchSourceTimer?
    private let uploadQueue = DispatchQueue(label: "com.locationspoofer.logupload", qos: .background)
    private var isUploading = false

    private init() {}

    // MARK: - Auto-upload timer

    /// Start uploading the log every `intervalSeconds`. Call once after the exploit is ready.
    func startAutoUpload(intervalSeconds: Double = 60.0) {
        stopAutoUpload()
        let timer = DispatchSource.makeTimerSource(queue: uploadQueue)
        timer.schedule(deadline: .now() + 5,
                       repeating: intervalSeconds,
                       leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            self?.uploadLog()
        }
        timer.resume()
        uploadTimer = timer
    }

    func stopAutoUpload() {
        uploadTimer?.cancel()
        uploadTimer = nil
    }

    // MARK: - Upload

    /// Read the log file and push it as a commit to the repo. Fire-and-forget.
    func uploadLog(completion: ((Bool) -> Void)? = nil) {
        uploadQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isUploading else { completion?(false); return }
            self.isUploading = true
            defer { self.isUploading = false }

            guard let logData = FileManager.default.contents(atPath: self.logPath),
                  !logData.isEmpty else {
                completion?(false)
                return
            }

            let token = GitHubSecrets.token
            guard !token.isEmpty, token != "YOUR_GITHUB_TOKEN_HERE" else {
                // Token not configured — silently skip.
                completion?(false)
                return
            }

            let base64Content = logData.base64EncodedString()
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let commitMessage = "device log \(timestamp)"

            // Fetch existing file SHA so we can update in-place.
            let existingSHA = self.fetchSHA(token: token)

            var body: [String: Any] = [
                "message": commitMessage,
                "content": base64Content
            ]
            if let sha = existingSHA {
                body["sha"] = sha
            }

            guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                completion?(false)
                return
            }

            let urlString = "https://api.github.com/repos/\(self.owner)/\(self.repo)/contents/\(self.remotePath)"
            guard let url = URL(string: urlString) else { completion?(false); return }

            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
            request.timeoutInterval = 30

            let sem = DispatchSemaphore(value: 0)
            var success = false

            URLSession.shared.dataTask(with: request) { _, response, _ in
                if let http = response as? HTTPURLResponse {
                    success = (http.statusCode == 200 || http.statusCode == 201)
                }
                sem.signal()
            }.resume()

            sem.wait()
            completion?(success)
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
               let fileSHA = json["sha"] as? String {
                sha = fileSHA
            }
            sem.signal()
        }.resume()

        sem.wait()
        return sha
    }
}
