-- ============================================================================
-- GameUI.lua — 贪玩渣渣灰 完整 UI 系统
-- 暗黑地牢风角色选择 + NanoVG 圆球 HP/MP + 开门过渡 + 技能栏 + 飘字
-- ============================================================================

local UI = require("urhox-libs/UI")
local CharacterClass = require("scripts.CharacterClass")
require "urhox-libs.UI.GameHUD"

local GameUI = {}

-- UI 颜色
local C = CharacterClass.Colors

-- ============================================================================
-- NanoVG 常量
-- ============================================================================
local NVG_ALIGN_LEFT   = 1
local NVG_ALIGN_CENTER = 2
local NVG_ALIGN_RIGHT  = 4
local NVG_ALIGN_TOP    = 8
local NVG_ALIGN_MIDDLE = 16
local NVG_ALIGN_BOTTOM = 32
local NVG_CW  = 1
local NVG_CCW = 2

-- ============================================================================
-- NanoVG 状态
-- ============================================================================
local nvgCtx = nil
local nvgFontId = -1

-- ============================================================================
-- 开门过渡状态
-- ============================================================================
local doorState = {
    active = false,
    progress = 0,     -- 0=关闭, 1=完全打开
    duration = 2.2,
    onComplete = nil,
}

-- ============================================================================
-- UI 状态
-- ============================================================================
local uiState = {
    phase = "select",   -- "select" | "playing"
    selectedClass = nil,
    player = nil,
    joystick = nil,
    skillButtons = {},
    floatingTexts = {},
    onClassSelected = nil,
    hudRoot = nil,
    selectRoot = nil,
    refs = {},
}

GameUI.state = uiState

-- ============================================================================
-- 初始化 UI 系统
-- ============================================================================
function GameUI.InitUI()
    UI.Init({
        fonts = {
            { family = "sans", weights = {
                normal = "Fonts/MiSans-Regular.ttf",
            } }
        },
        scale = UI.Scale.DEFAULT,
    })
    print("[GameUI] UI system initialized")
end

-- ============================================================================
-- 初始化 NanoVG (HP/MP 圆球 + 开门过渡)
-- ============================================================================
function GameUI.InitNanoVG()
    nvgCtx = nvgCreate(1)
    if nvgCtx then
        nvgFontId = nvgCreateFont(nvgCtx, "sans", "Fonts/MiSans-Regular.ttf")
        SubscribeToEvent(nvgCtx, "NanoVGRender", "HandleNanoVGRender")
        print("[GameUI] NanoVG initialized, fontId=" .. nvgFontId)
    else
        print("[GameUI] WARNING: NanoVG creation failed")
    end
end

-- NanoVG 渲染回调（全局函数）
function HandleNanoVGRender(eventType, eventData)
    if not nvgCtx then return end
    GameUI._RenderNanoVG()
end

-- ============================================================================
-- NanoVG 主渲染
-- ============================================================================
function GameUI._RenderNanoVG()
    local sw = graphics.width
    local sh = graphics.height
    nvgBeginFrame(nvgCtx, sw, sh, 1.0)

    -- 绘制 HP/MP 圆球 (仅游戏阶段)
    if uiState.phase == "playing" and uiState.player then
        GameUI._DrawOrbs(nvgCtx, sw, sh)
    end

    -- 绘制开门过渡
    if doorState.active then
        GameUI._DrawDoorTransition(nvgCtx, sw, sh)
    end

    nvgEndFrame(nvgCtx)
end

