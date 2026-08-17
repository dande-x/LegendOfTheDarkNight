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
        dialogues = {
            { speaker = "旁白", text = "那一夜，半兽人的火把照亮了整片银杏山谷。" },
            { speaker = "师父", text = "快走！带着这把乌木剑，去盟重……找……真相……" },
            { speaker = "旁白", text = "师父倒在了你怀里，手里还紧紧攥着这把剑。" },
            { speaker = "你", text = "我会回来。我会让它们血债血偿。" },
            { speaker = "旁白", text = "村庄已成废墟。清理田间游荡的稻草人，让幸存者重返家园。" },
        },
    },
    {
        id = "q_002", name = "幽影来袭", chapter = "第一幕 · 边城烽火",
        type = "kill", target = "幽灵", count = 8,
        desc = "废墟上游荡着不散的幽影。它们像是被什么力量驱使着，彻夜哀鸣。",
        rewardExp = 180, rewardGold = 80,
        dialogues = {
            { speaker = "村民", text = "那些幽影……夜夜在村口徘徊，像是认得回家的路。" },
            { speaker = "你", text = "它们是被夜袭害死的村民。有人在用邪术囚禁亡魂。" },
        },
    },
    {
        id = "q_003", name = "骷髅军团", chapter = "第一幕 · 边城烽火",
        type = "kill", target = "骷髅", count = 10,
        desc = "夜袭的尸骨竟从泥土里爬了起来。有人在暗中操控亡者。",
        rewardExp = 260, rewardGold = 120,
        dialogues = {
            { speaker = "旁白", text = "你挖开夜袭留下的埋尸坑，里面的尸骨竟在微微颤动。" },
            { speaker = "神秘商人", text = "小伙子，有人在比奇城里替半兽人开了门。查查城门，你会明白的。" },
        },
    },
    {
        id = "q_004", name = "半兽人先锋", chapter = "第一幕 · 边城烽火",
        type = "kill", target = "半兽人", count = 12,
        desc = "半兽人的先锋队有组织地推进。它们不像野兽，倒像一支军队。",
        rewardExp = 400, rewardGold = 180,
        dialogues = {
            { speaker = "旁白", text = "半兽人的先锋队排着整齐的队形，这绝不是野兽能做出来的事。" },
            { speaker = "你", text = "有内奸。它们对我们的布防了如指掌。" },
        },
    },
    {
        id = "q_005", name = "蛛穴之影", chapter = "第一幕 · 边城烽火",
        type = "kill", target = "毒蜘蛛", count = 15,
        desc = "追杀溃逃的兽兵时，你撞进了毒蛛的巢穴。杀出去，别回头。",
        rewardExp = 600, rewardGold = 260,
        dialogues = {
            { speaker = "旁白", text = "你追着溃逃的兽兵，一路追进了城外的蛛穴。" },
            { speaker = "你", text = "这些毒蛛……是被故意放养在这里，堵住追兵的。" },
        },
    },
    {
        id = "q_006", name = "边城守卫战", chapter = "第一幕 · 边城烽火",
        type = "boss", target = "半兽勇士", count = 1,
        desc = "真相大白——你曾最信任的守卫队长，正是为半兽人打开城门的叛徒。",
        rewardExp = 1500, rewardGold = 800,
        dialogues = {
            { speaker = "守卫队长", text = "没想到是你活了下来。" },
            { speaker = "守卫队长", text = "不错，是我开的门。半兽人答应我，事成之后，比奇城归我。" },
            { speaker = "你", text = "师父的命，全村人的命，就为了一个城主的位子？" },
            { speaker = "守卫队长", text = "杀了我，也改变不了什么。半兽勇士已经压境了！" },
            { speaker = "旁白", text = "城门洞开，半兽勇士率军冲入。这是你第一次，直面真正的战场。" },
        },
    },

    -- ============ 第二幕「黄沙盟重」（盟重土城，Lv16~30）============
    {
        id = "q_007", name = "野狼出没", chapter = "第二幕 · 黄沙盟重",
        type = "kill", target = "狼", count = 20,
        desc = "黄沙之城的商路被狼群切断。护送商队穿过荒漠。",
        rewardExp = 1800, rewardGold = 900,
        dialogues = {
            { speaker = "旁白", text = "你循着师父的遗言，一路西行，来到了黄沙深处的盟重土城。" },
            { speaker = "商队头领", text = "城外狼群越聚越多，商路快断了。帮我们清一条路出来。" },
        },
    },
    {
        id = "q_008", name = "石魔之心", chapter = "第二幕 · 黄沙盟重",
        type = "kill", target = "石魔", count = 15,
        desc = "荒漠深处的石魔被唤醒，它们的心脏里封着古老的符文。",
        rewardExp = 2200, rewardGold = 1200,
        dialogues = {
            { speaker = "旁白", text = "土城东郊的石墓（猪洞）传来异动。传闻有白野猪作乱。" },
            { speaker = "你", text = "石魔心脏上的符文……和比奇城见到的一模一样。" },
        },
    },
    {
        id = "q_009", name = "猪洞之影", chapter = "第二幕 · 黄沙盟重",
        type = "boss", target = "白野猪", count = 1,
        desc = "城主竟被掉了包！猪洞的骚乱只是调虎离山。杀入石墓，夺回城主信物。",
        rewardExp = 3000, rewardGold = 1500,
        dialogues = {
            { speaker = "旁白", text = "你终于见到了城主，却发现——他的眼神，不对。" },
            { speaker = "假城主", text = "真正的城主被我关在猪洞深处。而你，也一起留下吧！" },
            { speaker = "旁白", text = "石墓（猪洞）深处传来闷雷般的咆哮。白野猪撞碎石门，冲了出来！" },
            { speaker = "旁白", text = "假城主现出原形。守住土城，夺回城主信物！" },
        },
    },

    -- ============ 第三幕「怒海寻踪」（水上城市，Lv31~44）============
    {
        id = "q_010", name = "将军之骨", chapter = "第三幕 · 怒海寻踪",
        type = "kill", target = "骷髅将军", count = 20,
        desc = "海上迷城的水域飘来无数骸骨。它们都朝着同一个方向跪拜。",
        rewardExp = 3800, rewardGold = 1800,
        dialogues = {
            { speaker = "旁白", text = "你循线索来到水上城市——一座建在海域上的贸易城。" },
            { speaker = "故交", text = "你师父……他本是沃玛寺庙的守门人。当年的事，远比你想象的复杂。" },
        },
    },
    {
        id = "q_011", name = "熔火之门", chapter = "第三幕 · 怒海寻踪",
        type = "kill", target = "赤焰魔", count = 20,
        desc = "水城的航路被熔火封锁。有东西在海底烧灼着整片海域。",
        rewardExp = 4800, rewardGold = 2400,
        dialogues = {
            { speaker = "旁白", text = "蚁后不是元凶，它只是被沃玛教主的黑暗力量驱使。" },
            { speaker = "你", text = "原来我复仇的对象，从一开始就错了。" },
        },
    },
    {
        id = "q_012", name = "蛇窟", chapter = "第三幕 · 怒海寻踪",
        type = "kill", target = "巨蟒", count = 25,
        desc = "通往真相的路，盘踞着无数巨蟒。",
        rewardExp = 6000, rewardGold = 3000,
        dialogues = {
            { speaker = "故交", text = "你师父当年并非战死。他是自愿献祭，封印沃玛教主。" },
            { speaker = "你", text = "……所以，他骗了我。他让我来找的，是他自己的死亡。" },
        },
    },
    {
        id = "q_012b", name = "蚁后之渊", chapter = "第三幕 · 怒海寻踪",
        type = "boss", target = "蚁后", count = 1,
        desc = "水城的蚁患背后，是沃玛教主的黑暗力量。击败蚁后，夺回进入沃玛寺庙的通行证。",
        rewardExp = 8000, rewardGold = 4000,
        dialogues = {
            { speaker = "旁白", text = "水城蚁患肆虐，整片海域的航路都被蚁群吞噬。" },
            { speaker = "故交", text = "蚁后不是元凶，它只是被沃玛教主的黑暗力量驱使。" },
            { speaker = "你", text = "为了水城，也为了拿到进入沃玛寺庙的通行证——必须击破蚁后！" },
        },
    },

    -- ============ 终章「屠龙之战」（沃玛寺庙 → 祖玛寺庙，Lv45~50）============
    {
        id = "q_013", name = "噬魂之潮", chapter = "终章 · 屠龙之战",
        type = "kill", target = "噬魂兽", count = 25,
        desc = "真相的尽头是更大的黑暗。",
        rewardExp = 7500, rewardGold = 3600,
        dialogues = {
            { speaker = "旁白", text = "你带着对师父的真正敬意，踏入沃玛寺庙。" },
            { speaker = "你", text = "师父，我来完成你未竟的事。" },
        },
    },
    {
        id = "q_014", name = "麒麟试炼", chapter = "终章 · 屠龙之战",
        type = "kill", target = "麒麟", count = 20,
        desc = "集齐屠龙宝刀的残片，需先通过麒麟的试炼。",
        rewardExp = 9000, rewardGold = 4500,
        dialogues = {
            { speaker = "旁白", text = "屠龙宝刀散落大陆。要打开祖玛封印，必须集齐残片。" },
            { speaker = "你", text = "牛魔王也盯上了残片。绝不能让它先得手。" },
        },
    },
    {
        id = "q_014b", name = "沃玛教主", chapter = "终章 · 屠龙之战",
        type = "boss", target = "沃玛教主", count = 1,
        desc = "沃玛寺庙深处，沃玛教主祭起黑暗法阵。击败它，夺回通往祖玛的钥匙。",
        rewardExp = 11000, rewardGold = 7000,
        dialogues = {
            { speaker = "旁白", text = "沃玛寺庙深处，师父当年封印的黑暗，终于现出真身。" },
            { speaker = "沃玛教主", text = "守门人的徒弟？你和他一样，都将葬身于此！" },
            { speaker = "你", text = "师父没能彻底消灭你。今天，我来替他完成。" },
        },
    },
    {
        id = "q_015", name = "骨龙之渊", chapter = "终章 · 屠龙之战",
        type = "boss", target = "火龙王", count = 1,
        desc = "祖玛寺庙深处，火龙王守护着最后的封印。",
        rewardExp = 12000, rewardGold = 8000,
        dialogues = {
            { speaker = "旁白", text = "祖玛寺庙深处，火龙王在熔岩深渊中缓缓睁开眼。" },
            { speaker = "旁白", text = "这是最后的守护。屠龙宝刀在此觉醒。" },
        },
    },
    {
        id = "q_016", name = "深渊领主", chapter = "终章 · 屠龙之战",
        type = "boss", target = "牛魔王", count = 1,
        desc = "祖玛封印即将崩解，火龙王即将苏醒。",
        rewardExp = 20000, rewardGold = 15000,
        dialogues = {
            { speaker = "旁白", text = "祖玛寺庙最深处，牛魔王挡住了你的去路。" },
            { speaker = "牛魔王", text = "渺小的凡人，也敢踏足祖玛圣地！" },
            { speaker = "旁白", text = "用屠龙宝刀，斩断这场延续百年的战争。让玛法大陆，重归和平。" },
        },
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
Quest.onQuestStart = nil      -- function(quest) 任务开始时触发（播放剧情对话）

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

    -- 新任务开始时触发（播放剧情对话）
    local next = Quest.GetCurrent()
    if next and Quest.onQuestStart then
        Quest.onQuestStart(next)
    end
end

--- 手动触发当前任务的开始（进入游戏/读档后调用，播放当前任务对话）
function Quest.TriggerCurrentStart()
    local q = Quest.GetCurrent()
    if q and Quest.onQuestStart then
        Quest.onQuestStart(q)
    end
end

return Quest
