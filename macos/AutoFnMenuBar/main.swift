import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private let pollInterval: TimeInterval = 0.25
private let inputRoles: Set<String> = [
    "AXTextField",
    "AXTextArea",
    "AXSearchField",
    "AXComboBox",
    "AXDocument",
]
private let accessibilityBoostAttributes: [CFString] = [
    "AXEnhancedUserInterface" as CFString,
    "AXManualAccessibility" as CFString,
]
private let accessibilityBoostCooldown: TimeInterval = 2.0
private var lastAccessibilityBoostByPID: [pid_t: TimeInterval] = [:]
private let chromiumBrowserBundleIDs: Set<String> = [
    "com.google.Chrome",
    "org.chromium.Chromium",
    "com.brave.Browser",
    "com.brave.Browser.beta",
    "com.brave.Browser.nightly",
    "com.microsoft.edgemac",
    "company.thebrowser.dia",
]
private let firefoxBrowserBundleIDs: Set<String> = [
    "org.mozilla.firefox",
    "org.mozilla.nightly",
    "org.mozilla.firefoxdeveloperedition",
    "app.zen-browser.zen",
]

struct FocusDetectionState {
    let shouldHold: Bool
    let signature: String
    let focusRect: CGRect?
}

struct Hotkey {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let spec: String
    let holdMode: Bool
}

enum TriggerMode: String {
    case focus
    case longPress

    var label: String {
        switch self {
        case .focus:
            return "Focus/Blur"
        case .longPress:
            return "Long Press In Input"
        }
    }
}

final class FocusAXObserverManager {
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    var onEvent: (() -> Void)?

    func start() {
        rebindToFrontmostApp()
    }

    func stop() {
        teardown()
    }

    func rebindToFrontmostApp() {
        if let app = NSWorkspace.shared.frontmostApplication {
            rebind(pid: app.processIdentifier)
        } else {
            teardown()
        }
    }

    func rebind(pid: pid_t) {
        guard pid > 0 else {
            teardown()
            return
        }
        if observedPID == pid, observer != nil {
            return
        }

        teardown()

        var newObserver: AXObserver?
        let err = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let manager = Unmanaged<FocusAXObserverManager>.fromOpaque(refcon).takeUnretainedValue()
            manager.onEvent?()
        }, &newObserver)
        guard err == .success, let axObserver = newObserver else {
            observedPID = 0
            observer = nil
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let notifications: [CFString] = [
            kAXFocusedUIElementChangedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString,
            kAXWindowCreatedNotification as CFString,
        ]
        for notification in notifications {
            _ = AXObserverAddNotification(axObserver, appElement, notification, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        observer = axObserver
        observedPID = pid
    }

    private func teardown() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = 0
    }

    deinit {
        teardown()
    }
}

final class MousePressMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    var onLeftMouseDown: (() -> Void)?
    var onLeftMouseUp: (() -> Void)?

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event.type)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event.type)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func handle(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            onLeftMouseDown?()
        case .leftMouseUp:
            onLeftMouseUp?()
        default:
            break
        }
    }
}