-- ============================================================================
-- HP/MP 合体圆球绘制（左半HP 右半MP）
-- ============================================================================
function GameUI._DrawOrbs(ctx, sw, sh)
    local scale = sh / 720
    local player = uiState.player

    local r  = math.floor(38 * scale)
    local cx = math.floor(55 * scale)
    local cy = math.floor(60 * scale)

    local hpProg = math.max(0, math.min(1, player.hp / math.max(1, player.maxHP)))
    local mpProg = math.max(0, math.min(1, player.mp / math.max(1, player.maxMP)))

    -- 外发光 (紫色混合)
    nvgBeginPath(ctx)
    nvgCircle(ctx, cx, cy, r + 6 * scale)
    local glowGrad = nvgRadialGradient(ctx, cx, cy, r - 2, r + 10 * scale,
        nvgRGBA(100, 40, 90, 45),
        nvgRGBA(60, 30, 60, 0))
    nvgFillPaint(ctx, glowGrad)
    nvgFill(ctx)

    -- 背景圆（深黑底）
    nvgBeginPath(ctx)
    nvgCircle(ctx, cx, cy, r)
    local bgGrad = nvgRadialGradient(ctx, cx, cy - r * 0.2, r * 0.1, r,
        nvgRGBA(25, 18, 15, 240),
        nvgRGBA(10, 8, 6, 250))
    nvgFillPaint(ctx, bgGrad)
    nvgFill(ctx)

    -- ======== 左半圆: HP (红) ========
    if hpProg > 0 then
        nvgSave(ctx)
        local fillH = 2 * r * hpProg
        local clipY = cy + r - fillH
        -- 先裁剪到左半圆
        nvgScissor(ctx, cx - r, cy - r, r, 2 * r)
        -- 再裁剪到液面高度
        nvgIntersectScissor(ctx, cx - r, clipY, r, fillH)

        nvgBeginPath(ctx)
        nvgCircle(ctx, cx, cy, r - 1)
        local hpGrad = nvgRadialGradient(ctx, cx - r * 0.1, cy - r * 0.15, r * 0.1, r * 0.85,
            nvgRGBA(220, 55, 35, 210),
            nvgRGBA(110, 25, 15, 230))
        nvgFillPaint(ctx, hpGrad)
        nvgFill(ctx)

        -- 液面高光
        nvgBeginPath(ctx)
        nvgEllipse(ctx, cx - r * 0.25, clipY + 2 * scale, r * 0.35, 2 * scale)
        nvgFillColor(ctx, nvgRGBA(255, 255, 255, 30))
        nvgFill(ctx)

        nvgRestore(ctx)
    end

    -- ======== 右半圆: MP (蓝) ========
    if mpProg > 0 then
        nvgSave(ctx)
        local fillH = 2 * r * mpProg
        local clipY = cy + r - fillH
        -- 裁剪到右半圆
        nvgScissor(ctx, cx, cy - r, r, 2 * r)
        -- 裁剪到液面高度
        nvgIntersectScissor(ctx, cx, clipY, r, fillH)

        nvgBeginPath(ctx)
        nvgCircle(ctx, cx, cy, r - 1)
        local mpGrad = nvgRadialGradient(ctx, cx + r * 0.1, cy - r * 0.15, r * 0.1, r * 0.85,
            nvgRGBA(50, 110, 210, 210),
            nvgRGBA(25, 55, 120, 230))
        nvgFillPaint(ctx, mpGrad)
        nvgFill(ctx)

        -- 液面高光
        nvgBeginPath(ctx)
        nvgEllipse(ctx, cx + r * 0.25, clipY + 2 * scale, r * 0.35, 2 * scale)
        nvgFillColor(ctx, nvgRGBA(255, 255, 255, 30))
        nvgFill(ctx)

        nvgRestore(ctx)
    end

    -- ======== 中线分隔 ========
    nvgBeginPath(ctx)
    nvgMoveTo(ctx, cx, cy - r + 2)
    nvgLineTo(ctx, cx, cy + r - 2)
    nvgStrokeColor(ctx, nvgRGBA(180, 170, 140, 80))
    nvgStrokeWidth(ctx, 1.2 * scale)
    nvgStroke(ctx)

    -- 玻璃反光（左上月牙 + 右上月牙）
    nvgBeginPath(ctx)
    nvgEllipse(ctx, cx - r * 0.28, cy - r * 0.35, r * 0.18, r * 0.12)
    nvgFillColor(ctx, nvgRGBA(255, 255, 255, 25))
    nvgFill(ctx)
    nvgBeginPath(ctx)
    nvgEllipse(ctx, cx + r * 0.28, cy - r * 0.35, r * 0.15, r * 0.10)
    nvgFillColor(ctx, nvgRGBA(255, 255, 255, 20))
    nvgFill(ctx)

    -- 外圈边框
    nvgBeginPath(ctx)
    nvgCircle(ctx, cx, cy, r)
    nvgStrokeColor(ctx, nvgRGBA(160, 120, 70, 190))
    nvgStrokeWidth(ctx, 2.5 * scale)
    nvgStroke(ctx)

    nvgBeginPath(ctx)
    nvgCircle(ctx, cx, cy, r + 1.5 * scale)
    nvgStrokeColor(ctx, nvgRGBA(40, 35, 28, 200))
    nvgStrokeWidth(ctx, 1.0 * scale)
    nvgStroke(ctx)

    -- 数值文字
    if nvgFontId >= 0 then
        nvgFontFaceId(ctx, nvgFontId)
        nvgFontSize(ctx, math.floor(11 * scale))
        nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

        -- 左侧 HP 数值
        nvgFillColor(ctx, nvgRGBA(255, 200, 180, 230))
        nvgText(ctx, cx - r * 0.32, cy, tostring(math.floor(player.hp)), nil)

        -- 右侧 MP 数值
        nvgFillColor(ctx, nvgRGBA(180, 210, 255, 230))
        nvgText(ctx, cx + r * 0.32, cy, tostring(math.floor(player.mp)), nil)

        -- 底部标签
        nvgFontSize(ctx, math.floor(8 * scale))
        nvgFillColor(ctx, nvgRGBA(190, 75, 55, 150))
        nvgText(ctx, cx - r * 0.35, cy + r + 9 * scale, "HP", nil)
        nvgFillColor(ctx, nvgRGBA(70, 140, 210, 150))
        nvgText(ctx, cx + r * 0.35, cy + r + 9 * scale, "MP", nil)
    end
