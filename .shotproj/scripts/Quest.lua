-- ============================================================================
-- Quest.lua — 暗夜传奇 主线任务系统
--
-- 致敬盛大《热血传奇》，主线按「三幕 + 终章」组织。地图始终按自己的
-- 自然怪物池刷新；任务只描述玩家要完成的行为，不再修改地图刷怪候选。
--
-- 任务模式：
--   clear      —— 在目标地图清理任意敌人
--   patrol     —— 依次到达少量已有地标
--   survive    —— 在指定区域累计坚守时间；离图或死亡时只暂停
--   encounter  —— 在地标触发显式精英/Boss 遭遇
--
-- 设计原则（反「流水账刷怪」）：
--   - 普通任务不向地图刷怪池注入“任务怪”，地图始终只有一套自然生态
--   - 四种轻量模式分散到整条主线，不给每章堆叠独立复杂机制
--   - 每幕最后一个任务是 encounter，作为章节情感高潮
--   - 任务名与 desc 承载剧情反转，驱动玩家「为什么而战」
--   - 奖励 = 经验 + 金币（装备奖励字段预留，由经济系统分支接入）
-- ============================================================================

local Quest = {}

-- 坚守类任务统一使用 50 秒；波次按“已坚守时间”触发，而不是按现实时间，
-- 这样离开区域、死亡、暂停和读档都不会偷偷消耗波次间隔。
local SURVIVE_DURATION = 50
local SURVIVE_WAVE_INTERVAL = 10
Quest.SURVIVE_DURATION = SURVIVE_DURATION
Quest.SURVIVE_WAVE_INTERVAL = SURVIVE_WAVE_INTERVAL

