import SwiftUI

struct PairingView: View {
    @EnvironmentObject private var client: BackendClient
    @Environment(\.dismiss) private var dismiss

    let device: DeviceInfo

    @State private var session: PairStartResponse?
    @State private var pin: String = ""
    @State private var status: String = "Starting…"
    @State private var error: String?
    @State private var busy = false
    @State private var done = false
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text(status)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                    if let s = session, !done {
                        if s.needsPin == true {
                            Text("Look at your Apple TV — a 4-digit PIN should appear for **\(s.protocolName ?? "")**. Type it below.")
                                .font(.system(size: 14))
                                .foregroundColor(Theme.text)
                        } else {
                            Text("**\(s.protocolName ?? "")** doesn't display a PIN. Press Continue.")
                                .font(.system(size: 14))
                                .foregroundColor(Theme.text)
                        }
                    } else if done {
                        Text("Paired \((session?.pairedProtocols ?? []).joined(separator: ", ")).")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.text)
                    }
                    if session?.needsPin == true && !done {
                        TextField("PIN", text: $pin)
                            .disableAutocorrection(true)
                            .font(.system(size: 20).monospacedDigit())
                            .multilineTextAlignment(.center)
                            .padding(12)
                            .background(Theme.surface2)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .onSubmit { submit() }
                    }
                    progressChips
                    if let err = error {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.danger)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.danger.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.danger.opacity(0.35), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button(done ? "Close" : "Cancel") {
                            cancel()
                        }
                        .buttonStyle(SurfaceButton())
                        Button {
                            if done { connectAfterPair() } else { submit() }
                        } label: {
                            Group {
                                if connecting {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .controlSize(.small)
                                        .tint(.white)
                                } else {
                                    Text(done ? "Connect now" : (session?.needsPin == true ? "Submit PIN" : "Continue"))
                                }
                            }
                            .frame(minWidth: 80)
                        }
                        .buttonStyle(PrimaryButton())
                        .disabled(busy || connecting || (session == nil && !done))
                    }
                }
                .padding(18)
            }
            .navigationTitle(done ? "Paired \(session?.name ?? device.name)" : "Pair \(device.name)")
        }
        .preferredColorScheme(.dark)
        .task { await start() }
    }

    private struct Chip: Identifiable {
        let id = UUID()
        let label: String
        let tag: String
    }

    private var chips: [Chip] {
        var result: [Chip] = []
        for p in session?.completed ?? [] { result.append(Chip(label: p, tag: "done")) }
        if let p = session?.protocolName { result.append(Chip(label: p, tag: "current")) }
        for f in session?.failed ?? [] { result.append(Chip(label: f.protocol, tag: "fail")) }
        for p in session?.remaining ?? [] { result.append(Chip(label: p, tag: "pending")) }
        return result
    }

    private var progressChips: some View {
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                Text(chip.label)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(color(for: chip.tag).opacity(0.18))
                    .foregroundColor(color(for: chip.tag))
                    .clipShape(Capsule())
            }
            Spacer()
        }
    }

    private func color(for tag: String) -> Color {
        switch tag {
        case "done": return Theme.good
        case "current": return Theme.accent
        case "fail": return Theme.danger
        default: return Theme.muted
        }
    }

    private func start() async {
        do {
            let s = try await client.pairStart(identifier: device.identifier)
            session = s
            updateStatus(from: s)
        } catch {
            self.error = "Couldn't start pairing: \(error.localizedDescription)"
        }
    }

    private func submit() {
        guard let s = session, let sid = s.sessionId else { return }
        busy = true
        error = nil
        Task {
            do {
                let next = try await client.pairSubmit(sessionId: sid, pin: pin)
                pin = ""
                session = next
                updateStatus(from: next)
                if next.done == true { done = true }
            } catch let e {
                self.error = e.localizedDescription
            }
            busy = false
        }
    }

    private func updateStatus(from r: PairStartResponse) {
        let completed = r.completed?.count ?? 0
        let failed = r.failed?.count ?? 0
        let remaining = r.remaining?.count ?? 0
        let total = completed + failed + (r.protocolName != nil ? 1 : 0) + remaining
        if r.done == true {
            status = "Done — paired \((r.pairedProtocols ?? []).joined(separator: ", "))"
        } else if let p = r.protocolName {
            status = "Step \(completed + failed + 1) of \(total) — \(p)"
        }
    }

    private func cancel() {
        if let sid = session?.sessionId, !done {
            Task { await client.pairCancel(sessionId: sid) }
        }
        dismiss()
    }

    private func connectAfterPair() {
        guard let identifier = session?.identifier ?? session?.identifier else { dismiss(); return }
        let connectDevice = DeviceInfo(identifier: identifier, name: session?.name ?? device.name,
                                       address: device.address, model: device.model,
                                       services: device.services, isPaired: true)
        connecting = true
        Task {
            let ok = (try? await client.connect(to: connectDevice)) != nil
            connecting = false
            if ok { dismiss() }
        }
    }
}
