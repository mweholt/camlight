import Foundation
import CoreMediaIO

struct Snapshot {
    struct Light { let id: UUID; let name: String; let powered: Bool; let configured: Bool }
    struct Camera { let name: String; let streaming: Bool }
    let lights: [Light]
    let cameras: [Camera]
    let automationEnabled: Bool
    var anyPowered: Bool { lights.contains { $0.powered } }
}

final class Controller {
    private let dryRun: Bool
    private let events = DispatchQueue(label: "camlight.events")   // serial: guards all state below
    private let exec = DispatchQueue(label: "camlight.exec")       // serial: one uhubctl at a time

    private var settings: AppSettings
    private var streaming: [CMIOObjectID: Bool] = [:]
    private var identity: [CMIOObjectID: (name: String, uid: String)] = [:]
    private var powered: [UUID: Bool] = [:]
    private var pending: [UUID: DispatchWorkItem] = [:]
    private var settled = false

    /// Called on the main queue whenever the menu bar should redraw.
    var onStateChange: (() -> Void)?

    init(settings: AppSettings, dryRun: Bool) {
        self.settings = settings
        self.dryRun = dryRun
    }

    func start() {
        var addr = propertyAddress(kCMIOHardwarePropertyDevices)
        CMIOObjectAddPropertyListenerBlock(systemObject, &addr, events) { [weak self] _, _ in
            self?.rescan()
        }
        events.async {
            self.rescan()
            self.settled = true       // the first pass forces lights to a known state with no delay
        }
    }

    // MARK: camera state

    private func rescan() {
        for device in cameraDevices() where streaming[device] == nil {
            identity[device] = (cameraName(device),
                                stringProperty(device, kCMIODevicePropertyDeviceUID) ?? "")
            streaming[device] = isStreaming(device)

            var addr = propertyAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
            CMIOObjectAddPropertyListenerBlock(device, &addr, events) { [weak self] _, _ in
                self?.deviceChanged(device)
            }
            log("watching \"\(identity[device]!.name)\"")
        }
        evaluate()
        notifyChanged()
    }

    private func deviceChanged(_ device: CMIOObjectID) {
        let running = isStreaming(device)
        guard streaming[device] != running else { return }   // the property fires more than once per transition
        streaming[device] = running
        log("\"\(identity[device]?.name ?? "?")\" \(running ? "started" : "stopped") streaming")
        evaluate()
        notifyChanged()
    }

    private func cameraActive(for light: LightSettings) -> Bool {
        streaming.contains { device, running in
            guard running else { return false }
            if light.camera == LightSettings.anyCamera { return true }
            guard let info = identity[device] else { return false }
            return info.name == light.camera || info.uid == light.camera
        }
    }

    // MARK: deciding

