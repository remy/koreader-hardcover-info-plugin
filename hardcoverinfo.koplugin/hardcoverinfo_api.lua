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

function Api.request(token, query, variables)
    local body = JSON.encode({ query = query, variables = variables })
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, _, status = socket.skip(1, http.request{
        url = API_URL,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
            ["Authorization"] = "Bearer " .. token,
            ["User-Agent"] = USER_AGENT,
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    local response = table.concat(sink)

    if type(code) ~= "number" then
        logger.warn("Hardcover: request failed", code, status)
        return nil, "Network error: " .. tostring(code or status)
    end
    if code ~= 200 then
        logger.warn("Hardcover: HTTP", code, response)
        return nil, errorMessage(code, response)
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

-- Returns a list of { id, title, authors, year, series } tables.
function Api.search(token, query, per_page)
    local data, err = Api.request(token, SEARCH_QUERY, { q = query, per_page = per_page or 8 })
    if not data then return nil, err end
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

function Api.getBook(token, id)
    local data, err = Api.request(token, BOOK_QUERY, { id = id })
    if not data then return nil, err end
    if type(data.books_by_pk) ~= "table" then
        return nil, "Book not found on Hardcover."
    end
    return data.books_by_pk
end

return Api
