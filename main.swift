import AppKit
import CoreServices

// Override is useful for isolated diagnostics/tests; normal installs use ~/.config.
let configFile = ProcessInfo.processInfo.environment["URL_ROUTER_CONFIG"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/url-router.conf")
let home = FileManager.default.homeDirectoryForCurrentUser.path
let templateFile = Bundle.main.url(forResource: "rules", withExtension: "conf")

func loadConfig(create: Bool = false) throws -> Config {
    try readConfig(at: configFile, template: templateFile, createIfMissing: create)
}

func applicationURL(for config: Config) throws -> URL {
    guard config.browser.lowercased() != Config.routerID,
          let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: config.browser),
          let bundle = Bundle(url: url), bundle.bundleIdentifier?.lowercased() != Config.routerID,
          let executable = bundle.executableURL,
          FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw RouterError("Browser '\(config.browser)' is not installed, is not executable, or points back to this router. Correct @browser in \(configFile.path).")
    }
    return url
}

func loadProfiles(_ config: Config) throws -> [BrowserProfile] {
    let state = try config.profileRoot(home: home).appendingPathComponent("Local State")
    do { return try browserProfiles(from: Data(contentsOf: state)) }
    catch { throw RouterError("\(state.path): \(error.localizedDescription)") }
}

func checkedRoute(_ input: String, config: Config, profiles: () throws -> [BrowserProfile]) throws -> Route {
    let route = try planRoute(input, config: config, profiles: profiles)
    try requireProfileDirectory(route.directory, config: config, home: home)
    return route
}

func defaultStatus() -> String {
    let defaults = ["http", "https"].map { scheme -> String in
        let id = LSCopyDefaultHandlerForURLScheme(scheme as CFString)?.takeRetainedValue() as String?
        return "\(scheme): \(id == Config.routerID ? "this router" : id ?? "not set")"
    }
    return defaults.joined(separator: "  •  ")
}

func setDefault() throws {
    guard Bundle.main.bundleIdentifier == Config.routerID else {
        throw RouterError("Run --set-default from the built .app bundle, not a standalone executable.")
    }
    let registration = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
    guard registration == noErr else { throw RouterError("App registration failed (OSStatus \(registration)). Reinstall the app.") }
    var errors: [String] = []
    for scheme in ["http", "https"] {
        let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, Config.routerID as CFString)
        if status != noErr { errors.append("\(scheme): OSStatus \(status)") }
        let current = LSCopyDefaultHandlerForURLScheme(scheme as CFString)?.takeRetainedValue() as String?
        if current != Config.routerID { errors.append("\(scheme): macOS has not selected the router") }
    }
    if !errors.isEmpty {
        throw RouterError(errors.joined(separator: "\n") + "\nIn System Settings, search for 'Default web browser' and select URL to Profile Router.")
    }
}

func configurationReport(_ config: Config) throws -> String {
    let app = try applicationURL(for: config)
    var lines = ["Browser: \(app.lastPathComponent)", "Rules: \(config.rules.count)", "Config: \(configFile.path)"]
    if !config.usesChromiumArguments && config.rules.isEmpty && config.fallbackProfile == nil {
        return (["Configuration OK"] + lines + ["This browser opens URLs normally; profile selection requires Chromium."]).joined(separator: "\n")
    }
    let profiles = try loadProfiles(config)
    var errors: [String] = []
    for rule in config.rules {
        do { try requireProfileDirectory(resolveProfile(rule.profile, in: profiles), config: config, home: home) }
        catch { errors.append("Line \(rule.line): \(error.localizedDescription)") }
    }
    if let fallback = config.fallbackProfile {
        do { try requireProfileDirectory(resolveProfile(fallback, in: profiles), config: config, home: home) }
        catch { errors.append("@fallback: \(error.localizedDescription)") }
    }

    lines.append("\nAvailable profiles (name → directory):")
    lines += profiles.map { "\($0.name.debugDescription) → \($0.directory)" }
    lines += config.warnings.map { "Warning: \($0)" }
    if !errors.isEmpty { throw RouterError((lines + ["\nFix before routing:"] + errors).joined(separator: "\n")) }
    return (["Configuration OK"] + lines).joined(separator: "\n")
}

