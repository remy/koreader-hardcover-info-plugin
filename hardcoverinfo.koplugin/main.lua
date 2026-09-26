--[[
Hardcover info: look up the current book on Hardcover.app and show
title, authors, year, series (with its other books), description and rating.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Api = require("hardcoverinfo_api")

local TOKEN_KEY = "hardcoverinfo_token"
local CACHE_KEY = "hardcoverinfo"
local TOKEN_URL = "https://hardcover.app/account/api?scope=read:catalog"

local HardcoverInfo = WidgetContainer:extend{
    name = "hardcoverinfo",
    is_doc_only = false,
}

-- Helpers -------------------------------------------------------------------

local function str(v)
    return type(v) == "string" and v ~= "" and v or nil
end

local function formatPosition(p)
    p = tonumber(p)
    if not p then return nil end
    if p == math.floor(p) then return string.format("%d", p) end
    return string.format("%g", p)
end

local function thousands(n)
    local s = string.format("%d", n)
    return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function cleanDescription(text)
    text = text:gsub("<[bB][rR]%s*/?>", "\n"):gsub("</[pP]>", "\n\n"):gsub("<[^>]+>", "")
    text = text:gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">")
    text = text:gsub("\r", ""):gsub("\n\n\n+", "\n\n")
    return util.trim(text)
end

local function normalise(s)
    return (s or ""):lower():gsub("[%p%s]+", " "):gsub("^ ", ""):gsub(" $", "")
end

local function findIsbn(identifiers)
    if not identifiers then return nil end
    local s = identifiers:gsub("-", "")
    return s:match("97[89]%d%d%d%d%d%d%d%d%d%d")
        or s:match("%f[%w]%d%d%d%d%d%d%d%d%d[%dXx]%f[%W]")
end

local function withLoading(text, fn)
    local msg = InfoMessage:new{ text = text }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local a, b = fn()
    UIManager:close(msg)
    return a, b
end

-- Reduce the API response to plain values that are safe to store in doc settings.
local function toViewModel(book)
    local vm = {
        id = tonumber(book.id),
        title = str(book.title),
        subtitle = str(book.subtitle),
        slug = str(book.slug),
        year = tonumber(book.release_year),
        release_date = str(book.release_date),
        description = str(book.description) and cleanDescription(book.description),
        rating = tonumber(book.rating),
        ratings_count = tonumber(book.ratings_count),
        pages = tonumber(book.pages),
        authors = {},
        series = {},
    }
    local others = {}
    for __, c in ipairs(type(book.contributions) == "table" and book.contributions or {}) do
        local name = type(c.author) == "table" and str(c.author.name)
        if name then
            local role = str(c.contribution)
            if not role or role:lower() == "author" then
                table.insert(vm.authors, name)
            else
                table.insert(others, name .. " (" .. role .. ")")
            end
        end
    end
    if #vm.authors == 0 then vm.authors = others end

    for __, bs in ipairs(type(book.book_series) == "table" and book.book_series or {}) do
        local series = type(bs.series) == "table" and bs.series
        if series and str(series.name) then
            local entry = {
                name = series.name,
                position = str(bs.details) or formatPosition(bs.position),
                count = tonumber(series.books_count),
                books = {},
            }
            for __, sb in ipairs(type(series.book_series) == "table" and series.book_series or {}) do
                local b = type(sb.book) == "table" and sb.book
                if b then
                    table.insert(entry.books, {
                        title = str(b.title) or "?",
                        year = tonumber(b.release_year),
                        position = formatPosition(sb.position),
                        current = tonumber(b.id) == vm.id,
                    })
                end
            end
            table.insert(vm.series, entry)
        end
    end
    return vm
end

local function formatInfo(vm)
    local lines = {}
    local function add(s) table.insert(lines, s) end

    add(vm.title or "?")
    if vm.subtitle then add(vm.subtitle) end
    add("")
    if #vm.authors > 0 then add(T(_("Author: %1"), table.concat(vm.authors, ", "))) end
    if vm.year then add(T(_("Published: %1"), vm.year)) end
    if vm.pages then add(T(_("Pages: %1"), vm.pages)) end
    if vm.rating and vm.rating > 0 then
        add(T(_("Rating: ★ %1 / 5 (%2 ratings)"), string.format("%.2f", vm.rating), thousands(vm.ratings_count or 0)))
    else
        add(_("Rating: not yet rated"))
    end

    if #vm.series == 0 then
        add("")
        add(_("Series: not part of a series"))
    end
    for __, s in ipairs(vm.series) do
        add("")
        local head = s.position and T(_("Series: %1, book %2"), s.name, s.position) or T(_("Series: %1"), s.name)
        if s.count then head = head .. " " .. T(_("(of %1)"), s.count) end
        add(head)
        for __, b in ipairs(s.books) do
            local line = string.format("%s %s. %s", b.current and "▶" or "  ", b.position or "?", b.title)
            if b.year then line = line .. " (" .. b.year .. ")" end
            add(line)
        end
    end

    if vm.description then
        add("")
        add(_("Description"))
        add(vm.description)
    end
    if vm.slug then
        add("")
        add("https://hardcover.app/books/" .. vm.slug)
    end
    return table.concat(lines, "\n")
end

-- Plugin --------------------------------------------------------------------

function HardcoverInfo:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function HardcoverInfo:onDispatcherRegisterActions()
    Dispatcher:registerAction("hardcoverinfo_show", {
        category = "none",
        event = "ShowHardcoverInfo",
        title = _("Hardcover book info"),
        reader = true,
    })
end

function HardcoverInfo:onShowHardcoverInfo()
    self:showInfo()
    return true
end

function HardcoverInfo:addToMainMenu(menu_items)
    local has_doc = function() return self.ui.document ~= nil end
    menu_items.hardcoverinfo = {
        text = _("Hardcover book info"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Show book info"),
                enabled_func = has_doc,
                callback = function() self:showInfo() end,
            },
            {
                text = _("Refresh from Hardcover"),
                enabled_func = has_doc,
                callback = function() self:showInfo(true) end,
            },
            {
                text = _("Change matched book…"),
                enabled_func = has_doc,
                callback = function() self:manualSearch() end,
                separator = true,
            },
            {
                text = _("API token…"),
                keep_menu_open = true,
                callback = function() self:editToken() end,
            },
        },
    }
