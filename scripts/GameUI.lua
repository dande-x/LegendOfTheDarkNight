-- ============================================================================
-- GameUI.lua — 贪玩渣渣灰 完整 UI 系统
-- 暗黑地牢风角色选择 + NanoVG 圆球 HP/MP + 开门过渡 + 技能栏 + 飘字
-- + 菜单/背包按钮 + 背包面板 + 施法条 + 伤害数字弹跳
-- ============================================================================

local UI = require("urhox-libs/UI")
local CharacterClass = require("scripts.CharacterClass")
local Inventory = require("scripts.Inventory")
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
    progress = 0,
    duration = 2.2,
    onComplete = nil,
}

-- ============================================================================
-- 施法条状态（由 main.lua 设置）
-- ============================================================================
local castBarState = {
    active = false,
    progress = 0,    -- 0~1
    skillName = "",
    isCharging = false, -- 法师蓄力状态
}

-- ============================================================================
-- 相机引用（用于世界坐标→屏幕坐标）
-- ============================================================================
local cameraRef = nil

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
    bagOpen = false,     -- 背包面板是否打开
    bagRoot = nil,       -- 背包面板 UI root
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
-- 初始化 NanoVG (HP/MP 圆球 + 开门过渡 + 伤害飘字)
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
-- 设置相机引用（world→screen 转换）
-- ============================================================================
function GameUI.SetCamera(cam)
    cameraRef = cam
end

-- ============================================================================
-- 施法条控制
-- ============================================================================
function GameUI.ShowCastBar(skillName, isCharging)
    castBarState.active = true
    castBarState.progress = 0
    castBarState.skillName = skillName or ""
    castBarState.isCharging = isCharging or false
end

function GameUI.UpdateCastBar(progress)
    castBarState.progress = progress
end

function GameUI.HideCastBar()
    castBarState.active = false
    castBarState.progress = 0
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

    -- 绘制伤害飘字
    if uiState.phase == "playing" and cameraRef then
        GameUI._DrawFloatingTexts(nvgCtx, sw, sh)
    end

    -- 绘制施法条
    if castBarState.active and uiState.phase == "playing" then
        GameUI._DrawCastBar(nvgCtx, sw, sh)
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
        nvgScissor(ctx, cx - r, cy - r, r, 2 * r)
        nvgIntersectScissor(ctx, cx - r, clipY, r, fillH)

        nvgBeginPath(ctx)
        nvgCircle(ctx, cx, cy, r - 1)
        local hpGrad = nvgRadialGradient(ctx, cx - r * 0.1, cy - r * 0.15, r * 0.1, r * 0.85,
            nvgRGBA(220, 55, 35, 210),
            nvgRGBA(110, 25, 15, 230))
        nvgFillPaint(ctx, hpGrad)
        nvgFill(ctx)

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
        nvgScissor(ctx, cx, cy - r, r, 2 * r)
        nvgIntersectScissor(ctx, cx, clipY, r, fillH)

        nvgBeginPath(ctx)
        nvgCircle(ctx, cx, cy, r - 1)
        local mpGrad = nvgRadialGradient(ctx, cx + r * 0.1, cy - r * 0.15, r * 0.1, r * 0.85,
            nvgRGBA(50, 110, 210, 210),
            nvgRGBA(25, 55, 120, 230))
        nvgFillPaint(ctx, mpGrad)
        nvgFill(ctx)

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

    -- 玻璃反光
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

        nvgFillColor(ctx, nvgRGBA(255, 200, 180, 230))
        nvgText(ctx, cx - r * 0.32, cy, tostring(math.floor(player.hp)), nil)

        nvgFillColor(ctx, nvgRGBA(180, 210, 255, 230))
        nvgText(ctx, cx + r * 0.32, cy, tostring(math.floor(player.mp)), nil)

        nvgFontSize(ctx, math.floor(8 * scale))
        nvgFillColor(ctx, nvgRGBA(190, 75, 55, 150))
        nvgText(ctx, cx - r * 0.35, cy + r + 9 * scale, "HP", nil)
        nvgFillColor(ctx, nvgRGBA(70, 140, 210, 150))
        nvgText(ctx, cx + r * 0.35, cy + r + 9 * scale, "MP", nil)
    end
