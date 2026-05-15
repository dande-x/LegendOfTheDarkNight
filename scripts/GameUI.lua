-- ============================================================================
-- GameUI.lua — 贪玩渣渣灰 完整 UI 系统
-- 暗黑地牢风角色选择 + NanoVG 圆球 HP/MP (左下角) + EXP条 + 开门过渡
-- + 技能栏 + 飘字 + 菜单/背包按钮 + 背包面板 + 施法条 + 技能选择面板
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
    isCharging = false,
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
    bagOpen = false,
    bagRoot = nil,
    skillPanelOpen = false,
    skillPanelRoot = nil,
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
-- 初始化 NanoVG
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

function HandleNanoVGRender(eventType, eventData)
    if not nvgCtx then return end
    GameUI._RenderNanoVG()
end

-- ============================================================================
-- 设置相机引用
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

    -- 绘制 HP/MP 圆球 + EXP 条 (仅游戏阶段，左下角)
    if uiState.phase == "playing" and uiState.player then
        GameUI._DrawOrbs(nvgCtx, sw, sh)
    end

    -- 绘制敌人头顶血条
    if uiState.phase == "playing" and cameraRef then
        GameUI._DrawEnemyHealthBars(nvgCtx, sw, sh)
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
-- HP/MP 合体圆球 + EXP条 + 等级 (左下角)
-- ============================================================================
function GameUI._DrawOrbs(ctx, sw, sh)
    local scale = sh / 720
    local player = uiState.player

    local r  = math.floor(38 * scale)
    local cx = math.floor(55 * scale)
    local cy = sh - math.floor(75 * scale)  -- 左下角

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

    -- ======== 等级标签 (球上方) ========
    if nvgFontId >= 0 then
        nvgFontFaceId(ctx, nvgFontId)
        nvgFontSize(ctx, math.floor(12 * scale))
        nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)

        -- 暗底衬托
        nvgFillColor(ctx, nvgRGBA(0, 0, 0, 140))
        nvgText(ctx, cx + 1, cy - r - 4 * scale + 1, "Lv." .. player.level, nil)
        -- 文字
        nvgFillColor(ctx, nvgRGBA(210, 195, 160, 255))
        nvgText(ctx, cx, cy - r - 4 * scale, "Lv." .. player.level, nil)
    end

    -- ======== 经验条 (球下方) ========
    local expProg = player.exp / math.max(1, player.expToNext)
    local barW = math.floor(90 * scale)
    local barH = math.floor(6 * scale)
    local barX = cx - barW / 2
    local barY = cy + r + math.floor(18 * scale)

    -- 经验条背景
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, barX, barY, barW, barH, 3 * scale)
    nvgFillColor(ctx, nvgRGBA(15, 12, 10, 200))
    nvgFill(ctx)

    -- 经验条填充
    if expProg > 0 then
        nvgBeginPath(ctx)
        nvgRoundedRect(ctx, barX, barY, barW * expProg, barH, 3 * scale)
        nvgFillColor(ctx, nvgRGBA(210, 180, 80, 220))
        nvgFill(ctx)
    end

    -- 经验条边框
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, barX, barY, barW, barH, 3 * scale)
    nvgStrokeColor(ctx, nvgRGBA(120, 100, 60, 140))
    nvgStrokeWidth(ctx, 1.0 * scale)
    nvgStroke(ctx)

    -- EXP 文字
    if nvgFontId >= 0 then
        nvgFontSize(ctx, math.floor(8 * scale))
        nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(ctx, nvgRGBA(210, 180, 80, 180))
        nvgText(ctx, cx, barY + barH + 2 * scale,
            "EXP " .. math.floor(expProg * 100) .. "%", nil)
    end
end

