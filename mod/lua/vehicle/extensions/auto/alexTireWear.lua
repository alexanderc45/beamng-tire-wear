-- Realistic Tire Wear v1 -- per-wheel tread-depth + thermal model.
-- Vehicle extension, auto-loaded from lua/vehicle/extensions/auto/ on every spawn.
-- Global name is the file basename ("alexTireWear"), so it is namespaced already.
--
-- Tires are ALWAYS brand new on spawn and on reset: nothing is persisted (see the
-- onSerialize note at the bottom).

local M = {}

-- ---------------------------------------------------------------------------
-- Tuning. Every play-testable constant lives here and nowhere else.
-- Every constant is re-read on each step, so live edits from the console take
-- effect immediately:  alexTireWear.settings.slipEnergyScale = 0.1
-- ---------------------------------------------------------------------------
local settings = {
  -- Per-wheel debug telemetry to the console (uiUpdateInterval-independent).
  --   alexTireWear.settings.debug = true
  debug = false,
  debugInterval = 5.0,      -- seconds between debug lines per wheel

  -- CALIBRATION KNOB #1. wd.slipEnergy's units / whether it is already
  -- dt-integrated are unverified (research.md sec.8 item 1), so it is treated as an
  -- arbitrary-scale rate and the whole scale is absorbed here. If wear/heat come
  -- out uniformly too fast or too slow on the test machine, move this first --
  -- it scales heating and wear together, which is what you usually want.
  -- Deliberately conservative until we have a real magnitude off the test machine.
  slipEnergyScale = 0.25,

  -- Tread depth, mm. Wear is integrated as a 0..1 scalar internally and mapped onto
  -- this range for display / warnings / blowout. treadDepthDead is the cords-showing,
  -- legal-limit point at which the tire is finished.
  treadDepthNew = 8.0,
  treadDepthDead = 1.6,

  -- Wear. wear/s = wearRate * slipPower * tempWearMult(treadTemp), rate-capped.
  -- CALIBRATION KNOB #2 (wear only, independent of heating).
  wearRate = 1.0e-7,
  -- Structural guard, not a tuning nicety: slipEnergy's true magnitude is unknown,
  -- so an uncapped rate means a large-magnitude vehicle destroys a tire in seconds.
  -- This puts a hard floor on how fast a new tire can possibly reach the cords.
  maxWearPerSecond = 1.0 / 150.0,

  -- Wear-vs-temperature multiplier breakpoints (degC).
  wearTempCold = 40.0,      -- at or below: wearMultCold
  wearTempOptLow = 75.0,    -- optimal band start (multiplier 1.0)
  wearTempOptHigh = 100.0,  -- optimal band end
  wearTempHot = 115.0,      -- at or above: wearMultHot
  wearMultCold = 0.6,
  wearMultHot = 3.5,

  -- Thermal model (degC/s per unit of the driving quantity).
  slipHeatCoef = 6.0e-4,        -- tread heating from slip power
  rollHeatCoef = 1.0e-5,        -- tread heating from load * speed (rolling losses)
  treadCoreConduction = 0.03,   -- tread <-> core coupling
  coreCondRatio = 0.4,          -- core has more thermal mass than the tread layer
  treadCoolCoef = 0.02,         -- convective cooling of the tread
  coreCoolCoef = 0.006,         -- convective cooling of the core
  coolingAirCoef = 0.02,        -- cooling multiplier = 1 + coolingAirCoef * airspeed
  brakeHeatCoef = 0.002,        -- brake surface -> core; kept monotonic (never cools)
  brakeHeatMax = 2.0,           -- clamp on brake heat input, degC/s
  minTemp = -80.0,
  -- Operative range ceiling. Not a physical melting point -- a numerical clamp, kept
  -- near "smoking rubber" rather than at some absurd 600 degC so the displayed number
  -- stays meaningful. tempWearMult already saturates at wearTempHot, so this value does
  -- not affect wear rate.
  maxTemp = 300.0,
  fallbackEnvTemp = 20.0,       -- if obj:getEnvTemperature() is unavailable

  -- Grip from wear: gentle decline, then a knee once the tread is nearly gone.
  -- wearGripKnee 0.8 lands at ~2.9mm of tread, i.e. the low-tread zone.
  wearGripKnee = 0.8,
  wearGripAtKnee = 0.88,
  wearGripAtDead = 0.65,

  -- Grip from temperature: plateau in the optimal window, soft shoulders.
  gripColdTemp = 20.0,
  gripColdMult = 0.85,
  gripTempOptLow = 75.0,
  gripTempOptHigh = 100.0,
  gripHotTemp = 135.0,
  gripHotMult = 0.80,

  gripMin = 0.4,             -- hard floor on the actuated multiplier
  gripApplyEpsilon = 0.002,  -- only re-arm the actuator when grip moved this much

  -- There is exactly ONE blowout path: tread depletion. Temperature never bursts a
  -- tire; it punishes the driver through tempWearMult instead (an overheated tire eats
  -- its tread up to wearMultHot times faster) and through gripFromTemp.

  -- Driver warnings (one-shot per stage, per tire, reset with the vehicle).
  wearWarnStages = {0.5, 0.75, 0.9},
  -- Overheat advisory, with hysteresis so it cannot chatter. Re-arms once the tread
  -- drops back below overheatClearTemp.
  overheatWarnTemp = 120.0,
  overheatClearTemp = 100.0,

  streamName = "alexTireWear",
  uiUpdateInterval = 0.1,   -- seconds between UI stream pushes
  reinitInterval = 1.0,     -- seconds between self-heal wheel-list rescans
}

