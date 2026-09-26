--[[
Book details view: header with metadata on the left and cover on the right,
scrollable HTML body (series, description) below.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local CSS = [[
@page { margin: 0; }
body { margin: 0; line-height: 1.35; font-family: sans-serif; }
h2 { font-size: 1em; font-weight: bold; margin: 0.9em 0 0.3em 0; }
h2.first { margin-top: 0; }
p { margin: 0 0 0.5em 0; }
table { border-collapse: collapse; margin-bottom: 0.5em; }
td { padding: 0.1em 0; vertical-align: top; }
td.pos { padding-right: 0.8em; text-align: right; }
.current { font-weight: bold; }
.link { font-size: 0.8em; margin-top: 1.2em; }
]]

local function thousands(n)
    local s = string.format("%d", n)
    return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function stars(rating)
    local full = math.floor(rating + 0.25)
    return string.rep("★", full) .. string.rep("☆", 5 - full)
end

local function esc(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function buildHtml(vm)
    local out = {}
    local function add(s) table.insert(out, s) end
    local first = true
    local function heading(text)
        add(string.format('<h2%s>%s</h2>', first and ' class="first"' or "", esc(text)))
        first = false
    end

    for __, s in ipairs(vm.series) do
        heading(s.name)
        add("<table>")
        for __, b in ipairs(s.books) do
            local title = esc(b.title)
            if b.year then title = title .. " (" .. b.year .. ")" end
            add(string.format('<tr%s><td class="pos">%s</td><td>%s</td></tr>',
                b.current and ' class="current"' or "", esc(b.position or ""), title))
        end
        add("</table>")
    end

    if vm.description then
        heading(_("Description"))
        for para in (vm.description .. "\n\n"):gmatch("(.-)\n\n+") do
            if para ~= "" then
                add("<p>" .. esc(para):gsub("\n", "<br/>") .. "</p>")
            end
        end
    end

    if vm.slug then
        add('<p class="link">hardcover.app/books/' .. esc(vm.slug) .. "</p>")
    end
    return table.concat(out, "\n")
end

local HardcoverView = InputContainer:extend{
    vm = nil,
    cover_file = nil,
    font_size = 20, -- unscaled base size
}

function HardcoverView:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    self.width = screen_w - Screen:scaleBySize(30)
    self.height = screen_h - Screen:scaleBySize(30)
    local vm = self.vm
    local pad = Size.padding.large
    local inner_w = self.width - 2 * pad

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        local range = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
        self.ges_events = {
            TapClose = { GestureRange:new{ ges = "tap", range = range } },
            MultiSwipe = { GestureRange:new{ ges = "multiswipe", range = range } },
        }
    end

    local titlebar = TitleBar:new{
        width = self.width,
        align = "left",
        with_bottom_line = true,
        title = _("Hardcover"),
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    -- Cover (right column)
    local cover
    local cover_w = 0
    if self.cover_file and lfs.attributes(self.cover_file, "mode") == "file" then
        cover_w = math.floor(inner_w * 0.32)
        local ok, img = pcall(function()
            local w = ImageWidget:new{
                file = self.cover_file,
                width = cover_w,
                height = math.floor(cover_w * 1.6),
                scale_factor = 0,
                file_do_cache = false,
            }
            w:_render()
            return w
        end)
        if ok then
            cover = img
        else
            logger.warn("Hardcover: cannot render cover", self.cover_file, img)
            cover_w = 0
        end
    end

    -- Metadata (left column), sized relative to the base font
    local base = self.font_size
    local function face(name, ratio)
        return Font:getFace(name, math.floor(base * ratio + 0.5))
    end

    local text_w = cover and (inner_w - cover_w - pad) or inner_w
    local meta = VerticalGroup:new{ align = "left" }
    local function line(text, face, opts)
        opts = opts or {}
        table.insert(meta, TextBoxWidget:new{
            text = text,
            face = face,
            width = text_w,
            bold = opts.bold,
            fgcolor = Blitbuffer.COLOR_BLACK,
        })
        table.insert(meta, VerticalSpan:new{ width = opts.gap or Size.padding.small })
    end

    line(vm.title or "?", face("tfont", 1.35), { gap = Size.padding.tiny })
    if vm.subtitle then line(vm.subtitle, face("cfont", 0.95)) end
    table.insert(meta, VerticalSpan:new{ width = Size.padding.default })
    if #vm.authors > 0 then
        line(table.concat(vm.authors, ", "), face("cfont", 1.05), { bold = true, gap = Size.padding.default })
    end

    local facts = {}
    if vm.year then table.insert(facts, tostring(vm.year)) end
    if vm.pages then table.insert(facts, T(_("%1 pages"), thousands(vm.pages))) end
    if #facts > 0 then line(table.concat(facts, " · "), face("cfont", 0.95)) end

    if vm.rating and vm.rating > 0 then
        line(string.format("%s  %.2f", stars(vm.rating), vm.rating), face("cfont", 1.05), { gap = 0 })
        line(T(_("%1 ratings"), thousands(vm.ratings_count or 0)), face("cfont", 0.85))
    else
        line(_("Not yet rated"), face("cfont", 0.95))
    end

    table.insert(meta, VerticalSpan:new{ width = Size.padding.default })
    if #vm.series == 0 then
        line(_("Standalone"), face("cfont", 0.95))
    else
        for __, s in ipairs(vm.series) do
            local txt = s.position and T(_("Book %1 of %2"), s.position, s.name) or s.name
            line(txt, face("cfont", 0.95))
        end
    end

    local header = HorizontalGroup:new{ align = "top", meta }
    if cover then
        table.insert(header, HorizontalSpan:new{ width = pad })
        table.insert(header, cover)
    end
    local header_frame = FrameContainer:new{
        padding = pad,
        bordersize = 0,
        header,
    }

    local separator = LineWidget:new{
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        dimen = Geom:new{ w = inner_w, h = Size.line.thin },
    }

    local body_h = self.height - titlebar:getHeight() - header_frame:getSize().h - Size.line.thin - 2 * pad
    local content = VerticalGroup:new{
        align = "left",
        titlebar,
        header_frame,
        FrameContainer:new{ padding = 0, padding_left = pad, bordersize = 0, separator },
    }
    local html = buildHtml(vm)
    if html ~= "" and body_h > Screen:scaleBySize(80) then
        self.body = ScrollHtmlWidget:new{
            html_body = html,
            css = CSS,
            default_font_size = Screen:scaleBySize(base),
            width = inner_w,
            height = body_h,
            dialog = self,
        }
        table.insert(content, FrameContainer:new{ padding = pad, bordersize = 0, self.body })
    end

    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        TopContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            content,
        },
    }
    self[1] = WidgetContainer:new{
        align = "center",
        dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h },
        self.frame,
    }
end

function HardcoverView:onShow()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
    return true
end

function HardcoverView:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.frame.dimen end)
end

function HardcoverView:onTapClose(arg, ges)
    if ges.pos:notIntersectWith(self.frame.dimen) then
        self:onClose()
    end
    return true
end

function HardcoverView:onMultiSwipe()
    self:onClose()
    return true
end

function HardcoverView:onClose()
    UIManager:close(self)
    return true
end

HardcoverView._buildHtml = buildHtml

return HardcoverView
