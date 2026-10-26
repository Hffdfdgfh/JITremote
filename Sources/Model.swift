import SwiftUI

@MainActor
final class Model: ObservableObject {
    static let udid = "JITREMOTE-0000"

    @Published var host: String { didSet { UserDefaults.standard.set(host, forKey: "host") } }
    @Published var port: String { didSet { UserDefaults.standard.set(port, forKey: "port") } }
    @Published var mode: JITMode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") } }
    @Published var apps: [RemoteApp] = []
    @Published var log: [String] = ["ready"]
    @Published var busy = false
    @Published var hasPairing = false
    @Published var needPin = false
    @Published var pin = ""
    @Published var serverOn = false
    @Published var serverInfo = ""

    var discovery: Discovery?
    private var pinBox: PinBox?
    private let server = HTTPServer()

    static var pairingURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rppairing.plist")
    }

    init() {
        let d = UserDefaults.standard
        host = d.string(forKey: "host") ?? ""
        port = d.string(forKey: "port") ?? ""
        mode = JITMode(rawValue: d.string(forKey: "mode") ?? "") ?? .attachOnly
        refreshPairing()
    }

    // MARK: Pairing file

    func refreshPairing() {
        let fm = FileManager.default
        let docs = Self.pairingURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: Self.pairingURL.path),
           let found = (try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension.lowercased() == "plist" }) {
            try? fm.moveItem(at: found, to: Self.pairingURL)
            add("adopted \(found.lastPathComponent) as pairing file")
        }
        hasPairing = fm.fileExists(atPath: Self.pairingURL.path)
    }

    func add(_ line: String) { log.append(line); if log.count > 200 { log.removeFirst() } }

    func importPairing(from src: URL) {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        do {
            try? FileManager.default.removeItem(at: Self.pairingURL)
            try FileManager.default.copyItem(at: src, to: Self.pairingURL)
            add("pairing file imported")
        } catch { add("import failed: \(error.localizedDescription)") }
        refreshPairing()
    }

    func deletePairing() {
        try? FileManager.default.removeItem(at: Self.pairingURL)
        refreshPairing()
        add("pairing file removed")
    }

    func use(_ d: FoundDevice) { host = d.host; port = String(d.port) }

    func submitPin(cancel: Bool) {
        pinBox?.pin = cancel ? "" : pin
        pinBox?.semaphore.signal()
        needPin = false
        pin = ""
    }

    // MARK: Connecting

    private func makeRemote(host h: String, port p: UInt16) -> RemoteJIT {
        let box = PinBox()
        box.onNeedPin = { [weak self] in Task { @MainActor in self?.needPin = true } }
        pinBox = box
        let config = RemoteConfig(host: h, port: p, pairingPath: Self.pairingURL.path,
                                  hostname: UIDevice.current.name)
        return RemoteJIT(config: config, pinBox: box)
    }

    /// Runs a blocking FFI call off the main thread and gives up after `timeout` seconds.
    nonisolated private static func attempt<T>(timeout: TimeInterval,
                                               _ op: @escaping () throws -> T) -> Result<T, Error>? {
        let lock = NSLock()
        var outcome: Result<T, Error>?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let r = Result { try op() }
            lock.lock(); outcome = r; lock.unlock()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut { return nil }
        lock.lock(); defer { lock.unlock() }
        return outcome
    }

    /// Tries the saved endpoint; if it fails, rescans Bonjour for the same IP (the port rotates) and retries.
    private func run<T>(timeout: TimeInterval = 30, _ op: @escaping (RemoteJIT) throws -> T) async throws -> T {
        var candidates: [(String, UInt16)] = []
        if let p = UInt16(port), !host.isEmpty { candidates.append((host, p)) }
        var lastError: Error = RemoteError.message("enter the target IP first")
        for round in 0..<2 {
            for (h, p) in candidates {
                let remote = makeRemote(host: h, port: p)
                let result = await Task.detached { Model.attempt(timeout: timeout) { try op(remote) } }.value
                switch result {
                case .success(let value)?:
                    host = h; port = String(p)
                    return value
                case .failure(let error)?:
                    lastError = error
                case nil:
                    lastError = RemoteError.message("timed out (\(Int(timeout))s) at \(h):\(p)")
                }
            }
            guard round == 0, !host.isEmpty, let discovery else { break }
            add("rescanning for \(host)…")
            discovery.start()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            candidates = discovery.found.filter { $0.host == host }.map { ($0.host, $0.port) }
            if candidates.isEmpty { break }
        }
        throw lastError
    }

    private func refreshApps() async throws {
        apps = try await run { try $0.listApps() }
    }

    private func enableJIT(_ app: RemoteApp) async throws {
        let mode = self.mode
        try await run(timeout: 90) { remote in
            try remote.enableJIT(app: app, mode: mode) { line in
                Task { @MainActor in self.add(line) }
            }
        }
    }

    // MARK: UI actions

    func loadApps() {
        guard !busy else { return }
        busy = true; add("connecting to \(host):\(port)…")
        Task {
            do { try await refreshApps(); add("found \(apps.count) apps") }
            catch { add("error: \(error.localizedDescription)") }
            busy = false; refreshPairing()
        }
    }

    func enable(_ app: RemoteApp) {
        guard !busy else { return }
        busy = true; add("enabling JIT for \(app.name)…")
        Task {
            do { try await enableJIT(app); add("done: \(app.name)") }
            catch { add("error: \(error.localizedDescription)") }
            busy = false
        }
    }

    /// Diagnostic: try every discovered endpoint and log each result.
    func tryAll(_ devices: [FoundDevice]) {
        guard !busy else { return }
        let sameIP = devices.filter { $0.host == host }
        let list = sameIP.isEmpty ? devices : sameIP
        guard !list.isEmpty else { add("scan first"); return }
        busy = true
        add("trying \(list.count) endpoint(s)…")
        Task {
            for d in list {
                add("-> \(d.host):\(d.port) [\(d.name.prefix(8))]")
                let remote = makeRemote(host: d.host, port: d.port)
                let result = await Task.detached { Model.attempt(timeout: 30) { try remote.listApps() } }.value
                switch result {
                case .success(let found)?:
                    host = d.host; port = String(d.port)
                    apps = found; add("OK: \(found.count) apps via port \(d.port)")
                    busy = false; refreshPairing()
                    return
                case .failure(let error)?: add("   failed: \(error.localizedDescription)")
                case nil: add("   timed out after 30s (handshake hung)")
                }
            }
            add("no endpoint worked"); busy = false; refreshPairing()
        }
    }

    // MARK: SideJITServer-compatible HTTP API

    func toggleServer(_ on: Bool) {
        if on {
            server.onRequest = { [weak self] path in
                await self?.handle(path: path) ?? (500, "{\"ERROR\":\"gone\"}")
            }
            do {
                try server.start(port: 8080)
                serverOn = true
                UIApplication.shared.isIdleTimerDisabled = true
                serverInfo = "http://\(Self.localIP()):8080/  (keep this app open)"
                add("server started on 8080")
            } catch { add("server failed: \(error.localizedDescription)"); serverOn = false }
        } else {
            server.stop()
            serverOn = false
            UIApplication.shared.isIdleTimerDisabled = false
            add("server stopped")
        }
    }

    private func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func appDict(_ list: [RemoteApp]) -> [[String: Any]] {
        list.map { ["name": $0.name, "bundle": $0.id, "pid": -1] }
    }

    func handle(path rawPath: String) async -> (Int, String) {
        add("GET \(rawPath)")
        let clean = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawPath
        let parts = clean.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }

        if parts.isEmpty {
            guard !host.isEmpty else { return (200, jsonString(["ERROR": "Could not find any device!"])) }
            return (200, jsonString(["iPhone (\(host))": Self.udid]))
        }
        if parts == ["ver"] { return (200, jsonString(["JITRemote": "1.0"])) }
        if busy { return (503, jsonString(["ERROR": "busy, try again"])) }

        busy = true
        defer { busy = false }
        do {
            if parts == ["re"] {
                try await refreshApps()
                return (200, jsonString(["OK": "Refreshed!"]))
            }
            guard parts[0] == Self.udid else { return (404, jsonString(["ERROR": "Invalid path or could not find device!"])) }
            if apps.isEmpty { try await refreshApps() }

            if parts.count == 1 {
                let dev = apps.filter { $0.isDeveloper }
                return (200, jsonString(appDict(dev.isEmpty ? apps : dev)))
            }
            switch parts[1] {
            case "all_apps":
                return (200, jsonString(appDict(apps)))
            case "re":
                try await refreshApps()
                return (200, jsonString(["OK": "Refreshed app list!"]))
            default:
                let wanted = parts[1]
                guard let app = apps.first(where: { $0.name == wanted || $0.id == wanted })
                        ?? apps.first(where: { $0.name.lowercased() == wanted.lowercased() }) else {
                    return (200, jsonString("Could not find '\(wanted)'!"))
                }
                try await enableJIT(app)
                return (200, jsonString("Enabled JIT for '\(app.name)'!"))
            }
        } catch {
            add("error: \(error.localizedDescription)")
            return (500, jsonString(["ERROR": error.localizedDescription]))
        }
    }

    static func localIP() -> String {
        var result = "?"
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = ptr.pointee
            guard let sa = item.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  String(cString: item.ifa_name) == "en0" else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                result = String(cString: buffer)
            }
        }
        return result
    }
}