end

-- ============================================================================
-- 伤害飘字 NanoVG 渲染（物理弹跳动画）
-- ============================================================================
function GameUI._DrawFloatingTexts(ctx, sw, sh)
    if nvgFontId < 0 or not cameraRef then return end

    local scale = sh / 720
    nvgFontFaceId(ctx, nvgFontId)

    for _, ft in ipairs(uiState.floatingTexts) do
        local t = ft.timer
        local dur = ft.duration

        -- 世界坐标 → 屏幕坐标
        local worldPos = ft.worldPos + Vector3(0, 1.5, 0)
        local screenPos = cameraRef:WorldToScreenPoint(worldPos)

        -- screenPos.x/y 是 0~1 归一化坐标
        local sx = screenPos.x * sw
        local sy = screenPos.y * sh

        -- 物理弹跳: 初速上方 -180, 重力 +350
        local vy0 = -180 * scale / 720
        local gravity = 350 * scale / 720
        local offsetY = (vy0 * t + 0.5 * gravity * t * t) * 720

        -- 水平随机偏移（每个飘字固定方向）
        local offsetX = ft.offsetX * scale * t * 30

        sy = sy + offsetY

        -- 缩放动画: 开始 1.8x 快速回落到 1.0x
        local popTime = 0.15
        local scaleAnim = 1.0
        if t < popTime then
            scaleAnim = 1.8 - 0.8 * (t / popTime)
        end

        -- 透明度: 最后 0.4 秒淡出
        local alpha = 1.0
        local fadeStart = dur - 0.4
        if t > fadeStart then
            alpha = 1.0 - (t - fadeStart) / 0.4
        end
        alpha = math.max(0, math.min(1, alpha))

        -- 字体大小
        local baseSize = ft.isCrit and 22 or 16
        local fontSize = math.floor(baseSize * scale * scaleAnim)
        nvgFontSize(ctx, fontSize)
        nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

        local c = ft.color
        local a = math.floor(c[4] * alpha)

        -- 描边（黑色阴影）
        nvgFillColor(ctx, nvgRGBA(0, 0, 0, math.floor(a * 0.7)))
        nvgText(ctx, sx + offsetX + 1.5 * scale, sy + 1.5 * scale, ft.text, nil)

        -- 正文
        nvgFillColor(ctx, nvgRGBA(c[1], c[2], c[3], a))
        nvgText(ctx, sx + offsetX, sy, ft.text, nil)
    end
end

-- ============================================================================
-- 施法条绘制
-- ============================================================================
function GameUI._DrawCastBar(ctx, sw, sh)
    local scale = sh / 720
    local barW = math.floor(180 * scale)
    local barH = math.floor(14 * scale)
    local bx = (sw - barW) / 2
    local by = sh * 0.55

    -- 背景
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, bx, by, barW, barH, 4 * scale)
    nvgFillColor(ctx, nvgRGBA(10, 8, 6, 200))
    nvgFill(ctx)

    -- 填充
    local fillW = barW * castBarState.progress
    if fillW > 0 then
        nvgBeginPath(ctx)
        nvgRoundedRect(ctx, bx, by, fillW, barH, 4 * scale)
        if castBarState.isCharging then
            -- 蓄力模式: 蓝色脉冲
            local pulse = 0.7 + 0.3 * math.sin(castBarState.progress * math.pi * 6)
            local pAlpha = math.floor(220 * pulse)
            nvgFillColor(ctx, nvgRGBA(60, 140, 255, pAlpha))
        else
            nvgFillColor(ctx, nvgRGBA(220, 180, 60, 220))
        end
        nvgFill(ctx)
    end

    -- 边框
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, bx, by, barW, barH, 4 * scale)
    nvgStrokeColor(ctx, nvgRGBA(140, 120, 80, 180))
    nvgStrokeWidth(ctx, 1.5 * scale)
    nvgStroke(ctx)

    -- 技能名
    if nvgFontId >= 0 and castBarState.skillName ~= "" then
        nvgFontFaceId(ctx, nvgFontId)
        nvgFontSize(ctx, math.floor(10 * scale))
        nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(ctx, nvgRGBA(255, 240, 200, 230))
        nvgText(ctx, sw / 2, by + barH / 2, castBarState.skillName, nil)
    end
