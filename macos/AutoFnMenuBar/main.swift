import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private let pollInterval: TimeInterval = 0.06
private let inputRoles: Set<String> = [
    "AXTextField",
    "AXTextArea",
    "AXSearchField",
    "AXComboBox",
    "AXDocument",
]

struct Hotkey {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let spec: String
    let holdMode: Bool
}

func keyCodeForToken(_ token: String) -> CGKeyCode? {
    let t = token.lowercased()
    let map: [String: CGKeyCode] = [
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38,
        "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17,
        "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        "space": 49, "tab": 48, "enter": 36, "return": 36, "esc": 53, "escape": 53,
    ]
    return map[t]
}

func parseHotkey(_ spec: String) -> Hotkey? {
    if spec.lowercased() == "fn" {
        return Hotkey(keyCode: 63, flags: [], spec: spec, holdMode: true)
    }
    let parts = spec.lowercased().split(separator: "+").map { String($0) }.filter { !$0.isEmpty }
    guard let keyToken = parts.last, let keyCode = keyCodeForToken(keyToken) else { return nil }
    var flags: CGEventFlags = []
    for token in parts.dropLast() {
        switch token {
        case "cmd", "command":
            flags.insert(.maskCommand)
        case "ctrl", "control":
            flags.insert(.maskControl)
        case "alt", "option":
            flags.insert(.maskAlternate)
        case "shift":
            flags.insert(.maskShift)
        default:
            return nil
        }
    }
    return Hotkey(keyCode: keyCode, flags: flags, spec: spec, holdMode: false)
}

final class AutoFnController {
    private var timer: Timer?
    private(set) var enabled = true
    private var fnHeld = false
    private var lastInputSignature = ""
    private var falseStreak = 0
    private let releaseDebounceTicks = 4
    var triggerHotkey = Hotkey(keyCode: 18, flags: .maskCommand, spec: "cmd+1", holdMode: false)

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        setFnHeld(false)
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value {
            setFnHeld(false)
        }
    }

    private func tick() {
        guard enabled else {
            setFnHeld(false)
            return
        }
        let rawHold = shouldHoldFnForFocusedElement()
        let effectiveHold: Bool
        if rawHold {
            falseStreak = 0
            effectiveHold = true
        } else {
            falseStreak += 1
            effectiveHold = fnHeld && falseStreak < releaseDebounceTicks
        }
        setFnHeld(effectiveHold)
    }

    private func setFnHeld(_ target: Bool) {
        if triggerHotkey.holdMode {
            if fnHeld != target {
                postFn(pressed: target)
                fnHeld = target
            }
            return
        }

        if target {
            let signature = currentFocusedInputSignature()
            let shouldTrigger = (!fnHeld) || (signature != lastInputSignature)
            if shouldTrigger {
                sendHotkey(triggerHotkey)
                lastInputSignature = signature
                fnHeld = true
            }
            return
        }

        if fnHeld {
            fnHeld = false
            lastInputSignature = ""
        }
    }
}

func copyAttr(_ element: AXUIElement, _ attr: CFString) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, attr, &value)
    return (err, value)
}

func copyStringAttr(_ element: AXUIElement, _ attr: CFString) -> String? {
    let (err, value) = copyAttr(element, attr)
    guard err == .success, let v = value else { return nil }
    return v as? String
}

func copyBoolAttr(_ element: AXUIElement, _ attr: CFString) -> Bool? {
    let (err, value) = copyAttr(element, attr)
    guard err == .success, let v = value else { return nil }
    return (v as? Bool)
}

func copyElementAttr(_ element: AXUIElement, _ attr: CFString) -> AXUIElement? {
    let (err, value) = copyAttr(element, attr)
    guard err == .success, let v = value else { return nil }
    return (v as! AXUIElement)
}

func copyElementArrayAttr(_ element: AXUIElement, _ attr: CFString) -> [AXUIElement] {
    let (err, value) = copyAttr(element, attr)
    guard err == .success, let v = value else { return [] }
    if let arr = v as? [AXUIElement] {
        return arr
    }
    if let anyArr = v as? [Any] {
        return anyArr.map { $0 as! AXUIElement }
    }
    return []
}

