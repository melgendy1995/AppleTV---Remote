import SwiftUI

/// The remote buttons. Keyboard shortcuts are NOT attached to these buttons:
/// they are handled by a window-level key monitor in AppDelegate so they keep
/// working while this sidebar is hidden (and never fire during text editing).
struct RemoteControlsView: View {
    @EnvironmentObject private var client: BackendClient

    var body: some View {
        VStack(spacing: 12) {
            dpad
            menuRow
            transportRow
            systemRow
        }
    }

    // MARK: - D-pad

    private var dpad: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, 280)
            ZStack {
                Circle()
                    .fill(.clear)
                    .glassCircle(interactive: false)
                VStack(spacing: 0) {
                    dpadButton("▲", command: "up")
                    HStack(spacing: 0) {
                        dpadButton("◀", command: "left")
                        Button { send("select") } label: {
                            Circle()
                                .fill(.clear)
                                .overlay(Text("●").foregroundColor(Theme.muted).font(.system(size: 14)))
                                .frame(width: size * 0.30, height: size * 0.30)
                                .glassCircle()
                        }
                        .buttonStyle(.plain)
                        dpadButton("▶", command: "right")
                    }
                    dpadButton("▼", command: "down")
                }
                .frame(width: size, height: size)
            }
            .frame(width: geo.size.width, height: geo.size.width, alignment: .center)
        }
        .frame(maxWidth: 280)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private func dpadButton(_ label: String, command: String) -> some View {
        Button { send(command) } label: {
            Text(label)
                .font(.system(size: 22))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundColor(Theme.text)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    // MARK: - Rows

    private var menuRow: some View {
        Button { send("menu") } label: {
            Text("↩ Menu")
        }
        .buttonStyle(SurfaceButton(prominent: true))
    }

    private var transportRow: some View {
        HStack(spacing: 8) {
            Button { send("previous") } label: { Text("⏮") }
                .buttonStyle(SurfaceButton())
            Button { send("play_pause") } label: { Text("⏯") }
                .buttonStyle(PrimaryButton())
            Button { send("next") } label: { Text("⏭") }
                .buttonStyle(SurfaceButton())
        }
    }

    private var systemRow: some View {
        HStack(spacing: 8) {
            Button { send("home") } label: { Text("⌂ TV") }
                .buttonStyle(SurfaceButton())
            Button { send("home_hold") } label: { Text("⌂⌂") }
                .buttonStyle(SurfaceButton())
        }
    }

    private func send(_ command: String) {
        Task { await client.sendCommand(command) }
    }
}