-- ============================================================================
-- 伤害飘字 NanoVG 渲染（物理弹跳动画）
-- ============================================================================
-- ============================================================================
-- 敌人头顶血条 (黑框红条+白色数字)
-- ============================================================================
function GameUI._DrawEnemyHealthBars(ctx, sw, sh)
    if nvgFontId < 0 or not cameraRef then return end

    local Combat = require("scripts.Combat")
    local enemies = Combat.enemies
    if not enemies or #enemies == 0 then return end

    local scale = sh / 720
    local barW = math.floor(48 * scale)
    local barH = math.floor(5 * scale)
    local borderW = math.floor(1 * scale)
    local fontSize = math.max(8, math.floor(10 * scale))
    local yOffset = math.floor(18 * scale)  -- 血条在头顶上方的偏移

    nvgFontFaceId(ctx, nvgFontId)
    nvgFontSize(ctx, fontSize)
    nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)

    for _, e in ipairs(enemies) do
        if e.node and e.hp > 0 then
            -- 头顶位置 (角色高度约1.5m)
            local headPos = e.node.position + Vector3(0, 1.8, 0)
            local screenPos = cameraRef:WorldToScreenPoint(headPos)

            -- 不在屏幕内则跳过
            if screenPos.z > 0 and screenPos.x > -0.1 and screenPos.x < 1.1
                and screenPos.y > -0.1 and screenPos.y < 1.1 then

                local sx = screenPos.x * sw
                local sy = screenPos.y * sh - yOffset

                local hpRatio = math.max(0, math.min(1, e.hp / e.maxHP))

                -- 黑色背景框
                nvgBeginPath(ctx)
                nvgRoundedRect(ctx, sx - barW / 2 - borderW, sy - barH / 2 - borderW,
                    barW + borderW * 2, barH + borderW * 2, 2 * scale)
                nvgFillColor(ctx, nvgRGBA(0, 0, 0, 200))
                nvgFill(ctx)

                -- 红色血条
                if hpRatio > 0 then
                    local fillW = math.max(1, barW * hpRatio)
                    nvgBeginPath(ctx)
                    nvgRoundedRect(ctx, sx - barW / 2, sy - barH / 2,
                        fillW, barH, 1.5 * scale)

                    -- 血量低变黄/红
                    if hpRatio > 0.5 then
                        nvgFillColor(ctx, nvgRGBA(200, 40, 40, 230))
                    elseif hpRatio > 0.25 then
                        nvgFillColor(ctx, nvgRGBA(220, 140, 30, 230))
                    else
                        nvgFillColor(ctx, nvgRGBA(220, 50, 50, 255))
                    end
                    nvgFill(ctx)
                end

                -- 白色数字（HP/MaxHP）
                local hpText = tostring(math.floor(e.hp))
                -- 阴影
                nvgFillColor(ctx, nvgRGBA(0, 0, 0, 180))
                nvgText(ctx, sx + 1, sy - barH / 2 - 2 * scale + 1, hpText, nil)
                -- 正文
                nvgFillColor(ctx, nvgRGBA(255, 255, 255, 240))
                nvgText(ctx, sx, sy - barH / 2 - 2 * scale, hpText, nil)
            end
        end
    end
end

function GameUI._DrawFloatingTexts(ctx, sw, sh)
    if nvgFontId < 0 or not cameraRef then return end

    local scale = sh / 720
    nvgFontFaceId(ctx, nvgFontId)

    for _, ft in ipairs(uiState.floatingTexts) do
        local t = ft.timer
        local dur = ft.duration

        local worldPos = ft.worldPos + Vector3(0, 1.5, 0)
        local screenPos = cameraRef:WorldToScreenPoint(worldPos)

        local sx = screenPos.x * sw
        local sy = screenPos.y * sh

        local vy0 = -180 * scale / 720
        local gravity = 350 * scale / 720
        local offsetY = (vy0 * t + 0.5 * gravity * t * t) * 720

        local offsetX = ft.offsetX * scale * t * 30

        sy = sy + offsetY

        local popTime = 0.15
        local scaleAnim = 1.0
        if t < popTime then
            scaleAnim = 1.8 - 0.8 * (t / popTime)
        end

        local alpha = 1.0
        local fadeStart = dur - 0.4
        if t > fadeStart then
            alpha = 1.0 - (t - fadeStart) / 0.4
        end
        alpha = math.max(0, math.min(1, alpha))

        local baseSize = ft.isCrit and 22 or 16
        local fontSize = math.floor(baseSize * scale * scaleAnim)
        nvgFontSize(ctx, fontSize)
        nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

        local c = ft.color
        local a = math.floor(c[4] * alpha)

        nvgFillColor(ctx, nvgRGBA(0, 0, 0, math.floor(a * 0.7)))
        nvgText(ctx, sx + offsetX + 1.5 * scale, sy + 1.5 * scale, ft.text, nil)

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

    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, bx, by, barW, barH, 4 * scale)
    nvgFillColor(ctx, nvgRGBA(10, 8, 6, 200))
    nvgFill(ctx)

    local fillW = barW * castBarState.progress
    if fillW > 0 then
        nvgBeginPath(ctx)
        nvgRoundedRect(ctx, bx, by, fillW, barH, 4 * scale)
        if castBarState.isCharging then
            local pulse = 0.7 + 0.3 * math.sin(castBarState.progress * math.pi * 6)
            local pAlpha = math.floor(220 * pulse)
            nvgFillColor(ctx, nvgRGBA(60, 140, 255, pAlpha))
        else
            nvgFillColor(ctx, nvgRGBA(220, 180, 60, 220))
        end
        nvgFill(ctx)
    end

    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, bx, by, barW, barH, 4 * scale)
    nvgStrokeColor(ctx, nvgRGBA(140, 120, 80, 180))
    nvgStrokeWidth(ctx, 1.5 * scale)
    nvgStroke(ctx)

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
    uiState.skillPanelOpen = false
    uiState.skillPanelRoot = nil

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
-- 游戏 HUD（去掉左上角 playerInfo，改由 NanoVG 绘制）
-- ============================================================================
function GameUI.ShowGameHUD(player)
    uiState.phase = "playing"
    uiState.player = player
    uiState.bagOpen = false
    uiState.skillPanelOpen = false

    GameHUD.Initialize()
    local hud = GameHUD.Create({})
    uiState.joystick = hud.joystick
    -- 隐藏 WASD 按键提示（保留键盘响应）
    if hud.joystick then
        hud.joystick.showKeyHints = false
    end

    local hudRoot = UI.Panel {
        id = "gameHUD",
        width = "100%",
        height = "100%",
        pointerEvents = "box-none",
        children = {
            GameUI._CreateSkillBar(player),
            GameUI._CreateMiniMapArea(player),
            GameUI._CreateTopButtons(),
        },
    }

    uiState.hudRoot = hudRoot
    UI.SetRoot(hudRoot)
    print("[GameUI] Game HUD shown for " .. player.className)
