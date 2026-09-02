import AppKit

// camlight — a USB light that follows your camera.
//
// Left-click the menu bar icon to toggle the light, right-click for the menu.
// Pass --dry-run to log uhubctl commands without running them.

setvbuf(stdout, nil, _IOLBF, 0)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only: no Dock icon

let controller = Controller(settings: AppSettings.load(),
                            dryRun: CommandLine.arguments.contains("--dry-run"))
controller.start()

var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGTERM, SIGINT] {
    signal(signalNumber, SIG_IGN)   // required so the dispatch source sees it instead
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        controller.powerOffAll()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

let menuBar = MenuBarController(controller: controller)

// Nothing configured yet: open settings so the first launch isn't a dead end.
if controller.currentSettings().lights.isEmpty {
    DispatchQueue.main.async { menuBar.openSettings(nil) }
}

withExtendedLifetime(menuBar) { app.run() }
