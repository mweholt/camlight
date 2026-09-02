import Foundation

/// One light: a USB port, and the camera that drives it.
struct LightSettings: Codable, Equatable {
    var id = UUID()
    var name = "Ring light"
    var camera = LightSettings.anyCamera   // a camera's exact name, or anyCamera
    var hub = ""                           // uhubctl location, e.g. "0-1.2"
    var port = ""                          // single port number
    var onDelay: Double = 0
    var offDelay: Double = 5
    var exactPort = true                   // uhubctl -e: never the USB3 companion port

    static let anyCamera = "*"
    var isConfigured: Bool { !hub.isEmpty && !port.isEmpty }
}

struct HotKeySettings: Codable, Equatable {
    var keyCode: UInt32 = 37 // L on a US keyboard
    var key = "L"
    var command = false
    var option = true
    var control = true
    var shift = false

    var displayName: String {
        (control ? "⌃" : "")
            + (option ? "⌥" : "")
            + (shift ? "⇧" : "")
            + (command ? "⌘" : "")
            + key
    }
}

struct AppSettings: Codable {
    var useSudo = false
    var powerOffOnExit = true
    var automationEnabled = true
    var lights: [LightSettings] = []
    var hubNames: [String: String] = [:]   // user-facing names keyed by stable uhubctl location
    var hotKey: HotKeySettings? = HotKeySettings()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case useSudo, powerOffOnExit, automationEnabled, lights, hubNames, hotKey
    }

    /// `hubNames` was added after the initial release. Decode every value with its
    /// default so existing saved settings continue to load as the model evolves.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        useSudo = try values.decodeIfPresent(Bool.self, forKey: .useSudo) ?? false
        powerOffOnExit = try values.decodeIfPresent(Bool.self, forKey: .powerOffOnExit) ?? true
        automationEnabled = try values.decodeIfPresent(Bool.self, forKey: .automationEnabled) ?? true
        lights = try values.decodeIfPresent([LightSettings].self, forKey: .lights) ?? []
        hubNames = try values.decodeIfPresent([String: String].self, forKey: .hubNames) ?? [:]
        hotKey = values.contains(.hotKey)
            ? try values.decodeIfPresent(HotKeySettings.self, forKey: .hotKey)
            : HotKeySettings()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(useSudo, forKey: .useSudo)
        try values.encode(powerOffOnExit, forKey: .powerOffOnExit)
        try values.encode(automationEnabled, forKey: .automationEnabled)
        try values.encode(lights, forKey: .lights)
        try values.encode(hubNames, forKey: .hubNames)
        if let hotKey {
            try values.encode(hotKey, forKey: .hotKey)
        } else {
            try values.encodeNil(forKey: .hotKey)
        }
    }

    // MARK: persistence

    private static let defaultsKey = "camlight.settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

/// A USB hub that can switch power on individual ports.
struct Hub {
    let location: String       // uhubctl -l value
    let description: String
    let portCount: Int
    let ports: [HubPort]
}

/// The device, if any, that uhubctl found directly on a hub port.
struct HubPort {
    let number: Int
    let deviceName: String?
    let isConnected: Bool

    var menuTitle: String {
        if let deviceName { return "Port \(number) — \(deviceName)" }
        if isConnected { return "Port \(number) — Connected device" }
        return "Port \(number) — Empty"
    }
}

enum HubScanner {
    /// Parses `uhubctl` output, keeping only hubs that advertise per-port power
    /// switching (`ppps`) — the rest cannot cut power to a port at all.
    static func scan() -> [Hub] {
        guard let output = run(BundledUhubctl.executablePath) else { return [] }
        return parse(output)
    }

    /// Kept separate from process execution so the uhubctl text format can be tested.
    static func parse(_ output: String) -> [Hub] {
        let prefix = "Current status for hub "
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var hubs: [Hub] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            defer { index += 1 }
            guard line.hasPrefix(prefix) else { continue }

            let rest = line.dropFirst(prefix.count)
            guard let open = rest.firstIndex(of: "["), let close = rest.lastIndex(of: "]") else { continue }

            let attributes = String(rest[rest.index(after: open)..<close])
            guard attributes.contains("ppps") else { continue }

            let fields = attributes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let portCount = fields.compactMap { field -> Int? in
                guard field.hasSuffix(" ports") else { return nil }
                return Int(field.dropLast(" ports".count))
            }.first ?? 0

            var ports: [HubPort] = []
            var portIndex = index + 1
            while portIndex < lines.count && !lines[portIndex].hasPrefix(prefix) {
                if let port = parsePort(lines[portIndex]) { ports.append(port) }
                portIndex += 1
            }

            hubs.append(Hub(location: rest[..<open].trimmingCharacters(in: .whitespaces),
                            description: fields.first ?? "USB hub",
                            portCount: portCount,
                            ports: ports.sorted { $0.number < $1.number }))
        }
        return hubs
    }

    private static func parsePort(_ line: String) -> HubPort? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefix = "Port "
        guard trimmed.hasPrefix(prefix), let colon = trimmed.firstIndex(of: ":"),
              let number = Int(trimmed[trimmed.index(trimmed.startIndex, offsetBy: prefix.count)..<colon])
        else { return nil }

        let details = trimmed[trimmed.index(after: colon)...]
        let isConnected = details.split(whereSeparator: \Character.isWhitespace).contains("connect")

        var deviceName: String?
        if isConnected, let open = details.lastIndex(of: "["), let close = details.lastIndex(of: "]"), open < close {
            let descriptor = details[details.index(after: open)..<close]
                .trimmingCharacters(in: .whitespaces)
            if !descriptor.isEmpty {
                deviceName = displayName(from: descriptor)
            }
        }
        return HubPort(number: number, deviceName: deviceName, isConnected: isConnected)
    }

    /// uhubctl prefixes descriptions with a USB vendor/product ID. Hide that ID when a
    /// human-readable name follows it, but keep it as the useful fallback when it does not.
    private static func displayName(from descriptor: String) -> String {
        let parts = descriptor.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
        guard parts.count == 2, isUSBIdentifier(parts[0]) else { return descriptor }
        return String(parts[1])
    }

    private static func isUSBIdentifier(_ value: Substring) -> Bool {
        guard value.count == 9, value[value.index(value.startIndex, offsetBy: 4)] == ":" else { return false }
        return value.enumerated().allSatisfy { offset, character in
            offset == 4 || character.isHexDigit
        }
    }

    static func run(_ path: String, _ arguments: [String] = []) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // read before waiting, or we deadlock
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

enum BundledUhubctl {
    static var executablePath: String {
        let fileManager = FileManager.default
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/uhubctl").path
        if fileManager.isExecutableFile(atPath: bundled) { return bundled }

        if let executable = Bundle.main.executableURL {
            let adjacent = executable.deletingLastPathComponent()
                .appendingPathComponent("uhubctl").path
            if fileManager.isExecutableFile(atPath: adjacent) { return adjacent }
        }

        return fileManager.currentDirectoryPath + "/.build/uhubctl"
    }
}