    private func evaluate() {
        guard settings.automationEnabled else { return }
        for light in settings.lights where light.isConfigured {
            let desired = cameraActive(for: light)
            if powered[light.id] == desired {
                pending[light.id]?.cancel()      // cancels a scheduled off when the camera comes back
                pending[light.id] = nil
                continue
            }
            guard pending[light.id] == nil else { continue }

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending[light.id] = nil
                self.apply(light, on: desired)
                self.notifyChanged()
            }
            pending[light.id] = work
            let delay = settled ? (desired ? light.onDelay : light.offDelay) : 0
            if delay > 0 {
                events.asyncAfter(deadline: .now() + delay, execute: work)
            } else {
                events.async(execute: work)
            }
        }
    }

    // MARK: menu bar interface

    func snapshot() -> Snapshot {
        events.sync {
            Snapshot(
                lights: settings.lights.map {
                    Snapshot.Light(id: $0.id, name: $0.name,
                                   powered: powered[$0.id] ?? false, configured: $0.isConfigured)
                },
                cameras: streaming
                    .map { Snapshot.Camera(name: identity[$0.key]?.name ?? "?", streaming: $0.value) }
                    .sorted { $0.name < $1.name },
                automationEnabled: settings.automationEnabled)
        }
    }

    func currentSettings() -> AppSettings { events.sync { settings } }

    /// Left-clicking the status item: flip every configured light at once. If automation
    /// is on, the next camera transition takes control back.
    func toggleAll() {
        events.async {
            let configured = self.settings.lights.filter(\.isConfigured)
            guard !configured.isEmpty else { return }
            let turnOn = !configured.contains { self.powered[$0.id] == true }
            log("manual toggle → \(turnOn ? "on" : "off")")
            for light in configured {
                self.pending[light.id]?.cancel()
                self.pending[light.id] = nil
                if self.powered[light.id] != turnOn { self.apply(light, on: turnOn) }
            }
            self.notifyChanged()
        }
    }

    func setAutomation(_ enabled: Bool) {
        events.async {
            guard self.settings.automationEnabled != enabled else { return }
            self.settings.automationEnabled = enabled
            self.settings.save()
            log("automation \(enabled ? "enabled" : "disabled")")
            if enabled { self.evaluate() }
            self.notifyChanged()
        }
    }

    /// Applies edits from the settings window. Only lights whose port actually moved get
    /// switched off, so renaming one doesn't power-cycle it.
    func update(settings newSettings: AppSettings) {
        events.async {
            var merged = newSettings
            merged.automationEnabled = self.settings.automationEnabled   // the menu owns this
            let previous = self.settings

            for light in previous.lights where self.powered[light.id] == true {
                let replacement = merged.lights.first { $0.id == light.id }
                let samePort = replacement.map {
                    $0.hub == light.hub && $0.port == light.port && $0.exactPort == light.exactPort
                } ?? false
                if !samePort {
                    log("\(light.name) → off (settings changed)")
                    self.send(self.command(for: light, on: false, in: previous), label: light.name)
                    self.powered[light.id] = nil
                }
            }

            let liveIDs = Set(merged.lights.map(\.id))
            for (id, work) in self.pending where !liveIDs.contains(id) { work.cancel() }
            self.pending = self.pending.filter { liveIDs.contains($0.key) }
            self.powered = self.powered.filter { liveIDs.contains($0.key) }

            self.settings = merged
            merged.save()
            self.settled = false      // establish a known state for anything new
            self.evaluate()
            self.settled = true
            self.notifyChanged()
        }
    }

    private func notifyChanged() {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?() }
    }

    // MARK: running uhubctl

    private func apply(_ light: LightSettings, on: Bool) {
        powered[light.id] = on
        log("\(light.name) → \(on ? "on" : "off")")
        send(command(for: light, on: on, in: settings), label: light.name)
    }

    private func command(for light: LightSettings, on: Bool, in settings: AppSettings) -> [String] {
        precondition(!light.port.isEmpty, "\(light.name): a blank port would target the whole hub")
        var argv = [BundledUhubctl.executablePath, "-l", light.hub, "-p", light.port,
                    "-a", on ? "on" : "off"]
        if light.exactPort { argv.append("-e") }
        if settings.useSudo { argv = ["/usr/bin/sudo", "-n"] + argv }
        return argv
    }

    private func send(_ argv: [String], label: String) {
        log("  \(argv.joined(separator: " "))")
        guard !dryRun else { return }
        exec.async { Self.run(argv, label: label) }
    }

    private static func run(_ argv: [String], label: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let text = String(data: output, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                log("\(label): uhubctl exited \(process.terminationStatus)\(text.isEmpty ? "" : ": \(text)")")
            }
        } catch {
            log("\(label): could not run \(argv[0]): \(error.localizedDescription)")
        }
    }

    /// Called on quit so lights don't stay lit with nothing watching them.
    func powerOffAll() {
        guard settings.powerOffOnExit else { return }
        events.sync {
            for light in settings.lights where powered[light.id] == true {
                pending[light.id]?.cancel()
                log("\(light.name) → off (quitting)")
                let argv = command(for: light, on: false, in: settings)
                if !dryRun { Self.run(argv, label: light.name) }
            }
        }
    }
}