end

-- ============================================================================
-- 开门过渡绘制
-- ============================================================================
function GameUI._DrawDoorTransition(ctx, sw, sh)
    local p = doorState.progress
    -- Ease out cubic
    local ep = 1 - (1 - p) * (1 - p) * (1 - p)

    local halfW = sw / 2
    local openOffset = halfW * ep

    -- 左门扇
    local leftW = halfW - openOffset
    if leftW > 0 then
        nvgBeginPath(ctx)
        nvgRect(ctx, 0, 0, leftW, sh)
        local leftGrad = nvgLinearGradient(ctx, 0, 0, leftW, 0,
            nvgRGBA(18, 14, 10, 255),
            nvgRGBA(40, 32, 22, 255))
        nvgFillPaint(ctx, leftGrad)
        nvgFill(ctx)

        -- 左门右侧石质边框
        nvgBeginPath(ctx)
        nvgRect(ctx, leftW - 6, 0, 6, sh)
        nvgFillColor(ctx, nvgRGBA(70, 58, 42, 220))
        nvgFill(ctx)

        -- 左门铆钉装饰
        local boltSpacing = sh / 6
        for i = 1, 5 do
            local by = boltSpacing * i
            nvgBeginPath(ctx)
            nvgCircle(ctx, leftW - 30, by, 4)
            nvgFillColor(ctx, nvgRGBA(90, 75, 55, 200))
            nvgFill(ctx)
            nvgBeginPath(ctx)
            nvgCircle(ctx, leftW - 30, by, 2)
            nvgFillColor(ctx, nvgRGBA(140, 120, 85, 160))
            nvgFill(ctx)
        end
    end

    -- 右门扇
    local rightX = halfW + openOffset
    local rightW = sw - rightX
    if rightW > 0 then
        nvgBeginPath(ctx)
        nvgRect(ctx, rightX, 0, rightW, sh)
        local rightGrad = nvgLinearGradient(ctx, rightX, 0, sw, 0,
            nvgRGBA(40, 32, 22, 255),
            nvgRGBA(18, 14, 10, 255))
        nvgFillPaint(ctx, rightGrad)
        nvgFill(ctx)

        -- 右门左侧石质边框
        nvgBeginPath(ctx)
        nvgRect(ctx, rightX, 0, 6, sh)
        nvgFillColor(ctx, nvgRGBA(70, 58, 42, 220))
        nvgFill(ctx)

        -- 右门铆钉装饰
        local boltSpacing = sh / 6
        for i = 1, 5 do
            local by = boltSpacing * i
            nvgBeginPath(ctx)
            nvgCircle(ctx, rightX + 30, by, 4)
            nvgFillColor(ctx, nvgRGBA(90, 75, 55, 200))
            nvgFill(ctx)
            nvgBeginPath(ctx)
            nvgCircle(ctx, rightX + 30, by, 2)
            nvgFillColor(ctx, nvgRGBA(140, 120, 85, 160))
            nvgFill(ctx)
        end
    end

    -- 中缝光线（门开中间漏出的光）
    if ep > 0.02 and ep < 0.95 then
        local beamW = openOffset * 0.5
        local beamAlpha = math.floor(200 * (1 - ep))
        nvgBeginPath(ctx)
        nvgRect(ctx, halfW - beamW / 2, 0, beamW, sh)
        local beamGrad = nvgLinearGradient(ctx,
            halfW - beamW / 2, 0, halfW + beamW / 2, 0,
            nvgRGBA(200, 170, 100, 0),
            nvgRGBA(220, 190, 120, beamAlpha))
        nvgFillPaint(ctx, beamGrad)
        nvgFill(ctx)

        -- 对称的另一半
        nvgBeginPath(ctx)
        nvgRect(ctx, halfW - beamW / 2, 0, beamW, sh)
        local beamGrad2 = nvgLinearGradient(ctx,
            halfW + beamW / 2, 0, halfW - beamW / 2, 0,
            nvgRGBA(200, 170, 100, 0),
            nvgRGBA(220, 190, 120, beamAlpha))
        nvgFillPaint(ctx, beamGrad2)
        nvgFill(ctx)
    end

    -- 上方兽头装饰线（门框顶部）
    if ep < 0.85 then
        local topAlpha = math.floor(255 * (1 - ep / 0.85))
        nvgBeginPath(ctx)
        nvgRect(ctx, 0, 0, sw, 8)
        nvgFillColor(ctx, nvgRGBA(55, 45, 32, topAlpha))
        nvgFill(ctx)
        nvgBeginPath(ctx)
        nvgRect(ctx, 0, sh - 6, sw, 6)
        nvgFillColor(ctx, nvgRGBA(55, 45, 32, topAlpha))
        nvgFill(ctx)
    end
