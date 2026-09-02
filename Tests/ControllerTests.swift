import Foundation

@main
struct ControllerTests {
    static func main() {
        let controller = Controller(settings: AppSettings(), dryRun: true)

        // The settings UI creates a draft first, then configures the same light when
        // a port is selected. Selecting that first port must not power it off.
        var light = LightSettings(name: "Desk light")
        var settings = AppSettings()
        settings.lights = [light]
        controller.update(settings: settings)
        precondition(controller.snapshot().lights.first?.configured == false)

        light.hub = "1-4"
        light.port = "2"
        settings.lights = [light]
        controller.update(settings: settings)

        let added = controller.snapshot().lights
        precondition(added.count == 1)
        precondition(added[0].configured)
        precondition(added[0].powered, "a newly configured light must initially remain on")

        print("ControllerTests passed")
    }
}
