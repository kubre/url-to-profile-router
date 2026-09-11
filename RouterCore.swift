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

struct Rule {
    let host: String
    let profile: String
    let line: Int
    let subdomainsOnly: Bool
    var pattern: String { (subdomainsOnly ? "*." : "") + host }

    func matches(_ candidate: String) -> Bool {
        hostMatches(candidate, rule: host) && (!subdomainsOnly || candidate != host)
    }
    func covers(_ other: Rule) -> Bool {
        if host == other.host { return !subdomainsOnly || other.subdomainsOnly }
        return matches(other.host)
    }
}

// These functions contain no AppKit or filesystem access, so routing can be tested
// without opening a browser, changing defaults, or touching a real profile.
struct Config {
    static let routerID = "com.vaibhav.urlrouter"
    static let defaultBrowserID = "net.imput.helium"
    var browser = defaultBrowserID
    var userDataDirectory: String?
    var fallbackProfile: String?
    var rules: [Rule] = []
    var warnings: [String] = []

    init(text: String, source: String = "config") throws {
        var errors: [String] = []
        var directives: Set<String> = []
        var contents = text
        if contents.hasPrefix("\u{feff}") { contents.removeFirst() }
        contents = contents.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for (index, raw) in contents.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let location = "\(source):\(index + 1)"
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2 else {
                errors.append("\(location): expected <domain> <profile> or @directive <value>.")
                continue
            }
            let key = String(parts[0])
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            do {
                guard !value.isEmpty, value.rangeOfCharacter(from: .controlCharacters) == nil else {
                    throw RouterError("profile/directive value must be nonempty and contain no control characters.")
                }
                if key.hasPrefix("@") {
                    guard directives.insert(key).inserted else {
                        throw RouterError("duplicate \(key); keep just one value.")
                    }
                    switch key {
                    case "@browser":
                        guard value.lowercased() != Self.routerID,
                              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }),
                              value.contains(".") else {
                            throw RouterError("@browser must be a browser bundle ID, not the router itself.")
                        }
                        browser = value
                    case "@fallback": fallbackProfile = value
                    case "@user-data-dir":
                        guard value.hasPrefix("/") || value.hasPrefix("~/") else {
                            throw RouterError("@user-data-dir needs an absolute path or ~/path (without quotes).")
                        }
                        userDataDirectory = value
                    default: throw RouterError("unknown directive \(key). Use @browser, @fallback, or @user-data-dir.")
                    }
                } else {
                    // A single leading *. is the only wildcard; it never crosses
                    // the host boundary or looks at a URL's path/query/user info.
                    let wildcard = key.hasPrefix("*.")
                    var bare = wildcard ? String(key.dropFirst(2)) : key
                    if !wildcard && bare.hasPrefix(".") { bare.removeFirst() } // legacy syntax
                    let host = try canonicalHost(bare)
                    guard !wildcard || !isIPAddress(host) else {
                        throw RouterError("Invalid wildcard '\(key)': IP literals match exactly, not by subdomain.")
                    }
                    let rule = Rule(host: host, profile: value, line: index + 1, subdomainsOnly: wildcard)
                    if let earlier = rules.first(where: { $0.covers(rule) }) {
                        warnings.append("\(location): \(key) is covered by line \(earlier.line) (\(earlier.pattern)); first match wins.")
                    }
                    rules.append(rule)
                }
            } catch { errors.append("\(location): \(error.localizedDescription)") }
        }
        if !errors.isEmpty { throw RouterError(errors.joined(separator: "\n")) }
        if let knownID = Self.browserRoots.keys.first(where: { $0.lowercased() == browser.lowercased() }) {
            browser = knownID
        }
    }

    func selection(for url: URL) throws -> (profile: String?, reason: String) {
        if url.isFileURL { return (nil, "local file; browser's last-used profile") }
        guard let rawHost = url.host else { throw RouterError("URL is missing a host.") }
        let host = try canonicalHost(rawHost)
        if let rule = rules.first(where: { $0.matches(host) }) {
            return (rule.profile, "line \(rule.line): \(rule.pattern)")
        }
        return (fallbackProfile, fallbackProfile == nil ? "no matching rule; browser's last-used profile" : "@fallback")
    }

    static let browserRoots = [
        "net.imput.helium": "net.imput.helium",
        "com.google.Chrome": "Google/Chrome",
        "org.chromium.Chromium": "Chromium",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi"
    ]

    var usesChromiumArguments: Bool { userDataDirectory != nil || Self.browserRoots[browser] != nil }

    func profileRoot(home: String) throws -> URL {
        if let directory = userDataDirectory {
            let path = directory.hasPrefix("~/") ? home + String(directory.dropFirst()) : directory
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        guard let root = Self.browserRoots[browser] else {
            throw RouterError("Profile location for \(browser) is unknown. For a Chromium browser, set @user-data-dir to the parent of its chrome://version Profile Path.")
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(root, isDirectory: true)
    }
}

func canonicalHost(_ input: String) throws -> String {
    var host = input.lowercased()
    // A DNS trailing dot is equivalent. A leading dot is config-only syntax.
    if host.hasSuffix(".") { host.removeLast() }
    if host.contains(":") || host.contains("[") || host.contains("]") {
        let literal = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var address = in6_addr()
        guard literal.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            throw RouterError("Invalid IPv6 host '\(input)'; use [::1] without a port.")
        }
        // INET6_ADDRSTRLEN is the system API's required output buffer size.
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else {
            throw RouterError("Cannot normalize IPv6 host '\(input)'.")
        }
        return "[\(String(cString: buffer))]"
    }
    guard !host.isEmpty,
          !host.contains(where: { $0.isWhitespace }),
          host.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\?#@%*" ).union(.controlCharacters)) == nil,
          let url = URL(string: "https://\(host)/"),
          url.user == nil, url.password == nil, url.port == nil,
          let parsed = url.host?.lowercased(), !parsed.isEmpty else {
        throw RouterError("Invalid domain '\(input)'. Use only a host or *.domain, not a URL, port, path, or embedded wildcard.")
    }
    guard parsed.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
        !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-") &&
        label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }) else { throw RouterError("Invalid domain '\(input)'. Check its labels and punctuation.") }
    // Chromium also accepts legacy IPv4 spellings (127.1, hex and octal).
    // Normalize them before matching so they cannot bypass an IP rule.
    var address = in_addr()
    if parsed.withCString({ inet_aton($0, &address) }) == 1 {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else {
            throw RouterError("Cannot normalize IPv4 host '\(input)'.")
        }
        return String(cString: buffer)
    }
    return parsed
}

