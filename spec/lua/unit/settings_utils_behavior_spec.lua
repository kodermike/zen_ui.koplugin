describe("settings utilities", function()
    local Utils

    before_each(function()
        ZenSpec.replace("device", {})
        ZenSpec.replace("ui/uimanager", {})
        ZenSpec.unload("modules/settings/zen_settings_utils")
        Utils = require("modules/settings/zen_settings_utils")
    end)

    it("normalizes values and reads and writes nested paths", function()
        assert.are.equal("42", Utils.normalize_value(42))
        assert.are.equal("value", Utils.normalize_value("  value  "))
        assert.is_nil(Utils.normalize_value("   "))
        assert.is_nil(Utils.normalize_value({}))
        assert.are.equal("first", Utils.first_non_empty("", nil, "first", "second"))

        local config = {}
        Utils.set_path(config, { "reader", "clock", "enabled" }, true)
        assert.is_true(Utils.get_path(config, { "reader", "clock", "enabled" }))
        assert.is_nil(Utils.get_path(config, { "reader", "missing" }))
    end)

    it("toggles a feature and invokes the supplied apply callback", function()
        local config = { features = { navbar = false } }
        local applied
        local item = Utils.make_enable_feature_item("navbar", "Navbar", config, function(feature)
            applied = feature
        end)

        assert.is_false(item.checked_func())
        item.callback()
        assert.is_true(item.checked_func())
        assert.are.equal("navbar", applied)
        item.callback()
        assert.is_false(item.checked_func())
    end)

    it("orders preferred items first while preserving all remaining items", function()
        local alpha = { text = "Alpha" }
        local beta = { text = "Beta" }
        local duplicate_beta = { text = "Beta", id = "duplicate" }
        local unnamed = { separator = true }

        local ordered = Utils.order_items_by_text(
            { alpha, beta, duplicate_beta, unnamed },
            { "Beta", "Missing", "Alpha" }
        )

        assert.are.same({ beta, alpha, duplicate_beta, unnamed }, ordered)
    end)

    it("reorders the first matching nested submenu", function()
        local one = { text = "One" }
        local two = { text = "Two" }
        local menu = {{
            text = "Outer",
            sub_item_table = {{
                text = "Target",
                sub_item_table = { one, two },
            }},
        }}

        assert.is_true(Utils.reorder_nested_items_by_text(menu, "Target", { "Two", "One" }))
        assert.are.same({ two, one }, menu[1].sub_item_table[1].sub_item_table)
        assert.is_false(Utils.reorder_nested_items_by_text(menu, "Missing", {}))
    end)

    it("formats time and resolves the active file manager directory", function()
        assert.are.equal("03:07", Utils.fmt_time(3, 7))
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = { file_chooser = { path = "/books/current" } },
        })
        assert.are.equal("/books/current", Utils.get_current_dir())

        ZenSpec.replace("apps/filemanager/filemanager", { instance = nil })
        G_reader_settings:saveSetting("lastdir", "/books/last")
        assert.are.equal("/books/last", Utils.get_current_dir())
    end)

    it("uses the library layout for image pickers and falls back from classic to mosaic", function()
        local modules = { "bookinfomanager", "covermenu", "listmenu", "mosaicmenu",
            "common/cover_utils", "ui/widget/pathchooser" }
        local originals = {}
        for _i, name in ipairs(modules) do originals[name] = package.loaded[name] end
        local mode = "list_only_meta"
        local update = function() end
        local close = function() end
        local list_build = function() end
        local mosaic_build = function() end
        ZenSpec.replace("bookinfomanager", {
            getSetting = function(_self, key)
                if key == "filemanager_display_mode" then return mode end
                return ({ nb_cols_portrait = 4, nb_rows_portrait = 5,
                    nb_cols_landscape = 6, nb_rows_landscape = 7 })[key]
            end,
        })
        ZenSpec.replace("covermenu", { updateItems = update, onCloseWidget = close })
        ZenSpec.replace("listmenu", {
            _recalculateDimen = list_build, _updateItemsBuildUI = list_build,
        })
        ZenSpec.replace("mosaicmenu", {
            _recalculateDimen = mosaic_build, _updateItemsBuildUI = mosaic_build,
        })
        ZenSpec.replace("common/cover_utils", { getFilesPerPage = function() return 9 end })
        ZenSpec.replace("ui/widget/pathchooser", {
            new = function(_self, options) return options end,
        })

        local list = Utils.newImagePathChooser{ path = "/images" }
        assert.are.equal("list", list.display_mode_type)
        assert.are.equal(list_build, list._updateItemsBuildUI)
        assert.are.equal(update, list.updateItems)
        assert.are.equal(close, list.onCloseWidget)
        assert.is_true(list._do_cover_images)
        assert.is_true(list._do_filename_only)
        assert.are.equal(9, list.files_per_page)

        mode = "classic"
        local mosaic = Utils.newImagePathChooser{ path = "/images" }
        assert.are.equal("mosaic", mosaic.display_mode_type)
        assert.are.equal(mosaic_build, mosaic._updateItemsBuildUI)
        assert.is_true(mosaic._do_cover_images)
        assert.are.same({ 4, 5, 6, 7 }, {
            mosaic.nb_cols_portrait, mosaic.nb_rows_portrait,
            mosaic.nb_cols_landscape, mosaic.nb_rows_landscape,
        })

        mode = "mosaic_text"
        assert.are.equal("mosaic", Utils.newImagePathChooser{}.display_mode_type)
        for _i, name in ipairs(modules) do package.loaded[name] = originals[name] end
    end)

    it("prefers the active interface IPv4 address", function()
        ZenSpec.replace("ui/network/manager", { interface = "wlan0" })
        ZenSpec.replace("ffi/posix_h", {})
        local freed = false
        local wlan0 = {
            ifa_name = "wlan0",
            ifa_addr = { sa_family = 2 },
        }
        local eth0 = {
            ifa_name = "eth0",
            ifa_addr = { sa_family = 2 },
            ifa_next = wlan0,
        }
        ZenSpec.replace("ffi", {
            C = {
                AF_INET = 2,
                NI_MAXHOST = 64,
                NI_NUMERICHOST = 1,
                getifaddrs = function(ifaddrs)
                    ifaddrs[0] = eth0
                    return 0
                end,
                getnameinfo = function(sockaddr, _size, host)
                    host.value = sockaddr == eth0.ifa_addr and "192.168.1.10" or "192.168.1.20"
                    return 0
                end,
                freeifaddrs = function() freed = true end,
            },
            new = function() return {} end,
            sizeof = function() return 16 end,
            string = function(value) return type(value) == "table" and value.value or value end,
        })

        assert.are.equal("192.168.1.20", Utils.get_device_ip_address())
        assert.is_true(freed)
    end)
end)
