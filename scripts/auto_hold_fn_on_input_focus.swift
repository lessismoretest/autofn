#!/usr/bin/env swift

import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

let pollIntervalUsec: useconds_t = 60_000
let debugMode = CommandLine.arguments.contains("--debug")
let verboseMode = CommandLine.arguments.contains("--verbose")
let addressBarCountsAsInput = !CommandLine.arguments.contains("--no-address-bar-input")
let hotkeySpec = {
    let args = CommandLine.arguments
    guard let idx = args.firstIndex(of: "--hotkey"), idx + 1 < args.count else { return "cmd+1" }
    return args[idx + 1]
}()
let inputRoles: Set<String> = [
    "AXTextField",
    "AXTextArea",
    "AXSearchField",
    "AXComboBox",
    "AXDocument",
]
let accessibilityBoostAttributes: [CFString] = [
    "AXEnhancedUserInterface" as CFString,
    "AXManualAccessibility" as CFString,
]
let accessibilityBoostCooldown: TimeInterval = 2.0
var lastAccessibilityBoostByPID: [pid_t: TimeInterval] = [:]
let chromiumBrowserBundleIDs: Set<String> = [
    "com.google.Chrome",
    "org.chromium.Chromium",
    "com.brave.Browser",
    "com.brave.Browser.beta",
    "com.brave.Browser.nightly",
    "com.microsoft.edgemac",
    "company.thebrowser.dia",
]
let firefoxBrowserBundleIDs: Set<String> = [
    "org.mozilla.firefox",
    "org.mozilla.nightly",
    "org.mozilla.firefoxdeveloperedition",
    "app.zen-browser.zen",
]

var triggerArmed = false
var lastInputSignature = ""
var falseStreak = 0
let releaseDebounceTicks = 4
var shouldRun = true

struct Hotkey {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let spec: String
    let holdMode: Bool
}

struct FocusDetectionState {
    let shouldHold: Bool
    let reason: String
    let signature: String
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

let configuredHotkey = parseHotkey(hotkeySpec) ?? Hotkey(keyCode: 18, flags: .maskCommand, spec: "cmd+1", holdMode: false)

func axErrorName(_ err: AXError) -> String {
    switch err {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete: return "cannotComplete"
    case .attributeUnsupported: return "attributeUnsupported"
    case .actionUnsupported: return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented: return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled: return "apiDisabled"
    case .noValue: return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "notEnoughPrecision"
    @unknown default: return "unknown(\(err.rawValue))"
    }
}

func copyAttr(_ element: AXUIElement, _ attr: CFString) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, attr, &value)
    return (err, value)
}

func frontmostWindowApp() -> (pid_t, String)? {
    guard let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else {
        return nil
    }
    for win in rawList {
        let layer = (win[kCGWindowLayer as String] as? Int) ?? 0
        if layer != 0 {
            continue
        }
        guard let pidInt = win[kCGWindowOwnerPID as String] as? Int else {
            continue
        }
        let pid = pid_t(pidInt)
        let owner = (win[kCGWindowOwnerName as String] as? String) ?? "pid:\(pid)"
        return (pid, owner)
    }
    return nil
}

@inline(__always)
func copyStringAttr(_ element: AXUIElement, _ attr: CFString) -> String? {
    let (err, value) = copyAttr(element, attr)
    guard err == .success, let v = value else { return nil }
    return v as? String
}

@inline(__always)
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