-- ============================================================================
-- 主线任务链（按策划案三幕 + 终章）
-- ============================================================================
Quest.CHAIN = {
    -- ============ 第一幕「边城烽火」（比奇省·银杏山谷，Lv1~9）============
    {
        id = "q_001", name = "初入荒原", chapter = "第一幕 · 边城烽火",
        mode = "clear", mapId = "map_bq", count = 5, legacyCount = 5,
        desc = "村庄被半兽人夜袭焚毁。清理附近游荡的威胁，让幸存的村民重返家园。",
        rewardExp = 100, rewardGold = 50,
        dialogues = {
            { speaker = "旁白", text = "那一夜，半兽人的火把照亮了整片银杏山谷。" },
            { speaker = "师父", text = "快走！带着这把乌木剑，去盟重……找……真相……" },
            { speaker = "旁白", text = "师父倒在了你怀里，手里还紧紧攥着这把剑。" },
            { speaker = "你", text = "我会回来。我会让它们血债血偿。" },
            { speaker = "旁白", text = "村庄已成废墟。清理附近游荡的怪物，让幸存者重返家园。" },
        },
    },
    {
        id = "q_002", name = "幽影来袭", chapter = "第一幕 · 边城烽火",
        mode = "patrol", mapId = "map_bq", count = 2, legacyCount = 6,
        points = {
            { name = "荒村废墟", x = -30, z = -22, radius = 6 },
            { name = "断桥", x = 15, z = 12, radius = 6 },
        },
        desc = "沿荒村与断桥巡查幽影留下的痕迹，找出它们被驱使的方向。",
        rewardExp = 280, rewardGold = 80,
        dialogues = {
            { speaker = "村民", text = "那些幽影……夜夜在村口徘徊，像是认得回家的路。" },
            { speaker = "你", text = "它们是被夜袭害死的村民。有人在用邪术囚禁亡魂。" },
        },
    },
    {
        id = "q_003", name = "骷髅军团", chapter = "第一幕 · 边城烽火",
        mode = "clear", mapId = "map_bq", count = 8, legacyCount = 8,
        desc = "夜袭的尸骨竟从泥土里爬了起来。边清理周边威胁，边寻找操控亡者的线索。",
        rewardExp = 200, rewardGold = 120,
        dialogues = {
            { speaker = "旁白", text = "你挖开夜袭留下的埋尸坑，里面的尸骨竟在微微颤动。" },
            { speaker = "神秘商人", text = "小伙子，有人在比奇城里替半兽人开了门。查查城门，你会明白的。" },
        },
    },
    {
        id = "q_004", name = "半兽人先锋", chapter = "第一幕 · 边城烽火",
        mode = "survive", mapId = "map_bq", count = 50, legacyCount = 10,
        area = { name = "断桥", x = 15, z = 12, radius = 9 },
        desc = "敌人正有组织地穿过断桥。守住桥头，阻止它们继续向城门推进。",
        rewardExp = 690, rewardGold = 180,
        dialogues = {
            { speaker = "旁白", text = "半兽人的先锋队排着整齐的队形，这绝不是野兽能做出来的事。" },
            { speaker = "你", text = "有内奸。它们对我们的布防了如指掌。" },
        },
    },
    {
        id = "q_005", name = "蛛穴之影", chapter = "第一幕 · 边城烽火",
        mode = "clear", mapId = "map_bq", count = 10, legacyCount = 10,
        desc = "追杀溃逃的兽兵时，你撞进了毒蛛巢穴。清开退路，别被困在里面。",
        rewardExp = 350, rewardGold = 260,
        dialogues = {
            { speaker = "旁白", text = "你追着溃逃的兽兵，一路追进了城外的蛛穴。" },
            { speaker = "你", text = "这些毒蛛……是被故意放养在这里，堵住追兵的。" },
        },
    },
    {
        id = "q_006", name = "边城守卫战", chapter = "第一幕 · 边城烽火",
        mode = "encounter", mapId = "map_bq", target = "半兽勇士", count = 1, legacyCount = 1,
        encounter = { name = "荒村废墟", x = -30, z = -22 },
        desc = "真相大白——你曾最信任的守卫队长，正是为半兽人打开城门的叛徒。",
        rewardExp = 500, rewardGold = 800,
        dialogues = {
            { speaker = "守卫队长", text = "没想到是你活了下来。" },
            { speaker = "守卫队长", text = "不错，是我开的门。半兽人答应我，事成之后，比奇城归我。" },
            { speaker = "你", text = "师父的命，全村人的命，就为了一个城主的位子？" },
            { speaker = "守卫队长", text = "杀了我，也改变不了什么。半兽勇士已经压境了！" },
            { speaker = "旁白", text = "城门洞开，半兽勇士率军冲入。这是你第一次，直面真正的战场。" },
        },
    },

    -- ============ 第二幕「黄沙盟重」（盟重土城，Lv10~24）============
    {
        id = "q_007", name = "野狼出没", chapter = "第二幕 · 黄沙盟重",
        mode = "patrol", mapId = "map_mz", count = 2, legacyCount = 12,
        points = {
            { name = "黄沙商路", x = -34, z = -9, radius = 7 },
            { name = "北城残垣", x = 0, z = 40, radius = 7 },
        },
        desc = "黄沙之城的商路被截断。沿商路巡查到北城残垣，替商队探明通路。",
        rewardExp = 5050, rewardGold = 900,
        dialogues = {
            { speaker = "旁白", text = "你循着师父的遗言，一路西行，来到了黄沙深处的盟重土城。" },
            { speaker = "商队头领", text = "城外狼群越聚越多，商路快断了。帮我们清一条路出来。" },
        },
    },
    {
        id = "q_008", name = "石魔之心", chapter = "第二幕 · 黄沙盟重",
        mode = "clear", mapId = "map_mz", count = 10, legacyCount = 10,
        desc = "荒漠深处的魔物被唤醒。清理石墓周边，从战场痕迹中寻找古老符文。",
        rewardExp = 5200, rewardGold = 1200,
        dialogues = {
            { speaker = "旁白", text = "土城东郊的石墓（猪洞）传来异动。传闻有白野猪作乱。" },
            { speaker = "你", text = "石魔心脏上的符文……和比奇城见到的一模一样。" },
        },
    },
    {
        id = "q_009", name = "猪洞之影", chapter = "第二幕 · 黄沙盟重",
        mode = "encounter", mapId = "map_mz", target = "白野猪", count = 1, legacyCount = 1,
        encounter = { name = "石墓入口", x = 30, z = 20 },
        desc = "城主竟被掉了包！猪洞的骚乱只是调虎离山。杀入石墓，夺回城主信物。",
        rewardExp = 7000, rewardGold = 1500,
        dialogues = {
            { speaker = "旁白", text = "你终于见到了城主，却发现——他的眼神，不对。" },
            { speaker = "假城主", text = "真正的城主被我关在猪洞深处。而你，也一起留下吧！" },
            { speaker = "旁白", text = "石墓（猪洞）深处传来闷雷般的咆哮。白野猪撞碎石门，冲了出来！" },
            { speaker = "旁白", text = "假城主现出原形。守住土城，夺回城主信物！" },
        },
    },

    -- ============ 第三幕「怒海寻踪」（水上城市，Lv25~34）============
    {
        id = "q_010", name = "将军之骨", chapter = "第三幕 · 怒海寻踪",
        mode = "clear", mapId = "map_sc", count = 10, legacyCount = 10,
        desc = "海上迷城的水域飘来无数骸骨。清理航道，追查它们朝拜的方向。",
        rewardExp = 4800, rewardGold = 1800,
        dialogues = {
            { speaker = "旁白", text = "你循线索来到水上城市——一座建在海域上的贸易城。" },
            { speaker = "故交", text = "你师父……他本是沃玛寺庙的守门人。当年的事，远比你想象的复杂。" },
        },
    },
    {
        id = "q_011", name = "熔火之门", chapter = "第三幕 · 怒海寻踪",
        mode = "survive", mapId = "map_sc", count = 50, legacyCount = 10,
        area = { name = "灯塔", x = 0, z = 38, radius = 9 },
        desc = "水城的航路被熔火封锁。守住灯塔，让城中的船只完成撤离。",
        -- 坚守延长到 50 秒后会多经历约 10 只同期怪；下调任务本体经验，
        -- 保持第三幕结束仍落在既定 Lv35 阶段，而不是提前溢出到下一档。
        rewardExp = 5300, rewardGold = 2400,
        dialogues = {
            { speaker = "旁白", text = "海底的熔火并非自然异变，焦黑岩壁上残留着熟悉的黑暗符文。" },
            { speaker = "你", text = "这股力量和师父封印中的一模一样。真正的幕后之物，就在前方。" },
        },
    },
    {
        id = "q_012", name = "蛇窟", chapter = "第三幕 · 怒海寻踪",
        mode = "patrol", mapId = "map_sc", count = 3, legacyCount = 12,
        points = {
            { name = "灯塔", x = 0, z = 38, radius = 7 },
            { name = "西水道", x = -30, z = 0, radius = 7 },
            { name = "蚁穴入口", x = 30, z = -26, radius = 7 },
        },
        desc = "从灯塔穿过西水道，找到通往蚁穴深处的入口。",
        rewardExp = 8350, rewardGold = 3000,
        dialogues = {
            { speaker = "故交", text = "你师父当年并非战死。他是自愿献祭，封印沃玛教主。" },
            { speaker = "你", text = "……所以，他骗了我。他让我来找的，是他自己的死亡。" },
        },
    },
    {
        id = "q_012b", name = "蚁后之渊", chapter = "第三幕 · 怒海寻踪",
        mode = "encounter", mapId = "map_sc", target = "蚁后", count = 1, legacyCount = 1,
        encounter = { name = "蚁穴入口", x = 30, z = -26 },
        desc = "水城的蚁患背后，是沃玛教主的黑暗力量。击败蚁后，夺回进入沃玛寺庙的通行证。",
        rewardExp = 4600, rewardGold = 4000,
        dialogues = {
            { speaker = "旁白", text = "水城蚁患肆虐，整片海域的航路都被蚁群吞噬。" },
            { speaker = "故交", text = "蚁后不是元凶，它只是被沃玛教主的黑暗力量驱使。" },
            { speaker = "你", text = "为了水城，也为了拿到进入沃玛寺庙的通行证——必须击破蚁后！" },
        },
    },

    -- ============ 终章「屠龙之战」（沃玛 Lv35~44 → 祖玛 Lv45~50）============
    {
        id = "q_013", name = "噬魂之潮", chapter = "终章 · 屠龙之战",
        mode = "clear", mapId = "map_wm", count = 12, legacyCount = 12,
        desc = "真相的尽头是更大的黑暗。清理寺庙外围，为深入封印打开道路。",
        rewardExp = 10750, rewardGold = 3600,
        dialogues = {
            { speaker = "旁白", text = "你带着对师父的真正敬意，踏入沃玛寺庙。" },
            { speaker = "你", text = "师父，我来完成你未竟的事。" },
        },
    },
    {
        id = "q_014", name = "麒麟试炼", chapter = "终章 · 屠龙之战",
        mode = "patrol", mapId = "map_wm", count = 3, legacyCount = 10,
        points = {
            { name = "石柱廊", x = -12, z = -22, radius = 7 },
            { name = "封印祭坛", x = 0, z = 18, radius = 7 },
            { name = "教主殿", x = 30, z = -28, radius = 7 },
        },
        desc = "循着屠龙宝刀残片的共鸣，穿过石柱廊与封印祭坛，抵达教主殿。",
        rewardExp = 13440, rewardGold = 4500,
        dialogues = {
            { speaker = "旁白", text = "屠龙宝刀散落大陆。要打开祖玛封印，必须集齐残片。" },
            { speaker = "你", text = "牛魔王也盯上了残片。绝不能让它先得手。" },
        },
    },
    {
        id = "q_014b", name = "沃玛教主", chapter = "终章 · 屠龙之战",
        mode = "encounter", mapId = "map_wm", target = "沃玛教主", count = 1, legacyCount = 1,
        encounter = { name = "教主殿", x = 30, z = -28 },
        desc = "沃玛寺庙深处，沃玛教主祭起黑暗法阵。击败它，夺回通往祖玛的钥匙。",
        rewardExp = 14000, rewardGold = 7000,
        dialogues = {
            { speaker = "旁白", text = "沃玛寺庙深处，师父当年封印的黑暗，终于现出真身。" },
            { speaker = "沃玛教主", text = "守门人的徒弟？你和他一样，都将葬身于此！" },
            { speaker = "你", text = "师父没能彻底消灭你。今天，我来替他完成。" },
        },
    },
    {
        id = "q_015", name = "熔火龙巢", chapter = "终章 · 屠龙之战",
        mode = "encounter", mapId = "map_zm", target = "火龙王", count = 1, legacyCount = 1,
        encounter = { name = "熔火龙巢", x = 0, z = -32 },
        desc = "祖玛寺庙深处，火龙王在熔火龙巢中巡猎，守护着最后的封印。",
        rewardExp = 10000, rewardGold = 8000,
        dialogues = {
            { speaker = "旁白", text = "祖玛寺庙深处，火龙王在熔岩深渊中缓缓睁开眼。" },
            { speaker = "旁白", text = "这是最后的守护。屠龙宝刀在此觉醒。" },
        },
    },
    {
        id = "q_016", name = "深渊领主", chapter = "终章 · 屠龙之战",
        mode = "encounter", mapId = "map_zm", target = "牛魔王", count = 1, legacyCount = 1,
        encounter = { name = "深渊王座", x = 30, z = 26 },
        desc = "祖玛封印撑过了熔岩冲击，却仍在崩解。牛魔王正从深渊王座踏入人间。",
        rewardExp = 15000, rewardGold = 15000,
        dialogues = {
            { speaker = "旁白", text = "祖玛寺庙最深处，牛魔王挡住了你的去路。" },
            { speaker = "牛魔王", text = "渺小的凡人，也敢踏足祖玛圣地！" },
            { speaker = "旁白", text = "用屠龙宝刀，斩断这场延续百年的战争。让玛法大陆，重归和平。" },
        },
        completionDialogues = {
            { speaker = "旁白", text = "屠龙划过深渊，牛魔王的怒吼终于沉入熔岩之下。" },
            { speaker = "师父", text = "你没有替我复仇。你替这片大陆，结束了仇恨。" },
            { speaker = "你", text = "天亮了。该回比奇看看了。" },
            { speaker = "旁白", text = "百年长夜就此落幕，而玛法大陆的新传奇，才刚刚开始。" },
        },
    },
}

