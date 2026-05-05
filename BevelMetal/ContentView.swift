import SwiftUI
import UIKit

struct ContentView: View {
    @State private var bevelWidth: BevelWidth = .medium
    /// Live slider value — bound to the Slider, redrawn at every tick.
    @State private var kernLive:      Double = 5
    /// Committed value that's actually pushed to the Metal view; only updated
    /// when the user releases the slider, so the SDF rebuild only fires once
    /// per drag instead of 60+ times.
    @State private var kernCommitted: CGFloat = 5
    @State private var borderShadow = Color(red: 0.32, green: 0.32, blue: 0.36)
    @State private var borderLit    = Color(red: 1.00, green: 1.00, blue: 1.00)
    @State private var faceColor    = Color(red: 0.84, green: 0.84, blue: 0.86)

    let font: UIFont = .systemFont(ofSize: 260, weight: .semibold)

    var body: some View {
        ZStack(alignment: .topLeading) {
            BevelMetal(
                text: "$2,000",
                font: font,
                kern: kernCommitted,
                bevelWidth: bevelWidth,
                borderShadowColor: borderShadow.rgbFloat3,
                borderLitColor:    borderLit.rgbFloat3,
                faceColor:         faceColor.rgbFloat3
            )
            .ignoresSafeArea()
            .background(Color(white: 0.05))

            controls
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(16)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Bevel width", selection: $bevelWidth) {
                Text("Thin").tag(BevelWidth.thin)
                Text("Medium").tag(BevelWidth.medium)
                Text("Heavy").tag(BevelWidth.heavy)
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Kern (rebuilds)")
                Slider(
                    value: $kernLive,
                    in: -30...80,
                    onEditingChanged: { editing in
                        if !editing { kernCommitted = CGFloat(kernLive) }
                    }
                )
                Text("\(Int(kernLive))").monospacedDigit().frame(width: 32, alignment: .trailing)
            }

            ColorPicker("Bevel — shadow side", selection: $borderShadow, supportsOpacity: false)
            ColorPicker("Bevel — lit side",    selection: $borderLit,    supportsOpacity: false)
            ColorPicker("Face fill",            selection: $faceColor,    supportsOpacity: false)
        }
        .frame(maxWidth: 280)
        .font(.footnote)
    }
}

struct BevelMetal: UIViewRepresentable {
    let text: String
    var font: UIFont = .systemFont(ofSize: 260, weight: .heavy)
    var kern: CGFloat = 0
    var bevelWidth: BevelWidth = .medium
    var borderShadowColor: SIMD3<Float> = SIMD3(0.32, 0.32, 0.36)
    var borderLitColor:    SIMD3<Float> = SIMD3(1.00, 1.00, 1.00)
    var faceColor:         SIMD3<Float> = SIMD3(0.84, 0.84, 0.86)

    func makeUIView(context: Context) -> BevelMetalView {
        let view = BevelMetalView(frame: .zero, device: nil)
        apply(to: view)
        return view
    }

    func updateUIView(_ view: BevelMetalView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: BevelMetalView) {
        if view.text              != text              { view.text              = text }
        if view.labelFont         != font              { view.labelFont         = font }
        if view.kern              != kern              { view.kern              = kern }
        if view.bevelWidth        != bevelWidth        { view.bevelWidth        = bevelWidth }
        if view.borderShadowColor != borderShadowColor { view.borderShadowColor = borderShadowColor }
        if view.borderLitColor    != borderLitColor    { view.borderLitColor    = borderLitColor }
        if view.faceColor         != faceColor         { view.faceColor         = faceColor }
    }
}

private extension Color {
    /// SwiftUI `Color` → linear-display RGB packed as `SIMD3<Float>` for the
    /// shader's color uniforms. Goes through `UIColor` so any color the user
    /// can pick in `ColorPicker` is supported.
    var rgbFloat3: SIMD3<Float> {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(Float(r), Float(g), Float(b))
    }
}

#Preview {
    ContentView()
}
