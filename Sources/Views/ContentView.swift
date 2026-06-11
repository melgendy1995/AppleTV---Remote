import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var client: BackendClient
    @State private var showDevicePicker = false
    @State private var showSettings = false
    @State private var showKeyboard = false
    @State private var keyboardAutoOpened = false
    @State private var pairingDevice: DeviceInfo?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 12) {
                topbar
                if !client.backendReachable {
                    backendBanner
                }
                NowPlayingCard()
                RemoteControlsView()
                    .disabled(!client.connected)
                    .opacity(client.connected ? 1 : 0.4)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: 460)
        }
        .preferredColorScheme(.dark)
        .onChange(of: client.keyboard) { _, new in handleKeyboardChange(new) }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
        }
        .sheet(isPresented: $showDevicePicker) {
            DevicePickerView(onPair: { device in
                showDevicePicker = false
                pairingDevice = device
            })
            .environmentObject(client)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(client)
        }
        .sheet(isPresented: $showKeyboard) {
            KeyboardView(autoOpened: $keyboardAutoOpened)
                .environmentObject(client)
        }
        .sheet(item: $pairingDevice) { device in
            PairingView(device: device)
                .environmentObject(client)
        }
    }

    private var topbar: some View {
        HStack(spacing: 8) {
            Button { showDevicePicker = true } label: { Text("⋮") }
                .buttonStyle(IconButton())
                .help("Devices")

            HStack(spacing: 8) {
                Circle()
                    .fill(client.connected ? Theme.good : Theme.muted)
                    .frame(width: 9, height: 9)
                    .shadow(color: client.connected ? Theme.good.opacity(0.6) : .clear, radius: 4)
                Text(client.connected ? (client.connectedDevice?.name ?? "Connected") : "Not connected")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { showKeyboard = true } label: { Text("⌨") }
                .buttonStyle(IconButton())
                .help("Keyboard")
                .disabled(!client.connected)

            Button { Task { await client.refreshPlaying(); await client.scan() } } label: { Text("↻") }
                .buttonStyle(IconButton())
                .help("Rescan")

            Button { showSettings = true } label: { Text("⚙") }
                .buttonStyle(IconButton())
                .help("Settings")
        }
    }

    private var backendBanner: some View {
        HStack {
            Text("Can't reach backend at \(client.backendURLString)")
                .font(.system(size: 12))
                .foregroundColor(Theme.danger)
            Spacer()
            Button("Settings") { showSettings = true }
                .font(.system(size: 12))
                .foregroundColor(Theme.danger)
                .buttonStyle(.plain)
        }
        .padding(10)
        .background(Theme.danger.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.danger.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func handleKeyboardChange(_ kb: KeyboardEvent) {
        if kb.focused {
            if !showKeyboard {
                keyboardAutoOpened = true
                showKeyboard = true
            }
        } else if keyboardAutoOpened {
            showKeyboard = false
            keyboardAutoOpened = false
        }
    }
}
