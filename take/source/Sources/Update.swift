import Foundation

/// The only network request take makes, and only while "Check for updates" is on (off by default).
/// One GET of https://take.ante.design/version.json at launch and then at most once a day:
/// {"version": "1.1", "build": 2}. No cookies, no cache, nothing sent but the request itself.
/// A newer build is shown in the sidebar with a link to the site. Nothing is downloaded or installed.
final class Updater {
    static let url = URL(string: "https://take.ante.design/version.json")!
    static let site = URL(string: "https://take.ante.design/")!
    static let interval: TimeInterval = 24 * 60 * 60

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0 }

    private struct Remote: Decodable { let version: String; let build: Int }

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()

    /// Calls back on the main queue with the newer version, or nil when this one is current or the check failed.
    func check(_ done: @escaping (String?) -> Void) {
        session.dataTask(with: Updater.url) { data, response, _ in
            var newer: String?
            if let data, (response as? HTTPURLResponse)?.statusCode == 200,
               let r = try? JSONDecoder().decode(Remote.self, from: data), r.build > Updater.currentBuild {
                newer = r.version
            }
            DispatchQueue.main.async { done(newer) }
        }.resume()
    }
}
