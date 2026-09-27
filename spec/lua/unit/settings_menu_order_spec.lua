describe("settings menu organization", function()
    it("groups device settings below Reader with and without Bluetooth", function()
        local originals = {}
        local function replace(name, value)
            originals[name] = { value = package.loaded[name] }
            ZenSpec.replace(name, value)
        end
        local function items(labels)
            local result = {}
            for _i, label in ipairs(labels) do result[#result + 1] = { text = label } end
            return result
        end
        local function labels(item_table)
            local result = {}
            for _i, item in ipairs(item_table) do result[#result + 1] = item.text end
            return result
        end

        replace("gettext", function(text) return text end)
        replace("ui/uimanager", {})
        replace("common/shutdown", {})
        replace("modules/settings/zen_settings_apply", {})
        replace("modules/settings/zen_updater", {
            init_banner = function() end,
            build_update_available_action = function() end,
        })
        replace("common/inline_icon_map", { settings = "gear" })
        replace("common/ui/icon_menu_item", {
            installMenuPatch = function() end,
            decorate = function(item, glyph)
                item.icon_glyph = glyph
                return item
            end,
        })
        replace("device", {})
        replace("modules/settings/zen_settings_utils", false)
        for _i, section in ipairs({
            "library_settings/home_settings", "library_settings/navbar_settings",
            "menu_settings", "app_launcher_settings",
        }) do
            replace("modules/settings/sections/" .. section, { build = function() return {} end })
        end
        for _i, section in ipairs({ "library_settings", "reader_settings", "updates_settings" }) do
            replace("modules/settings/sections/" .. section, {
                build = function() return items({ "Original control" }) end,
            })
        end
        replace("modules/settings/sections/extras_settings", {
            build = function()
                return items({ "Stats", "Install ZenPM", "Zen OPDS", "Rakuyomi", "Schedules", "Sleep", "Zen Search", "Lockdown mode", "Zen Keyboard", "Custom icons" })
            end,
        })
        local has_bluetooth, wifi_item, bluetooth_item, double_tap_item, language_item, time_item
        replace("modules/settings/sections/about_settings", {
            build = function()
                local result = items({ "Version", "Wi-Fi", "Device", "Setup Guide", "Report a Bug", "Advanced" })
                wifi_item = result[2]
                result[6].sub_item_table = items({ "Original control", "Double tap to open books" })
                double_tap_item = result[6].sub_item_table[2]
                language_item = { text = "Language", sub_item_table = {} }
                time_item = { text = "Time and date", sub_item_table = {} }
                if has_bluetooth then
                    bluetooth_item = { text = "Bluetooth" }
                    table.insert(result, 3, bluetooth_item)
                end
                return result, language_item, time_item
            end,
        })

        local original_builder = package.loaded["modules/settings/zen_settings"]
        ZenSpec.unload("modules/settings/zen_settings")
        local builder = require("modules/settings/zen_settings")
        for _i, available in ipairs({ false, true }) do
            has_bluetooth = available
            local root = builder.build({ config = { features = {} } }).sub_item_table
            assert.are.same({ "Controls", "Launcher", "Home", "Library", "Navbar", "Reader", "General", "Extras" }, labels(root))
            assert.are.equal("gear", root[7].icon_glyph)
            local general = root[7].sub_item_table
            local expected = { "Wi-Fi", "Schedules", "Sleep", "Language", "Time and date", "Advanced", "Updates", "About" }
            if available then table.insert(expected, 2, "Bluetooth") end
            assert.are.same(expected, labels(general))
            assert.are.equal(wifi_item, general[1])
            assert.are.equal(language_item, general[#general - 4])
            assert.are.equal(time_item, general[#general - 3])
            if available then assert.are.equal(bluetooth_item, general[2]) end
            assert.are.same({ "Original control" }, labels(general[#general - 2].sub_item_table))
            assert.are.same({ "Original control" }, labels(general[#general - 1].sub_item_table))
            assert.are.same({ "Original control", "Double tap to open books" }, labels(root[4].sub_item_table))
            assert.are.equal(double_tap_item, root[4].sub_item_table[#root[4].sub_item_table])
            assert.are.same({ "Version", "Device", "Setup Guide", "Report a Bug", "Quit KOReader" }, labels(general[#general].sub_item_table))
            assert.are.same({ "Install ZenPM", "Zen OPDS", "Zen Search", "Zen Keyboard", "Stats", "Rakuyomi", "Lockdown mode", "Custom icons" }, labels(root[8].sub_item_table))
        end
        package.loaded["modules/settings/zen_settings"] = original_builder
        for name, original in pairs(originals) do package.loaded[name] = original.value end
    end)
end)
