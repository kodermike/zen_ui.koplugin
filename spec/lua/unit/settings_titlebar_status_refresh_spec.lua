describe("settings title bar", function()
    local SettingsTitleBar
    local saved_modules
    local scheduled
    local unscheduled

    local dependency_names = {
        "ffi/blitbuffer",
        "ui/widget/button",
        "ui/widget/container/centercontainer",
        "device",
        "ui/widget/container/framecontainer",
        "ui/geometry",
        "ui/gesturerange",
        "ui/widget/horizontalgroup",
        "ui/widget/horizontalspan",
        "ui/widget/iconbutton",
        "ui/widget/container/inputcontainer",
        "ui/widget/inputtext",
        "ui/widget/container/leftcontainer",
        "ui/widget/linewidget",
        "ui/widget/overlapgroup",
        "ui/size",
        "ui/widget/textwidget",
        "ui/uimanager",
        "ui/widget/verticalgroup",
        "ui/widget/verticalspan",
        "common/clock_timer",
        "common/shared_state",
        "common/ui/icon_menu_item",
        "common/ui/zen_icon_button",
        "common/ui/zen_solid_circle",
        "common/ui/zen_settings_titlebar",
        "common/ui/zen_title_style",
        "common/widget_resources",
        "common/utils",
        "common/plugin_root",
        "gettext",
        "apps/filemanager/filemanager",
    }

    before_each(function()
        saved_modules = {}
        scheduled = {}
        unscheduled = {}
        for _i, name in ipairs(dependency_names) do
            saved_modules[name] = package.loaded[name] or false
        end

        for _i, name in ipairs(dependency_names) do
            ZenSpec.replace(name, {})
        end
        ZenSpec.replace("ui/widget/container/inputcontainer", {
            extend = function(_self, prototype)
                prototype.__index = prototype
                return prototype
            end,
        })
        ZenSpec.replace("device", { screen = {} })
        ZenSpec.replace("ui/uimanager", {
            scheduleIn = function(_self, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
            unschedule = function(_self, callback)
                unscheduled[#unscheduled + 1] = callback
            end,
        })
        ZenSpec.replace("common/clock_timer", { unbind = function() end })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.unload("ui/geometry")
        ZenSpec.unload("ui/gesturerange")
        ZenSpec.unload("apps/filemanager/filemanager")
        ZenSpec.unload("common/ui/zen_settings_titlebar")
        SettingsTitleBar = require("common/ui/zen_settings_titlebar")
    end)

    after_each(function()
        for _i, name in ipairs(dependency_names) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    local function make_title_bar()
        local refreshes = 0
        local owner = {}
        local title_bar = { show_parent = owner }
        owner._zen_status_title_bar = title_bar
        owner._zen_status_refresh = function()
            refreshes = refreshes + 1
        end
        package.loaded["ui/uimanager"]._window_stack = { { widget = owner } }
        return title_bar, function() return refreshes end, owner
    end

    local function init_title_bar(options)
        local function new_widget(_self, spec)
            spec.getSize = function(self)
                return self.dimen or { w = self.width or 40, h = self.height or 40 }
            end
            return spec
        end
        for _i, name in ipairs(dependency_names) do
            if name:find("^ui/widget/") or name == "common/ui/zen_icon_button" then
                package.loaded[name].new = new_widget
            end
        end
        local screen = package.loaded["device"].screen
        screen.getWidth = function() return 600 end
        screen.scaleBySize = function(_self, size) return size end
        local style = package.loaded["common/ui/zen_title_style"]
        style.ICON_SIZE, style.BUTTON_PADDING, style.BUTTON_SIZE = 28, 8, 44
        style.LEADING_WIDTH, style.TITLE_LEADING_PADDING = 44, 8
        style.LEFT_PADDING, style.RIGHT_PADDING, style.TRAILING_GAP = 12, 12, 4
        style.ROW_HEIGHT, style.VERTICAL_PADDING, style.DIVIDER_HEIGHT = 44, 6, 2
        style.getTitleFace = function() return {} end
        package.loaded["common/utils"].resolveLocalIcon = function() return "/zen/icon.svg" end
        package.loaded["common/plugin_root"] = "/zen"
        options.ges_events = {}
        local title_bar = setmetatable(options, SettingsTitleBar)
        title_bar:init()
        return title_bar
    end

    it("omits hidden close controls and their space, and shows them by default", function()
        local closed = false
        local title_bar = init_title_bar({
            title = "Wi-Fi networks", title_full_width = true,
            back_visible = true, search_visible = false, close_visible = false,
            action = { file = "/zen/refresh.svg" },
            close_callback = function() closed = true end,
        })

        local title_width = title_bar._title_max_width
        assert.is_nil(title_bar.close_button)
        assert.are.same({ title_bar.back_button, title_bar.action_button },
            title_bar:generateHorizontalLayout()[1])

        title_bar.close_visible = nil
        title_bar:init()
        assert.is_truthy(title_bar.close_button)
        assert.are.equal(title_width - 48, title_bar._title_max_width)
        assert.are.same({ title_bar.back_button, title_bar.action_button, title_bar.close_button },
            title_bar:generateHorizontalLayout()[1])
        title_bar.close_button.callback()
        assert.is_true(closed)
    end)

    it("uses one back hitbox across the chevron, gap, and title", function()
        local taps, holds = 0, 0
        local title_bar = init_title_bar({
            title = "Library", back_visible = true, search_visible = false,
            back_callback = function() taps = taps + 1 end,
            back_hold_callback = function() holds = holds + 1 end,
        })
        local Geom = require("ui/geometry")
        title_bar.back_button.dimen = Geom:new{ x = 20, y = 20, w = 44, h = 44 }
        title_bar.title_container.dimen = Geom:new{ x = 72, y = 20, w = 150, h = 44 }
        title_bar.title_widget.getSize = function() return { w = 100, h = 24 } end
        local tap_range = title_bar.ges_events.TapBackTitle[1]
        for _i, x in ipairs({ 24, 68, 110 }) do
            assert.is_true(tap_range:match({ ges = "tap", pos = Geom:new{ x = x, y = 40 } }))
            assert.is_true(title_bar:onTapBackTitle())
        end
        assert.are.equal(3, taps)
        assert.is_false(tap_range:match({ ges = "tap", pos = Geom:new{ x = 173, y = 40 } }))
        assert.is_false(tap_range:match({ ges = "tap", pos = Geom:new{ x = 68, y = 19 } }))
        assert.is_true(title_bar.ges_events.HoldBackTitle[1]:match({
            ges = "hold", pos = Geom:new{ x = 68, y = 40 },
        }))
        assert.is_true(title_bar:onHoldBackTitle())
        assert.are.equal(1, holds)

        title_bar.back_visible = false
        assert.is_false(tap_range:match({ ges = "tap", pos = Geom:new{ x = 68, y = 40 } }))
        assert.is_false(title_bar:onTapBackTitle())
        assert.is_false(title_bar:onHoldBackTitle())
        assert.are.equal(3, taps)
        assert.are.equal(1, holds)
    end)

    it("refreshes immediately when the network connects or disconnects", function()
        local title_bar, refreshes = make_title_bar()

        SettingsTitleBar.onNetworkConnected(title_bar)
        SettingsTitleBar.onNetworkDisconnected(title_bar)

        assert.are.equal(2, refreshes())
    end)

    it("debounces charging changes and cancels the timer when cleared", function()
        local title_bar, refreshes, owner = make_title_bar()

        SettingsTitleBar.onCharging(title_bar)
        local first_callback = scheduled[1].callback
        SettingsTitleBar.onNotCharging(title_bar)

        assert.are.equal(2, #scheduled)
        assert.are.equal(1.5, scheduled[2].delay)
        assert.are.equal(first_callback, unscheduled[1])

        scheduled[2].callback()
        assert.are.equal(1, refreshes())

        SettingsTitleBar.onCharging(title_bar)
        local pending_callback = scheduled[3].callback
        SettingsTitleBar.clearStatusRefresh(title_bar)

        assert.are.equal(pending_callback, unscheduled[2])
        assert.is_nil(title_bar._zen_status_charging_refresh_timer)
        assert.is_nil(owner._zen_status_refresh)
    end)

    it("leaves device events to the active file manager dispatcher", function()
        local title_bar, refreshes = make_title_bar()
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = { _updateStatusBar = function() end },
        })

        SettingsTitleBar.onNetworkConnected(title_bar)
        SettingsTitleBar.onCharging(title_bar)

        assert.are.equal(0, refreshes())
        assert.are.equal(0, #scheduled)
    end)
end)
