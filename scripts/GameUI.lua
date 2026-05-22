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
    charPanelOpen = false,
    charPanelRoot = nil,
    systemPanelOpen = false,
    systemPanelRoot = nil,
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

    -- 绘制敌人头顶血条（pcall 保护，防止崩溃阻断 nvgEndFrame）
    if uiState.phase == "playing" and cameraRef then
        local ok, err = pcall(GameUI._DrawEnemyHealthBars, nvgCtx, sw, sh)
        if not ok then
            if not _hpBarErrorCount then _hpBarErrorCount = 0 end
            _hpBarErrorCount = _hpBarErrorCount + 1
            if _hpBarErrorCount <= 5 then
                print("[GameUI] EnemyHealthBars error #" .. _hpBarErrorCount .. ": " .. tostring(err))
            end
        end
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

    local r  = math.floor(52 * scale)
    local cx = math.floor(72 * scale)
    local cy = sh - math.floor(105 * scale)  -- 左下角

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
        nvgFontSize(ctx, math.floor(15 * scale))
        nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

        nvgFillColor(ctx, nvgRGBA(255, 200, 180, 230))
        nvgText(ctx, cx - r * 0.32, cy, tostring(math.floor(player.hp)), nil)

        nvgFillColor(ctx, nvgRGBA(180, 210, 255, 230))
        nvgText(ctx, cx + r * 0.32, cy, tostring(math.floor(player.mp)), nil)
    end

    -- ======== 等级标签(嵌在球底) + 经验条(紧贴球下) ========
    local expProg = player.exp / math.max(1, player.expToNext)
    local expFontSize = math.floor(10 * scale)

    -- ---- 等级标签：药丸形，嵌在球底部边缘 ----
    local lvText = "Lv." .. player.level
    local lvFontSize = math.floor(13 * scale)
    local pillH = math.floor(18 * scale)
    local pillW = math.floor(46 * scale)
    local pillX = cx - pillW / 2
    local pillY = cy + r - pillH * 0.45  -- 向上嵌入球底边缘

    -- 药丸底色（深色）
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, pillX, pillY, pillW, pillH, pillH / 2)
    nvgFillColor(ctx, nvgRGBA(18, 14, 10, 245))
    nvgFill(ctx)

    -- 药丸金色边框
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, pillX, pillY, pillW, pillH, pillH / 2)
    nvgStrokeColor(ctx, nvgRGBA(200, 170, 60, 210))
    nvgStrokeWidth(ctx, 1.8 * scale)
    nvgStroke(ctx)

    -- 等级文字
    if nvgFontId >= 0 then
        nvgFontFaceId(ctx, nvgFontId)
        nvgFontSize(ctx, lvFontSize)
        nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        -- 阴影
        nvgFillColor(ctx, nvgRGBA(0, 0, 0, 200))
        nvgText(ctx, cx + 1, pillY + pillH / 2 + 1, lvText, nil)
        -- 金色文字
        nvgFillColor(ctx, nvgRGBA(255, 225, 100, 255))
        nvgText(ctx, cx, pillY + pillH / 2, lvText, nil)
    end

    -- ---- 经验条：紧贴球下方，宽度与球直径一致 ----
    local barW = r * 2 + math.floor(16 * scale)  -- 略宽于球直径
    local barH = math.floor(8 * scale)            -- 薄条
    local barX = cx - barW / 2
    local barY = cy + r + pillH * 0.55 + math.floor(4 * scale)
    local barCenterY = barY + barH / 2

    -- 外框阴影
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, barX - 1, barY - 1, barW + 2, barH + 2, (barH / 2) + 1)
    nvgFillColor(ctx, nvgRGBA(0, 0, 0, 80))
    nvgFill(ctx)

    -- 经验条背景（深色凹槽）
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, barX, barY, barW, barH, barH / 2)
    local barBgGrad = nvgLinearGradient(ctx, barX, barY, barX, barY + barH,
        nvgRGBA(8, 6, 5, 220),
        nvgRGBA(20, 16, 12, 230))
    nvgFillPaint(ctx, barBgGrad)
    nvgFill(ctx)

    -- 经验条填充（金色渐变）
    if expProg > 0 then
        local fillW = math.max(barH * 0.6, barW * expProg)
        nvgBeginPath(ctx)
        nvgRoundedRect(ctx, barX, barY, fillW, barH, barH / 2)
        local expGrad = nvgLinearGradient(ctx, barX, barY, barX, barY + barH,
            nvgRGBA(255, 225, 80, 245),
            nvgRGBA(195, 145, 25, 225))
        nvgFillPaint(ctx, expGrad)
        nvgFill(ctx)

        -- 顶部高光
        nvgBeginPath(ctx)
        nvgRoundedRect(ctx, barX + 2 * scale, barY + 1 * scale,
            fillW - 4 * scale, barH * 0.35, barH * 0.17)
        nvgFillColor(ctx, nvgRGBA(255, 255, 220, 50))
        nvgFill(ctx)
    end

    -- 经验条边框
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, barX, barY, barW, barH, barH / 2)
    nvgStrokeColor(ctx, nvgRGBA(130, 105, 45, 140))
    nvgStrokeWidth(ctx, 1.0 * scale)
    nvgStroke(ctx)

    -- EXP 百分比（经验条右侧外面）
    if nvgFontId >= 0 then
        nvgFontFaceId(ctx, nvgFontId)
        nvgFontSize(ctx, expFontSize)
        nvgTextAlign(ctx, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
        nvgFillColor(ctx, nvgRGBA(0, 0, 0, 150))
        nvgText(ctx, barX + barW + 5 * scale + 1, barCenterY + 1,
            math.floor(expProg * 100) .. "%", nil)
        nvgFillColor(ctx, nvgRGBA(210, 195, 130, 210))
        nvgText(ctx, barX + barW + 5 * scale, barCenterY,
            math.floor(expProg * 100) .. "%", nil)
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

    -- [DEBUG] 一次性打印确认函数进入
    if not _hpBarDebugPrinted then
        _hpBarDebugPrinted = true
        print("[DEBUG] _DrawEnemyHealthBars: enemies=" .. #enemies .. " fontId=" .. nvgFontId)
    end

    local scale = sh / 720
    local barW = math.floor(80 * scale)
    local barH = math.floor(14 * scale)
    local borderW = math.floor(1.5 * scale)
    local fontSize = math.max(10, math.floor(13 * scale))
    local yOffset = math.floor(28 * scale)  -- 血条在头顶上方的偏移

    nvgFontFaceId(ctx, nvgFontId)
    nvgFontSize(ctx, fontSize)
    nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    -- 获取相机节点前方向量，用于判断敌人是否在相机前方
    local camNode = cameraRef:GetNode()
    local camPos = camNode.worldPosition
    local camForward = camNode.worldDirection  -- 相机朝向

    for _, e in ipairs(enemies) do
        if e.node and e.hp and e.maxHP and e.hp > 0 then
            -- 头顶位置 (角色高度约1.5m)
            local headPos = e.node.position + Vector3(0, 1.8, 0)

            -- 检查敌人是否在相机前方（点积 > 0 表示在前方）
            local toEnemy = headPos - camPos
            local dot = toEnemy:DotProduct(camForward)
            if dot <= 0 then goto continue_enemy end

            -- WorldToScreenPoint 返回 Vector2 (x,y 归一化坐标，0~1)
            local screenPos = cameraRef:WorldToScreenPoint(headPos)

            -- 不在屏幕内则跳过
            if screenPos.x > -0.05 and screenPos.x < 1.05
                and screenPos.y > -0.05 and screenPos.y < 1.05 then

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

                -- 白色数字居中显示 (当前/总量)
                local hpText = math.floor(e.hp) .. "/" .. math.floor(e.maxHP)
                -- 阴影
                nvgFillColor(ctx, nvgRGBA(0, 0, 0, 200))
                nvgText(ctx, sx + 1, sy + 1, hpText, nil)
                -- 正文
                nvgFillColor(ctx, nvgRGBA(255, 255, 255, 240))
                nvgText(ctx, sx, sy, hpText, nil)
            end
        end
        ::continue_enemy::
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
    uiState.charPanelOpen = false
    uiState.charPanelRoot = nil
    uiState.systemPanelOpen = false
    uiState.systemPanelRoot = nil

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
                    text = "进入山海",
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
    uiState.charPanelOpen = false
    uiState.systemPanelOpen = false

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
-- 右上角按钮（由 _CreateTopRightArea 统一管理，不再单独创建）
-- ============================================================================
function GameUI._CreateTopButtons()
    -- 已合并到 _CreateTopRightArea，返回空容器
    return UI.Panel { width = 0, height = 0 }
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
    -- ── 整合右上角：小地图 + 信息条 + 角色/系统按钮 ──

    -- 小地图圆形（深底 + 金色外圈 + 十字准星 + 指北标）
    local mapSize = 64
    local miniMap = UI.Panel {
        width = mapSize, height = mapSize,
        borderRadius = mapSize / 2,
        backgroundColor = {18, 22, 18, 220},
        borderWidth = 2,
        borderColor = {150, 125, 55, 180},
        justifyContent = "center",
        alignItems = "center",
        children = {
            -- 内圈（模拟地图区域）
            UI.Panel {
                width = mapSize - 10, height = mapSize - 10,
                borderRadius = (mapSize - 10) / 2,
                borderWidth = 1,
                borderColor = {80, 90, 70, 100},
                justifyContent = "center",
                alignItems = "center",
                children = {
                    -- 十字准星（竖线）
                    UI.Panel {
                        position = "absolute",
                        width = 1, height = 20,
                        backgroundColor = {100, 130, 90, 80},
                    },
                    -- 十字准星（横线）
                    UI.Panel {
                        position = "absolute",
                        width = 20, height = 1,
                        backgroundColor = {100, 130, 90, 80},
                    },
                    -- 玩家标记点（中心亮点）
                    UI.Panel {
                        width = 6, height = 6,
                        borderRadius = 3,
                        backgroundColor = {80, 220, 120, 255},
                    },
                },
            },
            -- 指北标 N
            UI.Panel {
                position = "absolute",
                top = 3,
                justifyContent = "center",
                alignItems = "center",
                children = {
                    UI.Label {
                        text = "N",
                        fontSize = 8,
                        fontColor = {220, 200, 100, 200},
                        fontWeight = "bold",
                    },
                },
            },
        },
    }

    -- 信息条（击杀 + 金币，紧凑横排）
    local infoBar = UI.Panel {
        flexDirection = "row",
        alignItems = "center",
        backgroundColor = {16, 14, 10, 190},
        borderRadius = 10,
        borderWidth = 1,
        borderColor = {90, 75, 40, 120},
        paddingLeft = 8, paddingRight = 10,
        paddingTop = 3, paddingBottom = 3,
        gap = 10,
        marginTop = 4,
        children = {
            -- 击杀
            UI.Panel {
                flexDirection = "row", alignItems = "center", gap = 3,
                children = {
                    UI.Label { text = "⚔", fontSize = 11, fontColor = {200, 80, 60, 230} },
                    (function()
                        local lbl = UI.Label {
                            text = "0", fontSize = 11, fontColor = {210, 190, 170, 230},
                        }
                        uiState.refs.killCount = lbl
                        return lbl
                    end)(),
                },
            },
            -- 金币
            UI.Panel {
                flexDirection = "row", alignItems = "center", gap = 3,
                children = {
                    UI.Label { text = "💰", fontSize = 11, fontColor = {255, 210, 60, 240} },
                    (function()
                        local lbl = UI.Label {
                            text = "0", fontSize = 11, fontColor = {255, 225, 110, 240},
                        }
                        uiState.refs.goldLabel = lbl
                        return lbl
                    end)(),
                },
            },
        },
    }

    -- 功能按钮行（角色 + 系统，横排）
    local function makeBtn(label, labelColor, bgColor, borderColor, onTap)
        return UI.Panel {
            flexDirection = "row",
            alignItems = "center",
            justifyContent = "center",
            paddingLeft = 10, paddingRight = 10,
            paddingTop = 5, paddingBottom = 5,
            borderRadius = 12,
            backgroundColor = bgColor,
            borderWidth = 1,
            borderColor = borderColor,
            onPointerUp = onTap,
            children = {
                UI.Label {
                    text = label,
                    fontSize = 11,
                    fontColor = labelColor,
                    fontWeight = "bold",
                },
            },
        }
    end

    local btnRow = UI.Panel {
        flexDirection = "row",
        justifyContent = "center",
        gap = 6,
        marginTop = 4,
        children = {
            makeBtn("角色",
                {240, 215, 100, 255},
                {30, 26, 20, 210},
                {140, 115, 50, 160},
                function() if GameUI.onCharacterPanelToggle then GameUI.onCharacterPanelToggle() end end
            ),
            makeBtn("系统",
                {180, 175, 165, 240},
                {30, 28, 24, 200},
                {90, 85, 70, 140},
                function() if GameUI.onSystemPanelToggle then GameUI.onSystemPanelToggle() end end
            ),
        },
    }

    return UI.Panel {
        id = "topRight",
        position = "absolute",
        top = 10, right = 10,
        alignItems = "center",
        children = {
            miniMap,
            infoBar,
            btnRow,
        },
    }
end

-- ============================================================================
-- 角色面板（技能 + 背包 Tab 合并）
-- ============================================================================

--- 构建技能 Tab 内容
local function _BuildSkillTabContent(player)
    local classDef = CharacterClass.Classes[player.classId]
    local allSkills = classDef.skills
    local classColors = {
        warrior = {200, 85, 45, 255},
        mage    = {50, 120, 210, 255},
        taoist  = {65, 190, 90, 255},
    }
    local clr = classColors[player.classId]

    local skillRows = {}
    for _, skill in ipairs(allSkills) do
        local slvl = CharacterClass.GetSkillLevel(skill, player.level)
        local locked = (slvl == 0)
        local equippedSlot = 0
        for s = 1, 6 do
            if player.equippedSkills[s] and player.equippedSkills[s].id == skill.id then
                equippedSlot = s
                break
            end
        end

        local unlockText = ""
        if skill.unlockLevels then
            local parts = {}
            for _, lv in ipairs(skill.unlockLevels) do
                local star = player.level >= lv and "★" or "☆"
                table.insert(parts, star .. "Lv." .. lv)
            end
            unlockText = table.concat(parts, " ")
        end

        local typeNames = {
            melee = "近战", ranged = "远程", aoe = "范围",
            buff = "增益", heal = "治愈", dot = "持续", dash = "位移", summon = "召唤",
        }
        local typeName = typeNames[skill.type] or skill.type

        local statusText, statusColor
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

        table.insert(skillRows, UI.Panel {
            width = "100%",
            flexDirection = "row",
            alignItems = "center",
            paddingVertical = 10,
            paddingHorizontal = 12,
            backgroundColor = equippedSlot > 0 and {38, 32, 26, 210} or {22, 18, 15, 190},
            borderRadius = 6,
            borderWidth = equippedSlot > 0 and 1 or 0,
            borderColor = equippedSlot > 0 and {clr[1], clr[2], clr[3], 100} or {0,0,0,0},
            children = {
                UI.Panel {
                    flex = 1, flexShrink = 1,
                    children = {
                        UI.Panel {
                            flexDirection = "row", alignItems = "center", gap = 6,
                            children = {
                                UI.Label { text = skill.name, fontSize = 15, fontColor = nameColor, fontWeight = "bold" },
                                UI.Label { text = "[" .. typeName .. "]", fontSize = 11, fontColor = {155, 145, 125, 170} },
                            },
                        },
                        UI.Label { text = skill.desc or "", fontSize = 11, fontColor = descColor, marginTop = 3 },
                        UI.Label { text = unlockText, fontSize = 11, fontColor = {200, 180, 80, 200}, marginTop = 3 },
                    },
                },
                UI.Panel {
                    width = 70, alignItems = "center",
                    children = {
                        UI.Label { text = skill.manaCost > 0 and ("蓝 " .. skill.manaCost) or "免费", fontSize = 11, fontColor = {110, 170, 230, 210} },
                        UI.Label { text = skill.cooldown > 0 and ("CD " .. skill.cooldown .. "s") or "", fontSize = 11, fontColor = {175, 160, 115, 170}, marginTop = 2 },
                    },
                },
                UI.Panel {
                    width = 72, alignItems = "center",
                    children = {
                        UI.Label { text = statusText, fontSize = 12, fontColor = statusColor },
                        not locked and UI.Panel {
                            width = 62, height = 28, borderRadius = 5,
                            backgroundColor = equippedSlot > 0 and {60, 30, 25, 220} or {30, 48, 30, 220},
                            borderWidth = 1,
                            borderColor = equippedSlot > 0 and {170, 75, 60, 170} or {85, 150, 85, 170},
                            justifyContent = "center", alignItems = "center", marginTop = 4,
                            onPointerUp = function()
                                if equippedSlot > 0 then
                                    player.equippedSkills[equippedSlot] = nil
                                else
                                    local placed = false
                                    for s = 1, 6 do
                                        if player.equippedSkills[s] == nil then
                                            player.equippedSkills[s] = skill
                                            placed = true
                                            break
                                        end
                                    end
                                    if not placed then player.equippedSkills[1] = skill end
                                end
                                GameUI.HideCharacterPanel()
                                GameUI.ShowCharacterPanel(player, "skill")
                            end,
                            children = {
                                UI.Label {
                                    text = equippedSlot > 0 and "卸下" or "装备",
                                    fontSize = 12,
                                    fontColor = equippedSlot > 0 and {210, 95, 75, 255} or {130, 210, 130, 255},
                                },
                            },
                        } or nil,
                    },
                },
            },
        })
    end

    return UI.Panel {
        width = "100%", flexShrink = 1, overflow = "scroll", gap = 6,
        children = skillRows,
    }
end

--- 构建背包 Tab 内容
local function _BuildBagTabContent(player)
    local inv = Inventory.playerData
    local SLOT = Inventory.SLOT
    local RARITY = Inventory.RARITY

    local slotNames = {
        { slot = SLOT.WEAPON,   label = "武器" },
        { slot = SLOT.ARMOR,    label = "防具" },
        { slot = SLOT.RING,     label = "戒指" },
        { slot = SLOT.NECKLACE, label = "项链" },
    }

    -- 装备格子：2列布局，每格足够容纳名称+属性
    local equipSlots = {}
    for _, s in ipairs(slotNames) do
        local item = inv.equipped[s.slot]
        local itemName = item and item.name or "空"
        local rarity = item and RARITY[item.rarity] or nil
        local nameColor = rarity and rarity.color or {120, 115, 105, 180}
        local borderClr = rarity and {rarity.color[1], rarity.color[2], rarity.color[3], 140} or {55, 50, 42, 140}

        -- 属性文字
        local statParts = {}
        if item then
            if item.atk > 0 then table.insert(statParts, "攻+" .. item.atk) end
            if item.def > 0 then table.insert(statParts, "防+" .. item.def) end
            if item.hp  > 0 then table.insert(statParts, "血+" .. item.hp) end
        end
        local statText = table.concat(statParts, " ")

        table.insert(equipSlots, UI.Panel {
            flex = 1, minWidth = 140, height = 72,
            backgroundColor = {24, 20, 16, 230},
            borderRadius = 6, borderWidth = 1, borderColor = borderClr,
            paddingVertical = 8, paddingHorizontal = 10,
            justifyContent = "center",
            children = {
                UI.Label { text = s.label, fontSize = 12, fontColor = {170, 160, 140, 200} },
                UI.Label { text = itemName, fontSize = 15, fontColor = nameColor, marginTop = 4, fontWeight = "bold" },
                statText ~= "" and UI.Label {
                    text = statText,
                    fontSize = 12, fontColor = {190, 185, 165, 200}, marginTop = 3,
                } or nil,
            },
        })
    end

    -- 背包格子
    local bagItems = {}
    for i = 1, 20 do
        local item = inv.bag[i]
        local itemName = item and item.name or ""
        local rarity = item and RARITY[item.rarity] or nil
        local nameColor = rarity and rarity.color or {80, 80, 80, 100}
        local bgColor = item and {28, 24, 20, 240} or {20, 17, 14, 160}
        local borderClr = rarity and {rarity.color[1], rarity.color[2], rarity.color[3], 100} or {45, 40, 35, 100}

        table.insert(bagItems, UI.Panel {
            width = 64, height = 64,
            backgroundColor = bgColor, borderRadius = 4,
            borderWidth = 1, borderColor = borderClr,
            justifyContent = "center", alignItems = "center",
            paddingHorizontal = 4,
            children = {
                UI.Label { text = itemName, fontSize = 12, fontColor = nameColor, textAlign = "center" },
            },
        })
    end

    return UI.Panel {
        width = "100%", flexShrink = 1, overflow = "scroll",
        children = {
            -- 金币
            UI.Panel {
                flexDirection = "row", alignItems = "center", gap = 6, marginBottom = 8,
                children = {
                    UI.Label { text = "💰", fontSize = 16 },
                    UI.Label { text = tostring(inv.gold), fontSize = 16, fontColor = {255, 220, 80, 255}, fontWeight = "bold" },
                },
            },
            -- 装备区 2 列
            UI.Panel { flexDirection = "row", flexWrap = "wrap", gap = 8, marginBottom = 12, children = equipSlots },
            -- 分隔线
            UI.Panel { width = "100%", height = 1, backgroundColor = {70, 60, 42, 120}, marginBottom = 10 },
            -- 背包区
            UI.Label { text = "背包 (" .. #inv.bag .. "/20)", fontSize = 14, fontColor = {180, 170, 150, 220}, marginBottom = 8 },
            UI.Panel { flexDirection = "row", flexWrap = "wrap", gap = 6, children = bagItems },
        },
    }
end

function GameUI.ShowCharacterPanel(player, tab)
    -- 关闭系统面板（互斥）
    if uiState.systemPanelOpen then GameUI.HideSystemPanel() end
    if uiState.charPanelOpen then
        -- 已打开则先关再开（用于 Tab 切换）
        uiState.charPanelOpen = false
        uiState.charPanelRoot = nil
    end
    uiState.charPanelOpen = true

    local activeTab = tab or "skill"
    local classDef = CharacterClass.Classes[player.classId]

    -- Tab 按钮样式
    local function makeTab(label, tabId)
        local active = (activeTab == tabId)
        return UI.Panel {
            flex = 1, height = 36, borderRadius = 6,
            backgroundColor = active and {55, 45, 30, 245} or {28, 22, 18, 190},
            borderWidth = active and 1.5 or 0,
            borderColor = {160, 130, 55, 180},
            justifyContent = "center", alignItems = "center",
            onPointerUp = function()
                if activeTab ~= tabId then
                    GameUI.HideCharacterPanel()
                    GameUI.ShowCharacterPanel(player, tabId)
                end
            end,
            children = {
                UI.Label {
                    text = label,
                    fontSize = 15,
                    fontColor = active and {245, 220, 105, 255} or {160, 150, 130, 200},
                    fontWeight = active and "bold" or "normal",
                },
            },
        }
    end

    -- 构建内容区
    local content
    if activeTab == "skill" then
        content = _BuildSkillTabContent(player)
    else
        content = _BuildBagTabContent(player)
    end

    uiState.charPanelRoot = UI.Panel {
        id = "charPanelOverlay",
        width = "100%", height = "100%",
        backgroundColor = {0, 0, 0, 170},
        justifyContent = "center", alignItems = "center",
        children = {
            UI.Panel {
                width = 440, maxHeight = "85%",
                backgroundColor = {16, 12, 10, 248},
                borderRadius = 10, borderWidth = 2,
                borderColor = {110, 90, 45, 190},
                padding = 18,
                children = {
                    -- 标题栏
                    UI.Panel {
                        flexDirection = "row", justifyContent = "space-between", alignItems = "center",
                        width = "100%", marginBottom = 10,
                        children = {
                            UI.Label { text = "角色 — " .. classDef.name, fontSize = 18, fontColor = {230, 200, 85, 255}, fontWeight = "bold" },
                            UI.Label { text = "Lv." .. player.level, fontSize = 15, fontColor = {200, 190, 170, 220} },
                        },
                    },
                    -- Tab 栏
                    UI.Panel {
                        flexDirection = "row", width = "100%", gap = 8, marginBottom = 12,
                        children = {
                            makeTab("技能", "skill"),
                            makeTab("背包", "bag"),
                        },
                    },
                    -- 分隔线
                    UI.Panel { width = "100%", height = 1, backgroundColor = {70, 60, 42, 120}, marginBottom = 10 },
                    -- 内容区
                    content,
                    -- 关闭按钮
                    UI.Panel {
                        width = "100%", alignItems = "center", marginTop = 12,
                        children = {
                            UI.Button {
                                text = "关闭",
                                width = 120, height = 38,
                                backgroundColor = {50, 40, 30, 240},
                                borderRadius = 6, borderWidth = 1,
                                borderColor = {100, 85, 60, 190},
                                fontSize = 15, fontColor = {220, 205, 165, 255},
                                onClick = function()
                                    GameUI.HideCharacterPanel()
                                    if GameUI.onCharacterPanelClosed then
                                        GameUI.onCharacterPanelClosed()
                                    end
                                end,
                            },
                        },
                    },
                },
            },
        },
    }

    UI.SetRoot(uiState.charPanelRoot)
    print("[GameUI] Character panel opened, tab=" .. activeTab)
end

function GameUI.HideCharacterPanel()
    if not uiState.charPanelOpen then return end
    uiState.charPanelOpen = false
    uiState.charPanelRoot = nil
    if uiState.hudRoot then
        UI.SetRoot(uiState.hudRoot)
    end
    print("[GameUI] Character panel closed")
end

function GameUI.IsCharacterPanelOpen()
    return uiState.charPanelOpen
end

--- 刷新技能栏按钮（面板关闭后重建HUD以反映新配置）
function GameUI.RefreshSkillButtons(player)
    if not player then return end
    GameUI.ShowGameHUD(player)
    print("[GameUI] Skill buttons refreshed")
end

-- ============================================================================
-- 系统面板（退出 + DBG）
-- ============================================================================
function GameUI.ShowSystemPanel()
    -- 关闭角色面板（互斥）
    if uiState.charPanelOpen then GameUI.HideCharacterPanel() end
    if uiState.systemPanelOpen then return end
    uiState.systemPanelOpen = true

    uiState.systemPanelRoot = UI.Panel {
        id = "systemPanelOverlay",
        width = "100%", height = "100%",
        backgroundColor = {0, 0, 0, 170},
        justifyContent = "center", alignItems = "center",
        children = {
            UI.Panel {
                width = 260,
                backgroundColor = {16, 12, 10, 248},
                borderRadius = 8, borderWidth = 2,
                borderColor = {80, 75, 60, 180},
                padding = 20,
                alignItems = "center",
                gap = 10,
                children = {
                    -- 标题
                    UI.Label { text = "系统", fontSize = 18, fontColor = {190, 180, 160, 240} },
                    -- 分隔线
                    UI.Panel { width = "100%", height = 1, backgroundColor = {60, 50, 38, 100} },
                    -- 退出游戏按钮
                    UI.Button {
                        text = "退出游戏",
                        width = 180, height = 40,
                        backgroundColor = {60, 25, 20, 240},
                        borderRadius = 6, borderWidth = 1,
                        borderColor = {160, 60, 45, 180},
                        fontSize = 14, fontColor = {220, 100, 80, 255},
                        onClick = function()
                            GameUI.HideSystemPanel()
                            if GameUI.onMenuPressed then GameUI.onMenuPressed() end
                        end,
                    },
                    -- 分隔线
                    UI.Panel { width = "100%", height = 1, backgroundColor = {50, 45, 35, 80} },
                    -- DBG 区域
                    UI.Panel {
                        width = "100%",
                        backgroundColor = {14, 18, 14, 160},
                        borderRadius = 6, borderWidth = 1,
                        borderColor = {55, 100, 55, 100},
                        padding = 8,
                        alignItems = "center",
                        gap = 6,
                        children = {
                            UI.Label { text = "调试", fontSize = 10, fontColor = {100, 170, 100, 150} },
                            UI.Panel {
                                flexDirection = "row", gap = 8, alignItems = "center",
                                children = {
                                    UI.Panel {
                                        width = 50, height = 26, borderRadius = 4,
                                        backgroundColor = {40, 75, 40, 220},
                                        justifyContent = "center", alignItems = "center",
                                        onPointerUp = function()
                                            if GameUI.onDebugLevelChange then GameUI.onDebugLevelChange(1) end
                                            -- 刷新面板显示
                                            GameUI.HideSystemPanel()
                                            GameUI.ShowSystemPanel()
                                        end,
                                        children = {
                                            UI.Label { text = "Lv+", fontSize = 11, fontColor = {160, 240, 160, 255} },
                                        },
                                    },
                                    (function()
                                        local lbl = UI.Label {
                                            text = "Lv." .. (uiState.player and uiState.player.level or 1),
                                            fontSize = 12,
                                            fontColor = {200, 210, 200, 240},
                                        }
                                        uiState.debugLevelLabel = lbl
                                        return lbl
                                    end)(),
                                    UI.Panel {
                                        width = 50, height = 26, borderRadius = 4,
                                        backgroundColor = {75, 40, 40, 220},
                                        justifyContent = "center", alignItems = "center",
                                        onPointerUp = function()
                                            if GameUI.onDebugLevelChange then GameUI.onDebugLevelChange(-1) end
                                            GameUI.HideSystemPanel()
                                            GameUI.ShowSystemPanel()
                                        end,
                                        children = {
                                            UI.Label { text = "Lv-", fontSize = 11, fontColor = {240, 160, 160, 255} },
                                        },
                                    },
                                },
                            },
                        },
                    },
                    -- 关闭按钮
                    UI.Button {
                        text = "关闭",
                        width = 100, height = 32,
                        backgroundColor = {40, 35, 28, 240},
                        borderRadius = 4, borderWidth = 1,
                        borderColor = {80, 70, 50, 160},
                        fontSize = 13, fontColor = {180, 170, 145, 240},
                        onClick = function()
                            GameUI.HideSystemPanel()
                        end,
                    },
                },
            },
        },
    }

    UI.SetRoot(uiState.systemPanelRoot)
    print("[GameUI] System panel opened")
end

function GameUI.HideSystemPanel()
    if not uiState.systemPanelOpen then return end
    uiState.systemPanelOpen = false
    uiState.systemPanelRoot = nil
    if uiState.hudRoot then
        UI.SetRoot(uiState.hudRoot)
    end
    print("[GameUI] System panel closed")
end

function GameUI.IsSystemPanelOpen()
    return uiState.systemPanelOpen
end

-- ============================================================================
-- HUD 更新
-- ============================================================================
function GameUI.UpdateHUD(player, dt)
    if uiState.phase ~= "playing" then return end
    if uiState.charPanelOpen or uiState.systemPanelOpen then
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

    -- 更新 debug 等级标签
    if uiState.debugLevelLabel and player then
        uiState.debugLevelLabel:SetText("Lv." .. player.level)
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
        label:SetText(tostring(count))
    end
end

function GameUI.UpdateGold(gold)
    local label = uiState.refs.goldLabel
    if label then
        label:SetText(tostring(gold))
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
GameUI.onCharacterPanelToggle = nil
GameUI.onSystemPanelToggle = nil
GameUI.onCharacterPanelClosed = nil
GameUI.onDebugLevelChange = nil  -- function(delta) : +1 升级, -1 降级

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