func copyCGPointAttr(_ element: AXUIElement, _ attr: CFString) -> CGPoint? {
    let (err, value) = copyAttr(element, attr)
    guard err == .success, let v = value else { return nil }
    let axValue = v as! AXValue
    guard AXValueGetType(axValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
    return point
}

func copyCGSizeAttr(_ element: AXUIElement, _ attr: CFString) -> CGSize? {
    let (err, value) = copyAttr(element, attr)
    guard err == .success, let v = value else { return nil }
    let axValue = v as! AXValue
    guard AXValueGetType(axValue) == .cgSize else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
    return size
}

@inline(__always)
func isInputElement(_ element: AXUIElement) -> Bool {
    let role = copyStringAttr(element, kAXRoleAttribute as CFString) ?? ""
    if inputRoles.contains(role) {
        return true
    }
    if let editable = copyBoolAttr(element, "AXEditable" as CFString), editable {
        return true
    }
    return false
}

func hasInputAncestor(_ element: AXUIElement, maxDepth: Int = 8) -> Bool {
    var current: AXUIElement? = element
    for _ in 0..<maxDepth {
        guard let node = current else { return false }
        if isInputElement(node) {
            return true
        }
        current = copyElementAttr(node, kAXParentAttribute as CFString)
    }
    return false
}

func hasFocusedInputDescendant(_ element: AXUIElement, depth: Int = 5) -> Bool {
    if depth < 0 {
        return false
    }
    let focused = copyBoolAttr(element, kAXFocusedAttribute as CFString) ?? false
    if focused && isInputElement(element) {
        return true
    }
    for child in copyElementArrayAttr(element, kAXChildrenAttribute as CFString) {
        if hasFocusedInputDescendant(child, depth: depth - 1) {
            return true
        }
    }
    return false
}

func frontmostWindowAppPID() -> pid_t? {
    guard let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else {
        return nil
    }
    for win in rawList {
        let layer = (win[kCGWindowLayer as String] as? Int) ?? 0
        if layer != 0 { continue }
        guard let pidInt = win[kCGWindowOwnerPID as String] as? Int else { continue }
        return pid_t(pidInt)
    }
    return nil
}

func focusedElement() -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    let (errSystemFocused, systemFocused) = copyAttr(systemWide, kAXFocusedUIElementAttribute as CFString)
    if errSystemFocused == .success, let raw = systemFocused {
        return (raw as! AXUIElement)
    }

    let app: AXUIElement
    let (errApp, appRef) = copyAttr(systemWide, kAXFocusedApplicationAttribute as CFString)
    if errApp == .success, let rawApp = appRef {
        app = rawApp as! AXUIElement
    } else if let pid = frontmostWindowAppPID() {
        app = AXUIElementCreateApplication(pid)
    } else if let frontmost = NSWorkspace.shared.frontmostApplication {
        app = AXUIElementCreateApplication(frontmost.processIdentifier)
    } else {
        return nil
    }

    let (errAppFocused, appFocused) = copyAttr(app, kAXFocusedUIElementAttribute as CFString)
    if errAppFocused == .success, let raw = appFocused {
        return (raw as! AXUIElement)
    }

    let (errWindow, windowRef) = copyAttr(app, kAXFocusedWindowAttribute as CFString)
    if errWindow == .success, let rawWindow = windowRef {
        let window = rawWindow as! AXUIElement
        let (errWindowFocused, windowFocused) = copyAttr(window, kAXFocusedUIElementAttribute as CFString)
        if errWindowFocused == .success, let raw = windowFocused {
            return (raw as! AXUIElement)
        }
    }
    return nil
}

func shouldHoldFnForFocusedElement() -> Bool {
    guard let element = focusedElement() else { return false }
    if isInputElement(element) {
        return true
    }
    if hasInputAncestor(element) {
        return true
    }
    if hasFocusedInputDescendant(element) {
        return true
    }
    return false
}

