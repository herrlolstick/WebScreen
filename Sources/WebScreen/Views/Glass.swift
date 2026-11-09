import SwiftUI

// Liquid Glass (macOS 26 “Tahoe”) with a clean fallback for older systems.
// `#if compiler(>=6.2)` keeps the project building with older Xcode versions;
// `#available` keeps the app running on macOS 14/15.

#if compiler(>=6.2)
@available(macOS 26.0, *)
private func makeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}
#endif

extension View {
    /// Liquid Glass background in any shape
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
        #else
        self.background(.regularMaterial, in: shape)
        #endif
    }

    /// Glass card with rounded corners
    func glassCard(cornerRadius: CGFloat = 22) -> some View {
        liquidGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Glass button (`.glass` / `.glassProminent`)
    func glassButton(prominent: Bool = false) -> some View {
        modifier(GlassButtonModifier(prominent: prominent))
    }
}

private struct GlassButtonModifier: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// Groups glass elements so they blend into each other like in macOS 26
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
