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

// MARK: - Liquid Glass

/// Glass background for cards, pills and buttons. Uses the native Liquid Glass
/// effect on macOS 26 (Tahoe); falls back to an ultra-thin material with a
/// hairline highlight on older systems. A `tint` colors the glass (accent,
/// danger, good); without one the glass is neutral.
struct GlassBackground<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color? = nil
    var interactive: Bool = false
    var isPressed: Bool = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else if let tint {
            content
                .background(tint.opacity(isPressed ? 0.7 : 1.0), in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.3), lineWidth: 1))
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var g: Glass = interactive ? .regular.interactive() : .regular
        if let tint { g = g.tint(tint.opacity(isPressed ? 0.8 : 0.45)) }
        return g
    }
}

extension View {
    /// Card/panel glass surface with a continuous rounded corner.
    func glassCard(cornerRadius: CGFloat = 14, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassBackground(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint, interactive: interactive))
    }

    /// Glass capsule background (pill buttons, status banners).
    func glassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        modifier(GlassBackground(shape: Capsule(), tint: tint, interactive: interactive))
    }

    /// Glass circle background (D-pad ring, select button).
    func glassCircle(tint: Color? = nil, interactive: Bool = true) -> some View {
        modifier(GlassBackground(shape: Circle(), tint: tint, interactive: interactive))
    }

    /// Glass background behind a button label (rounded rect, press-aware).
    func glassButton(tint: Color? = nil, cornerRadius: CGFloat = 14, isPressed: Bool = false) -> some View {
        modifier(GlassBackground(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint, interactive: true, isPressed: isPressed))
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
