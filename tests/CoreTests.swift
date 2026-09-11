import Foundation

struct TestFailure: Error { let message: String }
func expect(_ condition: @autoclosure () -> Bool, _ message: String = "expectation failed") throws {
    if !condition() { throw TestFailure(message: message) }
}
func equal<T: Equatable>(_ actual: T, _ expected: T) throws {
    try expect(actual == expected, "expected \(expected), got \(actual)")
}
func rejects(_ fragment: String, _ body: () throws -> Void) throws {
    do { try body() } catch let error as TestFailure { throw error }
    catch { try expect(fragment.isEmpty || error.localizedDescription.contains(fragment), "unexpected error: \(error)"); return }
    throw TestFailure(message: "expected an error containing '\(fragment)'")
}

@main struct CoreTests {
    static func main() throws {
        var passed = 0
        var failed = 0
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        let profiles = [BrowserProfile(directory: "Default", name: "persoanl"),
                        BrowserProfile(directory: "Profile 2", name: "tars"),
                        BrowserProfile(directory: "Profile 3", name: "Work Team")]
        let config = try Config(text: "github.com tars\nyoutube.com persoanl\nyoutu.be persoanl")
        func route(_ input: String, _ cfg: Config? = nil) throws -> Route {
            try planRoute(input, config: cfg ?? config, profiles: { profiles })
        }
        test("exact host") { try equal(route("https://github.com/foo").directory, "Profile 2") }
        test("subdomain") { try equal(route("https://gist.github.com/foo").directory, "Profile 2") }
        test("nested subdomain") { try equal(route("https://a.b.github.com/foo").directory, "Profile 2") }
        test("suffix lookalike must not match") { try equal(route("https://evilgithub.com").directory, nil) }
        test("parent followed by attacker suffix must not match") { try equal(route("https://github.com.evil.test").directory, nil) }
        test("URL user info cannot spoof host") { try equal(route("https://github.com@evil.test").directory, nil) }
        test("case insensitive scheme and host") { try equal(route("HTTPS://GIST.GITHUB.COM/a").directory, "Profile 2") }
        test("DNS trailing dot") { try equal(route("https://github.com./a").directory, "Profile 2") }
        test("port is not part of matching") { try equal(route("https://github.com:8443/a").directory, "Profile 2") }
        test("query and fragment do not match hosts") { try equal(route("https://other.test/?next=github.com#github.com").directory, nil) }
        test("URL query and fragment retained") {
            let input = "https://github.com/a%2Fb?q=a%26b&next=https%3A%2F%2Fx.test#frag"
            try equal(route(input).url.absoluteString, input)
        }
        test("first rule wins") {
            let cfg = try Config(text: "youtube.com persoanl\nmusic.youtube.com tars")
            try equal(route("https://music.youtube.com", cfg).directory, "Default")
            try equal(cfg.warnings.count, 1)
        }
        test("specific rule before parent") {
            let cfg = try Config(text: "music.youtube.com tars\nyoutube.com persoanl")
            try equal(route("https://music.youtube.com", cfg).directory, "Profile 2")
            try equal(cfg.warnings.count, 0)
        }
        test("fallback profile") { try equal(route("https://other.test", Config(text: "@fallback Work Team")).directory, "Profile 3") }
        test("unmatched default does not read Local State") {
            _ = try planRoute("https://other.test", config: config) { throw TestFailure(message: "unexpected profile read") }
        }
        test("local files ignore fallback") {
            _ = try planRoute("file:///tmp/a%20b.html", config: Config(text: "@fallback missing")) { throw TestFailure(message: "unexpected profile read") }
        }
        test("uppercase file scheme") { try equal(route("FILE:///tmp/x.html").directory, nil) }
        test("file localhost") { _ = try validatedURL("file://localhost/tmp/x.html") }
        test("remote file URL rejected") { try rejects("local, absolute") { _ = try validatedURL("file://server/share/a.html") } }
        for invalid in ["javascript:alert(1)", "data:text/html,x", "mailto:a@b.test", "https:///", "not a url", "--incognito", "https://a.test/\nextra"] {
            test("invalid URL \(invalid.debugDescription)") { try rejects("", { _ = try validatedURL(invalid) }) }
        }
        test("blank config") { try equal(Config(text: " \n# comment\n").rules.count, 0) }
        test("tabs and names with spaces") { try equal(Config(text: "github.com\tWork Team").rules[0].profile, "Work Team") }
        test("BOM") { try equal(Config(text: "\u{feff}github.com tars").rules.count, 1) }
        test("CRLF line diagnostics") {
            try rejects("fixture:3") { _ = try Config(text: "# comment\r\ngithub.com tars\r\nbad", source: "fixture") }
        }
        test("leading and trailing dots in config") { try equal(Config(text: ".GitHub.com. tars").rules[0].host, "github.com") }
        test("unknown directive rejected") { try rejects("unknown directive @typo") { _ = try Config(text: "@typo tars") } }
        test("missing value rejected with line") { try rejects("config:1") { _ = try Config(text: "github.com") } }
        test("duplicate directive rejected") { try rejects("duplicate @fallback") { _ = try Config(text: "@fallback tars\n@fallback persoanl") } }
        test("all malformed lines reported") {
            do { _ = try Config(text: "@typo x\nbad\n@other y"); throw TestFailure(message: "accepted malformed config") }
            catch let error as RouterError { try expect(error.message.contains("config:1") && error.message.contains("config:2") && error.message.contains("config:3")) }
        }
        test("self routing rejected") { try rejects("router itself") { _ = try Config(text: "@browser com.vaibhav.urlrouter") } }
        for host in ["https://github.com", "github.com/a", "github.com:80", "*", "*.*.github.com", "github.*", "foo*.github.com", "*..github.com", "a..test", "-a.test", "a-.test", "a@github.com", "github.com?x", ".", "a%2eb.test"] {
            test("invalid rule host \(host)") { try rejects("Invalid") { _ = try Config(text: "\(host) tars") } }
        }
        test("Unicode/ASCII host equivalence") { try equal(canonicalHost("bücher.de"), canonicalHost("xn--bcher-kva.de")) }
        test("Unicode rule matches punycode URL") { try equal(route("https://xn--bcher-kva.de/", Config(text: "bücher.de tars")).directory, "Profile 2") }
        test("localhost") { try equal(route("http://localhost:3000/a", Config(text: "localhost tars")).directory, "Profile 2") }
        test("IPv4") { try equal(route("http://127.0.0.1/a", Config(text: "127.0.0.1 tars")).directory, "Profile 2") }
        test("IPv6") { try equal(route("http://[::1]:3000/a", Config(text: "[::1] tars")).directory, "Profile 2") }
        test("display name exact") { try equal(resolveProfile("tars", in: profiles), "Profile 2") }
        test("display name case insensitive") { try equal(resolveProfile("TARS", in: profiles), "Profile 2") }
        test("directory ID") { try equal(resolveProfile("Profile 2", in: profiles), "Profile 2") }
        test("Default directory ID") { try equal(resolveProfile("Default", in: profiles), "Default") }
        test("unknown name never becomes a new directory") { try rejects("not found") { _ = try resolveProfile("personal", in: profiles) } }
        test("unknown directory never creates a profile") { try rejects("not found") { _ = try resolveProfile("Profile 99", in: profiles) } }
        test("ambiguous exact names") {
            try rejects("ambiguous") { _ = try resolveProfile("Work", in: [.init(directory: "Default", name: "Work"), .init(directory: "Profile 2", name: "Work")]) }
        }
        test("ambiguous case folded names") {
            try rejects("ambiguous") { _ = try resolveProfile("WORK", in: [.init(directory: "Default", name: "work"), .init(directory: "Profile 2", name: "Work")]) }
        }
        test("exact case resolves folded ambiguity") {
            try equal(resolveProfile("Work", in: [.init(directory: "Default", name: "work"), .init(directory: "Profile 2", name: "Work")]), "Profile 2")
        }
        test("directory ID wins over matching display name") {
            try equal(resolveProfile("Default", in: [.init(directory: "Default", name: "Work"), .init(directory: "Profile 2", name: "Default")]), "Default")
        }
        func decoded(_ json: String) throws -> [BrowserProfile] { try browserProfiles(from: Data(json.utf8)) }
        test("JSON Unicode escapes, surrogate pairs, quotes and braces") {
            let found = try decoded(#"{"profile":{"info_cache":{"Default":{"name":"caf\u00e9 \ud83d\ude80 \"{x}\""}}}}"#)
            try equal(found[0].name, "café 🚀 \"{x}\"")
        }
        test("JSON reads only profile.info_cache, not an unrelated key") {
            let found = try decoded(#"{"info_cache":{"Wrong":{"name":"wrong"}},"profile":{"info_cache":{"Default":{"name":"right","nested":{"name":"not a profile"}}}}}"#)
            try equal(found, [.init(directory: "Default", name: "right")])
        }
        test("JSON duplicate display names retained") {
            try equal(decoded(#"{"profile":{"info_cache":{"Default":{"name":"Work"},"Profile 2":{"name":"Work"}}}}"#).count, 2)
        }
        for json in ["", "{", "[]", #"{"profile":{}}"#, #"{"profile":{"info_cache":[]}}"#, #"{"profile":{"info_cache":{"Default":{"name":5}}}}"#, #"{"profile":{"info_cache":{"../bad":{"name":"x"}}}}"#] {
            test("corrupt Local State \(json)") { try rejects("") { _ = try decoded(json) } }
        }
        test("Helium profile root") { try equal(Config(text: "").profileRoot(home: "/home/test").path, "/home/test/Library/Application Support/net.imput.helium") }
        test("browser setting selects that browser's profiles") { try equal(Config(text: "@browser com.google.Chrome").profileRoot(home: "/home/test").path, "/home/test/Library/Application Support/Google/Chrome") }
        test("unknown browser profile root is actionable") { try rejects("@user-data-dir") { _ = try Config(text: "@browser test.browser").profileRoot(home: "/home/test") } }
        test("custom root expands tilde") { try equal(Config(text: "@user-data-dir ~/Browser Data").profileRoot(home: "/home/test").path, "/home/test/Browser Data") }
        test("relative profile root rejected") { try rejects("absolute path") { _ = try Config(text: "@user-data-dir ./data") } }
        test("launch arguments preserve spaces without shell quoting") {
            let cfg = try Config(text: "@user-data-dir ~/Browser Data\ngithub.com tars")
            try equal(route("https://github.com/a?x=1&y=2", cfg).arguments(config: cfg, home: "/home/test"),
                      ["--user-data-dir=/home/test/Browser Data", "--profile-directory=Profile 2", "--", "https://github.com/a?x=1&y=2"])
        }
        test("default argument list contains no profile flag") { try equal(route("https://other.test").arguments(config: config, home: "/home/test"), ["--", "https://other.test"]) }
        test("command default") { try equal(Command([]).mode, .application) }
        test("command URL launch") { try equal(Command(["https://github.com"]).mode, .open) }
        test("dry run with URL") { try equal(Command(["--dry-run", "https://github.com"]).mode, .dryRun) }
        test("dry run sample mode") { try equal(Command(["--dry-run"]).urls, []) }
        test("CLI uppercase URL") { try equal(Command(["HTTPS://github.com"]).mode, .open) }
        test("Finder serial number ignored") { try equal(Command(["-psn_0_123"]).mode, .application) }
        test("unknown option") { try rejects("Unknown option") { _ = try Command(["--dr-run"]) } }
        test("conflicting commands") { try rejects("one command") { _ = try Command(["--check", "--dry-run"]) } }
        test("URL rejected for non-URL command") { try rejects("does not accept URLs") { _ = try Command(["--check", "https://a.test"]) } }
        test("end of options") { try equal(Command(["--dry-run", "--", "https://a.test"]).urls, ["https://a.test"]) }
        test("read-only config load creates nothing") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let template = dir.appendingPathComponent("rules.conf")
            try "github.com tars".write(to: template, atomically: true, encoding: .utf8)
            let configURL = dir.appendingPathComponent("nested/config")
            try equal(readConfig(at: configURL, template: template, createIfMissing: false).rules.count, 1)
            try expect(!FileManager.default.fileExists(atPath: configURL.deletingLastPathComponent().path))
        }
        test("first run creates config, subsequent loads never replace edits") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let template = dir.appendingPathComponent("rules.conf")
            try "github.com tars".write(to: template, atomically: true, encoding: .utf8)
            let configURL = dir.appendingPathComponent("nested/config")
            _ = try readConfig(at: configURL, template: template, createIfMissing: true)
            try "@fallback persoanl".write(to: configURL, atomically: true, encoding: .utf8)
            try equal(readConfig(at: configURL, template: template, createIfMissing: true).fallbackProfile, "persoanl")
        }
        test("malformed on-disk config is not silently replaced") {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            try "bad".write(to: file, atomically: true, encoding: .utf8)
            try rejects("expected <domain>") { _ = try readConfig(at: file, template: nil, createIfMissing: true) }
            try equal(String(contentsOf: file, encoding: .utf8), "bad")
        }

        test("wildcard matches subdomains but not the root") {
            let cfg = try Config(text: "*.github.com tars")
            try equal(route("https://gist.github.com", cfg).directory, "Profile 2")
            try equal(route("https://a.b.github.com", cfg).directory, "Profile 2")
            try equal(route("https://github.com", cfg).directory, nil)
            try equal(route("https://github.com.", cfg).directory, nil)
            let reason = try route("https://gist.github.com", cfg).reason
            try expect(reason.contains("*.github.com"))
        }
        test("wildcard keeps host boundaries and ignores path/query/userinfo") {
            let cfg = try Config(text: "*.github.com tars")
            for input in ["https://evilgithub.com", "https://gist.github.com.evil.test",
                          "https://gist.github.com@evil.test", "https://evil.test/gist.github.com?next=https://gist.github.com"] {
                try equal(route(input, cfg).directory, nil)
            }
        }
        test("wildcard Unicode domain and trailing dot") {
            let cfg = try Config(text: "*.BÜCHER.DE. tars")
            try equal(route("https://a.xn--bcher-kva.de", cfg).directory, "Profile 2")
            try equal(route("https://bücher.de", cfg).directory, nil)
        }
        test("wildcard shadow warnings distinguish root coverage") {
            try equal(Config(text: "*.github.com tars\ngithub.com persoanl").warnings.count, 0)
            try equal(Config(text: "github.com tars\n*.github.com persoanl").warnings.count, 1)
            try equal(Config(text: "*.github.com tars\n*.github.com persoanl").warnings.count, 1)
            try equal(Config(text: "*.github.com tars\ngist.github.com persoanl").warnings.count, 1)
            try equal(Config(text: "*.github.com tars\n*.gist.github.com persoanl").warnings.count, 1)
        }
        test("subdomains can differ from root without global wildcard") {
            let cfg = try Config(text: "*.github.com tars\ngithub.com persoanl\n@fallback Work Team")
            try equal(route("https://gist.github.com", cfg).directory, "Profile 2")
            try equal(route("https://github.com", cfg).directory, "Default")
            try equal(route("https://other.test", cfg).directory, "Profile 3")
        }
        for pattern in ["*.127.0.0.1", "*.127.1", "*.[::1]"] {
            test("IP wildcards rejected: \(pattern)") { try rejects("Invalid wildcard") { _ = try Config(text: "\(pattern) tars") } }
        }
        for host in ["127.1", "0x7f000001", "0177.0.0.1", "2130706433", "127.000.000.001"] {
            test("alternate IPv4 spelling: \(host)") {
                try equal(route("http://\(host)/", Config(text: "127.0.0.1 tars")).directory, "Profile 2")
            }
        }
        test("expanded IPv6 matches compressed rule") {
            try equal(route("http://[0:0:0:0:0:0:0:1]/", Config(text: "[::1] tars")).directory, "Profile 2")
        }
        test("IP rules never suffix-match domains") {
            try expect(!hostMatches("sub.127.0.0.1", rule: "127.0.0.1"))
        }
        for input in ["https://evil.test\\@github.com", "https://github.com\\evil.test", "https://github.com/\\evil.test"] {
            test("backslash ambiguity rejected: \(input)") { try rejects("invalid URL") { _ = try validatedURL(input) } }
        }
        test("percent escaped authority rejected") { try rejects("ambiguous") { _ = try validatedURL("https://%67ithub.com/x") } }
        test("encoded path and credentials are not mistaken for escaped host") {
            _ = try validatedURL("https://user:p%40ss@github.com/a%5Cb?q=%2F")
        }
        test("leading dot is allowed only in config, not URL authority") {
            try equal(Config(text: ".github.com tars").rules[0].host, "github.com")
            try rejects("Invalid domain") { _ = try validatedURL("https://.github.com") }
        }
        test("case cannot bypass self-routing check") { try rejects("router itself") { _ = try Config(text: "@browser COM.VAIBHAV.URLROUTER") } }
        test("browser bundle ID case normalized for profile discovery") { try equal(Config(text: "@browser COM.GOOGLE.CHROME").browser, "com.google.Chrome") }
        test("shell metacharacters stay inside one URL argument") {
            let plan = try route("https://github.com/?x=$(touch%20/tmp/nope)&y=;--no-sandbox")
            let arguments = try plan.arguments(config: config, home: "/home/test")
            try equal(arguments.count, 3)
            try equal(arguments[1], "--")
            try equal(arguments[2], plan.url.absoluteString)
            try expect(!arguments.contains("--no-sandbox"))
        }
        test("custom root must already contain browser data even for fallback") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let cfg = try Config(text: "@user-data-dir \(root.path)")
            try rejects("data directory is missing") { try requireProfileDirectory(nil, config: cfg, home: "/unused") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try rejects("No Local State") { try requireProfileDirectory(nil, config: cfg, home: "/unused") }
            try Data("{}".utf8).write(to: root.appendingPathComponent("Local State"))
            try requireProfileDirectory(nil, config: cfg, home: "/unused")
        }
        test("existing profile checked; traversal, missing paths and escaping symlinks rejected") {
            let fm = FileManager.default
            let fixture = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? fm.removeItem(at: fixture) }
            let root = fixture.appendingPathComponent("Data")
            let outside = fixture.appendingPathComponent("Data-other")
            try fm.createDirectory(at: root.appendingPathComponent("Default"), withIntermediateDirectories: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: root.appendingPathComponent("Local State"))
            let cfg = try Config(text: "@user-data-dir \(root.path)")
            try requireProfileDirectory("Default", config: cfg, home: "/unused")
            try rejects("directory is missing") { try requireProfileDirectory("Profile 99", config: cfg, home: "/unused") }
            try expect(!fm.fileExists(atPath: root.appendingPathComponent("Profile 99").path))
            for directory in ["..", "../Data-other", "/tmp", "A/B", "A\\B", "\u{0}"] {
                try rejects("Invalid profile directory") { try requireProfileDirectory(directory, config: cfg, home: "/unused") }
            }
            try fm.createSymbolicLink(at: root.appendingPathComponent("Escape"), withDestinationURL: outside)
            try rejects("outside") { try requireProfileDirectory("Escape", config: cfg, home: "/unused") }
        }
        test("dangling config symlink is not overwritten or followed for creation") {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? fm.removeItem(at: root) }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let config = root.appendingPathComponent("config")
            let target = root.appendingPathComponent("absent")
            let template = root.appendingPathComponent("rules.conf")
            try "github.com tars".write(to: template, atomically: true, encoding: .utf8)
            try fm.createSymbolicLink(at: config, withDestinationURL: target)
            try rejects("Cannot load") { _ = try readConfig(at: config, template: template, createIfMissing: true) }
            try expect(!fm.fileExists(atPath: target.path))
            try equal(fm.destinationOfSymbolicLink(atPath: config.path), target.path)
        }

        print("\n\(passed) passed; \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
