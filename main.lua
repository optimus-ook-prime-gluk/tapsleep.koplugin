--[[--
Tap Sleep: a "fake sleep" for devices whose power button is hard to press.

Sleeping shows a random image from the screensaver folder, turns off the
front light (and optionally Wi-Fi) and swallows every touch. Tapping twice
(or three times) quickly anywhere wakes it and puts everything back.

v2 hardening (lessons from a real overnight failure):
  * The device is kept out of real suspend while Tap Sleep is active
    (Kindle: powerd preventScreenSaver, Kobo/Cervantes: pause_auto_suspend),
    regardless of whether "Keep alive" was switched on.
  * If a real suspend happens anyway (power button, magnetic cover, battery
    guard...), the fake-sleep screen is dismissed on the way down, and the
    light/Wi-Fi are restored after resume, so the power button always brings
    you straight back to your book.
  * Taps are counted by the plugin itself, so waking does not depend on
    KOReader's global double-tap detector state.
  * Battery guard: falls back to real sleep when the battery gets low, and
    optionally after a maximum duration.
  * State is persisted, so a crash/restart while asleep restores the light
    and the auto-sleep setting on next start.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local PluginShare = require("pluginshare")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local T = require("ffi/util").template
local _ = require("gettext")
local Screen = Device.screen

local TAP_WINDOW = time.s(0.7)      -- max gap between taps of one wake gesture
local ARM_DELAY = time.s(1.5)       -- ignore touches right after falling asleep
local CLOSE_DELAY = 0.35            -- keep swallowing stray taps briefly after waking
local WATCHDOG_EVERY = 10 * 60      -- seconds between battery / duration checks
local RESTORE_AFTER_RESUME = 1.5    -- seconds; must lose the race with powerd:afterResume
local STATE_KEY = "tapsleep_state"

-- Settings (with defaults)
local function tapsNeeded() return G_reader_settings:readSetting("tapsleep_taps", 2) end
local function wifiOffEnabled() return G_reader_settings:nilOrTrue("tapsleep_wifi_off") end
local function batteryGuard() return G_reader_settings:readSetting("tapsleep_battery_guard", 10) end -- percent, 0 = off
local function maxHours() return G_reader_settings:readSetting("tapsleep_max_hours", 0) end -- 0 = never

-- Shared across FileManager/Reader plugin instances.
local state = {
    screen = nil,          -- the active SleepScreen
    light_was_on = false,
    wifi_was_on = false,
    forced_awake = false,  -- we (not Keep alive) blocked auto-suspend
    started = nil,
    pending_restore = nil, -- { light = bool, wifi = bool } after a real suspend
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function powerd() return Device:getPowerDevice() end

local function setAutoSleepBlocked(blocked)
    if Device:isKindle() then
        local ok = os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver " .. (blocked and "1" or "0"))
        logger.info("TapSleep: preventScreenSaver", blocked, "->", ok)
    elseif Device:isKobo() or Device:isCervantes() then
        PluginShare.pause_auto_suspend = blocked
    end
end

local function blockAutoSleep()
    -- If Keep alive is already on, it owns that setting: leave it alone.
    if PluginShare.keepalive then
        state.forced_awake = false
    else
        setAutoSleepBlocked(true)
        state.forced_awake = true
    end
end

local function releaseAutoSleep()
    if state.forced_awake and not PluginShare.keepalive then
        setAutoSleepBlocked(false)
    end
    state.forced_awake = false
end

local function lightOn()
    if not Device:hasFrontlight() then return false end
    local ok, on = pcall(powerd().isFrontlightOn, powerd())
    return ok and on or false
end

local function setLight(on)
    if not Device:hasFrontlight() then return end
    local p = powerd()
    if on then pcall(p.turnOnFrontlight, p) else pcall(p.turnOffFrontlight, p) end
end

local function wifiIsOn()
    if not Device:hasWifiToggle() then return false end
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok then return false end
    local ok2, on = pcall(NetworkMgr.isWifiOn, NetworkMgr)
    return ok2 and on or false
end

local function setWifi(on)
    if not Device:hasWifiToggle() then return end
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok then return end
    if on then
        if not wifiIsOn() then
            pcall(NetworkMgr.turnOnWifi, NetworkMgr, nil, false) -- non-interactive
        end
    else
        pcall(NetworkMgr.turnOffWifi, NetworkMgr)
    end
end

local function persist()
    G_reader_settings:saveSetting(STATE_KEY, {
        light = state.light_was_on,
        wifi = state.wifi_was_on,
        forced = state.forced_awake,
    })
    pcall(G_reader_settings.flush, G_reader_settings)
end

local function clearPersist()
    if G_reader_settings:has(STATE_KEY) then
        G_reader_settings:delSetting(STATE_KEY)
        pcall(G_reader_settings.flush, G_reader_settings)
    end
end

local IMAGE_EXT = { png = true, jpg = true, jpeg = true, bmp = true, gif = true, webp = true }

local function listImages(dir)
    local files = {}
    if not dir or lfs.attributes(dir, "mode") ~= "directory" then return files end
    for f in lfs.dir(dir) do
        local ext = f:match("%.([^.]+)$")
        if not f:match("^%.") and ext and IMAGE_EXT[ext:lower()] then
            files[#files + 1] = dir .. "/" .. f
        end
    end
    return files
end

-- Build an image widget, forcing it to decode now so a broken file can't
-- blow up later inside the repaint loop.
local function loadImage(file, w, h)
    local ok, img = pcall(ImageWidget.new, ImageWidget, {
        file = file, width = w, height = h,
        scale_factor = 0, -- best fit
        file_do_cache = false,
    })
    if not ok or not img then return nil end
    local ok2 = pcall(img.getSize, img)
    if not ok2 then
        pcall(img.free, img)
        return nil
    end
    return img
end

local function pickImage(w, h)
    local files = listImages(G_reader_settings:readSetting("screensaver_dir"))
    -- Try a few random files in case one is unreadable.
    for _attempt = 1, math.min(#files, 5) do
        local i = math.random(#files)
        local img = loadImage(files[i], w, h)
        if img then return img end
        logger.warn("TapSleep: unreadable image", files[i])
        table.remove(files, i)
    end
    return nil
end

---------------------------------------------------------------------------
-- The full-screen sleep overlay
---------------------------------------------------------------------------

local SleepScreen = InputContainer:extend{
    name = "TapSleepScreen",
    covers_fullscreen = true,
    modal = true,
    -- Deliver every tap immediately as a plain "tap"; we count them ourselves.
    disable_double_tap = true,
    on_wake_request = nil,
    on_touch = nil,
    on_suspend = nil,
}

function SleepScreen:init()
    local w, h = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
    self.shown_at = time.now()
    self.tap_count = 0
    self.last_tap = nil
    self.closing = false

    local content = pickImage(w, h)
    if not content then
        content = TextWidget:new{
            text = T(_("Sleeping — tap %1 times to wake"), tapsNeeded()),
            face = Font:getFace("cfont", 22),
            fgcolor = Blitbuffer.COLOR_WHITE,
        }
    end
    self[1] = FrameContainer:new{
        padding = 0, margin = 0, bordersize = 0,
        background = Blitbuffer.COLOR_BLACK,
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            content,
        },
    }
end

-- Swallow every gesture so nothing underneath reacts; count taps to wake.
function SleepScreen:onGesture(ev)
    if self.closing or not ev then return true end
    local now = time.now()
    if now - self.shown_at < ARM_DELAY then return true end
    if self.on_touch then self.on_touch() end

    local taps = (ev.ges == "tap" and 1) or (ev.ges == "double_tap" and 2) or 0
    if taps > 0 then
        if self.last_tap and now - self.last_tap <= TAP_WINDOW then
            self.tap_count = self.tap_count + taps
        else
            self.tap_count = taps
        end
        self.last_tap = now
        if self.tap_count >= tapsNeeded() and self.on_wake_request then
            self.closing = true
            self.on_wake_request()
        end
    end
    return true
end

-- A real suspend is starting (power button, cover, battery guard, timeout).
function SleepScreen:onSuspend()
    if self.on_suspend then self.on_suspend() end
end

-- Closed by somebody else (e.g. KOReader exiting): don't leave things off.
function SleepScreen:onCloseWidget()
    if state.screen == self then
        logger.info("TapSleep: overlay closed externally, restoring")
        state.screen = nil
        releaseAutoSleep()
        if state.light_was_on then setLight(true) end
        clearPersist()
    end
end

---------------------------------------------------------------------------
-- Plugin
---------------------------------------------------------------------------

local TapSleep = WidgetContainer:extend{
    name = "tapsleep",
    is_doc_only = false,
}

local watchdog -- forward declaration

local function stopWatchdog()
    UIManager:unschedule(watchdog)
end

local function realSleep(reason)
    logger.info("TapSleep: falling back to real sleep:", reason)
    -- The Suspend broadcast will dismiss the overlay via SleepScreen:onSuspend.
    releaseAutoSleep()
    UIManager:suspend()
end

watchdog = function()
    if not state.screen then return end
    local p = powerd()
    local charging = false
    if Device:hasBattery() then
        local okc, c = pcall(p.isCharging, p)
        charging = okc and c or false
        local guard = batteryGuard()
        if guard > 0 and not charging then
            local okb, level = pcall(p.getCapacity, p)
            if okb and type(level) == "number" and level > 0 and level <= guard then
                return realSleep("battery " .. level .. "%")
            end
        end
    end
    local hours = maxHours()
    if hours > 0 and not charging and state.started
        and time.now() - state.started >= time.s(hours * 3600) then
        return realSleep("max duration " .. hours .. "h")
    end
    UIManager:scheduleIn(WATCHDOG_EVERY, watchdog)
end

-- Wake by taps: restore everything and take the overlay down.
local function wakeByTap()
    local scr = state.screen
    if not scr then return end
    logger.info("TapSleep: wake by tap")
    stopWatchdog()
    state.screen = nil
    releaseAutoSleep()
    if state.light_was_on then setLight(true) end
    -- Keep the (already "closing") overlay up for a moment to eat extra taps,
    -- so a third/fourth tap doesn't turn the page.
    UIManager:scheduleIn(CLOSE_DELAY, function()
        UIManager:close(scr, "full")
    end)
    if state.wifi_was_on then
        UIManager:scheduleIn(1, function() setWifi(true) end)
    end
    clearPersist()
end

-- A real suspend started while fake-asleep: drop the overlay now (the real
-- screensaver is on top already) and restore light/Wi-Fi after resume.
local function wakeBySuspend()
    local scr = state.screen
    if not scr then return end
    logger.info("TapSleep: real suspend while asleep; will restore on resume")
    stopWatchdog()
    state.screen = nil
    releaseAutoSleep()
    state.pending_restore = { light = state.light_was_on, wifi = state.wifi_was_on }
    UIManager:close(scr) -- no refresh: it's hidden under the real screensaver
    -- Keep the persisted state until the restore actually happens.
end

local function reassertLightOff()
    -- Something (e.g. AutoDim restoring brightness on input) turned it back on.
    if lightOn() then setLight(false) end
end

function TapSleep:sleep()
    if state.screen then return end
    state.pending_restore = nil

    state.light_was_on = lightOn()
    if state.light_was_on then setLight(false) end

    state.wifi_was_on = false
    if wifiOffEnabled() and wifiIsOn() then
        state.wifi_was_on = true
        setWifi(false)
    end

    blockAutoSleep()
    state.started = time.now()
    persist()

    state.screen = SleepScreen:new{
        on_wake_request = wakeByTap,
        on_touch = reassertLightOff,
        on_suspend = wakeBySuspend,
    }
    logger.info("TapSleep: sleep (light", state.light_was_on, "wifi", state.wifi_was_on,
                "forced", state.forced_awake, ")")
    UIManager:show(state.screen, "full")
    UIManager:scheduleIn(WATCHDOG_EVERY, watchdog)
end

function TapSleep:onDispatcherRegisterActions()
    Dispatcher:registerAction("tapsleep_sleep", {
        category = "none",
        event = "TapSleep",
        title = _("Tap Sleep (screen off)"),
        general = true,
    })
end

function TapSleep:init()
    math.randomseed(os.time())
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self:recoverFromCrash()
end

-- KOReader died or restarted while fake-asleep: undo what we changed.
function TapSleep:recoverFromCrash()
    if state.screen or state.pending_restore then return end
    local saved = G_reader_settings:readSetting(STATE_KEY)
    if type(saved) ~= "table" then return end
    logger.info("TapSleep: recovering state from an interrupted sleep")
    if saved.forced and not PluginShare.keepalive then setAutoSleepBlocked(false) end
    if saved.light then UIManager:scheduleIn(1, function() setLight(true) end) end
    clearPersist()
end

function TapSleep:onTapSleep()
    self:sleep()
    return true
end

-- Broadcast after a real resume (power button / cover).
function TapSleep:onResume()
    local pr = state.pending_restore
    if not pr then return end
    state.pending_restore = nil
    -- Lose the race against KindlePowerD:afterResume's own frontlight fixup.
    UIManager:scheduleIn(RESTORE_AFTER_RESUME, function()
        if pr.light then setLight(true) end
        if pr.wifi then setWifi(true) end
        clearPersist()
        logger.info("TapSleep: restored after resume")
    end)
end

function TapSleep:addToMainMenu(menu_items)
    local function radio(text, key, value, default)
        return {
            text = text,
            radio = true,
            checked_func = function() return G_reader_settings:readSetting(key, default) == value end,
            callback = function() G_reader_settings:saveSetting(key, value) end,
        }
    end
    menu_items.tapsleep = {
        text = _("Tap Sleep"),
        sorting_hint = "device",
        sub_item_table = {
            {
                text = _("Sleep now"),
                callback = function()
                    -- Let the menu close and repaint before blanking the screen.
                    UIManager:scheduleIn(0.5, function() self:sleep() end)
                end,
                separator = true,
            },
            {
                text_func = function() return T(_("Taps to wake: %1"), tapsNeeded()) end,
                sub_item_table = {
                    radio(_("2 taps (double-tap)"), "tapsleep_taps", 2, 2),
                    radio(_("3 taps (safer in a bag)"), "tapsleep_taps", 3, 2),
                },
            },
            {
                text = _("Turn off Wi-Fi while asleep"),
                checked_func = wifiOffEnabled,
                callback = function() G_reader_settings:flipNilOrTrue("tapsleep_wifi_off") end,
            },
            {
                text_func = function()
                    local g = batteryGuard()
                    return g > 0 and T(_("Real sleep when battery ≤ %1%"), g) or _("Real sleep on low battery: off")
                end,
                sub_item_table = {
                    radio(_("Off"), "tapsleep_battery_guard", 0, 10),
                    radio(_("5%"), "tapsleep_battery_guard", 5, 10),
                    radio(_("10%"), "tapsleep_battery_guard", 10, 10),
                    radio(_("20%"), "tapsleep_battery_guard", 20, 10),
                },
            },
            {
                text_func = function()
                    local hrs = maxHours()
                    return hrs > 0 and T(_("Real sleep after %1 h"), hrs) or _("Real sleep after: never")
                end,
                sub_item_table = {
                    radio(_("Never"), "tapsleep_max_hours", 0, 0),
                    radio(_("1 hour"), "tapsleep_max_hours", 1, 0),
                    radio(_("2 hours"), "tapsleep_max_hours", 2, 0),
                    radio(_("4 hours"), "tapsleep_max_hours", 4, 0),
                    radio(_("8 hours"), "tapsleep_max_hours", 8, 0),
                },
                separator = true,
            },
            {
                text = _("Help"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_([[Sleep: long-press the bottom-right corner (or use "Sleep now").
Wake: tap the screen %1 times quickly.

While asleep the Kindle is kept out of real sleep automatically, so taps keep working even if Keep alive is off.

Power button while asleep: the Kindle really sleeps; pressing it again brings you straight back to your book.

"Real sleep" options save battery, but waking from real sleep needs the power button.

Change the gesture: gear → Taps and gestures → Gesture manager → pick a gesture → General → "Tap Sleep (screen off)".]]), tapsNeeded()),
                    })
                end,
            },
        },
    }
end

return TapSleep
