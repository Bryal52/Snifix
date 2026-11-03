import Foundation
import IOKit

/// iPhones and iPads currently plugged into the Mac by USB.
enum AppleUSB {
    static func connectedDevices() -> [String] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var names: [String] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            let vendor = IORegistryEntryCreateCFProperty(service, "idVendor" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            let name = IORegistryEntryCreateCFProperty(service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if vendor == 0x05AC, let name, name.contains("iPhone") || name.contains("iPad") { names.append(name) }
        }
        return names
    }
}

struct AndroidDevice: Identifiable, Hashable {
    var id: String { serial }
    var serial: String
    var state: String
    var model: String
    var proxied = false
}

/// Drives Android phones over adb: traffic goes through the USB cable with `adb reverse`.
final class AndroidBridge {
    let adb: String?

    init() {
        adb = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb",
               NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func devices() -> [AndroidDevice] {
        guard adb != nil else { return [] }
        return run(["devices", "-l"]).split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { return nil }
            let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            return AndroidDevice(serial: parts[0], state: parts[1], model: model ?? parts[0])
        }
    }

    func connect(_ serial: String, port: Int) -> Bool {
        _ = run(["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"])
        _ = run(["-s", serial, "shell", "settings", "put", "global", "http_proxy", "127.0.0.1:\(port)"])
        return currentProxy(serial) == "127.0.0.1:\(port)"
    }

    func disconnect(_ serial: String, port: Int) {
        _ = run(["-s", serial, "shell", "settings", "put", "global", "http_proxy", ":0"])
        _ = run(["-s", serial, "reverse", "--remove", "tcp:\(port)"])
    }

    func currentProxy(_ serial: String) -> String {
        run(["-s", serial, "shell", "settings", "get", "global", "http_proxy"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Copies the certificate to Downloads on the phone and opens the security settings there.
    func pushCertificate(_ serial: String, der: Data) -> Bool {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Snifix-CA.crt")
        guard (try? der.write(to: tmp)) != nil else { return false }
        let out = run(["-s", serial, "push", tmp.path, "/sdcard/Download/Snifix-CA.crt"])
        _ = run(["-s", serial, "shell", "am", "start", "-a", "android.settings.SECURITY_SETTINGS"])
        return !out.lowercased().contains("error")
    }

    @discardableResult
    func run(_ args: [String]) -> String {
        guard let adb else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
