import Foundation

struct TestFailure: Error {}
func expect(_ value: @autoclosure () -> Bool) throws { if !value() { throw TestFailure() } }
func equal<T: Equatable>(_ a: T, _ b: T) throws { try expect(a == b) }
func rejects(_ body: () throws -> Void) throws { do { try body() } catch { return }; throw TestFailure() }

@main struct Tests {
    static func main() throws {
        let ps = [BrowserProfile(directory: "Default", name: "personal"), BrowserProfile(directory: "Profile 2", name: "tars")]
        let cfg = try Config("github.com tars\nyoutube.com personal")
        func route(_ url: String, _ config: Config? = nil) throws -> Route { try planRoute(url, config: config ?? cfg) { ps } }

        try equal(route("https://github.com/a").directory, "Profile 2")
        try equal(route("https://gist.github.com/a").directory, "Profile 2")
        try equal(route("https://evilgithub.com/a").directory, nil)
        try equal(route("HTTPS://GITHUB.COM/a").directory, "Profile 2")
        try equal(route("file:///tmp/a", try Config("@fallback tars")).directory, nil)
        try equal(route("https://x.test", try Config("@fallback personal")).directory, "Default")
        try equal(try Config("github.com Work Team").rules[0].profile, "Work Team")
        try rejects { _ = try Config("bad") }
        try rejects { _ = try Config("@typo x") }
        try rejects { _ = try Config("@browser com.vaibhav.urlrouter") }
        try rejects { _ = try Config("https://github.com x") }
        try equal(try canonicalHost("GitHub.com."), "github.com")
        try rejects { _ = try validatedURL("javascript:alert(1)") }
        try equal(try resolveProfile("TARS", profiles: ps), "Profile 2")
        try rejects { _ = try resolveProfile("missing", profiles: ps) }
        try rejects { _ = try resolveProfile("work", profiles: [.init(directory: "Default", name: "work"), .init(directory: "Profile 2", name: "work")]) }
        let json = #"{"profile":{"info_cache":{"Default":{"name":"caf\u00e9"},"Profile 2":{"name":"Work"}}}}"#
        try equal(try parseProfiles(Data(json.utf8))[0].name, "café")
        try rejects { _ = try parseProfiles(Data("{}".utf8)) }
        try equal(try Config("").profileRoot(home: "/tmp").path, "/tmp/Library/Application Support/net.imput.helium")
        try equal(try Config("@browser com.google.Chrome").profileRoot(home: "/tmp").path, "/tmp/Library/Application Support/Google/Chrome")
        try rejects { _ = try Config("@browser org.mozilla.firefox").profileRoot(home: "/tmp") }
        print("core tests passed")
    }
}
