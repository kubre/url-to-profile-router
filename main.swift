import AppKit
import CoreServices
import ServiceManagement
import UniformTypeIdentifiers
import Foundation

let fm = FileManager.default
let home = NSHomeDirectory()
let configURL = URL(fileURLWithPath: home + "/.config/url-router.conf")
let templateURL = Bundle.main.url(forResource: "rules", withExtension: "conf")
let bundleURL = Bundle.main.bundleURL

final class FileCache<T> {
    private var entries: [String: (Date, T)] = [:]
    func value(at path: String, load: () throws -> T) throws -> T {
        let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        if let (stamp, stored) = entries[path], stamp == modified { return stored }
        let loaded = try load()
        entries[path] = (modified, loaded)
        return loaded
    }
}
let configCache = FileCache<Config>()
let profileCache = FileCache<[BrowserProfile]>()

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
    return try configCache.value(at: configURL.path) {
        do { return try Config(String(contentsOf: configURL, encoding: .utf8), source: configURL.path) }
        catch { throw RouterError("cannot load \(configURL.path): \(error.localizedDescription)") }
    }
}

func browserURL(_ browser: String) throws -> URL {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser),
          let bundle = Bundle(url: url), bundle.bundleIdentifier?.lowercased() != Config.routerID,
          let executable = bundle.executableURL, fm.isExecutableFile(atPath: executable.path) else {
        throw RouterError("browser '\(browser)' is not installed or executable")
    }
    return url
}

func profiles(_ browser: String) throws -> [BrowserProfile] {
    let state = try Config.profileRoot(browser: browser, home: home).appendingPathComponent("Local State")
    return try profileCache.value(at: state.path) {
        do { return try parseProfiles(Data(contentsOf: state)) }
        catch { throw RouterError("\(state.path): \(error.localizedDescription)") }
    }
}

func notifyRunningBrowser(_ browser: String, app: URL, args: [String]) -> Bool {
    guard let root = try? Config.profileRoot(browser: browser, home: home),
          let cookie = try? fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent("SingletonCookie").path),
          let socketPath = try? fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent("SingletonSocket").path),
          socketPath.utf8.count < 104,
          (try? fm.destinationOfSymbolicLink(atPath: (socketPath as NSString).deletingLastPathComponent + "/SingletonCookie")) == cookie,
          let executable = Bundle(url: app)?.executableURL else { return false }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: socketPath.utf8) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return false }

    let message = Array((["START", "/", executable.path] + args).joined(separator: "\0").utf8)
    guard message.withUnsafeBufferPointer({ send(fd, $0.baseAddress, $0.count, 0) }) == message.count,
          shutdown(fd, SHUT_WR) == 0 else { return false }
    var reply = [UInt8](repeating: 0, count: 8)
    guard recv(fd, &reply, reply.count, 0) == 3, String(decoding: reply.prefix(3), as: UTF8.self) == "ACK" else { return false }
    NSRunningApplication.runningApplications(withBundleIdentifier: browser).first?.activate(options: [])
    return true
}

func checkedRoute(_ text: String, cfg: Config, profiles: (String) throws -> [BrowserProfile]) throws -> Route {
    let route = try planRoute(text, config: cfg, profiles: profiles)
    if let dir = route.directory {
        let root = try Config.profileRoot(browser: route.browser, home: home).standardizedFileURL
        let target = root.appendingPathComponent(dir).standardizedFileURL
        var isDir: ObjCBool = false
        guard target.deletingLastPathComponent() == root,
              fm.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            throw RouterError("profile directory is missing: \(target.path)")
        }
    }
    return route
}

func defaultHandler(_ scheme: String) -> String? {
    guard let url = URL(string: "\(scheme)://example.com"),
          let application = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
    return Bundle(url: application)?.bundleIdentifier
}

func report(_ cfg: Config) throws -> String {
    var lines = ["OK: \(cfg.rules.count) rules", "Default browser: \(cfg.browser)"]
    for value in [nil, cfg.fallback] + cfg.rules.map({ Optional($0.profile) }) {
        let destination = try cfg.destination(value)
        _ = try browserURL(destination.browser)
        if let name = destination.profile { _ = try resolveProfile(name, profiles: try profiles(destination.browser)) }
    }
    for scheme in ["http", "https"] {
        let handler = defaultHandler(scheme)
        lines.append("\(scheme) handler: \(handler ?? "none")")
    }
    lines += cfg.warnings.map { "Warning: \($0)" }
    return lines.joined(separator: "\n")
}

