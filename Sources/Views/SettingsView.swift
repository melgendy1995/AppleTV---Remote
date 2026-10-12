import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var client: BackendClient
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var error: String?
    @AppStorage(CaptureCoordinator.previewFPSDefaultsKey) private var previewFPS = 30

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text("Backend URL")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                    TextField("http://localhost:8000", text: $draft)
                        .disableAutocorrection(true)
                        .font(.system(size: 15).monospaced())
                        .padding(12)
                        .glassCard(cornerRadius: 10)

                    Text("Examples: `http://localhost:8000`, `http://192.168.1.20:8000`. Use the LAN IP of the machine running the FastAPI backend.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)

                    Text("Preview frame rate")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                    Picker("Preview frame rate", selection: $previewFPS) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Applies to the live preview and to recordings without reconnecting.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)

                    if let r = testResult {
                        Text(r).font(.system(size: 12)).foregroundColor(Theme.muted)
                    }
                    if let e = error {
                        Text(e).font(.system(size: 12)).foregroundColor(Theme.danger)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button("Test connection") { Task { await test() } }
                            .buttonStyle(SurfaceButton())
                            .disabled(testing)
                        Button("Save") { save() }
                            .buttonStyle(PrimaryButton())
                    }
                }
                .padding(18)
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { draft = client.backendURLString }
    }

    private func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        guard URL(string: s) != nil else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func save() {
        error = nil
        guard let normalized = normalize(draft) else {
            error = "Not a valid URL."
            return
        }
        client.backendURLString = normalized
        Task {
            client.closeWebSocket()
            await client.refreshStatus()
            dismiss()
        }
    }

    private func test() async {
        testResult = nil
        error = nil
        guard let normalized = normalize(draft), let base = URL(string: normalized) else {
            error = "Not a valid URL."
            return
        }
        testing = true
        defer { testing = false }
        do {
            var req = URLRequest(url: base.appendingPathComponent("api/status"))
            req.timeoutInterval = 5
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                error = "HTTP error"
                return
            }
            if let s = try? JSONDecoder().decode(StatusResponse.self, from: data) {
                testResult = s.connected
                    ? "Reachable. Currently connected to \(s.identifier ?? "?")."
                    : "Reachable. Currently idle."
            } else {
                testResult = "Reachable."
            }
        } catch {
            self.error = "Could not reach backend: \(error.localizedDescription)"
        }
    }
}
