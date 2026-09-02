import AppKit

/// Edits AppSettings in place. Every control applies immediately — there is no
/// OK/Cancel, so `onChange` may fire many times and the controller is careful to
/// only power-cycle a light whose port actually moved.
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    private final class PortChoice: NSObject {
        let hub: String
        let port: String

        init(hub: String, port: String) {
            self.hub = hub
            self.port = port
        }
    }

    private var settings: AppSettings
    private var cameras: [String]
    private var hubs: [Hub] = []
    private let onChange: (AppSettings) -> Void

    private let tableView = NSTableView()
    private let addRemove = NSSegmentedControl(labels: ["+", "−"], trackingMode: .momentary,
                                               target: nil, action: nil)
    private let nameField = NSTextField()
    private let cameraPopup = NSPopUpButton()
    private let portPopup = NSPopUpButton()
    private let hubNameField = NSTextField()
    private let onDelayField = NSTextField()
    private let offDelayField = NSTextField()
    private let hotKeyButton = HotKeyRecorderButton()
    private let exactCheck = NSButton(checkboxWithTitle: "This port only, not its USB3 companion",
                                      target: nil, action: nil)
    private let sudoCheck = NSButton(checkboxWithTitle: "Use sudo for USB power control (needs a NOPASSWD rule)",
                                     target: nil, action: nil)
    private let powerOffCheck = NSButton(checkboxWithTitle: "Turn lights off when camlight quits",
                                         target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    private var selectedIndex: Int? {
        let row = tableView.selectedRow
        return settings.lights.indices.contains(row) ? row : nil
    }

    init(settings: AppSettings, cameras: [String], onChange: @escaping (AppSettings) -> Void) {
        self.settings = settings
        self.cameras = cameras
        self.onChange = onChange

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "camlight Settings"
        super.init(window: window)

        window.contentView = buildLayout()
        window.center()

        reloadHubs()
        tableView.reloadData()
        if !settings.lights.isEmpty { tableView.selectRowIndexes([0], byExtendingSelection: false) }
        syncForm()
        syncGlobals()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: layout

    private func buildLayout() -> NSView {
        let scroll = NSScrollView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 180
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 250).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 200).isActive = true

        addRemove.target = self
        addRemove.action = #selector(addOrRemove(_:))
        addRemove.segmentDistribution = .fillEqually

        let leftColumn = NSStackView(views: [label("Lights", bold: true), scroll, addRemove])
        leftColumn.orientation = .vertical
        leftColumn.alignment = .leading
        leftColumn.spacing = 6

        for field in [nameField, hubNameField, onDelayField, offDelayField] {
            field.delegate = self
            field.target = self
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
        }
        nameField.action = #selector(formChanged(_:))
        hubNameField.action = #selector(hubNameChanged(_:))
        onDelayField.action = #selector(formChanged(_:))
        offDelayField.action = #selector(formChanged(_:))

        for control in [cameraPopup, portPopup] {
            control.target = self
            control.action = #selector(formChanged(_:))
        }
        exactCheck.target = self
        exactCheck.action = #selector(formChanged(_:))
        hotKeyButton.onChange = { [weak self] shortcut in
            guard let self else { return }
            self.settings.hotKey = shortcut
            self.publish()
        }

        nameField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        cameraPopup.widthAnchor.constraint(equalToConstant: 300).isActive = true
        portPopup.widthAnchor.constraint(equalToConstant: 300).isActive = true
        hubNameField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        onDelayField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        offDelayField.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let form = NSGridView(views: [
            [label("Name"), nameField],
            [label("Camera"), cameraPopup],
            [label("Port"), portPopup],
            [label("Hub name"), hubNameField],
            [label("Turn on after"), suffixed(onDelayField, "seconds")],
            [label("Turn off after"), suffixed(offDelayField, "seconds")],
            [NSGridCell.emptyContentView, exactCheck],
        ])
        form.column(at: 0).xPlacement = .trailing
        form.rowSpacing = 10
        form.columnSpacing = 10

        let top = NSStackView(views: [leftColumn, form])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = 20

        let separator = NSBox()
        separator.boxType = .separator

        for check in [sudoCheck, powerOffCheck] {
            check.target = self
            check.action = #selector(globalsChanged(_:))
        }
        let rescan = NSButton(title: "Rescan ports", target: self, action: #selector(rescanHubs(_:)))
        hotKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

        let globals = NSGridView(views: [
            [label("Toggle hotkey"), hotKeyButton],
            [label("USB ports"), rescan],
            [NSGridCell.emptyContentView, sudoCheck],
            [NSGridCell.emptyContentView, powerOffCheck],
        ])
        globals.column(at: 0).xPlacement = .trailing
        globals.rowSpacing = 8
        globals.columnSpacing = 10

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2

        let root = NSStackView(views: [top, separator, globals, statusLabel])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        return container
    }

    private func label(_ text: String, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        if bold { field.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
        return field
    }

    private func suffixed(_ field: NSTextField, _ suffix: String) -> NSStackView {
        let stack = NSStackView(views: [field, label(suffix)])
        stack.orientation = .horizontal
        stack.spacing = 6
        return stack
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { settings.lights.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let light = settings.lights[row]
        return label(light.isConfigured ? light.name : "\(light.name)  (no port set)")
    }

    func tableViewSelectionDidChange(_ notification: Notification) { syncForm() }

    // MARK: syncing model → controls

    private func syncForm() {
        guard let index = selectedIndex else {
            [nameField, hubNameField, onDelayField, offDelayField].forEach {
                $0.isEnabled = false
                $0.stringValue = ""
            }
            [cameraPopup, portPopup].forEach { $0.isEnabled = false; $0.removeAllItems() }
            exactCheck.isEnabled = false
            return
        }
        let light = settings.lights[index]
        [nameField, onDelayField, offDelayField].forEach { $0.isEnabled = true }
        [cameraPopup, portPopup].forEach { $0.isEnabled = true }
        exactCheck.isEnabled = true

        nameField.stringValue = light.name
        onDelayField.stringValue = String(format: "%g", light.onDelay)
        offDelayField.stringValue = String(format: "%g", light.offDelay)
        exactCheck.state = light.exactPort ? .on : .off

        cameraPopup.removeAllItems()
        cameraPopup.addItem(withTitle: "Any camera")
        cameraPopup.lastItem?.representedObject = LightSettings.anyCamera
        var names = cameras
        if light.camera != LightSettings.anyCamera && !names.contains(light.camera) {
            names.append(light.camera)          // keep a camera that's currently unplugged
        }
        for name in names {
            cameraPopup.addItem(withTitle: name)
            cameraPopup.lastItem?.representedObject = name
        }
        selectItem(in: cameraPopup, matching: light.camera)

        syncPortPopup(for: light)
        syncHubNameField(for: light)
    }

    private func syncPortPopup(for light: LightSettings) {
        portPopup.removeAllItems()
        portPopup.addItem(withTitle: "Choose a port…")

        for (hubIndex, hub) in hubs.enumerated() {
            if hubIndex > 0 || portPopup.numberOfItems > 1 { portPopup.menu?.addItem(.separator()) }
            addHubHeading(title: hubDisplayName(hub.location, fallback: hub.description))

            let portNumbers = hub.portCount > 0
                ? Array(1...hub.portCount)
                : hub.ports.map(\.number)
            for portNumber in portNumbers {
                let port = hub.ports.first { $0.number == portNumber }
                addPort(title: port?.menuTitle ?? "Port \(portNumber)",
                        hub: hub.location, port: String(portNumber))
            }

            let savedPort = Int(light.port)
            let savedPortWasReported = savedPort.map(portNumbers.contains) ?? false
            if light.hub == hub.location, !light.port.isEmpty, !savedPortWasReported {
                addPort(title: "Port \(light.port) — Not reported",
                        hub: light.hub, port: light.port)
            }
        }

        if !light.hub.isEmpty && !hubs.contains(where: { $0.location == light.hub }) {
            if portPopup.numberOfItems > 1 { portPopup.menu?.addItem(.separator()) }
            addHubHeading(title: hubDisplayName(light.hub, fallback: light.hub) + " — Not connected")
            if !light.port.isEmpty {
                addPort(title: "Port \(light.port)", hub: light.hub, port: light.port)
            }
        }

        if hubs.isEmpty && light.hub.isEmpty {
            portPopup.removeAllItems()
            portPopup.addItem(withTitle: "No switchable ports found")
            portPopup.lastItem?.isEnabled = false
            portPopup.isEnabled = false
        } else {
            selectPort(hub: light.hub, port: light.port)
        }
    }

    private func addHubHeading(title: String) {
        let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        portPopup.menu?.addItem(heading)
    }

    private func addPort(title: String, hub: String, port: String) {
        portPopup.addItem(withTitle: title)
        portPopup.lastItem?.indentationLevel = 1
        portPopup.lastItem?.representedObject = PortChoice(hub: hub, port: port)
        portPopup.lastItem?.toolTip = title
    }

    private func selectPort(hub: String, port: String) {
        let match = portPopup.itemArray.first { item in
            guard let choice = item.representedObject as? PortChoice else { return false }
            return choice.hub == hub && choice.port == port
        }
        portPopup.select(match ?? portPopup.itemArray.first)
    }

    private func syncHubNameField(for light: LightSettings) {
        guard !light.hub.isEmpty else {
            hubNameField.isEnabled = false
            hubNameField.stringValue = ""
            hubNameField.placeholderString = "Choose a port first"
            return
        }
        hubNameField.isEnabled = true
        hubNameField.placeholderString = nil
        let fallback = hubs.first { $0.location == light.hub }?.description ?? light.hub
        hubNameField.stringValue = hubDisplayName(light.hub, fallback: fallback)
    }

    private func hubDisplayName(_ location: String, fallback: String) -> String {
        settings.hubNames[location] ?? fallback
    }

    private func selectItem(in popup: NSPopUpButton, matching value: String) {
        let match = popup.itemArray.first { ($0.representedObject as? String) == value }
        popup.select(match ?? popup.itemArray.first)
    }

    private func syncGlobals() {
        hotKeyButton.setShortcut(settings.hotKey)
        sudoCheck.state = settings.useSudo ? .on : .off
        powerOffCheck.state = settings.powerOffOnExit ? .on : .off
        updateStatusLabel()
    }

    private func updateStatusLabel() {
        if !FileManager.default.isExecutableFile(atPath: BundledUhubctl.executablePath) {
            statusLabel.stringValue = "The bundled USB helper is missing. Rebuild camlight, then press Rescan."
        } else if hubs.isEmpty {
            statusLabel.stringValue = "No hubs with per-port power switching found. Only hubs uhubctl marks "
                                    + "`ppps` can cut power to a port."
        } else {
            statusLabel.stringValue = "\(hubs.count) switchable hub\(hubs.count == 1 ? "" : "s") found. "
                                    + "Ports are grouped by hub; select a port to view or rename its hub."
        }
    }

    // MARK: controls → model

    @objc private func formChanged(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        var light = settings.lights[index]
        light.name = nameField.stringValue.isEmpty ? "Light" : nameField.stringValue
        light.camera = (cameraPopup.selectedItem?.representedObject as? String) ?? LightSettings.anyCamera
        light.onDelay = max(0, Double(onDelayField.stringValue) ?? light.onDelay)
        light.offDelay = max(0, Double(offDelayField.stringValue) ?? light.offDelay)
        light.exactPort = exactCheck.state == .on

        let choice = portPopup.selectedItem?.representedObject as? PortChoice
        light.hub = choice?.hub ?? ""
        light.port = choice?.port ?? ""

        settings.lights[index] = light
        tableView.reloadData()
        tableView.selectRowIndexes([index], byExtendingSelection: false)
        syncForm()
        publish()
    }

    @objc private func hubNameChanged(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        let location = settings.lights[index].hub
        guard !location.isEmpty else { return }

        let name = hubNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = hubs.first { $0.location == location }?.description ?? location
        if name.isEmpty || name == fallback {
            settings.hubNames.removeValue(forKey: location)
        } else {
            settings.hubNames[location] = name
        }
        syncForm()
        publish()
    }

    @objc private func globalsChanged(_ sender: Any?) {
        settings.useSudo = sudoCheck.state == .on
        settings.powerOffOnExit = powerOffCheck.state == .on
        reloadHubs()
        syncForm()
        publish()
    }

    @objc private func addOrRemove(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            settings.lights.append(LightSettings(name: "Light \(settings.lights.count + 1)"))
            tableView.reloadData()
            tableView.selectRowIndexes([settings.lights.count - 1], byExtendingSelection: false)
        } else {
            guard let index = selectedIndex else { return }
            settings.lights.remove(at: index)
            tableView.reloadData()
            if !settings.lights.isEmpty {
                tableView.selectRowIndexes([min(index, settings.lights.count - 1)], byExtendingSelection: false)
            }
        }
        syncForm()
        publish()
    }

    @objc private func rescanHubs(_ sender: Any?) {
        reloadHubs()
        syncForm()
        publish()
    }

    private func reloadHubs() {
        hubs = HubScanner.scan()
        updateStatusLabel()
    }

    private func publish() { onChange(settings) }

    func controlTextDidEndEditing(_ notification: Notification) {
        if (notification.object as? NSTextField) === hubNameField {
            hubNameChanged(nil)
        } else {
            formChanged(nil)
        }
    }
}
