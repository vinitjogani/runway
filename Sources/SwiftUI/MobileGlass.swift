import Foundation
import RunwayCore

/// Translucent capsule material for the mobile chrome.
struct MobileGlassSurface: View, PrimitiveView {
    typealias Body = Never

    enum Material { case tabBar, toolbar, selection }

    let material: Material
    init(_ material: Material) { self.material = material }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let backend = ctx.host.backend
        let dark = ctx.env.colorScheme == .dark
        let opacity = ctx.env._opacity
        let tint = ctx.env._tint?.resolve(ctx.env)
        var props = WidgetProps()
        props.opacity = opacity
        switch material {
        case .tabBar: props.backdropBlur = BackdropBlur(radius: 14, cornerRadius: .infinity)
        case .toolbar: props.backdropBlur = BackdropBlur(radius: 10, cornerRadius: .infinity)
        case .selection: break
        }
        return [ShapeNode(widget: ctx.widget(.canvas, "surface"), backend: backend,
                          props: props, events: WidgetEvents()) { rect in
            material.surface(in: rect, dark: dark, tint: tint)
        }]
    }
}

private extension MobileGlassSurface.Material {
    func surface(in rect: CGRect, dark: Bool, tint: RGBA?) -> [DrawCommand] {
        guard !rect.isEmpty else { return [] }

        let fill: [RGBA]
        if dark {
            switch self {
            case .tabBar: fill = [RGBA(0.23, 0.24, 0.27, 0.89), RGBA(0.13, 0.14, 0.16, 0.76), RGBA(0.16, 0.17, 0.19, 0.84)]
            case .toolbar: fill = [RGBA(0.27, 0.28, 0.31, 0.72), RGBA(0.16, 0.17, 0.19, 0.58), RGBA(0.20, 0.21, 0.23, 0.70)]
            case .selection: fill = [RGBA.white.withAlpha(0.17), RGBA.white.withAlpha(0.11), RGBA.white.withAlpha(0.14)]
            }
        } else {
            switch self {
            case .tabBar: fill = [RGBA.white.withAlpha(0.91), RGBA(0.99, 0.995, 1, 0.73), RGBA.white.withAlpha(0.85)]
            case .toolbar: fill = [RGBA.white.withAlpha(0.76), RGBA(0.99, 0.995, 1, 0.53), RGBA.white.withAlpha(0.66)]
            case .selection: fill = [RGBA.black.withAlpha(0.082), RGBA.black.withAlpha(0.105), RGBA.black.withAlpha(0.073)]
            }
        }

        let path = glassCapsule(rect)
        let wash = glassGradient(fill, locations: [0, 0.46, 1])
        var commands: [DrawCommand] = [.fill(path, wash)]
        if self != .selection {
            // Put the highlight and lower edge on the same contour. An
            // inset highlight draws a second outline at high display scales.
            let edge = Paint.linearGradient(stops: [
                GradientStop(color: .white.withAlpha(dark ? 0.37 : 0.80), location: 0),
                GradientStop(color: .white.withAlpha(dark ? 0.15 : 0.23), location: 0.26),
                GradientStop(color: .black.withAlpha(dark ? 0.23 : 0.12), location: 0.50),
                GradientStop(color: .black.withAlpha(dark ? 0.16 : 0.035), location: 1),
            ], start: UnitPoint.top.point, end: UnitPoint.bottom.point)
            let contour = glassCapsule(rect.insetBy(dx: 0.4, dy: 0.4))
            commands.append(.stroke(contour, edge, lineWidth: 0.8, dash: []))
            return commands
        }

        if let tint {
            commands.append(.fill(path, .color(tint.multiplyingAlpha(0.035))))
        }

        let edge = RGBA.black.withAlpha(dark ? 0.25 : 0.075)
        let outerRim = glassCapsule(rect.insetBy(dx: 0.5, dy: 0.5))
        commands.append(.stroke(outerRim, .color(edge), lineWidth: 1, dash: []))

        let bright = RGBA.white.withAlpha(dark ? 0.37 : 0.83)
        let rest = RGBA.white.withAlpha(dark ? 0.065 : 0.28)
        let reflection = RGBA.white.withAlpha(dark ? 0.19 : 0.60)
        let rim = glassGradient([bright, rest, rest, reflection], locations: [0, 0.34, 0.72, 1], opacity: 0.42)
        let innerRim = glassCapsule(rect.insetBy(dx: 1.1, dy: 1.1))
        commands.append(.stroke(innerRim, rim, lineWidth: 0.6, dash: []))
        return commands
    }
}

private func glassCapsule(_ rect: CGRect) -> ShapePath {
    .roundedRect(rect, radius: min(rect.width, rect.height) / 2)
}

private func glassGradient(_ colors: [RGBA], locations: [Double], opacity: Double = 1) -> Paint {
    let stops = zip(colors, locations).map { GradientStop(color: $0.0.multiplyingAlpha(opacity), location: $0.1) }
    return .linearGradient(stops: stops, start: CGPoint(x: 0.18, y: 0), end: CGPoint(x: 0.82, y: 1))
}
