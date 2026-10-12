import SwiftUI

enum Theme {
    static let bg        = Color.black
    static let surface   = Color(red: 0.055, green: 0.055, blue: 0.063)
    static let surface2  = Color(red: 0.086, green: 0.086, blue: 0.102)
    static let border    = Color(red: 0.165, green: 0.165, blue: 0.192)
    static let accent    = Color(red: 0.039, green: 0.518, blue: 1.0)
    static let danger    = Color(red: 1.0, green: 0.271, blue: 0.227)
    static let good      = Color(red: 0.188, green: 0.820, blue: 0.345)
    static let muted     = Color(red: 0.549, green: 0.549, blue: 0.584)
    static let text      = Color(red: 0.953, green: 0.953, blue: 0.961)
}

// MARK: - Opaque surfaces

/// Solid fill behind cards, pills, and buttons. Blur and glass materials
/// sample whatever is behind them, so they stay out of the preview and sidebar.
struct OpaqueSurface<S: Shape>: ViewModifier {
    let shape: S
    let fill: Color
    var stroke: Color = Theme.border

    func body(content: Content) -> some View {
        content
            .background(fill, in: shape)
            .overlay(shape.stroke(stroke, lineWidth: 1))
    }
}

extension View {
    /// `tint` colors the border only; the fill stays opaque so it does not blur the preview.
    func glassCard(cornerRadius: CGFloat = 14, tint: Color? = nil) -> some View {
        modifier(OpaqueSurface(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            fill: Theme.surface,
            stroke: tint ?? Theme.border))
    }

    func glassCapsule(tint: Color? = nil) -> some View {
        modifier(OpaqueSurface(shape: Capsule(), fill: tint ?? Theme.surface))
    }

    func glassCircle(tint: Color? = nil) -> some View {
        modifier(OpaqueSurface(shape: Circle(), fill: tint ?? Theme.surface))
    }

    func glassButton(tint: Color? = nil, cornerRadius: CGFloat = 14, isPressed: Bool = false) -> some View {
        let fill = isPressed ? Theme.surface2 : (tint ?? Theme.surface)
        return modifier(OpaqueSurface(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            fill: fill))
    }
}

// MARK: - Button styles

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundColor(.white)
            .contentShape(Rectangle())
            .glassButton(tint: Theme.accent, isPressed: configuration.isPressed)
    }
}

struct SurfaceButton: ButtonStyle {
    var prominent: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: prominent ? .semibold : .regular))
            .frame(maxWidth: .infinity)
            .padding(.vertical, prominent ? 16 : 12)
            .foregroundColor(Theme.text)
            .contentShape(Rectangle())
            .glassButton(isPressed: configuration.isPressed)
    }
}

struct IconButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .frame(width: 36, height: 36)
            .foregroundColor(Theme.text)
            .contentShape(Rectangle())
            .glassButton(cornerRadius: 10, isPressed: configuration.isPressed)
    }
}
