import SwiftUI

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
                    .fill(Theme.surface)
                    .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                VStack(spacing: 0) {
                    dpadButton("▲", command: "up", shortcut: .upArrow)
                    HStack(spacing: 0) {
                        dpadButton("◀", command: "left", shortcut: .leftArrow)
                        Button { send("select") } label: {
                            Circle()
                                .fill(Theme.surface2)
                                .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                                .overlay(Text("●").foregroundColor(Theme.muted).font(.system(size: 14)))
                                .frame(width: size * 0.30, height: size * 0.30)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return, modifiers: [])
                        dpadButton("▶", command: "right", shortcut: .rightArrow)
                    }
                    dpadButton("▼", command: "down", shortcut: .downArrow)
                }
                .frame(width: size, height: size)
            }
            .frame(width: geo.size.width, height: geo.size.width, alignment: .center)
        }
        .frame(maxWidth: 280)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private func dpadButton(_ label: String, command: String, shortcut: KeyEquivalent? = nil) -> some View {
        Button { send(command) } label: {
            Text(label)
                .font(.system(size: 22))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundColor(Theme.text)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .modifier(OptionalKeyboardShortcut(key: shortcut))
    }

    // MARK: - Rows

    private var menuRow: some View {
        Button { send("menu") } label: {
            Text("↩ Menu")
        }
        .buttonStyle(SurfaceButton(prominent: true))
        .keyboardShortcut(.escape, modifiers: [])
    }

    private var transportRow: some View {
        HStack(spacing: 8) {
            Button { send("previous") } label: { Text("⏮") }
                .buttonStyle(SurfaceButton())
                .keyboardShortcut("p", modifiers: [])
            Button { send("play_pause") } label: { Text("⏯") }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.space, modifiers: [])
            Button { send("next") } label: { Text("⏭") }
                .buttonStyle(SurfaceButton())
                .keyboardShortcut("n", modifiers: [])
        }
    }

    private var systemRow: some View {
        HStack(spacing: 8) {
            Button { send("home") } label: { Text("⌂ TV") }
                .buttonStyle(SurfaceButton())
                .keyboardShortcut("h", modifiers: [])
            Button { send("home_hold") } label: { Text("⌂⌂") }
                .buttonStyle(SurfaceButton())
        }
    }

    private func send(_ command: String) {
        Task { await client.sendCommand(command) }
    }
}

/// Applies a SwiftUI `.keyboardShortcut` only when a key is provided.
private struct OptionalKeyboardShortcut: ViewModifier {
    let key: KeyEquivalent?
    func body(content: Content) -> some View {
        if let k = key {
            content.keyboardShortcut(k, modifiers: [])
        } else {
            content
        }
    }
}
