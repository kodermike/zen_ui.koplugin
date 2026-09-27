local ConfigDialog = require("ui/widget/configdialog")
local util = require("util")
local _ = require("gettext")

local M = {}

local function label(value)
    if type(value) ~= "table" then return tostring(value) end
    local parts = {}
    for index, part in ipairs(value) do parts[index] = tostring(part) end
    return table.concat(parts, ", ")
end

function M.build(owner, page)
    local reader = owner.ui
    local config = reader.config
    local controller = setmetatable({
        ui = reader, document = reader.document,
        configurable = config.configurable, config_options = config.options,
        _zen_settings_page = page,
        dialog_frame = { dimen = page.dimen },
        update = function()
            if not page._closed then
                page._search_index = nil
                page:updateItems()
            end
        end,
    }, { __index = ConfigDialog })

    local function decorate(item)
        item._zen_native_owner = owner
        item._zen_native_setting = true
        item.keep_menu_open = true
        return item
    end
    local function name(option)
        return option.name_text_func and option.name_text_func(config.configurable, reader.document)
            or option.name_text or option.alt_name_text or option.name
    end
    local function choices(option)
        local items = {}
        local action = option.name == "font_fine_tune" or option.values and #option.values == 0
        local values = not action and option.values or option.args or {}
        local labels = option.labels or option.toggle or option.item_text or values
        for index, value in ipairs(values) do
            items[#items + 1] = decorate({
                text_func = function()
                    if action then return label(labels[index] or value) end
                    local default = G_reader_settings:readSetting(config.options.prefix .. "_" .. option.name)
                    if default == nil then default = option.default_value end
                    return label(labels[index] or value) .. (util.tableEquals(default, value) and " ★" or "")
                end,
                radio = not action,
                checked_func = not action and function()
                    local current = option.current_func and option.current_func()
                    if current == nil then current = config.configurable[option.name] end
                    return util.tableEquals(current, value)
                end or nil,
                callback = function()
                    controller:onConfigChoose(option.values, option.name, option.event,
                        option.args, index, option.hide_on_apply)
                end,
                hold_callback = function()
                    controller:onMakeDefault(option.name, name(option), values, labels, index)
                end,
            })
        end
        if option.fine_tune then
            for _i, direction in ipairs({ "-", "+" }) do
                items[#items + 1] = decorate({
                    text = direction == "-" and _("Decrease") or _("Increase"),
                    callback = function()
                        controller:onConfigFineTuneChoose(option.values, option.name, option.event,
                            option.args, direction, option.hide_on_apply, option.fine_tune_param)
                    end,
                    hold_callback = function()
                        controller:onMakeFineTuneDefault(option.name, name(option), values, labels, direction)
                    end,
                })
            end
        end
        if option.more_options then
            items[#items + 1] = decorate({
                text = _("More"),
                callback = function()
                    local default = option.default_value
                    local params = {}
                    for key, value in pairs(option.more_options_param or {}) do params[key] = value end
                    params.show_true_value_func = params.show_true_value_func or option.show_true_value_func
                    if params.names then
                        default = {}
                        for index, key in ipairs(params.names) do
                            default[index] = controller:findOptionByName(key).default_value
                        end
                    end
                    controller:onConfigMoreChoose(option.values, default, option.name,
                        option.event, nil, name(option), params)
                end,
            })
        end
        return items
    end
    local items = { _zen_native_owner = owner }
    for _i, panel in ipairs(config.options) do
        local companions = {}
        for _j, option in ipairs(panel.options) do
            local target = option.name == "font_fine_tune" and "font_size"
                or option.more_options_param and option.more_options_param.name
            if target and target ~= option.name
                    and (option.name == "font_fine_tune" or option.values and #option.values == 0) then
                companions[target] = option
            end
        end
        for _j, option in ipairs(panel.options) do
            local target = option.more_options_param and option.more_options_param.name
            if not (option.name == "font_fine_tune" or target and companions[target] == option) then
                local companion = companions[option.name]
                items[#items + 1] = decorate({
                    text_func = function()
                        local text = name(option)
                        return text == option.name and companion and name(companion) or text
                    end,
                    show_func = function()
                        if option.show_func then return option.show_func(config.configurable, reader.document) ~= false end
                        return option.show ~= false
                    end,
                    enabled_func = function()
                        return not option.enabled_func or option.enabled_func(config.configurable, reader.document) ~= false
                    end,
                    help_text = option.help_text,
                    hold_callback = option.name_text_hold_callback and function()
                        option.name_text_hold_callback(config.configurable, option, config.options.prefix, reader.document)
                    end or nil,
                    sub_item_table_func = function()
                        local children = choices(option)
                        if companion then
                            for _k, child in ipairs(choices(companion)) do children[#children + 1] = child end
                        end
                        return children
                    end,
                })
            end
        end
    end
    -- The controller only borrows KOReader's handlers; it owns no painted widget.
    controller.updateConfigPanel = controller.update
    controller.closeDialog = function() page:backToUpperMenu(true) end
    controller.onClose = controller.closeDialog
    return items
end

return M
