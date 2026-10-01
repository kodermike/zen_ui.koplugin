local M = {}

function M.isSupported(Device)
    return Device.isKobo and Device:isKobo()
end

function M.new(NetworkMgr, logger)
    local ffiutil = require("ffi/util")
    local _ = require("gettext")
    local adapter = { id = "kobo" }

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
        local reply
        reply, err = wcli:sendCtrlCmd(reconnect and "SELECT_NETWORK " .. tostring(id) or "DISCONNECT")
        local connected = false
        if reconnect and reply and reply:sub(1, 2) == "OK" then
            for _i = 1, 120 do
                local current = wcli:getConnectedNetwork()
                if current and tostring(current.id) == tostring(id) then
                    connected = true
                    break
                end
                ffiutil.usleep(250 * 1000)
            end
        end
        if reconnect then wcli:sendCtrlCmd("ENABLE_NETWORK all") end
        wcli:close()
        if connected then return true, _("Authenticated") end
        if reply and reply:sub(1, 2) == "OK" then
            if reconnect then return false, _("Timed out") end
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

    function adapter.connect(network, use_password)
        local id = not use_password and
            (network.wpa_supplicant_id or adapter.profileId(network.ssid))
        if not id then return NetworkMgr:authenticateNetwork(network) end
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
