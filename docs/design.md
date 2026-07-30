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
- No wear persistence anywhere: tires are brand new on every spawn and reset
  (user decision, 2026-07-29). `onSerialize` stays minimal/explicit only so the
  engine doesn't serialize the whole module table.

## Per-wheel state

Keyed by wheel cid, initialized to environment temperature:

| field | meaning |
|---|---|
| `wear` | 0 fresh → 1 dead; presented as **tread depth** in mm, `treadDepthNew` (8.0) → `treadDepthDead` (1.6, cords) |
| `treadTemp` | tread surface temp, °C |
| `coreTemp` | carcass/core temp, °C |
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

**Blowout.** Exactly one deterministic path (user decision, 2026-07-29 — there
is no overheat blowout): when tread depth reaches `treadDepthDead`
(`wear >= 1.0`), `beamstate.deflateTire(cid)` + a "tire blowout!" message.
Overheating punishes the driver only by accelerating tread loss
(`tempWearMult`) and softening grip — it never pops a tire directly.

**Cord sparks (added 2026-07-30, user request; geometry reworked same day).**
Once tread is within `sparkTreadWindow` (0.2 mm) of `treadDepthDead`, the
contact patch throws spark particles while the wheel is rolling (≥2 m/s) under
load (≥150 N) on a hard surface (asphalt/metal/rock — mirrors vanilla's spark
material table). Emission uses `obj:addParticleVelWidthTypeCount` (the same
primitive the engine's own friction sparks use): origin = the last tread
contact node (ground level), velocity = rearward along travel following the
sign of wheelSpeed (reversing sprays forward) + 12 % vertical, magnitude
speed-scaled. Falls back to node-axis emission (with an honest log warning)
if the primitive is missing; ≤1 emission call per wheel per frame, zero
per-frame allocations. One-shot "tire on the cords!" warning at onset.
Panel-tunable: `sparksEnabled`, `sparkTreadWindow`, `sparkAmount` (0.25–3×),
`sparkThickness` (0.01–0.30). Known limits: direction uses the vehicle forward
axis (drifting wheels trail the body axis), and a fully locked wheel doesn't
spark (gate is wheel speed, not ground speed).

## Driver feedback

- `guihooks.message(msg, ttl, category, icon)` warnings, one-shot per stage per
  tire, phrased in tread terms ("FR tread low: 2.4mm") at 50 % / 75 % / 90 %
  wear, an overheat warning ("wearing fast"), and blowout. Category namespaced
  per wheel so messages don't stomp each other.
- Simple UI app (`mod/ui/modules/apps/tireWear/`, AngularJS per research.md):
  per-tire tiles showing **tread depth in mm** (primary number) and tread temp,
  color-coded (blue cold → green optimal → red overheat; tile fill for wear).
  Data ships over the custom "alexTireWear" stream (verified working in-game).

## User tuning panel (added 2026-07-30, user request)

Gear icon in the HUD app opens a slider/toggle panel: current tread % (apply to
player's tires), new-tire tread depth (4–14 mm), wear speed (0.25–5×, scales
rate and safety cap together), tire heating (0.25–4×), temp-affects-grip
toggle, cord sparks toggle + spark window (0.1–1.0 mm), reset to defaults.
Sliders only — no text inputs (BeamNG's CEF-typing guard doesn't cover plain-DOM
text fields, so typed digits would reach the car controls). Extension side:
`applyUserTuning` (validated/clamped, idempotent via baseline snapshot, pushed
to ALL vehicles via `queueAllObjectLua`) and `setTreadPercent` (player vehicle;
popped tires stay popped). Persistence: localStorage (`apps:alexTireWear.tuning`,
the vanilla convention) + a tuning token echoed on the stream; the app re-pushes
whenever a vehicle's token mismatches (rate-limited 1/s). Known gap: tuning only
reaches vehicles while the HUD app is open.

## Tuning

All constants in one `settings` table at the top of the extension (wear rate
multiplier, thermal coefficients, thresholds), so play-testing feedback maps to
one-line changes. Default target: a hard track session degrades noticeably
within ~10–15 min; sustained drifting/burnouts can kill a tire in ~2–3 min;
normal road driving takes much longer.

## v1 non-goals

Per-compound differences, flatspots, punctures from debris, and pressure loss
before the pop. Candidates for v2. Wear persistence is explicitly rejected, not
deferred — tires are always fresh on spawn/reset.
