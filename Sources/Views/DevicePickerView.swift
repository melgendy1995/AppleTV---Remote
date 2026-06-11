import SwiftUI

struct DevicePickerView: View {
    @EnvironmentObject private var client: BackendClient
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var confirmUnpairFor: DeviceInfo?

    let onPair: (DeviceInfo) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 10) {
                        if scanning && client.devices.isEmpty {
                            ProgressView("Scanning…").tint(Theme.muted).foregroundColor(Theme.muted)
                                .padding(.top, 30)
                        } else if client.devices.isEmpty {
                            Text("No devices found.\nMake sure your Apple TV is on the same Wi-Fi as the backend.")
                                .multilineTextAlignment(.center)
                                .foregroundColor(Theme.muted)
                                .padding()
                        } else {
                            ForEach(client.devices) { device in
                                deviceRow(device)
                            }
                        }
                        Text("Click **Connect** on a paired device, or **Pair** to set up a new one.")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.muted)
                            .padding(.top, 8)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Apple TVs on your network")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { scan() } label: { Text("Rescan") }
                }
            }
        }
        .task { scan() }
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "Unpair \(confirmUnpairFor?.name ?? "")?",
            isPresented: Binding(
                get: { confirmUnpairFor != nil },
                set: { if !$0 { confirmUnpairFor = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmUnpairFor
        ) { device in
            Button("Unpair", role: .destructive) {
                Task { try? await client.forget(identifier: device.identifier) }
            }
            Button("Cancel", role: .cancel) { confirmUnpairFor = nil }
        } message: { _ in
            Text("Removes the saved credentials. You'll need to pair again to control this Apple TV.")
        }
    }

    private func deviceRow(_ device: DeviceInfo) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Text("\(device.address)\(device.model.map { " · \($0)" } ?? "")")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(device.isPaired ? "Paired" : "Not paired")
                .font(.system(size: 10).bold())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(device.isPaired ? Theme.good.opacity(0.2) : Theme.border)
                .foregroundColor(device.isPaired ? Theme.good : Theme.muted)
                .clipShape(Capsule())
            Button(device.isPaired ? "Connect" : "Pair") {
                if device.isPaired {
                    Task { try? await client.connect(to: device); dismiss() }
                } else {
                    onPair(device)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(device.isPaired ? .white : Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(device.isPaired ? Theme.accent : Theme.surface)
            .overlay(Capsule().stroke(device.isPaired ? Theme.accent : Theme.border, lineWidth: 1))
            .clipShape(Capsule())
            .buttonStyle(.plain)

            if device.isPaired {
                Menu {
                    Button("Unpair…", role: .destructive) {
                        confirmUnpairFor = device
                    }
                } label: {
                    Text("⋯")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Theme.muted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28, height: 28)
            }
        }
        .padding(12)
        .background(Theme.surface2)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func scan() {
        scanning = true
        Task {
            await client.scan()
            scanning = false
        }
    }
}
