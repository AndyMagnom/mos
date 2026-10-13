import Foundation

enum AppConfig {
    #if os(macOS)
    static let platform = "macos"
    static let nativeMarker = "MedPrepMac/1"
    #else
    static let platform = "ios"
    static let nativeMarker = "MedPrepIOS/1"
    #endif
    static let site = URL(string: "https://new.medpreparation.com")!
    static let moodleHosts = ["new.medpreparation.com", "med.medpreparation.com", "test.medpreparation.com", "moodle.cooky.theworkpc.com"]
    static let sitesPath = "/local/siteswitcher/sites.php"
    static let reportPath = "/auth/devicelock/appguard_rest.php"
    static let identityPath = "/auth/devicelock/ios_identity.php"
    static let attestEnvironment = Bundle.main.object(forInfoDictionaryKey: "AppAttestEnvironment") as? String ?? "production"
    static let marker = "MedoPrepo2121/2.0.0"
    static let version = "2.2.1"
    static let privacy = URL(string: "https://med.medpreparation.com/admin/tool/policy/viewall.php?returnurl=https%3A%2F%2Fmed.medpreparation.com%2F")!
    static let embedHosts = ["youtube.com", "youtube-nocookie.com", "ytimg.com", "googlevideo.com"]
}

// TLS requires default platform validation plus current/backup SPKI pins. API redirects are forbidden so tokens,
// cookies and device signals cannot be forwarded to a different origin.
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        if PinnedTrust.accepts(challenge), let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum Network {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()
    static func cookieHeader(_ cookies: [HTTPCookie], for url: URL) -> String? {
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let host = url.host ?? ""; let path = url.path.isEmpty ? "/" : url.path
            let pathMatches = path == cookie.path || path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/")
            let domainMatches = cookie.domain.hasPrefix(".") ? (host == domain || host.hasSuffix("." + domain)) : host == domain
            return domainMatches && pathMatches &&
                (cookie.expiresDate.map { $0 > Date() } ?? true) && (!cookie.isSecure || url.scheme == "https")
        }
        return HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
    }
    static func json(_ url: URL, body: Data, token: String? = nil, cookieHeader: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.httpShouldHandleCookies = false
        if let cookieHeader { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConfig.marker + " " + AppConfig.nativeMarker, forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 403 { throw URLError(.userAuthenticationRequired) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 65536 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

@MainActor final class SiteRegistry {
    private(set) var hosts: Set<String>
    private var lastAttempt = Date.distantPast
    private var fetching = false
    init() { hosts = Set((UserDefaults.standard.stringArray(forKey: "siteHosts") ?? AppConfig.moodleHosts).filter(Self.validHost)) }
    static func validHost(_ host: String) -> Bool {
        guard host.count <= 253, !host.isEmpty else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" &&
            $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
    func trusts(host: String) -> Bool {
        host.lowercased() == AppConfig.site.host || hosts.contains(host.lowercased())
    }
    func allows(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil &&
        (url.port == nil || url.port == 443) &&
        url.host.map { trusts(host: $0) } == true
    }
    func embedded(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, (url.port == nil || url.port == 443), let host = url.host?.lowercased() else { return false }
        return AppConfig.embedHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
    var start: URL {
        if let saved = UserDefaults.standard.url(forKey: "lastSite"), allows(saved) { return saved }
        return AppConfig.site
    }
    func remember(_ url: URL) {
        guard allows(url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        parts.path = "/"; parts.query = nil; parts.fragment = nil
        UserDefaults.standard.set(parts.url, forKey: "lastSite")
    }
    func refresh() async {
        guard !fetching, Date().timeIntervalSince(lastAttempt) > 600 else { return }
        fetching = true; lastAttempt = Date()
        defer { fetching = false }
        do {
            let (data, response) = try await Network.session.data(from: AppConfig.site.appendingPathComponent(AppConfig.sitesPath))
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65536,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = object["hosts"] as? [String] else { return }
            hosts = Set(list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter(Self.validHost).prefix(50))
            UserDefaults.standard.set(Array(hosts), forKey: "siteHosts")
        } catch { /* Retain the last validated list on network failure. */ }
    }
}