-- ============================================================================
-- 运行时状态
-- ============================================================================
local QUEST_SAVE_VERSION = 2
Quest.SAVE_VERSION = QUEST_SAVE_VERSION

local state = {
    questIndex = 1,   -- 当前任务在 CHAIN 中的下标（1 起始）
    progress = 0,     -- 当前模式的数值进度
    modeState = {},   -- 当前模式的可持久化状态（只保存纯数据）
    finished = false, -- 是否已通关全部主线
    dialogueRead = {}, -- 已看过的任务开场对话，避免读档重复播放
    endingSeen = false, -- 最终 Boss 尾声是否完整播放
    lastNotifiedProgress = -1,
    -- 以下状态不单独持久化：是否已触发首波可由 progress 推导，波次索引也
    -- 由已保存的坚守秒数推导，避免为一次性演出再引入第二套存档真源。
    areaActive = false,
    areaTriggered = false,
    surviveWaveIndex = 0,
}

-- 外部回调（由 main.lua 注册）
Quest.onQuestComplete = nil   -- function(quest) 任务完成时触发（发放奖励）
Quest.onProgressUpdate = nil  -- function(quest, progress, count) 进度变化时触发（刷新 HUD）
Quest.onQuestStart = nil      -- function(quest) 任务开始时触发（播放剧情对话）
Quest.onObjectiveReached = nil -- function(quest, point, progress) 巡逻点首次到达
Quest.onAreaStateChanged = nil -- function(quest, active, area, firstActivation) 坚守区域状态
Quest.onSurviveWave = nil      -- function(quest, waveIndex, area) 坚守波次触发

