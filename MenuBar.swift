import AppKit
import ServiceManagement

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let controller: Controller
    private var settingsWindow: SettingsWindowController?
    private var globalHotKey: GlobalHotKey?
    private var configuredHotKey: HotKeySettings?
    private var didConfigureHotKey = false

    /// SMAppService only works from inside an .app bundle.
    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    private var opensAtLogin: Bool { isBundled && SMAppService.mainApp.status == .enabled }

    init(controller: Controller) {
        self.controller = controller
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "camlight — click to toggle, right-click for options"
            log("menu bar item installed")
        } else {
            log("warning: no menu bar item — is camlight running outside a GUI session?")
        }

        refreshIcon()
        refreshHotKey()
        controller.onStateChange = { [weak self] in
            self?.refreshIcon()
            self?.refreshHotKey()
        }
    }

    private func refreshIcon() {
        let snapshot = controller.snapshot()
        // A slashed bulb means automation is off — the light no longer follows the camera.
        let symbol: String
        switch (snapshot.automationEnabled, snapshot.anyPowered) {
        case (true, true):   symbol = "lightbulb.fill"
        case (true, false):  symbol = "lightbulb"
        case (false, true):  symbol = "lightbulb.slash.fill"
        case (false, false): symbol = "lightbulb.slash"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription:
                                snapshot.anyPowered ? "light on" : "light off")
        image?.isTemplate = true          // let the menu bar tint it for light/dark
        statusItem.button?.image = image
    }

    private func refreshHotKey() {
        let shortcut = controller.currentSettings().hotKey
        guard !didConfigureHotKey || configuredHotKey != shortcut else { return }
        globalHotKey = nil
        configuredHotKey = shortcut
        didConfigureHotKey = true
        if let shortcut {
            globalHotKey = GlobalHotKey(shortcut: shortcut) { [weak self] in
                self?.controller.toggleAll()
            }
        }
    }

    // MARK: clicks

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            showMenu()
        } else if controller.snapshot().lights.contains(where: { $0.configured }) {
            controller.toggleAll()
        } else {
            openSettings(nil)     // nothing to toggle yet — send them somewhere useful
        }
    }

    private func showMenu() {
        // Attaching a menu makes *every* click open it, so attach it only for this click.
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let automationOn = controller.snapshot().automationEnabled

        let enable = item("Enable", #selector(enableAutomation(_:)))
        enable.state = automationOn ? .on : .off
        menu.addItem(enable)

        let disable = item("Disable", #selector(disableAutomation(_:)))
        disable.state = automationOn ? .off : .on
        menu.addItem(disable)

        menu.addItem(.separator())
        menu.addItem(item("Reset All Ports to On", #selector(powerOnAllPorts(_:))))
        menu.addItem(item("Settings…", #selector(openSettings(_:)), key: ","))

        let login = item("Open at login", #selector(toggleLoginItem(_:)))
        login.state = opensAtLogin ? .on : .off
        if !isBundled {
            login.title = "Open at login (needs the .app bundle)"
            login.isEnabled = false
        }
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit camlight", #selector(quit(_:)), key: "q"))
        return menu
    }

    private func item(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: actions

    @objc private func enableAutomation(_ sender: Any?) { controller.setAutomation(true) }
    @objc private func disableAutomation(_ sender: Any?) { controller.setAutomation(false) }
    @objc private func powerOnAllPorts(_ sender: Any?) { controller.powerOnAllPorts() }

    @objc func openSettings(_ sender: Any?) {
        if settingsWindow?.window?.isVisible != true {
            settingsWindow = SettingsWindowController(
                settings: controller.currentSettings(),
                cameras: controller.snapshot().cameras.map(\.name),
                onChange: { [weak self] updated in self?.controller.update(settings: updated) })
        }
        NSApp.activate(ignoringOtherApps: true)   // .accessory apps don't come forward on their own
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleLoginItem(_ sender: Any?) {
        guard isBundled else { return }
        do {
            if opensAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Could not change the login setting"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quit(_ sender: Any?) {
        controller.powerOffAll()
        NSApp.terminate(nil)
    }
}