end

-- ============================================================================
-- 启动开门动画
-- ============================================================================
function GameUI.StartDoorOpen(onComplete)
    doorState.active = true
    doorState.progress = 0
    doorState.duration = 2.2
    doorState.onComplete = onComplete
    print("[GameUI] Door transition started")
end

-- ============================================================================
-- 角色选择界面 (暗黑地牢风格)
-- ============================================================================
function GameUI.ShowClassSelect(onSelected)
    uiState.phase = "select"
    uiState.onClassSelected = onSelected

    local classOrder = {"warrior", "mage", "taoist"}
    local classIcons = {
        warrior = "武",
        mage    = "法",
        taoist  = "道",
    }
    local classGlowColors = {
        warrior = {200, 85, 45, 255},
        mage    = {50, 120, 210, 255},
        taoist  = {65, 190, 90, 255},
    }
    local classDescLines = {
        warrior = "近战之王\n刀光剑影，血战沙场",
        mage    = "法术宗师\n天雷地火，毁天灭地",
        taoist  = "万灵召唤\n驱使群兽，碾压一切",
    }

    local cards = {}
    for _, classId in ipairs(classOrder) do
        local cls = CharacterClass.Classes[classId]
        local glow = classGlowColors[classId]

        table.insert(cards, UI.Panel {
            width = 185,
            paddingVertical = 22,
            paddingHorizontal = 14,
            alignItems = "center",
            backgroundColor = {16, 12, 10, 245},
            borderRadius = 4,
            borderWidth = 2,
            borderColor = {60, 50, 38, 200},
            children = {
                -- 职业图标（深色底 + 发光边框圆）
                UI.Panel {
                    width = 88, height = 88,
                    borderRadius = 44,
                    backgroundColor = {8, 6, 5, 255},
                    borderWidth = 3,
                    borderColor = glow,
                    justifyContent = "center",
                    alignItems = "center",
                    children = {
                        UI.Label {
                            text = classIcons[classId],
                            fontSize = 38,
                            fontColor = glow,
                        },
                    },
                },
                -- 职业名（金色）
                UI.Label {
                    text = cls.name,
                    fontSize = 22,
                    fontColor = {210, 180, 75, 255},
                    marginTop = 14,
                },
                -- 职业描述（暗色）
                UI.Label {
                    text = classDescLines[classId],
                    fontSize = 11,
                    fontColor = {125, 115, 100, 190},
                    marginTop = 6,
                    textAlign = "center",
                },
                -- 分隔线
                UI.Panel {
                    width = "80%",
                    height = 1,
                    backgroundColor = {60, 50, 38, 100},
                    marginTop = 12,
                    marginBottom = 8,
                },
                -- 属性
                UI.Label {
                    text = "生命 " .. cls.baseHP,
                    fontSize = 11,
                    fontColor = {180, 80, 65, 200},
                },
                UI.Label {
                    text = "攻击 " .. cls.baseATK .. "  防御 " .. cls.baseDEF,
                    fontSize = 11,
                    fontColor = {140, 130, 115, 160},
                    marginTop = 3,
                },
                -- 选择按钮（石质暗色风格）
                UI.Button {
                    label = "进入山海",
                    marginTop = 16,
                    width = 130,
                    height = 40,
                    backgroundColor = {50, 40, 30, 240},
                    borderRadius = 4,
                    borderWidth = 1,
                    borderColor = {95, 80, 58, 180},
                    fontSize = 14,
                    fontColor = {210, 195, 155, 255},
                    onClick = function()
                        uiState.selectedClass = classId
                        GameUI.HideClassSelect()
                        if uiState.onClassSelected then
                            uiState.onClassSelected(classId)
                        end
                    end,
                },
            },
        })
    end

    uiState.selectRoot = UI.Panel {
        id = "classSelect",
        width = "100%",
        height = "100%",
        backgroundColor = {10, 8, 6, 252},
        justifyContent = "center",
        alignItems = "center",
        children = {
            -- 标题
            UI.Label {
                text = "贪玩渣渣灰",
                fontSize = 36,
                fontColor = {215, 185, 80, 255},
                marginBottom = 4,
            },
            UI.Label {
                text = "选择你的命运",
                fontSize = 13,
                fontColor = {110, 100, 85, 170},
                marginBottom = 30,
            },
            -- 三张卡片横排
            UI.Panel {
                flexDirection = "row",
                gap = 18,
                children = cards,
            },
        },
    }

    UI.SetRoot(uiState.selectRoot)
    print("[GameUI] Class select screen shown (dungeon style)")
