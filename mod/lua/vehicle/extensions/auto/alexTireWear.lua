-- Realistic Tire Wear v1 -- per-wheel wear + thermal model.
-- Vehicle extension, auto-loaded from lua/vehicle/extensions/auto/ on every spawn.
-- Global name is the file basename ("alexTireWear"), so it is namespaced already.

local M = {}

-- ---------------------------------------------------------------------------
-- Tuning. Every play-testable constant lives here and nowhere else.
-- ---------------------------------------------------------------------------
local settings = {
  -- CALIBRATION KNOB #1. wd.slipEnergy's units / whether it is already
  -- dt-integrated are unverified (research.md sec.8 item 1), so it is treated as an
  -- arbitrary-scale rate and the whole scale is absorbed here. If wear/heat come
  -- out uniformly too fast or too slow on the test machine, move this first --
  -- it scales heating and wear together, which is what you usually want.
  slipEnergyScale = 1.0,

  -- Wear. wear/s = wearRate * slipPower * tempWearMult(treadTemp)
  -- CALIBRATION KNOB #2 (wear only, independent of heating).
  wearRate = 1.0e-7,

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
  maxTemp = 600.0,
  fallbackEnvTemp = 20.0,       -- if obj:getEnvTemperature() is unavailable

  -- Grip from wear: gentle decline, then a knee once the tread is nearly gone.
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

  -- Blowout path B: sustained overheat, integrated (never an instant threshold).
  heatDamageTemp = 140.0,          -- damage accumulates above this tread temp
  heatDamageDegreeSeconds = 1200.0,-- degC*s above the threshold needed to burst
  heatDamageRecovery = 0.02,       -- per second, once back below the threshold

  -- Driver warnings (one-shot per stage, per tire, reset on vehicle reset).
  wearWarnStages = {0.5, 0.75, 0.9},
  heatWarnStages = {0.5, 0.85},

  streamName = "alexTireWear",
  uiUpdateInterval = 0.1,  -- seconds between UI stream pushes
}

-- ---------------------------------------------------------------------------

local min, max, abs, floor = math.min, math.max, math.abs, math.floor

local wheelStates = {}    -- wheel name -> state (name is stable across cid churn)
local activeList = {}     -- cid-sorted array of the states we integrate
local pendingRestore = nil
local envTemp = settings.fallbackEnvTemp
local coolMult = 1.0
local uiTimer = 0
local actuatorOk = true
local actuatorChecked = false
local streamCache = {wheels = {}}

local function getEnvTemp()
  if obj and obj.getEnvTemperature then
    local t = obj:getEnvTemperature()
    if type(t) == "number" and t == t then return t - 273.15 end
  end
  return settings.fallbackEnvTemp
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

local function newState(name, cid, wheelID)
  return {
    name = name, cid = cid, wheelID = wheelID,
    wear = 0, treadTemp = envTemp, coreTemp = envTemp, heatDamage = 0,
    popped = false,
    grip = 1.0, lastGrip = -1,       -- -1 forces one actuator write after init
    slipPower = 0, rollPower = 0, brakeTemp = envTemp,
    wearWarn = 0, heatWarn = 0,
  }
end

local function resetState(st)
  st.wear, st.heatDamage = 0, 0
  st.treadTemp, st.coreTemp = envTemp, envTemp
  st.popped = false
  st.grip, st.lastGrip = 1.0, -1
  st.slipPower, st.rollPower, st.brakeTemp = 0, 0, envTemp
  st.wearWarn, st.heatWarn = 0, 0
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
  local wd = wheels and wheels.wheels and wheels.wheels[st.cid]
  if wd and not wd.isTireDeflated and not wd.isBroken and beamstate and beamstate.deflateTire then
    beamstate.deflateTire(st.cid)
  end
  warn(st, string.format("%s tire blowout (%s)", tostring(st.name), reason), "blowout")
end