-- ============================================================================
-- 查询接口
-- ============================================================================

local function IsFiniteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function Clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, value))
end

local function ResolveQuest(quest)
    if type(quest) == "table" then return quest end
    if type(quest) ~= "string" then return nil end
    for _, item in ipairs(Quest.CHAIN) do
        if item.id == quest then return item end
    end
    return nil
end

local function CopyModeState(source)
    local copy = {}
    if type(source) ~= "table" then return copy end
    for key, value in pairs(source) do
        if type(value) == "number" or type(value) == "string" or type(value) == "boolean" then
            copy[key] = value
        end
    end
    return copy
end

local function SyncModeState(quest)
    local modeState = {}
    if quest then
        if quest.mode == "clear" then
            modeState.kills = math.floor(state.progress)
        elseif quest.mode == "patrol" then
            modeState.step = math.floor(state.progress)
        elseif quest.mode == "survive" then
            modeState.seconds = state.progress
        elseif quest.mode == "encounter" then
            modeState.defeated = state.progress >= quest.count
        end
    end
    state.modeState = modeState
end

local function SetProgress(quest, value)
    local count = math.max(1, tonumber(quest and quest.count) or 1)
    local progress = IsFiniteNumber(value) and Clamp(value, 0, count) or 0
    if quest and quest.mode ~= "survive" then progress = math.floor(progress) end
    state.progress = progress
    SyncModeState(quest)
