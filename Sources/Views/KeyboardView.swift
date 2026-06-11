import SwiftUI

struct KeyboardView: View {
    @EnvironmentObject private var client: BackendClient
    @Environment(\.dismiss) private var dismiss
    @Binding var autoOpened: Bool

    @State private var text: String = ""
    @State private var hint: String = "Type below — text appears on the Apple TV as you type."
    @State private var sendTimer: Task<Void, Never>?
    @State private var lastSent: String = ""
    @State private var suppressUntil: Date = .distantPast
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text(hint)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                    TextField("Type here", text: $text)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .disableAutocorrection(true)
                        .font(.system(size: 18))
                        .padding(12)
                        .background(Theme.surface2)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .focused($fieldFocused)
                        .onSubmit { submit() }
                        .onChange(of: text) { _, new in schedulePush(new) }
                    Spacer()
                    HStack(spacing: 8) {
                        Button("Clear field") { clear() }
                            .buttonStyle(SurfaceButton())
                        Button("Submit ⏎") { submit() }
                            .buttonStyle(PrimaryButton())
                    }
                }
                .padding(18)
            }
            .navigationTitle("Keyboard")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if let snap = await client.keyboardSnapshot() {
                text = snap.text ?? ""
                lastSent = text
                hint = snap.focused
                    ? "Text field active on the Apple TV — type below."
                    : "No text field focused. Type anyway; it'll go to whatever opens next."
            }
            fieldFocused = true
        }
        .onChange(of: client.keyboard) { _, new in
            // Sync field from TV side if not echoing our own writes.
            guard new.focused else { return }
            if Date() > suppressUntil, let t = new.text, t != lastSent {
                text = t
            }
        }
    }

    private func schedulePush(_ value: String) {
        sendTimer?.cancel()
        sendTimer = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            lastSent = value
            suppressUntil = Date().addingTimeInterval(0.75)
            await client.keyboardSet(value)
        }
    }

    private func submit() {
        sendTimer?.cancel()
        let value = text
        Task {
            await client.keyboardSet(value)
            await client.keyboardAppend("\n")
            dismiss()
        }
    }

    private func clear() {
        text = ""
        Task { await client.keyboardClear() }
        fieldFocused = true
    }
}