func stderr(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

let help = """
URL to Profile Router
  Router [URL ...]             Open HTTP(S) URLs or local file URLs
  Router --dry-run [URL ...]   Explain routing without opening or changing anything
  Router --check               Validate rules, browser and profile targets
  Router --list-profiles       List exact profile names and directory IDs
  Router --settings            Open the native setup and link-testing window
  Router --set-default         Request and verify HTTP and HTTPS default handlers
  Router --help                Show this help

Rules: ~/.config/url-router.conf (one domain and profile per line)
First match wins. example.com includes subdomains; *.example.com excludes the root.
Names may contain spaces; do not quote them. Rules are hosts, not URL path globs.
Local files always use the browser's last-used profile, even with @fallback.
"""

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let command: Command
    struct LaunchJob { let app: URL; let urls: [String]; let arguments: [String]; let chromium: Bool }
    var jobs: [LaunchJob] = []
    var nextJob = 0
    var launching = false
    var pending: Int { jobs.count - nextJob + (launching ? 1 : 0) }
    var finishedLaunching = false
    var receivedURLs = false
    var exitCode: Int32 = 0
    var failedURLs: [String] = []
    var failures: [String] = []
    var window: NSWindow?
    lazy var status = NSTextField(wrappingLabelWithString: "")
    lazy var details = NSTextView()
    lazy var testField = NSTextField()
    lazy var testResult = NSTextField(wrappingLabelWithString: "Paste a link to see its destination. Testing never opens it.")
    lazy var retryButton = NSButton(title: "Retry Unopened Links", target: nil, action: nil)
    lazy var copyButton = NSButton(title: "Copy Unopened Links", target: nil, action: nil)

    init(command: Command) { self.command = command }
    var isCLI: Bool { command.mode == .open }

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishedLaunching = true
        if command.mode == .open { route(command.urls) }
        else if command.mode == .settings { showSettings() }
        // Finder's ordinary launch is handled by applicationOpenUntitledFile.
        // A URL launch must never flash a settings window or steal focus.
        finishIfIdle()
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if command.mode == .application { showSettings() }
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    // AppKit delivers both URL Apple Events and document opens here. A second
    // custom kAEGetURL handler would create two competing delivery paths.
    func application(_ application: NSApplication, open urls: [URL]) {
        receivedURLs = true
        route(urls.map(\.absoluteString))
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if window?.isVisible == true { refresh() }
    }

    func route(_ inputs: [String]) {
        guard !inputs.isEmpty else { finishIfIdle(); return }
        do {
            let config = try loadConfig(create: !isCLI)
            let appURL = try applicationURL(for: config)
            var cachedProfiles: [BrowserProfile]?
            func profiles() throws -> [BrowserProfile] {
                if let cachedProfiles { return cachedProfiles }
                let loaded = try loadProfiles(config)
                cachedProfiles = loaded
                return loaded
            }
            // One handoff per consecutive destination, preserving URL order and
            // avoiding one new launcher process for every tab in a batch.
            var groups: [(directory: String?, urls: [String], arguments: [String])] = []
            for input in inputs {
                do {
                    let plan = try checkedRoute(input, config: config, profiles: profiles)
                    let arguments = try plan.arguments(config: config, home: home)
                    if let last = groups.indices.last, groups[last].directory == plan.directory {
                        groups[last].urls.append(input)
                        groups[last].arguments.append(plan.url.absoluteString)
                    } else { groups.append((plan.directory, [input], arguments)) }
                } catch { recordFailure([input], error) }
            }
            jobs += groups.map { LaunchJob(app: appURL, urls: $0.urls, arguments: $0.arguments, chromium: config.usesChromiumArguments) }
            launchNext()
        } catch { recordFailure(inputs, error) }
        finishIfIdle()
    }

    func launchNext() {
        guard !launching else { return }
        guard nextJob < jobs.count else {
            jobs.removeAll(); nextJob = 0
            finishIfIdle()
            return
        }
        let job = jobs[nextJob]
        nextJob += 1; launching = true
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        let completed: (NSRunningApplication?, Error?) -> Void = { _, error in
            DispatchQueue.main.async {
                if let error { self.recordFailure(job.urls, error) }
                self.launching = false
                self.launchNext()
            }
        }
        if job.chromium {
            options.createsNewApplicationInstance = true
            options.arguments = job.arguments
            NSWorkspace.shared.openApplication(at: job.app, configuration: options, completionHandler: completed)
        } else {
            // Non-Chromium apps receive native open-URL events, not ignored argv.
            // Every URL here has already passed validatedURL; do not drop one.
            do {
                let urls = try job.urls.map(validatedURL)
                NSWorkspace.shared.open(urls, withApplicationAt: job.app, configuration: options, completionHandler: completed)
            } catch { completed(nil, error) }
        }
    }

    func recordFailure(_ urls: [String], _ error: Error) {
        exitCode = 1
        if isCLI { stderr("Not opened: \(urls.map { $0.debugDescription }.joined(separator: ", "))\n\(error.localizedDescription)") }
        else {
            failedURLs += urls
            failures.append(error.localizedDescription)
            showSettings()
        }
    }

    func finishIfIdle() {
        guard finishedLaunching, pending == 0, window?.isVisible != true,
              isCLI || receivedURLs else { return }
        // Defer by one main-queue turn, not an arbitrary timeout. New URL events
        // may have added work before this block runs, so check again inside it.
        DispatchQueue.main.async {
            if self.pending == 0 && self.window?.isVisible != true { NSApp.terminate(nil) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // The window is still visible while this callback runs.
        DispatchQueue.main.async {
            if self.pending == 0 && self.window?.isVisible != true { NSApp.terminate(nil) }
        }
    }

    func makeButton(_ title: String, action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    @objc func showSettings() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.title = "URL to Profile Router"
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.setFrameAutosaveName("RouterSettings")
            panel.minSize = NSSize(width: 580, height: 500)
            let title = NSTextField(labelWithString: "Every link, the right profile.")
            title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
            status.setAccessibilityLabel("Default browser status")
            let actions = NSStackView(views: [makeButton("Edit Rules…", action: #selector(editRules)),
                makeButton("Make Default", action: #selector(makeDefault)), makeButton("Refresh", action: #selector(refresh))])
            actions.spacing = 8
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            details.isEditable = false
            details.isSelectable = true
            details.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            details.textContainerInset = NSSize(width: 8, height: 8)
            details.autoresizingMask = [.width]
            details.isVerticallyResizable = true
            details.isHorizontallyResizable = false
            details.textContainer?.widthTracksTextView = true
            details.setAccessibilityLabel("Configuration and available profiles")
            scroll.documentView = details
            testField.placeholderString = "https://example.com"
            testField.setAccessibilityLabel("URL to test without opening")
            testField.target = self
            testField.action = #selector(testURL)
            let test = NSStackView(views: [testField, makeButton("Test Link", action: #selector(testURL))])
            testField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            retryButton.target = self; retryButton.action = #selector(retryLinks)
            copyButton.target = self; copyButton.action = #selector(copyLinks)
            let recovery = NSStackView(views: [retryButton, copyButton])
            let stack = NSStackView(views: [title, status, actions, scroll, test, testResult, recovery])
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            guard let content = panel.contentView else { return }
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
                status.widthAnchor.constraint(equalTo: stack.widthAnchor),
                test.widthAnchor.constraint(equalTo: stack.widthAnchor),
                testResult.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
            window = panel
            installMenu()
            panel.center()
        }
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit URL to Profile Router", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(); editItem.title = "Edit"
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @objc func refresh() {
        status.stringValue = defaultStatus()
        var report: String
        do { report = try configurationReport(loadConfig(create: true)) }
        catch { report = error.localizedDescription }
        if !failedURLs.isEmpty {
            report = "\(failedURLs.count) link(s) were NOT opened. Fix the issue below, then Retry.\n" + failures.joined(separator: "\n") + "\n\n" + report
        }
        details.string = report
        retryButton.isHidden = failedURLs.isEmpty
        copyButton.isHidden = failedURLs.isEmpty
    }

    @objc func testURL() {
        do {
            let config = try loadConfig()
            _ = try applicationURL(for: config)
            let plan = try checkedRoute(testField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                        config: config, profiles: { try loadProfiles(config) })
            testResult.stringValue = plan.explanation
        } catch { testResult.stringValue = error.localizedDescription }
    }

    @objc func editRules() {
        do {
            // Opening TextEdit explicitly avoids recursive routing if the user
            // has associated .conf files with this app or a browser.
            _ = try loadConfig(create: true)
        } catch {
            if !FileManager.default.fileExists(atPath: configFile.path) { testResult.stringValue = error.localizedDescription; return }
        }
        guard let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            NSWorkspace.shared.activateFileViewerSelecting([configFile]); return
        }
        NSWorkspace.shared.open([configFile], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { DispatchQueue.main.async { self.testResult.stringValue = "Cannot open rules: \(error.localizedDescription)" } }
        }
    }

    @objc func makeDefault() {
        do { try setDefault(); testResult.stringValue = "Both HTTP and HTTPS now use this router." }
        catch { testResult.stringValue = error.localizedDescription }
        refresh()
    }

    @objc func retryLinks() {
        let links = failedURLs
        failedURLs = []; failures = []
        route(links)
        refresh()
    }

    @objc func copyLinks() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(failedURLs.joined(separator: "\n"), forType: .string)
        testResult.stringValue = "Unopened links copied."
    }
}

let command: Command
do { command = try Command(Array(CommandLine.arguments.dropFirst())) }
catch { stderr(error.localizedDescription); exit(1) }

do {
    switch command.mode {
    case .help: print(help); exit(0)
    case .check: print(try configurationReport(loadConfig())); exit(0)
    case .profiles:
        let config = try loadConfig()
        for profile in try loadProfiles(config) { print("\(profile.name.debugDescription) → \(profile.directory)") }
        exit(0)
    case .setDefault: try setDefault(); print(defaultStatus()); exit(0)
    case .dryRun:
        let config = try loadConfig()
        _ = try applicationURL(for: config)
        var profiles: [BrowserProfile]?
        var failed = false
        let inputs = command.urls.isEmpty ? ["https://github.com/foo", "https://www.youtube.com/watch?v=x", "https://youtu.be/x", "https://example.com"] : command.urls
        for input in inputs {
            do {
                let plan = try checkedRoute(input, config: config) {
                    if let profiles { return profiles }
                    let loaded = try loadProfiles(config); profiles = loaded; return loaded
                }
                print("\(input) → \(config.browser)\n\(plan.explanation)")
            } catch { stderr("\(input): \(error.localizedDescription)"); failed = true }
        }
        exit(failed ? 1 : 0)
    default: break
    }
} catch { stderr(error.localizedDescription); exit(1) }

let app = NSApplication.shared
let delegate = Delegate(command: command)
app.delegate = delegate
app.run()
exit(delegate.exitCode)
