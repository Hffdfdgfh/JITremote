import Foundation
import idevice

struct RemoteApp: Identifiable, Hashable {
    let id: String          // bundle identifier
    let name: String
    let path: String
    let isDeveloper: Bool
}

enum JITMode: String, CaseIterable, Identifiable {
    case attachOnly, universal, legacy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .attachOnly: return "Attach only (no TXM)"
        case .universal: return "Universal script (TXM / iOS 26)"
        case .legacy: return "Legacy script"
        }
    }
}

struct RemoteConfig {
    var host: String
    var port: UInt16
    var pairingPath: String
    var hostname: String
}

enum RemoteError: LocalizedError {
    case invalidAddress
    case message(String)
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Invalid IPv4 address."
        case .message(let m): return m
        }
    }
}

/// Lets the blocking FFI thread wait for a PIN typed on the UI thread.
final class PinBox {
    let semaphore = DispatchSemaphore(value: 0)
    var pin = ""
    var onNeedPin: (() -> Void)?
}

private let pinCallback: @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>? = { context in
    guard let context else { return nil }
    let box = Unmanaged<PinBox>.fromOpaque(context).takeUnretainedValue()
    box.onNeedPin?()
    box.semaphore.wait()
    guard let copy = strdup(box.pin) else { return nil }
    return UnsafePointer(copy)
}

/// Talks to ANOTHER device over Wi-Fi: RemotePairing tunnel -> app service -> debug proxy.
final class RemoteJIT {

    private struct Tunnel {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        func free() {
            if let handshake { rsd_handshake_free(handshake) }
            if let adapter { adapter_free(adapter) }
        }
    }

    private let config: RemoteConfig
    private let pinBox: PinBox?

    init(config: RemoteConfig, pinBox: PinBox?) {
        self.config = config
        self.pinBox = pinBox
    }

    // MARK: Public

    func listApps() throws -> [RemoteApp] {
        let tunnel = try makeTunnel()
        defer { tunnel.free() }
        let service = try connectAppService(tunnel)
        defer { app_service_free(service) }

        var apps: UnsafeMutablePointer<AppListEntryC>?
        var count: UInt = 0
        try IdeviceFFI.check("failed to list apps") {
            app_service_list_apps(service, 0, 1, 0, 0, 0, &apps, &count)
        }
        guard let apps else { return [] }
        defer { app_service_free_app_list(apps, count) }

        var result: [RemoteApp] = []
        for i in 0..<Int(count) {
            let entry = apps[i]
            guard let bid = entry.bundle_identifier else { continue }
            result.append(RemoteApp(
                id: String(cString: bid),
                name: entry.name.map { String(cString: $0) } ?? String(cString: bid),
                path: entry.path.map { String(cString: $0) } ?? "",
                isDeveloper: entry.is_developer_app != 0))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func enableJIT(app: RemoteApp, mode: JITMode, progress: @escaping (String) -> Void) throws {
        let tunnel = try makeTunnel()
        defer { tunnel.free() }
        let service = try connectAppService(tunnel)
        defer { app_service_free(service) }

        var pid = try runningPID(service: service, appPath: app.path)
        if let pid {
            progress("\(app.name) already running, pid \(pid)")
        } else {
            progress("launching \(app.name)…")
            pid = try launch(service: service, bundleID: app.id)
            progress("launched, pid \(pid!)")
        }
        guard let pid else { throw RemoteError.message("could not determine pid") }

        var remoteServer: OpaquePointer?
        var debugProxy: OpaquePointer?
        try IdeviceFFI.check("failed to connect remote server (is the DDI mounted on the target?)") {
            remote_server_connect_rsd(tunnel.adapter, tunnel.handshake, &remoteServer)
        }
        defer { if let remoteServer { remote_server_free(remoteServer) } }
        try IdeviceFFI.check("failed to connect debug proxy") {
            debug_proxy_connect_rsd(tunnel.adapter, tunnel.handshake, &debugProxy)
        }
        defer { if let debugProxy { debug_proxy_free(debugProxy) } }
        guard let proxy = debugProxy else { throw StikJITError.debugProxyUnavailable }

        debug_proxy_send_ack(proxy)
        _ = try? sendCommand("QStartNoAckMode", over: proxy)
        debug_proxy_set_ack_mode(proxy, 0)

        switch mode {
        case .attachOnly:
            progress("attaching to pid \(pid)…")
            _ = try sendCommand("vAttach;\(String(pid, radix: 16))", over: proxy)
            _ = try? sendCommand("D", over: proxy)
            progress("JIT enabled (attached + detached)")
        case .universal, .legacy:
            let script: StikJIT.Script = (mode == .universal) ? .universal : .legacy
            try ScriptRunner(targetPID: pid, debugProxy: proxy, script: script, progress: progress).run()
        }
    }

    // MARK: Tunnel

    private func makeTunnel() throws -> Tunnel {
        var pairing: OpaquePointer?
        if FileManager.default.fileExists(atPath: config.pairingPath) {
            try IdeviceFFI.check("failed to read pairing file") {
                config.pairingPath.withCString { rp_pairing_file_read($0, &pairing) }
            }
        } else {
            try IdeviceFFI.check("failed to generate pairing file") {
                config.hostname.withCString { rp_pairing_file_generate($0, &pairing) }
            }
        }
        guard let pairing else { throw RemoteError.message("no pairing file") }
        defer { rp_pairing_file_free(pairing) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = config.port.bigEndian
        guard config.host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw RemoteError.invalidAddress
        }

        let context: UnsafeMutableRawPointer? = pinBox.map { Unmanaged.passUnretained($0).toOpaque() }
        let usePin = pinBox != nil

        var tunnel = Tunnel()
        try IdeviceFFI.check("failed to create tunnel to \(config.host):\(config.port)") {
            config.hostname.withCString { hostname in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        tunnel_create_rppairing(
                            sa, socklen_t(MemoryLayout<sockaddr_in>.stride),
                            hostname, pairing,
                            usePin ? pinCallback : nil, context,
                            &tunnel.adapter, &tunnel.handshake)
                    }
                }
            }
        }

        // The file may have been updated in place by a first-time pair-setup; persist it.
        if let error = config.pairingPath.withCString({ rp_pairing_file_write(pairing, $0) }) {
            idevice_error_free(error)
        }
        return tunnel
    }

