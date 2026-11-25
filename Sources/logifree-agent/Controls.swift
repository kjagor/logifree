import Foundation
import LogifreeCore

/// Read-only dump of every reprogrammable control (0x1B04 functions 0, 1, 2 only). Exits after 10 s.
func dumpControls() -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)
    let monitor = HIDMonitor()
    monitor.onAttach = { transport in
        for device in transport.discoverDevices() where device.ping() {
            device.loadIdentity()
            guard device.isMouse, let count = try? device.call(HIDPP.Feature.reprogControls, 0)[0] else { continue }
            print("\(device.name): \(count) controls")
            for function in [UInt8(0), 1] { // thumbwheel getInfo, getReporting
                guard let bytes = try? device.call(HIDPP.Feature.thumbwheel, function) else { continue }
                print("thumbwheel function \(function): " + bytes.prefix(10).map { String(format: "%02X", $0) }.joined(separator: " "))
            }
            for index in 0..<count {
                guard let info = try? device.call(HIDPP.Feature.reprogControls, 1, [index]) else { continue }
                let names = [(0x01, "mouse"), (0x02, "fkey"), (0x04, "hotkey"), (0x08, "fntoggle"), (0x10, "reprog"),
                             (0x20, "divertable"), (0x40, "persistdivert"), (0x80, "virtual")]
                let flags = names.filter { Int(info[4]) & $0.0 != 0 }.map(\.1).joined(separator: ",")
                let reporting = (try? device.call(HIDPP.Feature.reprogControls, 2, Array(info[0..<2])).prefix(5)) ?? []
                print(String(format: "#%02d cid=%02X%02X task=%02X%02X flags=%02X [%@] rawXY=%@ reporting=", index, info[0], info[1],
                             info[2], info[3], info[4], flags, info[8] & 1 != 0 ? "yes" : "no")
                    + reporting.map { String(format: "%02X", $0) }.joined(separator: " "))
            }
        }
    }
    monitor.start()
    Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in exit(0) }
    CFRunLoopRun()
    exit(0)
}
