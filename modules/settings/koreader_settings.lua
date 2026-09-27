local UIManager = require("ui/uimanager")
local _ = require("gettext")

local M = {}
local context
local installed
local views = setmetatable({}, { __mode = "k" })

local function current(ctx)
    return ctx and not ctx.page._closed and not ctx.tool
        and require("modules/menu/app_launcher/native_menu").isSettingsOwner(ctx.owner)
end

function M.invoke(page, item, callback, ...)
    local ctx = {
        page = page, item = item, owner = item._zen_native_owner,
        setting = item._zen_native_setting,
    }
    if not current(ctx) then page:closeMenu(); return false end
    local previous = context
    context = ctx
    local ok, err = pcall(callback, ...)
    context = previous
    if not ok then error(err, 0) end
    if not require("modules/menu/app_launcher/native_menu").isSettingsOwner(ctx.owner) then
        page:closeMenu()
    end
    return ctx.handled and not ctx.tool
end

function M.copyItems(source, owner, setting, copies)
    copies = copies or {}
    if copies[source] then return copies[source] end
    local items = { _zen_native_owner = owner }
    copies[source] = items
    for key, value in pairs(source) do
        if type(key) ~= "number" then items[key] = value end
    end
    items._zen_refresh = function() return M.copyItems(source, owner, setting) end
    if type(source.refresh_func) == "function" then
        items.refresh_func = function()
            return M.copyItems(source.refresh_func() or source, owner, setting)
        end
    end
    for index, original in ipairs(source) do
        local item = {}
        for key, value in pairs(original) do item[key] = value end
        item._zen_native_owner = owner
        item._zen_native_setting = setting or original.id == "search_settings"
            or original.id == "advanced_settings"
        if original.enabled_func then item.enabled = nil end
        if original.checked_func or original.checked ~= nil then
            item.checked_func = function()
                if original.checked_func then return not not original.checked_func() end
                return not not original.checked
            end
        end
        if type(original.sub_item_table_func) == "function" then
            item.sub_item_table = nil
            item.sub_item_table_func = function(page)
                local children = original.sub_item_table_func(page)
                if type(children) == "table" then
                    return M.copyItems(children, owner, item._zen_native_setting)
                end
            end
        elseif type(original.sub_item_table) == "table" then
            item.sub_item_table = M.copyItems(original.sub_item_table, owner, item._zen_native_setting, copies)
        elseif #original > 0 then
            item.sub_item_table = M.copyItems(original, owner, item._zen_native_setting, copies)
        end
        if original.id == "document_settings" and owner.ui and owner.ui.config then
            local children = item.sub_item_table or {}
            table.insert(children, 1, {
                text = _("Layout"),
                _zen_native_owner = owner,
                sub_item_table_func = function(page)
                    return require("modules/settings/koreader_layout").build(owner, page)
                end,
            })
            children._zen_refresh = function()
                return M.copyItems({ original }, owner, setting)[1].sub_item_table
            end
            item.sub_item_table = children
        end
        items[index] = item
    end
    return items
end

local function find_widget(widget, class, seen)
    if type(widget) ~= "table" then return end
    if getmetatable(widget) == class then return widget end
    seen = seen or {}
    if seen[widget] then return end
    seen[widget] = true
    for _i, child in ipairs(widget) do
        local found = find_widget(child, class, seen)
        if found then return found end
    end
end

local function native_item(ctx, item)
    item._zen_native_owner = ctx.owner
    item._zen_native_setting = true
    item.keep_menu_open = true
    return item
end

local function selector_items(widget, kind, ctx)
    local items = { _zen_native_owner = ctx.owner }
    if kind == "menu" then
        items = M.copyItems(widget.item_table, ctx.owner, true)
        for index, item in ipairs(items) do
            local original = widget.item_table[index]
            if not item.sub_item_table and not item.sub_item_table_func then
                item.callback_func = nil
                item.callback = function() widget:onMenuSelect(original) end
                item.hold_callback_func = nil
                item.hold_callback = function() widget:onMenuHold(original) end
                item.keep_menu_open = true
            end
        end
        items._zen_refresh = nil
        return items
    elseif kind == "radio" then
        local radio = find_widget(widget, require("ui/widget/radiobuttontable"))
        for _i, row in ipairs(radio.radio_buttons_layout) do
            for _j, button in ipairs(row) do
                items[#items + 1] = native_item(ctx, {
                    text = button.text, radio = true, enabled = button.enabled,
                    checked_func = function() return radio.checked_button == button end,
                    callback = button.callback,
                    hold_callback = button.hold_callback,
                })
            end
        end
    else
        local function add_picker(picker, title)
            items[#items + 1] = native_item(ctx, {
                text = title .. ": " .. tostring(picker.formatted_value) .. (widget.unit or ""),
                sub_item_table_func = picker.value_table and function()
                    local choices = {}
                    for index, value in ipairs(picker.value_table) do
                        choices[#choices + 1] = native_item(ctx, {
                            text = tostring(value), radio = true,
                            checked_func = function() return picker.value_index == index end,
                            callback = function()
                                picker.value_index, picker.value = index, value
                                picker:update()
                            end,
                        })
                    end
                    return choices
                end or nil,
                callback = picker.text_value.callback,
            })
            for _i, direction in ipairs({ -1, 1 }) do
                items[#items + 1] = native_item(ctx, {
                    text = direction < 0 and _("Decrease") or _("Increase"),
                    callback = function()
                        picker.value = picker:changeValue(direction * picker.value_step)
                        picker:update()
                    end,
                    hold_callback = function()
                        picker.value = picker:changeValue(direction * picker.value_hold_step)
                        picker:update()
                    end,
                })
            end
        end
        if kind == "double" then
            add_picker(widget.left_widget, widget.left_text)
            add_picker(widget.right_widget, widget.right_text)
        else
            add_picker(widget.value_widget, _("Value"))
        end
    end
    local footer = find_widget(widget, require("ui/widget/buttontable"))
    for _i, row in ipairs(footer.buttons) do
        for _j, button in ipairs(row) do
            items[#items + 1] = native_item(ctx, {
                text = button.text, enabled = button.enabled,
                callback = button.callback,
            })
        end
    end
    return items