func copyStringArrayAttr(_ element: AXUIElement, _ attr: CFString) -> [String] {
    let (err, value) = copyAttr(element, attr)
    guard err == .success, let v = value else { return [] }
    if let arr = v as? [String] {
        return arr
    }
    if let anyArr = v as? [Any] {
        return anyArr.compactMap { $0 as? String }
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

func elementPID(_ element: AXUIElement) -> pid_t? {
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return nil }
    return pid
}

func boostAppAccessibilityAttribute(_ appElement: AXUIElement, attribute: CFString) {
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(appElement, attribute, &settable) == .success, settable.boolValue else {
        return
    }
    if let enabled = copyBoolAttr(appElement, attribute), enabled {
        return
    }
    _ = AXUIElementSetAttributeValue(appElement, attribute, kCFBooleanTrue)
}

func maybeBoostAppAccessibility(for pid: pid_t) {
    guard pid > 0 else { return }
    let now = Date().timeIntervalSince1970
    if let last = lastAccessibilityBoostByPID[pid], now - last < accessibilityBoostCooldown {
        return
    }
    lastAccessibilityBoostByPID[pid] = now
    let appElement = AXUIElementCreateApplication(pid)
    for attribute in accessibilityBoostAttributes {
        boostAppAccessibilityAttribute(appElement, attribute: attribute)
    }
}

func elementBundleIdentifier(_ element: AXUIElement) -> String? {
    guard let pid = elementPID(element), pid > 0 else { return nil }
    return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
}

func isBrowserAddressBar(_ element: AXUIElement) -> Bool {
    guard let bundleID = elementBundleIdentifier(element) else { return false }

    if bundleID == "com.apple.Safari" || bundleID == "com.apple.SafariTechnologyPreview" {
        return copyStringAttr(element, "AXIdentifier" as CFString) == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
    }
    if bundleID == "company.thebrowser.Browser" {
        return copyStringAttr(element, "AXIdentifier" as CFString) == "commandBarTextField"
    }
    if bundleID == "com.vivaldi.Vivaldi" {
        let classes = Set(copyStringArrayAttr(element, "AXDOMClassList" as CFString))
        return classes.contains("UrlBar-UrlField") && classes.contains("vivaldi-addressfield")
    }
    if bundleID == "com.operasoftware.Opera" {
        return copyStringArrayAttr(element, "AXDOMClassList" as CFString).contains("AddressTextfieldView")
    }
    if chromiumBrowserBundleIDs.contains(bundleID) {
        return copyStringArrayAttr(element, "AXDOMClassList" as CFString).contains("OmniboxViewViews")
    }
    if firefoxBrowserBundleIDs.contains(bundleID) {
        return copyStringAttr(element, "AXDOMIdentifier" as CFString) == "urlbar-input"
    }
    return false
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

func focusedElement() -> (AXUIElement?, String) {
    let systemWide = AXUIElementCreateSystemWide()
    let (errSystemFocused, systemFocused) = copyAttr(systemWide, kAXFocusedUIElementAttribute as CFString)
    if errSystemFocused == .success, let raw = systemFocused {
        let element = raw as! AXUIElement
        if let pid = elementPID(element) {
            maybeBoostAppAccessibility(for: pid)
        }
        return (element, "system.focusedUIElement=success")
    }

    let app: AXUIElement
    var appPID: pid_t?
    var appReason = ""
    let (errApp, appRef) = copyAttr(systemWide, kAXFocusedApplicationAttribute as CFString)
    if errApp == .success, let rawApp = appRef {
        app = rawApp as! AXUIElement
        appPID = elementPID(app)
        appReason = "system.focusedApp=success"
    } else if let frontWin = frontmostWindowApp() {
        app = AXUIElementCreateApplication(frontWin.0)
        appPID = frontWin.0
        appReason = "system.focusedApp=\(axErrorName(errApp)); fallback.frontmostWindowApp=\(frontWin.1)(\(frontWin.0))"
    } else if let frontmost = NSWorkspace.shared.frontmostApplication {
        app = AXUIElementCreateApplication(frontmost.processIdentifier)
        appPID = frontmost.processIdentifier
        appReason = "system.focusedApp=\(axErrorName(errApp)); fallback.frontmostApp=\(frontmost.localizedName ?? "pid:\(frontmost.processIdentifier)")"
    } else {
        return (nil, "system.focusedUIElement=\(axErrorName(errSystemFocused)); system.focusedApp=\(axErrorName(errApp)); fallback.frontmostApp=unavailable")
    }
    if let pid = appPID {
        maybeBoostAppAccessibility(for: pid)
    }

    let (errAppFocused, appFocused) = copyAttr(app, kAXFocusedUIElementAttribute as CFString)
    if errAppFocused == .success, let raw = appFocused {
        let v = raw as! AXUIElement
        return (v, "system.focusedUIElement=\(axErrorName(errSystemFocused)); \(appReason); app.focusedUIElement=success")
    }

    let (errWindow, windowRef) = copyAttr(app, kAXFocusedWindowAttribute as CFString)
    if errWindow == .success, let rawWindow = windowRef {
        let window = rawWindow as! AXUIElement
        let (errWindowFocused, windowFocused) = copyAttr(window, kAXFocusedUIElementAttribute as CFString)
        if errWindowFocused == .success, let raw = windowFocused {
            let v = raw as! AXUIElement
            return (v, "system.focusedUIElement=\(axErrorName(errSystemFocused)); \(appReason); app.focusedUIElement=\(axErrorName(errAppFocused)); window.focusedUIElement=success")
        }
        return (nil, "system.focusedUIElement=\(axErrorName(errSystemFocused)); \(appReason); app.focusedUIElement=\(axErrorName(errAppFocused)); window.focusedUIElement=\(axErrorName(errWindowFocused))")
    }

    return (nil, "system.focusedUIElement=\(axErrorName(errSystemFocused)); \(appReason); app.focusedUIElement=\(axErrorName(errAppFocused)); app.focusedWindow=\(axErrorName(errWindow))")
}

func focusedAppNameAndPID() -> (String, pid_t)? {
    if let frontWin = frontmostWindowApp() {
        return (frontWin.1, frontWin.0)
    }
    let systemWide = AXUIElementCreateSystemWide()
    let (err, value) = copyAttr(systemWide, kAXFocusedApplicationAttribute as CFString)
    if err == .success, let appRef = value {
        let app = appRef as! AXUIElement
        var pid: pid_t = 0
        if AXUIElementGetPid(app, &pid) == .success {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid:\(pid)"
            return (name, pid)
        }
    }
    if let frontmost = NSWorkspace.shared.frontmostApplication {
        return (frontmost.localizedName ?? "pid:\(frontmost.processIdentifier)", frontmost.processIdentifier)
    }
    return nil
}

func focusedElementSignature(_ element: AXUIElement) -> String {
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

func detectFocusedInputState() -> FocusDetectionState {
    let (focused, sourceReason) = focusedElement()
    guard let element = focused else {
        return FocusDetectionState(shouldHold: false, reason: "no_focused_element \(sourceReason)", signature: "")
    }
    let role = copyStringAttr(element, kAXRoleAttribute as CFString) ?? "unknown-role"
    let subrole = copyStringAttr(element, kAXSubroleAttribute as CFString) ?? "-"
    let signature = focusedElementSignature(element)
    if isBrowserAddressBar(element) {
        return FocusDetectionState(
            shouldHold: addressBarCountsAsInput,
            reason: "\(sourceReason) via=browser_address role=\(role) subrole=\(subrole)",
            signature: signature
        )
    }
    if isInputElement(element) {
        return FocusDetectionState(
            shouldHold: true,
            reason: "\(sourceReason) role=\(role) subrole=\(subrole)",
            signature: signature
        )
    }
    if hasInputAncestor(element) {
        return FocusDetectionState(
            shouldHold: true,
            reason: "\(sourceReason) via=ancestor role=\(role) subrole=\(subrole)",
            signature: signature
        )
    }
    if hasFocusedInputDescendant(element) {
        return FocusDetectionState(
            shouldHold: true,
            reason: "\(sourceReason) via=descendant role=\(role) subrole=\(subrole)",
            signature: signature
        )
    }
    return FocusDetectionState(
        shouldHold: false,
        reason: "\(sourceReason) role=\(role) subrole=\(subrole)",
        signature: signature
    )
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

func setFnHeld(_ target: Bool, signature: String) {
    if configuredHotkey.holdMode {
        if triggerArmed != target {
            postFn(pressed: target)
            triggerArmed = target
            let msg = target ? "FN DOWN" : "FN UP"
            print("[auto-fn] \(msg)")
            fflush(stdout)
        }
        return
    }

    if target {
        let shouldTrigger = (!triggerArmed) || (signature != lastInputSignature)
        if shouldTrigger {
            sendHotkey(configuredHotkey)
            lastInputSignature = signature
            triggerArmed = true
            print("[auto-fn] TRIGGER \(configuredHotkey.spec)")
            fflush(stdout)
        }
        return
    }

    if triggerArmed {
        triggerArmed = false
        lastInputSignature = ""
        print("[auto-fn] IDLE")
        fflush(stdout)
    }
}

func releaseForExit() {
    if configuredHotkey.holdMode && triggerArmed {
        postFn(pressed: false)
    }
    triggerArmed = false
    lastInputSignature = ""
}

func releaseAndExit(_ code: Int32) -> Never {
    releaseForExit()
    exit(code)
}

print("[auto-fn] started")
print("[auto-fn] grant Accessibility permission to your terminal app, then re-run if needed.")
print("[auto-fn] AXIsProcessTrusted=\(AXIsProcessTrusted())")
print("[auto-fn] hotkey=\(configuredHotkey.spec)")
print("[auto-fn] addressBarCountsAsInput=\(addressBarCountsAsInput)")
if debugMode {
    print("[auto-fn] debug=on")
}
if verboseMode {
    print("[auto-fn] verbose=on")
}
fflush(stdout)

signal(SIGINT) { _ in
    shouldRun = false
}
signal(SIGTERM) { _ in
    shouldRun = false
}

var lastDebugSignature = ""
var lastVerboseTs = Date().timeIntervalSince1970
while shouldRun {
    let detection = detectFocusedInputState()
    let rawHold = detection.shouldHold
    let reason = detection.reason
    let targetHold: Bool
    if rawHold {
        falseStreak = 0
        targetHold = true
    } else {
        falseStreak += 1
        targetHold = triggerArmed && falseStreak < releaseDebounceTicks
    }
    let appInfo = focusedAppNameAndPID().map { "\($0.0)(\($0.1))" } ?? "unknown-app"
    let signature = "hold=\(targetHold) raw=\(rawHold) app=\(appInfo) \(reason)"
    if debugMode {
        if signature != lastDebugSignature {
            print("[auto-fn][debug] \(signature)")
            fflush(stdout)
            lastDebugSignature = signature
        }
    }
    if verboseMode {
        let now = Date().timeIntervalSince1970
        if now - lastVerboseTs >= 1.0 {
            print("[auto-fn][verbose] \(signature)")
            fflush(stdout)
            lastVerboseTs = now
        }
    }
    setFnHeld(targetHold, signature: detection.signature)
    usleep(pollIntervalUsec)
}

releaseAndExit(0)
