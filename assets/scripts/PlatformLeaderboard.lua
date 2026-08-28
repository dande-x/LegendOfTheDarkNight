---@diagnostic disable: undefined-global, param-type-mismatch, assign-type-mismatch
-- ============================================================================
-- PlatformLeaderboard.lua — 暗夜传奇平台排行榜
-- 客户端模式使用 clientCloud iscores：等级、累计击杀、金币。
-- 本地没有平台云服务时保持静默降级，不影响离线/预览流程。
-- ============================================================================

local PlatformLeaderboard = {}

local MAX_SCORE = 1000000000
local TOP_COUNT = 20

local BOARDS = {
    { id = "level", key = "night_legend_level", label = "等级", valueLabel = "等级" },
    { id = "monster_kills", key = "night_legend_monster_kills", label = "消灭怪物", valueLabel = "击杀" },
    { id = "gold", key = "night_legend_gold", label = "金币", valueLabel = "金币" },
}

local BOARD_BY_ID = {}
for _, board in ipairs(BOARDS) do
    BOARD_BY_ID[board.id] = board
end

local lastSuccessfulScores = nil
local inFlight = false
local inFlightScores = nil
local queuedScores = nil
local inFlightWaiters = {}
local queuedWaiters = {}

local function safeCall(fn, ...)
    if type(fn) ~= "function" then return end
    pcall(fn, ...)
end

local function getMethod(object, name)
    if object == nil then return nil end
    local ok, method = pcall(function() return object[name] end)
    if not ok or type(method) ~= "function" then return nil end
    return method
end

local function getClientCloud()
    local cloud = clientCloud
    if cloud == nil then return nil end
    if not getMethod(cloud, "BatchSet") then return nil end
    return cloud
end

local function normalizeScore(value)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then
        return 0
    end
    return math.max(0, math.min(MAX_SCORE, math.floor(number)))
end

local function normalizeScores(scores)
    local result = {}
    scores = type(scores) == "table" and scores or {}
    for _, board in ipairs(BOARDS) do
        result[board.id] = normalizeScore(scores[board.id] ~= nil
            and scores[board.id] or scores[board.key])
    end
    return result
end