func currentFocusedInputSignature() -> String {
    guard let element = focusedElement() else { return "" }
    var pid: pid_t = 0
    _ = AXUIElementGetPid(element, &pid)
    let role = copyStringAttr(element, kAXRoleAttribute as CFString) ?? "-"
    let subrole = copyStringAttr(element, kAXSubroleAttribute as CFString) ?? "-"
    let title = copyStringAttr(element, kAXTitleAttribute as CFString) ?? "-"
    let identifier = copyStringAttr(element, "AXIdentifier" as CFString) ?? "-"
    let pos = copyCGPointAttr(element, kAXPositionAttribute as CFString) ?? CGPoint(x: -1, y: -1)
    let size = copyCGSizeAttr(element, kAXSizeAttribute as CFString) ?? CGSize(width: -1, height: -1)
    let geo = "\(Int(pos.x)),\(Int(pos.y)),\(Int(size.width)),\(Int(size.height))"
    return "\(pid)|\(role)|\(subrole)|\(title)|\(identifier)|\(geo)"
}

func postFn(pressed: Bool) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 63, keyDown: pressed) else { return }
    event.type = .flagsChanged
    event.flags = pressed ? .maskSecondaryFn : []
    event.post(tap: .cghidEventTap)
}

func sendHotkey(_ hotkey: Hotkey) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: hotkey.keyCode, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: hotkey.keyCode, keyDown: false)
    else { return }
    keyDown.flags = hotkey.flags
    keyUp.flags = hotkey.flags
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
}

func openAccessibilitySettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
    }
}