-- ---------------------------------------------------------------------------

local abs, floor = math.abs, math.floor

local wheelStates = {}    -- wheel name -> state (name is stable across cid churn)
local activeList = {}     -- cid-sorted array of the states we integrate
local envTemp = settings.fallbackEnvTemp
local coolMult = 1.0
local uiTimer = 0
local reinitTimer = 0
local debugTimer = 0
local actuatorOk = true
local actuatorChecked = false
local streamCache = {wheels = {}, count = 0, treadNew = 8.0, treadDead = 1.6}
local srcTable = nil         -- the wheel table initState built activeList from
local builtWheelCount = -1   -- candidate count of the source table we last built from
local beaconCount = -1       -- last count we logged, so re-inits only log on change
local gfxErrorLogged = false

local function getEnvTemp()
  if obj and obj.getEnvTemperature then
    local t = obj:getEnvTemperature()
    if type(t) == "number" and t == t then return t - 273.15 end
  end
  return settings.fallbackEnvTemp
end

-- wear 0..1  ->  remaining tread depth in mm
local function treadDepth(w)
  local s = settings
  if w < 0 then w = 0 elseif w > 1 then w = 1 end
  return s.treadDepthNew - w * (s.treadDepthNew - s.treadDepthDead)
end

local function tempWearMult(t)
  local s = settings
  if t <= s.wearTempCold then return s.wearMultCold end
  if t < s.wearTempOptLow then
    return s.wearMultCold + (1.0 - s.wearMultCold) * (t - s.wearTempCold) / (s.wearTempOptLow - s.wearTempCold)
  end
  if t <= s.wearTempOptHigh then return 1.0 end
  if t >= s.wearTempHot then return s.wearMultHot end
  return 1.0 + (s.wearMultHot - 1.0) * (t - s.wearTempOptHigh) / (s.wearTempHot - s.wearTempOptHigh)
end

local function gripFromWear(w)
  local s = settings
  if w <= 0 then return 1.0 end
  if w <= s.wearGripKnee then
    return 1.0 + (s.wearGripAtKnee - 1.0) * (w / s.wearGripKnee)
  end
  local f = (w - s.wearGripKnee) / (1.0 - s.wearGripKnee)
  if f > 1 then f = 1 end
  return s.wearGripAtKnee + (s.wearGripAtDead - s.wearGripAtKnee) * f