local function scoresEqual(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    for _, board in ipairs(BOARDS) do
        if normalizeScore(left[board.id]) ~= normalizeScore(right[board.id]) then
            return false
        end
    end
    return true
end

local function copyScores(scores)
    local result = {}
    for _, board in ipairs(BOARDS) do
        result[board.id] = normalizeScore(scores and scores[board.id])
    end
    return result
end

local function notifyWaiters(waiters, success, scores, code, reason, skipped)
    for _, callbacks in ipairs(waiters or {}) do
        if success then
            safeCall(callbacks.ok, scores, skipped == true)
        else
            safeCall(callbacks.error, code, reason)
        end
    end
end

local function flushQueuedSync()
    if inFlight or not queuedScores then return end
    local scores = queuedScores
    local waiters = queuedWaiters
    queuedScores = nil
    queuedWaiters = {}
    if lastSuccessfulScores and scoresEqual(lastSuccessfulScores, scores) then
        notifyWaiters(waiters, true, scores, nil, nil, true)
        return
    end
    PlatformLeaderboard._StartSync(scores, waiters)
end

function PlatformLeaderboard.GetBoards()
    local result = {}
    for i, board in ipairs(BOARDS) do
        result[i] = {
            id = board.id,
            key = board.key,
            label = board.label,
            valueLabel = board.valueLabel,
        }
    end
    return result
end

function PlatformLeaderboard.IsAvailable()
    local cloud = getClientCloud()
    return cloud ~= nil
        and getMethod(cloud, "GetRankList") ~= nil
        and getMethod(cloud, "GetUserRank") ~= nil
end

local function finishSync(success, scores, waiters, code, reason)
    inFlight = false
    inFlightScores = nil
    inFlightWaiters = {}
    if success then lastSuccessfulScores = copyScores(scores) end
    notifyWaiters(waiters, success, scores, code, reason, false)
    flushQueuedSync()
end

function PlatformLeaderboard._StartSync(scores, waiters)
    local cloud = getClientCloud()
    if not cloud then
        notifyWaiters(waiters, false, scores, "unavailable", "平台排行榜暂不可用")
        return false
    end
    inFlight = true
    inFlightScores = copyScores(scores)
    inFlightWaiters = waiters
    local completed = false
    local function finishOnce(success, code, reason)
        if completed then return end
        completed = true
        finishSync(success, scores, waiters, code, reason)
    end
    local ok, err = pcall(function()
        local batch = cloud:BatchSet()
        if not batch then error("BatchSet returned nil") end
        for _, board in ipairs(BOARDS) do
            batch = batch:SetInt(board.key, scores[board.id])
            if not batch then error("SetInt returned nil for " .. board.key) end
        end
        batch:Save("暗夜传奇排行榜", {
            ok = function() finishOnce(true) end,
            error = function(code, reason)
                finishOnce(false, code, reason or "平台排行榜保存失败")
            end,
            timeout = function() finishOnce(false, "timeout", "平台排行榜保存超时") end,
        })
    end)
    if not ok then
        finishOnce(false, "exception", tostring(err))
        return false
    end
    return true
end

function PlatformLeaderboard.Sync(scores, callbacks)
    local normalized = normalizeScores(scores)
    callbacks = type(callbacks) == "table" and callbacks or {}
    if not getClientCloud() then
        safeCall(callbacks.error, "unavailable", "平台排行榜暂不可用")
        return false
    end
    if inFlight then
        if inFlightScores and scoresEqual(inFlightScores, normalized)
            and not queuedScores then
            table.insert(inFlightWaiters, callbacks)
            return true
        end
        queuedScores = normalized
        table.insert(queuedWaiters, callbacks)
        return true
    end
    if queuedScores then
        queuedScores = normalized
        table.insert(queuedWaiters, callbacks)
        return true
    end
    if lastSuccessfulScores and scoresEqual(lastSuccessfulScores, normalized) then
        safeCall(callbacks.ok, normalized, true)
        return true
    end
    return PlatformLeaderboard._StartSync(normalized, { callbacks })
end

local function getCurrentUserId(cloud)
    local ok, userId = pcall(function() return cloud.userId end)
    if ok and userId ~= nil then return userId end
    local lobbyObject = lobby
    local getMyUserId = getMethod(lobbyObject, "GetMyUserId")
    if getMyUserId then
        local lobbyOk, lobbyUserId = pcall(function() return lobbyObject:GetMyUserId() end)
        if lobbyOk then return lobbyUserId end
    end
    return nil
end

local function getScoreFromItem(item, board)
    if type(item) ~= "table" then return 0 end
    local iscore = type(item.iscore) == "table" and item.iscore or {}
    return normalizeScore(iscore[board.key] ~= nil and iscore[board.key] or iscore[board.id])
end

local function getItemUserId(item)
    if type(item) ~= "table" then return nil end
    return item.userId ~= nil and item.userId or item.player
end

local function queryNicknameMap(userIds, onDone)
    local map = {}
    if #userIds == 0 or type(GetUserNickname) ~= "function" then onDone(map); return end
    local completed = false
    local function finish(result)
        if completed then return end
        completed = true
        if type(result) == "table" then
            for _, info in ipairs(result) do
                if type(info) == "table" and info.userId ~= nil then
                    map[tostring(info.userId)] = tostring(info.nickname or "")
                end
            end
        end
        onDone(map)
    end
    local ok, err = pcall(function()
        GetUserNickname {
            userIds = userIds,
            onSuccess = finish,
            onError = function() finish(nil) end,
        }
    end)
    if not ok then
        print("[PlatformLeaderboard] nickname query failed: " .. tostring(err))
        finish(nil)
    end
end

local function queryUserRank(cloud, userId, board, onDone)
    if userId == nil or not getMethod(cloud, "GetUserRank") then onDone(nil, nil); return end
    local completed = false
    local function finish(rank, score)
        if completed then return end
        completed = true
        onDone(tonumber(rank), normalizeScore(score))
    end
    local ok, err = pcall(function()
        cloud:GetUserRank(userId, board.key, {
            ok = finish,
            error = function() finish(nil, nil) end,
            timeout = function() finish(nil, nil) end,
        })
    end)
    if not ok then
        print("[PlatformLeaderboard] user rank query failed: " .. tostring(err))
        finish(nil, nil)
    end
end

function PlatformLeaderboard.Fetch(boardId, topN, callback)
    callback = type(callback) == "function" and callback or function() end
    local board = BOARD_BY_ID[boardId] or BOARD_BY_ID.level
    local cloud = getClientCloud()
    if not cloud or not getMethod(cloud, "GetRankList") then
        callback(false, { code = "unavailable", reason = "平台排行榜暂不可用" })
        return false
    end
    local count = math.max(1, math.min(100, math.floor(tonumber(topN) or TOP_COUNT)))
    local completed = false
    local function finish(success, payload)
        if completed then return end
        completed = true
        callback(success, payload)
    end
    local function processRankList(rankList)
        local entries, userIds, seenUsers = {}, {}, {}
        local list = type(rankList) == "table" and rankList or {}
        local currentUserId = getCurrentUserId(cloud)
        local currentUserKey = currentUserId ~= nil and tostring(currentUserId) or nil
        for index, item in ipairs(list) do
            local userId = getItemUserId(item)
            local userKey = userId ~= nil and tostring(userId) or ("unknown_" .. tostring(index))
            table.insert(entries, {
                rank = index,
                userId = userId,
                nickname = "玩家 " .. userKey,
                score = getScoreFromItem(item, board),
                isMe = currentUserKey ~= nil and userKey == currentUserKey,
            })
            if userId ~= nil and not seenUsers[userKey] then
                seenUsers[userKey] = true
                table.insert(userIds, userId)
            end
        end
        queryNicknameMap(userIds, function(nicknameMap)
            for _, entry in ipairs(entries) do
                local key = entry.userId ~= nil and tostring(entry.userId) or nil
                if key and nicknameMap[key] and nicknameMap[key] ~= "" then entry.nickname = nicknameMap[key] end
            end
            queryUserRank(cloud, currentUserId, board, function(myRank, myScore)
                finish(true, {
                    board = { id = board.id, key = board.key, label = board.label, valueLabel = board.valueLabel },
                    entries = entries,
                    myRank = myRank,
                    myScore = myScore,
                })
            end)
        end)
    end
    local ok, err = pcall(function()
        cloud:GetRankList(board.key, 0, count, {
            ok = processRankList,
            error = function(code, reason) finish(false, { code = code, reason = reason or "排行榜加载失败" }) end,
            timeout = function() finish(false, { code = "timeout", reason = "排行榜加载超时" }) end,
        })
    end)
    if not ok then
        finish(false, { code = "exception", reason = tostring(err) })
        return false
    end
    return true
end

PlatformLeaderboard.TOP_COUNT = TOP_COUNT
PlatformLeaderboard.BOARDS = PlatformLeaderboard.GetBoards()

return PlatformLeaderboard
