# VFX references (GR5-22) — for Game Design Agent sanity-check

Written from general knowledge of these titles/techniques (no live links verified); please confirm vs art direction (concept doc §18).

1. **Neon bloom** — Technique: threshold -> downsampled gaussian blur (3 passes) -> additive composite, masked by a neon tag so only tagged pixels glow.
   - Cyberpunk 2077 / Tron: Evolution style UIs: thin bright lines on dark with soft additive halo.
   - Mindustry / Rebel Galaxy: bloom limited to emissive elements (lasers, engines), dark base.
   - Everything Unity/Unreal "selective bloom" (emissive mask) pattern.
2. **AI-error glitch** — Technique: ~0.35s burst: 2-frame hold, RGB channel split (~4px), horizontal slice displacement, faint scanlines, ease-out.
   - Cyberpunk 2077 hack/breach failure UI.
   - Alien: Isolation / Observation terminal-fault flicker.
   - Hacknet-style error flashes. Used only on error.
3. **Trade routes** — Technique: dashed polyline, dash offset scrolled over time when active; blue safe / orange risky.
   - Stellaris / Endless Space hyperlane + fleet lines.
   - Elite Dangerous galaxy map route plotting (orange route line).
   - Offworld Trading Company / Factorio logistics-overlay moving dots.
4. **Context halo** — Technique: ring around the card; idle = dim static, pending = amber slow pulse (1.5 Hz), executing = bright teal steady/larger.
   - Mass Effect / Destiny 2 UI "active ability" rings.
   - Voice-assistant "thinking" pulse (Siri/Alexa ring).
5. **Ship trail** — Technique: ring buffer of positions sampled every 50 ms, width and alpha fade with age, additive + bloom.
   - FTL / Homeworld engine trails; Rebel Galaxy.
