--[[--
Codex (ChatGPT) for KOReader.

Sign in with your ChatGPT subscription (device-code flow, no API key), then:
  - "Ask Codex" on any highlighted text (Explain / Summarize / Define / Ask…)
  - "Ask Codex…" free-form question from the main menu

@module koplugin.codex
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Auth = require("codexauth")
local Api = require("codexapi")

local DEFAULT_INSTRUCTIONS =
    "You are a knowledgeable reading companion inside an e-reader. The user " ..
    "is reading a book and may ask about a passage. Answer clearly in plain " ..
    "language and give enough detail to explain the subject properly. For an " ..
    "explanatory question, normally write several focused paragraphs and " ..
    "include relevant context, implications, and examples. Adapt to the " ..
    "question, but do not be artificially terse. Output readable plain text, " ..
    "not Markdown: do not use # headings, **bold**, backticks, code fences, " ..
    "or tables. When a list is useful, use the bullet character •. Short " ..
    "plain-text section labels are allowed. Do not mention that you are Codex " ..
    "or a coding assistant."

-- Models served by the openai-codex provider (chatgpt.com/backend-api/codex).
-- Keep the default model and reasoning effort separate: "Luna Medium" is
-- gpt-5.6-luna with reasoning effort "medium".
local MODEL_PRESETS = {
    "gpt-5.6-luna",        -- default: efficient, high-volume work
    "gpt-5.6-terra",       -- everyday workhorse
    "gpt-5.6-sol",         -- flagship capability
}

-- Reasoning effort ("thinking"). More effort = slower but deeper answers.
local REASONING_PRESETS = { "none", "low", "medium", "high", "xhigh" }
local DEFAULT_REASONING = "medium"
local SUPPORTED_REASONING = {}
for _, reasoning in ipairs(REASONING_PRESETS) do
    SUPPORTED_REASONING[reasoning] = true
end

local function normalize_reasoning(reasoning)
    if reasoning == "minimal" then return "none" end
    if SUPPORTED_REASONING[reasoning] then return reasoning end
    return DEFAULT_REASONING
end

local Codex = WidgetContainer:extend{
    name = "codex",
    is_doc_only = false,
}

local MAX_HISTORY = 50

local function viewer_buttons()
    return {
        {
            { text = _("Previous"), callback = function() end },
            { text = _("Next"), callback = function() end },
        },
        {
            { text = _("Reply"), callback = function() end },
            { text = _("History"), callback = function() end },
            { text = _("New chat"), callback = function() end },
        },
    }
end

--- Split text at the exact wrapped-line boundaries used by TextViewer.
local function transcript_pages(text)
    local measurement = TextViewer:new{
        title = _("Codex chat"),
        text = text,
        justified = false,
        show_menu = false,
        add_default_buttons = false,
        buttons_table = viewer_buttons(),
    }
    local text_widget = measurement.scroll_text_w.text_widget
    local lines = text_widget.vertical_string_list
    local lines_per_page = text_widget.lines_per_page
    local charlist = util.splitToChars(text)
    local pages = {}

    for line_num = 1, #lines, lines_per_page do
        local next_page_line = lines[line_num + lines_per_page]
        local end_char = next_page_line and next_page_line.offset - 1 or #charlist
        pages[#pages + 1] = table.concat(
            charlist, "", lines[line_num].offset, end_char
        )
    end
    measurement:free()

    if #pages == 0 then
        pages[1] = _("No conversation text is available.")
    end
    return pages
end

local function style_page(text)
    local bold_start = TextBoxWidget.PTF_BOLD_START
    local bold_end = TextBoxWidget.PTF_BOLD_END
    text = text:gsub("^You:", bold_start .. "You:" .. bold_end)
    text = text:gsub("^Codex:", bold_start .. "Codex:" .. bold_end)
    text = text:gsub("\nYou:", "\n" .. bold_start .. "You:" .. bold_end)
    text = text:gsub("\nCodex:", "\n" .. bold_start .. "Codex:" .. bold_end)
    return TextBoxWidget.PTF_HEADER .. text
end

function Codex:init()
    self.config = LuaSettings:open(DataStorage:getSettingsDir() .. "/codex_config.lua")
    self.chats = LuaSettings:open(DataStorage:getSettingsDir() .. "/codex_chats.lua")
    local saved_reasoning = self.config:readSetting("reasoning")
    if saved_reasoning then
        local reasoning = normalize_reasoning(saved_reasoning)
        if reasoning ~= saved_reasoning then
            self.config:saveSetting("reasoning", reasoning)
            self.config:flush()
        end
    end
    self.ui.menu:registerToMainMenu(self)
    if self.ui.highlight then
        self:addToHighlightDialog()
    end
end

function Codex:getModel()
    return self.config:readSetting("model") or MODEL_PRESETS[1]
end

function Codex:webSearchEnabled()
    return self.config:readSetting("web_search") == true
end

function Codex:getReasoning()
    return normalize_reasoning(self.config:readSetting("reasoning"))
end

--------------------------------------------------------------------------------
-- Main menu
--------------------------------------------------------------------------------

function Codex:addToMainMenu(menu_items)
    menu_items.codex = {
        text = _("Codex (ChatGPT)"),
        sub_item_table = {
            {
                text_func = function()
                    if Auth:isLoggedIn() then
                        return T(_("Signed in: %1"), Auth:getEmail() or _("ChatGPT account"))
                    end
                    return _("Sign in with ChatGPT")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    if Auth:isLoggedIn() then
                        self:confirmSignOut(touchmenu_instance)
                    else
                        self:startLogin(touchmenu_instance)
                    end
                end,
            },
            {
                text = _("Chat with Codex…"),
                enabled_func = function() return Auth:isLoggedIn() end,
                callback = function() self:newChatPrompt() end,
            },
            {
                text_func = function()
                    return T(_("Chat history (%1)"), #self:getChatList())
                end,
                enabled_func = function() return #self:getChatList() > 0 end,
                sub_item_table_func = function() return self:historyMenu() end,
            },
            {
                text = _("Web search"),
                checked_func = function() return self:webSearchEnabled() end,
                callback = function()
                    self.config:saveSetting("web_search", not self:webSearchEnabled())
                    self.config:flush()
                end,
                keep_menu_open = true,
                separator = true,
            },
            {
                text_func = function() return T(_("Model: %1"), self:getModel()) end,
                sub_item_table_func = function() return self:modelMenu() end,
            },
            {
                text_func = function() return T(_("Thinking: %1"), self:getReasoning()) end,
                sub_item_table_func = function() return self:reasoningMenu() end,
            },
            {
                text = _("Check for updates"),
                separator = true,
                callback = function()
                    require("codexupdater").check()
                end,
            },
        },
    }
end

function Codex:reasoningMenu()
    local items = {}
    for _i, r in ipairs(REASONING_PRESETS) do
        items[#items + 1] = {
            text = r,
            radio = true,
            checked_func = function() return self:getReasoning() == r end,
            callback = function()
                self.config:saveSetting("reasoning", r)
                self.config:flush()
            end,
        }
    end
    return items
end

function Codex:modelMenu()
    local items = {}
    for _, m in ipairs(MODEL_PRESETS) do
        items[#items + 1] = {
            text = m,
            checked_func = function() return self:getModel() == m end,
            callback = function()
                self.config:saveSetting("model", m)
                self.config:flush()
            end,
            radio = true,
        }
    end
    items[#items + 1] = {
        text = _("Custom…"),
        keep_menu_open = true,
        callback = function()
            local dialog
            dialog = InputDialog:new{
                title = _("Model id"),
                input = self:getModel(),
                buttons = {{
                    { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                    { text = _("Save"), is_enter_default = true, callback = function()
                        local v = dialog:getInputText()
                        if v and v ~= "" then
                            self.config:saveSetting("model", v)
                            self.config:flush()
                        end
                        UIManager:close(dialog)
                    end },
                }},
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end,
    }
    return items
end

function Codex:confirmSignOut(touchmenu_instance)
    local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
    local dialog
    dialog = ButtonDialogTitle:new{
        title = T(_("Signed in as %1"), Auth:getEmail() or _("ChatGPT account")),
        buttons = {{
            { text = _("Sign out"), callback = function()
                Auth:logout()
                UIManager:close(dialog)
                if touchmenu_instance then touchmenu_instance:updateItems() end
                UIManager:show(InfoMessage:new{ text = _("Signed out.") })
            end },
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
        }},
    }
    UIManager:show(dialog)
end

--------------------------------------------------------------------------------
-- Device-code login (non-blocking polling)
--------------------------------------------------------------------------------

function Codex:startLogin(touchmenu_instance)
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Contacting ChatGPT…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local dc, err = Auth:requestDeviceCode()
        UIManager:close(info)
        if not dc then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not start sign-in (%1)."), err or "error"),
            })
            return
        end

        self._login_cancelled = false
        local prompt = InfoMessage:new{
            text = T(_([[Sign in to ChatGPT

On your phone or computer, open:
%1

Enter this code:
    %2

Waiting for approval…
(tap to cancel)]]), Auth.VERIFICATION_URL, dc.user_code),
            dismiss_callback = function() self._login_cancelled = true end,
        }
        UIManager:show(prompt)

        local deadline = os.time() + 15 * 60
        local interval = math.max(dc.interval or 5, 3)
        local poll
        poll = function()
            if self._login_cancelled then return end
            local status, reason = Auth:pollDeviceToken(dc.device_auth_id, dc.user_code)
            if status == "ok" then
                UIManager:close(prompt)
                if touchmenu_instance then touchmenu_instance:updateItems() end
                UIManager:show(InfoMessage:new{
                    text = T(_("Signed in as %1."), Auth:getEmail() or _("your ChatGPT account")),
                })
            elseif status == "error" then
                UIManager:close(prompt)
                UIManager:show(InfoMessage:new{
                    text = T(_("Sign-in failed (%1)."), reason or "error"),
                })
            else -- pending
                if os.time() >= deadline then
                    UIManager:close(prompt)
                    UIManager:show(InfoMessage:new{ text = _("Sign-in timed out. Try again.") })
                else
                    UIManager:scheduleIn(interval, poll)
                end
            end
        end
        UIManager:scheduleIn(interval, poll)
    end)
end

--------------------------------------------------------------------------------
-- Conversation engine
--------------------------------------------------------------------------------

local function message_text(m)
    if type(m) ~= "table" then return "" end
    if type(m.content) == "string" then return m.content end
    if type(m.content) ~= "table" then return "" end

    local parts = {}
    for _, c in ipairs(m.content) do
        if type(c) == "table" and type(c.text) == "string" then
            parts[#parts + 1] = c.text
        end
    end
    return table.concat(parts)
end

--------------------------------------------------------------------------------
-- Persistent chat history
--------------------------------------------------------------------------------

function Codex:getChatList()
    return self.chats:readSetting("list") or {}
end

--- Save (or update) the current conversation to history.
function Codex:saveCurrentChat()
    if not self.messages or #self.messages == 0 then return end
    local list = self:getChatList()
    -- Title = first user message, single line, truncated.
    local title = message_text(self.messages[1]):gsub("%s+", " ")
    if #title > 50 then title = title:sub(1, 50) .. "…" end
    local entry = {
        id = self.current_chat_id,
        title = title ~= "" and title or _("(untitled)"),
        time = os.time(),
        messages = self.messages,
    }
    if self.current_chat_id then
        -- Update existing entry in place.
        for i, e in ipairs(list) do
            if e.id == self.current_chat_id then
                table.remove(list, i)
                break
            end
        end
    else
        self.current_chat_id = (self.chats:readSetting("next_id") or 0) + 1
        self.chats:saveSetting("next_id", self.current_chat_id)
        entry.id = self.current_chat_id
    end
    table.insert(list, 1, entry) -- newest first
    while #list > MAX_HISTORY do table.remove(list) end
    self.chats:saveSetting("list", list)
    self.chats:flush()
end

function Codex:openChat(entry)
    -- Copy the array so appending follow-ups doesn't mutate the stored ref.
    local msgs = {}
    for i, v in ipairs(entry.messages) do msgs[i] = v end
    self.messages = msgs
    self.current_chat_id = entry.id
    self:showConversation(1)
end

function Codex:historyMenu()
    local items = {}
    for _i, e in ipairs(self:getChatList()) do
        local when = os.date("%Y-%m-%d %H:%M", e.time or 0)
        items[#items + 1] = {
            text = e.title .. "  ·  " .. when,
            callback = function() self:openChat(e) end,
        }
    end
    items[#items + 1] = {
        text = _("Clear all history"),
        separator = true,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self.chats:saveSetting("list", {})
            self.chats:flush()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    }
    return items
end

function Codex:showHistory()
    local entries = self:getChatList()
    if #entries == 0 then
        UIManager:show(InfoMessage:new{ text = _("No saved chats.") })
        return
    end

    local items = {}
    local menu
    for _, entry in ipairs(entries) do
        local when = os.date("%Y-%m-%d %H:%M", entry.time or 0)
        items[#items + 1] = {
            text = entry.title .. "  ·  " .. when,
            callback = function()
                UIManager:close(menu)
                UIManager:scheduleIn(0.1, function() self:openChat(entry) end)
            end,
        }
    end
    menu = Menu:new{
        title = _("Codex chat history"),
        item_table = items,
        covers_fullscreen = true,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

--- Send the current self.messages to Codex and continue the conversation.
-- Runs inline (not in a subprocess) so any failure is always surfaced.
function Codex:sendConversation()
    if not Auth:isLoggedIn() then
        UIManager:show(InfoMessage:new{
            text = _("Not signed in. Use the menu: Codex (ChatGPT) → Sign in with ChatGPT."),
        })
        return
    end
    local model = self:getModel()
    local web = self:webSearchEnabled()
    local reasoning = self:getReasoning()
    NetworkMgr:runWhenOnline(function()
        local token, account_id = Auth:getValidToken()
        if not token then
            UIManager:show(InfoMessage:new{
                text = _("Could not get a valid token. Try signing in again."),
            })
            return
        end
        -- Show a spinner and force it to paint BEFORE the blocking request.
        local busy = InfoMessage:new{
            text = web and _("Searching the web + asking Codex…") or _("Asking Codex…"),
        }
        UIManager:show(busy)
        UIManager:forceRePaint()

        local ok, text, err = pcall(function()
            return Api:askMessages(token, account_id, DEFAULT_INSTRUCTIONS,
                self.messages, model, web, reasoning)
        end)
        UIManager:close(busy)

        if not ok then
            -- A Lua error inside the request path (text holds the error message).
            table.remove(self.messages)
            UIManager:show(InfoMessage:new{
                text = T(_("Codex crashed: %1"), tostring(text)),
            })
            if #self.messages > 0 then
                UIManager:scheduleIn(0.1, function() self:showConversation() end)
            end
            return
        end
        if not text then
            table.remove(self.messages)
            UIManager:show(InfoMessage:new{
                text = T(_("Codex error: %1"), tostring(err or "no response")),
            })
            if #self.messages > 0 then
                UIManager:scheduleIn(0.1, function() self:showConversation() end)
            end
            return
        end
        self.messages[#self.messages + 1] = Api.assistantMessage(text)
        self:saveCurrentChat()
        logger.info("Codex: response ready", #text, "bytes")
        -- Let KOReader finish closing the busy overlay before opening the chat.
        UIManager:scheduleIn(0.1, function() self:showConversation() end)
    end)
end

--- Render one immutable, exactly measured page of the conversation.
function Codex:showConversation(page_index)
    local parts = {}
    for _i, m in ipairs(self.messages) do
        local who = (m.role == "user") and _("You") or _("Codex")
        parts[#parts + 1] = who .. ":\n" .. message_text(m)
    end
    local transcript = table.concat(parts, "\n\n────────\n\n")
    if transcript == "" then
        transcript = _("No conversation text is available.")
    end
    local pages = transcript_pages(transcript)
    page_index = math.max(1, math.min(page_index or 1, #pages))
    logger.info("Codex: showing conversation", #self.messages, "messages",
        #transcript, "bytes", "page", page_index, "of", #pages)

    local function show_page(index)
        local viewer
        local function replace_page(new_index)
            UIManager:close(viewer)
            show_page(new_index)
        end
        viewer = TextViewer:new{
            title = T(_("Codex chat (%1/%2)"), index, #pages),
            text = style_page(pages[index]),
            justified = false,
            show_menu = false,
            add_default_buttons = false,
            buttons_table = {
                {
                    {
                        text = _("Previous"),
                        enabled = index > 1,
                        callback = function() replace_page(index - 1) end,
                    },
                    {
                        text = _("Next"),
                        enabled = index < #pages,
                        callback = function() replace_page(index + 1) end,
                    },
                },
                {
                    {
                        text = _("Reply"),
                        callback = function()
                            UIManager:close(viewer)
                            self:replyPrompt()
                        end,
                    },
                    {
                        text = _("History"),
                        callback = function()
                            UIManager:close(viewer)
                            self:showHistory()
                        end,
                    },
                    {
                        text = _("New chat"),
                        callback = function()
                            UIManager:close(viewer)
                            self:newChatPrompt()
                        end,
                    },
                },
            },
        }
        UIManager:show(viewer)
    end
    show_page(page_index)
end

--- Generic single-line/multi-line prompt; calls fn(text) on submit.
function Codex:promptText(title, hint, fn)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = "",
        input_hint = hint,
        allow_newline = true,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Send"), is_enter_default = true, callback = function()
                local q = dialog:getInputText()
                UIManager:close(dialog)
                if q and q ~= "" then fn(q) end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Start a brand-new conversation seeded with user_text, then send.
function Codex:startConversation(user_text)
    self.current_chat_id = nil -- a fresh chat gets its own history entry
    self.messages = { Api.userMessage(user_text) }
    self:sendConversation()
end

function Codex:newChatPrompt()
    self:promptText(_("Ask Codex"), _("Type your question…"), function(q)
        self:startConversation(q)
    end)
end

function Codex:replyPrompt()
    self:promptText(_("Reply"), _("Your follow-up…"), function(q)
        self.messages[#self.messages + 1] = Api.userMessage(q)
        self:sendConversation()
    end)
end

--------------------------------------------------------------------------------
-- Highlight integration
--------------------------------------------------------------------------------

function Codex:addToHighlightDialog()
    -- '13_*' keeps it after the built-in '12_search' item.
    self.ui.highlight:addToHighlightDialog("13_codex", function(this)
        return {
            text = _("Ask Codex"),
            callback = function()
                local text = util.cleanupSelectedText(this.selected_text.text)
                this:onClose(true)
                self:selectionActions(text)
            end,
        }
    end)
end

function Codex:selectionActions(text)
    local dialog
    local function start(prompt)
        UIManager:close(dialog)
        self:startConversation(prompt)
    end
    dialog = ButtonDialog:new{
        buttons = {
            {{ text = _("Explain"), callback = function()
                start("Explain the following passage thoroughly in plain language. " ..
                    "Include the context, meaning, and significance needed to understand it:\n\n" ..
                    text)
            end }},
            {{ text = _("Summarize"), callback = function()
                start("Write a substantive summary of the following passage. Preserve " ..
                    "its main argument, important details, and necessary context:\n\n" .. text)
            end }},
            {{ text = _("Define terms"), callback = function()
                start("Define the difficult words, names, and references in this passage, " ..
                    "and explain why each matters in context:\n\n" .. text)
            end }},
            {{ text = _("Ask about this…"), callback = function()
                UIManager:close(dialog)
                self:promptText(_("Ask about the selection"), _("What do you want to know?"),
                    function(q) self:startConversation(q .. "\n\nPassage:\n" .. text) end)
            end }},
        },
    }
    UIManager:show(dialog)
end

return Codex
