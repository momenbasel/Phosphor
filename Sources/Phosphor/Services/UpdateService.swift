import Foundation

struct UpdateRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let releaseNotesURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case releaseNotesURL = "html_url"
        case draft
        case prerelease
        case assets
    }

    var version: String {
        UpdateService.normalizedVersion(tagName) ?? tagName
    }

    var downloadURL: URL {
        assets.first {
            $0.name.compare("Phosphor.dmg", options: [.caseInsensitive]) == .orderedSame
                && UpdateService.isTrustedGitHubURL($0.browserDownloadURL)
        }?.browserDownloadURL ?? releaseNotesURL
    }
}

enum UpdateCheckResult: Sendable {
    case updateAvailable(UpdateRelease)
    case upToDate(UpdateRelease)
}

enum UpdateServiceError: LocalizedError {
    case invalidResponse(statusCode: Int)
    case invalidRelease
    case invalidVersion(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let statusCode):
            return "GitHub returned HTTP \(statusCode)."
        case .invalidRelease:
            return "GitHub did not return a usable stable Phosphor release."
        case .invalidVersion(let version):
            return "Phosphor could not compare version \(version)."
        }
    }
}

struct UpdateService: Sendable {
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/momenbasel/Phosphor/releases/latest"
    )!

    func checkForUpdates(currentVersion: String = AppVersion.current) async throws -> UpdateCheckResult {
        guard Self.normalizedVersion(currentVersion) != nil else {
            throw UpdateServiceError.invalidVersion(currentVersion)
        }

        var request = URLRequest(url: Self.latestReleaseURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Phosphor/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UpdateServiceError.invalidResponse(statusCode: statusCode)
        }

        let release = try Self.decodeRelease(from: data)
        guard !release.draft, !release.prerelease,
              Self.normalizedVersion(release.tagName) != nil else {
            throw UpdateServiceError.invalidRelease
        }

        if Self.isVersion(release.tagName, newerThan: currentVersion) {
            return .updateAvailable(release)
        }
        return .upToDate(release)
    }

    static func decodeRelease(from data: Data) throws -> UpdateRelease {
        let release = try JSONDecoder().decode(UpdateRelease.self, from: data)
        guard isTrustedGitHubURL(release.releaseNotesURL) else {
            throw UpdateServiceError.invalidRelease
        }
        return release
    }

    static func isTrustedGitHubURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "github.com"
            && url.user == nil
            && url.password == nil
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        guard let candidateParts = versionComponents(candidate),
              let currentParts = versionComponents(current) else {
            return false
        }

        let componentCount = max(candidateParts.count, currentParts.count)
        for index in 0..<componentCount {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }
        return false
    }

    static func normalizedVersion(_ version: String) -> String? {
        versionComponents(version)?.map(String.init).joined(separator: ".")
    }

    private static func versionComponents(_ version: String) -> [Int]? {
        var normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.first == "v" || normalized.first == "V" {
            normalized.removeFirst()
        }
        guard !normalized.isEmpty,
              !normalized.contains("-"),
              !normalized.contains("+") else {
            return nil
        }

        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }
}
