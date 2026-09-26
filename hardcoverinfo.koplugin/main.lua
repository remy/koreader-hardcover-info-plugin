--[[
Hardcover info: look up the current book on Hardcover.app and show
title, authors, year, series (with its other books), description and rating.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local DataStorage = require("datastorage")
local _ = require("gettext")
local T = require("ffi/util").template

local Api = require("hardcoverinfo_api")
local HardcoverView = require("hardcoverinfo_view")

-- Place the menu entry in the main (☰) menu, right after "Book information".
local reader_order = require("ui/elements/reader_menu_order")
if not util.arrayContains(reader_order.main, "hardcoverinfo") then
    local pos = util.arrayContains(reader_order.main, "book_info")
    table.insert(reader_order.main, pos and pos + 1 or #reader_order.main + 1, "hardcoverinfo")
end

local COVER_DIR = DataStorage:getDataDir() .. "/cache/hardcoverinfo"

local TOKEN_KEY = "hardcoverinfo_token"
local CACHE_KEY = "hardcoverinfo"
local TOKEN_URL = "https://hardcover.app/account/api?scope=read:catalog"
local OAUTH_KEY = "hardcoverinfo_oauth"
local SCOPE = "read:catalog"
-- Public client ID of the Hardcover OAuth app ("Mobile, desktop, or CLI",
-- Device Authorization Grant on, scope read:catalog). Empty disables sign-in.
local CLIENT_ID = "78640659-b53c-42ad-9c03-68ac0487677c"

local HardcoverInfo = WidgetContainer:extend{
    name = "hardcoverinfo",
    is_doc_only = true,
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
        cover_url = type(book.image) == "table" and str(book.image.url) or nil,
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
                text_func = function()
                    return G_reader_settings:readSetting(OAUTH_KEY) and _("Sign out of Hardcover")
                        or _("Sign in to Hardcover")
                end,
                enabled_func = function() return CLIENT_ID ~= "" end,
                callback = function()
                    if G_reader_settings:readSetting(OAUTH_KEY) then
                        self:signOut()
                    else
                        self:signIn()
                    end
                end,
            },
            {
                text = _("Personal API token…"),
                keep_menu_open = true,
                callback = function() self:editToken() end,
            },
        },
    }
end

-- Auth ------------------------------------------------------------------------

local function saveOAuth(res)
    G_reader_settings:saveSetting(OAUTH_KEY, {
        access_token = res.access_token,
        refresh_token = res.refresh_token,
        expires_at = os.time() + (tonumber(res.expires_in) or 3600),
    })
    G_reader_settings:flush()
end

function HardcoverInfo:getPersonalToken()
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

function HardcoverInfo:hasCredentials()
    return G_reader_settings:readSetting(OAUTH_KEY) ~= nil or self:getPersonalToken() ~= nil
end

-- Refresh tokens rotate on every use: save the new pair straight away.
function HardcoverInfo:refreshOAuth()
    local oauth = G_reader_settings:readSetting(OAUTH_KEY)
    if not oauth then return nil, _("Not signed in.") end
    local res, err, code = Api.oauth("token", {
        grant_type = "refresh_token",
        refresh_token = oauth.refresh_token,
        client_id = CLIENT_ID,
    })
    if res and str(res.access_token) then
        saveOAuth(res)
        return res.access_token
    end
    if code then
        -- Refresh token rejected: session is gone.
        G_reader_settings:delSetting(OAUTH_KEY)
        return nil, _("Hardcover session expired. Sign in again.")
    end
    return nil, err
end

function HardcoverInfo:getToken()
    local oauth = G_reader_settings:readSetting(OAUTH_KEY)
    if oauth then
        if (oauth.expires_at or 0) - 300 > os.time() then
            return oauth.access_token
        end
        return self:refreshOAuth()
    end
    return self:getPersonalToken() or nil, _("Not signed in to Hardcover.")
end

-- Call fn(token, ...) and retry once with a refreshed OAuth token on 401.
function HardcoverInfo:api(fn, ...)
    local token, err = self:getToken()
    if not token then return nil, err end
    local res, code
    res, err, code = fn(token, ...)
    if code == 401 and G_reader_settings:readSetting(OAUTH_KEY) then
        token, err = self:refreshOAuth()
        if not token then return nil, err end
        res, err = fn(token, ...)
    end
    return res, err
end

function HardcoverInfo:signIn(on_success)
    if CLIENT_ID == "" then
        return self:showError(_("No OAuth client ID configured. Use a personal API token instead."))
    end
    NetworkMgr:runWhenOnline(function()
        local device, err = withLoading(_("Contacting Hardcover…"), function()
            return Api.oauth("device", { client_id = CLIENT_ID, scope = SCOPE })
        end)
        if not device or not str(device.device_code) then
            return self:showError(err or _("Invalid response from Hardcover."), _("Hardcover sign-in failed:"))
        end

        local interval = tonumber(device.interval) or 5
        local deadline = os.time() + (tonumber(device.expires_in) or 900)
        local done = false
        local msg = InfoMessage:new{
            text = T(_("On your phone or computer, go to:\n%1\n\nand enter the code:\n\n%2\n\nWaiting for approval… Tap to cancel."),
                device.verification_uri or "https://hardcover.app/link", device.user_code),
            dismiss_callback = function() done = true end,
        }
        UIManager:show(msg)

        local function finish(text)
            done = true
            UIManager:close(msg)
            if text then UIManager:show(InfoMessage:new{ text = text, timeout = 3 }) end
        end

        local poll
        poll = function()
            if done then return end
            if os.time() > deadline then
                return finish(_("Code expired. Try signing in again."))
            end
            local res, perr, code = Api.oauth("token", {
                grant_type = "urn:ietf:params:oauth:grant-type:device_code",
                device_code = device.device_code,
                client_id = CLIENT_ID,
            })
            if done then return end
            if res and str(res.access_token) then
                saveOAuth(res)
                finish(_("Signed in to Hardcover."))
                if on_success then UIManager:scheduleIn(1, on_success) end
                return
            end
            if code == "slow_down" then interval = interval + 5 end
            -- Keep polling while pending, and through transient network errors.
            if code == nil or code == "authorization_pending" or code == "slow_down" then
                return UIManager:scheduleIn(interval, poll)
            end
            finish()
            self:showError(code == "access_denied" and _("Access denied.") or perr, _("Hardcover sign-in failed:"))
        end
        UIManager:scheduleIn(interval, poll)
    end)
end

function HardcoverInfo:signOut()
    local oauth = G_reader_settings:readSetting(OAUTH_KEY)
    G_reader_settings:delSetting(OAUTH_KEY)
    G_reader_settings:flush()
    -- Best effort: revoke so the session disappears from Hardcover's authorised apps.
    if oauth and NetworkMgr.isOnline and NetworkMgr:isOnline() then
        Api.oauth("revoke", {
            token = oauth.refresh_token,
            token_type_hint = "refresh_token",
            client_id = CLIENT_ID,
        })
    end
    UIManager:show(InfoMessage:new{ text = _("Signed out of Hardcover."), timeout = 2 })
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

-- Returns true if credentials exist; otherwise starts sign-in and runs
-- on_success once signed in.
function HardcoverInfo:requireAuth(on_success)
    if self:hasCredentials() then return true end
    if CLIENT_ID ~= "" then
        self:signIn(on_success)
    else
        self:editToken()
    end
    return false
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

function HardcoverInfo:showInfo(force_refresh)
    if not self.ui.document then return end
    local cached = self.ui.doc_settings:readSetting(CACHE_KEY)
    if cached and cached.book and not force_refresh then
        return self:display(cached.book)
    end
    if not self:requireAuth(function() self:showInfo(force_refresh) end) then return end
    NetworkMgr:runWhenOnline(function()
        if cached and cached.id then
            self:fetchAndShow(cached.id)
        else
            self:autoMatch()
        end
    end)
end

function HardcoverInfo:search(query)
    return withLoading(T(_("Searching Hardcover for:\n%1"), query), function()
        return self:api(Api.search, query)
    end)
end

function HardcoverInfo:autoMatch()
    local info = self:getDocInfo()
    local hits, err
    if info.isbn then
        hits, err = self:search(info.isbn)
        if hits and hits[1] then
            return self:fetchAndShow(hits[1].id)
        end
    end
    local query = util.trim(info.title .. " " .. (info.author or ""))
    if query == "" then return self:manualSearch() end
    hits, err = self:search(query)
    if not hits then return self:showError(err) end
    if hits[1] and normalise(hits[1].title) == normalise(info.title) then
        return self:fetchAndShow(hits[1].id)
    end
    self:chooseResult(hits, query)
end

function HardcoverInfo:manualSearch()
    if not self:requireAuth(function() self:manualSearch() end) then return end
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
                        local hits, err = self:search(query)
                        if not hits then return self:showError(err) end
                        self:chooseResult(hits, query)
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function HardcoverInfo:chooseResult(hits, query)
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
                self:fetchAndShow(hit.id)
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

function HardcoverInfo:fetchAndShow(id)
    local book, err = withLoading(_("Fetching book from Hardcover…"), function()
        return self:api(Api.getBook, id)
    end)
    if not book then return self:showError(err) end
    local vm = toViewModel(book)
    if vm.cover_url then
        vm.cover_file = withLoading(_("Fetching cover…"), function()
            return self:downloadCover(vm.id or id, vm.cover_url)
        end)
    end
    self.ui.doc_settings:saveSetting(CACHE_KEY, { id = id, book = vm, fetched = os.time() })
    self:display(vm)
end

function HardcoverInfo:downloadCover(id, url)
    if lfs.attributes(COVER_DIR, "mode") ~= "directory" then
        util.makePath(COVER_DIR)
    end
    local ext = (url:match("%.(%a+)$") or url:match("%.(%a+)%?") or "jpg"):lower()
    local path = string.format("%s/%d.%s", COVER_DIR, id, ext)
    if Api.download(url, path) then return path end
end

function HardcoverInfo:display(vm)
    UIManager:show(HardcoverView:new{ vm = vm, cover_file = vm.cover_file })
end

function HardcoverInfo:showError(err, heading)
    UIManager:show(InfoMessage:new{
        text = (heading or _("Hardcover lookup failed:")) .. "\n" .. tostring(err),
    })
end

-- Exposed for tests.
HardcoverInfo._toViewModel = toViewModel
HardcoverInfo._findIsbn = findIsbn
HardcoverInfo._setClientId = function(id) CLIENT_ID = id end

return HardcoverInfo
