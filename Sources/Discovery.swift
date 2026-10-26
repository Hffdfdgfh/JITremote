import Foundation
import Darwin

struct FoundDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let port: UInt16
}

/// Browses for devices advertising _remotepairing._tcp on the local network (IPv4 only).
final class Discovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published var found: [FoundDevice] = []
    @Published var scanning = false

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []

    func start() {
        stop()
        found = []
        services = []
        browser.delegate = self
        scanning = true
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        scanning = false
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        for data in sender.addresses ?? [] {
            let ip: String? = data.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress, raw.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                let sa = base.assumingMemoryBound(to: sockaddr.self).pointee
                guard sa.sa_family == sa_family_t(AF_INET) else { return nil }
                var sin = base.assumingMemoryBound(to: sockaddr_in.self).pointee
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: buffer)
            }
            if let ip {
                let device = FoundDevice(id: "\(sender.name)-\(ip)", name: sender.name, host: ip, port: UInt16(clamping: sender.port))
                DispatchQueue.main.async {
                    if !self.found.contains(device) { self.found.append(device) }
                }
                return
            }
        }
    }
}
