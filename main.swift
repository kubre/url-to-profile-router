import AppKit
import CoreServices

struct Rule { var host: String; var profile: String }
struct Config { var browser: String; var rules: [Rule]; var fallbackProfile: String? }

let fm = FileManager.default
let home = NSHomeDirectory()
let configPath = home + "/.config/url-router.conf"
let heliumSupport = home + "/Library/Application Support/net.imput.helium"
let defaultBrowserID = "net.imput.helium"

// Keep in sync with rules.conf (used only if the bundled template is missing).
let embeddedConfig = """
# URL to Profile Router — one rule per line: <domain> <helium-profile>
# First match wins. Subdomains match too: github.com covers gist.github.com.
github.com tars
youtube.com persoanl
youtu.be persoanl
music.youtube.com persoanl
# @browser <bundle-id>  (default net.imput.helium)
# @fallback <profile>   (default: Helium's last-used profile)
"""

func defaultConfig() -> String {
    if let u = Bundle.main.url(forResource: "rules", withExtension: "conf"),
       let s = try? String(contentsOf: u, encoding: .utf8) { return s }
    return embeddedConfig
}

func loadConfig() -> Config {
    if !fm.fileExists(atPath: configPath) {
        try? fm.createDirectory(atPath: (configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? defaultConfig().write(toFile: configPath, atomically: true, encoding: .utf8)
    }
    let text = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? defaultConfig()
    var browser = defaultBrowserID
    var fallback: String? = nil
    var rules: [Rule] = []
    for raw in text.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count != 2 { continue }
        let key = String(parts[0])
        let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
        if value.isEmpty { continue }
        if key == "@browser" { browser = value }
        else if key == "@fallback" { fallback = value }
        else if !key.hasPrefix("@") { rules.append(Rule(host: key, profile: value)) }
    }
    return Config(browser: browser, rules: rules, fallbackProfile: fallback)
}

// Helium's Local State maps profile dirs ("Profile 3") to display names ("tars").
// Read it with a tiny brace-tracking scan instead of a JSON parser.
func heliumProfiles() -> [String: String] {
    let state = heliumSupport + "/Local State"
    guard let data = fm.contents(atPath: state),
          let t = String(data: data, encoding: .utf8),
          let key = t.range(of: "\"info_cache\""),
          let open = t[key.upperBound...].firstIndex(of: "{") else { return [:] }
    var out: [String: String] = [:]
    var depth = 0
    var dir: String? = nil
    var i = open
    let end = t.endIndex
    func readString(_ i: inout String.Index) -> String {
        var s = ""
        i = t.index(after: i)
        while i < end, t[i] != "\"" {
            if t[i] == "\\" { i = t.index(after: i); if i < end { s.append(t[i]); i = t.index(after: i) } }
            else { s.append(t[i]); i = t.index(after: i) }
        }
        if i < end { i = t.index(after: i) }
        return s
    }
    func skipSpace(_ i: inout String.Index) {
        while i < end, " \t\n\r".contains(t[i]) { i = t.index(after: i) }
    }
    while i < end {
        let c = t[i]
        if c == "{" { depth += 1; i = t.index(after: i) }
        else if c == "}" {
            depth -= 1
            if depth <= 0 { break }
            if depth == 1 { dir = nil }
            i = t.index(after: i)
        } else if c == "\"" {
            let s = readString(&i)
            var k = i; skipSpace(&k)
            if k < end, t[k] == ":" {
                if depth == 1 { dir = s }
                else if depth == 2, s == "name", let d = dir {
                    var m = t.index(after: k); skipSpace(&m)
                    if m < end, t[m] == "\"" { out[readString(&m)] = d; i = m }
                }
            }
        } else { i = t.index(after: i) }
    }
    return out
}

func profileDir(for name: String) -> String? {
    let profiles = heliumProfiles()
    if let exact = profiles[name] { return exact }
    let lower = name.lowercased()
    for (n, dir) in profiles where n.lowercased() == lower { return dir }
    return nil
}

func matchProfile(host: String, cfg: Config) -> String? {
    let h = host.lowercased()
    for rule in cfg.rules {
        let p = rule.host.lowercased().trimmingCharacters(in: .init(charactersIn: "."))
        if h == p || h.hasSuffix("." + p) { return rule.profile }
    }
    return cfg.fallbackProfile
}

func launch(_ appURL: URL, _ args: [String]) {
    let conf = NSWorkspace.OpenConfiguration()
    conf.activates = true
    conf.arguments = args
    NSWorkspace.shared.openApplication(at: appURL, configuration: conf) { _, _ in }
}

func openURL(_ urlString: String, dryRun: Bool = false) {
    guard let url = URL(string: urlString) else { return }
    let cfg = loadConfig()
    let browserID = cfg.browser.isEmpty ? defaultBrowserID : cfg.browser
    let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserID)
    let appURL = ((resolved != nil && fm.fileExists(atPath: resolved!.path)) ? resolved! : URL(fileURLWithPath: "/Applications/Helium.app"))
    if url.isFileURL {
        if dryRun { print("\(urlString) -> \(browserID) (local file, default profile)") }
        else { launch(appURL, [urlString]) }
        return
    }
    guard let host = url.host else { return }
    let profile = matchProfile(host: host, cfg: cfg)
    var dir: String? = nil
    if let p = profile { dir = profileDir(for: p) ?? p }
    if dryRun {
        print("\(urlString) -> \(browserID) profile=\(profile ?? "(default)") dir=\(dir ?? "(default)")")
        return
    }
    if let d = dir { launch(appURL, ["--profile-directory=\(d)", urlString]) }
    else { launch(appURL, [urlString]) }
}

class Delegate: NSObject, NSApplicationDelegate {
    var idle: Timer?
    func applicationDidFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:withReply:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        armIdle()
    }
    func application(_ app: NSApplication, open urls: [URL]) {
        for u in urls { openURL(u.absoluteString) }
        armIdle()
    }
    @objc func handleURL(_ event: NSAppleEventDescriptor, withReply: NSAppleEventDescriptor) {
        if let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue { openURL(s) }
        armIdle()
    }
    func armIdle() {
        idle?.invalidate()
        idle = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in NSApp.terminate(nil) }
    }
}

let args = CommandLine.arguments
if args.contains("--list-profiles") {
    for (name, dir) in heliumProfiles().sorted(by: { $0.key < $1.key }) { print("\(name) -> \(dir)") }
    exit(0)
}
if args.contains("--set-default") {
    let id = Bundle.main.bundleIdentifier ?? "com.vaibhav.urlrouter"
    LSSetDefaultHandlerForURLScheme("http" as CFString, id as CFString)
    LSSetDefaultHandlerForURLScheme("https" as CFString, id as CFString)
    print("set default browser to \(id) (if nothing changed, set it in System Settings → Desktop & Dock)")
    exit(0)
}
let urls = args.dropFirst().filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") || $0.hasPrefix("file://") }
if args.contains("--dry-run") || !urls.isEmpty {
    let dry = args.contains("--dry-run")
    if urls.isEmpty, dry {
        for sample in ["https://github.com/foo", "https://www.youtube.com/watch?v=x", "https://youtu.be/x", "https://example.com"] { openURL(sample, dryRun: true) }
    } else {
        for u in urls { openURL(u, dryRun: dry) }
        if !dry { sleep(2) }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.run()
