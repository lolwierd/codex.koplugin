--[[--
Calls the ChatGPT Codex backend `/responses` endpoint with an OAuth bearer
token (same endpoint/headers the Codex CLI and `pi` use) and returns the
assistant's text.

We request a non-streamed response for simple parsing, but the parser also
copes with a Server-Sent-Events stream in case the backend insists on one.

@module codex.api
--]]--

local JSON = require("json")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local Api = {
    RESPONSES_URL = "https://chatgpt.com/backend-api/codex/responses",
    -- Mirror the Codex CLI so requests look like a sanctioned client.
    ORIGINATOR = "codex_cli_rs",
    USER_AGENT = "codex_cli_rs/0.0.0 (KOReader; codex.koplugin)",
}

local function build_headers(token, account_id, web_search)
    local h = {
        ["Authorization"] = "Bearer " .. token,
        ["OpenAI-Beta"] = "responses=experimental",
        ["originator"] = Api.ORIGINATOR,
        ["User-Agent"] = Api.USER_AGENT,
        ["Content-Type"] = "application/json",
        ["Accept"] = "text/event-stream",
        -- Codex sends this; "true" makes the request eligible for web search.
        ["x-oai-web-search-eligible"] = web_search and "true" or "false",
    }
    if account_id then
        h["chatgpt-account-id"] = account_id
    end
    return h
end

--- Pull assistant text out of a decoded Responses-API object.
local function text_from_response_obj(obj)
    if type(obj) ~= "table" then return nil end
    if type(obj.output_text) == "string" and obj.output_text ~= "" then
        return obj.output_text
    end
    local out = obj.output or (obj.response and obj.response.output)
    if type(out) ~= "table" then return nil end
    local chunks = {}
    for _, item in ipairs(out) do
        if type(item) == "table" and item.content then
            for _, c in ipairs(item.content) do
                if type(c) == "table" and c.type == "output_text" and c.text then
                    chunks[#chunks + 1] = c.text
                end
            end
        end
    end
    if #chunks > 0 then return table.concat(chunks) end
    return nil
end

--- Parse either a single JSON object or an SSE stream of events.
local function parse_body(raw)
    -- Try plain JSON first (stream=false).
    local ok, obj = pcall(JSON.decode, raw)
    if ok then
        local t = text_from_response_obj(obj)
        if t then return t end
        if obj and obj.error then
            return nil, (obj.error.message or "API error")
        end
    end
    -- Fall back to SSE: accumulate output_text deltas / final completed event.
    local deltas = {}
    local final
    local api_err
    for line in raw:gmatch("[^\r\n]+") do
        local data = line:match("^data:%s?(.+)$")
        if data and data ~= "[DONE]" then
            local okd, evt = pcall(JSON.decode, data)
            if okd and type(evt) == "table" then
                if evt.type == "response.output_text.delta" and evt.delta then
                    deltas[#deltas + 1] = evt.delta
                elseif evt.type == "response.completed" then
                    final = text_from_response_obj(evt.response or evt)
                elseif evt.type == "error" or evt.error then
                    api_err = (evt.error and evt.error.message) or evt.message or "API error"
                end
            end
        end
    end
    if #deltas > 0 then return table.concat(deltas) end
    if final then return final end
    if api_err then return nil, api_err end
    return nil, "could not parse response"
end
Api._parse_body = parse_body

--- Build a single user-message input array (for one-shot asks).
function Api.userMessage(text)
    return { type = "message", role = "user",
             content = { { type = "input_text", text = text } } }
end

--- Build an assistant-message input item (for conversation history).
function Api.assistantMessage(text)
    return { type = "message", role = "assistant",
             content = { { type = "output_text", text = text } } }
end

--- Ask the model with a full conversation. Returns answer_string, or nil, err.
-- @param token       access token
-- @param account_id  chatgpt account id (may be nil)
-- @param instructions system prompt
-- @param messages    array of Responses-API input items (see userMessage/assistantMessage)
-- @param model       model id (e.g. "gpt-5.5")
-- @param web_search  boolean: offer the hosted web_search tool
-- @param reasoning   reasoning effort string ("none", "low", "medium", "high", "xhigh")
function Api:askMessages(token, account_id, instructions, messages, model, web_search, reasoning)
    local payload = {
        model = model or "gpt-5.5",
        instructions = instructions,
        input = messages,
        store = false,
        -- The Codex backend is built for streaming; request SSE and parse it.
        stream = true,
    }
    if reasoning and reasoning ~= "" and reasoning ~= "default" then
        payload.reasoning = { effort = reasoning, summary = "auto" }
    end
    if web_search then
        -- Hosted tool: the server runs the search and folds it into the answer.
        payload.tools = { { type = "web_search", external_web_access = true } }
        payload.tool_choice = "auto"
    end
    local body = JSON.encode(payload)
    local sink = {}
    -- Block timeout = max gap between chunks; total = hard cap for a long answer.
    -- Web search needs longer: the server pauses to fetch pages.
    socketutil:set_timeout(40, web_search and 180 or 120)
    local code, headers, status = socket.skip(1, http.request{
        url = self.RESPONSES_URL,
        method = "POST",
        headers = build_headers(token, account_id, web_search),
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    local raw = table.concat(sink)
    if headers == nil then
        logger.warn("Codex api: network error", status or code)
        return nil, "Network error. Is Wi-Fi on?"
    end
    if code == 401 or code == 403 then
        return nil, "Unauthorized (" .. tostring(code) .. "). Try signing in again."
    end
    if code ~= 200 then
        local _, err = parse_body(raw)
        logger.warn("Codex api: http", code, raw)
        return nil, (err or ("HTTP " .. tostring(code)))
    end
    local text, err = parse_body(raw)
    if not text then
        return nil, err or "Empty response"
    end
    return text
end

--- Convenience: one-shot single-prompt ask.
function Api:ask(token, account_id, instructions, prompt, model, web_search, reasoning)
    return self:askMessages(token, account_id, instructions,
        { Api.userMessage(prompt) }, model, web_search, reasoning)
end

return Api