end

-- Token -----------------------------------------------------------------------

function HardcoverInfo:getToken()
    local token = G_reader_settings:readSetting(TOKEN_KEY)
    if not str(token) and self.path then
        local f = io.open(self.path .. "/token.txt", "r")
        if f then
            token = f:read("*a")
            f:close()
        end
    end
    token = str(token) and util.trim(token):gsub("^[Bb]earer%s+", "")
    return str(token)
end

function HardcoverInfo:editToken()
    local dialog
    dialog = InputDialog:new{
        title = _("Hardcover API token"),
        description = T(_("Create a token with the read:catalog scope at:\n%1\n\nOr save it in token.txt inside the plugin folder."), TOKEN_URL),
        input = G_reader_settings:readSetting(TOKEN_KEY) or "",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Clear"),
                callback = function()
                    G_reader_settings:delSetting(TOKEN_KEY)
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local value = util.trim(dialog:getInputText() or "")
                    if value == "" then
                        G_reader_settings:delSetting(TOKEN_KEY)
                    else
                        G_reader_settings:saveSetting(TOKEN_KEY, value)
                    end
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Lookup ----------------------------------------------------------------------

function HardcoverInfo:getDocInfo()
    local props = self.ui.doc_props or (self.ui.document and self.ui.document:getProps()) or {}
    local title = str(props.display_title) or str(props.title)
    if not title and self.ui.document then
        local __, filename = util.splitFilePathName(self.ui.document.file)
        title = util.splitFileNameSuffix(filename)
    end
    local author = str(props.authors) and props.authors:match("^[^\n]+")
    return {
        title = title or "",
        author = author,
        isbn = findIsbn(str(props.identifiers)),
    }
end

function HardcoverInfo:requireToken()
    local token = self:getToken()
    if not token then
        UIManager:show(InfoMessage:new{
            text = T(_("No Hardcover API token set.\n\nCreate one at:\n%1"), TOKEN_URL),
        })
        self:editToken()
    end
    return token
end

function HardcoverInfo:showInfo(force_refresh)
    if not self.ui.document then return end
    local cached = self.ui.doc_settings:readSetting(CACHE_KEY)
    if cached and cached.book and not force_refresh then
        return self:display(cached.book)
    end
    local token = self:requireToken()
    if not token then return end
    NetworkMgr:runWhenOnline(function()
        if cached and cached.id then
            self:fetchAndShow(token, cached.id)
        else
            self:autoMatch(token)
        end
    end)
end

function HardcoverInfo:search(token, query)
    return withLoading(T(_("Searching Hardcover for:\n%1"), query), function()
        return Api.search(token, query)
    end)
end

function HardcoverInfo:autoMatch(token)
    local info = self:getDocInfo()
    local hits, err
    if info.isbn then
        hits, err = self:search(token, info.isbn)
        if hits and hits[1] then
            return self:fetchAndShow(token, hits[1].id)
        end
    end
    local query = util.trim(info.title .. " " .. (info.author or ""))
    if query == "" then return self:manualSearch() end
    hits, err = self:search(token, query)
    if not hits then return self:showError(err) end
    if hits[1] and normalise(hits[1].title) == normalise(info.title) then
        return self:fetchAndShow(token, hits[1].id)
    end
    self:chooseResult(token, hits, query)
end

function HardcoverInfo:manualSearch()
    local token = self:requireToken()
    if not token then return end
    local info = self:getDocInfo()
    local dialog
    dialog = InputDialog:new{
        title = _("Search Hardcover"),
        input = util.trim(info.title .. " " .. (info.author or "")),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local query = util.trim(dialog:getInputText() or "")
                    UIManager:close(dialog)
                    if query == "" then return end
                    NetworkMgr:runWhenOnline(function()
                        local hits, err = self:search(token, query)
                        if not hits then return self:showError(err) end
                        self:chooseResult(token, hits, query)
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function HardcoverInfo:chooseResult(token, hits, query)
    local dialog
    local buttons = {}
    for __, hit in ipairs(hits) do
        local label = hit.title
        if hit.year then label = label .. " (" .. hit.year .. ")" end
        if hit.authors[1] then label = label .. " – " .. hit.authors[1] end
        table.insert(buttons, {{
            text = label,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                self:fetchAndShow(token, hit.id)
            end,
        }})
    end
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function() UIManager:close(dialog) end,
        },
        {
            text = _("Search manually…"),
            callback = function()
                UIManager:close(dialog)
                self:manualSearch()
            end,
        },
    })
    dialog = ButtonDialog:new{
        title = #hits > 0 and T(_("Select the matching book for:\n%1"), query)
            or T(_("No results for:\n%1"), query),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function HardcoverInfo:fetchAndShow(token, id)
    local book, err = withLoading(_("Fetching book from Hardcover…"), function()
        return Api.getBook(token, id)
    end)
    if not book then return self:showError(err) end
    local vm = toViewModel(book)
    self.ui.doc_settings:saveSetting(CACHE_KEY, { id = id, book = vm, fetched = os.time() })
    self:display(vm)
end

function HardcoverInfo:display(vm)
    UIManager:show(TextViewer:new{
        title = _("Hardcover"),
        text = formatInfo(vm),
    })
end

function HardcoverInfo:showError(err)
    UIManager:show(InfoMessage:new{
        text = T(_("Hardcover lookup failed:\n%1"), tostring(err)),
    })
end

-- Exposed for tests.
HardcoverInfo._toViewModel = toViewModel
HardcoverInfo._formatInfo = formatInfo
HardcoverInfo._findIsbn = findIsbn

return HardcoverInfo
