# BeamNG.drive Progressive Tire Wear — Implementation Reference

Research notes for building a mod that simulates progressive tire wear: grip loss from
slip energy and temperature over time, eventually popping the tire.

**Target game version:** 0.38.6 (released 2026-05-18). 0.39 announced (graphics overhaul,
PS5) but unreleased as of this writing.

---

## Method and provenance

BeamNG's official documentation is thin on the Lua side and says so explicitly:

> There's no centralized list with those special functions and variables; the source code
> IS the documentation(tm).
> — <https://documentation.beamng.com/modding/programming/extensions/>

So most of what follows was read directly out of mirrors of the game's shipped Lua rather
than from docs. Mirrors used:

| Mirror | Version | Notes |
| --- | --- | --- |
| `SchankIND/lua` | ~0.36 (committed Aug 2025) | primary; paths below are `<root>/vehicle/...` |
| `wlkmanist/BeamNG_lua` | 0.34.2 | cross-check; paths are `<root>/lua/vehicle/...` |
| `KRtkovo-eu-AI/BeamNG_FreeMode_Inventory` | `.beamng/orig-0.36/` | second cross-check |

Line numbers below refer to the ~0.36 dump unless stated. Where a claim comes from official
docs, the URL is given. Anything I could not confirm is collected in
[§8 Unverified](#8-unverified-and-open-questions) rather than presented as fact.

---

## 1. What vanilla BeamNG already does

### 1.1 There is no tire wear, and no *enabled* tire thermals

Correcting a common assumption: **the 0.36 update did not add tire thermals or tire wear.**
I fetched the [v0.36 release notes](https://www.beamng.com/game/news/patch/beamng-drive-v0-36/)
directly — zero mentions of tire thermals or wear. Same for 0.37 and 0.38. Tire-adjacent work
in 0.37 was wheel-slip *vibration* by ground model, on-the-fly tire pressure equipment, and
the new spike strip prop.

**There is no tire wear (abrasion / condition) simulation in vanilla, in any version.**

BeamNG's Vehicle Systems Lead (*Diamondback*), on
[Any plans for tire thermal simulation?](https://www.beamng.com/threads/any-plans-for-tire-thermal-simulation.77308/):

> Plans....certainly... But yea, it's a very delicate matter that needs very very careful
> calibration and affects a ton of other systems, so we can't really promise anything.

### 1.2 But a complete C++ tire thermal engine ships, unconfigured

This is the single most important finding, and it determines the mod's architecture.
`vehicle/jbeam/stage2.lua` `processWheels()` pushes two thermal configs into every wheel's
C++ object at spawn:

```lua
-- vehicle/jbeam/stage2.lua:279-296
local wobj = obj:getWheel(wid)
if wobj then
  wobj:setThermal(
    checkNum(wheel.heatCoefNodeToEnv), checkNum(wheel.heatCoefEnvMultStationary, 0.4),
    checkNum(wheel.heatCoefEnvTerminalSpeed, 20), checkNum(wheel.heatCoefNodeToCore),
    checkNum(wheel.heatCoefCoreToNodes), checkNum(wheel.heatCoefNodeToSurface),
    checkNum(wheel.heatCoefFriction), checkNum(wheel.heatCoefFlashFriction),
    checkNum(wheel.heatCoefStrain), checkNum(wheel.smokingTemp, 1e18),
    checkNum(wheel.meltingTemp, 1e19),
    type(wheel.heatAffectsPressure) == 'boolean' and wheel.heatAffectsPressure or false
  )

  wobj:setFrictionThermalSensitivity(
    checkNum(wheel.frictionLowTemp, -300), checkNum(wheel.frictionHighTemp, 1e7),
    checkNum(wheel.frictionLowSlope, 1e-10), checkNum(wheel.frictionHighSlope, 1e-10),
    checkNum(wheel.frictionSlopeSmoothCoef, 10), checkNum(wheel.frictionCoefLow, 1),
    checkNum(wheel.frictionCoefMiddle, 1), checkNum(wheel.frictionCoefHigh, 1)
  )
end
```

So the engine has a wheel thermal solver (friction heating, flash friction, strain heating,
node↔core↔surface conduction, environment cooling with a speed term, smoking/melting
temperatures, optional heat→pressure coupling) **and** a temperature→friction curve
(low/mid/high plateaus with sloped transitions).

**It is disabled by default.** `checkNum(val, default)` returns `default or 0`
(`vehicle/jbeam/stage2.lua:22`), so every `heatCoef*` defaults to **0** — no heat is
generated. And the `setFrictionThermalSensitivity` defaults (`-300`, `1e7`, slopes `1e-10`,
all three coefs `1`) make the friction curve perfectly flat. It is opt-in per tire part via
jbeam.

Supporting evidence that nothing uses it:

- `gh api search/code 'heatCoefNodeToEnv extension:jbeam'` → **0 results**. Same for
  `heatCoefFriction`, `smokingTemp`, `frictionCoefMiddle`.
- None of these fields appear on the official
  [pressureWheel page](https://documentation.beamng.com/modding/vehicle/sections/wheels/),
  which documents `frictionCoef`, `slidingFrictionCoef`, `treadCoef`, `softnessCoef`,
  `noLoadCoef`, `fullLoadCoef`, `loadSensitivitySlope`, `stribeckExponent` and *none* of
  the thermal ones.
- There is **no `enableTireThermals` flag**. Grepping the whole Lua tree for
  `tireTherm|enableTireThermals|tireTemperature|treadTemp` returns nothing. Enabling is
  implicit: nonzero `heatCoef*` values.

**Do not confuse this with `wheelThermals`, which is brakes-only.**
`electrics.values.wheelThermals[wheelName]` carries only `brakeSurfaceTemperature`,
`brakeCoreTemperature`, `brakeThermalEfficiency` (`vehicle/wheels.lua:219-221`). Vanilla
brake thermals are real, complete, and working — and useful to us as a *heat input*
(see §6.2).

### 1.3 Thermal readback APIs that work today

From `vehicle/bdebugImpl.lua:349-371`, the `wheelThermals` debug visualizer:

```lua
obj:getWheelAvgTemperature(wd.wheelID)   -- Kelvin, tread average
obj:getWheelCoreTemperature(wd.wheelID)  -- Kelvin, core / inner air
obj:getNodeTemperature(nodeCid)          -- Kelvin, per node
obj:getGroupPressure(v.data.pressureGroups[wd.pressureGroup])  -- Pascal
```

These are callable regardless of jbeam config. How *meaningfully they vary* depends on the
`heatCoef*` values being nonzero, which for stock tires they are not.

### 1.4 Design conclusion

Implement your own wear and thermal model in Lua, but **use
`setFrictionThermalSensitivity` as the grip actuator**. Do not attempt to "extend the
built-in system" — the built-in system is an unconfigured chassis with no wear concept at
all. Precisely: *undocumented and unconfigured is not the same as absent*, and that
distinction is exactly what makes the actuator usable.

---

## 2. Vehicle Lua API for wheels and tires

### 2.1 The one call that provides everything per frame

`vehicle/wheels.lua:332`, inside `updateWheelsGFX(dt)`:

```lua
wd.lastSlip, wd.lastSideSlip, wd.slipEnergy, wd.downForceRaw, wd.peakForce,
  wd.contactDepth, wd.contactMaterialID1, wd.contactMaterialID2
    = wd.obj:getSlipVelEnergyDownPeakForceDepthMats()
```

Vanilla refreshes these every graphics frame, and `extensions.hook("updateGFX", dtSim)`
fires **after** `wheels.updateGFX` (`vehicle/main.lua:94`, then `:100`). So inside your
extension's `updateGFX` the values are already fresh — read
`wheels.wheelRotators[i].slipEnergy` and **do not re-call the C++ function**.

### 2.2 Per-wheel fields

From `vehicle/wheels.lua:924-1000` (`initWheels()`). Both `wheels.wheels[cid]` and
`wheels.wheelRotators[cid]` reference the same table (`M.wheels[wd.cid] = wheel`,
`M.wheelRotators[wd.cid] = wheel`), indexed by **cid**, `0 .. wheelRotatorCount-1`.

| Field | Meaning |
| --- | --- |
| `slipEnergy` | slip energy — primary wear / heat driver |
| `lastSlip`, `lastSideSlip` | longitudinal / lateral slip velocity |
| `downForceRaw`, `downForce` | wheel load, raw and smoothed (`downForceSmoother`) |
| `peakForce` | peak available force |
| `contactDepth`, `contactMaterialID1`, `contactMaterialID2` | ground penetration + ground model IDs |
| `angularVelocity`, `wheelSpeed`, `wheelDir` | rotation; `wheelDir` is ±1 for side |
| `propulsionTorque`, `brakingTorque`, `brakeTorque`, `frictionTorque` | torques |
| `radius`, `dynamicRadius`, `hubRadius`, `tireWidth` | geometry |
| `treadCoef`, `softnessCoef` | compound proxies (`treadCoef`: slick 0, street 0.7, offroad 0.9) |
| `brakeSurfaceTemperature`, `brakeCoreTemperature`, `brakeThermalEfficiency`, `isBrakeMolten` | vanilla brake thermals — real and working |
| `node1`, `node2`, `nodes`, `treadNodes`, `lastTreadContactNode` | node handles |
| `pressureGroup`, `pressureGroupId` | for pressure get/set |
| `isBroken`, `isTireDeflated`, `hasTire` | state |
| `wheelID`, `cid` | **two different IDs — see below** |
| `coreData` | `obj:getWheelFFI(wd.cid)` FFI struct (`brakeTorqueApplied`, `speedScore`) |

> **`wheelID` vs `cid` gotcha.** Vanilla uses `obj:getWheel(wd.wheelID)`
> (`vehicle/wheels.lua:915`) but `obj:getWheelFFI(wd.cid)`, and the tables are keyed by
> `cid`. The Redux mod calls `obj:getWheel(i)` where `i` is the `cid` key — which works
> only when the two happen to coincide. **Use `obj:getWheel(wd.wheelID)`** to match vanilla.

### 2.3 Other useful inputs

```lua
sensors.gx, sensors.gy, sensors.gz          -- chassis accelerometers
sensors.gx2, sensors.gy2, sensors.gz2       -- secondary
electrics.values.airflowspeed               -- for convective cooling
electrics.values.airspeed
electrics.values.wheelspeed
obj:getEnvTemperature()                     -- Kelvin; no GE round-trip needed
obj:getStaticFrictionCoef()
particles.getMaterialsParticlesTable()      -- contactMaterialID -> ground model name; CACHE IT
```

`particles.getMaterialsParticlesTable()` allocates — call once and cache.

### 2.4 Friction setters — three tiers

**Tier 1 (recommended): whole-wheel grip multiplier.** Repurpose the unused thermal
sensitivity curve as a flat scalar. This is what the shipped mods do, and it is the
cleanest lever available:

```lua
local wobj = obj:getWheel(wd.wheelID)
wobj:setFrictionThermalSensitivity(
  -300, 1e7, 1e-10, 1e-10, 10,   -- neutralise the temperature curve
  gripMult, gripMult, gripMult)  -- frictionCoefLow / Middle / High
```

*Limitation:* uniform across the whole tire, so per-zone temperatures can only ever be
cosmetic.

**Tier 2: per-node friction.** `obj:setNodeFrictionSlidingCoefs(nodeCid, frictionCoef,
slidingFrictionCoef)`. Confirmed in vanilla at `vehicle/beamstate.lua:554`:

```lua
for _, nodecid in pairs(wheel.treadNodes) do
  local frictionCoef = v.data.nodes[nodecid].frictionCoef
  local slidingFrictionCoef = v.data.nodes[nodecid].slidingFrictionCoef
  if frictionCoef then
    local rnd1, rnd2 = math.random(20, 50), math.random(25, 60)
    obj:setNodeFrictionSlidingCoefs(nodecid, frictionCoef * rnd1 * 0.01,
                                    (slidingFrictionCoef or frictionCoef) * rnd2 * 0.01)
  end
end
```

Always scale off the **jbeam baseline** `v.data.nodes[cid].frictionCoef`, never off the
current value — it does not read back, so you would compound the multiplier every frame.
This tier enables asymmetric / flatspot wear.

**Tier 3: full node rewrite.** Needed only to change node *mass* (flatspot vibration, wheel
imbalance). Signature from `vehicle/jbeam/stage2.lua:210`:

```lua
obj:setNode(cid, x, y, z, nodeWeight, ntype, frictionCoef, slidingFrictionCoef,
            stribeckExponent, stribeckVelMult, noLoadCoef, fullLoadCoef,
            loadSensitivitySlope, softnessCoef, treadCoef, tag, couplerStrength,
            firstGroup, selfCollision, collision, staticCollision, nodeMaterial)
```

### 2.5 Best wear data source: `onNodeCollision` (physics rate)

Physically the correct driver for abrasion is per-node friction work, available at physics
rate. `vehicle/main.lua:471`:

```lua
function onNodeCollision(id1, pos, normal, nodeVel, perpendicularVel, slipVec, slipVel,
                         slipForce, normalForce, depth, materialId1, materialId2)
  local p = particlefilter.particleData
  p.id1, p.pos, p.normal, p.nodeVel, p.perpendicularVel = id1, pos, normal, nodeVel, perpendicularVel
  p.slipVec, p.slipVel, p.slipForce = slipVec, slipVel, slipForce
  p.normalForce, p.depth, p.materialID1, p.materialID2 = normalForce, depth, materialId1, materialId2

  wheels.nodeCollision(p)
  fire.nodeCollision(p)
  controller.nodeCollision(p)
  particlefilter.nodeCollision(p)
  bdebug.nodeCollision(p)
end
```

`slipForce * slipVel` is instantaneous frictional power at that node. Map node → wheel via
`v.data.nodes[id1].wheelID`, as `wheels.nodeCollision` does at `vehicle/wheels.lua:97`.

Three gotchas:

1. **There is no `extensions.hook` here.** To receive node collisions from an auto
   extension you must wrap the global:
   ```lua
   local originalOnNodeCollision = onNodeCollision
   function onNodeCollision(...)
     originalOnNodeCollision(...)
     myHandler(...)
   end
   ```
2. `p` is a **shared, reused table** (`particlefilter.particleData`). Read scalars
   immediately; never retain the table.
3. The field is `p.materialID1` (as set by `main.lua`), but `vehicle/wheels.lua:107` reads
   `p.materialID` — a latent vanilla typo that makes its `p.materialID ~= 4` test always
   true. **Use `materialID1`.**

---

## 3. Popping / deflating a tire

### 3.1 The API

**`beamstate.deflateTire(wheelCid)`** — one argument. Full implementation at
`vehicle/beamstate.lua:517`:

```lua
local function deflateTire(wheelid)
  local wheel = v.data.wheels[wheelid]
  M.lowpressure = true
  local brokenBeams = wheelBrokenBeams[wheelid] or 1
  local pressureGroupPressure = 200000
  if wheel.pressureGroup ~= nil then
    if v.data.pressureGroups[wheel.pressureGroup] ~= nil then
      pressureGroupPressure = obj:getGroupPressure(v.data.pressureGroups[wheel.pressureGroup])
      if brokenBeams > 4 then
        obj:deflatePressureGroup(v.data.pressureGroups[wheel.pressureGroup])
        obj:changePressureGroupDrag(v.data.pressureGroups[wheel.pressureGroup], 0)
      elseif brokenBeams == 1 then
        obj:setGroupPressure(v.data.pressureGroups[wheel.pressureGroup], (0.1 * 6894.757 + 101325))
      end
    end
  end
  if brokenBeams == 1 then
    if wheels.wheels[wheelid] then wheels.wheels[wheelid].isTireDeflated = true end
    guihooks.message({txt = "vehicle.beamstate.tireDeflated", context = {wheelName = wheel.name}},
                     5, "vehicle.damage.deflated." .. wheel.name)
    damageTracker.setDamage("wheels", "tire" .. wheel.name, true)
    extensions.hook("onTireDeflated", wheelid)
    local tireBurstVolume = linearScale(pressureGroupPressure, 0, 1000000, 0, 1)
    local tireBurstColor = wheels.wheels[wheelid]
                           and linearScale(wheels.wheels[wheelid].tireVolume, 0, 1, 0, 5) or 0
    obj:playSFXOnceCT("event:>Vehicle>Failures>tire_burst", wheel.node1,
                      tireBurstVolume, 1, tireBurstColor, 0)
    M.damageExt = M.damageExt + 1000
    -- ... then randomises tread node friction, softens treadBeams / sideBeams / peripheryBeams
  end
end

-- exports, vehicle/beamstate.lua:1543-1548
M.deflateTire = deflateTire
M.deflateTires = deflateTires
M.deflateRandomTire = deflateRandomTire
```

It is a full burst: sound, localized UI message, damage tracker entry, `onTireDeflated`
hook, tread node friction randomisation and beam softening. You get all of that for one
call.

### 3.2 How vanilla triggers it

**Spike strip** — `vehicle/wheels.lua:341`. The cleanest precedent for a condition-driven pop:

```lua
if wd.contactMaterialID1 == 32 or wd.contactMaterialID2 == 32 then
  beamstate.deflateTire(wd.cid)
end
```

**Fire** — `vehicle/fire.lua:243`, when node temperature exceeds `tirePopTemp`:

```lua
beamstate.deflateTire(wheelData.wheelID, 1)
```

(Note the stray second argument — harmless, the signature takes one. Also note it passes
`wheelID` where `wheels.lua` passes `cid`; vanilla is inconsistent here.)

**Beam break** — `vehicle/beamstate.lua:822`: `deflateTire(beam.wheelID)`

**Debug / fun menu** — `ge/extensions/core/funstuff.lua:74`:
`getPlayerVehicle(0):queueLuaCommand("beamstate.deflateTires()")`

### 3.3 Using it in the mod

```lua
local function pop(cid)
  local wd = wheels.wheels[cid]
  if not wd or wd.isTireDeflated or wd.isBroken then return end  -- guard: not idempotent-cheap
  beamstate.deflateTire(cid)
end
```

**Partial / slow leaks** instead of a hard pop:
`obj:setGroupPressure(pressureGroupId, pascals)` — absolute Pascals, atmospheric = 101325.
Also available: `obj:setGroupPressureRel`, `obj:deflatePressureGroup`,
`obj:changePressureGroupDrag`. `vehicle/controller/tirePressureControl.lua` is a working
reference for gradual inflate/deflate.

You can also surface wear itself as damage:
`damageTracker.setDamage(group, name, value, notifyUI)` (`vehicle/damageTracker.lua:46`).

---

## 4. Mod structure

### 4.1 Auto-loading vehicle extension

`vehicle/main.lua:314`, inside post-spawn `init()`:

```lua
-- load the extensions at this point in time, so the whole jbeam is parsed already
extensions.loadModulesInDirectory("lua/vehicle/extensions/auto")
```

**`lua/vehicle/extensions/auto/<name>.lua` auto-loads on every vehicle spawn, after jbeam
parsing.** Verified identical across all three mirrors (0.34-era `:311`, 0.36 `:314`,
mid-2025 `:314`). No modScript, no jbeam edit, no part slot required.

This is **undocumented**, and the official
[Extensions page](https://documentation.beamng.com/modding/programming/extensions/) actively
implies the opposite — *"An extension you create won't be loaded until you write explicit
code for it to be loaded… As a general rule, you shouldn't need to automatically load an
extension"* — and never mentions `auto`. But the mechanism is in the shipped source and all
four existing tire mods rely on it.

Two practical details:

- `loadModulesInDirectory` uses `FS:findFiles(dir, "*.lua", -1, true, false)` → **recursive**,
  and loads each file at root `""`, so the extension's global name is just the **basename**
  (`auto/mymod/foo.lua` → global `foo`). **Namespace your filename** — `myTireWear.lua` →
  global `myTireWear` — or you will collide with another mod.
- **There is no `auto` equivalent for GELUA.** `ge/main.lua` only calls
  `extensions.addModulePath("lua/ge/extensions/")`.

### 4.2 Zip layout

`lua/`, `ui/`, `scripts/` go at the **zip root** — no wrapper folder. Now confirmed
officially:

> When opening your `.zip`, the first visible folders should be the relevant top level
> folders like `vehicles`, `levels`, `lua`, etc.
> — <https://documentation.beamng.com/modding/mod-support/mod_packing/>

and FAQ #7: *"Do not leave files in the root of the zip or add extra unnecessary folder
layers."* Valid top-level folders: `vehicles`, `levels`, `art`, `assets`, `lua`, `scripts`,
`ui`, `gameplay`, `settings`, `trackEditor`, `vehicleGroups`.

```
mytirewear.zip
├── lua/
│   ├── vehicle/
│   │   └── extensions/
│   │       ├── auto/
│   │       │   └── myTireWear.lua        <- auto-loads per vehicle
│   │       └── myTireWearModel.lua       <- helper, via require() / extensions.load()
│   └── ge/
│       └── extensions/
│           └── myTireWear.lua            <- GE side: ground models, settings, persistence
├── ui/
│   └── modules/apps/MyTireWear/
│       ├── app.json
│       ├── app.js
│       └── app.png
└── scripts/
    └── myTireWear/modScript.lua          <- optional
```

**`mod_info/<ID>/info.json` is repository-generated — do not author it.** Matched at
`ge/extensions/core/modmanager.lua:348` with
`'^/?mod_info/([0-9a-zA-Z]*)/info%.json'` and the comment `-- its a repo info file!`. The
mod repository injects it on upload. A hand-packed zip needs no metadata file at all.

**`scripts/<anything>/modScript.lua`** is `dofile`'d at mod-manager init
(`modmanager.lua:615-640`), GELUA only. Modern pattern is `extensions.load("myMod_x")` plus
`setExtensionUnloadMode("myMod_x", "manual")` (defined at `ge/main.lua:387`) — a bare
`extensions.load` there logs a deprecation warning. To reach vehicles from modScript, use
`be:queueAllObjectLua('...')`.

### 4.3 Attaching Lua to a jbeam part

The key is the **`controller` section with `fileName`** — not `luaFile`, not `vehicleLua`
(neither exists anywhere in the tree):

```json
"controller": [
  ["fileName"],
  ["myMod/myTireCtrl", {}]
]
```

Resolves to `lua/vehicle/controller/myMod/myTireCtrl.lua` (`local directory = "controller/"`,
`vehicle/controller.lua:276/460`).
See <https://documentation.beamng.com/modding/vehicle/sections/controller/>.

Relevant only if you want wear to be a fittable *part*. For a universal mod, `auto/` remains
correct. Note that controllers get `updateFixedStep` (100 Hz), `updateWheelsIntermediate` and
`nodeCollision` as first-class callbacks — a legitimate alternative route to physics-rate data
without touching `enablePhysicsStepHook`.

Per-vehicle alternative (official, but from a 2014 blog): drop `.lua` files in
`vehicles/<vehicle>/lua/`. Source confirms with an exclusion list —
`extensions.loadModulesInDirectory(path .. "/lua", {"controller", "powertrain", "energyStorage"})`
(`vehicle/main.lua:224/262`).

### 4.4 Lifecycle callbacks

All read out of `vehicle/main.lua` unless noted.

| `M.` member | Fired from | Notes |
| --- | --- | --- |
| `onExtensionLoaded(data)` | `extensions.lua` `processLoadedFreshList()` | **The real init point.** jbeam parsed, `v.data` available |
| `onVehicleLoaded(retainDebug)` | `main.lua:315` | Fires immediately *after* all `auto/` extensions load — best "everything ready" hook |
| `updateGFX(dt)` | `main.lua:100` | `extensions.hook("updateGFX", dtSim)`; after `wheels.updateGFX` at `:94`, so slip data is fresh |
| `onPhysicsStep(dtPhys)` | `main.lua:86` | **Gated — see warning below** |
| `onReset(retainDebug)` | `main.lua:434` | |
| `onTireDeflated(wheelid)` | `beamstate.lua:542` | |
| `onBeamBroke(id, energy)` | `main.lua:358` | |
| `onBeamDeformed(id, ratio)` | `main.lua:365` | |
| `onTorsionbarBroken(id, energy)` | `main.lua:370` | |
| `onCouplerFound(nodeId, obj2id, obj2nodeId, nodeDist)` | `main.lua:379` | |
| `onCouplerAttached(nodeId, obj2id, obj2nodeId, attachSpeed, attachEnergy)` | `main.lua:388` | |
| `onCouplerDetached(nodeId, obj2id, obj2nodeId, breakForce)` | `main.lua:397` | |
| `onDebugDraw(focusPos)` / `onDebugDrawActive(focusPos)` | `main.lua:137/139` | |
| `onSettingsChanged()` | `main.lua:523` | |
| `onPlayersChanged(anySeated)` | `main.lua:506` | |
| `onSerialize()` / `onDeserialize(data)` / `onDeserialized(data)` | `extensions.lua:936/975` | see §4.5 |
| `onExtensionUnloaded()` | `extensions.lua:246` | `onUnload()` is deprecated |
| `M.dependencies = {...}` | `extensions.lua` | declarative deps |

#### ⚠️ `M.onInit` never fires for a vehicle `auto/` extension

Two independent gates, both verified:

1. `extensions.hook("onInit")` fires at `vehicle/main.lua:194` inside `initSystems()`, which
   runs **before** the `auto` directory is loaded at `:314`. Your extension does not exist
   yet, so it cannot receive the hook.
2. The other `onInit` dispatch path, `common/extensions.lua:616` in
   `processLoadedFreshList()`, is explicitly gated to the GE VM:

```lua
-- common/extensions.lua:616-627
if vmType == 'game' then
  for i, moduleName in ipairs(modulesToInit) do
    if moduleName then
      modulesToInit[i] = false
      local m = rawget(_G, moduleName)
      if m and type(m.onInit) == 'function' then
        m.onInit(deserializedData[m.__extensionName__])
      end
    end
  end
end
```

and `vmType = "vehicle"` in `vehicle/main.lua:6` (vs `vmType = 'game'` in `ge/main.lua:9`).

**Use `onExtensionLoaded` and/or `onVehicleLoaded` instead.** This is very likely a live
latent bug in the existing mods: both Redux and `tyrewearandthermals2` register `M.onInit`,
and `tyrewearandthermals2`'s `onInit` is what calls `generateModTyres()` to populate its
`tyres` table. If `onInit` never fires on first spawn, its `for i, tyre in pairs(tyres)` loop
no-ops until the player first resets the vehicle — which would explain a class of "mod does
nothing until I hit Ctrl-R" reports.

Related deprecations:

- `M.init()` still works but is deprecated. `common/extensions.lua:19-24` maps it:
  `init = {replacement = 'onExtensionLoaded', executeOnModuleLoad = true}` — auto-patched onto
  `onExtensionLoaded`, executed immediately, and logs a warning.
- **`M.reset()` is not an extension callback.** Nothing calls it on extensions; the 2014 blog
  claim that *"updateGFX, init and reset functions are called automatically"* is stale for
  `reset`. Use `M.onReset`.
- **`M.updateFixedStep(dt)` and `M.updateWheelsIntermediate(dt)` are controller callbacks,
  not extension hooks.** `vehicle/controller.lua:541-556` (`cacheControllerFunctions`)
  collects `update`, `updateWheelsIntermediate`, `updateGFX`, `updateFixedStep`, `debugDraw`,
  `beamBroken`, `beamDeformed`, `nodeCollision`, `onCouplerFound/Attached/Detached`,
  `onGameplayEvent` from jbeam-declared controllers only.

#### ⚠️ `onPhysicsStep` is silently gated

`vehicle/main.lua:52` has `local extensionsHook = nop`, and `:62` only enables the physics
step when `extensionsHook ~= nop`. You must call the global:

```lua
enablePhysicsStepHook()   -- global in vehicle/main.lua:65
```

Without it, `M.onPhysicsStep` never fires and there is no error. Only two vanilla extensions
do this — `vehicle/extensions/test/ffbCalibration.lua:264` and
`vehicle/extensions/tech/wheelForces.lua:240`. The latter is a useful worked example of
physics-rate wheel telemetry. **No existing tire mod calls it**, which is why they all run at
graphics rate.

#### Update rates

Official, from
<https://documentation.beamng.com/modding/programming/virtualmachines/>:

| Callback | Rate |
| --- | --- |
| `onPhysicsStep` | **2000 Hz** |
| `updateGFX` | graphics framerate, **guaranteed 20 Hz floor** — below that the simulation slows down rather than dropping the callback |
| controller `updateFixedStep` | **100 Hz** (`local fixedStepTime = 1 / 100`, `vehicle/controller.lua:43`) |

The 20 Hz floor is a strong argument for doing wear integration in `onPhysicsStep`: at 20 fps
a graphics-rate model samples slip 100× more coarsely than the physics engine does.

### 4.5 Persisting state

**1. Across VM reload (Ctrl-R / Ctrl-L) — `onSerialize` / `onDeserialize`.** Exact precedence,
from `common/extensions.lua` `getSerializationData(reason)` (`:936`) and
`deserialize(data, filter)` (`:975`):

```
save: if type(M.onSerialize)=='function' then tmp[k] = M.onSerialize(reason)
      elseif M.state then tmp[k] = M.state
      else tmp[k] = M                     -- fallback: your ENTIRE M table
load: if type(M.onDeserialize)=='function' then M.onDeserialize(data[k])
      elseif M.state then tableMerge(M.state, data[k])
      else tableMerge(M, data[k])
      then if M.onDeserialized then M.onDeserialized(data[k]) end
```

`reason` defaults to `'reload'`. Transport is `exportPersistentData()` →
`obj:setPersistentData(serialize(serializePackages("reload")))` and `importPersistentData(s)`
(`vehicle/main.lua:498-508`).

> **Define `onSerialize` explicitly.** If you define neither `onSerialize` nor `M.state`, the
> engine serializes your **entire `M` table** and `tableMerge`s it back on reload. That
> fallback bites.

This does **not** survive vehicle respawn or game restart.

**2. Per-part wear — `vehicle/partCondition.lua`.** This is exactly what career mode uses.
Public API (`:583-603`):

```lua
partCondition.getConditions()   -- {[partName] = {odometer=, integrityValue=, visualValue=,
                                --                integrityState=, visualState=}} or false
partCondition.initConditions(partsCondition, fallbackOdometer, fallbackIntegrityValue,
                             fallbackVisualValue, defaultPaints)
partCondition.ensureConditionsInit(fallbackOdometer, fallbackIntegrityValue, fallbackVisualValue)
partCondition.reset()
partCondition.createConditionSnapshot(snapshotKey)
partCondition.applyConditionSnapshot(snapshotKey)
partCondition.deleteConditionSnapshots()
partCondition.setResetSnapshotKey(snapshotKey)
partCondition.getRootPartOdometerValue()
partCondition.getRootPartTripValue()
partCondition.setPartPaints(partName, paints, paintOdometer)
partCondition.setAllPartPaints(paints, paintOdometer)
partCondition.setPartMeshPaints(partName, paints)
```

**Naming precision: there is no `partCondition.setPartCondition`.** The public setter is
`initConditions`. `setPartCondition` is the name of the *per-subsystem fan-out* that the
private `initCondition(partId, odometer, integrity, visual, defaultPaints)` (`:409`) calls:

```lua
powertrain.setPartCondition(partTypes, odometer, integrity, visual)
energyStorage.setPartCondition(partTypes, odometer, integrity, visual)
beamstate.setPartCondition(partId, partTypes, odometer, integrity, visual)
setPaintCondition(partId, visual, defaultPaints)
```

Read-back is the mirror — `powertrain.getPartCondition(partData)` etc., returning
`{integrityValue, visualValue, integrityState, visualState}`; `getCondition` takes `min()`
across all subsystems.

Field semantics: `odometer` in **meters** (absolute base + `extensions.odometer.getRelativeRecording()`
delta); `integrityValue` / `visualValue` are 0..1 scalars; `integrityState` / `visualState` are
richer per-subsystem tables (`{powertrain=, energyStorage=, jbeam=, paint=}`) that **take
precedence** over the scalars on the way in (`integrity = integrityState or integrityValue`).

A wear system wanting career integration should expose matching
`setPartCondition` / `getPartCondition` and drive `integrity`.

**3. Cross-session (GE side).** `partCondition` is not itself persistent — career pumps it
across the VM boundary:

```lua
-- GE -> read: ge/extensions/career/modules/inventory.lua:423
core_vehicleBridge.requestValue(veh, function(res) ... res.result ... end, 'getPartConditions')
-- GE -> write: inventory.lua:437
veh:queueLuaCommand("partCondition.initConditions(" .. serialize(conds) .. ")")
```

Vehicle-side handler registered in
`vehicle/extensions/gameplayInterfaceModules/interactPartCondition.lua:92`
(`M.moduleLookups.getPartConditions = getConditions`).

Disk I/O: `jsonWriteFile(filename, obj, pretty, numberPrecision, atomicWrite)` and
`jsonReadFile(filename)` (`common/utils.lua:466/484`). Settings: `settings.getValue(key, default)`
works in both VMs (`common/settings.lua:113`); writing is GE-only via
`core_settings_settings.setValue(key, value)` / `.requestSave()`.

### 4.6 Cross-VM messaging

```lua
-- VLUA -> GELUA
obj:queueGameEngineLua('myLuaCode()')
-- GELUA -> one VLUA
be:getPlayerVehicle(0):queueLuaCommand('myLuaCode()')
-- GELUA -> all VLUA
be:queueAllObjectLua('myLuaCode()')
-- VLUA -> all VLUA
BeamEngine:queueAllObjectLua(code)
BeamEngine:queueAllObjectLuaExcept(code, exceptObjectID)
-- mailboxes (faster than queues; reads are non-destructive)
be:sendToMailbox("addr", data)      -- GE
obj:getLastMailbox("addr")          -- VLUA
```

### 4.7 UI app

Folder `ui/modules/apps/<AppName>/` with `app.json` + `app.js` + `app.png`. Hardcoded in
`ge/extensions/ui/apps.lua:8-13`: `local appsDir = '/ui/modules/apps/'`,
`FS:findFiles(appsDir, 'app.json', -1, false, false)`, `appData["jsSource"] = appDir..'app.js'`.
**There is no `app.html`** — markup goes in the directive's `template` string. Optional:
`settings.json`, `app2.png` / `app3.png`. `app.png` recommended 250×120.

**Framework: AngularJS 1.5.8 — still the only mod-accessible option in 0.38.**

> The user interface and apps of BeamNG.drive are written using the AngularJS (1.5.8)
> framework… apps are just simple directives in the module `beamng.apps`.
> — <https://documentation.beamng.com/modding/ui/app_creation/> (last revised Aug 2025)

0.38's Vue work covers the loading screen and main menu only, not apps.

`app.json`, verbatim from the Redux mod:

```json
{
  "domElement": "<tyre-wear-thermals></tyre-wear-thermals>",
  "name": "Tyre Wear and Thermals",
  "types": ["ui.apps.categories.debug", "ui.apps.categories.vehicle_info",
            "ui.apps.categories.info", "ui.apps.categories.racing"],
  "description": "TODO",
  "css": { "left": "0px", "height": "220px", "width": "165px",
           "min-width": "160px", "min-height": "120px",
           "top": "0px", "border-radius": "15px" },
  "author": "ZestyMaple98",
  "version": "0.18",
  "directive": "tyreWearThermals"
}
```

`directive` (camelCase) must match the `angular.module(...).directive(...)` name; `domElement`
is its kebab-case tag. The loader only **hard-requires** `domElement` and `directive` (plus
`appName`, which defaults to `directive`); anything else is cosmetic, and a missing required
field logs *`'invalid app data: … missing "domElement" or "directive" in app.json - IGNORING APP'`*.
Undocumented fields the loader also reads: `appName`, `types` (defaults to
`{'ui.apps.categories.unknown'}`), `official`.

`app.js` subscription pattern:

```js
angular.module("beamng.apps")
  .directive("myTireWear", [function () {
    return {
      template: '<canvas width="220"></canvas>',
      replace: true,
      restrict: "EA",
      link: function (scope, element, attrs) {
        var streamsList = ["MyTireWear"];
        StreamsManager.add(streamsList);
        scope.$on("$destroy", function () { StreamsManager.remove(streamsList); });

        var c = element[0], ctx = c.getContext("2d");
        scope.$on('app:resized', function (event, data) {
          c.width = data.width; c.height = data.height;
        });
        scope.$on("streamsUpdate", function (event, streams) {
          if (!streams.MyTireWear) return;
          /* draw */
        });
      }
    };
  }]);
```

Vehicle side — `streams = require("guistreams")` is a global (`vehicle/main.lua:254`):

```lua
-- vehicle/guistreams.lua:16
local function willSend(name)
  return guihooks.updateStreams and streamControl[name]
end
```

Two options:

- **Gated (correct):** `if streams.willSend("MyTireWear") then gui.send("MyTireWear", stream) end`.
  Costs nothing when the app is closed. Vanilla does exactly this for `wheelThermalData`
  (`vehicle/wheels.lua:178` + `:322`).
- **Unconditional (simple):** `gui.send("MyTireWear", stream)` every frame. What both
  open-source mods do.

**Registering a new stream name: nothing to register.** `streamControl` is just a name set
filled by `streams.setRequiredStreams(state)` (`vehicle/guistreams.lua:92`) from whatever the
UI asked for. Built-in names with server-side `streamsHandlers` are `wheelInfo`, `engineInfo`,
`stats`, `electrics`, `sensors`, `environment`. Names *without* handlers
(`wheelThermalData`, `genericGraphSimple`, `genericGraphAdvanced`) are pushed directly with
`gui.send` — do the same for your own name.

Dispatch: `onGraphicsStep` calls `guihooks.sendStreams()` only when
`streams.hasActiveStreams() and obj:getUpdateUIflag()`, flushing via
`obj:queueStreamDataJS(name, json)` (`vehicle/main.lua:104-110`).

Non-stream path: `guihooks.trigger("myEvent", arg1, arg2)` from Lua,
`$scope.$on("myEvent", ...)` in the app. UI → GELUA is `bngApi.engineLua('myLuaCode()')`.

### 4.8 On-screen messages

Exact signature, `common/guihooks.lua:120` — **four positional args, including an `icon`**:

```lua
local function message(msg, ttl, category, icon)
  if not playerInfo.firstPlayerSeated then return end
  trigger('Message', {msg = msg, ttl = (ttl or 5), category = (category or ''), icon = icon})
end
```

`ttl` defaults to 5 s, `category` to `''`. The GE-side equivalent is the global
`ui_message(msg, ttl, category, icon)` (`common/utils.lua:891`).

`msg` is either a plain string or a `{txt=..., context=...}` table:

```lua
-- localized (vehicle/beamstate.lua:537)
guihooks.message({txt = "vehicle.beamstate.tireDeflated", context = {wheelName = wheel.name}},
                 5, "vehicle.damage.deflated." .. wheel.name)

-- pre-formatted, non-localized (vehicle/wheels.lua:380)
guihooks.message({txt = string.format("Brakingdistance from %dkm/h: %.2fm",
                                      targetSpeed * 3.6, distance),
                  context = {}}, 5, "vehicle.brakingdistance")

-- with icon (ge/main.lua:803)
ui_message({txt = "vehicle.main.instability", context = {vehicle = tostring(jbeamFilename)}},
           10, 'instability', "warning")
```

`txt` is a translation key resolved UI-side; `context` supplies interpolation variables, and
its values may themselves be keys (nested lookup). `icon` is a Material Icons name
(`"warning"`, `"local_movies"`).

**`category` doubles as a dedup/replace channel** — reuse a stable per-wheel key so repeated
warnings do not spam. Clearing is regex-based:
`guihooks.message("", 0, "^vehicle\\.")` (`vehicle/main.lua:184/455`, *"clear damage messages
on vehicle restart"*).

For tire warnings:

```lua
guihooks.message({txt = "Front left tyre at 20%", context = {}},
                 5, "myTireWear.wear." .. wd.name, "warning")
```

Translation files live at `/locales/<lang>.json`
(`FS:findFiles('/locales/', '*.json', -1, true, false)`, key via
`string.match(l, 'locales/(.*).json')`). A mod can ship a `locales/` folder.

---

## 5. Existing prior art

Four mods; two with source available.

| Mod | Author | Version / date | Source | Pops tire? |
| --- | --- | --- | --- | --- |
| Luuk's Tyre Thermals and Wear | lucky4luuk | 1.3, Jan 2024 — **unsupported** | [AGPL fork](https://github.com/OfficialLambdax/LuuksTyreThermalsAndWearMod-Continued) | No |
| [Tyre Wear and Thermals Redux](https://www.beamng.com/resources/tyre-wear-and-thermals-redux.29934/) | Zesty_Maple98 | 0.20, Oct 2025, alpha | [AGPL](https://github.com/ample-samples/tyre-thermals-and-wear) | **Yes** |
| [Tyre Wear and Thermals Rework](https://www.beamng.com/resources/tyre-wear-and-thermals-rework.37615/) | nezapomnyat | **0.19.9, Jul 2026** — most current | closed | No (deliberate) |
| [Node Based Tire Wear](https://www.beamng.com/resources/node-based-tire-wear.36502/) | Jesus Goose | **2.611, Jun 2026** — most advanced | closed | Not from wear |

### 5.1 Redux — the reference implementation

Three tread rings plus a core per wheel, all in `updateGFX`. Heat from `slipEnergy`,
cornering work via `sensors.gx`, deformation energy, and vanilla brake temperature; cooling
via `sqrt(airspeed)`. Grip is a quartic in condition multiplied by a temperature→grip LUT,
applied through `setFrictionThermalSensitivity`. Pops at `condition < 0.1`. Adds
`$WheelCoolingDuctFront/Rear` tuning sliders that persist into `.pc` files.

The grip actuator, verbatim
(`lua/vehicle/extensions/auto/luukstyrethermalsandwear.lua:379-388`):

```lua
wheel:setFrictionThermalSensitivity(
    -300,     -- frictionLowTemp              default: -300
    1e7,      -- frictionHighTemp             default: 1e7
    1e-10,    -- frictionLowSlope             default: 1e-10
    1e-10,    -- frictionHighSlope            default: 1e-10
    10,       -- frictionSlopeSmoothCoef      default: 10
    tyreGrip, -- frictionCoefLow              default: 1
    tyreGrip, -- frictionCoefMiddle           default: 1
    tyreGrip  -- frictionCoefHigh             default: 1
)
```

Its wear→grip curve is a data-fitted quartic in `condition` (0–100), worth keeping as a
reference shape (1.0002 at 100, 0.770 at 0):

```lua
tyreGrip = tyreGrip * 0.7701504 + 0.002476352 * data.condition
         + 0.0001259966 * data.condition ^ 2
         - 0.000002465426 * data.condition ^ 3
         + 1.187875e-8   * data.condition ^ 4
```

### 5.2 Four real bugs in Redux's wear formula — do not copy it

1. `tempDistWeighted = avgTemp / working_temp` is a **ratio (~1.0)** but is fed to
   `tempDistToWearMult(d) = -1.8/(1 + 0.01*d^2) + 2.8`, which only responds for d ≳ 10 (i.e.
   a °C *difference*). The advertised "wear increases outside ideal temps" feature is
   **dead code**.
2. `lerp(1, 20.0, math.max(1, tempDistWeighted))` — `max` should be `min`. As written the
   factor is **always 20**, permanently 20×-ing slip wear. Almost certainly why reviewers
   report tires popping after ~2.5 laps.
3. `tempLerpValue` divides by `working_temp` twice and is then never used — heat gain no
   longer self-limits near working temperature.
4. `local loadRaw = loadRaw or vehicleMass` shadows the parameter and mixes kg with newtons.

### 5.3 Rework (current)

Nine tread slices, permanent thermal fatigue / heat damage, full flatspot on lockup, six
surface classes with dirt pickup, two HUDs. Its 0.19.5 changelog fixes *"erroneous quadratic
subtraction formula … caused hot brake discs (>350 °C) to produce negative thermal values,
effectively cooling the tyre core"* — that is precisely Redux's
`0.3 * (brakeTemp - T4 - 0.0009 * brakeTemp^2)` term, which flips sign near 370 °C.
**Keep brake→tire heat transfer monotonic.**

### 5.4 Node Based Tire Wear (most architecturally ambitious)

Per-tread-node friction *and mass*, so flatspots, camber wear and wheel imbalance **emerge**
rather than being scripted. Four thermal layers (rim / inner air / core / surface), dynamic
pressure, per-node wear visualiser, tire repair + preheat + swap, state saved per-vehicle.
Feeds off the `nodeCollision` callback. Requires fitting a "Wheel Damage" part in the
**License Plate Design** slot (a slot hijack; the auto-enable addon breaks traffic spawning).

### 5.5 Recurring failure modes — the real value of this survey

1. **Everything runs at graphics rate**, never physics rate → framerate-dependent results,
   aliased slip transients. Fixable: `enablePhysicsStepHook()`.
2. **Tire pressure declared and never used** — `OPTIMAL_PRESSURE` sits dead in both
   open-source mods. Only NBTW models pressure.
3. **Wear from rolling distance** (`angularVel * 0.05`) instead of from work → the universal
   "wears while cruising / while parked on the brakes" complaint, patched with `vehNotParked`
   flags rather than fixed at the source.
4. **Temperature barely affects grip** — Redux caps it at ~5.3% (its LUT peaks 1.000 at
   100–115 °C, bottoms at 0.947); the author admits *"tyre temps above WorkingTemp dont make
   a big difference"*. The Rework's answer was permanent thermal fatigue instead.
5. **One parameter set cannot serve racing and city driving** — every mod ping-pongs
   `WEAR_RATE` between releases; none has per-compound profiles.
6. **AI and multiplayer**: the GE→vehicle ground-model bridge only targets
   `be:getPlayerVehicle(0)`, so **AI cars silently run at friction 1.0**. All client-side,
   nothing authoritative — Luuk cited BeamMP desync as why popping never shipped.
7. **Wheel identity is chronically fragile** — front/rear inferred from
   `wheel_name:sub(1,1) == "f"`; >4-wheel vehicles misplace in the UI.
8. **Injecting tuning variables is dangerous** — `tableMerge` into `vdata.variables` plus
   `debug.getlocal(3, 3)` config scraping produced a fatal C++ exception on part change in
   the Rework (fixed in 0.19.9).
9. **Nobody has the domain knowledge.** Redux's author, publicly: *"I've ran into many issues
   due to lack of domain knowledge surrounding tyre behavior… there is too little publicly
   accessible educational material… My degree-level mechanical engineering experience has only
   taken development so far."* He is recruiting tyre engineers.

---

## 6. Recommended wear model

Design for **defensibility and calibratability**, not fidelity. Four decoupled blocks, each
independently tunable.

### 6.1 Wear driver — friction work (Archard), not distance

Archard's law: wear volume ∝ normal load × sliding distance ∝ **frictional energy
dissipated**. So integrate friction power, and *never* add a term proportional to
`angularVelocity` — that is the single most-complained-about bug in every existing mod.

Best data (physics rate, per node), via a wrapped `onNodeCollision`:

```lua
-- accumulate per wheel, per physics step
local P = slipForce * slipVel          -- watts dissipated at this tread node
wheelFrictionEnergy[wheelId] = wheelFrictionEnergy[wheelId] + P * dtPhys
```

Cheaper fallback (graphics rate, per wheel): use `wd.slipEnergy`. Treat it as an
arbitrary-scale rate and absorb the scale into your constant (see §8).

```
dw/dt = k_w * P_fric * f_temp(T) * f_surface(groundModel) / (referenceLoad * tireWidth)
```

- `f_surface` from `groundModel.staticFrictionCoefficient` — asphalt abrades far more than
  grass. Fetch GE-side from `core_environment.groundModels` and **broadcast to all vehicles,
  not just `getPlayerVehicle(0)`**.
- `f_temp` — Arrhenius-ish: rubber abrades faster hot, and cold rubber chunks.
  `f_temp(T) = 1 + a*max(0, (T-T_opt)/50)^2 + b*max(0, (T_cold-T)/50)^2`, `a≈2`, `b≈0.5`.
- Normalise by load and width so light and heavy cars behave sanely.
- Calibrate `k_w` so one hard track lap ≈ 1–3% wear, and normal street driving is
  essentially free.

Store `w ∈ [0,1]` per wheel (or per tread zone for flatspots).

### 6.2 Temperature — lumped capacity, energy balance

One tread node plus one core node per tire is plenty, and avoids the 3-vs-9-zone rabbit hole:

```
m_tread * c * dT_tread/dt = eta * P_fric
                          + k_core  * (T_core  - T_tread)
                          - h(v)    * A       * (T_tread - T_env)
                          - sigma * eps * A   * (T_tread^4 - T_env^4)

m_core  * c * dT_core/dt  = k_core  * (T_tread - T_core)
                          + k_brake * (T_brake - T_core)     -- MONOTONIC, see below
                          - h_core(v) * A_core * (T_core - T_env)
```

Starting constants: `c_rubber ≈ 2000 J/(kg·K)`, `m_tread ≈ 4 kg`, `m_core ≈ 6 kg`,
`A ≈ 0.5 m²`, `eta ≈ 0.5–0.7` (fraction of friction power into the tire vs the road),
`h(v) = h0 + h1*sqrt(v_air)` with `h0 ≈ 10`, `h1 ≈ 15 W/(m²·K)`.

Inputs already available: `T_env = obj:getEnvTemperature() - 273.15`,
`v_air = electrics.values.airflowspeed`, `T_brake = wd.brakeSurfaceTemperature`
(**nil on AI / traffic cars — default to ambient**).

> **Keep brake→tire transfer strictly monotonic.** `k_brake * (T_brake - T_core)` is fine. Do
> not add a `-c*T_brake^2` damping term to tame runaway — Redux did, and it inverts above
> ~370 °C, *cooling* the tire. If you need a cap, clamp:
> `min(k_brake * (T_brake - T_core), Q_max)`.

### 6.3 Grip multiplier — separable, applied once

```lua
local gripMult = clamp(gripFromWear(w) * gripFromTemp(tTread), 0.4, 1.0)
local wobj = obj:getWheel(wd.wheelID)
if wobj then
  wobj:setFrictionThermalSensitivity(-300, 1e7, 1e-10, 1e-10, 10,
                                     gripMult, gripMult, gripMult)
end
```

**Wear → grip: flat, then a cliff.** Real tires barely lose grip until the tread is nearly
gone.

```lua
local function gripFromWear(w)   -- w = 0 new .. 1 worn out
  return 1.0 - 0.05 * w - 0.25 * w ^ 4   -- 1.00 new, ~0.95 half-worn, 0.70 at 0
end
```

(Redux's data-fitted quartic in §5.1 is the same shape; either is defensible.)

**Temperature → grip: plateau with soft shoulders.**

```lua
local function gripFromTemp(T)
  local d = (T - T_opt) / T_window                  -- T_opt ~85 race / ~65 street; T_window ~35
  return 1.0 - GRIP_TEMP_DEPTH * math.min(d * d, 1) -- clamp the parabola
end
```

Derive `T_opt` and `T_window` from `treadCoef` (slick → hotter, narrower window). On
`GRIP_TEMP_DEPTH`: real data says ~0.05, which is imperceptible; Redux used 0.05 and its
author admits temps "don't make a big difference". **Recommend 0.12–0.15** — a deliberate
playability-over-realism call, so expose it as a user setting rather than presenting it as
physical.

### 6.4 Blowout — two independent paths

```lua
-- Path A: tread gone
if w >= 1.0 then pop(cid) end

-- Path B: sustained overheat damage integrator.
-- NOT an instantaneous threshold: avoids a single spike popping a tire,
-- and gives the player a warning window.
if tCore > T_CRIT then
  heatDamage = heatDamage + (tCore - T_CRIT) * dt / T_CRIT_SCALE
else
  heatDamage = math.max(0, heatDamage - dt * 0.05)   -- slow recovery
end
if heatDamage >= 1.0 then pop(cid) end
```

`T_CRIT` ≈ 200 °C street / 250 °C race. Sanity-check against the jbeam-facing `smokingTemp`
and `meltingTemp` fields if the tire part defines them.

Warn before popping — `guihooks.message` with a stable per-wheel category key at 80% and 95%
— plus permanent heat fatigue (à la the Rework) so an overheat event costs something even
when it does not burst.

Note `enableTireSupportBeams` (**new in 0.38**) keeps deflated tire nodes off the rim, i.e.
it improves how blowouts behave. Related reinforcement-beam family:
`enableTireReinfBeams`, `enableTireLbeams`, `enableTireSideReinfBeams`,
`enableTreadReinfBeams` (*"Improves lateral stiffness and reduces grip loss at high speeds"*),
`enableTirePeripheryReinfBeams`. (`enableTireReinflation` does **not** exist.)

### 6.5 Skeleton

```lua
-- lua/vehicle/extensions/auto/myTireWear.lua
local M = {}

local wear, tTread, tCore, heatDmg, fricEnergy = {}, {}, {}, {}, {}

local function initState()
  enablePhysicsStepHook()   -- REQUIRED, else onPhysicsStep never fires
  local tEnv = obj:getEnvTemperature() - 273.15
  for cid, wd in pairs(wheels.wheels) do
    wear[cid], tTread[cid], tCore[cid] = 0, tEnv, tEnv
    heatDmg[cid], fricEnergy[cid] = 0, 0
  end
end

local function onPhysicsStep(dtPhys)
  -- bank friction energy per wheel; see 2.5 for the onNodeCollision wrapper
end

local function updateGFX(dt)
  local tEnv   = obj:getEnvTemperature() - 273.15
  local airspd = electrics.values.airflowspeed or 0
  local stream = {data = {}}

  for cid, wd in pairs(wheels.wheels) do
    -- 1. integrate wear from the energy banked in onPhysicsStep
    -- 2. integrate the two-node thermal model
    -- 3. apply grip
    local g = clamp(gripFromWear(wear[cid]) * gripFromTemp(tTread[cid]), 0.4, 1.0)
    local wobj = obj:getWheel(wd.wheelID)
    if wobj then
      wobj:setFrictionThermalSensitivity(-300, 1e7, 1e-10, 1e-10, 10, g, g, g)
    end
    -- 4. blowout checks (see 6.4)

    table.insert(stream.data, {name = wd.name, wear = wear[cid],
                               temp = tTread[cid], core = tCore[cid], grip = g})
  end

  if streams.willSend("MyTireWear") then gui.send("MyTireWear", stream) end
end

-- NOTE: onInit is NEVER called for a vehicle auto/ extension (see 4.4)
M.onExtensionLoaded = initState
M.onVehicleLoaded   = initState
M.onReset           = initState
M.onPhysicsStep     = onPhysicsStep
M.updateGFX         = updateGFX
M.onSerialize       = function() return {wear = wear, tTread = tTread, tCore = tCore} end
M.onDeserialize     = function(d)
  if d then wear, tTread, tCore = d.wear, d.tTread, d.tCore end
end

return M
```

---

## 7. jbeam reference — grip parameters

Official: <https://documentation.beamng.com/modding/vehicle/sections/wheels/>
(parameter list current as of 0.38.5.0).

| Field | Default | Meaning |
| --- | --- | --- |
| `frictionCoef` | — | Friction coef of tire tread nodes. "Determines overall grip of the tire." Multiplier on the groundmodel's static friction |
| `slidingFrictionCoef` | — | Friction coef when sliding |
| `stribeckVelMult` | — | "Affects the velocity at which the sliding coefficient will apply" |
| `stribeckExponent` | 1.75 | "Smaller values will result in a more progressive transition" |
| `treadCoef` | 1 | Slick 0, offroad ~0.9, standard 0.7. Multiplied against each ground type's roughness coefficient; also drives tire sounds |
| `softnessCoef` | 0.6 | "Influences the time variant friction behavior." Higher (max 1) = soft racing slick. Also affects squeal |
| `noLoadCoef` | — | Friction modifier unloaded (should be > `fullLoadCoef`) |
| `loadSensitivitySlope` | — | "The loss of coef per newton of normal force" |
| `fullLoadCoef` | — | Friction modifier fully loaded |
| `nodeMaterial` | — | Physics material of tire tread nodes |
| `pressurePSI` | — | Fill pressure. Docs' real-world targets: road 25–35, racing slick 22–27, light truck 30–50, rock crawler 5–15, heavy truck 50–100 |
| `maxPressurePSI` | — | Stability clamp |
| `numRays` | — | Even, 10–20. Docs warn high values hurt cornering / longitudinal stiffness |

Load sensitivity is computed **per node**: *"As the force is calculated per node, the normal
force used is the force on each individual node, not the force on the wheel itself."*

The other half of the friction equation is the groundmodel —
`staticFrictionCoefficient`, `slidingFrictionCoefficient`, `roughnessCoefficient`,
`hydrodynamicFriction`, `stribeckVelocity` in `/art/groundmodels.json` or
`levels/<levelName>/groundModels/*.json`
(<https://documentation.beamng.com/modding/levels/level_formats/groundmodels/>).

The **undocumented** thermal fields consumed by `setThermal` / `setFrictionThermalSensitivity`
are listed in §1.2.

---

## 8. Unverified and open questions

Carry these into implementation as things to check on the Windows/Linux test machine.

1. **`wd.slipEnergy` units and semantics.** I could not determine its exact units, or whether
   it is already dt-integrated. Treat it as an arbitrary-scale rate and absorb the scale into
   your calibration constant. If you use the `onNodeCollision` path
   (`slipForce * slipVel * dtPhys`, watts → joules) this is moot, which is another argument
   for that path.
2. **0.38.6 parity for all source-derived APIs.** No 0.38 Lua dump is publicly available. I
   diffed `processWheels()` between 0.34.2 and 0.36 — identical (3-line offset only) — and
   `getWheelAvgTemperature` / `getWheelCoreTemperature` are present in both, and a mod packed
   in Oct 2025 uses `setFrictionThermalSensitivity`. Regression is unlikely but unproven.
   **Sanity check:** `dump(obj:getWheel(0))` and confirm `setThermal` /
   `setFrictionThermalSensitivity` appear.
3. **Whether any *stock* vehicle jbeam enables the thermal coefficients.** I found none, but
   I had only the Lua tree, not vehicle files, and GitHub code search returned 0 jbeam hits.
   Check `vehicles/common/` and a few tire parts directly.
4. **The `onInit`-never-fires consequence for existing mods.** The gating is proven from
   source; what I did not do is empirically confirm that Redux and `tyrewearandthermals2`
   are actually broken on first spawn as a result. Worth a quick test, since it validates the
   reading.
5. **`setRequiredStreams` has no Lua caller anywhere in the tree.** The UI →
   vehicle propagation from `StreamsManager.add()` happens in C++/JS, outside the Lua source.
   The mechanism works (vanilla relies on it) but its exact path is unverified.
6. **Runtime-injectable Vue UI apps look impossible.** The
   [forum thread](https://www.beamng.com/threads/vue-ui-apps.104230/) is unanswered by staff;
   community reading is that Vue apps are defined at build time in
   `ui/ui-vue/src/modules/apps/index.js`. AngularJS is correct for 0.38 — but this is a
   migration risk to watch for 0.39+.
7. **Mod-local translation file naming.** I verified the directory and glob
   (`/locales/*.json`) but not whether the convention is `en-US.json` or `en.json`.
8. **Multiplayer / AI correctness is unsolved by anyone.** Every existing mod is client-side
   and silently leaves AI vehicles at friction 1.0. If BeamMP or AI parity matters, treat it
   as unexplored design space, not a solved problem.
