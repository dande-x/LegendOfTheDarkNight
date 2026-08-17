-- ============================================================================
-- Quest.lua — 暗夜传奇 主线任务系统
--
-- 致敬盛大《热血传奇》，主线按「三幕 + 终章」组织，每幕一个剧情反转、
-- 一场高潮 Boss 战。任务目标怪物名与 Combat.ENEMY_DEFS 的 name 字段对齐；
-- 待 P1 命名替换（蜘蛛→毒蜘蛛、狼人→狼、山岳巨人→沃玛教主 等）落地后，
-- 需同步更新下方 target 字段即可，任务链结构无需改动。
--
-- 任务类型：
--   kill  —— 击杀指定怪物 N 只（普通推进）
--   boss  —— 击杀指定 Boss 1 只（章节高潮）
--
-- 设计原则（反「流水账刷怪」）：
--   - 每幕最后一个任务是 Boss 战，作为章节情感高潮
--   - 任务名与 desc 承载剧情反转，驱动玩家「为什么而战」
--   - 奖励 = 经验 + 金币（装备奖励字段预留，由经济系统分支接入）
-- ============================================================================

local Quest = {}

-- ============================================================================
-- 主线任务链（按策划案三幕 + 终章）
-- ============================================================================
Quest.CHAIN = {
    -- ============ 第一幕「边城烽火」（比奇省·银杏山谷，Lv1~15）============
    {
        id = "q_001", name = "初入荒原", chapter = "第一幕 · 边城烽火",
        type = "kill", target = "稻草人", count = 5,
        desc = "村庄被半兽人夜袭焚毁。清理田间的稻草人，让幸存的村民重返家园。",
        rewardExp = 100, rewardGold = 50,
    },
    {
        id = "q_002", name = "幽影来袭", chapter = "第一幕 · 边城烽火",
        type = "kill", target = "幽灵", count = 8,
        desc = "废墟上游荡着不散的幽影。它们像是被什么力量驱使着，彻夜哀鸣。",
        rewardExp = 180, rewardGold = 80,
    },
    {
        id = "q_003", name = "骷髅军团", chapter = "第一幕 · 边城烽火",
        type = "kill", target = "骷髅", count = 10,
        desc = "夜袭的尸骨竟从泥土里爬了起来。有人在暗中操控亡者。",
        rewardExp = 260, rewardGold = 120,
    },
    {
        id = "q_004", name = "半兽人先锋", chapter = "第一幕 · 边城烽火",
        type = "kill", target = "半兽人", count = 12,
        desc = "半兽人的先锋队有组织地推进。它们不像野兽，倒像一支军队。",
        rewardExp = 400, rewardGold = 180,
    },
    {
        id = "q_005", name = "蛛穴之影", chapter = "第一幕 · 边城烽火",
        type = "kill", target = "毒蜘蛛", count = 15,
        desc = "追杀溃逃的兽兵时，你撞进了毒蛛的巢穴。杀出去，别回头。",
        rewardExp = 600, rewardGold = 260,
    },
    {
        id = "q_006", name = "边城守卫战", chapter = "第一幕 · 边城烽火",
        type = "boss", target = "沃玛教主", count = 1,
        desc = "真相大白——你曾最信任的守卫队长，正是为半兽人打开城门的叛徒。山岳巨人压境，唯有死战。",
        rewardExp = 1500, rewardGold = 800,
    },

    -- ============ 第二幕「黄沙盟重」（盟重土城，Lv16~30）============
    {
        id = "q_007", name = "野狼出没", chapter = "第二幕 · 黄沙盟重",
        type = "kill", target = "狼", count = 20,
        desc = "黄沙之城的商路被狼群切断。护送商队穿过荒漠，让土城的血重新流动。",
        rewardExp = 1800, rewardGold = 900,
    },
    {
        id = "q_008", name = "石魔之心", chapter = "第二幕 · 黄沙盟重",
        type = "kill", target = "石魔", count = 15,
        desc = "荒漠深处的石魔被唤醒，它们的心脏里封着古老的符文。",
        rewardExp = 2200, rewardGold = 1200,
    },
    {
        id = "q_009", name = "蛛后巢穴", chapter = "第二幕 · 黄沙盟重",
        type = "boss", target = "蚁后", count = 1,
        desc = "城主竟被掉了包！猪洞的骚乱只是调虎离山。杀入蛛后巢穴，夺回城主信物。",
        rewardExp = 3000, rewardGold = 1500,
    },

    -- ============ 第三幕「怒海寻踪」（水上城市，Lv31~44）============
    {
        id = "q_010", name = "将军之骨", chapter = "第三幕 · 怒海寻踪",
        type = "kill", target = "骷髅将军", count = 20,
        desc = "海上迷城的水域飘来无数骸骨。它们都朝着同一个方向跪拜。",
        rewardExp = 3800, rewardGold = 1800,
    },
    {
        id = "q_011", name = "熔火之门", chapter = "第三幕 · 怒海寻踪",
        type = "kill", target = "赤焰魔", count = 20,
        desc = "水城的航路被熔火封锁。有东西在海底烧灼着整片海域。",
        rewardExp = 4800, rewardGold = 2400,
    },
    {
        id = "q_012", name = "蛇窟", chapter = "第三幕 · 怒海寻踪",
        type = "kill", target = "巨蟒", count = 25,
        desc = "通往真相的路，盘踞着无数巨蟒。师父当年守的，究竟是什么样的门？",
        rewardExp = 6000, rewardGold = 3000,
    },

    -- ============ 终章「屠龙之战」（沃玛寺庙 → 祖玛寺庙，Lv45~50）============
    {
        id = "q_013", name = "噬魂之潮", chapter = "终章 · 屠龙之战",
        type = "kill", target = "噬魂兽", count = 25,
        desc = "真相的尽头是更大的黑暗。师父并非战死，而是自愿献祭封印魔王。",
        rewardExp = 7500, rewardGold = 3600,
    },
    {
        id = "q_014", name = "麒麟试炼", chapter = "终章 · 屠龙之战",
        type = "kill", target = "麒麟", count = 20,
        desc = "集齐屠龙宝刀的残片，需先通过麒麟的试炼。复仇的对象，从一开始就错了。",
        rewardExp = 9000, rewardGold = 4500,
    },
    {
        id = "q_015", name = "骨龙之渊", chapter = "终章 · 屠龙之战",
        type = "boss", target = "火龙王", count = 1,
        desc = "沃玛寺庙深处，骨龙守护着最后的封印。屠龙宝刀在此觉醒。",
        rewardExp = 12000, rewardGold = 8000,
    },
    {
        id = "q_016", name = "深渊领主", chapter = "终章 · 屠龙之战",
        type = "boss", target = "牛魔王", count = 1,
        desc = "祖玛封印即将崩解，火龙王即将苏醒。用屠龙宝刀，斩断这场延续百年的战争。",
        rewardExp = 20000, rewardGold = 15000,
    },
}