end

function GameUI.HideClassSelect()
    uiState.selectRoot = nil
end

-- ============================================================================
-- 游戏 HUD
-- ============================================================================
function GameUI.ShowGameHUD(player)
    uiState.phase = "playing"
    uiState.player = player

    -- 初始化 GameHUD (摇杆)
    GameHUD.Initialize()
    local hud = GameHUD.Create({})
    uiState.joystick = hud.joystick

    -- 构建 HUD UI
    local hudRoot = UI.Panel {
        id = "gameHUD",
        width = "100%",
        height = "100%",
        pointerEvents = "box-none",
        children = {
            -- 左上角：角色等级信息（HP/MP 由 NanoVG 绘制）
            GameUI._CreatePlayerInfo(player),
            -- 右下角：技能栏
            GameUI._CreateSkillBar(player),
            -- 左下角：药瓶快捷键
            GameUI._CreatePotions(player),
            -- 右上角：小地图占位 + 击杀
            GameUI._CreateMiniMapArea(player),
        },
    }

    uiState.hudRoot = hudRoot
    UI.SetRoot(hudRoot)
    print("[GameUI] Game HUD shown for " .. player.className)
end

-- ============================================================================
-- 左上角 - 角色信息面板（简化版，HP/MP 由 NanoVG 绘制）
-- ============================================================================
function GameUI._CreatePlayerInfo(player)
    local classDef = CharacterClass.Classes[player.classId]
    local classColors = {
        warrior = {200, 85, 45, 255},
        mage    = {50, 120, 210, 255},
        taoist  = {65, 190, 90, 255},
    }
    local clr = classColors[player.classId]

    return UI.Panel {
        id = "playerInfo",
        position = "absolute",
        top = 8, left = 8,
        width = 170,
        padding = 8,
        backgroundColor = {12, 10, 8, 140},
        borderRadius = 6,
        borderWidth = 1,
        borderColor = {55, 45, 35, 100},
        children = {
            -- 职业标识 + 等级
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                children = {
                    UI.Panel {
                        width = 22, height = 22,
                        borderRadius = 11,
                        backgroundColor = clr,
                        justifyContent = "center",
                        alignItems = "center",
                        children = {
                            UI.Label {
                                text = string.sub(classDef.name, 1, 3),
                                fontSize = 9,
                                fontColor = {255, 255, 255, 255},
                            },
                        },
                    },
                    (function()
                        local lbl = UI.Label {
                            text = "Lv." .. player.level .. " " .. classDef.name,
                            fontSize = 12,
                            fontColor = {210, 195, 160, 255},
                            marginLeft = 6,
                        }
                        uiState.refs.playerLevel = lbl
                        return lbl
                    end)(),
                },
            },
            -- EXP 条（窄条）
            (function()
                local bar = UI.ProgressBar {
                    width = "100%",
                    height = 4,
                    marginTop = 6,
                    value = player.exp / math.max(1, player.expToNext),
                    backgroundColor = {25, 22, 18, 150},
                    fillColor = C.ExpGold,
                    borderRadius = 2,
                }
                uiState.refs.expBar = bar
                return bar
            end)(),
        },
    }
