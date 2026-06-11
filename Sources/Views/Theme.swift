import SwiftUI

enum Theme {
    static let bg        = Color(red: 0.039, green: 0.039, blue: 0.047)
    static let surface   = Color(red: 0.086, green: 0.086, blue: 0.102)
    static let surface2  = Color(red: 0.122, green: 0.122, blue: 0.145)
    static let border    = Color(red: 0.165, green: 0.165, blue: 0.192)
    static let accent    = Color(red: 0.039, green: 0.518, blue: 1.0)
    static let danger    = Color(red: 1.0, green: 0.271, blue: 0.227)
    static let good      = Color(red: 0.188, green: 0.820, blue: 0.345)
    static let muted     = Color(red: 0.549, green: 0.549, blue: 0.584)
    static let text      = Color(red: 0.953, green: 0.953, blue: 0.961)
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.7 : 1.0))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SurfaceButton: ButtonStyle {
    var prominent: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: prominent ? .semibold : .regular))
            .frame(maxWidth: .infinity)
            .padding(.vertical, prominent ? 16 : 12)
            .background(configuration.isPressed ? Theme.accent : Theme.surface2)
            .foregroundColor(configuration.isPressed ? .white : Theme.text)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(configuration.isPressed ? Theme.accent : Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct IconButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .frame(width: 36, height: 36)
            .background(configuration.isPressed ? Theme.surface2 : Theme.surface)
            .foregroundColor(Theme.text)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
