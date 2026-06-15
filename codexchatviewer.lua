local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

local ChatViewer = InputContainer:extend{
    text = "",
    page = 1,
}

function ChatViewer:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    self.width = screen_w - Screen:scaleBySize(30)
    self.height = screen_h - Screen:scaleBySize(30)
    self.region = Geom:new{ w = screen_w, h = screen_h }

    self.titlebar = TitleBar:new{
        width = self.width,
        align = "left",
        with_bottom_line = true,
        title = _("Codex chat"),
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    self.button_table = ButtonTable:new{
        width = self.width,
        zero_sep = true,
        show_parent = self,
        buttons = {
            {
                {
                    id = "previous",
                    text = _("Previous"),
                    callback = function() self:setPage(self.page - 1) end,
                },
                {
                    id = "next",
                    text = _("Next"),
                    callback = function() self:setPage(self.page + 1) end,
                },
            },
            {
                {
                    text = _("Reply"),
                    callback = function()
                        UIManager:close(self)
                        if self.reply_callback then
                            UIManager:scheduleIn(0.1, self.reply_callback)
                        end
                    end,
                },
                {
                    text = _("History"),
                    callback = function()
                        UIManager:close(self)
                        if self.history_callback then
                            UIManager:scheduleIn(0.1, self.history_callback)
                        end
                    end,
                },
                {
                    text = _("New chat"),
                    callback = function()
                        UIManager:close(self)
                        if self.new_chat_callback then
                            UIManager:scheduleIn(0.1, self.new_chat_callback)
                        end
                    end,
                },
            },
        },
    }

    local padding = Size.padding.large
    local body_height = self.height - self.titlebar:getHeight() -
        self.button_table:getSize().h
    local text_width = self.width - 2 * padding
    local text_height = body_height - 2 * padding
    local text_types = G_reader_settings:readSetting("textviewer_text_types")
    local general = text_types and text_types.general or {}

    self.text_widget = TextBoxWidget:new{
        text = self.text,
        face = Font:getFace("x_smallinfofont", general.font_size or 20),
        width = text_width,
        height = text_height,
        alignment = "left",
        justified = false,
        auto_para_direction = true,
    }
    self.page_count = math.max(1, math.ceil(
        #self.text_widget.vertical_string_list / self.text_widget.lines_per_page
    ))

    self.text_frame = FrameContainer:new{
        padding = padding,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.text_widget,
    }
    self.text_area = TopContainer:new{
        dimen = Geom:new{ w = self.width, h = body_height },
        self.text_frame,
    }

    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            self.titlebar,
            self.text_area,
            self.button_table,
        },
    }
    self[1] = WidgetContainer:new{
        align = "center",
        dimen = self.region,
        self.frame,
    }

    if Device:isTouchDevice() then
        self.ges_events = {
            Swipe = {
                GestureRange:new{
                    ges = "swipe",
                    range = function() return self.text_area.dimen end,
                },
            },
        }
    end

    self:setPage(self.page, true)
end

function ChatViewer:setPage(page, initial)
    self.page = math.max(1, math.min(page, self.page_count))
    local line = 1 + (self.page - 1) * self.text_widget.lines_per_page
    if self.text_widget.virtual_line_num ~= line then
        self.text_widget.virtual_line_num = line
        self.text_widget:free(false)
        self.text_widget:_updateLayout()
    end

    self.titlebar:setTitle(
        T(_("Codex chat (%1/%2)"), self.page, self.page_count),
        true
    )
    local previous = self.button_table:getButtonById("previous")
    local next_button = self.button_table:getButtonById("next")
    if self.page > 1 then previous:enable() else previous:disable() end
    if self.page < self.page_count then next_button:enable() else next_button:disable() end
    if not initial then UIManager:setDirty(self, "ui") end
end

function ChatViewer:onSwipe(_, ges)
    if ges.direction == "north" or ges.direction == "west" then
        self:setPage(self.page + 1)
    elseif ges.direction == "south" or ges.direction == "east" then
        self:setPage(self.page - 1)
    end
    return true
end

function ChatViewer:onShow()
    UIManager:setDirty(self, "ui")
    return true
end

function ChatViewer:onCloseWidget()
    UIManager:setDirty(nil, "ui", self.frame.dimen)
end

function ChatViewer:onClose()
    UIManager:close(self)
    return true
end

return ChatViewer
