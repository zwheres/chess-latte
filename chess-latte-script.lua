local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local lplayer = Players.LocalPlayer

local function get_offsets()
    local t = {}
    for k, v in game:HttpGet("https://offsets.ntgetwritewatch.workers.dev/offsets.json"):gmatch('"([^"]-)"%s*:%s*"([^"]-)"') do
        t[k] = v
    end
    return t
end

local function parseHex(val)
    if type(val) == "string" then
        return tonumber(val, 16) or tonumber(val)
    end
    return nil
end

local rawOffsets = get_offsets()

local Offsets = {
    DisplayName  = parseHex(rawOffsets["DisplayName"]),
    FrameVisible = parseHex(rawOffsets["FrameVisible"]),
}

local displayName = memory_read("string", lplayer.Address + Offsets.DisplayName)

if game.PlaceId ~= 6222531507 then
    notify("This script is for Chess (PlaceId 6222531507). You are in the wrong game.", "Wrong Game", 10)
    return
end

loadstring(game:HttpGet('https://raw.githubusercontent.com/n0v3l3w/chess-latte/refs/heads/main/x11-colorpicker.lua'))()
local UILib = UILib

local EngineInfo = {
    name            = "Unknown",
    is_lc0          = false,
    nodes_multiplier = 1000,
}

local function fetchEngineInfo()
    local ok, ret = pcall(function()
        return game:HttpGet("http://127.0.0.1:3000/api/info")
    end)

    if not ok or not ret or ret == "" then
        notify("Could not reach server. Make sure server.py is running!", "Server Error", 8)
        return false
    end

    local name     = ret:match('"engine_name"%s*:%s*"([^"]+)"')
    local is_lc0   = ret:match('"is_lc0"%s*:%s*(true)') ~= nil
    local mult_str = ret:match('"nodes_multiplier"%s*:%s*(%d+)')

    if name then EngineInfo.name = name end
    EngineInfo.is_lc0 = is_lc0
    if mult_str then EngineInfo.nodes_multiplier = tonumber(mult_str) end

    return true
end

local Config = {
    Depth             = 17,
    Nodes             = 17000,
    ThinkTime         = 100,
    DisregardThinkTime = false,
}

local State = {
    Status     = "Connecting...",
    LastOutput = "",
    Running    = true,
}

local PieceMap = {
    Pawn   = "p",
    Knight = "n",
    Bishop = "b",
    Rook   = "r",
    Queen  = "q",
    King   = "k",
}

local Board = {}
Board.__index = Board

function Board.new()
    local self = setmetatable({}, Board)
    return self
end

function Board.gameInProgress()
    local piecesFolder = Workspace:FindFirstChild("Pieces")
    if not piecesFolder then return false end
    return #piecesFolder:GetChildren() > 0
end

local function getTilePosition(boardTile)
    if not boardTile then return nil end

    if boardTile.ClassName == "Model" then
        local meshTile = boardTile:FindFirstChild("Meshes/tile_a")
        if meshTile then return meshTile.Position end

        local tilePart = boardTile:FindFirstChild("Tile")
        if tilePart then return tilePart.Position end

        local primary = boardTile.PrimaryPart
        if primary then return primary.Position end

        return nil
    end

    return boardTile.Position
end

local function getPiecePosition(piece)
    if not piece then return nil end

    local primary = nil

    local ok1, res1 = pcall(function()
        return piece:FindFirstChildOfClass("MeshPart")
    end)
    if ok1 and res1 then primary = res1 end

    if not primary then
        local ok2, res2 = pcall(function()
            return piece:FindFirstChildOfClass("Part")
        end)
        if ok2 and res2 then primary = res2 end
    end

    if primary then return primary.Position end

    local ok3, pos = pcall(function()
        return piece.Position
    end)
    if ok3 then return pos end

    return nil
end

local cachedTilePositions = nil

local function cacheTilePositions()
    local boardFolder = Workspace:FindFirstChild("Board")
    if not boardFolder then return nil end

    local positions = {}

    for x = 1,8 do
        for y = 1,8 do
            local tileName = tostring(x) .. "," .. tostring(y)
            local tile = boardFolder:FindFirstChild(tileName)
            local pos = getTilePosition(tile)
            if pos then
                positions[tileName] = { pos = pos, x = x, y = y }
            end
        end
    end

    cachedTilePositions = positions
    return positions
end

local function findTileForPiece(piecePos, tileCache)
    if not piecePos then return nil,nil end

    local bestDist = math.huge
    local bestX, bestY

    for _, tileData in pairs(tileCache) do
        local dx = piecePos.X - tileData.pos.X
        local dz = piecePos.Z - tileData.pos.Z
        local dist = dx*dx + dz*dz

        if dist < bestDist then
            bestDist = dist
            bestX = tileData.x
            bestY = tileData.y
        end
    end

    if bestDist < 16 then
        return bestX, bestY
    end

    return nil,nil
