# BevelMetal

Beveled, light-reactive metallic text rendered with a Metal SDF shader.

![demo](img/bevel_demo.gif)

## How it works

1. **Rasterize** the text into a bitmap via Core Text.
2. **Turn it into a signed distance field** — every pixel knows its distance to the nearest glyph edge (positive inside, negative outside) using the 8-point sequential Euclidean distance transform (8SSEDT). Sub-pixel boundary accuracy is recovered from the AA gray ramp of the rasterized glyph as `(α − 0.5) / |∇α|`, then the field is smoothed with `MPSImageGaussianBlur` to dissolve the polygon iso-line spokes that any pixel-quantized distance transform leaves behind.
3. **Shade in the fragment shader.** The distance picks where the layers live (drop shadow → outer beveled border → flat face). The *direction* of the distance gradient (`dfdx`/`dfdy`) is the surface's outward-facing direction at that pixel, dotted against a light vector to slide the bevel band from dark on one side of every glyph to bright on the other.

## Knobs

A SwiftUI control panel on the screen lets you tweak everything live; the text only re-rasterizes when properties that affect the SDF (text, font, kern) change. Color and light changes are uniform-only and run at 60 fps.

| Control     | What it does                                                                |
|-------------|-----------------------------------------------------------------------------|
| Bevel width | Thin / Medium / Heavy preset for the contour band                           |
| Kern        | Per-character extra spacing, in font points                                 |
| Bevel — shadow | Color used on the away-from-light side of the bevel                      |
| Bevel — lit | Color used on the toward-the-light side of the bevel                        |
| Face fill   | Flat color of the glyph interior                                            |
| Light pad   | Drag the circle in the box (bottom-right) to move the light around the text |

The SDF rebuild runs on a background queue with a generation-counter so quick parameter changes never apply a stale texture, and an activity spinner shows while a rebuild is in flight.

## Files

- `BevelMetal/Bevel.metal` — vertex + fragment shader. Layered compositing on the SDF plus inner-edge lighting from the SDF gradient.
- `BevelMetal/SDF8SSEDT.swift` — 8-point sequential signed Euclidean distance transform.
- `BevelMetal/BevelMetalView.swift` — `MTKView` subclass. Owns the SDF generation pipeline (CT rasterizer → 8SSEDT → AA refinement → MPS blur), the render pipeline, and the light panner.
- `BevelMetal/ContentView.swift` — SwiftUI `UIViewRepresentable` wrapper + control panel.

## Build

Open `BevelMetal.xcodeproj` and run on an iOS Simulator or device (iOS 17+). Release builds are noticeably faster on the SDF rebuild step than Debug — the 8SSEDT loop is hot.
