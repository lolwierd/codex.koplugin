--[[--
ChatGPT (Codex) OAuth via the device-code flow.

This mirrors, in Lua, exactly what the OpenAI Codex CLI and `pi` do:
  - same OAuth client id  (app_EMoamEEZ73f0CkXaXp7hrann)
  - same issuer           (https://auth.openai.com)
  - same device-code endpoints under /api/accounts/deviceauth/*
  - same token endpoint   (/oauth/token)

The device-code flow is used (rather than the localhost:1455 browser
callback) because it needs no local web server, no browser on the device,
and the server returns the PKCE verifier/challenge for us -- so no local
crypto is required for login.

Tokens ride your ChatGPT Plus/Pro subscription; there is no API key and no
extra per-token billing. This is unofficial use of OpenAI's Codex client;
keep it to your own account.

@module codex.auth
--]]--

local DataStorage = require("datastorage")
local JSON = require("json")
local LuaSettings = require("luasettings")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local sha2 = require("ffi/sha2")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")

local Auth = {
    CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann",
    ISSUER = "https://auth.openai.com",
}

Auth.TOKEN_URL = Auth.ISSUER .. "/oauth/token"
Auth.DEVICE_USERCODE_URL = Auth.ISSUER .. "/api/accounts/deviceauth/usercode"
Auth.DEVICE_TOKEN_URL = Auth.ISSUER .. "/api/accounts/deviceauth/token"
-- Shown to the user; where they go to enter the one-time code:
Auth.VERIFICATION_URL = Auth.ISSUER .. "/codex/device"
-- Redirect uri used in the final authorization_code exchange (must match what
-- the Codex CLI uses for the device flow):
Auth.DEVICE_REDIRECT_URI = Auth.ISSUER .. "/deviceauth/callback"

local function settings_file()
    return DataStorage:getSettingsDir() .. "/codex_auth.lua"
end

function Auth:getStore()
    if not self.store then
        self.store = LuaSettings:open(settings_file())
    end
    return self.store
end

--- Low-level HTTPS request. Returns: http_code, decoded_table_or_raw_string, raw_string
-- @param method "GET"/"POST"
-- @param url full url
-- @param headers table of request headers (Content-Length is added for you)
-- @param body string request body (optional)
local function request(method, url, headers, body)
    local sink = {}
    headers = headers or {}
    if body then
        headers["Content-Length"] = tostring(#body)
    end
    local req = {
        url = url,
        method = method,
        headers = headers,
        sink = ltn12.sink.table(sink),
    }
    if body then
        req.source = ltn12.source.string(body)
    end
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, _headers, status = socket.skip(1, http.request(req))
    socketutil:reset_timeout()
    local raw = table.concat(sink)
    if _headers == nil then
        logger.warn("Codex auth: network error", status or code)
        return nil, nil, raw
    end
    local ok, decoded = pcall(JSON.decode, raw)
    if ok then
        return code, decoded, raw
    end
    return code, nil, raw
end
Auth._request = request

--- Decode a JWT payload (base64url, possibly unpadded) into a Lua table.
local function decode_jwt(jwt)
    if type(jwt) ~= "string" then return nil end
    local parts = {}
    for p in jwt:gmatch("[^.]+") do parts[#parts + 1] = p end
    if #parts < 2 then return nil end
    local payload = parts[2]
    -- pad to a multiple of 4 so the base64 decoder emits the final group
    local pad = (4 - (#payload % 4)) % 4
    payload = payload .. string.rep("=", pad)
    local ok, bin = pcall(sha2.base64_to_bin, payload)
    if not ok or not bin then return nil end
    local ok2, claims = pcall(JSON.decode, bin)
    if not ok2 then return nil end
    return claims
end
Auth._decode_jwt = decode_jwt

local function account_id_from_jwt(jwt)
    local claims = decode_jwt(jwt)
    if not claims then return nil end
    local auth = claims["https://api.openai.com/auth"]
    if type(auth) == "table" then
        return auth.chatgpt_account_id
    end
    return nil
end

--------------------------------------------------------------------------------
-- Public state
--------------------------------------------------------------------------------

function Auth:isLoggedIn()
    local s = self:getStore()
    return s:has("refresh_token") and s:readSetting("refresh_token") ~= nil
end

function Auth:getEmail()
    return self:getStore():readSetting("email")
end

function Auth:logout()
    local s = self:getStore()
    s:delSetting("access_token")
    s:delSetting("refresh_token")
    s:delSetting("id_token")
    s:delSetting("account_id")
    s:delSetting("email")
    s:delSetting("expires_at")
    s:flush()
end

local function persist_tokens(self, tokens)
    local s = self:getStore()
    if tokens.access_token then s:saveSetting("access_token", tokens.access_token) end
    if tokens.refresh_token then s:saveSetting("refresh_token", tokens.refresh_token) end
    if tokens.id_token then s:saveSetting("id_token", tokens.id_token) end
    if tokens.expires_in then
        s:saveSetting("expires_at", os.time() + tonumber(tokens.expires_in) - 60)
    end
    -- account id + email come from the id_token (fall back to access token)
    local account_id = account_id_from_jwt(tokens.id_token) or account_id_from_jwt(tokens.access_token)
    if account_id then s:saveSetting("account_id", account_id) end
    local claims = decode_jwt(tokens.id_token)
    if claims and claims.email then s:saveSetting("email", claims.email) end
    s:flush()
end

--------------------------------------------------------------------------------
-- Device-code login
--------------------------------------------------------------------------------

--- Step 1: request a one-time user code.
-- Returns a table { user_code, device_auth_id, interval } or nil, err.
function Auth:requestDeviceCode()
    local body = JSON.encode({ client_id = self.CLIENT_ID })
    local code, res = request("POST", self.DEVICE_USERCODE_URL,
        { ["Content-Type"] = "application/json" }, body)
    if code == nil then
        return nil, "network"
    end
    if code ~= 200 or not res or not res.user_code then
        logger.warn("Codex auth: usercode failed", code)
        return nil, "http_" .. tostring(code)
    end
    return {
        user_code = res.user_code,
        device_auth_id = res.device_auth_id,
        interval = tonumber(res.interval) or 5,
    }
end

--- Step 2: poll once. Returns one of:
--   "pending"            -> keep polling
--   "ok", tokens_saved   -> logged in (tokens already persisted)
--   "error", reason
function Auth:pollDeviceToken(device_auth_id, user_code)
    local body = JSON.encode({ device_auth_id = device_auth_id, user_code = user_code })
    local code, res, raw = request("POST", self.DEVICE_TOKEN_URL,
        { ["Content-Type"] = "application/json" }, body)
    if code == nil then
        return "pending" -- transient network blip; try again
    end
    -- While the user hasn't approved yet the server returns 403/404.
    if code == 403 or code == 404 then
        return "pending"
    end
    if code ~= 200 or not res or not res.authorization_code then
        logger.warn("Codex auth: poll failed", code, raw)
        return "error", "http_" .. tostring(code)
    end
    -- Step 3: exchange the authorization_code (+ server-provided PKCE verifier)
    -- for real tokens.
    local ok, reason = self:exchangeAuthorizationCode(res.authorization_code, res.code_verifier)
    if not ok then
        return "error", reason
    end
    return "ok"
end

--- Step 3: authorization_code -> tokens.
function Auth:exchangeAuthorizationCode(authorization_code, code_verifier)
    local form = table.concat({
        "grant_type=authorization_code",
        "code=" .. socket_url.escape(authorization_code),
        "redirect_uri=" .. socket_url.escape(self.DEVICE_REDIRECT_URI),
        "client_id=" .. socket_url.escape(self.CLIENT_ID),
        "code_verifier=" .. socket_url.escape(code_verifier or ""),
    }, "&")
    local code, res, raw = request("POST", self.TOKEN_URL,
        { ["Content-Type"] = "application/x-www-form-urlencoded" }, form)
    if code ~= 200 or not res or not res.access_token then
        logger.warn("Codex auth: token exchange failed", code, raw)
        return false, "http_" .. tostring(code)
    end
    persist_tokens(self, res)
    return true
end

--------------------------------------------------------------------------------
-- Refresh + access
--------------------------------------------------------------------------------

function Auth:refresh()
    local s = self:getStore()
    local refresh_token = s:readSetting("refresh_token")
    if not refresh_token then return false, "no_refresh_token" end
    -- Codex sends JSON for refresh, with scope.
    local body = JSON.encode({
        client_id = self.CLIENT_ID,
        grant_type = "refresh_token",
        refresh_token = refresh_token,
        scope = "openid profile email",
    })
    local code, res, raw = request("POST", self.TOKEN_URL,
        { ["Content-Type"] = "application/json" }, body)
    if code ~= 200 or not res then
        logger.warn("Codex auth: refresh failed", code, raw)
        return false, "http_" .. tostring(code)
    end
    -- A refresh may omit refresh_token (keep the old one) and expires_in.
    persist_tokens(self, {
        access_token = res.access_token,
        refresh_token = res.refresh_token,
        id_token = res.id_token,
        expires_in = res.expires_in,
    })
    return true
end

--- Returns access_token, account_id (refreshing first if expired/near-expiry).
-- On failure returns nil, reason.
function Auth:getValidToken()
    local s = self:getStore()
    if not self:isLoggedIn() then return nil, "not_logged_in" end
    local expires_at = s:readSetting("expires_at") or 0
    if not s:readSetting("access_token") or os.time() >= expires_at then
        local ok, reason = self:refresh()
        if not ok then return nil, reason end
    end
    return s:readSetting("access_token"), s:readSetting("account_id")
end

return Auth