end

function Board.getPiece(tileName)
    local piecesFolder = Workspace:FindFirstChild("Pieces")
    if not piecesFolder then return nil end

    local tileCache = cachedTilePositions or cacheTilePositions()
    if not tileCache then return nil end

    local tileData = tileCache[tileName]
    if not tileData then return nil end

    local targetPos = tileData.pos
    local bestDist = math.huge
    local bestPiece = nil

    for _,piece in ipairs(piecesFolder:GetChildren()) do
        local piecePos = getPiecePosition(piece)

        if piecePos then
            local dx = piecePos.X - targetPos.X
            local dz = piecePos.Z - targetPos.Z
            local dist = dx*dx + dz*dz

            if dist < bestDist then
                bestDist = dist
                bestPiece = piece
            end
        end
    end

    if bestDist < 16 then
        return bestPiece
    end

    return nil
end

local playerGui = lplayer:FindFirstChild("PlayerGui")
local _gameStatus = playerGui and playerGui:FindFirstChild("GameStatus")

local _white = _gameStatus and _gameStatus:FindFirstChild("White")
local _black = _gameStatus and _gameStatus:FindFirstChild("Black")


local function normalizeText(value)
    if type(value) ~= "string" then
        return ""
    end

    return string.lower(value):gsub("%s+", " ")
end


local function instanceContainsPlayerName(instance)
    if not instance then
        return false
    end

    local username = normalizeText(lplayer.Name)
    local robloxDisplayName = normalizeText(lplayer.DisplayName)
    local memoryDisplayName = normalizeText(displayName)

    local function matches(text)
        text = normalizeText(text)

        if text == "" then
            return false
        end

        if username ~= "" and string.find(text, username, 1, true) then
            return true
        end

        if robloxDisplayName ~= "" and string.find(text, robloxDisplayName, 1, true) then
            return true
        end

        if memoryDisplayName ~= "" and string.find(text, memoryDisplayName, 1, true) then
            return true
        end

        return false
    end

    local directTextOk, directText = pcall(function()
        return instance.Text
    end)

    if directTextOk and matches(directText) then
        return true
    end

    for _, descendant in ipairs(instance:GetDescendants()) do
        local textOk, text = pcall(function()
            return descendant.Text
        end)

        if textOk and matches(text) then
            return true
        end
    end

    return false
end


local function normalVisibleCheck(instance)
    if not instance then
        return false
    end

    local current = instance

    while current and current ~= playerGui do
        local visibleOk, visible = pcall(function()
            return current.Visible
        end)

        if visibleOk and visible == false then
            return false
        end

        local enabledOk, enabled = pcall(function()
            return current.Enabled
        end)

        if enabledOk and enabled == false then
            return false
        end

        current = current.Parent
    end

    return true
end


local function _isVisible(instance)
    if not instance then
        return false
    end

    -- Prefer Roblox's normal Visible property.
    local visibleOk, visible = pcall(function()
        return instance.Visible
    end)

    if visibleOk then
        return visible and normalVisibleCheck(instance)
    end

    -- Fall back to the memory offset only when normal properties
    -- cannot be read.
    if Offsets.FrameVisible then
        local memoryOk, memoryVisible = pcall(function()
            return memory_read(
                "byte",
                instance.Address + Offsets.FrameVisible
            )
        end)

        if memoryOk then
            return memoryVisible == 1
        end
    end

    return false
end


ffunction Board:getLocalTeam()
    local playerGui = lplayer:FindFirstChild("PlayerGui")
    if not playerGui then
        return nil
    end

    local names = {
        string.lower(lplayer.Name or ""),
        string.lower(lplayer.DisplayName or ""),
        string.lower(displayName or "")
    }

    local function containsPlayerName(text)
        if type(text) ~= "string" then
            return false
        end

        text = string.lower(text)

        for _, name in ipairs(names) do
            if name ~= "" and string.find(text, name, 1, true) then
                return true
            end
        end

        return false
    end

    for _, object in ipairs(playerGui:GetDescendants()) do
        local ok, text = pcall(function()
            return object.Text
        end)

        if ok and containsPlayerName(text) then
            local current = object

            while current and current ~= playerGui do
                local objectName = string.lower(current.Name)

                if objectName == "white" then
                    return "w"
                end

                if objectName == "black" then
                    return "b"
                end

                current = current.Parent
            end
        end
    end

    return nil
end


function Board:isPlayerTurn()
    local team = self:getLocalTeam()

    if not team then
        State.LastOutput = "Could not determine your team"
        return false
    end

    local frame = team == "w" and _white or _black

    if not frame then
        State.LastOutput = "Could not locate turn indicator"
        return false
    end

    return _isVisible(frame)