end

-- ============================================================================
-- 开门过渡绘制
-- ============================================================================
function GameUI._DrawDoorTransition(ctx, sw, sh)
    local p = doorState.progress
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

        nvgBeginPath(ctx)
        nvgRect(ctx, leftW - 6, 0, 6, sh)
        nvgFillColor(ctx, nvgRGBA(70, 58, 42, 220))
        nvgFill(ctx)

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

        nvgBeginPath(ctx)
        nvgRect(ctx, rightX, 0, 6, sh)
        nvgFillColor(ctx, nvgRGBA(70, 58, 42, 220))
        nvgFill(ctx)

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

    -- 中缝光线
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

        nvgBeginPath(ctx)
        nvgRect(ctx, halfW - beamW / 2, 0, beamW, sh)
        local beamGrad2 = nvgLinearGradient(ctx,
            halfW + beamW / 2, 0, halfW - beamW / 2, 0,
            nvgRGBA(200, 170, 100, 0),
            nvgRGBA(220, 190, 120, beamAlpha))
        nvgFillPaint(ctx, beamGrad2)
        nvgFill(ctx)
    end

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
    uiState.bagOpen = false
    uiState.bagRoot = nil

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
                UI.Label {
                    text = cls.name,
                    fontSize = 22,
                    fontColor = {210, 180, 75, 255},
                    marginTop = 14,
                },
                UI.Label {
                    text = classDescLines[classId],
                    fontSize = 11,
                    fontColor = {125, 115, 100, 190},
                    marginTop = 6,
                    textAlign = "center",
                },
                UI.Panel {
                    width = "80%",
                    height = 1,
                    backgroundColor = {60, 50, 38, 100},
                    marginTop = 12,
                    marginBottom = 8,
                },
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
    uiState.bagOpen = false

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
            GameUI._CreatePlayerInfo(player),
            GameUI._CreateSkillBar(player),
            GameUI._CreatePotions(player),
            GameUI._CreateMiniMapArea(player),
            GameUI._CreateTopButtons(),
        },
    }

    uiState.hudRoot = hudRoot
    UI.SetRoot(hudRoot)
    print("[GameUI] Game HUD shown for " .. player.className)
end

-- ============================================================================
-- 左上角 - 角色信息面板
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
-- 右上角 - 菜单/背包按钮
-- ============================================================================
function GameUI._CreateTopButtons()
    return UI.Panel {
        id = "topButtons",
        position = "absolute",
        top = 100, right = 12,
        alignItems = "flex-end",
        gap = 8,
        children = {
            -- 背包按钮
            UI.Panel {
                width = 44, height = 44,
                borderRadius = 8,
                backgroundColor = {30, 25, 20, 220},
                borderWidth = 2,
                borderColor = {120, 100, 60, 180},
                justifyContent = "center",
                alignItems = "center",
                onPointerUp = function()
                    if GameUI.onBagToggle then GameUI.onBagToggle() end
                end,
                children = {
                    UI.Label {
                        text = "包",
                        fontSize = 16,
                        fontColor = {210, 180, 80, 255},
                    },
                },
            },
            -- 返回主菜单按钮
            UI.Panel {
                width = 44, height = 44,
                borderRadius = 8,
                backgroundColor = {30, 20, 18, 220},
                borderWidth = 2,
                borderColor = {140, 60, 50, 160},
                justifyContent = "center",
                alignItems = "center",
                onPointerUp = function()
                    if GameUI.onMenuPressed then GameUI.onMenuPressed() end
                end,
                children = {
                    UI.Label {
                        text = "退",
                        fontSize = 16,
                        fontColor = {200, 90, 70, 255},
                    },
                },
            },
        },
    }
