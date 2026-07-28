# Design — Realistic Tire Wear v1

Goal: every vehicle's tires accumulate wear from slip/friction energy and heat,
grip degrades progressively, and a tire pops when worn out or cooked. Tunable,
deterministic, self-contained vehicle Lua extension.

See `research.md` for verified API ground truth. Where this document and
research.md disagree on API details, research.md wins.

## Delivery

- Single vehicle extension: `mod/lua/vehicle/extensions/auto/alexTireWear.lua`
  (global name = file basename, so it's namespaced to avoid collisions).
- Lifecycle: init state in `onExtensionLoaded` AND `onVehicleLoaded` (idempotent),
  fresh tires on `onReset`. **Never `onInit`** (never fires for vehicle auto
  extensions — see research.md).
- Integration at physics rate via `onPhysicsStep` (call `enablePhysicsStepHook()`
  in init). Cheap math only in that hook; UI/messages/actuator updates at
  `updateGFX` rate.
- Explicit `onSerialize`/`onDeserialize` carrying only the per-wheel state table.

## Per-wheel state

Keyed by wheel cid, initialized to environment temperature:

| field | meaning |
|---|---|
| `wear` | 0 fresh → 1 dead (percentage of usable tread life) |
| `treadTemp` | tread surface temp, °C |
| `coreTemp` | carcass/core temp, °C |
| `heatDamage` | accumulated overheat damage 0 → 1 (separate blowout path) |
| `popped` | latch so we deflate exactly once |

## Model (per physics step, dt ≈ 0.0005 s)

**Heating.** Tread heats from slip: `treadTemp += kSlipHeat * slipEnergyRate * dt`
(slip energy per wheel from the wheels API; confirm units on the test box —
scale constant accordingly). Small rolling-heat term from load × speed so
highway driving settles tires into a warm band instead of staying at ambient.

**Conduction & cooling.** Tread ↔ core conduction proportional to their delta.
Both cool toward ambient convectively: `k * (temp - envTemp) * (1 + cAir * airspeed)`.
Ambient from `obj:getEnvTemperature()`.

**Wear.** `wear += kWear * slipEnergyRate * tempWearMult(treadTemp) * dt` where
`tempWearMult` is ~0.6 cold (<40 °C), 1.0 in the optimal band (75–100 °C),
ramping to ~3.5 when overheated (>115 °C). Hard launches, burnouts, drifting,
and lockups are the dominant wear sources — exactly as in real life.

**Grip multiplier.** `grip = wearMult(wear) * tempMult(treadTemp)`:

- `wearMult`: 1.0 fresh, gentle linear decline to ~0.88 at 80 % wear, then a
  steep knee to ~0.65 at 100 % (cords showing).
- `tempMult`: ~0.85 stone cold, 1.0 in the 75–100 °C window, fading to ~0.8 by
  135 °C (greasy overheated rubber).

Applied per wheel through the actuator recommended in research.md
(`setFrictionThermalSensitivity`), recomputed at updateGFX rate only when the
multiplier moved meaningfully (avoid hammering the setter every frame).

**Blowouts.** Two deterministic paths, both ending in
`beamstate.deflateTire(cid)` + a "tire blowout!" message:

1. Wear-out: `wear >= 1.0`.
2. Heat: while `treadTemp > 140 °C`, `heatDamage` accumulates (faster the hotter);
   pops at `heatDamage >= 1.0`. Recovers slowly if cooled before the threshold.

## Driver feedback

- `guihooks.message(msg, ttl, category, icon)` warnings, one-shot per stage per
  tire: 50 % / 75 % / 90 % wear, overheat warning, blowout. Category namespaced
  per wheel so messages don't stomp each other.
- Simple UI app (`mod/ui/modules/apps/tireWear/`, AngularJS per research.md):
  four tire tiles showing wear % and tread temp, color-coded (blue cold → green
  optimal → red overheat; tile fill for wear). Streams data from the extension
  via `guihooks.trigger` at updateGFX rate.

## Tuning

All constants in one `settings` table at the top of the extension (wear rate
multiplier, thermal coefficients, thresholds), so play-testing feedback maps to
one-line changes. Default target: a hard track session degrades noticeably
within ~10–15 min; sustained drifting/burnouts can kill a tire in ~2–3 min;
normal road driving takes much longer.

## v1 non-goals

Per-compound differences, flatspots, punctures from debris, wear persistence
across sessions (career `partCondition` integration), and pressure loss before
the pop. Candidates for v2.
