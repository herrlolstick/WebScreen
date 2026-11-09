import AppKit
import CoreImage.CIFilterBuiltins
import Darwin
import Foundation

enum WebScreenError: LocalizedError {
    case virtualDisplayFailed
    case displayNotFound
    case encoderFailed(OSStatus)
    case pageMissing
    case noScreenRecordingPermission

    var errorDescription: String? {
        switch self {
        case .virtualDisplayFailed:
            return "The virtual screen could not be created."
        case .displayNotFound:
            return "ScreenCaptureKit could not find the virtual screen."
        case .encoderFailed(let status):
            return "The video encoder could not be started (error \(status))."
        case .pageMissing:
            return "index.html is missing from the app bundle. Please build the app with ./build.sh."
        case .noScreenRecordingPermission:
            return "WebScreen needs the Screen Recording permission: System Settings → Privacy & Security → Screen & System Audio Recording. Restart the app afterwards."
        }
    }
}

enum LocalNetwork {
    /// IPv4 addresses of the active Ethernet/Wi-Fi interfaces (en0, en1, …)
    static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            let flags = Int32(iface.ifa_flags)
            guard let addr = iface.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            let name = String(cString: iface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }
}

enum QRCode {
    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

enum ReceiverPage {
    /// Loads the receiver page from the app bundle. When launched straight from Xcode
    /// (without a bundle), it falls back to Resources/index.html in the repo.
    static func load() throws -> String {
        if let url = Bundle.main.url(forResource: "index", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            return html
        }
        let repoFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WebScreen
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // Repo
            .appendingPathComponent("Resources/index.html")
        if let html = try? String(contentsOf: repoFile, encoding: .utf8) {
            return html
        }
        throw WebScreenError.pageMissing
    }
}