end

-- ============================================================================
-- 右下角 - 技能栏
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
-- 背包/装备面板 (全屏遮罩)
-- ============================================================================
function GameUI.ShowBagPanel(player)
    if uiState.bagOpen then return end
    uiState.bagOpen = true

    local inv = Inventory.playerData
    local SLOT = Inventory.SLOT
    local RARITY = Inventory.RARITY

    -- 构建装备槽
    local slotNames = {
        { slot = SLOT.WEAPON,   label = "武器" },
        { slot = SLOT.ARMOR,    label = "防具" },
        { slot = SLOT.RING,     label = "戒指" },
        { slot = SLOT.NECKLACE, label = "项链" },
    }

    local equipSlots = {}
    for _, s in ipairs(slotNames) do
        local item = inv.equipped[s.slot]
        local itemName = item and item.name or "空"
        local rarity = item and RARITY[item.rarity] or nil
        local nameColor = rarity and rarity.color or {100, 100, 100, 150}
        local borderColor = rarity and {rarity.color[1], rarity.color[2], rarity.color[3], 120} or {50, 45, 38, 120}

        table.insert(equipSlots, UI.Panel {
            width = 110, height = 60,
            backgroundColor = {20, 16, 14, 220},
            borderRadius = 4,
            borderWidth = 1,
            borderColor = borderColor,
            paddingVertical = 6,
            paddingHorizontal = 8,
            children = {
                UI.Label {
                    text = s.label,
                    fontSize = 9,
                    fontColor = {140, 130, 115, 160},
                },
                UI.Label {
                    text = itemName,
                    fontSize = 12,
                    fontColor = nameColor,
                    marginTop = 3,
                },
                item and UI.Label {
                    text = (item.atk > 0 and ("攻+" .. item.atk) or "") ..
                           (item.def > 0 and (" 防+" .. item.def) or "") ..
                           (item.hp > 0 and (" 血+" .. item.hp) or ""),
                    fontSize = 9,
                    fontColor = {160, 155, 140, 150},
                    marginTop = 2,
                } or nil,
            },
        })
    end

    -- 构建背包格子
    local bagItems = {}
    for i = 1, 20 do
        local item = inv.bag[i]
        local itemName = item and string.sub(item.name, 1, 6) or ""
        local rarity = item and RARITY[item.rarity] or nil
        local nameColor = rarity and rarity.color or {80, 80, 80, 80}
        local bgColor = item and {25, 20, 18, 240} or {18, 15, 12, 150}
        local borderColor = rarity and {rarity.color[1], rarity.color[2], rarity.color[3], 80} or {40, 35, 30, 80}

        table.insert(bagItems, UI.Panel {
            width = 52, height = 52,
            backgroundColor = bgColor,
            borderRadius = 3,
            borderWidth = 1,
            borderColor = borderColor,
            justifyContent = "center",
            alignItems = "center",
            children = {
                UI.Label {
                    text = itemName,
                    fontSize = 9,
                    fontColor = nameColor,
                    textAlign = "center",
                },
            },
        })
    end

    -- 面板整体
    uiState.bagRoot = UI.Panel {
        id = "bagOverlay",
        width = "100%",
        height = "100%",
        backgroundColor = {0, 0, 0, 160},
        justifyContent = "center",
        alignItems = "center",
        children = {
            UI.Panel {
                width = 360, height = 420,
                backgroundColor = {16, 12, 10, 245},
                borderRadius = 8,
                borderWidth = 2,
                borderColor = {80, 65, 45, 180},
                padding = 16,
                children = {
                    -- 标题栏
                    UI.Panel {
                        flexDirection = "row",
                        justifyContent = "space-between",
                        width = "100%",
                        marginBottom = 12,
                        children = {
                            UI.Label {
                                text = "装备 / 背包",
                                fontSize = 16,
                                fontColor = {210, 185, 80, 255},
                            },
                            UI.Label {
                                text = "金币: " .. inv.gold,
                                fontSize = 13,
                                fontColor = {255, 215, 80, 220},
                            },
                        },
                    },
                    -- 装备区
                    UI.Panel {
                        flexDirection = "row",
                        flexWrap = "wrap",
                        gap = 6,
                        marginBottom = 12,
                        children = equipSlots,
                    },
                    -- 分隔线
                    UI.Panel {
                        width = "100%", height = 1,
                        backgroundColor = {60, 50, 38, 100},
                        marginBottom = 10,
                    },
                    -- 背包标题
                    UI.Label {
                        text = "背包 (" .. #inv.bag .. "/20)",
                        fontSize = 11,
                        fontColor = {140, 130, 115, 160},
                        marginBottom = 6,
                    },
                    -- 背包格子
                    UI.Panel {
                        flexDirection = "row",
                        flexWrap = "wrap",
                        gap = 4,
                        children = bagItems,
                    },
                    -- 关闭按钮
                    UI.Panel {
                        width = "100%",
                        alignItems = "center",
                        marginTop = 12,
                        children = {
                            UI.Button {
                                label = "关闭",
                                width = 100, height = 34,
                                backgroundColor = {50, 40, 30, 240},
                                borderRadius = 4,
                                borderWidth = 1,
                                borderColor = {95, 80, 58, 180},
                                fontSize = 13,
                                fontColor = {210, 195, 155, 255},
                                onClick = function()
                                    GameUI.HideBagPanel()
                                end,
                            },
                        },
                    },
                },
            },
        },
    }

    UI.SetRoot(uiState.bagRoot)
    print("[GameUI] Bag panel opened")