end

function M.install()
    if installed then return end
    installed = true
    local classes = {
        spin = require("ui/widget/spinwidget"),
        double = require("ui/widget/doublespinwidget"),
        radio = require("ui/widget/radiobuttonwidget"),
        menu = require("ui/widget/menu"),
    }
    local InputDialog = require("ui/widget/inputdialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    local MultiConfirmBox = require("ui/widget/multiconfirmbox")
    local original_show, original_close = UIManager.show, UIManager.close
    local original_dirty = UIManager.setDirty

    UIManager.show = function(self, widget, ...)
        local ctx = context
        if current(ctx) then
            local input = getmetatable(widget) == InputDialog
            local confirm = getmetatable(widget) == ConfirmBox or getmetatable(widget) == MultiConfirmBox
            if input or confirm then
                ctx.handled = true
                if input then
                    require("common/ui/zen_modal_close").installDialog(widget, function()
                        widget:onClose()
                    end)
                end
                local function wrap(callback)
                    if type(callback) ~= "function" then return callback end
                    return function(...)
                        if not require("modules/menu/app_launcher/native_menu").isSettingsOwner(ctx.owner) then
                            UIManager:close(widget)
                            return
                        end
                        if current(ctx) then
                            local result = M.invoke(ctx.page, ctx.item, callback, ...)
                            if current(ctx) then ctx.page:updateItems() end
                            return result
                        end
                        return callback(...)
                    end
                end
                for _i, key in ipairs({ "ok_callback", "choice1_callback", "choice2_callback", "enter_callback" }) do
                    widget[key] = wrap(widget[key])
                end
                for _i, row in ipairs(widget.buttons or {}) do
                    for _j, button in ipairs(row) do button.callback = wrap(button.callback) end
                end
                local seen = {}
                local function wrap_buttons(node)
                    if type(node) ~= "table" or seen[node] then return end
                    seen[node] = true
                    node.callback = wrap(node.callback)
                    node.hold_callback = wrap(node.hold_callback)
                    for _i, child in ipairs(node) do wrap_buttons(child) end
                end
                wrap_buttons(widget)
            else
                for kind, class in pairs(classes) do
                    local source = widget
                    if kind == "menu" then source = ctx.setting and find_widget(widget, class) or nil end
                    if source and getmetatable(source) == class then
                        local view = { page = ctx.page, owner = ctx.owner, source = source, widget = widget }
                        local function leave()
                            if view.closed then return end
                            view.closed = true
                            views[widget], views[source] = nil, nil
                            if kind == "menu" then source:onCloseAllMenus() else source:onClose() end
                            if type(widget.free) == "function" then widget:free() end
                        end
                        local function build()
                            local items = selector_items(source, kind, ctx)
                            items._zen_refresh = build
                            items._zen_on_leave = leave
                            items._zen_native_view = view
                            return items
                        end
                        view.items = build()
                        views[widget], views[source] = view, view
                        local opener = {}
                        for key, value in pairs(ctx.item) do opener[key] = value end
                        opener.sub_title = source.title_text or source.title
                        ctx.page:_openSubmenu(opener, view.items)
                        ctx.handled = true
                        return
                    end
                end
                ctx.tool = true
            end
        end
        return original_show(self, widget, ...)
    end

    UIManager.close = function(self, widget, ...)
        local view = views[widget]
        if view and not view.closed then
            view.closed = true
            views[view.widget], views[view.source] = nil, nil
            local result = original_close(self, widget, ...)
            for _i, items in ipairs(view.page.item_table_stack) do
                if items._zen_native_view == view then
                    while view.page.item_table._zen_native_view ~= view do
                        view.page:backToUpperMenu(true)
                    end
                    break
                end
            end
            if view.page.item_table._zen_native_view == view then
                view.page:backToUpperMenu(true)
            end
            if type(view.widget.free) == "function" then view.widget:free() end
            return result
        end
        return original_close(self, widget, ...)
    end
    UIManager.setDirty = function(self, widget, ...)
        local view = views[widget]
        local page = view and view.page or type(widget) == "table" and widget._zen_settings_page
        if page then
            if page._closed then return end
            return original_dirty(self, page, "ui")
        end
        return original_dirty(self, widget, ...)
    end

    local original_schedule, original_unschedule = UIManager.schedule, UIManager.unschedule
    local scheduled = {}
    UIManager.schedule = function(self, when, action, ...)
        local ctx = context
        if not current(ctx) then return original_schedule(self, when, action, ...) end
        ctx.handled = true
        local wrappers = scheduled[action] or {}
        scheduled[action] = wrappers
        local wrapper
        wrapper = function(...)
            wrappers[wrapper] = nil
            if not next(wrappers) then scheduled[action] = nil end
            if not require("modules/menu/app_launcher/native_menu").isSettingsOwner(ctx.owner) then return end
            if current(ctx) then return M.invoke(ctx.page, ctx.item, action, ...) end
            return action(...)
        end
        wrappers[wrapper] = true
        return original_schedule(self, when, wrapper, ...)
    end
    UIManager.unschedule = function(self, action)
        local removed = original_unschedule(self, action)
        for wrapper in pairs(scheduled[action] or {}) do
            removed = original_unschedule(self, wrapper) or removed
        end
        scheduled[action] = nil
        return removed
    end
end

return M
