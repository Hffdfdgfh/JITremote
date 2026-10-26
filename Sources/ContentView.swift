import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = Model()
    @StateObject private var discovery = Discovery()
    @State private var importing = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section("Target device (Wi-Fi)") {
                    TextField("IPv4, e.g. 192.168.1.20", text: $model.host)
                        .keyboardType(.numbersAndPunctuation).autocapitalization(.none)
                    TextField("remotepairing port", text: $model.port)
                        .keyboardType(.numberPad)
                    Button(discovery.scanning ? "Stop scanning" : "Scan network (Bonjour)") {
                        discovery.scanning ? discovery.stop() : discovery.start()
                    }
                    ForEach(discovery.found) { d in
                        Button("\(d.name) — \(d.host):\(String(d.port))") { model.use(d) }
                    }
                }
                Section("Pairing") {
                    Text(model.hasPairing ? "pairing file present" : "none yet — a PIN pairing runs on first connect")
                        .font(.footnote).foregroundColor(.secondary)
                    Button("Import RemotePairing file") { importing = true }
                    if model.hasPairing { Button("Delete pairing file", role: .destructive) { model.deletePairing() } }
                }
                Section("JIT method") {
                    Picker("Method", selection: $model.mode) {
                        ForEach(JITMode.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("Apps") {
                    Button("Load apps") { model.loadApps() }.disabled(model.busy)
                    ForEach(model.apps) { app in
                        Button { model.enable(app) } label: {
                            VStack(alignment: .leading) {
                                Text(app.name)
                                Text(app.id + (app.isDeveloper ? "  •  dev" : ""))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }.disabled(model.busy)
                    }
                }
                Section("Log") {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.footnote, design: .monospaced))
                    }
                }
            }
            .navigationTitle("JITRemote")
        }
        .sheet(isPresented: $importing) {
            DocumentPicker(
                onPick: { url in model.importPairing(from: url); importing = false },
                onCancel: { importing = false })
            .ignoresSafeArea()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.refreshPairing() }
        }
        .alert("Enter PIN shown on target", isPresented: $model.needPin) {
            TextField("PIN", text: $model.pin).keyboardType(.numberPad)
            Button("Pair") { model.submitPin(cancel: false) }
            Button("Cancel", role: .cancel) { model.submitPin(cancel: true) }
        }
    }
}