end

-- ============================================================================
-- 右下角 - 技能栏 (弧形排列)
-- ============================================================================
function GameUI._CreateSkillBar(player)
    local classDef = CharacterClass.Classes[player.classId]

    local btnSize = {72, 56, 56, 56, 56, 64}
    local positions = {
        {x = -50,  y = -50},
        {x = -120, y = -65},
        {x = -175, y = -105},
        {x = -215, y = -160},
        {x = -235, y = -225},
        {x = -90,  y = -130},
    }

    local skillClassColors = {
        warrior = {190, 60, 50},
        mage    = {70, 140, 175},
        taoist  = {55, 155, 95},
    }
    local baseClr = skillClassColors[player.classId]

    local skillBtns = {}
    uiState.skillButtons = {}

    for i = 1, 6 do
        local skill = player.equippedSkills[i]
        local size = btnSize[i]
        local pos = positions[i]
        local isUltimate = (i == 6)
        local skillName = skill and string.sub(skill.name, 1, 6) or ""
        local skillLvl = skill and CharacterClass.GetSkillLevel(skill, player.level) or 0

        local borderClr
        if isUltimate then
            borderClr = C.ExpGold
        else
            borderClr = {baseClr[1], baseClr[2], baseClr[3], 180}
        end

        local btnId = "skill_" .. i
        local btn = UI.Panel {
            id = btnId,
            position = "absolute",
            right = -pos.x - size / 2,
            bottom = -pos.y - size / 2,
            width = size,
            height = size,
            borderRadius = size / 2,
            backgroundColor = {25, 22, 18, 210},
            borderWidth = isUltimate and 3 or 2,
            borderColor = borderClr,
            justifyContent = "center",
            alignItems = "center",
            children = {
                UI.Label {
                    text = skillName,
                    fontSize = size <= 56 and 10 or 12,
                    fontColor = skillLvl > 0 and {240, 235, 220, 255} or {100, 100, 100, 150},
                    textAlign = "center",
                },
                (function()
                    local cdTextLbl = UI.Label {
                        text = "",
                        fontSize = 14,
                        fontColor = {255, 255, 255, 220},
                    }
                    local cdPanel = UI.Panel {
                        position = "absolute",
                        top = 0, left = 0,
                        width = size, height = size,
                        borderRadius = size / 2,
                        backgroundColor = {0, 0, 0, 0},
                        justifyContent = "center",
                        alignItems = "center",
                        children = { cdTextLbl },
                    }
                    uiState.refs["skill_" .. i .. "_cd"] = cdPanel
                    uiState.refs["skill_" .. i .. "_cdText"] = cdTextLbl
                    return cdPanel
                end)(),
                skillLvl > 0 and UI.Panel {
                    position = "absolute",
                    bottom = 2,
                    flexDirection = "row",
                    gap = 2,
                    children = GameUI._CreateLevelDots(skillLvl),
                } or nil,
            },
            onPointerUp = function()
                if GameUI.onSkillPressed then
                    GameUI.onSkillPressed(i, skill)
                end
            end,
        }

        table.insert(skillBtns, btn)
        uiState.skillButtons[i] = {
            panel = btn,
            skill = skill,
            size = size,
        }
    end

    return UI.Panel {
        id = "skillBar",
        position = "absolute",
        right = 0, bottom = 0,
        width = 300, height = 300,
        pointerEvents = "box-none",
        children = skillBtns,
    }
