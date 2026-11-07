# Space background (GR5-17)

Status: plan only. This repo has no shader reader yet and the 8-color palette (GR5-3) is not defined, so no shader was written blind.

## Source and license
- Deep-Fold PixelSpace: https://github.com/Deep-Fold/PixelSpace (GDScript/Godot). Code is MIT. Generated images may be used in games or other projects, but must not be distributed standalone or in an asset pack. Credit is optional; list it in the credits screen anyway.
- OpenGameArt "Space Background 3": license UNVERIFIED (403 on fetch). Check before use.

## Plan
1. Port the star and nebula noise (fbm and dithering) to a GLSL fragment shader with inputs `seed`, `time` and a palette uniform.
2. Quantize the final color to the nearest of the 8 palette entries (the same ramp-remap as the planet shader), so no off-palette color reaches the screen.
3. Parallax: palette remap works per texture, so each layer is tinted independently with the same quantize pass. This should be feasible, but it needs confirming against the engine's shader reader (multi-layer, tiled scroll) once the engine exposes it. This is an [ENGINE] question.
4. Fallback: bake one static image per screen or planet offline, using the same palette.