final class TestPromptOverlay {
    private let panel: NSPanel
    private let label: NSTextField
    private var hideWorkItem: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.88)
        panel.level = .statusBar
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        label = NSTextField(labelWithString: "")
        label.textColor = .white
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.wantsLayer = true
        content.layer?.cornerRadius = 8
        content.layer?.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -7),
        ])
        panel.contentView = content
    }

    func show(_ message: String, near anchorRect: CGRect?) {
        let textWidth = (message as NSString).size(withAttributes: [.font: label.font as Any]).width
        let width = min(max(textWidth + 24, 180), 360)
        let height: CGFloat = 34

        let anchor = anchorRect ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        let x = anchor.maxX + 10
        let y = anchor.maxY + 10
        var frame = NSRect(x: x, y: y, width: width, height: height)

        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if frame.maxX > visible.maxX { frame.origin.x = max(visible.maxX - frame.width - 8, visible.minX + 8) }
            if frame.maxY > visible.maxY { frame.origin.y = max(anchor.minY - frame.height - 10, visible.minY + 8) }
            if frame.minX < visible.minX { frame.origin.x = visible.minX + 8 }
            if frame.minY < visible.minY { frame.origin.y = visible.minY + 8 }
        }

        label.stringValue = message
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }
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
    if spec.lowercased() == "test" {
        return Hotkey(keyCode: 0, flags: [], spec: "test", holdMode: false)
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
    private var lastInputRect: CGRect?
    private var longPressArmed = false
    private var longPressActive = false
    private var pendingLongPressWorkItem: DispatchWorkItem?
    private let longPressThreshold: TimeInterval = 0.30
    private var voiceAutoSubmitTracking = false
    private var voiceAutoSubmitPending = false
    private var voiceAutoSubmitBaselineText = ""
    private var voiceAutoSubmitSignature = ""
    private var voiceAutoSubmitDeadline: TimeInterval = 0
    private let voiceAutoSubmitTimeout: TimeInterval = 0
    private var voiceAutoSubmitHasObservedChange = false
    private var voiceAutoSubmitLastObservedText = ""
    private var voiceAutoSubmitLastChangeAt: TimeInterval = 0
    private let voiceAutoSubmitStabilityWindow: TimeInterval = 1.0
    var triggerHotkey = Hotkey(keyCode: 18, flags: .maskCommand, spec: "cmd+1", holdMode: false)
    var triggerMode: TriggerMode = .focus
    var addressBarCountsAsInput = true
    var autoPressEnterAfterVoiceFill = false
    var onTestPrompt: ((String, CGRect?) -> Void)?

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancelPendingLongPress()
        longPressActive = false
        clearVoiceAutoSubmitState()
        setFnHeld(false)
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value {
            cancelPendingLongPress()
            longPressActive = false
            clearVoiceAutoSubmitState()
            setFnHeld(false)
        }
    }

    func setTriggerMode(_ mode: TriggerMode) {
        guard triggerMode != mode else { return }
        triggerMode = mode
        cancelPendingLongPress()
        longPressArmed = false
        longPressActive = false
        falseStreak = 0
        clearVoiceAutoSubmitState()
        setFnHeld(false)
    }

    func handleLeftMouseDown() {
        guard enabled, triggerMode == .longPress else { return }
        let focusState = detectFocusedInputState()
        guard focusState.shouldHold else {
            cancelPendingLongPress()
            return
        }
        cancelPendingLongPress()
        longPressArmed = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.enabled, self.triggerMode == .longPress, self.longPressArmed else { return }
            self.longPressActive = true
            self.setFnHeld(true, signature: focusState.signature, focusRect: focusState.focusRect)
        }
        pendingLongPressWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressThreshold, execute: work)
    }

    func handleLeftMouseUp() {
        guard triggerMode == .longPress else { return }
        cancelPendingLongPress()
        if longPressActive {
            longPressActive = false
            setFnHeld(false)
        }
    }

    private func cancelPendingLongPress() {
        longPressArmed = false
        pendingLongPressWorkItem?.cancel()
        pendingLongPressWorkItem = nil
    }

    func evaluateNow() {
        tick()
    }

    private func tick() {
        guard enabled else {
            setFnHeld(false)
            return
        }
        processVoiceAutoSubmitIfNeeded()
        guard triggerMode == .focus else { return }
        let focusState = detectFocusedInputState()
        let rawHold = focusState.shouldHold
        let effectiveHold: Bool
        if rawHold {
            falseStreak = 0
            effectiveHold = true
        } else {
            falseStreak += 1
            effectiveHold = fnHeld && falseStreak < releaseDebounceTicks
        }
        setFnHeld(effectiveHold, signature: focusState.signature, focusRect: focusState.focusRect)
    }

    private func setFnHeld(_ target: Bool, signature: String = "", focusRect: CGRect? = nil) {
        if triggerHotkey.holdMode {
            if fnHeld != target {
                handleHoldModeTransition(nextHeld: target)
                postFn(pressed: target)
                fnHeld = target
            }
            return
        }

        if target {
            let shouldTrigger = (!fnHeld) || (signature != lastInputSignature)
            if shouldTrigger {
                if triggerHotkey.spec.lowercased() == "test" {
                    let anchor = focusRect ?? lastInputRect
                    onTestPrompt?("测试模式：输入框已聚焦（未触发快捷键）", anchor)
                } else {
                    sendHotkey(triggerHotkey)
                }
                if let focusRect {
                    lastInputRect = focusRect
                }
                lastInputSignature = signature
                fnHeld = true
            }
            return
        }

        if fnHeld {
            if triggerHotkey.spec.lowercased() == "test" {
                onTestPrompt?("测试模式：输入框已失焦（未触发快捷键）", lastInputRect)
            }
            fnHeld = false
            lastInputSignature = ""
            lastInputRect = nil
        }
    }

    private func handleHoldModeTransition(nextHeld: Bool) {
        guard autoPressEnterAfterVoiceFill else {
            clearVoiceAutoSubmitState()
            return
        }
        if nextHeld {
            guard let element = focusedElement() else {
                clearVoiceAutoSubmitState()
                return
            }
            voiceAutoSubmitBaselineText = readInputValueText(element) ?? ""
            voiceAutoSubmitSignature = focusedElementSignature(element)
            voiceAutoSubmitTracking = true
            voiceAutoSubmitPending = false
            voiceAutoSubmitDeadline = 0
            voiceAutoSubmitHasObservedChange = false
            voiceAutoSubmitLastObservedText = voiceAutoSubmitBaselineText
            voiceAutoSubmitLastChangeAt = 0
            return
        }
        if voiceAutoSubmitTracking {
            voiceAutoSubmitPending = true
            if voiceAutoSubmitTimeout > 0 {
                voiceAutoSubmitDeadline = Date().timeIntervalSince1970 + voiceAutoSubmitTimeout
            } else {
                voiceAutoSubmitDeadline = 0
            }
            voiceAutoSubmitLastObservedText = voiceAutoSubmitBaselineText
            voiceAutoSubmitLastChangeAt = Date().timeIntervalSince1970
        } else {
            clearVoiceAutoSubmitState()
        }
    }

    private func processVoiceAutoSubmitIfNeeded() {
        guard autoPressEnterAfterVoiceFill else {
            clearVoiceAutoSubmitState()
            return
        }
        guard voiceAutoSubmitPending else { return }
        if voiceAutoSubmitDeadline > 0, Date().timeIntervalSince1970 > voiceAutoSubmitDeadline {
            clearVoiceAutoSubmitState()
            return
        }
        guard let element = focusedElement() else { return }
        if focusedElementSignature(element) != voiceAutoSubmitSignature {
            clearVoiceAutoSubmitState()
            return
        }
        guard let currentText = readInputValueText(element) else { return }
        let now = Date().timeIntervalSince1970
        if currentText != voiceAutoSubmitLastObservedText {
            voiceAutoSubmitLastObservedText = currentText
            voiceAutoSubmitLastChangeAt = now
        }
        if !voiceAutoSubmitHasObservedChange {
            if currentText == voiceAutoSubmitBaselineText {
                return
            }
            voiceAutoSubmitHasObservedChange = true
            voiceAutoSubmitLastChangeAt = now
            return
        }
        guard !currentText.isEmpty else { return }
        if now - voiceAutoSubmitLastChangeAt < voiceAutoSubmitStabilityWindow {
            return
        }
        sendEnterKey()
        clearVoiceAutoSubmitState()
    }

    private func clearVoiceAutoSubmitState() {
        voiceAutoSubmitTracking = false
        voiceAutoSubmitPending = false
        voiceAutoSubmitBaselineText = ""
        voiceAutoSubmitSignature = ""
        voiceAutoSubmitDeadline = 0
        voiceAutoSubmitHasObservedChange = false
        voiceAutoSubmitLastObservedText = ""
        voiceAutoSubmitLastChangeAt = 0
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

func convertAXRectToAppKit(_ rect: CGRect) -> CGRect {
    for screen in NSScreen.screens {
        let convertedY = screen.frame.maxY - rect.origin.y - rect.height
        let converted = CGRect(x: rect.origin.x, y: convertedY, width: rect.width, height: rect.height)
        if screen.frame.intersects(converted) {
            return converted
        }
    }
    if let main = NSScreen.main {
        return CGRect(
            x: rect.origin.x,
            y: main.frame.maxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
    return rect
}

func focusedElementRect(_ element: AXUIElement) -> CGRect? {
    guard let pos = copyCGPointAttr(element, kAXPositionAttribute as CFString),
          let size = copyCGSizeAttr(element, kAXSizeAttribute as CFString)
    else { return nil }
    return convertAXRectToAppKit(CGRect(origin: pos, size: size))
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
        let element = raw as! AXUIElement
        if let pid = elementPID(element) {
            maybeBoostAppAccessibility(for: pid)
        }
        return element
    }

    let app: AXUIElement
    var appPID: pid_t?
    let (errApp, appRef) = copyAttr(systemWide, kAXFocusedApplicationAttribute as CFString)
    if errApp == .success, let rawApp = appRef {
        app = rawApp as! AXUIElement
        appPID = elementPID(app)
    } else if let pid = frontmostWindowAppPID() {
        app = AXUIElementCreateApplication(pid)
        appPID = pid
    } else if let frontmost = NSWorkspace.shared.frontmostApplication {
        app = AXUIElementCreateApplication(frontmost.processIdentifier)
        appPID = frontmost.processIdentifier
    } else {
        return nil
    }
    if let pid = appPID {
        maybeBoostAppAccessibility(for: pid)
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

func detectFocusedInputState() -> FocusDetectionState {
    guard let element = focusedElement() else {
        return FocusDetectionState(shouldHold: false, signature: "", focusRect: nil)
    }
    let signature = focusedElementSignature(element)
    let focusRect = focusedElementRect(element)
    if isBrowserAddressBar(element) {
        if let app = NSApp.delegate as? AutoFnMenuBarApp {
            return FocusDetectionState(
                shouldHold: app.addressBarCountsAsInputEnabled(),
                signature: signature,
                focusRect: focusRect
            )
        }
        return FocusDetectionState(shouldHold: false, signature: signature, focusRect: focusRect)
    }
    if isInputElement(element) {
        return FocusDetectionState(shouldHold: true, signature: signature, focusRect: focusRect)
    }
    if hasInputAncestor(element) {
        return FocusDetectionState(shouldHold: true, signature: signature, focusRect: focusRect)
    }
    if hasFocusedInputDescendant(element) {
        return FocusDetectionState(shouldHold: true, signature: signature, focusRect: focusRect)
    }
    return FocusDetectionState(shouldHold: false, signature: signature, focusRect: focusRect)
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

func sendEnterKey() {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true),
          let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
    else { return }
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
}

func readInputValueText(_ element: AXUIElement) -> String? {
    let (err, value) = copyAttr(element, kAXValueAttribute as CFString)
    guard err == .success, let raw = value else { return nil }
    if let text = raw as? String {
        return text
    }
    if let attributed = raw as? NSAttributedString {
        return attributed.string
    }
    return nil
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
    private let addressBarInputMenuItem = NSMenuItem(title: "Address Bar Counts As Input", action: #selector(toggleAddressBarCountsAsInput), keyEquivalent: "")
    private let autoEnterAfterVoiceMenuItem = NSMenuItem(title: "Auto Press Enter After Voice Fill (Experimental)", action: #selector(toggleAutoEnterAfterVoiceFill), keyEquivalent: "")
    private let triggerModeMenuItem = NSMenuItem(title: "Trigger Mode", action: nil, keyEquivalent: "")
    private let hotkeyMenuItem = NSMenuItem(title: "Trigger Hotkey", action: nil, keyEquivalent: "")
    private let accessMenuItem = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibility), keyEquivalent: "")
    private let launchAgentLabel = "com.lessismore.autofnmenubar.login"
    private let hotkeyDefaultsKey = "AutoFnMenuBar.TriggerHotkeySpec"
    private let addressBarInputDefaultsKey = "AutoFnMenuBar.AddressBarCountsAsInput"
    private let autoEnterAfterVoiceDefaultsKey = "AutoFnMenuBar.AutoPressEnterAfterVoiceFill"
    private let triggerModeDefaultsKey = "AutoFnMenuBar.TriggerMode"
    private let hotkeyPresets = ["test", "fn", "cmd+1", "ctrl+space", "cmd+space", "alt+space"]
    private let focusObserverManager = FocusAXObserverManager()
    private let mousePressMonitor = MousePressMonitor()
    private let testPromptOverlay = TestPromptOverlay()
    private var appActivateObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        loadHotkeyFromDefaults()
        loadAddressBarInputFromDefaults()
        loadAutoEnterAfterVoiceFillFromDefaults()
        loadTriggerModeFromDefaults()
        controller.onTestPrompt = { [weak self] message, rect in
            self?.showTestPrompt(message, near: rect)
        }
        focusObserverManager.onEvent = { [weak self] in
            self?.controller.evaluateNow()
        }
        focusObserverManager.start()
        mousePressMonitor.onLeftMouseDown = { [weak self] in
            self?.controller.handleLeftMouseDown()
        }
        mousePressMonitor.onLeftMouseUp = { [weak self] in
            self?.controller.handleLeftMouseUp()
        }
        mousePressMonitor.start()
        appActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.focusObserverManager.rebind(pid: app.processIdentifier)
            } else {
                self?.focusObserverManager.rebindToFrontmostApp()
            }
            self?.controller.evaluateNow()
        }
        controller.start()
        if !AXIsProcessTrusted() {
            promptAccessibilityPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let appActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivateObserver)
            self.appActivateObserver = nil
        }
        mousePressMonitor.stop()
        focusObserverManager.stop()
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

        addressBarInputMenuItem.target = self
        addressBarInputMenuItem.state = controller.addressBarCountsAsInput ? .on : .off
        menu.addItem(addressBarInputMenuItem)

        autoEnterAfterVoiceMenuItem.target = self
        autoEnterAfterVoiceMenuItem.state = controller.autoPressEnterAfterVoiceFill ? .on : .off
        menu.addItem(autoEnterAfterVoiceMenuItem)

        triggerModeMenuItem.submenu = makeTriggerModeSubmenu()
        menu.addItem(triggerModeMenuItem)

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

    private func makeTriggerModeSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Trigger Mode")
        for mode in [TriggerMode.focus, TriggerMode.longPress] {
            let item = NSMenuItem(title: mode.label, action: #selector(selectTriggerMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            submenu.addItem(item)
        }
        refreshTriggerModeMenuState()
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

    private func loadAddressBarInputFromDefaults() {
        if UserDefaults.standard.object(forKey: addressBarInputDefaultsKey) == nil {
            controller.addressBarCountsAsInput = true
        } else {
            controller.addressBarCountsAsInput = UserDefaults.standard.bool(forKey: addressBarInputDefaultsKey)
        }
        addressBarInputMenuItem.state = controller.addressBarCountsAsInput ? .on : .off
    }

    private func loadAutoEnterAfterVoiceFillFromDefaults() {
        controller.autoPressEnterAfterVoiceFill = UserDefaults.standard.bool(forKey: autoEnterAfterVoiceDefaultsKey)
        autoEnterAfterVoiceMenuItem.state = controller.autoPressEnterAfterVoiceFill ? .on : .off
    }

    private func loadTriggerModeFromDefaults() {
        let stored = UserDefaults.standard.string(forKey: triggerModeDefaultsKey) ?? TriggerMode.focus.rawValue
        let mode = TriggerMode(rawValue: stored) ?? .focus
        controller.setTriggerMode(mode)
        refreshTriggerModeMenuState()
    }

    func addressBarCountsAsInputEnabled() -> Bool {
        controller.addressBarCountsAsInput
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

    private func refreshTriggerModeMenuState() {
        guard let submenu = triggerModeMenuItem.submenu else { return }
        for item in submenu.items {
            guard let raw = item.representedObject as? String, let mode = TriggerMode(rawValue: raw) else {
                item.state = .off
                continue
            }
            item.state = (mode == controller.triggerMode) ? .on : .off
        }
        triggerModeMenuItem.title = "Trigger Mode (\(controller.triggerMode.label))"
    }

    private func showTestPrompt(_ message: String, near rect: CGRect?) {
        testPromptOverlay.show(message, near: rect)
        NSLog("[AutoFn][test] \(message)")
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

    @objc private func toggleAddressBarCountsAsInput() {
        controller.addressBarCountsAsInput.toggle()
        UserDefaults.standard.set(controller.addressBarCountsAsInput, forKey: addressBarInputDefaultsKey)
        addressBarInputMenuItem.state = controller.addressBarCountsAsInput ? .on : .off
    }

    @objc private func toggleAutoEnterAfterVoiceFill() {
        controller.autoPressEnterAfterVoiceFill.toggle()
        UserDefaults.standard.set(controller.autoPressEnterAfterVoiceFill, forKey: autoEnterAfterVoiceDefaultsKey)
        autoEnterAfterVoiceMenuItem.state = controller.autoPressEnterAfterVoiceFill ? .on : .off
    }

    @objc private func selectHotkeyPreset(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? String else { return }
        setTriggerHotkey(spec)
    }

    @objc private func selectTriggerMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = TriggerMode(rawValue: raw) else { return }
        controller.setTriggerMode(mode)
        UserDefaults.standard.set(mode.rawValue, forKey: triggerModeDefaultsKey)
        refreshTriggerModeMenuState()
        controller.evaluateNow()
    }

    @objc private func selectCustomHotkey() {
        let alert = NSAlert()
        alert.messageText = "Set Trigger Hotkey"
        alert.informativeText = "Format: test / fn / cmd+1 / ctrl+space / alt+tab / shift+enter"
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
