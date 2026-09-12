import AppKit
import CoreServices
import UniformTypeIdentifiers
import Foundation

let fm = FileManager.default
let home = NSHomeDirectory()
let configURL = URL(fileURLWithPath: home + "/.config/url-router.conf")
let templateURL = Bundle.main.url(forResource: "rules", withExtension: "conf")
let bundleURL = Bundle.main.bundleURL

func describeOSStatus(_ status: OSStatus) -> String {
    switch status {
    case noErr: return "success"
    case -10827: return "kLSNoExecutableErr"
    default: return "OSStatus \(status)"
    }
}

func createConfigIfMissing() throws {
    if fm.fileExists(atPath: configURL.path) { return }
    guard let templateURL else { throw RouterError("bundled rules.conf is missing; reinstall the app") }
    try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    do { try fm.copyItem(at: templateURL, to: configURL) }
    catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileWriteFileExistsError { }
}

func loadConfig(create: Bool = false) throws -> Config {
    if create { try createConfigIfMissing() }
    if !fm.fileExists(atPath: configURL.path) {
        guard let templateURL else { throw RouterError("bundled rules.conf is missing; reinstall the app") }
        return try Config(String(contentsOf: templateURL, encoding: .utf8), source: templateURL.path)
    }
    do { return try Config(String(contentsOf: configURL, encoding: .utf8), source: configURL.path) }
    catch { throw RouterError("cannot load \(configURL.path): \(error.localizedDescription)") }
}

func browserURL(_ cfg: Config) throws -> URL {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: cfg.browser),
          let bundle = Bundle(url: url), bundle.bundleIdentifier?.lowercased() != Config.routerID,
          let executable = bundle.executableURL, fm.isExecutableFile(atPath: executable.path) else {
        throw RouterError("browser '\(cfg.browser)' is not installed or executable")
    }
    return url
}

func profiles(_ cfg: Config) throws -> [BrowserProfile] {
    guard cfg.supportsProfileSwitching else { return [] }
    let state = try cfg.profileRoot(home: home).appendingPathComponent("Local State")
    do { return try parseProfiles(Data(contentsOf: state)) }
    catch { throw RouterError("\(state.path): \(error.localizedDescription)") }
}

func checkedRoute(_ text: String, cfg: Config, profiles: () throws -> [BrowserProfile]) throws -> Route {
    let route = try planRoute(text, config: cfg, profiles: profiles, requireProfiles: cfg.supportsProfileSwitching)
    if let dir = route.directory {
        let root = try cfg.profileRoot(home: home).standardizedFileURL
        let target = root.appendingPathComponent(dir).standardizedFileURL
        var isDir: ObjCBool = false
        guard target.deletingLastPathComponent() == root,
              fm.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            throw RouterError("profile directory is missing: \(target.path)")
        }
    }
    return route
}

func report(_ cfg: Config) throws -> String {
    _ = try browserURL(cfg)
    var lines = ["OK — \(cfg.rules.count) rules", "Browser: \(cfg.browser)"]
    if cfg.supportsProfileSwitching {
        let ps = try profiles(cfg)
        for rule in cfg.rules { _ = try resolveProfile(rule.profile, profiles: ps) }
        if let fallback = cfg.fallback { _ = try resolveProfile(fallback, profiles: ps) }
    }
    lines += cfg.warnings.map { "Warning: \($0)" }
    return lines.joined(separator: "\n")
}

func setDefault() throws {
    if bundleURL.path.contains(".app/Contents/MacOS/") {
        let registerStatus = LSRegisterURL(bundleURL as CFURL, true)
        guard registerStatus == noErr else { throw RouterError("could not register app bundle (\(describeOSStatus(registerStatus)))") }
    }
    let id = Bundle.main.bundleIdentifier ?? Config.routerID
    for scheme in ["http", "https"] {
        let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, id as CFString)
        if status != noErr { throw RouterError("could not set \(scheme) handler (OSStatus \(status))") }
    }
}