func isIPAddress(_ host: String) -> Bool {
    var address = in_addr()
    return host.hasPrefix("[") || host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1
}

func hostMatches(_ host: String, rule: String) -> Bool {
    if host == rule { return true }
    if isIPAddress(rule) { return false }
    return host.hasSuffix("." + rule)
}

func validatedURL(_ input: String) throws -> URL {
    guard input.rangeOfCharacter(from: .controlCharacters) == nil,
          !input.contains("\\"),
          let url = URL(string: input), let scheme = url.scheme?.lowercased(),
          ["http", "https", "file"].contains(scheme) else {
        throw RouterError("Unsupported or invalid URL. Expected http://, https://, or file://.")
    }
    if scheme == "file" {
        guard url.path.hasPrefix("/"), !url.path.isEmpty,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else {
            throw RouterError("Expected a local, absolute file URL (file:///path/to/file).")
        }
    } else {
        guard let host = url.host, !host.isEmpty else { throw RouterError("HTTP(S) URL is missing a host.") }
        // Foundation and browsers disagree about escaped hosts. Refuse those
        // ambiguous authorities instead of routing on one host and opening another.
        guard let separator = input.range(of: "://") else { throw RouterError("Expected an absolute HTTP(S) URL.") }
        let authority = input[separator.upperBound...].prefix { !"/?#".contains($0) }
        let hostPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
        guard !hostPort.contains("%") else {
            throw RouterError("Percent-escaped URL hosts are ambiguous. Use a plain domain, Unicode domain, or punycode host.")
        }
        _ = try canonicalHost(host)
    }
    return url
}

struct BrowserProfile: Equatable {
    let directory: String
    let name: String
}

func browserProfiles(from data: Data) throws -> [BrowserProfile] {
    // Foundation is a system framework already used by AppKit, not a bundled
    // dependency. Its JSON parser handles escapes, Unicode and corrupt input.
    let json: Any
    do { json = try JSONSerialization.jsonObject(with: data) }
    catch { throw RouterError("Cannot parse browser Local State: \(error.localizedDescription)") }
    guard let root = json as? [String: Any],
          let profile = root["profile"] as? [String: Any],
          let cache = profile["info_cache"] as? [String: Any] else {
        throw RouterError("Browser Local State has no profile.info_cache. Open the browser and create a profile first.")
    }
    return try cache.map { directory, entry in
        guard !directory.isEmpty, directory != ".", directory != "..",
              !directory.contains("/"), !directory.contains("\\"),
              directory.rangeOfCharacter(from: .controlCharacters) == nil,
              let info = entry as? [String: Any], let name = info["name"] as? String else {
            throw RouterError("Invalid profile entry '\(directory)' in browser Local State.")
        }
        return BrowserProfile(directory: directory, name: name)
    }.sorted { $0.directory < $1.directory }
}

func resolveProfile(_ name: String, in profiles: [BrowserProfile]) throws -> String {
    // Directory IDs remain unambiguous even when multiple profiles share a name.
    if let direct = profiles.first(where: { $0.directory == name }) { return direct.directory }
    let exact = profiles.filter { $0.name == name }
    let matches = exact.isEmpty ? profiles.filter { $0.name.lowercased() == name.lowercased() } : exact
    if matches.count == 1 { return matches[0].directory }
    if matches.isEmpty {
        throw RouterError("Profile '\(name)' was not found. Run --list-profiles and use an existing name or directory; no new profile was created.")
    }
    throw RouterError("Profile '\(name)' is ambiguous. Use a directory: \(matches.map(\.directory).joined(separator: ", ")).")
}

