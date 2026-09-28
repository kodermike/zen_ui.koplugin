local Device = require("device")
local LuaSettings = require("luasettings")
local PresetStore = require("config/preset_store")
local UIManager = require("ui/uimanager")

local M = {}
local SAMPLE_SECONDS = 30 * 60
local MAX_EVENTS = 512
local settings
local sleeping = false
local timer
local charge_timer
local pending_gap = false

local function capture()
    local powerd = Device:getPowerDevice()
    if not powerd then return nil end
    local ok, raw_level, charging = pcall(function()
        return powerd:getCapacityHW(), powerd:isCharging() or powerd:isCharged()
    end)
    if not ok then return nil end
    local level = tonumber(raw_level)
    if not level or level <= 0 or level > 100 then return nil end
    return {
        time = os.time(), level = level,
        charging = charging,
        sleeping = sleeping,
    }
end

local function read_attr(dir, name)
    local file = io.open(dir .. "/" .. name, "r")
    if not file then return nil end
    local value = file:read("*l")
    file:close()
    return value
end

local function battery_dir()
    local powerd = Device:getPowerDevice()
    for _i, key in ipairs({ "batt_capacity_file", "capacity_file" }) do
        local path = powerd and powerd[key]
        local dir = type(path) == "string" and path:match("^(.*)/[^/]+$")
        if dir and (read_attr(dir, "type") == "Battery"
            or read_attr(dir, "charge_full") or read_attr(dir, "charge_now")) then return dir end
    end

    local ok, iter, state = pcall(require("libs/libkoreader-lfs").dir, "/sys/class/power_supply")
    if not ok or type(iter) ~= "function" then return nil end
    local found
    for name in iter, state do
        local dir = "/sys/class/power_supply/" .. name
        if read_attr(dir, "type") == "Battery" then
            if found then return nil end
            found = dir
        end
    end
    return found
end

local function device_capacity()
    local dir = battery_dir()
    if not dir then return nil, nil end
    local function value(name)
        local number = tonumber(read_attr(dir, name))
        return number and number >= 0 and number or nil
    end
    local full, design = value("charge_full"), value("charge_full_design")
    local empty, design_empty = value("charge_empty"), value("charge_empty_design")
    local use_empty = full and design and empty and design_empty
        and full > empty and design > design_empty
    local current_charge = value("charge_now")
    if use_empty then
        full, design = full - empty, design - design_empty
        if current_charge then current_charge = math.max(0, current_charge - empty) end
    end
    local full_mah = full and full >= 50000 and full <= 100000000 and full / 1000 or nil
    local design_mah = design and design >= 50000 and design <= 100000000 and design / 1000 or nil
    local current_mah = current_charge and current_charge <= 100000000 and current_charge / 1000 or nil
    local health = full_mah and design_mah and full_mah / design_mah * 100 or nil
    if health and (health <= 0 or health > 200) then health = nil end
    return full_mah, design_mah, health, current_mah
end

local function trim(events)
    while #events > MAX_EVENTS do
        table.remove(events, 1)
    end
end