end

local function gripFromTemp(t)
  local s = settings
  if t <= s.gripColdTemp then return s.gripColdMult end
  if t < s.gripTempOptLow then
    return s.gripColdMult + (1.0 - s.gripColdMult) * (t - s.gripColdTemp) / (s.gripTempOptLow - s.gripColdTemp)
  end
  if t <= s.gripTempOptHigh then return 1.0 end
  if t >= s.gripHotTemp then return s.gripHotMult end
  return 1.0 + (s.gripHotMult - 1.0) * (t - s.gripTempOptHigh) / (s.gripHotTemp - s.gripTempOptHigh)
end

-- Three different ids per wheel, and they are NOT interchangeable:
--   cid      -- the key in the table we iterate. For wheels.wheelRotators that really is
--              wd.cid, but for wheels.wheels after initSecondStage it is a sequential
--              counter (vehicle/wheels.lua:1104). Use it only to index that same table.
--   dataCid  -- wd.cid, i.e. the key into v.data.wheels. This is what
--              beamstate.deflateTire() expects (it does v.data.wheels[arg];
--              vanilla passes wd.cid at vehicle/wheels.lua:341).
--   wheelID  -- what obj:getWheel() expects (vanilla, vehicle/wheels.lua:915).
local function newState(name, cid, dataCid, wheelID)
  return {
    name = name, cid = cid, dataCid = dataCid, wheelID = wheelID,
    wear = 0, treadTemp = envTemp, coreTemp = envTemp,
    popped = false,
    grip = 1.0, lastGrip = -1,       -- -1 forces one actuator write after init
    slipPower = 0, slipRaw = 0, rollPower = 0, brakeTemp = envTemp,
    wearWarn = 0, overheatWarned = false,
  }
end

local function resetState(st)
  st.wear = 0
  st.treadTemp, st.coreTemp = envTemp, envTemp
  st.popped = false
  st.grip, st.lastGrip = 1.0, -1
  st.slipPower, st.slipRaw, st.rollPower, st.brakeTemp = 0, 0, 0, envTemp
  st.wearWarn, st.overheatWarned = 0, false
end

local function warn(st, txt, channel)
  if guihooks and guihooks.message then
    guihooks.message({txt = txt, context = {}}, 5, "alexTireWear." .. channel .. "." .. st.name, "warning")
  end
end

local function popTire(st, reason)
  if st.popped then return end
  st.popped = true
  st.grip, st.lastGrip = settings.gripMin, -1
  local wd = srcTable and srcTable[st.cid]
  if wd and not wd.isTireDeflated and not wd.isBroken and beamstate and beamstate.deflateTire then
    beamstate.deflateTire(st.dataCid)
  end
  warn(st, string.format("%s tire blowout -- %s", tostring(st.name), reason), "blowout")
end

-- How many entries of a wheel table we would track. Kept in sync with the filter
-- used by initState below, so the cheap "did the wheel setup change?" check in
-- updateGFX cannot disagree with what we actually built.
local function candidateCount(tbl)
  if type(tbl) ~= "table" then return 0 end
  local n = 0
  for _, wd in pairs(tbl) do
    if type(wd) == "table" and wd.hasTire ~= false then n = n + 1 end
  end
  return n
end

-- `wheels.wheels` is the normal source, but note it is NOT cid-keyed after
-- wheels.initSecondStage(): that function does `M.wheels = {}` and re-fills it with a
-- *sequential* index, keeping only entries whose rotatorType == "wheel"
-- (vehicle/wheels.lua:1082-1106). So a vehicle whose tires are not plain "wheel"
-- rotators, or one whose second-stage init bailed out early on missing refNodes, can
-- leave wheels.wheels empty while wheels.wheelRotators is fully populated. Fall back to
-- wheelRotators in that case rather than silently tracking nothing.
local function pickWheelTable()
  local w = wheels and wheels.wheels
  local n = candidateCount(w)
  if n > 0 then return w, n, "wheels.wheels" end
  local r = wheels and wheels.wheelRotators
  n = candidateCount(r)
  if n > 0 then return r, n, "wheels.wheelRotators" end
  return nil, 0, "none"
