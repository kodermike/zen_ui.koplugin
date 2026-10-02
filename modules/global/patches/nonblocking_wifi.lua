local function apply_nonblocking_wifi()
    local Device = require("device")
    if not ((Device.isKobo and Device:isKobo()) or (Device.isKindle and Device:isKindle())) then return end
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr._zen_nonblocking_wifi then return end

    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    local ffi = require("ffi")
    local ffiutil = require("ffi/util")
    local buffer = require("string.buffer")
    local logger = require("common/zen_logger").new("nonblocking_wifi")
    local active
    local connection_failure
    local wifi_notice
    local queued = {}
    local start_next
    local reported_changing = false

    NetworkMgr.isWifiChanging = function(self)
        if self.pending_connection or self.pending_connectivity_check then return true end
        if active and not active.cancelled and not active.queued_only then return true end
        for _i, job in ipairs(queued) do
            if not job.queued_only then return true end
        end
        return false
    end

    local function notify_state()
        local changing = NetworkMgr:isWifiChanging()
        if changing == reported_changing then return end
        reported_changing = changing
        UIManager:broadcastEvent(Event:new("NetworkStateChanged"))
    end

    local function cancel()
        queued = {}
        connection_failure = nil
        if active and not active.cancelled then
            active.cancelled = true
            if not ffiutil.isSubProcessDone(active.pid) then
                ffi.C.kill(-active.pid, 9)
                ffi.C.kill(active.pid, 9) -- Also cover cancellation before the process group exists.
            end
        end
    end

    start_next = function()
        if active or #queued == 0 then return end
        local job = table.remove(queued, 1)
        local pid, read_fd = ffiutil.runInSubProcess(function(_pid, write_fd)
            ffi.C.fcntl(write_fd, 2, ffi.cast("int", 1)) -- FD_CLOEXEC: keep Wi-Fi daemons out of the pipe.
            if job.method_name then NetworkMgr[job.method_name] = job.method end
            NetworkMgr.wifi_toggle_long_press = job.long_press
            local completed, show_menu = false, false
            local no_known_networks
            UIManager.show = function(_self, widget)
                if widget.network_list then
                    show_menu = true
                    if Device.isKobo and Device:isKobo() then
                        local profiles = NetworkMgr:getConfiguredNetworks()
                        no_known_networks = profiles and #profiles == 0
                            and next(NetworkMgr:getAllSavedNetworks().data) == nil
                    end
                end
            end
            UIManager.close = function() end
            UIManager.forceRePaint = function() end
            UIManager.scheduleIn = function(_self, delay, callback, ...)
                ffiutil.usleep(delay * 1000000)
                callback(...)
            end
            package.loaded["ui/widget/networksetting"] = { new = function(_self, options) return options end }
            local ok, status = pcall(function()
                if job.action then return job.action() end
                return job.method(NetworkMgr, function() completed = true end, job.interactive)
            end)
            if not ok then logger.warn("Wi-Fi worker failed", "error_type=", type(status)) end
            ffiutil.writeToFD(write_fd, buffer.encode({
                completed = completed,
                failed = not ok or status == false,
                show_menu = show_menu,
                no_known_networks = no_known_networks,
                lease_ssid = NetworkMgr.lease_ssid,
                value = job.action and ok and status or nil,
                error = not ok and tostring(status) or nil,
            }), true)
        end, true)
        if not pid then
            logger.warn("Could not start Wi-Fi worker", "error_type=", type(read_fd))
            if job.action then
                job.complete_callback(nil, tostring(read_fd))
            elseif job.enabling then
                NetworkMgr:_abortWifiConnection(job.on_failure)
            elseif job.on_failure then
                job.on_failure()
            end
            start_next()
            notify_state()
            return
        end
        job.pid = pid
        active = job
        UIManager:preventStandby()
        notify_state()
        local polls = 0
        local function poll()
            polls = polls + 1
            if not ffiutil.isSubProcessDone(pid) then
                if polls == 480 then -- ponytail: 120 s total; split deadlines if many saved networks exceed it.
                    job.timed_out = true
                    ffi.C.kill(-pid, 9)
                    ffi.C.kill(pid, 9)
                end
                UIManager:scheduleIn(0.25, poll)
                return
            end
            local result
            local size = ffiutil.getNonBlockingReadSize(read_fd)
            if size and size > 0 then
                local data = ffi.new("char[?]", size)
                local count = tonumber(ffi.C.read(read_fd, data, size))
                if count and count > 0 then
                    local ok, decoded = pcall(buffer.decode, ffi.string(data, count))
                    if ok then result = decoded end
                end
            end
            ffi.C.close(read_fd)
            active = nil
            UIManager:allowStandby()
            if not job.cancelled then
                NetworkMgr.wifi_toggle_long_press = nil
                NetworkMgr.nw_settings = nil -- Reload credentials saved by the worker.
                if job.action then
                    local value, err
                    if result and not job.timed_out then value, err = result.value, result.error end
                    job.complete_callback(value, err)
                elseif result and not result.failed and not job.timed_out
                        and (not job.enabling or result.completed or result.show_menu) then
                    if job.enabling then NetworkMgr.lease_ssid = result.lease_ssid end
                    if result.completed and job.complete_callback then
                        if job.enabling and not result.show_menu then connection_failure = job.on_failure end
                        job.complete_callback()
                    end
                    if result.show_menu and job.on_failure then
                        if not result.completed then NetworkMgr:unscheduleConnectivityCheck() end
                        NetworkMgr.pending_connection = false
                        job.on_failure(result.no_known_networks)
                    end
                elseif job.enabling then
                    logger.warn("Background Wi-Fi connection failed")
                    NetworkMgr:_abortWifiConnection(job.on_failure)
                else
                    logger.warn("Background Wi-Fi shutdown failed")
                    if job.on_failure then job.on_failure() end
                end
            end
            start_next()
            notify_state()
        end
        UIManager:scheduleIn(0.25, poll)
    end

    local function background(self, method_name, action, interactive, on_failure, after)
        local method = self[method_name]
        self[method_name] = function(_self, complete_callback)
            queued[#queued + 1] = {
                method = method,
                method_name = method_name,
                enabling = method_name == "turnOnWifi",
                complete_callback = complete_callback or after,
                interactive = interactive,
                long_press = self.wifi_toggle_long_press,
                on_failure = on_failure,
            }
            start_next()
        end
        local ok, result = pcall(action)
        self[method_name] = method
        if not ok then error(result) end
        return result
    end

    NetworkMgr._zen_nonblocking_wifi = true
    NetworkMgr.showWifiNotice = function(_self, text)
        if wifi_notice then UIManager:close(wifi_notice) end
        wifi_notice = require("ui/widget/infomessage"):new{
            text = text,
            toast = true,
            timeout = 2,
            dismissable = true,
            dismiss_callback = function() wifi_notice = nil end,
        }
        UIManager:show(wifi_notice)
    end
    NetworkMgr.showWifiStarting = function(self)
        self:showWifiNotice(require("gettext")("Turning on Wi-Fi…"))
    end
    NetworkMgr.runWifiAsync = function(self, action, complete_callback, queued_only)
        if not queued_only then
            cancel()
            self:unscheduleConnectivityCheck()
            self.pending_connection = true
        end
        queued[#queued + 1] = {
            action = action,
            queued_only = queued_only,
            complete_callback = function(...)
                if not queued_only then self.pending_connection = false end
                complete_callback(...)
            end,
        }
        start_next()
    end
    local disableWifi = NetworkMgr.disableWifi
    NetworkMgr.disableWifi = function(self, ...)
        cancel()
        return disableWifi(self, ...)
    end
    local abortWifiConnection = NetworkMgr._abortWifiConnection
    NetworkMgr._abortWifiConnection = function(self, after)
        after = after or connection_failure
        cancel()
        return background(self, "turnOffWifi", function()
            return abortWifiConnection(self)
        end, false, after, after)
    end
    local connectivityCheck = NetworkMgr.connectivityCheck
    NetworkMgr.connectivityCheck = function(self, ...)
        local result = connectivityCheck(self, ...)
        if not self.pending_connection then connection_failure = nil end
        if not self.pending_connection then notify_state() end
        return result
    end
    NetworkMgr.toggleWifiOn = function(self, complete_callback, long_press, interactive, on_failure)
        if not self.pending_connection and interactive ~= false then self:showWifiStarting() end
        self.wifi_toggle_long_press = long_press
        local chooser_callback = complete_callback
        on_failure = interactive and (on_failure or function()
            require("modules/menu/network_switcher").open(chooser_callback)
        end) or nil
        if interactive ~= false then
            local after_connected, after_failed = complete_callback, on_failure
            complete_callback = function()
                if after_connected then after_connected() end
                local ssid = self.lease_ssid or (self:getCurrentNetwork() or {}).ssid
                self:showWifiNotice(ssid and ssid ~= ""
                    and ffiutil.template(require("gettext")("Connected to %1."):gsub("%.$", ""):gsub("。$", ""), ssid)
                    or require("gettext")("Connected."):gsub("%.$", ""):gsub("。$", ""))
            end
            on_failure = function(no_known_networks)
                if after_failed then after_failed() end
                if not no_known_networks then
                    self:showWifiNotice(require("gettext")("Error connecting to the network"))
                end
            end
        end
        return background(self, "turnOnWifi", function()
            return self:enableWifi(complete_callback, false)
        end, interactive, on_failure)
    end
    NetworkMgr.toggleWifiOff = function(self, complete_callback, interactive)
        return background(self, "turnOffWifi", function()
            return self:disableWifi(complete_callback, interactive)
        end)
    end
    if Device.isKobo and Device:isKobo() then
        -- The shell restore ignores networks saved only in KOReader.
        NetworkMgr.restoreWifiAsync = function(self)
            return background(self, "turnOnWifi", function()
                return self:requestToTurnOnWifi(nil, false)
            end, false)
        end
    end
    local broadcastEvent = UIManager.broadcastEvent
    UIManager.broadcastEvent = function(self, event, ...)
        if event and event.handler == "onSuspend" and active then
            NetworkMgr:disableWifi(nil, false)
        end
        return broadcastEvent(self, event, ...)
    end
end

return apply_nonblocking_wifi
