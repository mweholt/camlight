import Foundation

@main
struct HubScannerTests {
    static func main() {
        let output = """
        Current status for hub 1-4 [2109:2817 VIA Labs, Inc. USB2.0 Hub, USB 2.10, 4 ports, ppps]
          Port 1: 0100 power
          Port 2: 0503 power highspeed enable connect [2659:1210 Sundtek MediaTV Pro III U140603172543]
          Port 3: 0503 power highspeed enable connect [0424:4216]
          Port 4: 0103 power enable connect []
        Current status for hub 2 [1234:5678 Unsupported Hub, USB 2.00, 2 ports, ganged]
          Port 1: 0100 power
        """

        let hubs = HubScanner.parse(output)
        precondition(hubs.count == 1)
        precondition(hubs[0].location == "1-4")
        precondition(hubs[0].portCount == 4)
        precondition(hubs[0].ports.count == 4)
        precondition(hubs[0].ports[0].menuTitle == "Port 1 — Empty")
        precondition(hubs[0].ports[1].menuTitle == "Port 2 — Sundtek MediaTV Pro III U140603172543")
        precondition(hubs[0].ports[2].menuTitle == "Port 3 — 0424:4216")
        precondition(hubs[0].ports[3].menuTitle == "Port 4 — Connected device")

        // Settings saved by releases before hub renaming must still load intact.
        let legacySettings = """
        {"uhubctl":"/usr/local/bin/uhubctl","useSudo":true,"powerOffOnExit":false,
         "automationEnabled":false,"lights":[{
           "id":"00000000-0000-0000-0000-000000000001","name":"Desk light","camera":"*",
           "hub":"1-4","port":"2","onDelay":0,"offDelay":5,"exactPort":true
         }]}
        """.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(AppSettings.self, from: legacySettings)
        precondition(decoded.useSudo)
        precondition(decoded.lights.first?.hub == "1-4")
        precondition(decoded.lights.first?.port == "2")
        precondition(decoded.hubNames.isEmpty)
        precondition(decoded.hotKey == HotKeySettings())

        var renamed = decoded
        renamed.hubNames["1-4"] = "Desk hub"
        let roundTripped = try! JSONDecoder().decode(AppSettings.self,
                                                     from: JSONEncoder().encode(renamed))
        precondition(roundTripped.hubNames["1-4"] == "Desk hub")

        renamed.hotKey = nil
        let disabledHotKey = try! JSONDecoder().decode(AppSettings.self,
                                                       from: JSONEncoder().encode(renamed))
        precondition(disabledHotKey.hotKey == nil)
        print("HubScannerTests passed")
    }
}
