import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct RouterError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Destination: Equatable {
    let browser: String
    let profile: String?
}

struct Rule: Equatable {
    let host: String
    let profile: String
    let line: Int
}

struct Config {
    static let routerID = "com.vaibhav.urlrouter"
    static let defaultBrowserID = "net.imput.helium"
    static let browserRoots = [
        "net.imput.helium": "net.imput.helium",
        "com.google.Chrome": "Google/Chrome",
        "org.chromium.Chromium": "Chromium",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi"
    ]

    var browser = defaultBrowserID
    var fallback: String?
    var rules: [Rule] = []
    var warnings: [String] = []

    init(_ text: String, source: String = "config") throws {
        var errors: [String] = []
        var directives: Set<String> = []
        var text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{feff}") { text.removeFirst() }

        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let whereAt = "\(source):\(i + 1)"
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2 else {
                errors.append("\(whereAt): expected <domain> <profile> or @directive <value>")
                continue
            }
            let key = String(parts[0])
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else {
                errors.append("\(whereAt): value cannot be empty")
                continue
            }

            if key.hasPrefix("@") {
                guard ["@browser", "@fallback"].contains(key) else {
                    errors.append("\(whereAt): unknown directive \(key)")
                    continue
                }
                guard directives.insert(key).inserted else {
                    errors.append("\(whereAt): duplicate \(key)")
                    continue
                }
                if key == "@browser" {
                    guard value.lowercased() != Self.routerID else {
                        errors.append("\(whereAt): @browser cannot point to this router")
                        continue
                    }
                    browser = value
                } else {
                    fallback = value
                }
                continue
            }

            do {
                let host = try canonicalHost(key)
                if let previous = rules.first(where: { hostMatches(host, $0.host) }) {
                    warnings.append("\(whereAt): \(host) is already covered by line \(previous.line) (\(previous.host))")
                }
                rules.append(Rule(host: host, profile: value, line: i + 1))
            } catch {
                errors.append("\(whereAt): \(error.localizedDescription)")
            }
        }
        if !errors.isEmpty { throw RouterError(errors.joined(separator: "\n")) }
        if let known = Self.browserRoots.keys.first(where: { $0.lowercased() == browser.lowercased() }) { browser = known }
        _ = try destination(nil)
        for rule in rules { _ = try destination(rule.profile) }
        if let fallback { _ = try destination(fallback) }
    }

    func destination(_ value: String?) throws -> Destination {
        let parts = value?.components(separatedBy: "::") ?? []
        guard parts.count <= 2 else { throw RouterError("invalid destination '\(value ?? "")'; use browser-bundle-id::profile") }
        let requested = parts.count == 2 ? parts[0] : browser
        guard let browser = Self.browserRoots.keys.first(where: { $0.lowercased() == requested.lowercased() }) else {
            throw RouterError("Browser '\(requested)' is not supported; use Helium, Chrome, Chromium, Brave, Edge, or Vivaldi.")
        }
        let profile = parts.count == 2 ? parts[1] : value
        return Destination(browser: browser, profile: profile == "" ? nil : profile)
    }

    static func profileRoot(browser: String, home: String) throws -> URL {
        guard let relative = Self.browserRoots[browser] else {
            throw RouterError("Profile routing is not configured for browser '\(browser)'. Use a supported Chromium browser bundle ID.")
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(relative, isDirectory: true)
    }

    func profile(for url: URL) throws -> (name: String?, reason: String) {
        if url.isFileURL { return (nil, "local file") }
        guard let rawHost = url.host else { throw RouterError("URL has no host") }
        let host = try canonicalHost(rawHost)
        if let rule = rules.first(where: { hostMatches(host, $0.host) }) {
            return (rule.profile, "line \(rule.line): \(rule.host)")
        }
        return (fallback, fallback == nil ? "no matching rule" : "@fallback")
    }
}