-- ============================================================================
-- 运行时状态
-- ============================================================================
local state = {
    questIndex = 1,   -- 当前任务在 CHAIN 中的下标（1 起始）
    progress = 0,     -- 当前任务击杀进度
    finished = false, -- 是否已通关全部主线
}

-- 外部回调（由 main.lua 注册）
Quest.onQuestComplete = nil   -- function(quest) 任务完成时触发（发放奖励）
Quest.onProgressUpdate = nil  -- function(quest, progress, count) 进度变化时触发（刷新 HUD）

-- ============================================================================
-- 查询接口
-- ============================================================================

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
    return state.progress, q.count
end

--- 任务总进度（用于存档/展示）
function Quest.GetState()
    return {
        questIndex = state.questIndex,
        progress = state.progress,
        finished = state.finished,
    }
end

--- 恢复任务状态（读档时调用）
function Quest.Restore(saved)
    if not saved then
        state.questIndex = 1
        state.progress = 0
        state.finished = false
        return
    end
    state.questIndex = saved.questIndex or 1
    state.progress = saved.progress or 0
    state.finished = saved.finished or false
    -- 越界保护
    if state.questIndex > #Quest.CHAIN then
        state.finished = true
    end
end

--- 重置（新建角色时调用）
function Quest.Reset()
    state.questIndex = 1
    state.progress = 0
    state.finished = false
end

-- ============================================================================
-- 推进逻辑
-- ============================================================================

--- 击杀上报（由 Combat.onEnemyDeath 接线调用）
--- 只统计当前任务目标怪，其他击杀不打断当前任务
function Quest.OnKill(enemyName)
    if state.finished then return end
    local q = Quest.CHAIN[state.questIndex]
    if not q then
        state.finished = true
        return
    end

    -- 仅当击杀的怪物匹配当前任务目标时计数
    if enemyName ~= q.target then return end

    state.progress = state.progress + 1
    if state.progress >= q.count then
        state.progress = q.count
        Quest._CompleteCurrent()
    elseif Quest.onProgressUpdate then
        Quest.onProgressUpdate(q, state.progress, q.count)
    end
end

--- 完成当前任务，推进到下一任务
function Quest._CompleteCurrent()
    local q = Quest.CHAIN[state.questIndex]
    if not q then return end

    state.questIndex = state.questIndex + 1
    state.progress = 0

    if state.questIndex > #Quest.CHAIN then
        state.finished = true
    end

    if Quest.onQuestComplete then
        Quest.onQuestComplete(q)
    end
end

return Quest
