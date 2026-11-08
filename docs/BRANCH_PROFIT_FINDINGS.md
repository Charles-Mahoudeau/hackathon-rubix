# Branch profitability: findings and config proposals (GR5-64)

Numbers: `docs/BRANCH_PROFIT_REPORT.md` (5 seeds, 90 game minutes, deterministic; regenerate with `tools/branch_report.sh`, about 70 s). Unlock costs: Salvage 15,000, Refining 18,000, Raiding 20,000. Mining-only control at the T4 fork earns about 1,720 net worth per minute (`hmc`), 2,300 with stored ore shipped by a Logistician (`ship`).

## What the measurements say

| Branch (directive) | Net vs control / min | Failure / disable | Mission | Reading |
|---|---|---|---|---|
| Salvage careful | +12 @T4, -5 @T2 | 12% hazards, 0 disabled | not reached (stops at layer 2) | Gross 47-63 cr/min, Scavenger Compute 4,000-4,600 cr per window: Compute eats nearly all of gross. |
| Salvage reckless | +15 @T2, +23 @T4 | 25% hazards, 2.4 disabled per seed | V2 in 4/5 seeds | Same earnings, more risk and repairs; the V2 blueprint is the real payoff. |
| Refining shipped (best / naive) | +151 / +80 | none | V1 in 5/5 seeds | Net cash is negative (-289 / -338) because refined stock is still in the warehouse (about 50k cr marked); wide per-seed spread (-521 to +462). Not distinguishable from the logistics control at 5 seeds. |
| Refining sold at Orbis | not realizable | none | not reached | Orbis does not buy Catalyst or Processor, the stub Logistician stalls with 75k-150k cr of goods stranded. Unreachable buyer, not a refinery result. |
| Raiding careful | +15 | 24% attacks lost, 0 disabled | V3 in 3/5 seeds | Gross 103 cr/min against 6,200-8,000 cr Compute per window. Marginal net is about zero. |
| Raiding reckless | -293 | 45% attacks lost, 2.0 disabled | not reached | Loses 7,200-9,400 cr in repairs per window plus Compute. This is the section 15b intended tradeoff (reckless Privateers lose money) and is preserved. |

Payback of the unlock cost, measured as sustained marginal net worth: not reached in 90 minutes in any Salvage or Raiding scenario; extrapolated 150-3,150 minutes for Salvage (one seed effectively never), 510-640 for careful Raiding on the 3 of 5 seeds with positive net. Refining shipped pays back at 40-88 minutes on 3 of 5 seeds (best margin) / 4 of 5 (naive) and never or far out on the rest.

## Config proposals

No existing config was changed. Reckless Raiding and reckless Salvage losing money is the intended danger tradeoff.

The evidence does show one problem that is not a tradeoff: the careful, well-briefed Salvage and Raiding agents earn about what they cost in Compute, so a player who plays them correctly sees almost no benefit apart from missions. The levers are, in order of how little they disturb section 15b (none applied, none re-tested yet, for Game Design to pick; every proposal must be rerun against the controls with `tools/branch_report.sh`):

1. Raise careful Salvage layer loot value (`scripts/config/branches.luau`, salvage layer values) so gross is at least 2x Compute cost (target: gross about 100 cr/min for the careful directive).
2. Lower Scavenger / Privateer Compute per call rather than touching the global Compute price (`scripts/config/ai.luau` `priceCredits = 40` also prices the Miner and Logistician, whose control arms would move too).
3. Lower the Salvage and Raiding unlock (15,000 / 20,000) only if 1 and 2 are not enough: at current margins neither pays back within a session.

Refining needs no change before the stub Logistician can reach a buyer for Catalyst and Processor (an AI gap, not a balance gap: the next step is the Logistician stub or a Meridian route, not a number).

## Assumptions

Stub AI only (no real LLM); shop frozen after the fork; one freighter; unsold stock marked at its best unlocked sale price (compare Net with Net cash); mission rewards not claimed; data cores sell only at Meridian; Orbis buys neither Catalyst nor Processor.