func err(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

final class Delegate: NSObject, NSApplicationDelegate {
    struct Job { let app: URL; let urls: [URL]; let args: [String] }
    let initial: [String]
    var queue: [Job] = []
    var busy = false
    var failed: [(String, String)] = []
    var statusItem: NSStatusItem?
    var resident: Bool { initial.isEmpty }

    init(initial: [String] = []) { self.initial = initial }

    func applicationDidFinishLaunching(_ n: Notification) {
        if resident { showStatusItem() } else { route(initial) }
    }

    func showStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "URL to Profile Router")
        let menu = NSMenu()
        menu.addItem(withTitle: "Set as Default Browser", action: #selector(setAsDefault), keyEquivalent: "d").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Edit Rules…", action: #selector(editRules), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit URL to Profile Router", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc func setAsDefault() {
        do {
            try setDefault()
            let alert = NSAlert()
            alert.messageText = "Default browser updated"
            alert.informativeText = "URL to Profile Router is now the default handler for http and https."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not set default"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Close")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc func editRules() {
        do {
            try createConfigIfMissing()
            let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText)
                ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            NSWorkspace.shared.open([configURL], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            let alert = NSAlert()
            alert.messageText = "Cannot open rules"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        route(urls.map(\.absoluteString))
    }

    func route(_ inputs: [String]) {
        do {
            let cfg = try loadConfig(create: true)
            let app = try browserURL(cfg)
            var cached: [BrowserProfile]?
            func ps() throws -> [BrowserProfile] {
                if let cached { return cached }
                let value = try profiles(cfg); cached = value; return value
            }
            for input in inputs {
                do {
                    let route = try checkedRoute(input, cfg: cfg, profiles: ps)
                    var args = route.directory.map { ["--profile-directory=\($0)"] } ?? []
                    args += ["--", route.url.absoluteString]
                    queue.append(Job(app: app, urls: [route.url], args: args))
                } catch { failed.append((input, error.localizedDescription)) }
            }
            launchNext()
        } catch {
            failed += inputs.map { ($0, error.localizedDescription) }
            showFailure()
            finish()
        }
    }

    func launchNext() {
        guard !busy else { return }
        guard !queue.isEmpty else { showFailure(); finish(); return }
        busy = true
        let job = queue.removeFirst()
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.createsNewApplicationInstance = true
        cfg.arguments = job.args
        NSWorkspace.shared.openApplication(at: job.app, configuration: cfg) { _, error in
            DispatchQueue.main.async {
                if let error { self.failed += job.urls.map { ($0.absoluteString, error.localizedDescription) } }
                self.busy = false
                self.launchNext()
            }
        }
    }

    func showFailure() {
        guard !failed.isEmpty else { return }
        let message = failed.map { "\($0.0)\n\($0.1)" }.joined(separator: "\n\n")
        let alert = NSAlert()
        alert.messageText = "Some links were not opened"
        alert.informativeText = message
        alert.addButton(withTitle: "Copy Details")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message, forType: .string)
        }
        failed.removeAll()
    }

    func finish() {
        guard !resident, !busy, queue.isEmpty else { return }
        DispatchQueue.main.async { if !self.busy && self.queue.isEmpty { NSApp.terminate(nil) } }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    if args.contains("--help") || args.contains("-h") {
        print("Router [--dry-run] <URL...>\nRouter --check | --list-profiles | --set-default")
        exit(0)
    }
    if args.contains("--check") {
        print(try report(loadConfig()))
        exit(0)
    }
    if args.contains("--list-profiles") {
        let cfg = try loadConfig()
        for p in try profiles(cfg) { print("\(p.name) -> \(p.directory)") }
        exit(0)
    }
    if args.contains("--set-default") {
        try setDefault()
        print("default browser set to URL to Profile Router")
        exit(0)
    }
    let dry = args.contains("--dry-run")
    let inputs = args.filter { !$0.hasPrefix("-") }
    if dry {
        let cfg = try loadConfig()
        _ = try browserURL(cfg)
        let samples = inputs.isEmpty ? ["https://github.com/foo", "https://youtube.com", "https://example.com"] : inputs
        var ps: [BrowserProfile]?
        for input in samples {
            let route = try checkedRoute(input, cfg: cfg) {
                if let ps { return ps }
                let value = try profiles(cfg); ps = value; return value
            }
            print("\(input) -> \(route.profile ?? "default") [\(route.directory ?? "last used")] (\(route.reason))")
        }
        exit(0)
    }
    if !inputs.isEmpty {
        let app = NSApplication.shared
        let delegate = Delegate(initial: inputs)
        app.delegate = delegate
        app.run()
        exit(0)
    }
} catch {
    err(error.localizedDescription)
    exit(1)
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.run()