end

-- Rebuilds the wheel list. Tires always start new, so this is unconditionally fresh;
-- it is safe to call repeatedly (the self-heal rescan in updateGFX does).
local function initState()
  envTemp = getEnvTemp()
  coolMult = 1.0
  uiTimer = 0
  reinitTimer = 0
  debugTimer = 0
  actuatorOk = true
  actuatorChecked = false
  activeList = {}

  local wheelsTable, sourceCount, sourceName = pickWheelTable()
  builtWheelCount = sourceCount
  srcTable = wheelsTable
  if not wheelsTable then
    wheelStates = {}
    if beaconCount ~= 0 then
      beaconCount = 0
      if log then
        log("W", "alexTireWear",
          "loaded, tracking 0 tires -- no usable entries in wheels.wheels or wheels.wheelRotators (will rescan)")
      end
    end
    return
  end

  local kept = {}
  for cid, wd in pairs(wheelsTable) do
    -- wheels without a tire (and broken hubs) get no wear model at all
    if type(wd) == "table" and wd.hasTire ~= false then
      local name = wd.name
      if type(name) ~= "string" then name = "wheel" .. tostring(cid) end
      if kept[name] then name = name .. "#" .. tostring(cid) end
      local st = wheelStates[name]
      if not st then
        st = newState(name, cid, wd.cid or cid, wd.wheelID or cid)
      else
        st.cid = cid
        st.dataCid = wd.cid or cid
        st.wheelID = wd.wheelID or cid
        resetState(st)
      end
      kept[name] = st
      activeList[#activeList + 1] = st
    end
  end
  wheelStates = kept

  -- deterministic iteration order (pairs() over the wheel table is not)
  table.sort(activeList, function(a, b) return (a.cid or 0) < (b.cid or 0) end)

  -- Without this, M.onPhysicsStep silently never fires (vehicle/main.lua gates it).
  if type(enablePhysicsStepHook) == "function" then enablePhysicsStepHook() end

  -- Load beacon. "Is the extension even running, and on how many tires?" has to be
  -- answerable from the console log alone. Logged on first init and again whenever a
  -- rescan changes the count; silent on the redundant onExtensionLoaded/onVehicleLoaded
  -- double-call and on plain resets.
  local n = #activeList
  if n ~= beaconCount then
    beaconCount = n
    if log then
      local names = {}
      for i = 1, n do names[i] = tostring(activeList[i].name) end
      log(n > 0 and "I" or "W", "alexTireWear",
        string.format("loaded, tracking %d tires from %s [%s]", n, sourceName, table.concat(names, ", ")))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Physics rate (2000 Hz). Cheap arithmetic only: no allocations, no C++ calls,
-- no UI, no deflation. Inputs are latched by updateGFX below.
-- ---------------------------------------------------------------------------
local function onPhysicsStep(dtPhys)
  local list = activeList
  local n = #list
  if n == 0 or not dtPhys or dtPhys <= 0 then return end
  local s = settings
  local envT, cool = envTemp, coolMult
  local loT, hiT = s.minTemp, s.maxTemp
  local wearCap = s.maxWearPerSecond

  for i = 1, n do
    local st = list[i]
    if not st.popped then
      local tt, tc = st.treadTemp, st.coreTemp
      local slipPower = st.slipPower

      local cond = s.treadCoreConduction * (tc - tt)
      local heatIn = s.slipHeatCoef * slipPower + s.rollHeatCoef * st.rollPower
      local brakeQ = s.brakeHeatCoef * (st.brakeTemp - tc)
      if brakeQ < 0 then brakeQ = 0 elseif brakeQ > s.brakeHeatMax then brakeQ = s.brakeHeatMax end

      tt = tt + (heatIn + cond - s.treadCoolCoef * cool * (tt - envT)) * dtPhys
      tc = tc + (brakeQ - cond * s.coreCondRatio - s.coreCoolCoef * cool * (tc - envT)) * dtPhys

      if tt ~= tt or tt < loT then tt = envT elseif tt > hiT then tt = hiT end
      if tc ~= tc or tc < loT then tc = envT elseif tc > hiT then tc = hiT end
      st.treadTemp, st.coreTemp = tt, tc

      if slipPower > 0 and st.wear < 1 then
        local rate = s.wearRate * slipPower * tempWearMult(tt)
        if rate > wearCap then rate = wearCap end
        local w = st.wear + rate * dtPhys
        st.wear = w < 1 and w or 1
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Graphics rate. Samples fresh wheel data, drives the actuator, pops tires,
-- warns the driver, feeds the UI stream.
-- ---------------------------------------------------------------------------
-- module-level so the pcall probe below never allocates a closure
local function setGrip(wobj, g)
  -- flatten the (jbeam-default-neutral) temperature curve and repurpose the three
  -- friction coefficients as one whole-wheel grip multiplier
  wobj:setFrictionThermalSensitivity(-300, 1e7, 1e-10, 1e-10, 10, g, g, g)
end

local function applyGrip(st, g)
  if not actuatorOk then return end
  local wobj = obj and obj.getWheel and obj:getWheel(st.wheelID)
  if not wobj then return end
  if actuatorChecked then
    setGrip(wobj, g)
    st.lastGrip = g
    return
  end
  -- first call only: verify the API exists on this game version before trusting it
  local ok = pcall(setGrip, wobj, g)
  if ok then
    actuatorChecked = true
    st.lastGrip = g
  else
    actuatorOk = false
    if log then log("E", "alexTireWear", "setFrictionThermalSensitivity unavailable; grip actuation disabled") end
  end
end

local function updateGFXInner(dt)
  dt = dt or 0
  local s = settings

  -- Self-heal. onExtensionLoaded / onVehicleLoaded fire after wheels.init() and
  -- wheels.initSecondStage(), so the wheel list is normally ready by then -- but if a
  -- vehicle ever populates or re-shapes its wheel tables later (or does it in a way our
  -- filter rejects at spawn time), a one-shot init would leave us tracking nothing
  -- forever with no callback to recover from. Rescan at 1 Hz whenever we have nothing,
  -- or whenever the live wheel count no longer matches what we built from.
  reinitTimer = reinitTimer + dt
  if reinitTimer >= s.reinitInterval then
    reinitTimer = 0
    local _, liveCount = pickWheelTable()
    if liveCount > 0 and (#activeList == 0 or liveCount ~= builtWheelCount) then
      initState()
    end
  end

  local wheelsTable = srcTable
  local n = #activeList

  envTemp = getEnvTemp()
  local ev = electrics and electrics.values
  local airspeed = 0
  if ev then airspeed = ev.airflowspeed or ev.airspeed or 0 end
  if type(airspeed) ~= "number" or airspeed ~= airspeed or airspeed < 0 then airspeed = 0 end
  coolMult = 1.0 + s.coolingAirCoef * airspeed

  for i = 1, n do
    local st = activeList[i]
    local wd = wheelsTable and wheelsTable[st.cid]
    if wd then
      -- latch physics-loop inputs. wheels.updateGFX refreshed these just before
      -- this hook, so read them rather than re-calling the C++ getter.
      local slipEnergy = wd.slipEnergy
      if type(slipEnergy) ~= "number" or slipEnergy ~= slipEnergy or slipEnergy < 0 then slipEnergy = 0 end
      st.slipRaw = slipEnergy
      st.slipPower = slipEnergy * s.slipEnergyScale

      local load = wd.downForce or wd.downForceRaw or 0
      if type(load) ~= "number" or load ~= load or load < 0 then load = 0 end
      local speed = wd.wheelSpeed or 0
      if type(speed) ~= "number" or speed ~= speed then speed = 0 end
      st.rollPower = load * abs(speed)

      -- nil on AI / traffic vehicles: fall back to ambient
      local bt = wd.brakeSurfaceTemperature
      st.brakeTemp = (type(bt) == "number" and bt == bt) and bt or envTemp

      if wd.isTireDeflated or wd.isBroken or wd.hasTire == false then st.popped = true end
    else
      st.slipRaw, st.slipPower, st.rollPower = 0, 0, 0
    end

    -- The one and only blowout path: the tread is gone. Deflation happens here, not in
    -- the physics hook, to keep that hook free of engine calls.
    if not st.popped and st.wear >= 1 then
      popTire(st, string.format("tread gone (%.1fmm)", treadDepth(1)))
    end

    local g = s.gripMin
    if not st.popped then
      g = gripFromWear(st.wear) * gripFromTemp(st.treadTemp)
      if g > 1 then g = 1 elseif g < s.gripMin then g = s.gripMin end
    end
    st.grip = g
    if abs(g - st.lastGrip) > s.gripApplyEpsilon then applyGrip(st, g) end

    if not st.popped then
      -- staged driver warnings, in tread-depth terms
      local stages = s.wearWarnStages
      while st.wearWarn < #stages and st.wear >= stages[st.wearWarn + 1] do
        st.wearWarn = st.wearWarn + 1
        warn(st, string.format("%s tire tread %s: %.1fmm", tostring(st.name),
          st.wearWarn >= 2 and "LOW" or "half worn", treadDepth(st.wear)), "wear")
      end
      -- Overheat advisory only -- heat no longer bursts anything, it just accelerates
      -- tread loss (up to wearMultHot x). Hysteresis on the way back down.
      if not st.overheatWarned then
        if st.treadTemp >= s.overheatWarnTemp then
          st.overheatWarned = true
          warn(st, string.format("%s tire overheating (%d C) -- wearing fast",
            tostring(st.name), floor(st.treadTemp + 0.5)), "heat")
        end
      elseif st.treadTemp <= s.overheatClearTemp then
        st.overheatWarned = false
      end
    end
  end

  -- Calibration telemetry. One compact line per wheel every debugInterval seconds,
  -- carrying both the raw wd.slipEnergy and the scaled value, so the real magnitude of
  -- slipEnergy on the test machine can simply be read off the console and pasted back.
  if s.debug and n > 0 then
    debugTimer = debugTimer + dt
    if debugTimer >= s.debugInterval then
      debugTimer = 0
      if log then
        for i = 1, n do
          local st = activeList[i]
          log("I", "alexTireWear", string.format(
            "dbg %-6s slipRaw=%10.1f slipScaled=%10.1f tread=%6.1fC core=%6.1fC wear=%5.1f%% depth=%4.2fmm grip=%5.3f%s",
            tostring(st.name), st.slipRaw, st.slipPower, st.treadTemp, st.coreTemp,
            st.wear * 100, treadDepth(st.wear), st.grip,
            st.popped and " POPPED" or ""))
        end
      end
    end
  end

  -- UI stream, throttled to ~10 Hz.
  --
  -- Transport is exactly what vanilla's own custom-stream extension does
  -- (vehicle/extensions/advancedwheeldebug.lua:94-95): the only gate is
  -- playerInfo.firstPlayerSeated, then a bare gui.send. That handles multi-vehicle
  -- correctness -- every vehicle in the world (traffic included) runs this extension,
  -- and only the one the player sits in sends. gui.send is guihooks.queueStream, which
  -- itself no-ops unless guihooks.updateStreams is set (vehicle/main.lua:110-114 sets
  -- that from streams.hasActiveStreams() and obj:getUpdateUIflag()), so an idle or
  -- closed UI already costs us nothing.
  --
  -- Deliberately NOT gated on streams.willSend(): that additionally requires
  -- streamControl[name], which is filled only when C++ pushes the UI's requested-stream
  -- list into this vehicle VM (streams.setRequiredStreams has no Lua caller anywhere in
  -- the tree). Any vehicle that never receives that push would go permanently silent,
  -- which is not a failure mode worth the microseconds it saves. Vanilla's own
  -- custom-stream extension does not use it either.
  uiTimer = uiTimer + dt
  if uiTimer < s.uiUpdateInterval then return end
  uiTimer = 0
  if playerInfo and not playerInfo.firstPlayerSeated then return end
  if not (gui and gui.send) then return end

  -- Sent even when n == 0, so the app can tell "extension is running, this vehicle has
  -- no tires we track" apart from "nothing is sending at all".
  local out = streamCache.wheels
  for i = 1, n do
    local st = activeList[i]
    local e = out[i]
    if not e then e = {}; out[i] = e end
    e.name = st.name
    e.wear = st.wear
    e.treadDepth = treadDepth(st.wear)
    e.treadTemp = st.treadTemp
    e.coreTemp = st.coreTemp
    e.grip = st.grip
    e.popped = st.popped
    e.slipPower = st.slipPower   -- debug only; the app does not render it
    e.slipRaw = st.slipRaw       -- debug only
  end
  for i = #out, n + 1, -1 do out[i] = nil end
  streamCache.count = n
  streamCache.treadNew = s.treadDepthNew
  streamCache.treadDead = s.treadDepthDead
  gui.send(s.streamName, streamCache)
end

-- extensions.hook (common/extensions.lua hookFast, :803) does NOT pcall its callees, and
-- updateGFX is dispatched from vehicle/main.lua:100 -- i.e. before guihooks.sendStreams()
-- and before hydros/powertrain/sounds/props update. An unhandled error here would
-- therefore take out every UI stream and half the vehicle's graphics-step work, every
-- frame, and would also leave hookFast's lazily-built function cache half-populated.
-- Contain it and shout once instead.
local function updateGFX(dt)
  local ok, err = pcall(updateGFXInner, dt)
  if not ok and not gfxErrorLogged then
    gfxErrorLogged = true
    if log then
      log("E", "alexTireWear", "updateGFX failed (further errors suppressed): " .. tostring(err))
    end
  end
end

local function onTireDeflated(wheelid)
  -- vanilla is inconsistent about passing cid vs wheelID here, so match any of them
  for i = 1, #activeList do
    local st = activeList[i]
    if st.dataCid == wheelid or st.cid == wheelid or st.wheelID == wheelid then
      st.popped = true
      return
    end
  end
end

-- M.onInit is deliberately absent: it never fires for a vehicle auto/ extension
-- (the hook is dispatched before auto/ loads, and the other path is GE-VM only).
M.onExtensionLoaded = initState
M.onVehicleLoaded = initState
M.onReset = initState
M.onPhysicsStep = onPhysicsStep
M.updateGFX = updateGFX
M.onTireDeflated = onTireDeflated

-- Tires are always brand new: nothing is carried across a VM reload. onSerialize still
-- has to exist and return a table, because with neither onSerialize nor M.state defined
-- the engine serializes the ENTIRE M table and tableMerges it back (common/extensions.lua
-- getSerializationData / deserialize). onDeserialize exists for the same reason -- to stop
-- the tableMerge fallback -- and deliberately does nothing.
M.onSerialize = function() return {} end
M.onDeserialize = function() end

-- console helpers:
--   dump(alexTireWear.getDebugState())
--   alexTireWear.settings.debug = true
--   alexTireWear.settings.slipEnergyScale = 0.1
M.getDebugState = function() return activeList end
M.settings = settings

return M
