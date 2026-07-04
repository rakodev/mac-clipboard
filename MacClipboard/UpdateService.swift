import Foundation

enum UpdateCheckResult: Equatable {
    case upToDate(currentVersion: String)
    case updateAvailable(currentVersion: String, latestVersion: String, downloadURL: URL)
}


enum UpdateCheckError: LocalizedError, Equatable {
    case cancelled
    case invalidResponse
    case invalidPayload
    case rateLimited(resetDate: Date?)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Update check was cancelled."
        case .invalidResponse:
            return "The update server returned an unexpected response."
        case .invalidPayload:
            return "Could not parse update information."
        case .rateLimited(let resetDate):
            if let resetDate {
                return "GitHub rate-limited update checks. Try again after \(resetDate.formatted(date: .omitted, time: .shortened))."
            }
            return "GitHub rate-limited update checks. Try again later."
        case .requestFailed(let message):
            return message
        }
    }
}

final class UpdateService {
    static let shared = UpdateService()

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: URL?

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private let session: URLSession
    private let latestReleaseEndpoint: URL
    private let fallbackReleaseURL: URL
    private var currentTask: URLSessionDataTask?

    init(
        session: URLSession = .shared,
        latestReleaseEndpoint: URL = URL(string: "https://api.github.com/repos/rakodev/mac-clipboard/releases/latest")!,
        fallbackReleaseURL: URL = URL(string: "https://github.com/rakodev/mac-clipboard/releases/latest")!
    ) {
        self.session = session
        self.latestReleaseEndpoint = latestReleaseEndpoint
        self.fallbackReleaseURL = fallbackReleaseURL
    }

    func checkForUpdates(
        currentVersion: String,
        completion: @escaping (Result<UpdateCheckResult, UpdateCheckError>) -> Void
    ) {
        cancel()

        var request = URLRequest(url: latestReleaseEndpoint)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        currentTask = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            defer { self.currentTask = nil }

            if let nsError = error as NSError? {
                if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                    completion(.failure(.cancelled))
                } else {
                    completion(.failure(.requestFailed(nsError.localizedDescription)))
                }
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 403 || httpResponse.statusCode == 429 {
                    completion(.failure(.rateLimited(resetDate: self.rateLimitResetDate(from: httpResponse))))
                    return
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    completion(.failure(.invalidResponse))
                    return
                }
            }

            guard let data,
                  let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                completion(.failure(.invalidPayload))
                return
            }

            let latestVersion = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            if Self.isVersion(latestVersion, newerThan: currentVersion) {
                completion(.success(.updateAvailable(
                    currentVersion: currentVersion,
                    latestVersion: latestVersion,
                    downloadURL: release.htmlURL ?? fallbackReleaseURL
                )))
            } else {
                completion(.success(.upToDate(currentVersion: currentVersion)))
            }
        }

        currentTask?.resume()
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    private func rateLimitResetDate(from response: HTTPURLResponse) -> Date? {
        guard let resetValue = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
              let resetTime = TimeInterval(resetValue) else {
            return nil
        }
        return Date(timeIntervalSince1970: resetTime)
    }

    private static func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let components1 = v1.split(separator: ".").compactMap { Int($0) }
        let components2 = v2.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(components1.count, components2.count) {
            let c1 = i < components1.count ? components1[i] : 0
            let c2 = i < components2.count ? components2[i] : 0
            if c1 > c2 { return true }
            if c1 < c2 { return false }
        }
        return false
    }
}