    private func connectAppService(_ tunnel: Tunnel) throws -> OpaquePointer {
        var service: OpaquePointer?
        try IdeviceFFI.check("failed to connect app service") {
            app_service_connect_rsd(tunnel.adapter, tunnel.handshake, &service)
        }
        guard let service else { throw RemoteError.message("app service unavailable") }
        return service
    }

    // MARK: Processes

    private func normalize(_ s: String) -> String {
        var v = s
        if v.hasPrefix("file://") { v.removeFirst("file://".count) }
        if v.hasPrefix("/private") { v.removeFirst("/private".count) }
        return v
    }

    private func runningPID(service: OpaquePointer, appPath: String) throws -> Int32? {
        guard !appPath.isEmpty else { return nil }
        var processes: UnsafeMutablePointer<ProcessTokenC>?
        var count: UInt = 0
        try IdeviceFFI.check("failed to list processes") {
            app_service_list_processes(service, &processes, &count)
        }
        guard let processes else { return nil }
        defer { app_service_free_process_list(processes, count) }

        let wanted = normalize(appPath)
        for i in 0..<Int(count) {
            guard let url = processes[i].executable_url else { continue }
            if normalize(String(cString: url)).hasPrefix(wanted) { return Int32(processes[i].pid) }
        }
        return nil
    }

    private func launch(service: OpaquePointer, bundleID: String) throws -> Int32 {
        var response: UnsafeMutablePointer<LaunchResponseC>?
        try IdeviceFFI.check("failed to launch \(bundleID)") {
            bundleID.withCString { app_service_launch_app(service, $0, nil, 0, 0, 0, nil, &response) }
        }
        guard let response else { throw RemoteError.message("launch returned nothing") }
        defer { app_service_free_launch_response(response) }
        return Int32(response.pointee.pid)
    }

    // MARK: Debugserver

    @discardableResult
    private func sendCommand(_ command: String, over debugProxy: OpaquePointer) throws -> String? {
        guard let handle = command.withCString({ debugserver_command_new($0, nil, 0) }) else { return nil }
        defer { debugserver_command_free(handle) }
        var response: UnsafeMutablePointer<CChar>?
        try IdeviceFFI.check("debugserver command failed") {
            debug_proxy_send_command(debugProxy, handle, &response)
        }
        guard let response else { return nil }
        defer { idevice_string_free(response) }
        return String(cString: response)
    }
}
