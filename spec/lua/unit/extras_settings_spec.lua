describe("Extras settings", function()
    it("toggles Zen OPDS on its parent row and keeps display modes in the submenu", function()
        local originals = {}
        local function replace(name, module)
            originals[name] = { value = package.loaded[name] }
            ZenSpec.replace(name, module)
        end
        replace("gettext", function(text) return text end)
        replace("device", {})
        replace("ffi/util", {})
        replace("common/icon_packs", {})
        replace("modules/filebrowser/patches/rakuyomi", { is_available = function() return false end })
        replace("modules/settings/sections/global_settings", { build_extras_items = function() return {} end })
        replace("modules/settings/sections/stats_settings", { build = function() return { text = "Stats" } end })
        replace("modules/settings/zenpm_installer", { detect_assets = function() return false end })
        replace("common/inline_icon_map", { settings_opds = "opds-icon" })
        replace("common/ui/icon_menu_item", {
            decorate = function(item, glyph)
                item.icon_glyph = glyph
                return item
            end,
        })
        replace("modules/settings/sections/extras_settings", false)
        local ok, err = pcall(function()
            local saved, updates, restart_prompts = 0, 0, 0
            local config = { features = {} }
            local items = require("modules/settings/sections/extras_settings").build({
                config = config,
                plugin = { saveConfig = function() saved = saved + 1 end },
                settings_apply = { prompt_restart = function() restart_prompts = restart_prompts + 1 end },
            })
            local opds = items[2]
            assert.are.equal("Zen OPDS", opds.text)
            assert.are.equal("opds-icon", opds.icon_glyph)
            assert.are.equal(opds.callback, opds.checkmark_callback)
            assert.is_true(opds.checked_func())
            assert.are.equal(1, #opds.sub_item_table)
            local display_modes = opds.sub_item_table[1]
            assert.are.equal("Display mode", display_modes.text)
            assert.are.equal(3, #display_modes.sub_item_table)

            local menu = { updateItems = function() updates = updates + 1 end }
            opds.checkmark_callback(menu)
            assert.is_false(config.features.zen_opds)
            assert.is_false(opds.checked_func())
            opds.checkmark_callback(menu)
            assert.is_true(config.features.zen_opds)
            assert.is_true(opds.checked_func())
            assert.are.equal(2, saved)
            assert.are.equal(2, updates)
            assert.are.equal(2, restart_prompts)

            local classic = display_modes.sub_item_table[3]
            assert.are.equal("Classic", classic.text)
            classic.callback(menu)
            assert.are.equal("classic", config.opds.display_mode)
            assert.is_true(classic.checked_func())
            assert.are.equal(3, saved)
            assert.are.equal(3, updates)
            assert.are.equal(2, restart_prompts)
        end)
        for name, original in pairs(originals) do package.loaded[name] = original.value end
        assert.is_true(ok, err)
    end)
end)