end

-- 技能等级墨点
function GameUI._CreateLevelDots(level)
    local dots = {}
    for i = 1, 3 do
        table.insert(dots, UI.Panel {
            width = 5, height = 5,
            borderRadius = 3,
            backgroundColor = i <= level and {220, 210, 190, 255} or {80, 80, 80, 100},
        })
    end
    return dots
end

-- ============================================================================
-- 左下角 - 药瓶快捷键
-- ============================================================================
function GameUI._CreatePotions(player)
    return UI.Panel {
        id = "potions",
        position = "absolute",
        left = 20, bottom = 20,
        flexDirection = "row",
        gap = 10,
        children = {
            UI.Panel {
                width = 44, height = 44,
                borderRadius = 22,
                backgroundColor = {40, 15, 15, 210},
                borderWidth = 2,
                borderColor = {160, 55, 45, 200},
                justifyContent = "center",
                alignItems = "center",
                onPointerUp = function()
                    if GameUI.onUseHpPotion then GameUI.onUseHpPotion() end
                end,
                children = {
                    UI.Label {
                        text = "HP",
                        fontSize = 11,
                        fontColor = {210, 75, 60, 255},
                    },
                },
            },
            UI.Panel {
                width = 44, height = 44,
                borderRadius = 22,
                backgroundColor = {15, 15, 40, 210},
                borderWidth = 2,
                borderColor = {55, 110, 170, 200},
                justifyContent = "center",
                alignItems = "center",
                onPointerUp = function()
                    if GameUI.onUseMpPotion then GameUI.onUseMpPotion() end
                end,
                children = {
                    UI.Label {
                        text = "MP",
                        fontSize = 11,
                        fontColor = {65, 130, 195, 255},
                    },
                },
            },
        },
    }
end

-- ============================================================================
-- 右上角 - 小地图 + 信息
-- ============================================================================
function GameUI._CreateMiniMapArea(player)
    return UI.Panel {
        id = "topRight",
        position = "absolute",
        top = 12, right = 12,
        alignItems = "flex-end",
        children = {
            UI.Panel {
                width = 80, height = 80,
                borderRadius = 40,
                backgroundColor = {15, 12, 10, 160},
                borderWidth = 1,
                borderColor = {55, 45, 35, 100},
                justifyContent = "center",
                alignItems = "center",
                children = {
                    UI.Label {
                        text = "MAP",
                        fontSize = 10,
                        fontColor = {90, 85, 75, 120},
                    },
                },
            },
            (function()
                local lbl = UI.Label {
                    text = "击杀: 0",
                    fontSize = 11,
                    fontColor = {170, 160, 140, 180},
                    marginTop = 8,
                    textAlign = "right",
                }
                uiState.refs.killCount = lbl
                return lbl
            end)(),
            (function()
                local lbl = UI.Label {
                    text = "金币: 0",
                    fontSize = 11,
                    fontColor = {255, 215, 80, 200},
                    marginTop = 4,
                    textAlign = "right",
                }
                uiState.refs.goldLabel = lbl
                return lbl
            end)(),
        },
    }