func setDefault() throws {
    guard bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier == Config.routerID else {
        throw RouterError("run --set-default from the installed application bundle")
    }
    let registerStatus = LSRegisterURL(bundleURL as CFURL, true)
    guard registerStatus == noErr else { throw RouterError("could not register app bundle (OSStatus \(registerStatus))") }

    let id = Config.routerID
    for scheme in ["http", "https"] {
        if defaultHandler(scheme) == id { continue }
        let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, id as CFString)
        if status != noErr { throw RouterError("could not set \(scheme) handler (OSStatus \(status))") }
        guard defaultHandler(scheme) == id else {
            throw RouterError("macOS did not change the \(scheme) handler; select URL to Profile Router in System Settings > Desktop & Dock > Default web browser")
        }
    }
    try? SMAppService.mainApp.register()
}

func alert(_ title: String, _ text: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
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
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit URL to Profile Router", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc func setAsDefault() {
        do {
            try setDefault()
            alert("Default browser updated", "URL to Profile Router is now the default handler for http and https.")
        } catch { alert("Could not set default", error.localizedDescription) }
    }

    @objc func toggleLoginItem(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { alert("Could not update login item", error.localizedDescription) }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func editRules() {
        do {
            try createConfigIfMissing()
            let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText)
                ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            NSWorkspace.shared.open([configURL], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } catch { alert("Cannot open rules", error.localizedDescription) }
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        route(urls.map(\.absoluteString))
    }

    func route(_ inputs: [String]) {
        do {
            let cfg = try loadConfig(create: true)
            for input in inputs {
                do {
                    let route = try checkedRoute(input, cfg: cfg, profiles: profiles)
                    var args = route.directory.map { ["--profile-directory=\($0)"] } ?? []
                    args += ["--", route.url.absoluteString]
                    let app = try browserURL(route.browser)
                    if notifyRunningBrowser(route.browser, app: app, args: args) { continue }
                    queue.append(Job(app: app, urls: [route.url], args: args))
                } catch { failed.append((input, error.localizedDescription)) }
            }
            launchNext()
        } catch {
            failed += inputs.map { ($0, error.localizedDescription) }
            launchNext()
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
        let completion: (NSRunningApplication?, Error?) -> Void = { _, error in
            DispatchQueue.main.async {
                if let error { self.failed += job.urls.map { ($0.absoluteString, error.localizedDescription) } }
                self.busy = false
                self.launchNext()
            }
        }
        NSWorkspace.shared.openApplication(at: job.app, configuration: cfg, completionHandler: completion)
    }

    func showFailure() {
        guard !failed.isEmpty else { return }
        let message = failed.map { "\($0.0)\n\($0.1)" }.joined(separator: "\n\n")
        if !resident {
            err(message)
            exit(1)
        }
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
    let options: Set<String> = ["--help", "-h", "--check", "--list-profiles", "--set-default", "--dry-run"]
    if let unknown = args.first(where: { $0.hasPrefix("-") && !options.contains($0) }) {
        throw RouterError("unknown option '\(unknown)'; run --help")
    }
    let commands = args.filter { options.contains($0) }
    guard commands.count <= 1, commands.isEmpty || commands == ["--dry-run"] || args.count == 1 else {
        throw RouterError("use one command at a time; only --dry-run accepts URLs")
    }
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
        let browsers = Set(try ([nil, cfg.fallback] + cfg.rules.map { Optional($0.profile) }).map { try cfg.destination($0).browser })
        for browser in browsers.sorted() {
            for profile in try profiles(browser) { print("\(browser)::\(profile.name) -> \(profile.directory)") }
        }
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
        let samples = inputs.isEmpty ? ["https://github.com/foo", "https://youtube.com", "https://example.com"] : inputs
        for input in samples {
            let route = try checkedRoute(input, cfg: cfg, profiles: profiles)
            _ = try browserURL(route.browser)
            print("\(input) -> \(route.browser)::\(route.profile ?? "default") [\(route.directory ?? "last used")] (\(route.reason))")
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
