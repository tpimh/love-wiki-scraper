-- generate-api.lua: generate love_api.lua from wiki data

local json = require("lib.json")

-- Data structures
local pageTitles = {}      -- pageId -> title
local pageChildren = {}    -- parentId -> {childId1, childId2, ...}
local pageCategories = {}  -- pageId -> "category1, category2, ..."
local pageContent = {}     -- pageId -> raw content

-- Load config
local config = require("config")

-- Trim whitespace from a string
local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

-- clean up wiki markup
local function stripContent(content)
    if not content then
        return ""
    end
    -- Remove <source ...>...</source> blocks (including closing > of opening tag)
    local cleanedContent = content:gsub("<source.-%>.-</source>", "")
    -- remove all templates ({{...}})
    cleanedContent = cleanedContent:gsub("{{.-}}", "")

    -- remove empty lines and trim whitespace
    cleanedContent = cleanedContent:gsub("\n%s*\n", "\n") -- remove empty lines
    cleanedContent = cleanedContent:gsub("\r", "") -- remove carriage returns
    cleanedContent = cleanedContent:gsub("%s+", " ") -- collapse multiple spaces
    cleanedContent = cleanedContent:gsub("^%s(.-)%s$", "%1") -- trim leading/trailing whitespace

    return cleanedContent
end

-- Extract categories from raw content
local function extractCategories(raw)
    local cats = {}
    local cleanedContent = stripContent(raw)
    for cat in cleanedContent:gmatch("%[%[Category:([^%]]+)%]%]") do
        table.insert(cats, trim(cat))
    end
    if #cats > 0 then return table.concat(cats, ", ") end
    return nil
end

-- Find page ID by title (reverse lookup)
local function findPageByTitle(title)
    for pageId, pageTitle in pairs(pageTitles) do
        if pageTitle == title then
            return pageId
        end
    end
    return nil
end

-- Get page parent by id
local function findPageParent(pageId)
    local content = pageContent[pageId]
    if not content or content == "" or string.match(content, "^#REDIRECT") then
        return nil
    end
    local strippedContent = stripContent(content)
    local parents = {}
    for parentTitle in string.gmatch(strippedContent, "%[%[parent::([^%]]+)%]%]") do
        local parentId = findPageByTitle(trim(parentTitle))
        if parentId then
            table.insert(parents, parentId)
        end
    end
    if #parents > 0 then
        return parents
    end
    return nil
end

-- Load all data from dump files
local function loadAllData()
    local total = 0
    
    for i = 1, config.D_FILES do
        local filename = config.D_PREFIX .. i .. config.SUFFIX
        local file = io.open(filename, "r")
        if file then
            local jsonContent = file:read("*a")
            file:close()
            local ok, data = pcall(json.decode, jsonContent)
            if ok and data and data.query and data.query.pages then
                local addedCount = 0
                for pageid, pageInfo in pairs(data.query.pages) do
                    local pageId = tonumber(pageid)
                    if pageId and pageInfo.title and pageInfo.revisions and pageInfo.revisions[1] then
                        local title = pageInfo.title
                        local content = pageInfo.revisions[1]["*"]
                        
                        -- Skip disambiguation pages
                        if not string.match(title, " %(.+%)$") and content then
                            -- Store data in separate tables
                            pageTitles[pageId] = title
                            pageContent[pageId] = content
                            pageCategories[pageId] = extractCategories(content)
                            
                            addedCount = addedCount + 1
                        end
                    end
                end
                print(string.format("Loaded %d pages from %s", addedCount, filename))
                total = total + addedCount
            end
        end
    end
    
    -- Build parent-child relationships using IDs
    for pageId, content in pairs(pageContent) do
        local parents = findPageParent(pageId)
        if parents then
            -- Support multiple parents
            for _, parentId in ipairs(parents) do
                if not pageChildren[parentId] then
                    pageChildren[parentId] = {}
                end
                table.insert(pageChildren[parentId], pageId)
            end
        end
    end
    
    print(string.format("Total pages loaded: %d", total))
end

