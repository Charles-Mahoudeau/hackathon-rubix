# Prompt library and practice challenges (GR5-107)

Source: GR5-102 `directive-library.md`. Data in `scripts/config/prompt_library.luau`, accessors in `scripts/sim/prompt_library.luau`, challenge fixtures in `scripts/sim/prompt_challenges.luau`, tests in `tests/test_prompt_library.luau`, measured table from `luau tools/prompt_library_report.luau`.

## What is loaded

- 3 examples (BAD / OK / GOOD) and a hint of at most 60 characters for each of the six roles (Miner, Logistician, Refiner, Salvager = scavenger, Raider = privateer, Monitor) and for missions 1-8.
- Every directive is validated against the 400-token limit (`Compute.estimateTokens`, `config/ai.luau`), every hint against 60 characters, every tool against the agent type's permitted tools (`PromptLibrary.validate`, run by the test).
- Branch roles (Refiner, Salvager, Raider) list nothing until their branch is open. Examples that use a tool the player does not have yet carry a `blocker` (`tier_locked`, `needs_scanner`, ...) so the UI can grey them out. Mission examples are listed only once the mission is not `locked`.
- Each example has `support = "stub"` (the stub AI reads the whole directive) or `"partial"` (an `unread` list names the clauses the stub ignores; they are design intent for the real model, not guaranteed behaviour).
- The eight canonical mission checks, rewards and unlock order in `config/missions.luau` are unchanged.

## Measured results (seeded, headless, quiet market; credits/min and Compute are measured)

Values are the challenge metric; "Compute" is what the run spent in its window.

| Challenge | Directive | Value | Target | Passed | Credits/min | Compute |
|---|---|---|---|---|---|---|
| 1 Repeatable orders | BAD | 1 | 3 | no | 162 | 9.7 |
| 1 Repeatable orders | OK | 4 | 3 | yes | 176 | 8.3 |
| 1 Repeatable orders | GOOD | 10 | 3 | yes | 200 | 7.6 |
| 2 Scan, then aim | BAD | 0 | 1 | no | 177 | 7.6 |
| 2 Scan, then aim | OK | 1 | 1 | yes | 336 | 6.9 |
| 2 Scan, then aim | GOOD | 1 | 1 | yes | 336 | 7.0 |
| 3 Think less | AI every trip | 2100 | 1000 | no (Compute over 3) | - | 5.5 |
| 3 Think less | OK | 1500 | 1000 | no (Compute over 3) | - | 7.6 |
| 3 Think less | GOOD (saved skill) | 2100 | 1000 | yes | - | 0.6 |
| 4 Name your buyer | BAD | 0 | 500 | no | - | 9.4 |
| 4 Name your buyer | OK | 600 | 500 | yes | - | 9.4 |
| 4 Name your buyer | GOOD | 600 | 500 | yes | - | 9.5 |
| 5 Recover without polling | BAD | 0 | 3 | no | - | 0.6 |
| 5 Recover without polling | OK | 3 | 3 | yes | - | 1.8 |
| 5 Recover without polling | GOOD | 3 | 3 | yes | - | 1.8 |

Each challenge has seed 1, a fixed window and a numeric target in config; results are identical on every run (tested).

## GDD reference figures (NOT measured, shown separately in the UI as "spec reference")

Kept as `specReference` strings in config: full-hold K1 skill trip 300 cr in 80 s (225 cr/min); K4 700 cr in 118 s (about 356 cr/min); four K1 sales 1,200 cr in about 320 s; Kessa HMC titanium 3 cr/unit so 1.5x = 4.5; 10 Compute is at most 400 cr at 40 cr/Compute. The sim measures about 200 cr/min on K1 and 336 on K4; the gap is expected (travel and decision time) and these are never mixed into the table above. No per-prompt Compute or income figure is claimed anywhere in the library.

## Mismatches between the draft library and the game (documented, not hidden)

1. Missions 3/4 BAD "Report constantly": the Miner stub never reports, so this does nothing. Replaced: mission 3 BAD is a 10% hold ("tiny trips", the Compute pool runs dry at about 420 cr), mission 4 BAD is "Mine stuff." (AI sales never count as skill credit).
2. Stock guards ("when at least 300 is stocked", Refiner "only when at least 30 titanium is in stock") are not parsed by the stub. The Logistician sends whatever is in stock, the Refiner shrinks the batch to the stock. Both GOOD examples are marked `partial` with the unread clause listed.
3. Salvager: the stub has one hull threshold, so "return below 50; repair below 80" collapses. The GOOD example uses a single "repair below 60 hull".
4. Mission 3's 15 Compute budget is passable by a plain AI run (5.5 Compute for 2,100 cr in the challenge window). Challenge 3 therefore uses a stricter Compute cap (3) so the saved skill is what passes. Mission 3 itself is untouched.
5. Mission 6 and 7 GOOD need two directives (`text` and `text2`): one per Miner / Logistician. Mission 7 uses titanium and cobalt lanes to Halcyon instead of the draft's iridium/Meridian pairing, which the stub's lane rules do not support at the unlock tier.
6. Challenge 4: on a quiet market OK and GOOD sell the same units. The floor only separates them when Orbis saturates (price x0.5): OK sells cheap, GOOD holds its cargo (tested in `test_prompt_library.luau`, mission 5).
7. Challenge 3 and mission 3 use the same ledger (lifetime Compute); challenge metrics are read from decision records and the ledger and never write to missions.

None of these change the spec's intent; none needs a GR5-102 decision. Items 1-3 and 5 are listed for the author of the draft library so the player-facing text matches what the game does.
