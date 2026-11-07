# DECISIONS

- 2026-11-07 — GR5-17 backgrounds: port Deep-Fold PixelSpace (GDScript→GLSL, palette-quantized output) as the primary path; fall back to a small set of pre-generated static backgrounds if the port stalls. Reason: matches the issue's stated priority; generator code is MIT and its generated images are free to use in games (not redistributable standalone), so either path is license-safe.
- 2026-11-07 — GR5-17 parallax: the OpenGameArt "Space Background 3" license could not be verified (page returned 403 to automated fetch). Do NOT ship its art until someone reads the license tag in a browser; if CC-BY, add to the credits screen. Parallax is deferred behind that check and behind the GR5-3 palette landing in the engine's shader reader.