final class AutoFnMenuBarApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = AutoFnController()
    private let enabledMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "e")
    private let launchAtLoginMenuItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "l")
    private let hotkeyMenuItem = NSMenuItem(title: "Trigger Hotkey", action: nil, keyEquivalent: "")
    private let accessMenuItem = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibility), keyEquivalent: "")
    private let launchAgentLabel = "com.lessismore.autofnmenubar.login"
    private let hotkeyDefaultsKey = "AutoFnMenuBar.TriggerHotkeySpec"
    private let hotkeyPresets = ["fn", "cmd+1", "ctrl+space", "cmd+space", "alt+space"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        loadHotkeyFromDefaults()
        controller.start()
        if !AXIsProcessTrusted() {
            promptAccessibilityPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            var configured = false
            if let customIconURL = Bundle.main.url(forResource: "MenuBarIconTemplate", withExtension: "pdf"),
               let customIcon = NSImage(contentsOf: customIconURL)
            {
                customIcon.isTemplate = true
                customIcon.size = NSSize(width: 18, height: 18)
                button.image = customIcon
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleProportionallyDown
                button.title = ""
                configured = true
            }

            if !configured {
                let symbolCandidates = ["text.cursor", "character.cursor.ibeam"]
                for symbolName in symbolCandidates {
                    if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AutoFn") {
                        image.isTemplate = true
                        button.image = image
                        button.imagePosition = .imageOnly
                        button.title = ""
                        configured = true
                        break
                    }
                }
            }

            if !configured {
                button.image = nil
                button.title = "⌘I"
            }
        }
        let menu = NSMenu()

        enabledMenuItem.target = self
        enabledMenuItem.state = .on
        menu.addItem(enabledMenuItem)

        launchAtLoginMenuItem.target = self
        launchAtLoginMenuItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchAtLoginMenuItem)

        hotkeyMenuItem.submenu = makeHotkeySubmenu()
        menu.addItem(hotkeyMenuItem)

        accessMenuItem.target = self
        menu.addItem(accessMenuItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func makeHotkeySubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Trigger Hotkey")
        for spec in hotkeyPresets {
            let item = NSMenuItem(title: spec, action: #selector(selectHotkeyPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = spec
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let custom = NSMenuItem(title: "Custom...", action: #selector(selectCustomHotkey), keyEquivalent: "")
        custom.target = self
        submenu.addItem(custom)
        refreshHotkeyMenuState()
        return submenu
    }

    private func currentHotkeySpec() -> String {
        controller.triggerHotkey.spec
    }

    private func loadHotkeyFromDefaults() {
        let stored = UserDefaults.standard.string(forKey: hotkeyDefaultsKey) ?? "cmd+1"
        if let parsed = parseHotkey(stored) {
            controller.triggerHotkey = parsed
        } else {
            controller.triggerHotkey = Hotkey(keyCode: 18, flags: .maskCommand, spec: "cmd+1", holdMode: false)
        }
    }

    private func setTriggerHotkey(_ spec: String) {
        guard let parsed = parseHotkey(spec) else { return }
        controller.triggerHotkey = parsed
        UserDefaults.standard.set(parsed.spec, forKey: hotkeyDefaultsKey)
        refreshHotkeyMenuState()
    }

    private func refreshHotkeyMenuState() {
        guard let submenu = hotkeyMenuItem.submenu else { return }
        let current = currentHotkeySpec().lowercased()
        for item in submenu.items {
            if let spec = item.representedObject as? String {
                item.state = (spec.lowercased() == current) ? .on : .off
            } else if item.title == "Custom..." {
                item.state = hotkeyPresets.contains(where: { $0.lowercased() == current }) ? .off : .on
            } else {
                item.state = .off
            }
        }
        hotkeyMenuItem.title = "Trigger Hotkey (\(controller.triggerHotkey.spec))"
    }

    private func launchAgentPlistPath() -> String {
        let home = NSHomeDirectory()
        return "\(home)/Library/LaunchAgents/\(launchAgentLabel).plist"
    }

    private func launchAgentPlistURL() -> URL {
        URL(fileURLWithPath: launchAgentPlistPath())
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPlistPath())
    }

    private func runLaunchctl(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("launchctl failed: \(error)")
        }
    }

    private func writeLaunchAgentPlist() throws {
        let plistURL = launchAgentPlistURL()
        let plistDir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: plistDir, withIntermediateDirectories: true)
        let bundlePath = Bundle.main.bundlePath
        let dict: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": ["/usr/bin/open", bundlePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": ["Aqua"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    private func enableLaunchAtLogin() {
        do {
            try writeLaunchAgentPlist()
            let uid = getuid()
            let domain = "gui/\(uid)"
            let plistPath = launchAgentPlistPath()
            runLaunchctl(["bootout", domain, plistPath])
            runLaunchctl(["bootstrap", domain, plistPath])
            launchAtLoginMenuItem.state = .on
        } catch {
            NSLog("enable launch-at-login failed: \(error)")
            launchAtLoginMenuItem.state = .off
        }
    }

    private func disableLaunchAtLogin() {
        let uid = getuid()
        let domain = "gui/\(uid)"
        let plistPath = launchAgentPlistPath()
        runLaunchctl(["bootout", domain, plistPath])
        try? FileManager.default.removeItem(atPath: plistPath)
        launchAtLoginMenuItem.state = .off
    }

    private func promptAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func toggleEnabled() {
        let next = !controller.enabled
        controller.setEnabled(next)
        enabledMenuItem.state = next ? .on : .off
    }

    @objc private func openAccessibility() {
        openAccessibilitySettings()
    }

    @objc private func toggleLaunchAtLogin() {
        if isLaunchAtLoginEnabled() {
            disableLaunchAtLogin()
        } else {
            enableLaunchAtLogin()
        }
    }

    @objc private func selectHotkeyPreset(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? String else { return }
        setTriggerHotkey(spec)
    }

    @objc private func selectCustomHotkey() {
        let alert = NSAlert()
        alert.messageText = "Set Trigger Hotkey"
        alert.informativeText = "Format: fn / cmd+1 / ctrl+space / alt+tab / shift+enter"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = currentHotkeySpec()
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let result = alert.runModal()
        guard result == .alertFirstButtonReturn else { return }
        let raw = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, parseHotkey(raw) != nil else {
            NSSound.beep()
            return
        }
        setTriggerHotkey(raw)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AutoFnMenuBarApp()
app.delegate = delegate
app.run()