end


function Board:willCauseDesync()
    return not self:isPlayerTurn()
end

function Board:_scanBoard()
    local piecesFolder = Workspace:FindFirstChild("Pieces")
    if not piecesFolder then return nil end

    local tileCache = cachedTilePositions or cacheTilePositions()
    if not tileCache then return nil end

    local boardState = {}
    for x=1,8 do boardState[x] = {} end

    for _,piece in ipairs(piecesFolder:GetChildren()) do
        local pieceChar = PieceMap[piece.Name]
        if pieceChar then
            local piecePos = getPiecePosition(piece)
            local x,y = findTileForPiece(piecePos, tileCache)

            if x and y then
                local isWhite = false
                local primaryPart

                local ok1,res1 = pcall(function() return piece:FindFirstChildOfClass("MeshPart") end)
                if ok1 and res1 then primaryPart = res1 end

                if not primaryPart then
                    local ok2,res2 = pcall(function() return piece:FindFirstChildOfClass("Part") end)
                    if ok2 and res2 then primaryPart = res2 end
                end

                if primaryPart then
                    local colorOk,color = pcall(function() return primaryPart.Color end)
                    if colorOk and color then
                        local r,g,b = color.R, color.G, color.B
                        if r>1 or g>1 or b>1 then r,g,b = r/255, g/255, b/255 end
                        isWhite = (r+g+b)/3 > 0.5
                    end
                end

                boardState[x][y] = isWhite and string.upper(pieceChar) or pieceChar
            end
        end
    end

    return boardState
end

function Board:board2fen()
    local boardPieces = self:_scanBoard()
    if not boardPieces then return nil end

    local result = ""

    for y=8,1,-1 do
        local empty = 0
        for x=8,1,-1 do
            if not boardPieces[x] then boardPieces[x] = {} end
            local piece = boardPieces[x][y]

            if piece and piece ~= "" then
                if empty > 0 then
                    result = result .. tostring(empty)
                    empty = 0
                end
                result = result .. piece
            else
                empty = empty + 1
            end
        end

        if empty > 0 then result = result .. tostring(empty) end
        if y ~= 1 then result = result .. "/" end
    end

    result = result .. " " .. (self:getLocalTeam() or "w")
    return result
end

local function urlEncode(str)
    local encoded = ""
    for i=1,#str do
        local c = string.sub(str,i,i)
        local b = string.byte(c)
        if (b>=48 and b<=57) or (b>=65 and b<=90) or (b>=97 and b<=122)
        or c=="-" or c=="_" or c=="." or c=="~" then
            encoded = encoded .. c
        else
            encoded = encoded .. string.format("%%%02X", b)
        end
    end
    return encoded
end

local function getPosFromResult(result)
    local x1 = 9 - (string.byte(result,1) - 96)
    local y1 = tonumber(string.sub(result,2,2))
    local x2 = 9 - (string.byte(result,3) - 96)
    local y2 = tonumber(string.sub(result,4,4))
    return x1,y1,x2,y2
end

local Highlights = {}

local function destroyAllHighlights()
    for _,h in ipairs(Highlights) do
        pcall(function() h.circle:Remove() end)
    end
    Highlights = {}
end

local function highlightInstance(target)
    pcall(function()
        local pos = getPiecePosition(target) or getTilePosition(target)

        if not pos then
            local rawOk,rawPos = pcall(function() return target.Position end)
            if rawOk then pos = rawPos end
        end

        if not pos then return end

        local circle = Drawing.new("Circle")
        circle.Radius = 20
        circle.Color = Color3.fromRGB(59,235,223)
        circle.Thickness = 3
        circle.Filled = false
        circle.Visible = false

        table.insert(Highlights, { circle = circle, target = target, worldPos = pos })
    end)
end

local function updateHighlights()
    for _,h in ipairs(Highlights) do
        local pos = getPiecePosition(h.target) or getTilePosition(h.target) or h.worldPos
        local screenPos,onScreen = WorldToScreen(pos)
        h.circle.Visible = onScreen
        if onScreen then h.circle.Position = screenPos end
    end
end

local function getSearchHint()
    if EngineInfo.is_lc0 then
        local n = Config.Nodes
        if n >= 1000000 then
            return string.format("%.1fM nodes", n / 1000000)
        elseif n >= 1000 then
            return string.format("%gk nodes", n / 1000)
        end
        return tostring(n) .. " nodes"
    end
    return "depth " .. tostring(Config.Depth)
end

