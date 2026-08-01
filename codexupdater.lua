local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local JSON = require("json")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local _ = require("gettext")

local Updater = {
    REPO_SLUG = "lolwierd/codex.koplugin",
}

local function api_url(path)
    return "https://api.github.com/repos/" .. Updater.REPO_SLUG .. path
end

local function releases_url()
    return "https://github.com/" .. Updater.REPO_SLUG .. "/releases"
end

local function installed_version()
    local path = DataStorage:getDataDir() .. "/plugins/codex.koplugin/_meta.lua"
    local ok, meta = pcall(dofile, path)
    return (ok and type(meta) == "table" and meta.version) or "0.0.0"
end

local function parse_version(version)
    local parts = {}
    for part in tostring(version):gsub("^v", ""):gmatch("[^.]+") do
        parts[#parts + 1] = tonumber(part) or 0
    end
    return parts
end

local function is_newer(candidate, current)
    local a = parse_version(candidate)
    local b = parse_version(current)
    for i = 1, math.max(#a, #b) do
        local x = a[i] or 0
        local y = b[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

local function request(options)
    local sink = {}
    options.sink = ltn12.sink.table(sink)
    options.redirect = true
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code = pcall(function()
        return socket.skip(1, http.request(options))
    end)
    socketutil:reset_timeout()
    if not ok or code ~= 200 then return nil end
    return table.concat(sink)
end

local function latest_release(version)
    local raw = request{
        url = api_url("/releases/latest"),
        method = "GET",
        headers = {
            ["Accept"] = "application/vnd.github+json",
            ["User-Agent"] = "KOReader-Codex/" .. version,
        },
    }
    if not raw then return nil end
    local ok, release = pcall(JSON.decode, raw)
    if not ok or type(release) ~= "table" then return nil end
    return release
end

local function zip_url(release)
    for _, asset in ipairs(release.assets or {}) do
        if type(asset.name) == "string" and asset.name:match("%.zip$") then
            return asset.browser_download_url
        end
    end
end

local function show_releases_error(message)
    if Device:canOpenLink() then
        UIManager:show(ConfirmBox:new{
            text = message .. "\n\n" .. _("Open the GitHub releases page?"),
            ok_text = _("Open"),
            ok_callback = function() Device:openLink(releases_url()) end,
        })
    else
        UIManager:show(InfoMessage:new{ text = message, timeout = 4 })
    end
end

function Updater.install(url, version)
    UIManager:show(InfoMessage:new{ text = _("Downloading update..."), timeout = 1 })
    UIManager:scheduleIn(0.1, function()
        local cache_dir = DataStorage:getSettingsDir() .. "/codex_cache"
        if lfs.attributes(cache_dir, "mode") ~= "directory" then
            lfs.mkdir(cache_dir)
        end
        local archive_path = cache_dir .. "/codex.koplugin.zip"
        local file = io.open(archive_path, "wb")
        if not file then
            show_releases_error(_("Could not create the update file."))
            return
        end

        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local ok, code = pcall(function()
            return socket.skip(1, http.request{
                url = url,
                method = "GET",
                headers = { ["User-Agent"] = "KOReader-Codex/" .. installed_version() },
                sink = ltn12.sink.file(file),
                redirect = true,
            })
        end)
        socketutil:reset_timeout()
        if not ok or code ~= 200 then
            pcall(file.close, file)
            pcall(os.remove, archive_path)
            show_releases_error(_("Download failed."))
            return
        end
        file:close()

        local plugin_path = DataStorage:getDataDir() .. "/plugins/codex.koplugin"
        local unpacked, err = Device:unpackArchive(archive_path, plugin_path, true)
        pcall(os.remove, archive_path)
        if not unpacked then
            UIManager:show(InfoMessage:new{
                text = _("Installation failed: ") .. tostring(err),
                timeout = 5,
            })
            return
        end

        UIManager:show(ConfirmBox:new{
            text = _("Codex updated to v") .. version .. ".\n\n" ..
                _("Restart KOReader now?"),
            ok_text = _("Restart"),
            ok_callback = function() UIManager:restartKOReader() end,
        })
    end)
end

function Updater.check()
    local current = installed_version()
    NetworkMgr:runWhenOnline(function()
        UIManager:show(InfoMessage:new{
            text = _("Checking for updates..."),
            timeout = 1,
        })
        UIManager:scheduleIn(0.1, function()
            local release = latest_release(current)
            if not release or not release.tag_name then
                show_releases_error(_("Could not check for updates."))
                return
            end

            local latest = release.tag_name:gsub("^v", "")
            if not is_newer(latest, current) then
                UIManager:show(InfoMessage:new{
                    text = _("Codex is up to date.") .. "\n\n" ..
                        _("Version: v") .. current,
                    timeout = 3,
                })
                return
            end

            local url = zip_url(release)
            local viewer
            viewer = TextViewer:new{
                title = _("Codex update available"),
                text = _("Installed: v") .. current .. "\n" ..
                    _("Latest: v") .. latest .. "\n\n" ..
                    (release.body or ""),
                add_default_buttons = false,
                buttons_table = {{
                    {
                        text = _("Close"),
                        callback = function() UIManager:close(viewer) end,
                    },
                    {
                        text = _("Update and restart"),
                        callback = function()
                            UIManager:close(viewer)
                            if url then
                                Updater.install(url, latest)
                            else
                                show_releases_error(_("No ZIP download is available."))
                            end
                        end,
                    },
                }},
            }
            UIManager:show(viewer)
        end)
    end)
end

Updater._is_newer = is_newer

return Updater