struct Route {
    let url: URL
    let profile: String?
    let directory: String?
    let reason: String
    var explanation: String {
        "\(profile ?? "Last-used profile") → \(directory ?? "(browser default)")\n\(reason)"
    }
    func arguments(config: Config, home: String) throws -> [String] {
        var args: [String] = []
        if config.userDataDirectory != nil { args.append("--user-data-dir=\(try config.profileRoot(home: home).path)") }
        if let directory { args.append("--profile-directory=\(directory)") }
        // Do not invoke a shell. -- also prevents any URL from becoming a flag.
        return args + ["--", url.absoluteString]
    }
}

func planRoute(_ input: String, config: Config, profiles: () throws -> [BrowserProfile]) throws -> Route {
    let url = try validatedURL(input)
    let selection = try config.selection(for: url)
    let directory: String?
    if let profile = selection.profile { directory = try resolveProfile(profile, in: profiles()) }
    else { directory = nil }
    return Route(url: url, profile: selection.profile, directory: directory, reason: selection.reason)
}

struct Command {
    enum Mode: Equatable { case application, settings, help, check, profiles, dryRun, setDefault, open }
    let mode: Mode
    let urls: [String]

    init(_ arguments: [String]) throws {
        let modes: [String: Mode] = ["--settings": .settings, "--help": .help, "-h": .help,
            "--check": .check, "--list-profiles": .profiles, "--dry-run": .dryRun, "--set-default": .setDefault]
        var selected: Mode?
        var urls: [String] = []
        var options = true
        for argument in arguments {
            if options && argument == "--" { options = false; continue }
            // Finder's legacy process-serial-number argument is not a URL.
            if options && argument.hasPrefix("-psn_") { continue }
            if options, let mode = modes[argument] {
                guard selected == nil else { throw RouterError("Choose one command; do not combine mode flags.") }
                selected = mode
            } else {
                if options && argument.hasPrefix("-") { throw RouterError("Unknown option '\(argument)'. See --help.") }
                _ = try validatedURL(argument)
                urls.append(argument)
            }
        }
        if let selected, selected != .dryRun, !urls.isEmpty {
            throw RouterError("This command does not accept URLs. Use --dry-run or pass URLs without a mode flag.")
        }
        self.mode = selected ?? (urls.isEmpty ? .application : .open)
        self.urls = urls
    }
}

func readConfig(at file: URL, template: URL?, createIfMissing: Bool) throws -> Config {
    let fm = FileManager.default
    if !fm.fileExists(atPath: file.path) && (try? fm.attributesOfItem(atPath: file.path)) == nil {
        guard let template else { throw RouterError("Missing config \(file.path) and bundled rules.conf. Rebuild/install the app.") }
        if createIfMissing {
            do {
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                // copyItem never overwrites an existing config, even if another
                // invocation creates it between the existence check and copy.
                do { try fm.copyItem(at: template, to: file) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { }
            } catch { throw RouterError("Cannot create \(file.path): \(error.localizedDescription)") }
        } else {
            do { return try Config(text: String(contentsOf: template, encoding: .utf8), source: template.path) }
            catch { throw RouterError("Cannot load bundled rules: \(error.localizedDescription)") }
        }
    }
    do { return try Config(text: String(contentsOf: file, encoding: .utf8), source: file.path) }
    catch { throw RouterError("Cannot load \(file.path): \(error.localizedDescription)") }
}

// Existing paths only: typos must not ask Chromium to create new user data.
func requireProfileDirectory(_ directory: String?, config: Config, home: String) throws {
    guard directory != nil || config.userDataDirectory != nil else { return }
    let fm = FileManager.default
    let root = try config.profileRoot(home: home).resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw RouterError("Browser data directory is missing: \(root.path). Open the browser with that data directory first.")
    }
    if config.userDataDirectory != nil {
        let state = root.appendingPathComponent("Local State")
        guard fm.fileExists(atPath: state.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw RouterError("No Local State in \(root.path). @user-data-dir must select existing browser data, not a new folder or an individual profile.")
        }
    }
    guard let directory else { return }
    guard !directory.isEmpty, directory != ".", directory != "..",
          !directory.contains("/"), !directory.contains("\\"),
          directory.rangeOfCharacter(from: .controlCharacters) == nil else {
        throw RouterError("Invalid profile directory '\(directory)'.")
    }
    let profile = root.appendingPathComponent(directory).resolvingSymlinksInPath().standardizedFileURL
    guard profile.deletingLastPathComponent() == root else {
        throw RouterError("Profile '\(directory)' resolves outside \(root.path). Refusing an unexpected profile location.")
    }
    guard fm.fileExists(atPath: profile.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw RouterError("Profile directory is missing: \(profile.path). Open that profile in the browser first; the router will not create it.")
    }
}