func canonicalHost(_ input: String) throws -> String {
    var host = input.lowercased()
    if host.contains(":") || host.hasPrefix("[") {
        let literal = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var address = in6_addr()
        guard literal.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            throw RouterError("invalid IPv6 address '\(input)'")
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else {
            throw RouterError("cannot normalize IPv6 address '\(input)'")
        }
        return "[" + String(cString: buffer) + "]"
    }
    if host.hasPrefix(".") { host.removeFirst() }
    if host.hasSuffix(".") { host.removeLast() }
    guard !host.isEmpty,
          !host.contains(where: { $0.isWhitespace }),
          host.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\?#@%*:").union(.controlCharacters)) == nil,
          let url = URL(string: "https://\(host)/"),
          url.user == nil, url.password == nil, url.port == nil,
          let normalized = url.host?.lowercased(), !normalized.isEmpty else {
        throw RouterError("invalid domain '\(input)'; use a host only")
    }
    let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard normalized.utf8.count <= 253, labels.allSatisfy({ label in
        !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
            && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }) else { throw RouterError("invalid domain '\(input)'; use a host only") }
    return normalized
}

func hostMatches(_ host: String, _ rule: String) -> Bool {
    host == rule || host.hasSuffix("." + rule)
}

func validatedURL(_ text: String) throws -> URL {
    guard text.rangeOfCharacter(from: .controlCharacters) == nil,
          let url = URL(string: text),
          let scheme = url.scheme?.lowercased(),
          ["http", "https", "file"].contains(scheme) else {
        throw RouterError("invalid URL; expected http://, https://, or file://")
    }
    if scheme == "file" {
        guard url.path.hasPrefix("/"), url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else {
            throw RouterError("file URL must point to a local absolute path")
        }
    } else {
        guard let host = url.host, !host.isEmpty else { throw RouterError("URL has no host") }
        _ = try canonicalHost(host)
    }
    return url
}

struct BrowserProfile: Equatable {
    let directory: String
    let name: String
}

func parseProfiles(_ data: Data) throws -> [BrowserProfile] {
    let object: Any
    do { object = try JSONSerialization.jsonObject(with: data) }
    catch { throw RouterError("cannot parse browser Local State: \(error.localizedDescription)") }
    guard let root = object as? [String: Any],
          let profile = root["profile"] as? [String: Any],
          let cache = profile["info_cache"] as? [String: Any] else {
        throw RouterError("browser Local State has no profile.info_cache")
    }
    return try cache.map { dir, raw in
        guard !dir.isEmpty, dir != ".", dir != "..", !dir.contains("/"), !dir.contains("\\"),
              let info = raw as? [String: Any], let name = info["name"] as? String else {
            throw RouterError("invalid profile entry '\(dir)'")
        }
        return BrowserProfile(directory: dir, name: name)
    }.sorted { $0.directory < $1.directory }
}

func resolveProfile(_ requested: String, profiles: [BrowserProfile]) throws -> String {
    if let direct = profiles.first(where: { $0.directory == requested }) { return direct.directory }
    let exact = profiles.filter { $0.name == requested }
    let matches = exact.isEmpty ? profiles.filter { $0.name.lowercased() == requested.lowercased() } : exact
    if matches.count == 1 { return matches[0].directory }
    if matches.isEmpty { throw RouterError("profile '\(requested)' not found; run --list-profiles") }
    throw RouterError("profile '\(requested)' is ambiguous; use \(matches.map(\.directory).joined(separator: ", "))")
}

struct Route: Equatable {
    let url: URL
    let browser: String
    let profile: String?
    let directory: String?
    let reason: String
}

func planRoute(
    _ text: String,
    config: Config,
    profiles: (String) throws -> [BrowserProfile]
) throws -> Route {
    let url = try validatedURL(text)
    let selected = try config.profile(for: url)
    let destination = try config.destination(selected.name)
    let directory = try destination.profile.map { try resolveProfile($0, profiles: profiles(destination.browser)) }
    return Route(url: url, browser: destination.browser, profile: destination.profile, directory: directory, reason: selected.reason)
}
