-- Adds %hardcover_year to bookshelf.koplugin: the release year cached by
-- Hardcover book info in each book's sidecar. Empty until the book has been
-- looked up. Works in [if:hardcover_year] conditionals too.

local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local userpatch = require("userpatch")

local CACHE_KEY = "hardcoverinfo"

-- filepath -> { mtime, year }; re-read only when the sidecar changes.
local cache = {}

local function hardcoverYear(book)
    local fp = book and book.filepath
    if not fp then return "" end
    local sidecar = DocSettings:findSidecarFile(fp)
    if not sidecar then return "" end
    local mtime = lfs.attributes(sidecar, "modification")
    local hit = cache[fp]
    if not hit or hit.mtime ~= mtime then
        local stored = DocSettings.openSettingsFile(sidecar):readSetting(CACHE_KEY)
        local year = type(stored) == "table" and type(stored.book) == "table" and tonumber(stored.book.year)
        hit = { mtime = mtime, year = year and tostring(year) or "" }
        cache[fp] = hit
    end
    return hit.year
end

userpatch.registerPatchPluginFunc("bookshelf", function()
    local ok, Tokens = pcall(require, "lib/bookshelf_tokens")
    if not ok or type(Tokens) ~= "table" or not Tokens.expanders then return end
    if Tokens.expanders.hardcover_year then return end

    Tokens.expanders.hardcover_year = hardcoverYear
    if Tokens.CATALOGUE then
        table.insert(Tokens.CATALOGUE, {
            category = "Book", token = "%hardcover_year", description = "Hardcover release year",
        })
    end

    -- Token names are cached on first expand; drop the cache so ours is seen.
    local names_fn = userpatch.getUpValue(Tokens.expand, "tokenNamesByLengthDesc")
    if names_fn then
        local _, idx = userpatch.getUpValue(names_fn, "_token_names_cache")
        if debug.getupvalue(names_fn, idx) == "_token_names_cache" then
            userpatch.replaceUpValue(names_fn, idx, nil)
        end
    end
end)
