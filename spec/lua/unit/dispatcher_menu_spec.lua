local DispatcherMenu = require("common/dispatcher_menu")

describe("dispatcher menu persistence", function()
    it("keeps unavailable actions visible and updates their enabled state", function()
        local settingsList = {
            available = {},
            unavailable = { condition = false },
            reader = { reader = true },
        }
        local in_reader = false
        local dispatcher = {
            init = function() end,
            registerAction = function(_self, key) return settingsList[key] end,
            isActionEnabled = function(_self, spec)
                return spec.condition ~= false and (not spec.reader or in_reader)
            end,
            addSubMenu = function(_self, _caller, items, location, settings)
                local actions = {}
                for k, spec in pairs(settingsList) do
                    if spec.condition ~= false then
                        actions[#actions + 1] = {
                            text = k,
                            checked_func = function() return location[settings][k] end,
                        }
                    end
                end
                items[1] = { text = "Actions", sub_item_table = actions }
            end,
        }
        local items = {}
        DispatcherMenu.addSubMenu(dispatcher, {}, items, { action = {} }, "action")

        local actions = {}
        for _i, item in ipairs(items[1].sub_item_table) do actions[item.text] = item end
        assert.are.equal(3, #items[1].sub_item_table)
        assert.is_false(settingsList.unavailable.condition)
        assert.is_true(actions.available.enabled_func())
        assert.is_false(actions.unavailable.enabled_func())
        assert.is_false(actions.reader.enabled_func())
        in_reader = true
        assert.is_true(actions.reader.enabled_func())

        dispatcher.addSubMenu = function() error("menu failed") end
        assert.has_error(function()
            DispatcherMenu.addSubMenu(dispatcher, {}, {}, { action = {} }, "action")
        end, "menu failed")
        assert.is_false(settingsList.unavailable.condition)
    end)

    local function menu()
        return {
            refreshes = 0,
            updateItems = function(self)
                self.refreshes = self.refreshes + 1
            end,
        }
    end

    it("saves a synchronous action toggle immediately", function()
        local caller = {}
        local saves = 0
        local items = {{
            callback = function()
                caller.updated = true
            end,
        }}
        DispatcherMenu.wrap(items, caller, function() saves = saves + 1 end)

        items[1].callback(menu())

        assert.are.equal(1, saves)
        assert.is_false(caller.updated)
    end)

    it("saves an asynchronous dispatcher update when it refreshes", function()
        local caller = {}
        local saves = 0
        local pending
        local host = menu()
        local items = {{
            callback = function(touch_menu)
                pending = function()
                    caller.updated = true
                    touch_menu:updateItems()
                end
            end,
        }}
        DispatcherMenu.wrap(items, caller, function() saves = saves + 1 end)

        items[1].callback(host)
        assert.are.equal(0, saves)
        pending()

        assert.are.equal(1, host.refreshes)
        assert.are.equal(1, saves)
        assert.is_false(caller.updated)
    end)

    it("flushes a pending selection on Back or close", function()
        local caller = {}
        local saves = 0
        local host = menu()
        local items = {{ callback = function() end }}
        DispatcherMenu.wrap(items, caller, function() saves = saves + 1 end)
        items[1].callback(host)
        caller.updated = true

        assert.is_true(DispatcherMenu.flush(host))
        assert.are.equal(1, saves)
        assert.is_false(caller.updated)
    end)

    it("wraps dynamically generated action choices", function()
        local caller = {}
        local saves = 0
        local items = {{
            sub_item_table_func = function()
                return {{ callback = function() caller.updated = true end }}
            end,
        }}
        DispatcherMenu.wrap(items, caller, function() saves = saves + 1 end)

        local choices = items[1].sub_item_table_func()
        choices[1].callback(menu())

        assert.are.equal(1, saves)
    end)
end)
