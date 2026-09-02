import AppKit
import Carbon

/// Registers one system-wide Carbon hotkey without requiring Accessibility access.
final class GlobalHotKey {
    private static let signature: OSType = 0x436D4C74 // "CmLt"

    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init?(shortcut: HotKeySettings, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier)
                guard status == noErr, identifier.signature == GlobalHotKey.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                DispatchQueue.main.async { hotKey.action() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef)
        guard installStatus == noErr else {
            log("could not install hotkey event handler (\(installStatus))")
            return nil
        }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let registrationStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef)
        guard registrationStatus == noErr else {
            if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
            self.eventHandlerRef = nil
            log("could not register hotkey \(shortcut.displayName) (\(registrationStatus))")
            return nil
        }
        log("hotkey \(shortcut.displayName) registered")
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}

private extension HotKeySettings {
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if command { result |= UInt32(cmdKey) }
        if option { result |= UInt32(optionKey) }
        if control { result |= UInt32(controlKey) }
        if shift { result |= UInt32(shiftKey) }
        return result
    }
}

/// A small shortcut recorder used by the settings window.
final class HotKeyRecorderButton: NSButton {
    var onChange: ((HotKeySettings?) -> Void)?

    private var shortcut: HotKeySettings?
    private var eventMonitor: Any?
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording(_:))
        toolTip = "Click, then type a shortcut. Press Delete to turn it off."
        setShortcut(nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setShortcut(_ shortcut: HotKeySettings?) {
        self.shortcut = shortcut
        guard !isRecording else { return }
        title = shortcut?.displayName ?? "Set Hotkey…"
    }

    @objc private func beginRecording(_ sender: Any?) {
        stopRecording()
        isRecording = true
        title = "Type shortcut…"
        window?.makeFirstResponder(self)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == 53 { // Escape cancels recording.
            stopRecording()
            setShortcut(shortcut)
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete disables it.
            stopRecording()
            setShortcut(nil)
            onChange?(nil)
            return
        }

        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty else {
            NSSound.beep()
            return
        }

        let recorded = HotKeySettings(
            keyCode: UInt32(event.keyCode),
            key: Self.keyName(for: event),
            command: flags.contains(.command),
            option: flags.contains(.option),
            control: flags.contains(.control),
            shift: flags.contains(.shift))
        stopRecording()
        setShortcut(recorded)
        onChange?(recorded)
    }

    private func stopRecording() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        isRecording = false
    }

    private static func keyName(for event: NSEvent) -> String {
        let specialKeys: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
            115: "Home", 116: "Page Up", 117: "⌦", 119: "End", 121: "Page Down",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let special = specialKeys[event.keyCode] { return special }
        return event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
    }

    deinit { stopRecording() }
}