end

-- ============================================================================
-- HUD 更新
-- ============================================================================
function GameUI.UpdateHUD(player, dt)
    if uiState.phase ~= "playing" or not uiState.hudRoot then return end

    local refs = uiState.refs

    -- HP/MP 圆球由 NanoVG 实时绘制, 这里只更新 player 引用即可
    uiState.player = player

    -- EXP 条
    if refs.expBar then refs.expBar:SetValue(player.exp / math.max(1, player.expToNext)) end

    -- 等级标签
    if refs.playerLevel then
        local classDef = CharacterClass.Classes[player.classId]
        refs.playerLevel:SetText("Lv." .. player.level .. " " .. classDef.name)
    end

    -- 技能冷却显示
    for i = 1, 6 do
        local sb = uiState.skillButtons[i]
        if sb and sb.skill then
            local cd = player.cooldowns[sb.skill.id] or 0
            local cdPanel = refs["skill_" .. i .. "_cd"]
            local cdText  = refs["skill_" .. i .. "_cdText"]
            if cd > 0 then
                if cdPanel then cdPanel:SetStyle({ backgroundColor = {0, 0, 0, 140} }) end
                if cdText then cdText:SetText(string.format("%.0f", math.ceil(cd))) end
            else
                if cdPanel then cdPanel:SetStyle({ backgroundColor = {0, 0, 0, 0} }) end
                if cdText then cdText:SetText("") end
            end
        end
    end

    -- 开门过渡动画更新
    if doorState.active then
        doorState.progress = doorState.progress + dt / doorState.duration
        if doorState.progress >= 1 then
            doorState.progress = 1
            doorState.active = false
            if doorState.onComplete then doorState.onComplete() end
            print("[GameUI] Door transition complete")
        end
    end

    -- 飘字更新
    GameUI._UpdateFloatingTexts(dt)
end

-- ============================================================================
-- 伤害飘字系统
-- ============================================================================
function GameUI.AddFloatingText(text, worldPos, color)
    table.insert(uiState.floatingTexts, {
        text = text,
        worldPos = worldPos,
        color = color or {255, 255, 255, 255},
        timer = 0,
        duration = 1.2,
    })
end

function GameUI._UpdateFloatingTexts(dt)
    local i = 1
    while i <= #uiState.floatingTexts do
        local ft = uiState.floatingTexts[i]
        ft.timer = ft.timer + dt
        if ft.timer >= ft.duration then
            table.remove(uiState.floatingTexts, i)
        else
            i = i + 1
        end
    end
end

function GameUI.GetFloatingTexts()
    return uiState.floatingTexts
end

-- ============================================================================
-- 更新击杀计数
-- ============================================================================
function GameUI.UpdateKillCount(count)
    local label = uiState.refs.killCount
    if label then
        label:SetText("击杀: " .. count)
    end
end

-- ============================================================================
-- 更新金币显示
-- ============================================================================
function GameUI.UpdateGold(gold)
    local label = uiState.refs.goldLabel
    if label then
        label:SetText("金币: " .. gold)
    end
end

-- ============================================================================
-- 获取摇杆引用
-- ============================================================================
function GameUI.GetJoystick()
    return uiState.joystick
end

-- ============================================================================
-- 技能/药瓶回调 (由 main.lua 设置)
-- ============================================================================
GameUI.onSkillPressed = nil
GameUI.onUseHpPotion = nil
GameUI.onUseMpPotion = nil

-- ============================================================================
-- 清理
-- ============================================================================
function GameUI.Shutdown()
    if nvgCtx then
        nvgDelete(nvgCtx)
        nvgCtx = nil
    end
    UI.Shutdown()
end

return GameUI