end

-- 任务切换/读档时重置一次性区域演出的运行时状态。首波是否已经触发由
-- 坚守秒数推导，已保存的旧版本也能自然续接，不会因为升级代码而重复刷首波。
local function ResetObjectiveRuntimeState(quest, progress)
    state.areaActive = false
    state.areaTriggered = quest and quest.mode == "survive"
        and (tonumber(progress) or 0) > 0 or false
    if quest and quest.mode == "survive" then
        local safeProgress = math.max(0, tonumber(progress) or 0)
        state.surviveWaveIndex = math.floor(safeProgress / SURVIVE_WAVE_INTERVAL)
    else
        state.surviveWaveIndex = 0
    end
end

--- 当前任务（nil 表示全部完成）
function Quest.GetCurrent()
    if state.finished then return nil end
    return Quest.CHAIN[state.questIndex]
end

--- 是否已通关
function Quest.IsFinished()
    return state.finished
end

--- 当前进度 / 目标数
function Quest.GetProgress()
    local q = Quest.GetCurrent()
    if not q then return 0, 0 end
    return math.floor(state.progress), q.count
end

--- 获取任务目标所在地图。地图直接写在任务定义中，避免双重真源。
---@param quest table|string|nil 任务对象或任务 id
---@return string|nil mapId
function Quest.GetTargetMapId(quest)
    local resolved = ResolveQuest(quest)
    return resolved and resolved.mapId or nil
end

--- 返回可直接用于 HUD 的当前目标文案。
---@param quest table|nil
---@param progress number|nil
---@param count number|nil
---@return string
function Quest.GetObjectiveText(quest, progress, count)
    if not quest then return "主线已完成" end
    local currentProgress = math.floor(tonumber(progress) or state.progress or 0)
    local targetCount = math.max(1, math.floor(tonumber(count) or quest.count or 1))

    if quest.mode == "clear" then
        return "清理当前区域威胁 " .. currentProgress .. "/" .. targetCount
    elseif quest.mode == "patrol" then
        local nextPoint = quest.points and quest.points[currentProgress + 1] or nil
        if nextPoint then
            return "巡查：" .. nextPoint.name .. " " .. currentProgress .. "/" .. targetCount
        end
        return "巡查完成 " .. currentProgress .. "/" .. targetCount
    elseif quest.mode == "survive" then
        local areaName = quest.area and quest.area.name or "目标区域"
        return "坚守" .. areaName .. " " .. currentProgress .. "/" .. targetCount .. "秒"
    elseif quest.mode == "encounter" then
        return "击败" .. tostring(quest.target or "遭遇首领") .. " " .. currentProgress .. "/" .. targetCount
    end
    return quest.name or "任务目标"
end

