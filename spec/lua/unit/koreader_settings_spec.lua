describe("KOReader settings bridge", function()
    local Settings, UI, owner, page, classes, saved
    local names = {
        "gettext", "ui/uimanager", "modules/menu/app_launcher/native_menu",
        "modules/settings/koreader_settings", "modules/settings/koreader_layout",
        "ui/widget/spinwidget", "ui/widget/doublespinwidget", "ui/widget/radiobuttonwidget",
        "ui/widget/radiobuttontable", "ui/widget/buttontable", "ui/widget/menu",
        "ui/widget/inputdialog", "ui/widget/confirmbox", "ui/widget/multiconfirmbox",
        "common/ui/zen_modal_close", "ui/widget/configdialog", "util",
    }
    before_each(function()
        saved, classes = {}, {}
        for _i, name in ipairs(names) do saved[name] = { value = package.loaded[name] } end
        ZenSpec.replace("gettext", function(text) return text end)
        owner = {}
        page = { item_table = {}, item_table_stack = {}, dimen = {} }
        function page:closeMenu() self._closed = true end
        function page:_openSubmenu(item, items)
            table.insert(self.item_table_stack, self.item_table)
            self.item_table = items
            self.title = item.sub_title or item.text
        end
        function page:backToUpperMenu()
            local old = self.item_table
            self.item_table = table.remove(self.item_table_stack)
            if old._zen_on_leave then old._zen_on_leave() end
        end
        function page:updateItems()
            if self.item_table._zen_refresh then self.item_table = self.item_table._zen_refresh() end
        end
        UI = {
            shown = {}, closed = {}, tasks = {},
            show = function(self, widget) self.shown[#self.shown + 1] = widget end,
            close = function(self, widget) self.closed[#self.closed + 1] = widget end,
            setDirty = function() end,
            schedule = function(self, when, action) self.tasks[#self.tasks + 1] = { when = when, action = action } end,
            unschedule = function(self, action)
                local removed = false
                for index = #self.tasks, 1, -1 do
                    if self.tasks[index].action == action then table.remove(self.tasks, index); removed = true end
                end
                return removed
            end,
        }
        ZenSpec.replace("ui/uimanager", UI)
        ZenSpec.replace("modules/menu/app_launcher/native_menu", {
            isSettingsOwner = function(candidate) return candidate == owner end,
        })
        for _i, name in ipairs({ "spinwidget", "doublespinwidget", "radiobuttonwidget", "radiobuttontable",
            "buttontable", "menu", "inputdialog", "confirmbox", "multiconfirmbox" }) do
            classes[name] = {}
            ZenSpec.replace("ui/widget/" .. name, classes[name])
        end
        ZenSpec.replace("common/ui/zen_modal_close", { installDialog = function() end })
        ZenSpec.unload("modules/settings/koreader_settings")
        Settings = require("modules/settings/koreader_settings")
        Settings.install()
    end)
    after_each(function()
        for name, original in pairs(saved) do package.loaded[name] = original.value end
    end)

    local function invoke(callback, setting)
        return Settings.invoke(page, {
            text = "Native setting", _zen_native_owner = owner, _zen_native_setting = setting,
        }, callback)
    end

    it("copies plugin descendants, normalizes live controls and preserves dynamic refresh", function()
        local source = {
            { id = "plugin", text = "Plugin", checked = false, enabled = false, enabled_func = function() return true end },
            { text = "Dynamic", sub_item_table_func = function() return {{ text = "Nested" }} end },
        }
        source.needs_refresh = true
        source.refresh_func = function() source[1].text = "Changed" end
        local copy = Settings.copyItems(source, owner, true)
        assert.are_not.equal(source, copy)
        assert.are_not.equal(source[1], copy[1])
        assert.is_nil(copy[1].enabled)
        assert.is_false(copy[1].checked_func())
        source[1].checked = true
        assert.is_true(copy[1].checked_func())
        assert.are.equal("Nested", copy[2].sub_item_table_func(page)[1].text)
        assert.are.equal("Changed", copy.refresh_func()[1].text)
        assert.is_nil(source[1]._zen_native_owner)
        assert.is_nil(source[2]._zen_settings_row)
    end)

    it("propagates callback errors without leaving conversion active", function()
        assert.has_error(function() invoke(function() error("failed") end) end, "failed")
        local widget = setmetatable({}, classes.spinwidget)
        UI:show(widget)
        assert.are.equal(widget, UI.shown[1])
    end)

    it("captures deferred selector callbacks and preserves cancellation identity", function()
        local calls = 0
        local action = function() calls = calls + 1 end
        assert.is_true(invoke(function() UI:schedule(1, action) end))
        assert.is_true(UI:unschedule(action))
        assert.are.equal(0, #UI.tasks)
        invoke(function() UI:schedule(1, action) end)
        UI.tasks[1].action()
        assert.are.equal(1, calls)
        invoke(function() UI:schedule(1, action) end)
        owner = {}
        UI.tasks[#UI.tasks].action()
        assert.are.equal(1, calls)
    end)

    it("uses the original radio selection and footer actions", function()
        local first, second = { text = "First" }, { text = "Second", enabled = false }
        local radio = setmetatable({ radio_buttons_layout = {{ first, second }}, checked_button = first }, classes.radiobuttontable)
        local applied
        first.callback = function() radio.checked_button = first end
        second.callback = function() radio.checked_button = second end
        local widget = setmetatable({ radio }, classes.radiobuttonwidget)
        widget[2] = setmetatable({ buttons = {{ {
            text = "Apply", callback = function() applied = radio.checked_button end,
        } }} }, classes.buttontable)
        invoke(function() UI:show(widget) end, true)
        assert.is_true(page.item_table[1].radio)
        assert.is_true(page.item_table[1].checked_func())
        assert.is_false(page.item_table[2].enabled)
        invoke(page.item_table[2].callback)
        assert.is_true(page.item_table[2].checked_func())
        invoke(page.item_table[3].callback)
        assert.are.equal(second, applied)
    end)

    it("keeps tool menus native and discards stale routes", function()
        local widget = setmetatable({}, classes.menu)
        invoke(function() UI:show(widget) end, false)
        assert.are.equal(widget, UI.shown[1])
        local called = false
        owner = {}
        Settings.invoke(page, { _zen_native_owner = {} }, function() called = true end)
        assert.is_true(page._closed)
        assert.is_false(called)
    end)

    it("delegates numeric steps, input, Apply and cleanup to the original picker", function()
        local input = setmetatable({}, classes.inputdialog)
        local step, applied, closed
        local picker = {
            formatted_value = "1.5", value_step = 0.5, value_hold_step = 2.5,
            text_value = { callback = function() UI:show(input) end },
            changeValue = function(_self, delta) step = delta; return 1.5 + delta end,
            update = function(self) self.formatted_value = tostring(self.value); page:updateItems() end,
        }
        local widget = setmetatable({ value_widget = picker }, classes.spinwidget)
        function widget:onClose() UI:close(self); closed = (closed or 0) + 1 end
        function widget:free() self.freed = true end
        widget[1] = setmetatable({ buttons = {{ {
            text = "Apply", callback = function() applied = picker.value; widget:onClose() end,
        } }} }, classes.buttontable)
        invoke(function() UI:show(widget) end, true)
        assert.are.equal(0, #UI.shown)
        assert.are.equal("Value: 1.5", page.item_table[1].text)
        invoke(page.item_table[3].callback)
        assert.are.equal(0.5, step)
        invoke(page.item_table[2].hold_callback)
        assert.are.equal(-2.5, step)
        invoke(page.item_table[1].callback)
        assert.are.equal(input, UI.shown[1])
        local apply = page.item_table[4].callback
        page:_openSubmenu({ text = "Choices" }, {{ text = "Nested" }})
        invoke(apply)
        assert.are.equal(-1, applied)
        assert.are.equal(1, closed)
        assert.is_true(widget.freed)
        assert.are.equal(0, #page.item_table_stack)
    end)

    it("keeps paired picker Apply signatures and cancel cleanup", function()
        local widget = setmetatable({}, classes.doublespinwidget)
        local applied
        widget.left_text, widget.right_text = "Left", "Right"
        for _i, key in ipairs({ "left_widget", "right_widget" }) do
            widget[key] = { formatted_value = "3", value_step = 1, value_hold_step = 4, text_value = {}, update = function() end }
        end
        function widget:onClose() UI:close(self) end
        widget[1] = setmetatable({ buttons = {{ {
            text = "Apply", callback = function() applied = { 3, 3 } end,
        } }} }, classes.buttontable)
        invoke(function() UI:show(widget) end, true)
        assert.are.equal("Left: 3", page.item_table[1].text)
        assert.are.equal("Right: 3", page.item_table[4].text)
        invoke(page.item_table[7].callback)
        assert.are.same({ 3, 3 }, applied)
        page:backToUpperMenu()
        assert.are.equal(widget, UI.closed[1])
    end)

    it("uses reader configuration handlers without applying values while building", function()
        local calls = {}
        ZenSpec.replace("util", { tableEquals = function(a, b) return a == b end })
        ZenSpec.replace("ui/widget/configdialog", {
            onConfigChoose = function(_self, ...) calls.choose = { ... } end,
            onMakeDefault = function(_self, ...) calls.default = { ... } end,
        })
        local config = {
            configurable = { mode = 0 },
            options = { prefix = "kopt", { options = {
                { name = "mode", name_text = "Mode", values = { 0, 1 }, toggle = { "Page", "Continuous" },
                    args = { false, true }, event = "SetScrollMode", default_value = 1 },
                { name = "hidden", name_text = "Hidden", show_func = function(state) return state.mode == 1 end },
                { name = "font_size", values = { 1, 2 }, args = { 1, 2 }, event = "SetFont" },
                { name = "font_fine_tune", name_text = "Font Size", values = { -0.05, 0.05 },
                    args = { -0.05, 0.05 }, toggle = { "Decrease", "Increase" }, event = "FineTuneFont" },
            } } },
        }
        owner.ui = { config = config, document = {} }
        local items = require("modules/settings/koreader_layout").build(owner, page)
        assert.are.same({}, calls)
        assert.is_false(items[2].show_func())
        local choices = items[1].sub_item_table_func()
        assert.is_true(choices[1].checked_func())
        assert.are.equal("Continuous ★", choices[2].text_func())
        choices[2].callback()
        assert.are.equal("SetScrollMode", calls.choose[3])
        assert.are.same({ false, true }, calls.choose[4])
        assert.are.equal(2, calls.choose[5])
        choices[2].hold_callback()
        assert.are.equal("mode", calls.default[1])
        config.configurable.mode = 1
        assert.is_true(items[2].show_func())
        assert.are.equal(3, #items)
        assert.are.equal("Font Size", items[3].text_func())
        local fonts = items[3].sub_item_table_func()
        assert.is_true(fonts[1].radio)
        assert.is_false(fonts[3].radio)
        fonts[4].callback()
        assert.are.equal("FineTuneFont", calls.choose[3])
    end)
end)