local function findBestMove(board)
    local team = board:getLocalTeam()

    if not team then
        return {false, "Could not determine your team"}
    end

    local fen = board:board2fen()
    if not fen then return {false,"Could not read board"} end

    local encodedFen = urlEncode(fen)
    local url

    if EngineInfo.is_lc0 then
        url = "http://127.0.0.1:3000/api/solve?fen=" .. encodedFen
            .. "&nodes=" .. tostring(Config.Nodes)
            .. "&max_think_time=" .. tostring(Config.ThinkTime)
            .. "&disregard_think_time=" .. tostring(Config.DisregardThinkTime)
    else
        url = "http://127.0.0.1:3000/api/solve?fen=" .. encodedFen
            .. "&depth=" .. tostring(Config.Depth)
            .. "&max_think_time=" .. tostring(Config.ThinkTime)
            .. "&disregard_think_time=" .. tostring(Config.DisregardThinkTime)
    end

    local ok,ret = pcall(function() return game:HttpGet(url) end)
    if not ok then return {false,"HttpGet failed: "..tostring(ret)} end
    if not ret or ret=="" then return {false,"Empty response from server"} end

    local success = ret:match('"success"%s*:%s*(true)')
    local result  = ret:match('"result"%s*:%s*"([^"]+)"')

    if not success then
        return {false, result or "Unknown error"}
    end

    if not result then return {false,"No result in response"} end

    local x1,y1,x2,y2 = getPosFromResult(result)

    local pieceToMove = Board.getPiece(tostring(x1)..","..tostring(y1))
    if not pieceToMove then return {false,"No piece to move"} end

    local boardFolder = Workspace:FindFirstChild("Board")
    local placeToMove = boardFolder and boardFolder:FindFirstChild(tostring(x2)..","..tostring(y2))
    if not placeToMove then return {false,"No place to move to"} end

    return {true, result, pieceToMove, placeToMove}
end

local board = Board.new()

local function runBestMove()
    State.Status = "Calculating"
    State.LastOutput = getSearchHint()

    local output = findBestMove(board)

    if output[1] == false then
        State.Status = "Error!"
        State.LastOutput = tostring(output[2])

        task.spawn(function()
            task.wait(2.5)
            if State.Status == "Error!" then State.Status = "Idle" end
        end)

        return
    end

    destroyAllHighlights()
    highlightInstance(output[3])
    highlightInstance(output[4])

    State.Status = "Idle"
    State.LastOutput = "Best: "..tostring(output[2])

    task.spawn(function()
        while board:isPlayerTurn() do task.wait() end
        destroyAllHighlights()
    end)
end

destroyAllHighlights()

do
    local ok = fetchEngineInfo()
    if not ok then
        State.Status = "No Server"
    else
        State.Status = "Idle"
    end
end

local function getStatusText()
    return "Status: "..State.Status
end

local function getEngineText()
    return "Engine: "..EngineInfo.name
end

local function getOutputText()
    if #State.LastOutput > 0 then return State.LastOutput end
    return nil
end

local myGui = UILib.new("Chess", Vector2.new(320,380), {getStatusText, getEngineText, getOutputText})

local engineTab = myGui:Tab("Engine")
local settingsSection = myGui:Section(engineTab,"Settings")

if EngineInfo.is_lc0 then
    Config.Nodes = 17000
    myGui:Input(engineTab, settingsSection, "Nodes", Config.Nodes, function(value)
        Config.Nodes = math.max(1, math.floor(value))
    end, "e.g. 17000", 7, true)
else
    Config.Depth = 17
    myGui:Slider(engineTab, settingsSection, "Depth", Config.Depth, function(value)
        Config.Depth = value
    end, 1, 30, 1, "")
end

myGui:Slider(engineTab, settingsSection, "Think Time", Config.ThinkTime, function(value)
    Config.ThinkTime = value
end, 10, 5000, 10, "ms")

myGui:Checkbox(engineTab, settingsSection, "Disregard Time", Config.DisregardThinkTime, function(state)
    Config.DisregardThinkTime = state
end)

local controlsSection = myGui:Section(engineTab,"Controls")

myGui:Button(engineTab, controlsSection, "Calculate", function()
    task.spawn(runBestMove)
end)

myGui:Keybind(engineTab, controlsSection, "Calc Key", "r", function(state)
    if state then task.spawn(runBestMove) end
end, "Hold")

myGui:Checkbox(engineTab, controlsSection, "Unload", false, function(state)
    if state then State.Running = false end
end)

myGui:CreateSettingsTab()

if State.Status == "No Server" then
    notify("Could not reach server. Make sure server.py is running!", "Server Error", 8)
else
    local engineLabel = EngineInfo.is_lc0
        and "Lc0 loaded! Default: 17000 nodes"
        or  "Stockfish loaded! Default: depth 17"
    notify(engineLabel, "Chess Script", 5)
end

while State.Running do
    updateHighlights()
    myGui:Step()
    wait(0.0015)
end

destroyAllHighlights()
myGui:Destroy()