local function sample(gap, charging_event)
    if not settings then return end
    local event = capture()
    if not event then pending_gap = true; return end
    local events = settings:readSetting("events")
    local previous = events[#events]
    if previous and not gap and not pending_gap and previous.time == event.time
        and previous.level == event.level and previous.charging == event.charging
        and previous.sleeping == event.sleeping then return end
    event.gap = gap or pending_gap
        or (previous and previous.charging ~= event.charging and not charging_event) or nil
    pending_gap = false
    if previous and not previous.charging and event.level > previous.level then
        settings:saveSetting("last_unplug", nil)
    elseif previous and previous.charging and not event.charging then
        if event.gap then
            settings:saveSetting("last_unplug", nil)
        else
            settings:saveSetting("last_unplug", event.time)
        end
    end
    events[#events + 1] = event
    trim(events)
    settings:flush()
end

local function schedule()
    UIManager:unschedule(timer)
    if sleeping then return end
    UIManager:scheduleIn(SAMPLE_SECONDS, timer)
end

timer = function()
    sample()
    schedule()
end

charge_timer = function()
    sample(nil, true)
end

function M.start()
    if settings or not Device:hasBattery() then return end
    settings = LuaSettings:open(PresetStore.rootDir() .. "/battery.lua")
    local events = settings:readSetting("events")
    if type(events) ~= "table" then events = {} end
    for i = #events, 1, -1 do
        local event = events[i]
        if type(event) ~= "table" or type(event.time) ~= "number"
            or type(event.level) ~= "number" or type(event.charging) ~= "boolean"
            or type(event.sleeping) ~= "boolean" then
            table.remove(events, i)
        end
    end
    settings:saveSetting("events", events)
    sample(true) -- KOReader may have been closed or the device charged while it was off.
    schedule()
end

function M.suspend()
    if not settings or sleeping then return end
    UIManager:unschedule(charge_timer)
    sleeping = true
    sample()
    UIManager:unschedule(timer)
end

function M.resume()
    if not settings then return end
    if sleeping then
        sleeping = false
        sample()
    end
    schedule()
end

function M.chargingChanged()
    if not settings or sleeping then return end
    UIManager:unschedule(charge_timer)
    UIManager:scheduleIn(1.5, charge_timer)
end

function M.stop()
    if not settings then return end
    UIManager:unschedule(timer)
    UIManager:unschedule(charge_timer)
    sample()
    settings = nil
    sleeping = false
    pending_gap = false
end

function M.reset()
    if not settings then return false end
    settings:reset({ events = {} })
    settings:flush()
    if settings.file then os.remove(settings.file .. ".old") end
    pending_gap = false
    return true
end

function M.snapshot()
    if not settings then return nil end
    local events = settings:readSetting("events")
    local current = capture()
    local awake, asleep, total = { loss = 0, time = 0, elapsed = 0 },
        { loss = 0, time = 0, elapsed = 0 }, { loss = 0, time = 0 }
    local function accumulate(first, second)
        if type(first) ~= "table" or type(second) ~= "table" or second.gap then return end
        local elapsed = second.time - first.time
        if elapsed <= 0 or first.charging then return end
        local bucket = first.sleeping and asleep or awake
        bucket.elapsed = bucket.elapsed + elapsed
        if first.level < second.level then return end
        local loss = first.level - second.level
        bucket.loss = bucket.loss + loss
        bucket.time = bucket.time + elapsed
        total.loss = total.loss + loss
        total.time = total.time + elapsed
    end
    for i = 2, #events do accumulate(events[i - 1], events[i]) end
    if current and #events > 0 and events[#events].charging == current.charging then
        accumulate(events[#events], current)
    end
    local function rate(bucket)
        return bucket.time > 0 and bucket.loss * 3600 / bucket.time or nil
    end
    local overall = rate(total)
    local full_mah, design_mah, health, current_mah = device_capacity()
    local unplug = settings:readSetting("last_unplug")
    if current and #events > 0 then
        local previous = events[#events]
        if not previous.charging and current.level > previous.level then
            unplug = nil
        elseif previous.charging and not current.charging then
            unplug = current.time
        end
    end
    return {
        level = current and current.level,
        full_mah = full_mah,
        current_mah = current_mah,
        design_mah = design_mah,
        health = health,
        charging = current and current.charging,
        overall = overall,
        awake = rate(awake),
        asleep = rate(asleep),
        awake_time = awake.elapsed,
        asleep_time = asleep.elapsed,
        remaining = overall and overall > 0 and current and current.level * 3600 / overall or nil,
        since_charge = type(unplug) == "number" and current and current.time >= unplug
            and current.time - unplug or nil,
        samples = #events,
    }
end

return M