local function applyRestore()
  if not pendingRestore then return end
  for i = 1, #activeList do
    local st = activeList[i]
    local d = pendingRestore[st.name]
    if type(d) == "table" then
      if type(d.wear) == "number" then st.wear = max(0, min(1, d.wear)) end
      if type(d.treadTemp) == "number" then st.treadTemp = d.treadTemp end
      if type(d.coreTemp) == "number" then st.coreTemp = d.coreTemp end
      if type(d.heatDamage) == "number" then st.heatDamage = max(0, min(1, d.heatDamage)) end
      if type(d.wearWarn) == "number" then st.wearWarn = d.wearWarn end
      if type(d.heatWarn) == "number" then st.heatWarn = d.heatWarn end
      st.popped = d.popped == true
      st.lastGrip = -1
    end
  end
  pendingRestore = nil
end

-- Idempotent: rebuilds the wheel list, keeps existing wear unless fresh == true.
local function initState(fresh)
  envTemp = getEnvTemp()
  coolMult = 1.0
  uiTimer = 0
  actuatorOk = true
  actuatorChecked = false
  activeList = {}

  local wheelsTable = wheels and wheels.wheels
  if type(wheelsTable) ~= "table" then return end

  local kept = {}
  for cid, wd in pairs(wheelsTable) do
    -- wheels without a tire (and broken hubs) get no wear model at all
    if type(wd) == "table" and wd.hasTire ~= false then
      local name = wd.name
      if type(name) ~= "string" then name = "wheel" .. tostring(cid) end
      if kept[name] then name = name .. "#" .. tostring(cid) end
      local st = wheelStates[name]
      if not st then
        st = newState(name, cid, wd.wheelID or cid)
      else
        st.cid = cid
        st.wheelID = wd.wheelID or cid
        if fresh then resetState(st) end
      end
      kept[name] = st
      activeList[#activeList + 1] = st
    end
  end
  wheelStates = kept

  -- deterministic iteration order (pairs() over the wheel table is not)
  table.sort(activeList, function(a, b) return (a.cid or 0) < (b.cid or 0) end)

  if not fresh then applyRestore() else pendingRestore = nil end

  -- Without this, M.onPhysicsStep silently never fires (vehicle/main.lua gates it).
  if type(enablePhysicsStepHook) == "function" then enablePhysicsStepHook() end
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
        local w = st.wear + s.wearRate * slipPower * tempWearMult(tt) * dtPhys
        st.wear = w < 1 and w or 1
      end

      if tt > s.heatDamageTemp then
        local hd = st.heatDamage + (tt - s.heatDamageTemp) * dtPhys / s.heatDamageDegreeSeconds
        st.heatDamage = hd < 1 and hd or 1
      elseif st.heatDamage > 0 then
        local hd = st.heatDamage - s.heatDamageRecovery * dtPhys
        st.heatDamage = hd > 0 and hd or 0
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Graphics rate. Samples fresh wheel data, drives the actuator, pops tires,
-- warns the driver, feeds the UI stream.
-- ---------------------------------------------------------------------------
local function applyGrip(st, g)
  if not actuatorOk then return end
  local wobj = obj and obj.getWheel and obj:getWheel(st.wheelID)
  if not wobj then return end
  -- flatten the (jbeam-default-neutral) temperature curve and repurpose the three
  -- friction coefficients as one whole-wheel grip multiplier
  if actuatorChecked then
    wobj:setFrictionThermalSensitivity(-300, 1e7, 1e-10, 1e-10, 10, g, g, g)
    st.lastGrip = g
    return
  end
  -- first call only: verify the API exists on this game version before trusting it
  local ok = pcall(function()
    wobj:setFrictionThermalSensitivity(-300, 1e7, 1e-10, 1e-10, 10, g, g, g)
  end)
  if ok then
    actuatorChecked = true
    st.lastGrip = g
  else
    actuatorOk = false
    if log then log("E", "alexTireWear", "setFrictionThermalSensitivity unavailable; grip actuation disabled") end
  end
end

local function updateGFX(dt)
  local wheelsTable = wheels and wheels.wheels
  if type(wheelsTable) ~= "table" then return end
  local n = #activeList
  if n == 0 then return end

  local s = settings
  envTemp = getEnvTemp()
  local ev = electrics and electrics.values
  local airspeed = 0
  if ev then airspeed = ev.airflowspeed or ev.airspeed or 0 end
  if type(airspeed) ~= "number" or airspeed ~= airspeed or airspeed < 0 then airspeed = 0 end
  coolMult = 1.0 + s.coolingAirCoef * airspeed

  for i = 1, n do
    local st = activeList[i]
    local wd = wheelsTable[st.cid]
    if wd then
      -- latch physics-loop inputs. wheels.updateGFX refreshed these just before
      -- this hook, so read them rather than re-calling the C++ getter.
      local slipEnergy = wd.slipEnergy
      if type(slipEnergy) ~= "number" or slipEnergy ~= slipEnergy or slipEnergy < 0 then slipEnergy = 0 end
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
      st.slipPower, st.rollPower = 0, 0
    end

    if not st.popped then
      -- blowout paths (both deterministic; deflation happens here, not in the
      -- physics hook, to keep that hook free of engine calls)
      if st.wear >= 1 then
        popTire(st, "worn out")
      elseif st.heatDamage >= 1 then
        popTire(st, "overheated")
      end
    end

    local g = s.gripMin
    if not st.popped then
      g = gripFromWear(st.wear) * gripFromTemp(st.treadTemp)
      if g > 1 then g = 1 elseif g < s.gripMin then g = s.gripMin end
    end
    st.grip = g
    if abs(g - st.lastGrip) > s.gripApplyEpsilon then applyGrip(st, g) end

    if not st.popped then
      -- staged driver warnings
      local stages = s.wearWarnStages
      while st.wearWarn < #stages and st.wear >= stages[st.wearWarn + 1] do
        st.wearWarn = st.wearWarn + 1
        warn(st, string.format("%s tire at %d%% wear", tostring(st.name), floor(st.wear * 100 + 0.5)), "wear")
      end
      local hstages = s.heatWarnStages
      while st.heatWarn < #hstages and st.heatDamage >= hstages[st.heatWarn + 1] do
        st.heatWarn = st.heatWarn + 1
        warn(st, string.format("%s tire overheating: %d C", tostring(st.name), floor(st.treadTemp + 0.5)), "heat")
      end
    end
  end

  -- UI stream, throttled and gated: costs nothing while the app is closed
  uiTimer = uiTimer + (dt or 0)
  if uiTimer < s.uiUpdateInterval then return end
  uiTimer = 0
  if not (streams and streams.willSend and streams.willSend(s.streamName)) then return end
  if not (gui and gui.send) then return end

  local out = streamCache.wheels
  for i = 1, n do
    local st = activeList[i]
    local e = out[i]
    if not e then e = {}; out[i] = e end
    e.name = st.name
    e.wear = st.wear
    e.treadTemp = st.treadTemp
    e.coreTemp = st.coreTemp
    e.heatDamage = st.heatDamage
    e.grip = st.grip
    e.popped = st.popped
  end
  for i = #out, n + 1, -1 do out[i] = nil end
  gui.send(s.streamName, streamCache)
end

local function onTireDeflated(wheelid)
  -- vanilla is inconsistent about passing cid vs wheelID here, so match either
  for i = 1, #activeList do
    local st = activeList[i]
    if st.cid == wheelid or st.wheelID == wheelid then
      st.popped = true
      return
    end
  end
end

-- M.onInit is deliberately absent: it never fires for a vehicle auto/ extension
-- (the hook is dispatched before auto/ loads, and the other path is GE-VM only).
M.onExtensionLoaded = function() initState(false) end
M.onVehicleLoaded = function() initState(false) end
M.onReset = function() initState(true) end
M.onPhysicsStep = onPhysicsStep
M.updateGFX = updateGFX
M.onTireDeflated = onTireDeflated

-- Explicit, or the engine would serialize (and tableMerge back) the whole M table.
M.onSerialize = function()
  local out = {}
  for name, st in pairs(wheelStates) do
    out[name] = {
      wear = st.wear, treadTemp = st.treadTemp, coreTemp = st.coreTemp,
      heatDamage = st.heatDamage, popped = st.popped,
      wearWarn = st.wearWarn, heatWarn = st.heatWarn,
    }
  end
  return {wheels = out}
end

M.onDeserialize = function(data)
  if type(data) ~= "table" or type(data.wheels) ~= "table" then return end
  pendingRestore = data.wheels
  if #activeList > 0 then applyRestore() end
end

-- console helper: dump(alexTireWear.getDebugState())
M.getDebugState = function() return activeList end
M.settings = settings

return M