-- Remove wiki markup from description
local function stripDescription(description)
    -- remove <code> and </code> tags
    description = description:gsub("<code>", ""):gsub("</code>", "")
    -- remove [[...]] and [[...|...]] links
    description = description:gsub("%[%[[^%]|]+|([^%]]+)%]%]", "%1")
    return description
end

-- Get page description by id
local function getPageDescription(pageId)
    local content = pageContent[pageId]
    if not content or content == "" or string.match(content, "^#REDIRECT") then
        return ""
    end
    local description = string.match(content, "{{#set:Description=([^}]+)}}")
    if description then
      return stripDescription(description)
    else
      return ""
    end
end

-- Parse param line (arguments and returns)
local function parseParamLine(line)
    local type_, name, description = line:match("{{param|([^|]+)|([^|]+)|([^}]+)}}")
    if type_ and name and description then
        return {
            type = type_,
            name = name,
            description = stripDescription(description)
        }
    end
    return nil
end

-- Parse page content
local function parsePageContent(raw)
    if not raw or raw == "" then return { content = "", sections = {} } end
    local lines = {}
    for line in raw:gmatch("[^\r\n]+") do table.insert(lines, line) end
    local root = { content = "", sections = {} }
    local stack = { { node = root, level = 0 } }
    local currentContent = {}
    local function flushContentTo(section)
        local text = table.concat(currentContent, "\n"):match("^%s*(.-)%s*$")
        currentContent = {}
        if text ~= "" then section.content = text end
    end
    for _, line in ipairs(lines) do
        local eqs, title = line:match("^(=+)%s*(.-)%s*=+$")
        if eqs and title then
            local level = #eqs
            flushContentTo(stack[#stack].node)
            while #stack > 0 and stack[#stack].level >= level do table.remove(stack) end
            local section = { name = title, sections = {} }
            local parent = stack[#stack].node
            parent.sections = parent.sections or {}
            table.insert(parent.sections, section)
            table.insert(stack, { node = section, level = level })
        else
            table.insert(currentContent, line)
        end
    end
    flushContentTo(stack[#stack].node)
    local function clean(tbl)
        if tbl.sections and #tbl.sections == 0 then tbl.sections = nil end
        if tbl.content == nil or tbl.content == "" then tbl.content = nil end
        if tbl.name == nil then tbl.name = nil end
        if tbl.sections then for _, s in ipairs(tbl.sections) do clean(s) end end
    end
    clean(root)
    return root
end

-- Extract function/callback variants
local function extractFunctionVariants(pageid)
    local variants = {}
    local content = parsePageContent(pageContent[pageid])
    if content and content.sections then
        for _, section in ipairs(content.sections) do
            if section.name == "Function" then
                local variant = {}
                for _, subSection in ipairs(section.sections or {}) do
                    if subSection.name == "Arguments" and subSection.content ~= "None." then
                        variant.arguments = {}
                        for line in (subSection.content or ""):gmatch("[^\n]+") do
                            local param = parseParamLine(line)
                            if param then table.insert(variant.arguments, param) end
                        end
                    end
                    if subSection.name == "Returns" and subSection.content ~= "Nothing." then
                        variant.returns = {}
                        for line in (subSection.content or ""):gmatch("[^\n]+") do
                            local param = parseParamLine(line)
                            if param then table.insert(variant.returns, param) end
                        end
                    end
                end
                table.insert(variants, variant)
            end
        end
    end
    return variants
end

-- Extract categories from raw content
local function extractCategories(raw)
    local cats = {}
    local cleanedContent = stripContent(raw)
    for cat in cleanedContent:gmatch("%[%[Category:([^%]]+)%]%]") do
        table.insert(cats, trim(cat))
    end
    if #cats > 0 then return table.concat(cats, ", ") end
    return "none"
end

-- Build tree structure and sort it alphabetically
local function buildTree(pageId, visited)
    visited = visited or {}
    
    -- Check for circular reference
    if visited[pageId] then
        return {
            id = pageId,
            title = pageTitles[pageId],
            description = getPageDescription(pageId),
            category = pageCategories[pageId],
            circular = true -- Mark as circular reference
        }
    end
    
    -- Mark this node as visited
    visited[pageId] = true
    
    local node = {
        id = pageId,
        title = pageTitles[pageId],
        description = getPageDescription(pageId),
        category = pageCategories[pageId]
    }
        
    -- Get children of this page
    local children = pageChildren[pageId] or {}
    if #children > 0 then
        -- Sort children alphabetically by title
        table.sort(children, function(a, b)
            return pageTitles[a] < pageTitles[b]
        end)

        -- Recursively build child nodes
        node.children = {}
        for _, childId in ipairs(children) do
            table.insert(node.children, buildTree(childId, visited))
        end
    end
    
    -- Remove from visited set when done with this branch
    visited[pageId] = nil
        
    return node
end

-- Main build function
do
    loadAllData()

    -- Find love page ID
    local lovePageId = findPageByTitle("love")
    if not lovePageId then
        error("Could not find 'love' page")
    end
    
    -- Build the complete tree structure
    local loveTree = buildTree(lovePageId)
    
    local apiTree = {
        name = loveTree.title,
        description = loveTree.description,
        functions = {},
        callbacks = {},
        types = {},
        modules = {},
    }
    
    -- Fill apiTree based on loveTree (first level only)
    if loveTree.children then
        for _, child in ipairs(loveTree.children) do
            local cat = tostring(child.category or ""):lower()
            
            if cat:find("function") then
                local variants = extractFunctionVariants(child.id)
                local shortName = child.title:gsub("^love%.", "")
                table.insert(apiTree.functions, { name = shortName, description = child.description, variants = variants })
            elseif cat:find("callback") then
                local variants = extractFunctionVariants(child.id)
                local shortName = child.title:gsub("^love%.", "")
                table.insert(apiTree.callbacks, { name = shortName, description = child.description, variants = variants })
            elseif cat:find("type") then
                table.insert(apiTree.types, { name = child.title, description = child.description, functions = {} })
            elseif cat:find("module") then
                local shortName = child.title:gsub("^love%.", "")
                table.insert(apiTree.modules, { name = shortName, description = child.description })
            end
        end
    end
    -- Serialize and write to file
    local fieldOrder = {"type", "name", "description", "variants", "functions", "callbacks", "types", "modules", "arguments", "returns"}
    local function serializeTable(tbl, indent)
        indent = indent or "    "
        local lines = {"{"}
        local isArray = true
        local count = 0
        for k, _ in pairs(tbl) do
            count = count + 1
            if type(k) ~= "number" then isArray = false break end
        end
        if isArray then
            for i = 1, #tbl do
                local v = tbl[i]
                if type(v) == "table" then
                    table.insert(lines, indent .. serializeTable(v, indent .. "    ") .. ",")
                elseif type(v) == "string" then
                    table.insert(lines, indent .. string.format("'%s'", v) .. ",")
                else
                    table.insert(lines, indent .. tostring(v) .. ",")
                end
            end
        else
            local used = {}
            for _, key in ipairs(fieldOrder) do
                local v = rawget(tbl, key)
                if v ~= nil then
                    used[key] = true
                    if type(v) == "table" then
                        table.insert(lines, indent .. key .. " = " .. serializeTable(v, indent .. "    ") .. ",")
                    elseif type(v) == "string" then
                        local escaped = v:gsub("'", "\\'")
                        table.insert(lines, indent .. key .. " = '" .. escaped .. "',")
                    else
                        table.insert(lines, indent .. key .. " = " .. tostring(v) .. ",")
                    end
                end
            end
            for k, v in pairs(tbl) do
                if not used[k] then
                    local keyStr = (type(k) == "string" and k) or tostring(k)
                    if type(v) == "table" then
                    elseif type(v) == "string" then
                        local escaped = v:gsub("'", "\\'")
                        table.insert(lines, indent .. keyStr .. " = '" .. escaped .. "',")
                    else
                        table.insert(lines, indent .. keyStr .. " = " .. tostring(v) .. ",")
                    end
                end
            end
        end
        table.insert(lines, string.sub(indent, 1, -5) .. "}")
        return table.concat(lines, "\n")
    end
    local file, err = io.open("love_api.lua", "w")
    if not file then error(err) end
    file:write("-- This file is auto-generated.\nreturn ", serializeTable(apiTree), "\n")
    file:close()
    print("love_api.lua generated successfully.")
end
