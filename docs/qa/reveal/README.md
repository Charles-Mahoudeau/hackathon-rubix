# Planet reveal and tier progression: runtime evidence (GR5-105)

Real AYLO runtime captures, produced by `tools/map_capture.py` (`DebugConfig.mapTour = true`, a scripted tour in
`scripts/client/map_tour.luau`). Purchases in the tour are real `sim:buyUpgrade` calls; only the starting credits and lifetime
revenue are granted as controlled debug setup (no module, ship, branch or knowledge is granted). Frames are the 1280 px wide
window (1280x720 content plus the 32 px macOS title bar). The feed header shows `[QA nn step t=x.xx]`, where `t` is the reveal
timeline in seconds. Capture is ~2.4-9 fps depending on load; `t` values below are read from the capture clock (sim runs x1).

## Tier states, before / after

| Tier | Frames |
|---|---|
| T1 (Kessa only) | `t1-start` |
| T2 (revenue 1500, Engine Mk2 lights Varn) | `t2-before`, then `t2-after-mk2` (sequence below) |
| T3 (warehouse; tier cue) | `t3-warehouse-tier-cue`, `t3-before-mk3`, `t3-after-mk3` (Ashfall lit, Lumen still locked: Mk3 alone is not enough) |
| T4 (logistics hub; tier cue) | `t4-hub-tier-cue`, `t4-before-deepnav`, `t4-after-deepnav` (Mk3 + Deep-range nav lights Lumen) |
| T5 (command center) | `t5-command-center` |

## Timed frame sequence: Varn (Engine Mk2), 2.0 s

`seq-varn-a` t=0.17 (dim only) · `seq-varn-b` t=0.50 (burst fired at 0.3 s, ring growing, locked label still shown) ·
`seq-varn-c` t=0.85 (ring fading, label crossfade begins) · `seq-varn-d` t=1.18 · `seq-varn-e` t=1.50 (revealed label, panel
backing fading) · `seq-varn-f` t=1.84 · `seq-varn-g` t=1.95 (plain map again).

## Simultaneous unlocks (Mk3 lights Ashfall and Lumen together, Deep-range nav owned first)

`simul-before`, then `simul-a` t=0.06 (Ashfall starts) · `simul-b` t=0.70 · `simul-c` t=1.38 · `simul-d` t=0.18 (Lumen
starts after Ashfall's 2.0 s, Ashfall already revealed) · `simul-e` t=1.58 · `simul-after`. One reveal and one burst per planet,
in map order, never overlapping.

## Reload / hydration

`reload-hydration`: a fresh sim loaded already at T4 with every planet reachable. No reveal plays, no burst, no tier cue
(`Audio.firstSight` drops the loaded sim's event backlog; `Reveal.observe` records the first sight of a sim as baseline).

## Leaving the map mid-reveal

`exit-before` -> `exit-mid-reveal` (t=0.31, ring about to start) -> `exit-agents-screen` (left for Agents) -> `exit-back-on-map`:
the queue is dropped when the Map is left, nothing replays on return, Varn is simply lit.

## Reduced motion (`Vfx.reveal.reducedMotion = true`)

`reduced-before` -> `reduced-a` t=0.07 / `reduced-b` t=0.20 / `reduced-c` t=0.34 (static outline, final label at once, no dim,
no ring, no burst) -> `reduced-after` (outline gone after 0.5 s).

## What is verified and how

| Behavior | Evidence |
|---|---|
| Reveal fires only on reachability false->true, not on hydration | `tests/test_reveal.luau`, `reload-hydration` |
| Distinct events queue, one burst each, in map order | `tests/test_reveal.luau`, `simul-*` |
| Equipment gates independent (Lumen needs Mk3 + Deep-range nav) | `tests/test_reveal.luau`, `t3-after-mk3`, `t4-after-deepnav` |
| No module/ship/branch/knowledge granted by a reveal | `tests/test_reveal.luau` (counts unchanged around the purchases) |
| Tier cue only from the sim's `tier_up` event; a planet unlock alone is silent; reload does not replay | `tests/test_reveal.luau` |
| Mute silences the tier cue | `tests/test_reveal.luau` (headless via `Audio.setMuted`) |
| GR5-100 burst fires once per reveal, honors its cooldown | `tests/test_reveal.luau`, `seq-varn-b` |
| Map exit mid-reveal, reload, reduced motion | frames above + tests |
| Tour is real-sim driven | `tests/test_map_tour.luau` |

## Limits

- **No camera.** The AYLO engine has no camera or viewport transform, so there is no pan/zoom nudge toward the revealed planet;
  everything is drawn through `Shell.mapPoint`. Bounds are respected because nothing moves. See `DECISIONS.md`.
- **No "planet unlocked" sim event.** Reachability is derived from `Model.map(sim)` each frame (`lit`), diffed by
  `render/vfx/reveal.luau`; the sim stays UI-free. Unlocks that happen while another screen is open are silent on purpose.
- **Audio was not auditioned.** The agent runtime has no audio device; the sound rules are asserted headless, not heard.
- The window in some frames shows grey traffic lights (unfocused capture); this does not affect content.
