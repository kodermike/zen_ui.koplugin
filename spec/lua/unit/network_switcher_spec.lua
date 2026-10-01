describe("network switcher", function()
    local original_modules
    local shown
    local closed
    local events
    local NetworkMgr
    local network_menu
    local password_dialog
    local confirm_box
    local button_dialog
    local connected_network
    local connected_ip
    local verification_sleeps
    local authentication_attempts
    local fail_first_auth
    local ip_calls
    local logs
    local scan_task
    local scheduled
    local follow_up_checks
    local scan_handle_closes
    local kindle_disconnects
    local kindle_connects
    local kindle_deletes
    local kindle_scans
    local kindle_scan_state
    local kindle_scan_stays_idle
    local power_cycle_sleeps
    local created_profile
    local native_profiles
    local profile_read_fails
    local deleted_profile_id

    local module_names = {
        "device",
        "libopenlipclua",
        "ui/event",
        "ui/widget/buttondialog",
        "ui/widget/confirmbox",
        "ui/widget/infomessage",
        "ui/widget/inputdialog",
        "ui/widget/menu",
        "ui/widget/networksetting",
        "ui/size",
        "ui/network/manager",
        "ui/uimanager",
        "ffi/util",
        "ffi/crypto",
        "ffi/sha2",
        "ffi/inkview",
        "liblipclua",
        "lj-wpaclient/wpaclient",
        "ui/network/wpa_supplicant",
        "util",
        "common/inline_icon_map",
        "common/plugin_root",
        "common/ui/icon_menu_item",
        "common/ui/zen_settings_titlebar",
        "common/utils",
        "common/zen_logger",
        "modules/menu/network_adapters/kindle",
        "modules/menu/network_adapters/kobo",
        "modules/settings/zen_settings_utils",
        "gettext",
    }

    before_each(function()
        original_modules = {}
        for _i, name in ipairs(module_names) do
            original_modules[name] = package.loaded[name]
        end
        shown = {}
        closed = {}
        events = {}
        verification_sleeps = 0
        authentication_attempts = 0
        fail_first_auth = false
        ip_calls = 0
        logs = {}
        password_dialog = nil
        button_dialog = nil
        scan_task = nil
        scheduled = {}
        follow_up_checks = {}
        scan_handle_closes = 0
        kindle_disconnects = 0
        kindle_connects = 0
        kindle_deletes = 0
        kindle_scans = 0
        kindle_scan_state = 0
        kindle_scan_stays_idle = false
        power_cycle_sleeps = 0
        created_profile = nil
        native_profiles = {
            Home = { essid = "Home", netid = 11, psk = "saved" },
        }
        profile_read_fails = false
        deleted_profile_id = nil

        ZenSpec.replace("device", {
            hasWifiManager = function() return false end,
            isKindle = function() return true end,
        })
        ZenSpec.replace("ui/event", {
            new = function(_self, name) return { name = name } end,
        })
        ZenSpec.replace("ui/widget/buttondialog", {
            new = function(_self, options)
                options.kind = "actions"
                options.getContentSize = function() return { w = 400, h = 300 } end
                button_dialog = options
                return options
            end,
        })
        ZenSpec.replace("ui/widget/confirmbox", {
            new = function(_self, options)
                options.kind = "confirm"
                confirm_box = options
                return options
            end,
        })
        ZenSpec.replace("ui/widget/infomessage", {
            new = function(_self, options)
                options.kind = "message"
                return options
            end,
        })
        ZenSpec.replace("ui/widget/inputdialog", {
            new = function(_self, options)
                options.kind = "password"
                options.getInputText = function() return "guest-password" end
                options.onShowKeyboard = function() options.keyboard_shown = true end
                password_dialog = options
                return options
            end,
        })
        ZenSpec.replace("ui/widget/menu", {
            new = function(_self, options)
                options.kind = "menu"
                options.switchItemTable = function(self, _title, items, selected_index)
                    self.item_table = items
                    self.selected_index = selected_index
                end
                options.onMenuChoice = function(_menu, item)
                    if item.callback then return item.callback() end
                end
                options.onClose = function(self)
                    if self.close_callback then self.close_callback() end
                    return true
                end
                network_menu = options
                return options
            end,
        })
        ZenSpec.replace("common/ui/zen_settings_titlebar", {
            new = function(_self, options)
                options.root_icon = {}
                options.clearStatusRefresh = function(self)
                    self.status_refresh_clears = (self.status_refresh_clears or 0) + 1
                end
                options.clear = function(self) self.was_cleared = true end
                options.init = function(self) self.was_initialized = true end
                return options
            end,
        })
        ZenSpec.replace("ui/size", {
            padding = { large = 12, default = 8 },
        })

        NetworkMgr = {
            wifi_on = true,
            isWifiOn = function(self) return self.wifi_on end,
            isConnected = function(self) return self.current_ssid ~= nil end,
            turnOffWifi = function(self)
                self.wifi_on = false
                self.current_ssid = nil
            end,
            turnOnWifi = function(self) self.wifi_on = true return true end,
            getNetworkList = function(self)
                if self.current_ssid then
                    return {{
                        ssid = self.current_ssid,
                        flags = "[WPA2]",
                        password = "saved",
                        signal_quality = 80,
                        connected = true,
                    }}
                end
                return {
                    {
                        ssid = "Home",
                        flags = "[WPA2]",
                        password = "saved",
                        signal_quality = 80,
                        connected = false,
                        wpa_supplicant_id = 1,
                    },
                    {
                        ssid = "Guest",
                        flags = "[WPA2]",
                        password = self.guest_password,
                        signal_quality = 60,
                    },
                }
            end,
            current_ssid = "Home",
            disconnectNetwork = function(self, network)
                self.disconnected = network
            end,
            releaseIP = function(self) self.released = true end,
            saveNetwork = function(self, network) self.saved = network end,
            deleteNetwork = function(self, network) self.deleted = network end,
            authenticateNetwork = function(self, network)
                authentication_attempts = authentication_attempts + 1
                self.authenticated = network
                self.current_ssid = fail_first_auth and authentication_attempts == 1
                    and "Home" or network.ssid
                return true
            end,
            obtainIP = function(self) self.obtained = true end,
            getCurrentNetwork = function(self) return { ssid = self.current_ssid } end,
            getAllSavedNetworks = function()
                return { readSetting = function() return nil end }
            end,
            hasDefaultRoute = function() return false end,
            queryNetworkState = function(self) self.queried = true end,
        }
        ZenSpec.replace("ui/network/manager", NetworkMgr)
        ZenSpec.replace("lj-wpaclient/wpaclient", {
            __index = { enableNetworkByID = function() end },
        })
        ZenSpec.replace("liblipclua", {
            init = function(name)
                assert.are.equal("com.github.koreader.networkmgr", name)
                return {
                    set_string_property = function(_self, service, property, value)
                        assert.are.equal("com.lab126.wifid", service)
                        if property == "cmDisconnect" then
                            assert.are.equal("", value)
                            kindle_disconnects = kindle_disconnects + 1
                            NetworkMgr.current_ssid = nil
                        elseif property == "scan" then
                            assert.are.equal("", value)
                            kindle_scans = kindle_scans + 1
                            kindle_scan_state = 1
                        else
                            assert.are.equal("cmConnect", property)
                            local profile
                            for _name, saved in pairs(native_profiles) do
                                if tostring(saved.netid) == value then profile = saved break end
                            end
                            assert.is_not_nil(profile)
                            kindle_connects = kindle_connects + 1
                            authentication_attempts = authentication_attempts + 1
                            NetworkMgr.authenticated = { ssid = profile.essid }
                            NetworkMgr.current_ssid = fail_first_auth
                                    and authentication_attempts == 1 and "Home" or profile.essid
                        end
                    end,
                    get_string_property = function(_self, service, property)
                        assert.are.equal("com.lab126.wifid", service)
                        if property == "scanState" then
                            if kindle_scan_stays_idle then return "idle" end
                            local states = { "idle", "scanning", "idle" }
                            local state = states[kindle_scan_state]
                            kindle_scan_state = kindle_scan_state + 1
                            return state
                        end
                        assert.are.equal("cmState", property)
                        return "READY"
                    end,
                    close = function() scan_handle_closes = scan_handle_closes + 1 end,
                }
            end,
        })
        ZenSpec.replace("libopenlipclua", {
            open_no_name = function()
                local profile_data = {}
                return {
                    new_hasharray = function()
                        return {
                            add_hash = function() end,
                            put_string = function(_self, index, key, value)
                                assert.are.equal(0, index)
                                profile_data[key] = value
                            end,
                            put_int = function(_self, index, key, value)
                                assert.are.equal(0, index)
                                profile_data[key] = value
                            end,
                            destroy = function() end,
                        }
                    end,
                    access_hash_property = function(_self, service, property)
                        assert.are.equal("com.lab126.wifid", service)
                        if property == "scanList" then
                            return {
                                to_table = function()
                                    return {
                                        {
                                            essid = "Home",
                                            key_mgmt = "WPA2-PSK",
                                            signal = 4,
                                            signal_max = 5,
                                        },
                                        {
                                            essid = "Guest",
                                            key_mgmt = "WPA2-PSK",
                                            signal = 3,
                                            signal_max = 5,
                                        },
                                    }
                                end,
                                destroy = function() end,
                            }
                        elseif property == "profileData" then
                            if profile_read_fails then error("profileData unavailable") end
                            return {
                                to_table = function()
                                    local profiles = {}
                                    for _name, profile in pairs(native_profiles) do
                                        profiles[#profiles + 1] = profile
                                    end
                                    return profiles
                                end,
                                destroy = function() end,
                            }
                        end
                        assert.are.equal("createProfile", property)
                        created_profile = profile_data
                        native_profiles[profile_data.essid] = {
                            essid = profile_data.essid,
                            netid = 22,
                            psk = profile_data.psk,
                            smethod = profile_data.smethod,
                        }
                        return { destroy = function() end }
                    end,
                    set_int_property = function(_self, service, property, value)
                        assert.are.equal("com.lab126.wifid", service)
                        assert.are.equal("deleteProfile", property)
                        kindle_deletes = kindle_deletes + 1
                        deleted_profile_id = value
                        for name, profile in pairs(native_profiles) do
                            if profile.netid == value then native_profiles[name] = nil break end
                        end
                    end,
                    close = function() end,
                }
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, widget) shown[#shown + 1] = widget end,
            close = function(_self, widget) closed[#closed + 1] = widget end,
            forceRePaint = function() end,
            broadcastEvent = function(_self, event) events[#events + 1] = event.name end,
            tickAfterNext = function(_self, action) scan_task = action end,
            nextTick = function(_self, action) action() end,
            scheduleIn = function(_self, delay, action)
                if delay == 3 then
                    follow_up_checks[#follow_up_checks + 1] = action
                    return
                end
                assert.are.equal(0.25, delay)
                scheduled[#scheduled + 1] = action
            end,
            unschedule = function(_self, action)
                for i = #scheduled, 1, -1 do
                    if scheduled[i] == action then table.remove(scheduled, i) end
                end
            end,
        })
        ZenSpec.replace("ffi/util", {
            template = function(value, ...)
                local args = { ... }
                return (value:gsub("%%(%d)", function(index)
                    return tostring(args[tonumber(index)])
                end))
            end,
            usleep = function(delay)
                if delay == 2 * 1000 * 1000 then
                    power_cycle_sleeps = power_cycle_sleeps + 1
                    return
                end
                assert.are.equal(250 * 1000, delay)
                verification_sleeps = verification_sleeps + 1
            end,
        })
        ZenSpec.replace("common/zen_logger", {
            new = function()
                return {
                    dbg = function(...) logs[#logs + 1] = { "dbg", ... } end,
                    warn = function(...) logs[#logs + 1] = { "warn", ... } end,
                    isEnabled = function() return true end,
                }
            end,
        })
        ZenSpec.replace("common/ui/icon_menu_item", {
            SETTINGS_CARET_SIZE = 22,
            getSettingsFontSize = function() return 27 end,
            installMenuPatch = function() end,
        })
        ZenSpec.replace("common/inline_icon_map", {
            delete = "delete",
            details = "details",
            edit = "edit",
            wifi_off = "wifi-off",
            wifi_on = "wifi-on",
        })
        ZenSpec.replace("common/plugin_root", "/tmp/zen-ui")
        ZenSpec.replace("common/utils", {
            resolveLocalIcon = function(path, name)
                assert.are.equal("/tmp/zen-ui/icons/", path)
                return path .. name .. ".svg"
            end,
        })
        ZenSpec.replace("modules/settings/zen_settings_utils", {
            get_device_ip_address = function()
                ip_calls = ip_calls + 1
                if ip_calls == 1 then return "192.168.1.10" end
                if ip_calls == 2 then return nil end
                return "10.0.0.20"
            end,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.unload("modules/menu/network_switcher")
    end)

    after_each(function()
        for _i, name in ipairs(module_names) do
            package.loaded[name] = original_modules[name]
        end
        ZenSpec.unload("modules/menu/network_switcher")
    end)

    local function finish_scan()
        scan_task()
        network_menu.custom_title_bar.action.callback()
        while #scheduled > 0 do table.remove(scheduled, 1)() end
    end

    it("opens and scans the switcher when Kindle has no saved networks", function()
        native_profiles = {}
        profile_read_fails = true
        package.loaded["device"].hasWifiRestore = function() return true end
        NetworkMgr.wifi_on = false
        NetworkMgr.current_ssid = nil
        NetworkMgr.getWifiMenuTable = function()
            error("KOReader Wi-Fi toggle should not run")
        end
        local Switcher = require("modules/menu/network_switcher")

        assert.is_true(Switcher.toggleWifi({}, function() end, false, {}))
        assert.are.equal("network_switcher", network_menu.name)
        assert.is_function(scan_task)
        scan_task()
        assert.is_true(NetworkMgr.wifi_on)
        assert.are.equal(1, kindle_scans)
        while #scheduled > 0 do table.remove(scheduled, 1)() end
        assert.are.equal("Home", network_menu.item_table[1].text)
    end)

    it("opens the switcher despite residual Kindle profiles", function()
        native_profiles = {
            Old = { essid = "Old", netid = 2, psk = "saved" },
            Older = { essid = "Older", netid = 3, psk = "saved" },
        }
        package.loaded["device"].hasWifiRestore = function() return true end
        NetworkMgr.wifi_on = false
        NetworkMgr.current_ssid = nil
        NetworkMgr.restoreWifiAsync = function() error("Kindle restore should not run") end
        NetworkMgr.getWifiMenuTable = function()
            error("KOReader Wi-Fi toggle should not run")
        end
        local Switcher = require("modules/menu/network_switcher")

        assert.is_true(Switcher.toggleWifi({}, function() end, false, {}))
        assert.are.equal("network_switcher", network_menu.name)
        scan_task()
        assert.are.equal(1, kindle_scans)
    end)

    it("opens the switcher when Kindle Wi-Fi is on without a connection or saved network", function()
        native_profiles = {}
        NetworkMgr.current_ssid = nil
        NetworkMgr.getWifiMenuTable = function()
            error("KOReader Wi-Fi toggle should not run")
        end
        local Switcher = require("modules/menu/network_switcher")

        assert.is_true(Switcher.toggleWifi({}, function() end, false, {}))
        assert.are.equal("network_switcher", network_menu.name)
        scan_task()
        assert.are.equal(1, kindle_scans)
    end)

    it("still turns off a connected Kindle", function()
        local calls = 0
        package.loaded["ui/uimanager"].topdown_widgets_iter = function()
            return function() end
        end
        NetworkMgr.getWifiMenuTable = function()
            return { callback = function()
                calls = calls + 1
                NetworkMgr.wifi_on = false
            end }
        end
        local Switcher = require("modules/menu/network_switcher")

        Switcher.toggleWifi({}, nil, false, {})
        assert.are.equal(1, calls)
        assert.is_false(NetworkMgr.wifi_on)
        assert.are.equal(0, #shown)
    end)

    it("uses KOReader's Wi-Fi toggle on Kobo with no saved Zen networks", function()
        ZenSpec.replace("device", {
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        package.loaded["ui/uimanager"].topdown_widgets_iter = function()
            return function() end
        end
        local updates = 0
        local touch_menu = { updateItems = function() updates = updates + 1 end }
        NetworkMgr.wifi_on = false
        NetworkMgr.current_ssid = nil
        NetworkMgr.getAllSavedNetworks = function()
            error("Kobo toggle should not inspect Zen saved networks")
        end
        NetworkMgr.getWifiMenuTable = function()
            return { callback = function(menu)
                assert.are.equal(touch_menu, menu)
                NetworkMgr.wifi_on = not NetworkMgr.wifi_on
                menu:updateItems()
            end }
        end
        local Switcher = require("modules/menu/network_switcher")
        Switcher.open = function() error("Kobo toggle should not open the Zen switcher") end

        Switcher.toggleWifi(touch_menu, nil, true, {})
        assert.is_true(NetworkMgr.wifi_on)
        Switcher.toggleWifi(touch_menu, nil, true, {})
        assert.is_false(NetworkMgr.wifi_on)
        assert.are.equal(2, updates)
    end)

    it("opens and scans the switcher when KOReader has no saved networks", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr.wifi_on = false
        NetworkMgr.current_ssid = nil
        NetworkMgr.getAllSavedNetworks = function() return { data = {} } end
        NetworkMgr.getWifiMenuTable = function()
            error("KOReader Wi-Fi toggle should not run")
        end
        local Switcher = require("modules/menu/network_switcher")

        assert.is_true(Switcher.toggleWifi({}, function() end, true, {}))
        assert.are.equal("network_switcher", network_menu.name)
        scan_task()
        assert.is_true(NetworkMgr.wifi_on)
        assert.are.equal("Home", network_menu.item_table[1].text)
    end)

    it("replaces Kobo's native network list with the Zen switcher", function()
        ZenSpec.replace("device", {
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr.wifi_on = false
        NetworkMgr.current_ssid = nil
        NetworkMgr.getAllSavedNetworks = function()
            error("Kobo toggle should not inspect Zen saved networks")
        end
        local NetworkSetting = {}
        ZenSpec.replace("ui/widget/networksetting", NetworkSetting)
        local UIManager = package.loaded["ui/uimanager"]
        local windows = {{ text = "Existing message" }}
        UIManager.topdown_widgets_iter = function()
            local index = #windows + 1
            return function()
                index = index - 1
                return windows[index]
            end
        end
        UIManager.close = function(_self, widget)
            closed[#closed + 1] = widget
            if widget.onCloseWidget then widget:onCloseWidget() end
            for index = #windows, 1, -1 do
                if windows[index] == widget then table.remove(windows, index) end
            end
        end
        local stock_calls, switcher_calls = 0, 0
        local dialog = setmetatable({
            network_list = {},
            onCloseWidget = function() NetworkMgr.pending_connection = false end,
        }, NetworkSetting)
        local notice = { text = "Connection failed" }
        NetworkMgr.getWifiMenuTable = function()
            return { callback = function(touch_menu)
                assert.are.equal("touch menu", touch_menu)
                stock_calls = stock_calls + 1
                if stock_calls == 1 then
                    windows[#windows + 1] = dialog
                    windows[#windows + 1] = notice
                    NetworkMgr.pending_connection = true
                end
            end }
        end
        local Switcher = require("modules/menu/network_switcher")
        Switcher.open = function(callback, settings_subpage, plugin)
            switcher_calls = switcher_calls + 1
            assert.is_false(NetworkMgr.pending_connection)
            assert.is_function(callback)
            assert.is_false(settings_subpage)
            assert.are.equal("plugin", plugin)
            return true
        end

        assert.is_true(Switcher.toggleWifi("touch menu", function() end, false, "plugin"))
        assert.are.same({ dialog, notice }, closed)
        assert.are.equal(1, switcher_calls)
        assert.is_nil(Switcher.toggleWifi("touch menu", function() end, false, "plugin"))
        assert.are.equal(2, stock_calls)
        assert.are.equal(1, switcher_calls)
    end)

    it("opens PocketBook settings without changing an active connection", function()
        ZenSpec.replace("device", {
            model = "PB700",
            hasWifiManager = function() return false end,
            hasWifiToggle = function() return true end,
            isPocketBook = function() return true end,
        })
        local launches, callbacks = 0, 0
        ZenSpec.replace("ffi/inkview", {
            OpenBook = function(path, position, flags)
                assert.are.equal("/ebrmain/bin/settings.app", path)
                assert.is_nil(position)
                assert.are.equal(0, flags)
                launches = launches + 1
            end,
        })

        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open(function() callbacks = callbacks + 1 end))
        assert.is_true(Switcher.open(nil, true, {}))

        assert.are.equal(2, launches)
        assert.are.equal(0, callbacks)
        assert.is_true(NetworkMgr.wifi_on)
        assert.are.equal("Home", NetworkMgr.current_ssid)
        assert.is_nil(NetworkMgr.disconnected)
        assert.is_nil(NetworkMgr.released)
        assert.is_nil(scan_task)
        assert.are.same({}, events)
        assert.are.same({}, shown)
    end)

    it("keeps devices without Wi-Fi unsupported", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return false end,
            hasWifiToggle = function() return false end,
            isPocketBook = function() return true end,
        })
        local Switcher = require("modules/menu/network_switcher")
        assert.is_false(Switcher.open())
        assert.are.equal("Network selection is not supported on this device.", shown[1].text)
        assert.is_nil(scan_task)
    end)

    it("opens connected Wi-Fi without scanning or changing the connection", function()
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()

        assert.are.equal(0, kindle_scans)
        assert.are.equal(1, #network_menu.item_table)
        assert.are.equal("Home", network_menu.item_table[1].text)
        assert.are.equal("Connected", network_menu.item_table[1]._zen_settings_breadcrumb)
        assert.is_true(NetworkMgr.wifi_on)
        assert.is_nil(NetworkMgr.released)
        assert.is_nil(NetworkMgr.disconnected)
        assert.are.same({}, events)
        network_menu.item_table[1].callback()
        assert.are.equal(4, #button_dialog.buttons)
        assert.is_truthy(button_dialog.buttons[1][1].text:find("Info", 1, true))
        assert.is_truthy(button_dialog.buttons[2][1].text:find("Edit", 1, true))
        assert.is_truthy(button_dialog.buttons[3][1].text:find("Disconnect", 1, true))
        assert.is_truthy(button_dialog.buttons[4][1].text:find("Forget", 1, true))
        network_menu.dimen = { x = 20, y = 20 }
        network_menu.item_dimen = { w = 560, h = 80 }
        network_menu.title_bar = { getSize = function() return { h = 100 } end }
        network_menu.item_group = {{ entry = network_menu.item_table[1] }}
        local anchor, prefers_down = button_dialog.anchor()
        assert.are.same({ x = 152, y = 149, w = 22, h = 22 }, anchor)
        assert.is_true(prefers_down)
        button_dialog.buttons[4][1].callback()
        assert.are.equal("Forget Wi-Fi network Home?", confirm_box.text)
        confirm_box.ok_callback()
        assert.are.equal(1, kindle_deletes)
        assert.is_false(NetworkMgr.wifi_on)
        assert.are.equal(0, kindle_scans)
    end)

    for _i, case in ipairs({
        { name = "accepts an unchanged IP when reconnecting with a default route",
            route = true, connected = true, sleeps = 0 },
        { name = "waits for a default route when reconnecting with an unchanged IP",
            route = true, connected = true, sleeps = 1 },
        { name = "rejects an unchanged IP when reconnecting without a default route",
            route = false, sleeps = 60 },
        { name = "handles a failed route check when reconnecting with an unchanged IP",
            route_error = true, sleeps = 60 },
        { name = "rejects a stale IP and route when switching to another network",
            switch_network = true, route = true, sleeps = 60 },
        { name = "checks the active SSID before accepting an unchanged IP",
            current_ssid = "Guest", route = true, sleeps = 60 },
        { name = "rejects an unchanged IP and route when authentication selects another SSID",
            actual_ssid = "Guest", route = true, sleeps = 60 },
    }) do
        it(case.name, function()
            local ip = "192.168.1.10"
            ZenSpec.replace("modules/settings/zen_settings_utils", {
                get_device_ip_address = function() return ip end,
            })
            NetworkMgr.hasDefaultRoute = function()
                if case.route_error then error("route unavailable") end
                return case.route and verification_sleeps >= (case.connected and case.sleeps or 0)
            end
            NetworkMgr.obtainIP = function(self)
                self.obtained = true
                if case.actual_ssid then self.current_ssid = case.actual_ssid end
            end
            local reported_network, reported_ip
            local Switcher = require("modules/menu/network_switcher")
            assert.is_true(Switcher.open(function(network, address)
                reported_network, reported_ip = network, address
            end))
            if case.switch_network then finish_scan() else scan_task() end
            local item = network_menu.item_table[case.switch_network and 2 or 1]
            local target_ssid = item.network.ssid
            network_menu:onMenuHold(item)
            button_dialog.buttons[2][1].callback()
            if case.current_ssid then NetworkMgr.current_ssid = case.current_ssid end
            local buttons = password_dialog.buttons[1]
            buttons[#buttons].callback()

            assert.are.equal(case.sleeps, verification_sleeps)
            assert.is_nil(NetworkMgr.released)
            assert.is_nil(NetworkMgr.disconnected)
            if case.connected then
                assert.are.equal(target_ssid, reported_network.ssid)
                assert.are.equal(ip, reported_ip)
                assert.are.equal(target_ssid, NetworkMgr.lease_ssid)
                assert.are.same({ "NetworkConnecting", "NetworkConnected" }, events)
            else
                assert.is_nil(reported_network)
                assert.is_nil(reported_ip)
                assert.is_nil(NetworkMgr.lease_ssid)
                assert.are.same(case.switch_network
                    and { "NetworkConnecting", "NetworkConnecting" }
                    or { "NetworkConnecting" }, events)
                if case.actual_ssid then
                    assert.are.equal("Connected to Guest instead of Home. The password may be incorrect.",
                        password_dialog.description)
                else
                    assert.are.equal("Connected to " .. target_ssid
                        .. ", but no IP address or default route was assigned.",
                        network_menu.item_table[1].text)
                end
            end
        end)
    end

    it("does not scan connected non-Kindle Wi-Fi until refresh", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKindle = function() return false end,
        })
        local scans = 0
        NetworkMgr.getCurrentNetwork = function()
            return { ssid = "Home", id = 7 }
        end
        NetworkMgr.getAllSavedNetworks = function()
            return { readSetting = function(_self, ssid)
                assert.are.equal("Home", ssid)
                return { flags = "[WPA2]", password = "saved" }
            end }
        end
        NetworkMgr.getNetworkList = function()
            scans = scans + 1
            return {{ ssid = "Home", connected = true }}
        end

        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        assert.are.equal(0, scans)
        assert.are.equal("Home", network_menu.item_table[1].text)
        network_menu.item_table[1].callback()
        assert.are.equal(4, #button_dialog.buttons)
        button_dialog.buttons[3][1].callback()
        assert.are.equal(7, NetworkMgr.disconnected.wpa_supplicant_id)
        assert.are.equal("saved", network_menu.item_table[1].network.password)
        assert.are.equal("Saved", network_menu.item_table[1]._zen_settings_breadcrumb)
        network_menu.item_table[1].callback()
        assert.is_nil(password_dialog)
        assert.are.equal("Home", NetworkMgr.authenticated.ssid)

        network_menu.custom_title_bar.action.callback()
        assert.are.equal(1, scans)
    end)

    it("disconnects and clears a connected Kobo network when forgotten", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr.getCurrentNetwork = function()
            return { ssid = "Home", id = 7 }
        end
        NetworkMgr.getConfiguredNetworks = function() return {} end
        NetworkMgr.getAllSavedNetworks = function()
            return { readSetting = function()
                return { flags = "[WPA2]", password = "saved" }
            end }
        end
        local disconnect_fails = true
        NetworkMgr.disconnectNetwork = function(self, network)
            if disconnect_fails then return nil, "WPA client unavailable" end
            self.disconnected = network
            self.current_ssid = nil
        end
        local refreshes = 0
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open(function() refreshes = refreshes + 1 end))
        scan_task()
        network_menu.item_table[1].callback()
        button_dialog.buttons[4][1].callback()
        confirm_box.ok_callback()
        assert.is_nil(NetworkMgr.deleted)
        assert.is_true(network_menu.item_table[1].network.connected)
        disconnect_fails = false
        confirm_box.ok_callback()

        assert.are.equal(7, NetworkMgr.disconnected.wpa_supplicant_id)
        assert.is_true(NetworkMgr.released)
        assert.are.equal("Home", NetworkMgr.deleted.ssid)
        assert.are.equal(1, refreshes)
        assert.is_nil(network_menu.item_table[1].network.saved)
        assert.are.equal("Available", network_menu.item_table[1]._zen_settings_breadcrumb)
        network_menu:onMenuHold(network_menu.item_table[1])
        assert.are.equal(2, #button_dialog.buttons)
    end)

    it("persists Kobo Forget before deleting KOReader credentials", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr.wpa_supplicant = { ctrl_interface = "/var/run/wpa_supplicant/wlan0" }
        NetworkMgr.getCurrentNetwork = function(self)
            return self.current_ssid and { ssid = self.current_ssid, id = "7" } or nil
        end
        local profiles = {{ ssid = "Home", id = "7" }, { ssid = "Guest", id = "8" }}
        NetworkMgr.getConfiguredNetworks = function() return profiles end
        local saved = { flags = "[WPA2]", password = "saved" }
        NetworkMgr.getAllSavedNetworks = function()
            return { readSetting = function() return saved end }
        end
        NetworkMgr.deleteNetwork = function(self, network)
            self.deleted = network
            saved = nil
        end
        NetworkMgr.disconnectNetwork = function() error("profile was already removed") end
        local commands = {}
        local save_fails = true
        ZenSpec.replace("lj-wpaclient/wpaclient", {
            new = function()
                return {
                    sendCtrlCmd = function(_self, command)
                        commands[#commands + 1] = command
                        if command == "REMOVE_NETWORK 7" then
                            profiles = {{ ssid = "Guest", id = "8" }}
                            NetworkMgr.current_ssid = nil
                        elseif command == "RECONFIGURE" then
                            profiles = {{ ssid = "Home", id = "7" }, { ssid = "Guest", id = "8" }}
                            NetworkMgr.current_ssid = "Home"
                        elseif command == "SAVE_CONFIG" and save_fails then
                            return "FAIL\n"
                        end
                        return "OK\n"
                    end,
                    close = function() end,
                }
            end,
        })

        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        network_menu.item_table[1].callback()
        button_dialog.buttons[4][1].callback()
        confirm_box.ok_callback()
        assert.are.same({ "REMOVE_NETWORK 7", "SAVE_CONFIG", "RECONFIGURE" }, commands)
        assert.is_nil(NetworkMgr.deleted)
        assert.is_true(network_menu.item_table[1].network.connected)

        save_fails = false
        confirm_box.ok_callback()
        assert.are.same({ "REMOVE_NETWORK 7", "SAVE_CONFIG", "RECONFIGURE",
            "REMOVE_NETWORK 7", "SAVE_CONFIG" }, commands)
        assert.are.same({{ ssid = "Guest", id = "8" }}, profiles)
        assert.are.equal("Home", NetworkMgr.deleted.ssid)
        assert.is_true(NetworkMgr.released)
        assert.are.equal("Available", network_menu.item_table[1]._zen_settings_breadcrumb)
        network_menu.item_table[1].callback()
        assert.is_not_nil(password_dialog)
    end)

    it("reuses a Kobo-configured network after disconnect without a KOReader password", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr.wpa_supplicant = { ctrl_interface = "/var/run/wpa_supplicant/wlan0" }
        NetworkMgr.getCurrentNetwork = function(self)
            return self.current_ssid and { ssid = self.current_ssid, id = "7" } or nil
        end
        NetworkMgr.getConfiguredNetworks = function()
            return {{ ssid = "Home", id = "7" }}
        end
        NetworkMgr.getNetworkList = function()
            return {{ ssid = "Home", flags = "[WPA2]", signal_quality = 80 }}
        end
        NetworkMgr.disconnectNetwork = function() error("Kobo profile must be preserved") end
        local commands = {}
        local association_checks = 0
        ZenSpec.replace("lj-wpaclient/wpaclient", {
            __index = { enableNetworkByID = function() end },
            new = function(path)
                assert.are.equal("/var/run/wpa_supplicant/wlan0", path)
                return {
                    sendCtrlCmd = function(_self, command)
                        commands[#commands + 1] = command
                        if command == "DISCONNECT" then NetworkMgr.current_ssid = nil end
                        if command == "SELECT_NETWORK 7" then NetworkMgr.current_ssid = "Home" end
                        return "OK\n"
                    end,
                    getConnectedNetwork = function()
                        association_checks = association_checks + 1
                        if association_checks == 1 then return nil end
                        return NetworkMgr.current_ssid and { id = "7" } or nil
                    end,
                    close = function() end,
                }
            end,
        })

        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        network_menu.item_table[1].callback()
        button_dialog.buttons[2][1].callback()
        assert.are.same({ "DISCONNECT" }, commands)
        assert.is_true(NetworkMgr.released)
        assert.are.equal("Saved", network_menu.item_table[1]._zen_settings_breadcrumb)

        assert.is_true(Switcher.open())
        scan_task()
        assert.are.equal("Saved · 80%", network_menu.item_table[1]._zen_settings_breadcrumb)
        network_menu:onMenuHold(network_menu.item_table[1])
        assert.is_truthy(button_dialog.buttons[3][1].text:find("Forget", 1, true))
        network_menu.item_table[1].callback()
        assert.is_nil(password_dialog)
        assert.are.same({ "DISCONNECT", "SELECT_NETWORK 7",
            "ENABLE_NETWORK all" }, commands)
        assert.are.equal(2, association_checks)
        assert.are.equal(1, verification_sleeps)
        assert.is_nil(NetworkMgr.authenticated)
        assert.are.equal("Connected · 80%", network_menu.item_table[1]._zen_settings_breadcrumb)

        network_menu.item_table[1].callback()
        button_dialog.buttons[2][1].callback()
        ip_calls = 0
        password_dialog.buttons[1][3].callback()
        assert.are.equal("guest-password", NetworkMgr.authenticated.password)
        assert.are.same({ "DISCONNECT", "SELECT_NETWORK 7",
            "ENABLE_NETWORK all" }, commands)
    end)

    it("reports a timed-out Kobo profile reconnect", function()
        NetworkMgr.wpa_supplicant = { ctrl_interface = "/var/run/wpa_supplicant/wlan0" }
        NetworkMgr.getConfiguredNetworks = function()
            return {{ ssid = "Home", id = "7" }}
        end
        local commands = {}
        ZenSpec.replace("lj-wpaclient/wpaclient", {
            new = function()
                return {
                    sendCtrlCmd = function(_self, command)
                        commands[#commands + 1] = command
                        return "OK\n"
                    end,
                    getConnectedNetwork = function() return nil end,
                    close = function() end,
                }
            end,
        })
        local Kobo = require("modules/menu/network_adapters/kobo")
        local adapter = Kobo.new(NetworkMgr, require("common/zen_logger").new())
        local connected, reason = adapter.connect({ ssid = "Home" })
        assert.is_false(connected)
        assert.are.equal("Timed out", reason)
        assert.are.equal(120, verification_sleeps)
        assert.are.same({ "SELECT_NETWORK 7", "ENABLE_NETWORK all" }, commands)
    end)

    it("resumes Kobo password authentication after Disconnect and Forget", function()
        NetworkMgr.wpa_supplicant = { ctrl_interface = "/var/run/wpa_supplicant/wlan0" }
        local profiles = {{ ssid = "Home", id = "7" }, { ssid = "Other", id = "8" }}
        NetworkMgr.getConfiguredNetworks = function() return profiles end
        local disconnected = false
        local current_id = "7"
        local other_enabled = true
        local auth_client
        local WpaClient = { __index = {} }
        WpaClient.new = function()
            return setmetatable({}, WpaClient)
        end
        local methods = WpaClient.__index
        methods.sendCtrlCmd = function(_self, command)
            if command == "DISCONNECT" then
                disconnected = true
                current_id = nil
            elseif command == "REMOVE_NETWORK 7" then
                table.remove(profiles, 1)
            elseif command == "SELECT_NETWORK 9" then
                disconnected = false
                other_enabled = false
                current_id = "9"
            elseif command == "ENABLE_NETWORK all" then
                other_enabled = true
            elseif command == "ENABLE_NETWORK 9" and not disconnected then
                current_id = "9"
            end
            return "OK\n"
        end
        methods.enableNetworkByID = function(self, id)
            return self:sendCtrlCmd("ENABLE_NETWORK " .. id)
        end
        local original_enable = methods.enableNetworkByID
        methods.addNetwork = function(self)
            auth_client = self
            return "9"
        end
        methods.setNetwork = function(_self, id, key, value)
            assert.are.equal("9", id)
            assert.are.equal(key == "ssid" and "Home" or "new-psk", value)
            return "OK"
        end
        methods.getConnectedNetwork = function()
            if current_id then return { id = current_id, ssid = "Home" } end
            return nil, "DISCONNECTED"
        end
        methods.attach = function() return true end
        methods.readEvent = function() end
        methods.waitForEvent = function() end
        methods.removeNetwork = function() end
        methods.close = function(self) self.closed = true end
        ZenSpec.replace("lj-wpaclient/wpaclient", WpaClient)
        ZenSpec.replace("ffi/crypto", {
            pbkdf2_hmac_sha1 = function(password, ssid)
                assert.are.equal("new-password", password)
                assert.are.equal("Home", ssid)
                return "new-psk"
            end,
        })
        ZenSpec.replace("ffi/sha2", { bin_to_hex = function(value) return value end })
        ZenSpec.replace("util", {})
        ZenSpec.unload("ui/network/wpa_supplicant")
        NetworkMgr.authenticateNetwork = require("ui/network/wpa_supplicant").authenticateNetwork
        local Kobo = require("modules/menu/network_adapters/kobo")
        local adapter = Kobo.new(NetworkMgr, require("common/zen_logger").new())
        local network = { ssid = "Home", wpa_supplicant_id = "7", password = "new-password" }

        assert.is_true(adapter.disconnect(network, true))
        assert.is_true(adapter.forgetNetwork(network))
        assert.is_true(adapter.connect(network, true))
        assert.is_false(disconnected)
        assert.are.equal("9", network.wpa_supplicant_id)
        assert.are.equal("new-psk", NetworkMgr.saved.psk)
        assert.are.same({{ ssid = "Other", id = "8" }}, profiles)
        assert.is_true(other_enabled)
        assert.is_true(auth_client.closed)
        assert.are.equal(original_enable, methods.enableNetworkByID)

        NetworkMgr.authenticateNetwork = function()
            auth_client = WpaClient.new()
            auth_client:enableNetworkByID("9")
            error("authentication interrupted")
        end
        local authenticated, err = adapter.connect(network, true)
        assert.is_false(authenticated)
        assert.is_truthy(err:find("authentication interrupted", 1, true))
        assert.is_true(other_enabled)
        assert.is_true(auth_client.closed)
        assert.are.equal(original_enable, methods.enableNetworkByID)
    end)

    it("saves a Kobo connection and remembers Wi-Fi for restoration", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        local saved_password
        local saves = 0
        NetworkMgr.wifi_on = false
        NetworkMgr.current_ssid = nil
        NetworkMgr.wifi_was_on = false
        G_reader_settings:saveSetting("wifi_was_on", false)
        NetworkMgr.getNetworkList = function()
            return {{
                ssid = "Guest", flags = "[WPA2]", signal_quality = 80,
                password = saved_password,
            }}
        end
        NetworkMgr.saveNetwork = function(_self, network)
            saves = saves + 1
            saved_password = network.password
        end
        NetworkMgr.getAllSavedNetworks = function()
            return { readSetting = function()
                return saved_password and { password = saved_password } or nil
            end }
        end
        NetworkMgr.isOnline = function() return true end
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        network_menu.item_table[1].callback()
        password_dialog.buttons[1][2].callback()

        assert.are.equal("guest-password", saved_password)
        assert.are.equal(1, saves)
        assert.is_true(NetworkMgr.wifi_was_on)
        assert.is_true(G_reader_settings:isTrue("wifi_was_on"))

        NetworkMgr.wifi_on = false
        NetworkMgr.current_ssid = nil
        ip_calls = 0
        password_dialog = nil
        assert.is_true(Switcher.open())
        scan_task()
        assert.are.equal("Saved · 80%", network_menu.item_table[1]._zen_settings_breadcrumb)
        network_menu.item_table[1].callback()
        assert.is_nil(password_dialog)
        assert.are.equal("Guest", NetworkMgr.authenticated.ssid)
        assert.are.equal(2, #follow_up_checks)
        follow_up_checks[2]()

        local messages = {}
        for _i, entry in ipairs(logs) do
            messages[#messages + 1] = entry[2]
            for _j, value in ipairs(entry) do
                assert.not_equal("guest-password", value)
            end
        end
        local output = table.concat(messages, "\n")
        assert.is_truthy(output:find("Kobo scan result", 1, true))
        assert.is_truthy(output:find("Kobo scan network", 1, true))
        assert.is_truthy(output:find("Kobo credentials saved", 1, true))
        assert.is_truthy(output:find("Kobo credentials before auth", 1, true))
        assert.is_truthy(output:find("Kobo connection result", 1, true))
        assert.is_truthy(output:find("Kobo connection follow-up", 1, true))
    end)

    it("scans automatically when there is no current network", function()
        NetworkMgr.current_ssid = nil
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        assert.are.equal(1, kindle_scans)
    end)

    it("keeps an active connection when its network name is unavailable", function()
        NetworkMgr.getCurrentNetwork = function() error("network name unavailable") end
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        assert.are.equal(0, kindle_scans)
        assert.are.equal("Connected", network_menu.item_table[1].text)
    end)

    it("cancels an active scan and accepts idle results after reopening", function()
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        network_menu.custom_title_bar.action.callback()

        assert.are.equal(1, kindle_scans)
        assert.are.equal(1, #scheduled)
        local pending_poll = scheduled[1]

        network_menu.custom_title_bar.close_callback()

        assert.are.equal(0, #scheduled)
        assert.are.equal(1, scan_handle_closes)
        pending_poll()
        assert.are.equal("Searching for networks…", network_menu.item_table[1].text)

        kindle_scan_stays_idle = true
        assert.is_true(Switcher.open())
        finish_scan()
        assert.are.equal(2, kindle_scans)
        assert.are.equal("Guest", network_menu.item_table[2].text)
    end)

    it("rescans from the title bar without overlapping scans", function()
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        local refresh = network_menu.custom_title_bar.action
        assert.are.equal("/tmp/zen-ui/icons/quick_sync.svg", refresh.file)

        scan_task()
        refresh.callback()
        assert.are.equal(1, kindle_scans)
        while #scheduled > 0 do table.remove(scheduled, 1)() end

        refresh.callback()
        assert.are.equal("Searching for networks…", network_menu.item_table[1].text)
        assert.are.equal(2, kindle_scans)
        refresh.callback()
        assert.are.equal(2, kindle_scans)
        while #scheduled > 0 do table.remove(scheduled, 1)() end
        assert.are.equal("Guest", network_menu.item_table[2].text)
    end)

    it("uses settings back navigation when opened from Settings", function()
        local Switcher = require("modules/menu/network_switcher")
        local plugin = {}
        assert.is_true(Switcher.open(nil, true, plugin))
        assert.is_true(network_menu.custom_title_bar.back_visible)
        assert.is_false(network_menu.custom_title_bar.close_visible)
        assert.are.equal(plugin, network_menu.custom_title_bar.plugin)
        assert.are.equal(network_menu.custom_title_bar.back_callback,
            network_menu.custom_title_bar.back_hold_callback)

        network_menu.custom_title_bar.back_callback()
        scan_task()
        assert.are.equal(0, kindle_scans)

        assert.is_true(Switcher.open(nil, true))
        network_menu.dimen = { w = 600 }
        assert.is_true(network_menu:onSwipe(nil, {
            direction = "east",
            pos = { x = 100 },
        }))
        scan_task()
        assert.are.equal(0, kindle_scans)
    end)

    it("prompts, saves, switches, and verifies an unsaved network", function()
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open(function(network, ip)
            connected_network = network
            connected_ip = ip
        end))

        assert.are.equal("menu", network_menu.kind)
        assert.are.equal("network_switcher", network_menu.name)
        assert.are.equal(8, network_menu.items_per_page)
        assert.are.equal(27, network_menu.items_font_size)
        assert.is_false(network_menu.custom_title_bar.back_visible)
        assert.is_true(network_menu.custom_title_bar.close_visible)
        assert.is_false(network_menu.custom_title_bar.search_visible)
        assert.is_true(network_menu.custom_title_bar.title_full_width)
        assert.is_true(network_menu.custom_title_bar.root_icon.skip_paint)
        assert.is_nil(network_menu.custom_title_bar.status_factory)
        assert.are.equal(network_menu, network_menu.custom_title_bar.show_parent)
        assert.is_true(network_menu.custom_title_bar.was_cleared)
        assert.is_true(network_menu.custom_title_bar.was_initialized)
        assert.are.equal("Searching for networks…", network_menu.item_table[1].text)
        assert.is_true(network_menu.item_table[1]._zen_settings_row)
        assert.are.equal("Searching for networks…",
            network_menu.item_table[1]._zen_display_text)
        assert.is_nil(NetworkMgr.disconnected)
        assert.is_function(scan_task)

        finish_scan()

        assert.are.equal("Guest", network_menu.item_table[2].text)
        assert.are.equal(0, kindle_disconnects)
        assert.are.equal(1, kindle_scans)
        assert.are.equal(0, power_cycle_sleeps)
        assert.is_true(NetworkMgr.wifi_on)
        assert.is_nil(NetworkMgr.disconnected)
        assert.is_nil(NetworkMgr.released)
        assert.are.equal("Connected · 80%",
            network_menu.item_table[1]._zen_settings_breadcrumb)
        assert.are.equal("wifi-on", network_menu.item_table[1].icon_glyph)
        assert.is_nil(network_menu.item_table[2].icon_glyph)
        assert.is_true(network_menu.item_table[2]._zen_value_black)
        network_menu.item_table[2].callback()
        assert.are.equal("password", password_dialog.kind)
        assert.is_true(password_dialog.keyboard_shown)
        assert.is_nil(NetworkMgr.authenticated)

        password_dialog.buttons[1][2].callback()

        assert.is_nil(NetworkMgr.saved)
        assert.are.same({
            essid = "Guest",
            psk = "guest-password",
            secured = "yes",
            smethod = "wpa2",
            store_nw_user_pref = 0,
        }, created_profile)
        assert.are.equal(0, kindle_disconnects)
        assert.are.equal(1, kindle_connects)
        assert.are.equal(0, kindle_deletes)
        assert.are.equal("Guest", NetworkMgr.authenticated.ssid)
        assert.is_true(NetworkMgr.obtained)
        assert.are.equal("Guest", NetworkMgr.lease_ssid)
        assert.is_true(NetworkMgr.queried)
        assert.are.same({
            "NetworkConnecting",
            "NetworkConnected",
        }, events)
        assert.are.equal("Guest", connected_network.ssid)
        assert.are.equal("10.0.0.20", connected_ip)
        assert.are.equal(0, verification_sleeps)
        assert.are.equal(2, #network_menu.item_table)
        assert.are.equal("Home", network_menu.item_table[1].text)
        assert.are.equal("Guest", network_menu.item_table[2].text)
        assert.are.equal("Saved · 80%",
            network_menu.item_table[1]._zen_settings_breadcrumb)
        assert.is_nil(network_menu.item_table[1].icon_glyph)
        assert.are.equal("Connected · 60%",
            network_menu.item_table[2]._zen_settings_breadcrumb)
        assert.are.equal("wifi-on", network_menu.item_table[2].icon_glyph)
        assert.is_true(network_menu.item_table[2]._zen_value_black)
        assert.is_true(network_menu.item_table[2]._zen_settings_row)
        assert.are.equal("/tmp/zen-ui/icons/app_menu.svg",
            network_menu.item_table[2]._zen_caret_icon)
        assert.are.equal(2, network_menu.selected_index)

        network_menu.dimen = { x = 20, y = 20 }
        network_menu.border_size = 0
        network_menu.item_dimen = { w = 560, h = 80 }
        network_menu.title_bar = { getSize = function() return { h = 100 } end }
        network_menu.item_group = {
            { entry = network_menu.item_table[1] },
            { entry = network_menu.item_table[2] },
        }
        network_menu:onMenuSelect(network_menu.item_table[2], { x = 0.9, y = 0.5 })
        assert.are.equal("actions", button_dialog.kind)
        assert.are.equal("Guest", button_dialog.title)
        assert.are.equal(0.5, button_dialog.width_factor)
        assert.is_nil(button_dialog.buttons[1][1].height)
        assert.are.same({ x = 152, y = 229, w = 22, h = 22 }, button_dialog.anchor())
        assert.is_truthy(button_dialog.buttons[1][1].text:find("Info", 1, true))
        button_dialog.buttons[1][1].callback()
        assert.is_truthy(shown[#shown].text:find("IP address: 10.0.0.20", 1, true))

        network_menu:onMenuSelect(network_menu.item_table[2], { x = 0.9, y = 0.5 })
        assert.is_truthy(button_dialog.buttons[3][1].text:find("Disconnect", 1, true))
        button_dialog.buttons[3][1].callback()
        assert.is_false(NetworkMgr.wifi_on)
        assert.is_true(NetworkMgr.released)
        assert.are.equal(2, #network_menu.item_table)
        assert.are.equal("Saved · 60%",
            network_menu.item_table[2]._zen_settings_breadcrumb)
        assert.is_nil(network_menu.item_table[2].icon_glyph)
        assert.are.same({
            "NetworkConnecting",
            "NetworkConnected",
            "NetworkDisconnecting",
            "NetworkDisconnected",
        }, events)
    end)

    it("explains a target mismatch and prompts to replace the saved password", function()
        NetworkMgr.guest_password = "old-password"
        native_profiles.Guest = { essid = "Guest", netid = 22, psk = "old-password" }
        fail_first_auth = true

        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        finish_scan()
        network_menu.item_table[2].callback()

        assert.are.equal(1, authentication_attempts)
        assert.are.equal(0, kindle_deletes)
        assert.is_nil(created_profile)
        assert.are.equal("Guest", password_dialog.title)
        assert.are.equal("old-password", password_dialog.input)
        assert.are.equal(
            "Connected to Home instead of Guest. The password may be incorrect.",
            password_dialog.description
        )

        assert.are.equal("Forget", password_dialog.buttons[1][2].text)
        password_dialog.buttons[1][3].callback()

        assert.are.equal(2, authentication_attempts)
        assert.are.equal(0, kindle_disconnects)
        assert.are.equal(2, kindle_connects)
        assert.are.equal(1, kindle_deletes)
        assert.are.equal(22, deleted_profile_id)
        assert.are.equal("guest-password", created_profile.psk)
        assert.are.equal("wpa2", created_profile.smethod)
        assert.are.equal("Guest", NetworkMgr.lease_ssid)
        assert.is_true(NetworkMgr.queried)
        assert.are.equal(60, verification_sleeps)
        assert.is_true(#logs > 0)
    end)

    it("forgets a saved Kindle profile on hold", function()
        NetworkMgr.guest_password = string.rep("ab", 32)
        native_profiles.Guest = {
            essid = "Guest",
            netid = 22,
            psk = string.rep("ab", 32),
        }

        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        finish_scan()

        network_menu:onMenuHold(network_menu.item_table[2])
        assert.are.equal("actions", button_dialog.kind)
        assert.is_truthy(button_dialog.buttons[3][1].text:find("Forget", 1, true))
        button_dialog.buttons[3][1].callback()
        assert.are.equal("confirm", confirm_box.kind)
        assert.are.equal("Forget Wi-Fi network Guest?", confirm_box.text)
        confirm_box.ok_callback()

        assert.are.equal(0, kindle_disconnects)
        assert.are.equal(1, kindle_deletes)
        assert.are.equal(22, deleted_profile_id)
        assert.is_nil(native_profiles.Guest)
        assert.are.equal("Guest", NetworkMgr.deleted.ssid)
        assert.is_nil(NetworkMgr.deleted.password)
        assert.are.equal("Guest", network_menu.item_table[2].text)
        assert.are.equal("60%", network_menu.item_table[2]._zen_settings_breadcrumb)
    end)
end)
