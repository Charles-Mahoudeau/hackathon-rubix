# Screenshot gallery: every screen on a T5 company (GR5-54)

Real AYLO runtime captures (1280 px content, shown at 1600 px wide) of the scripted QA tour (`DebugConfig.qaTour`, `scripts/client/qa_tour.luau`),
shot with `tools/qa_capture.sh`. Each file is the last frame of its tour step, matched by the `[QA nn step]` label in the feed header
(read back with macOS Vision OCR). The company is prepared by `Tour.prepare()`: T5, command center, Monitor, Logistician, salvage branch, a saved skill, 3 prompt versions.

| Screen | Frames |
|---|---|
| Map | `01-map`, `34-map-feed` |
| Agents (editor, examples, Context, JSON format) | `02`-`06` |
| Team | `07-team` |
| Logs (list, filters, errors, detail, compare) | `08`-`14` |
| Archive / Skill studio (list, record, form, suggestion, parameter, assign, running) | `15`-`23` |
| Monitor (order reaching the feed) / Alerts | `24`-`27` |
| Branches | `28-branches` |
| Offline "While you were away" modal | `29-offline` |
| Station, Market, Fleet, Missions | `30`-`33` |

Not in the tour: Shop, Debug, T1-T4 states (T1-T5 map progression is in `docs/qa/reveal/`).

## Findings

Fixed in this PR
- Market: the trend glyph column touched the longest rows ("...BEST-"). It now sits clear of them.
- Top bar: the speed buttons moved ~12 px as Reputation / Credits changed length. Both cells now have a minimum width.
- New lint rule (`Fit.check`, `tests/test_ui_lint.luau`): single-line texts on the same row may not run into each other.

Opened as issues (not fixed here)
- GR5-117 Agents editor: the Directive / Order text inputs are drawn under the shell panels (a stray "d" shows in the gap between the boxes).
- GR5-118 Map: station sprites sit on the Orbis Exchange and Meridian Institute labels.

Seen, not a defect: the Tools and Feed lists in the Agents editor are scroll boxes, so their last row is cut by design.