end

function GameUI.HideBagPanel()
    if not uiState.bagOpen then return end
    uiState.bagOpen = false
    uiState.bagRoot = nil
    -- 恢复 HUD
    if uiState.hudRoot then
        UI.SetRoot(uiState.hudRoot)
    end
    print("[GameUI] Bag panel closed")
end

function GameUI.IsBagOpen()
    return uiState.bagOpen
end

-- ============================================================================
-- HUD 更新
-- ============================================================================
function GameUI.UpdateHUD(player, dt)
    if uiState.phase ~= "playing" then return end
    -- 如果背包打开，不更新 HUD widget（但 NanoVG 仍然绘制）
    if uiState.bagOpen then
        uiState.player = player
        -- 开门动画仍需更新
        if doorState.active then
            doorState.progress = doorState.progress + dt / doorState.duration
            if doorState.progress >= 1 then
                doorState.progress = 1
                doorState.active = false
                if doorState.onComplete then doorState.onComplete() end
            end
        end
        GameUI._UpdateFloatingTexts(dt)
        return
    end

    if not uiState.hudRoot then return end

    local refs = uiState.refs
    uiState.player = player

    if refs.expBar then refs.expBar:SetValue(player.exp / math.max(1, player.expToNext)) end

    if refs.playerLevel then
        local classDef = CharacterClass.Classes[player.classId]
        refs.playerLevel:SetText("Lv." .. player.level .. " " .. classDef.name)
    end

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
function GameUI.AddFloatingText(text, worldPos, color, isCrit)
    table.insert(uiState.floatingTexts, {
        text = text,
        worldPos = worldPos,
        color = color or {255, 255, 255, 255},
        timer = 0,
        duration = 1.2,
        isCrit = isCrit or false,
        offsetX = (math.random() - 0.5) * 2, -- 随机水平偏移方向 -1~1
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
-- 技能/药瓶/菜单/背包回调 (由 main.lua 设置)
-- ============================================================================
GameUI.onSkillPressed = nil
GameUI.onUseHpPotion = nil
GameUI.onUseMpPotion = nil
GameUI.onMenuPressed = nil
GameUI.onBagToggle = nil

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
