import SwiftUI

@MainActor
final class Model: ObservableObject {
    @Published var host: String { didSet { UserDefaults.standard.set(host, forKey: "host") } }
    @Published var port: String { didSet { UserDefaults.standard.set(port, forKey: "port") } }
    @Published var mode: JITMode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") } }
    @Published var apps: [RemoteApp] = []
    @Published var log: [String] = ["ready"]
    @Published var busy = false
    @Published var hasPairing = false
    @Published var needPin = false
    @Published var pin = ""

    private var pinBox: PinBox?

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

    private func makeRemote() -> RemoteJIT? {
        guard let p = UInt16(port), !host.isEmpty else { add("enter IP and port first"); return nil }
        let box = PinBox()
        box.onNeedPin = { [weak self] in DispatchQueue.main.async { self?.needPin = true } }
        pinBox = box
        let config = RemoteConfig(host: host, port: p, pairingPath: Self.pairingURL.path,
                                  hostname: UIDevice.current.name)
        return RemoteJIT(config: config, pinBox: box)
    }

    func loadApps() {
        guard !busy, let remote = makeRemote() else { return }
        busy = true; add("connecting to \(host):\(port)…")
        Task.detached { [self] in
            do {
                let list = try remote.listApps()
                await MainActor.run { apps = list; add("found \(list.count) apps"); busy = false; refreshPairing() }
            } catch {
                await MainActor.run { add("error: \(error.localizedDescription)"); busy = false; refreshPairing() }
            }
        }
    }

    func enable(_ app: RemoteApp) {
        guard !busy, let remote = makeRemote() else { return }
        let mode = self.mode
        busy = true; add("enabling JIT for \(app.name)…")
        Task.detached { [self] in
            do {
                try remote.enableJIT(app: app, mode: mode) { line in
                    DispatchQueue.main.async { self.add(line) }
                }
                await MainActor.run { add("done: \(app.name)"); busy = false }
            } catch {
                await MainActor.run { add("error: \(error.localizedDescription)"); busy = false }
            }
        }
    }
}