end

-- ============================================================================
-- 右上角按钮 (菜单 + 背包 + 技能)
-- ============================================================================
function GameUI._CreateTopButtons()
    return UI.Panel {
        id = "topButtons",
        position = "absolute",
        top = 100, right = 12,
        alignItems = "flex-end",
        gap = 8,
        children = {
            -- 技能配置按钮
            UI.Panel {
                width = 44, height = 44,
                borderRadius = 8,
                backgroundColor = {25, 25, 35, 220},
                borderWidth = 2,
                borderColor = {80, 120, 180, 180},
                justifyContent = "center",
                alignItems = "center",
                onPointerUp = function()
                    if GameUI.onSkillPanelToggle then GameUI.onSkillPanelToggle() end
                end,
                children = {
                    UI.Label {
                        text = "技",
                        fontSize = 16,
                        fontColor = {100, 170, 240, 255},
                    },
                },
            },
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
-- 左下角 - 药瓶快捷键（球的右侧偏移）
-- ============================================================================
function GameUI._CreatePotions(player)
    return UI.Panel {
        id = "potions",
        position = "absolute",
        left = 115, bottom = 50,
        flexDirection = "column",
        gap = 8,
        children = {
            UI.Panel {
                width = 40, height = 40,
                borderRadius = 20,
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
                        fontSize = 10,
                        fontColor = {210, 75, 60, 255},
                    },
                },
            },
            UI.Panel {
                width = 40, height = 40,
                borderRadius = 20,
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
                        fontSize = 10,
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
-- 技能选择面板（全屏遮罩）
-- ============================================================================
function GameUI.ShowSkillPanel(player)
    if uiState.skillPanelOpen then return end
    uiState.skillPanelOpen = true

    local classDef = CharacterClass.Classes[player.classId]
    local allSkills = classDef.skills

    local classColors = {
        warrior = {200, 85, 45, 255},
        mage    = {50, 120, 210, 255},
        taoist  = {65, 190, 90, 255},
    }
    local clr = classColors[player.classId]

    -- 构建技能行列表
    local skillRows = {}

    for _, skill in ipairs(allSkills) do
        local slvl = CharacterClass.GetSkillLevel(skill, player.level)
        local locked = (slvl == 0)

        -- 判断该技能是否已装备，以及装在第几槽
        local equippedSlot = 0
        for s = 1, 6 do
            if player.equippedSkills[s] and player.equippedSkills[s].id == skill.id then
                equippedSlot = s
                break
            end
        end

        -- 解锁条件文本
        local unlockText = ""
        if skill.unlockLevels then
            local parts = {}
            for i, lv in ipairs(skill.unlockLevels) do
                local star = player.level >= lv and "★" or "☆"
                table.insert(parts, star .. "Lv." .. lv)
            end
            unlockText = table.concat(parts, " ")
        end

        -- 技能类型文字
        local typeNames = {
            melee = "近战", ranged = "远程", aoe = "范围",
            buff = "增益", heal = "治愈", dot = "持续", dash = "位移", summon = "召唤",
        }
        local typeName = typeNames[skill.type] or skill.type

        -- 状态标签
        local statusText = ""
        local statusColor = {100, 100, 100, 150}
        if locked then
            statusText = "未解锁"
            statusColor = {150, 60, 60, 200}
        elseif equippedSlot > 0 then
            statusText = "槽位 " .. equippedSlot
            statusColor = clr
        else
            statusText = "未装备"
            statusColor = {160, 150, 120, 200}
        end

        local nameColor = locked and {100, 100, 100, 150} or {240, 235, 220, 255}
        local descColor = locked and {80, 80, 80, 120} or {160, 150, 130, 200}

        local skillId = skill.id
        table.insert(skillRows, UI.Panel {
            width = "100%",
            flexDirection = "row",
            alignItems = "center",
            paddingVertical = 8,
            paddingHorizontal = 10,
            backgroundColor = equippedSlot > 0 and {35, 30, 25, 200} or {20, 16, 14, 180},
            borderRadius = 4,
            borderWidth = equippedSlot > 0 and 1 or 0,
            borderColor = equippedSlot > 0 and {clr[1], clr[2], clr[3], 80} or {0,0,0,0},
            children = {
                -- 技能名区
                UI.Panel {
                    width = 130,
                    children = {
                        UI.Panel {
                            flexDirection = "row",
                            alignItems = "center",
                            gap = 6,
                            children = {
                                UI.Label {
                                    text = skill.name,
                                    fontSize = 13,
                                    fontColor = nameColor,
                                },
                                UI.Label {
                                    text = "[" .. typeName .. "]",
                                    fontSize = 9,
                                    fontColor = {140, 130, 115, 140},
                                },
                            },
                        },
                        UI.Label {
                            text = skill.desc or "",
                            fontSize = 9,
                            fontColor = descColor,
                            marginTop = 2,
                        },
                        UI.Label {
                            text = unlockText,
                            fontSize = 9,
                            fontColor = {180, 160, 80, 180},
                            marginTop = 2,
                        },
                    },
                },
                -- CD / 耗蓝
                UI.Panel {
                    width = 70,
                    alignItems = "center",
                    children = {
                        UI.Label {
                            text = skill.manaCost > 0 and ("耗蓝 " .. skill.manaCost) or "免费",
                            fontSize = 9,
                            fontColor = {100, 160, 220, 180},
                        },
                        UI.Label {
                            text = skill.cooldown > 0 and ("CD " .. skill.cooldown .. "s") or "",
                            fontSize = 9,
                            fontColor = {160, 140, 100, 140},
                            marginTop = 2,
                        },
                    },
                },
                -- 状态 + 装备按钮
                UI.Panel {
                    width = 80,
                    alignItems = "center",
                    children = {
                        UI.Label {
                            text = statusText,
                            fontSize = 10,
                            fontColor = statusColor,
                        },
                        not locked and UI.Panel {
                            width = 60, height = 26,
                            borderRadius = 4,
                            backgroundColor = equippedSlot > 0 and {60, 30, 25, 220} or {30, 45, 30, 220},
                            borderWidth = 1,
                            borderColor = equippedSlot > 0 and {160, 70, 60, 160} or {80, 140, 80, 160},
                            justifyContent = "center",
                            alignItems = "center",
                            marginTop = 4,
                            onPointerUp = function()
                                if equippedSlot > 0 then
                                    -- 卸下
                                    player.equippedSkills[equippedSlot] = nil
                                else
                                    -- 装备到第一个空槽
                                    local placed = false
                                    for s = 1, 6 do
                                        if player.equippedSkills[s] == nil then
                                            player.equippedSkills[s] = skill
                                            placed = true
                                            break
                                        end
                                    end
                                    if not placed then
                                        -- 所有槽位已满，替换第1槽
                                        player.equippedSkills[1] = skill
                                    end
                                end
                                -- 刷新面板
                                GameUI.HideSkillPanel()
                                GameUI.ShowSkillPanel(player)
                            end,
                            children = {
                                UI.Label {
                                    text = equippedSlot > 0 and "卸下" or "装备",
                                    fontSize = 10,
                                    fontColor = equippedSlot > 0 and {200, 90, 70, 255} or {120, 200, 120, 255},
                                },
                            },
                        } or nil,
                    },
                },
            },
        })
    end

    uiState.skillPanelRoot = UI.Panel {
        id = "skillPanelOverlay",
        width = "100%",
        height = "100%",
        backgroundColor = {0, 0, 0, 170},
        justifyContent = "center",
        alignItems = "center",
        children = {
            UI.Panel {
                width = 380, height = 480,
                backgroundColor = {16, 12, 10, 248},
                borderRadius = 8,
                borderWidth = 2,
                borderColor = {80, 65, 45, 180},
                padding = 14,
                children = {
                    -- 标题
                    UI.Panel {
                        flexDirection = "row",
                        justifyContent = "space-between",
                        width = "100%",
                        marginBottom = 10,
                        children = {
                            UI.Label {
                                text = "技能配置 — " .. classDef.name,
                                fontSize = 16,
                                fontColor = {210, 185, 80, 255},
                            },
                            UI.Label {
                                text = "Lv." .. player.level,
                                fontSize = 13,
                                fontColor = {180, 170, 150, 200},
                            },
                        },
                    },
                    UI.Label {
                        text = "点击【装备/卸下】调整槽位（最多6个技能）",
                        fontSize = 10,
                        fontColor = {130, 120, 105, 160},
                        marginBottom = 8,
                    },
                    -- 分隔线
                    UI.Panel {
                        width = "100%", height = 1,
                        backgroundColor = {60, 50, 38, 100},
                        marginBottom = 8,
                    },
                    -- 技能列表 (scrollable area)
                    UI.Panel {
                        width = "100%",
                        height = 340,
                        overflow = "scroll",
                        gap = 4,
                        children = skillRows,
                    },
                    -- 关闭按钮
                    UI.Panel {
                        width = "100%",
                        alignItems = "center",
                        marginTop = 10,
                        children = {
                            UI.Button {
                                label = "确认并关闭",
                                width = 120, height = 34,
                                backgroundColor = {50, 40, 30, 240},
                                borderRadius = 4,
                                borderWidth = 1,
                                borderColor = {95, 80, 58, 180},
                                fontSize = 13,
                                fontColor = {210, 195, 155, 255},
                                onClick = function()
                                    GameUI.HideSkillPanel()
                                    -- 通知 main.lua 刷新 HUD
                                    if GameUI.onSkillPanelClosed then
                                        GameUI.onSkillPanelClosed()
                                    end
                                end,
                            },
                        },
                    },
                },
            },
        },
    }

    UI.SetRoot(uiState.skillPanelRoot)
    print("[GameUI] Skill panel opened")
end

function GameUI.HideSkillPanel()
    if not uiState.skillPanelOpen then return end
    uiState.skillPanelOpen = false
    uiState.skillPanelRoot = nil
    if uiState.hudRoot then
        UI.SetRoot(uiState.hudRoot)
    end
    print("[GameUI] Skill panel closed")
end

function GameUI.IsSkillPanelOpen()
    return uiState.skillPanelOpen
end

--- 刷新技能栏按钮（技能面板关闭后重建HUD以反映新配置）
function GameUI.RefreshSkillButtons(player)
    if not player then return end
    -- 重建整个 HUD（最可靠的方式，确保按钮回调绑定到新技能）
    GameUI.ShowGameHUD(player)
    print("[GameUI] Skill buttons refreshed")
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
                    UI.Panel {
                        flexDirection = "row",
                        flexWrap = "wrap",
                        gap = 6,
                        marginBottom = 12,
                        children = equipSlots,
                    },
                    UI.Panel {
                        width = "100%", height = 1,
                        backgroundColor = {60, 50, 38, 100},
                        marginBottom = 10,
                    },
                    UI.Label {
                        text = "背包 (" .. #inv.bag .. "/20)",
                        fontSize = 11,
                        fontColor = {140, 130, 115, 160},
                        marginBottom = 6,
                    },
                    UI.Panel {
                        flexDirection = "row",
                        flexWrap = "wrap",
                        gap = 4,
                        children = bagItems,
                    },
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
    if uiState.bagOpen or uiState.skillPanelOpen then
        uiState.player = player
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

    uiState.player = player

    for i = 1, 6 do
        local sb = uiState.skillButtons[i]
        if sb and sb.skill then
            local cd = player.cooldowns[sb.skill.id] or 0
            local cdPanel = uiState.refs["skill_" .. i .. "_cd"]
            local cdText  = uiState.refs["skill_" .. i .. "_cdText"]
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
        offsetX = (math.random() - 0.5) * 2,
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
-- 更新击杀计数 / 金币显示
-- ============================================================================
function GameUI.UpdateKillCount(count)
    local label = uiState.refs.killCount
    if label then
        label:SetText("击杀: " .. count)
    end
end

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
-- 回调 (由 main.lua 设置)
-- ============================================================================
GameUI.onSkillPressed = nil
GameUI.onUseHpPotion = nil
GameUI.onUseMpPotion = nil
GameUI.onMenuPressed = nil
GameUI.onBagToggle = nil
GameUI.onSkillPanelToggle = nil
GameUI.onSkillPanelClosed = nil

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
