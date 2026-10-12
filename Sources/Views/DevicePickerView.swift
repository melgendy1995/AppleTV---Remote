import SwiftUI

struct DevicePickerView: View {
    @EnvironmentObject private var client: BackendClient
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var confirmUnpairFor: DeviceInfo?
    @State private var connectingTo: String?
    @State private var manualHost: String = ""
    @State private var addingHost: Bool = false
    @State private var manualHostError: String?

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

                        manualHostSection
                            .padding(.top, 12)
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
                    Button { scan(clearing: true) } label: { Text("Rescan") }
                        .disabled(scanning)
                }
            }
        }
        .task {
            // Show paired devices from saved credentials immediately; the
            // background scan refines the list when it finishes.
            client.seedDevicesFromSaved()
            scan()
        }
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
                .background(device.isPaired ? Theme.surface2 : Theme.border)
                .foregroundColor(device.isPaired ? Theme.good : Theme.muted)
                .clipShape(Capsule())
            if client.isConnectedDevice(device) {
                Text("✓ Connected")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.good)
                    .padding(.horizontal, 12).padding(.vertical, 7)
            } else {
            Button {
                if device.isPaired {
                    connect(device)
                } else {
                    onPair(device)
                }
            } label: {
                Group {
                    if connectingTo == device.identifier {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Text(device.isPaired ? "Connect" : "Pair")
                    }
                }
                .frame(minWidth: 56)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(device.isPaired ? .white : Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .contentShape(Capsule())
            .glassCapsule(tint: device.isPaired ? Theme.accent : nil)
            .buttonStyle(.plain)
            .disabled(connectingTo != nil)
            }

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
        .glassCard(cornerRadius: 12)
    }

    @ViewBuilder
    private var manualHostSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Not seeing your Apple TV?")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.muted)
            Text("Discovery can miss devices when a VPN captures the multicast route or the Apple TV is on a different subnet. Add it by IP or `.local` hostname.")
                .font(.system(size: 11))
                .foregroundColor(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("192.168.1.42 or apple-tv.local", text: $manualHost)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .onSubmit { addByHost() }
                Button {
                    addByHost()
                } label: {
                    Group {
                        if addingHost {
                            ProgressView().progressViewStyle(.circular).controlSize(.small).tint(.white)
                        } else {
                            Text("Add")
                        }
                    }
                    .frame(minWidth: 44)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .contentShape(Capsule())
                .glassCapsule(tint: Theme.accent)
                .buttonStyle(.plain)
                .disabled(addingHost || manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let err = manualHostError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.danger)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 12)
    }

    private func addByHost() {
        let host = manualHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !addingHost else { return }
        manualHostError = nil
        addingHost = true
        Task {
            do {
                let found = try await client.addDeviceByHost(host)
                if found.isEmpty {
                    manualHostError = "No Apple TV found at \(host)."
                } else {
                    manualHost = ""
                }
            } catch {
                manualHostError = error.localizedDescription
            }
            addingHost = false
        }
    }

    private func scan(clearing: Bool = false) {
        // A manual rescan wipes the list first so the loader is visible and
        // stale (possibly off-network) rows don't linger while scanning.
        if clearing { client.devices = [] }
        scanning = true
        Task {
            // 5s is plenty on a healthy LAN and keeps the picker responsive;
            // the main app flows still use the default 12s scan.
            await client.scan(timeout: 5)
            scanning = false
        }
    }

    private func connect(_ device: DeviceInfo) {
        connectingTo = device.identifier
        Task {
            let ok = (try? await client.connect(to: device)) != nil
            connectingTo = nil
            if ok { dismiss() }
        }
    }
}