--- 获取当前目标的小地图标记。clear 没有单点目标，其余模式返回纯坐标数据。
---@param quest table|nil
---@return table|nil
function Quest.GetObjectiveMarker(quest)
    quest = quest or Quest.GetCurrent()
    if not quest then return nil end

    local source = nil
    if quest.mode == "patrol" then
        source = quest.points and quest.points[math.floor(state.progress) + 1] or nil
    elseif quest.mode == "survive" then
        source = quest.area
    elseif quest.mode == "encounter" then
        source = quest.encounter
    end
    if not source then return nil end

    return {
        questId = quest.id,
        mode = quest.mode,
        mapId = quest.mapId,
        name = source.name or quest.target or quest.name,
        x = tonumber(source.x) or 0,
        z = tonumber(source.z) or 0,
        radius = tonumber(source.radius) or 0,
    }
end

--- 返回当前显式遭遇请求；Combat 只消费该通用数据，不反向依赖 Quest。
---@return table|nil
function Quest.GetEncounterRequest()
    local quest = Quest.GetCurrent()
    if not quest or quest.mode ~= "encounter" or state.progress >= quest.count then return nil end
    local location = quest.encounter or {}
    return {
        id = quest.id,
        mapId = quest.mapId,
        enemyName = quest.target,
        x = tonumber(location.x) or 0,
        z = tonumber(location.z) or 0,
    }
end

---@param quest table|nil
---@param mapId string|nil
---@return boolean
function Quest.IsOnTargetMap(quest, mapId)
    local targetMapId = Quest.GetTargetMapId(quest)
    return targetMapId == nil or targetMapId == mapId
end

--- 任务总进度（用于存档/展示）
function Quest.GetState()
    local dialogueRead = {}
    for questId, read in pairs(state.dialogueRead) do
        if read == true then dialogueRead[questId] = true end
    end
    local current = Quest.GetCurrent()
    return {
        version = QUEST_SAVE_VERSION,
        questIndex = state.questIndex,
        questId = current and current.id or nil,
        mode = current and current.mode or nil,
        progress = state.progress,
        modeState = CopyModeState(state.modeState),
        finished = state.finished,
        dialogueRead = dialogueRead,
        endingSeen = state.endingSeen,
    }
end

