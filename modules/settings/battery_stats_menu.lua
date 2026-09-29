local _ = require("gettext")

local M = {}

function M.buildItems()
    local BatteryStats = require("common/battery_stats")
    local stats = BatteryStats.snapshot()
    local missing = "-"
    if not stats then return {{ text = missing, keep_menu_open = true }} end
    local datetime = require("datetime")
    local function duration(seconds)
        if not seconds then return missing end
        local formatted = datetime.secondsToClockDuration("letters", seconds, true, true)
        return (formatted:gsub("\u{2009}", " "))
    end
    local function rate(value)
        return value and string.format("%.2f%%/h", value) or missing
    end
    local function row(label, value)
        return { text = label .. ": " .. value, keep_menu_open = true }
    end
    local health_items = {
        row(_("Battery percentage"), stats.level and stats.level .. "%" or missing),
        row(_("Current capacity"), stats.current_mah and string.format("%.0f mAh", stats.current_mah) or missing),
        row(_("Full capacity"), stats.full_mah and string.format("%.0f mAh", stats.full_mah) or missing),
        row(_("Design capacity"), stats.design_mah and string.format("%.0f mAh", stats.design_mah) or missing),
        row(_("Battery health"), stats.health and string.format("%.0f%%", stats.health) or missing),
    }
    local usage_items = {
        row(_("Used per hour"), rate(stats.overall)),
        row(_("While awake"), rate(stats.awake)),
        row(_("While asleep"), rate(stats.asleep)),
        row(_("Screen on time"), duration(stats.awake_time)),
        row(_("Screen off time"), duration(stats.asleep_time)),
    }
    local items
    local settings_items = {
        row(_("Tracked samples"), tostring(stats.samples)),
        {
            text = _("Reset battery log"),
            separator = true,
            keep_menu_open = true,
            callback = function(touchmenu)
                require("ui/uimanager"):show(require("ui/widget/confirmbox"):new{
                    text = _("Reset battery log") .. "?",
                    ok_text = _("Reset"),
                    ok_callback = function()
                        BatteryStats.reset()
                        if touchmenu and touchmenu.updateItems then
                            local refreshed = M.buildItems()
                            for i = 1, #items do items[i] = refreshed[i] end
                            touchmenu.item_table = items[#items].sub_item_table
                            touchmenu:updateItems()
                        end
                    end,
                })
            end,
        },
    }
    items = {
        {
            text = _("Health"),
            mandatory = stats.health and string.format("%.0f%%", stats.health) or missing,
            sub_item_table = health_items,
        },
        {
            text = _("Usage"),
            mandatory = rate(stats.overall),
            sub_item_table = usage_items,
        },
        { text = _("Estimated time remaining"), mandatory = duration(stats.remaining), keep_menu_open = true },
        { text = _("Time since last charge"),
            mandatory = stats.charging and _("Charging") or duration(stats.since_charge),
            keep_menu_open = true },
        { text = _("Settings"), sub_item_table = settings_items },
    }
    return items
end

function M.open(plugin)
    return require("modules/settings/zen_settings_page").show(plugin, {
        title = _("Battery"),
        root_items = M.buildItems(),
    })
end

return M
