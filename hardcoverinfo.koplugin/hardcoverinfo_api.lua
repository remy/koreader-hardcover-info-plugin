--[[
Minimal Hardcover GraphQL client.
Docs: https://docs.hardcover.app/api/getting-started/
]]

local JSON = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local socket = require("socket")
local socketutil = require("socketutil")

local API_URL = "https://api.hardcover.app/v1/graphql"
local OAUTH_URL = "https://api.hardcover.app/oauth2/"
local USER_AGENT = "KOReader hardcoverinfo plugin"

local SEARCH_QUERY = [[
query Search($q: String!, $per_page: Int!) {
  search(query: $q, query_type: "Book", per_page: $per_page, page: 1) {
    results
  }
}]]

-- Series book list follows the "Getting All Books in a Series" guide:
-- one book per position, no merged, partial or compilation entries.
local BOOK_QUERY = [[
query Book($id: Int!) {
  books_by_pk(id: $id) {
    id
    title
    subtitle
    slug
    release_year
    release_date
    description
    rating
    ratings_count
    pages
    image { url }
    cached_image
    contributions {
      contribution
      author { name }
    }
    book_series(order_by: [{featured: desc}, {position: asc}]) {
      position
      details
      series {
        id
        name
        books_count
        book_series(
          distinct_on: position
          order_by: [{position: asc}, {book: {users_count: desc}}]
          where: {
            book: {canonical_id: {_is_null: true}, is_partial_book: {_eq: false}},
            compilation: {_eq: false}
          }
        ) {
          position
          book { id title release_year }
        }
      }
    }
  }
}]]

local Api = {}

local function errorMessage(code, body)
    local ok, data = pcall(JSON.decode, body or "")
    local detail
    if ok and type(data) == "table" then
        if type(data.errors) == "table" and data.errors[1] then
            detail = data.errors[1].message
        end
        detail = detail or data.error_description or data.message or data.error
    end
    if code == 401 then
        return "Invalid or expired API token." .. (detail and (" (" .. tostring(detail) .. ")") or "")
    elseif code == 403 then
        return "Access denied. The token needs the read:catalog scope." .. (detail and (" (" .. tostring(detail) .. ")") or "")
    elseif code == 429 then
        return "Hardcover rate limit reached. Try again later."
    end
    return string.format("HTTP %s%s", tostring(code), detail and (": " .. tostring(detail)) or "")
end

local function post(url, body, content_type, token)
    local headers = {
        ["Content-Type"] = content_type,
        ["Content-Length"] = tostring(#body),
        ["Accept"] = "application/json",
        ["User-Agent"] = USER_AGENT,
    }
    if token then headers["Authorization"] = "Bearer " .. token end
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, _, status = socket.skip(1, http.request{
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    return code, table.concat(sink), status
end

local function formEncode(params)
    local parts = {}
    for k, v in pairs(params) do
        v = tostring(v):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)
        table.insert(parts, k .. "=" .. v)
    end
    return table.concat(parts, "&")
end

-- Returns data, or nil, error message, HTTP code.
function Api.request(token, query, variables)
    local code, response, status = post(API_URL, JSON.encode({ query = query, variables = variables }),
        "application/json", token)

    if type(code) ~= "number" then
        logger.warn("Hardcover: request failed", code, status)
        return nil, "Network error: " .. tostring(code or status)
    end
    if code ~= 200 then
        logger.warn("Hardcover: HTTP", code, response)
        return nil, errorMessage(code, response), code
    end

    local ok, data = pcall(JSON.decode, response)
    if not ok or type(data) ~= "table" then
        return nil, "Invalid response from Hardcover."
    end
    if type(data.errors) == "table" and data.errors[1] then
        logger.warn("Hardcover: GraphQL errors", response)
        return nil, tostring(data.errors[1].message)
    end
    return data.data
end

-- OAuth endpoint call ("device", "token" or "revoke").
-- Returns the decoded body, or nil, error message, OAuth error code (nil on network failure).
function Api.oauth(endpoint, params)
    local code, response, status = post(OAUTH_URL .. endpoint, formEncode(params),
        "application/x-www-form-urlencoded")
    if type(code) ~= "number" then
        logger.warn("Hardcover: OAuth request failed", code, status)
        return nil, "Network error: " .. tostring(code or status)
    end
    local ok, data = pcall(JSON.decode, response)
    data = ok and type(data) == "table" and data or {}
    if code ~= 200 then
        local err = type(data.error) == "string" and data.error or ("http_" .. code)
        return nil, tostring(data.error_description or err), err
    end
    return data
end

-- Returns a list of { id, title, authors, year, series } tables.
function Api.search(token, query, per_page)
    local data, err, code = Api.request(token, SEARCH_QUERY, { q = query, per_page = per_page or 8 })
    if not data then return nil, err, code end
    local results = data.search and data.search.results
    if type(results) == "string" then
        local ok, decoded = pcall(JSON.decode, results)
        results = ok and decoded or nil
    end
    local hits = {}
    for _, hit in ipairs(type(results) == "table" and type(results.hits) == "table" and results.hits or {}) do
        local doc = hit.document
        local id = type(doc) == "table" and tonumber(doc.id)
        if id then
            table.insert(hits, {
                id = id,
                title = type(doc.title) == "string" and doc.title or "?",
                authors = type(doc.author_names) == "table" and doc.author_names or {},
                year = tonumber(doc.release_year),
                series = type(doc.series_names) == "table" and doc.series_names or {},
            })
        end
    end
    return hits
end

-- Download url to path. Returns true, or nil, error message.
function Api.download(url, path)
    local f = io.open(path, "wb")
    if not f then return nil, "Cannot write " .. path end
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, _, status = socket.skip(1, http.request{
        url = url,
        headers = { ["User-Agent"] = USER_AGENT },
        sink = ltn12.sink.file(f),
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        os.remove(path)
        logger.warn("Hardcover: cover download failed", url, code, status)
        return nil, "HTTP " .. tostring(code or status)
    end
    return true
end

function Api.getBook(token, id)
    local data, err, code = Api.request(token, BOOK_QUERY, { id = id })
    if not data then return nil, err, code end
    if type(data.books_by_pk) ~= "table" then
        return nil, "Book not found on Hardcover."
    end
    return data.books_by_pk
end

return Api
