local M = {}

function M.isSupported(Device)
    return Device.isKobo and Device:isKobo()
end

function M.new(NetworkMgr, logger)
    local ffiutil = require("ffi/util")
    local _ = require("gettext")
    local adapter = { id = "kobo" }
    local max_auth_failures = 4 -- Match KOReader's password authentication limit.

    local function auth_failure(event)
        local msg = event.msg or ""
        local wrong_key = msg:find("reason=WRONG_KEY", 1, true) ~= nil
            or msg:find("pre-shared key may be incorrect", 1, true) ~= nil
        return wrong_key or event:isAuthFailed()
            and not msg:find("locally_generated=1", 1, true), wrong_key
    end

    local function finish_auth(wcli, connected)
        if not connected then
            local reply, err = wcli:sendCtrlCmd("DISCONNECT")
            logger.dbg("Kobo authentication stopped", "accepted=",
                reply ~= nil and reply:sub(1, 2) == "OK", "error=", err)
        end
        local reply, err = wcli:sendCtrlCmd("ENABLE_NETWORK all")
        if not reply or reply:sub(1, 2) ~= "OK" then
            logger.warn("could not re-enable Kobo Wi-Fi profiles", err or reply)
        end
    end

    function adapter.profileId(ssid)
        if type(NetworkMgr.getConfiguredNetworks) ~= "function" then return end
        local profiles = NetworkMgr:getConfiguredNetworks()
        for _i, profile in ipairs(profiles or {}) do
            if profile.ssid == ssid and profile.id then return profile.id end
        end
    end

    local function use_profile(id, reconnect)
        local WpaClient = require("lj-wpaclient/wpaclient")
        local wcli, err = WpaClient.new(NetworkMgr.wpa_supplicant.ctrl_interface)
        if not wcli then return false, err end
        if reconnect then
            local attached
            attached, err = wcli:attach()
            if not attached then
                wcli:close()
                return false, err
            end
        end
        local reply
        reply, err = wcli:sendCtrlCmd(reconnect and "SELECT_NETWORK " .. tostring(id) or "DISCONNECT")
        local connected = false
        local failures = 0
        local rejected = false
        local reason = _("Timed out")
        if reconnect and reply and reply:sub(1, 2) == "OK" then
            for _i = 1, 120 do
                local current = wcli:getConnectedNetwork()
                if current and tostring(current.id) == tostring(id) then
                    connected = true
                    break
                end
                for _j, event in ipairs(wcli:readAllEvents() or {}) do
                    local failed, wrong_key = auth_failure(event)
                    if failed then
                        failures = failures + 1
                        logger.dbg("Kobo authentication failure", "profile_id=", id,
                            "failures=", failures, "limit=", max_auth_failures,
                            "wrong_key=", wrong_key)
                        if wrong_key or failures >= max_auth_failures then
                            rejected = true
                            reason = _("Failed to authenticate")
                            break
                        end
                    end
                end
                if rejected then break end
                ffiutil.usleep(250 * 1000)
            end
        end
        if reconnect then finish_auth(wcli, connected) end
        wcli:close()
        if connected then return true, _("Authenticated") end
        if reply and reply:sub(1, 2) == "OK" then
            if reconnect then return false, reason end
            return true
        end
        return false, err or reply
    end

    function adapter.disconnect(network, preserve)
        local id = preserve and (network.wpa_supplicant_id or adapter.profileId(network.ssid))
        if not id then return NetworkMgr:disconnectNetwork(network) end
        local disconnected, err = use_profile(id, false)
        logger.dbg("Kobo configured profile disconnected", "ssid=", network.ssid,
            "profile_id=", id, "success=", disconnected)
        return disconnected, err
    end

    function adapter.forgetNetwork(network)
        if type(NetworkMgr.getConfiguredNetworks) ~= "function" then
            return false, "Kobo Wi-Fi profiles are unavailable"
        end
        local profiles, err = NetworkMgr:getConfiguredNetworks()
        if not profiles then return false, err or "Could not read Kobo Wi-Fi profiles" end
        local ids = {}
        for _i, profile in ipairs(profiles) do
            if profile.ssid == network.ssid then ids[#ids + 1] = profile.id end
        end
        if #ids == 0 then return true, nil, false end

        local WpaClient = require("lj-wpaclient/wpaclient")
        local wcli
        wcli, err = WpaClient.new(NetworkMgr.wpa_supplicant.ctrl_interface)
        if not wcli then return false, err end
        for _i, id in ipairs(ids) do
            local reply
            reply, err = wcli:sendCtrlCmd("REMOVE_NETWORK " .. tostring(id))
            if not reply or reply:sub(1, 2) ~= "OK" then
                wcli:sendCtrlCmd("RECONFIGURE")
                wcli:close()
                return false, err or reply
            end
        end
        local reply
        reply, err = wcli:sendCtrlCmd("SAVE_CONFIG")
        if not reply or reply:sub(1, 2) ~= "OK" then
            wcli:sendCtrlCmd("RECONFIGURE")
            wcli:close()
            return false, err or reply
        end
        wcli:close()
        logger.dbg("Kobo profiles forgotten", "ssid=", network.ssid, "profiles=", #ids)
        return true, nil, true
    end

    local function authenticate_password(network)
        local methods = require("lj-wpaclient/wpaclient").__index
        local enable = methods.enableNetworkByID
        local auth_client, close
        local failures = 0
        -- KOReader authenticates synchronously; SELECT_NETWORK clears an earlier DISCONNECT.
        methods.enableNetworkByID = function(wcli, id)
            auth_client = wcli
            close = wcli.close
            wcli.close = function() end -- Defer cleanup until the result is known.
            local read_event = wcli.readEvent
            wcli.readEvent = function(self)
                local event = read_event(self)
                if event then
                    local failed, wrong_key = auth_failure(event)
                    event.isAuthFailed = function() return failed end
                    if failed then
                        failures = failures + 1
                        logger.dbg("Kobo authentication failure", "profile_id=", id,
                            "failures=", failures, "limit=", max_auth_failures,
                            "wrong_key=", wrong_key)
                    end
                end
                return event
            end
            local reply, err = wcli:sendCtrlCmd("SELECT_NETWORK " .. tostring(id))
            logger.dbg("Kobo password profile selected", "ssid=", network.ssid,
                "profile_id=", id, "accepted=", reply ~= nil and reply:sub(1, 2) == "OK")
            return reply, err
        end
        local ok, authenticated, err = pcall(NetworkMgr.authenticateNetwork, NetworkMgr, network)
        methods.enableNetworkByID = enable
        if auth_client then
            finish_auth(auth_client, ok and authenticated == true)
            close(auth_client)
        end
        if not ok then return false, tostring(authenticated) end
        return authenticated, err
    end

    function adapter.connect(network, use_password)
        local id = not use_password and
            (network.wpa_supplicant_id or adapter.profileId(network.ssid))
        if not id then return authenticate_password(network) end
        local authenticated, err = use_profile(id, true)
        if authenticated then network.wpa_supplicant_id = id end
        logger.dbg("Kobo configured profile connection", "ssid=", network.ssid,
            "profile_id=", id, "accepted=", authenticated == true)
        return authenticated, err
    end

    function adapter.annotateScan(networks)
        local configured = type(NetworkMgr.getConfiguredNetworks) == "function"
            and NetworkMgr:getConfiguredNetworks() or {}
        local configured_ssids = {}
        for _i, profile in ipairs(configured) do
            configured_ssids[profile.ssid] = true
        end
        local saved_count = 0
        for _i, network in ipairs(networks) do
            network.kobo_configured = configured_ssids[network.ssid] == true
            if network.password ~= nil then saved_count = saved_count + 1 end
            logger.dbg("Kobo scan network", "ssid=", network.ssid or "<hidden>",
                "quality=", network.signal_quality or "none",
                "raw_signal=", network.signal_level or "none",
                "frequency=", network.frequency or "none",
                "configured=", network.kobo_configured)
        end
        logger.dbg("Kobo scan result", "networks=", #networks,
            "saved_credentials=", saved_count, "configured_profiles=", #configured)
    end

    return adapter
end

return M