--- 恢复任务状态（读档时调用）
function Quest.Restore(saved)
    if type(saved) ~= "table" then
        state.questIndex = 1
        state.progress = 0
        state.modeState = {}
        state.finished = false
        state.dialogueRead = {}
        state.endingSeen = false
        state.lastNotifiedProgress = -1
        ResetObjectiveRuntimeState(Quest.GetCurrent(), 0)
        return
    end

    local questIndex = tonumber(saved.questIndex)
    if not questIndex or questIndex ~= questIndex or questIndex == math.huge
        or questIndex == -math.huge then
        questIndex = 1
    end
    questIndex = math.max(1, math.min(#Quest.CHAIN + 1, questIndex))
    questIndex = math.floor(questIndex)

    state.questIndex = questIndex
    state.finished = saved.finished == true or questIndex > #Quest.CHAIN
    if state.finished then
        state.questIndex = #Quest.CHAIN + 1
        state.progress = 0
        state.modeState = {}
        ResetObjectiveRuntimeState(nil, 0)
    else
        local current = Quest.CHAIN[state.questIndex]
        local progress = IsFiniteNumber(tonumber(saved.progress)) and tonumber(saved.progress) or 0
        local sameSchema = tonumber(saved.version) == QUEST_SAVE_VERSION
            and saved.questId == current.id and saved.mode == current.mode
            and type(saved.modeState) == "table"

        if sameSchema then
            if current.mode == "clear" then
                progress = tonumber(saved.modeState.kills) or progress
            elseif current.mode == "patrol" then
                progress = tonumber(saved.modeState.step) or progress
            elseif current.mode == "survive" then
                progress = tonumber(saved.modeState.seconds) or progress
            elseif current.mode == "encounter" then
                progress = saved.modeState.defeated == true and current.count or progress
            end
        else
            -- v1 与过渡版 v2 都把 progress 解释为指定怪击杀数。按旧目标
            -- 总量折算到新模式，既不清空玩家投入，也不会把 10 次击杀当 10 秒。
            local legacyCount = math.max(1, tonumber(current.legacyCount) or tonumber(current.count) or 1)
            local ratio = Clamp(progress / legacyCount, 0, 1)
            if current.mode == "survive" then
                progress = ratio * current.count
            elseif current.mode == "encounter" then
                progress = ratio >= 1 and current.count or 0
            else
                progress = math.floor(ratio * current.count + 0.5)
            end
        end

        -- 当前任务按设计不应以“已完成但未推进”的状态落盘。遇到旧版或
        -- 损坏存档时保留到最后一步，让下一次合法行为完成并正常发奖。
        if progress >= current.count then
            progress = current.mode == "survive"
                and math.max(0, current.count - 0.01)
                or math.max(0, current.count - 1)
        end
        SetProgress(current, progress)
        ResetObjectiveRuntimeState(current, progress)
    end

    state.dialogueRead = {}
    if type(saved.dialogueRead) == "table" then
        for _, quest in ipairs(Quest.CHAIN) do
            if saved.dialogueRead[quest.id] == true then
                state.dialogueRead[quest.id] = true
            end
        end
    end
    -- 旧存档没有 dialogueRead 时保持兼容：当前任务仍会播放一次。
    if state.questIndex > #Quest.CHAIN then
        state.finished = true
    end
    state.endingSeen = state.finished and saved.endingSeen == true
    state.lastNotifiedProgress = math.floor(state.progress)
end

--- 重置（新建角色时调用）
function Quest.Reset()
    state.questIndex = 1
    state.progress = 0
    state.modeState = {}
    state.finished = false
    state.dialogueRead = {}
    state.endingSeen = false
    state.lastNotifiedProgress = -1
    ResetObjectiveRuntimeState(Quest.GetCurrent(), 0)
    SyncModeState(Quest.GetCurrent())
end

-- ============================================================================
-- 推进逻辑
-- ============================================================================

local function NotifyProgress(q, force)
    local displayProgress = math.floor(state.progress)
    if not force and displayProgress == state.lastNotifiedProgress then return end
    state.lastNotifiedProgress = displayProgress
    if Quest.onProgressUpdate then
        Quest.onProgressUpdate(q, displayProgress, q.count)
    end
end

local function NotifySurviveWaves(q)
    if not q or q.mode ~= "survive" then return end

    -- 到达 50 秒这一刻任务会直接完成，不再额外生成“完成后的”波次。
    local cappedProgress = math.min(state.progress, math.max(0, q.count - 0.0001))
    local waveIndex = math.floor(cappedProgress / SURVIVE_WAVE_INTERVAL)
    local previousWave = state.surviveWaveIndex or 0
    if waveIndex <= previousWave then return end

    state.surviveWaveIndex = waveIndex
    for index = previousWave + 1, waveIndex do
        if Quest.onSurviveWave then
            Quest.onSurviveWave(q, index, q.area)
        end
    end
end

local function AdvanceCurrent(amount, objective)
    local q = Quest.GetCurrent()
    if not q then return false end
    local increment = tonumber(amount) or 0
    if increment <= 0 then return false end

    SetProgress(q, state.progress + increment)

    if q.mode == "patrol" and objective and Quest.onObjectiveReached then
        Quest.onObjectiveReached(q, objective, math.floor(state.progress))
    elseif q.mode == "survive" then
        NotifySurviveWaves(q)
    end

    if state.progress >= q.count then
        Quest._CompleteCurrent()
    else
        NotifyProgress(q, false)
    end
    return true
end

--- 击杀上报（由 Combat.onEnemyDeath 接线调用）。
--- clear 统计目标地图任意敌人；encounter 只统计当前遭遇实体。
---@param enemyName string
---@param tier string|nil
---@param mapId string|nil
---@param encounterId string|nil
---@return boolean
function Quest.OnKill(enemyName, tier, mapId, encounterId)
    if state.finished or type(enemyName) ~= "string" then return false end
    local q = Quest.GetCurrent()
    if not q then
        state.finished = true
        return false
    end

    if type(mapId) == "string" and not Quest.IsOnTargetMap(q, mapId) then return false end

    if q.mode == "clear" then
        return AdvanceCurrent(1)
    elseif q.mode == "encounter" and enemyName == q.target
        and (encounterId == nil or encounterId == q.id) then
        return AdvanceCurrent(1)
    end
    return false
end

local function IsInsideObjective(position, objective)
    if not position or not objective then return false end
    local px, pz = tonumber(position.x), tonumber(position.z)
    local ox, oz = tonumber(objective.x), tonumber(objective.z)
    if not px or not pz or not ox or not oz then return false end
    local dx, dz = px - ox, pz - oz
    local radius = math.max(0.5, tonumber(objective.radius) or 6)
    return dx * dx + dz * dz <= radius * radius
end

--- 公开的目标区域判定，供世界特效和 HUD 使用同一套半径逻辑。
---@param position Vector3|table|nil
---@param objective table|nil
---@return boolean
function Quest.IsInsideObjective(position, objective)
    return IsInsideObjective(position, objective)
end

--- 更新巡逻与坚守目标。离开目标地图、角色死亡或离开坚守区域时只暂停，
--- 不清零已有进度；因此重生、传送往返和读档都不会让任务卡死。
---@param dt number
---@param mapId string|nil
---@param playerPos Vector3|table|nil
---@param isAlive boolean|nil
---@return boolean
function Quest.Update(dt, mapId, playerPos, isAlive)
    local q = Quest.GetCurrent()
    if not q then return false end

    -- 坚守区域离图/死亡时显式熄灭“生效”状态，但不清空已累计秒数；
    -- 回到区域后只恢复状态，不重复触发首波（除非本次任务从未触发过）。
    if not Quest.IsOnTargetMap(q, mapId) or isAlive == false then
        if q.mode == "survive" and state.areaActive then
            state.areaActive = false
            if Quest.onAreaStateChanged then
                Quest.onAreaStateChanged(q, false, q.area, false)
            end
        end
        return false
    end

    if q.mode == "patrol" then
        local nextPoint = q.points and q.points[math.floor(state.progress) + 1] or nil
        if not IsInsideObjective(playerPos, nextPoint) then return false end
        return AdvanceCurrent(1, nextPoint)
    end

    if q.mode ~= "survive" then return false end

    local insideArea = IsInsideObjective(playerPos, q.area)
    if insideArea and not state.areaActive then
        local firstActivation = not state.areaTriggered
        state.areaActive = true
        if firstActivation then state.areaTriggered = true end
        if Quest.onAreaStateChanged then
            Quest.onAreaStateChanged(q, true, q.area, firstActivation)
        end
    elseif not insideArea and state.areaActive then
        state.areaActive = false
        if Quest.onAreaStateChanged then
            Quest.onAreaStateChanged(q, false, q.area, false)
        end
    end

    if not insideArea then return false end

    local elapsed = tonumber(dt)
    if not IsFiniteNumber(elapsed) or elapsed <= 0 then return false end
    -- 防止切后台/调试断点后单帧时间过大，直接跳过整个坚守任务。
    local cappedElapsed = elapsed > 0.25 and 0.25 or elapsed
    return AdvanceCurrent(cappedElapsed)
end

--- 完成当前任务，推进到下一任务
function Quest._CompleteCurrent()
    local q = Quest.CHAIN[state.questIndex]
    if not q then return end

    state.questIndex = state.questIndex + 1
    state.progress = 0
    state.modeState = {}
    state.lastNotifiedProgress = -1
    ResetObjectiveRuntimeState(nil, 0)

    if state.questIndex > #Quest.CHAIN then
        state.finished = true
    end

    local next = Quest.GetCurrent()
    ResetObjectiveRuntimeState(next, 0)
    SyncModeState(next)

    if Quest.onQuestComplete then
        Quest.onQuestComplete(q)
    end

    -- 新任务开始时触发（播放剧情对话）
    if next and Quest.onQuestStart then
        Quest.onQuestStart(next)
        if not next.dialogues or #next.dialogues == 0 then
            state.dialogueRead[next.id] = true
        end
    end
end

--- 手动触发当前任务的开始（进入游戏/读档后调用，播放当前任务对话）
function Quest.TriggerCurrentStart()
    local q = Quest.GetCurrent()
    if not q or not Quest.onQuestStart then return false end
    if state.dialogueRead[q.id] == true then return false end
    if q.dialogues and #q.dialogues > 0 then
        Quest.onQuestStart(q)
    else
        state.dialogueRead[q.id] = true
    end
    return true
end

--- 标记任务开场对话已读；由宿主在 UI 对话真正播放完后调用。
---@param questId string|nil
function Quest.MarkDialogueRead(questId)
    if type(questId) ~= "string" then return false end
    for _, quest in ipairs(Quest.CHAIN) do
        if quest.id == questId then
            state.dialogueRead[questId] = true
            return true
        end
    end
    return false
end

---@param quest table|string|nil
---@return boolean
function Quest.IsDialogueRead(quest)
    local questId = type(quest) == "table" and quest.id or quest
    return type(questId) == "string" and state.dialogueRead[questId] == true
end

---@return boolean
function Quest.IsEndingSeen()
    return state.endingSeen == true
end

function Quest.MarkEndingSeen()
    if not state.finished then return false end
    state.endingSeen = true
    return true
end

return Quest
