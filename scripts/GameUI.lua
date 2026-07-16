-- ============================================================================
-- GameUI.lua — 暗夜传奇 完整 UI 系统
-- 暗黑地牢风角色选择 + NanoVG 圆球 HP/MP (左下角) + EXP条 + 开门过渡
-- + 技能栏 + 飘字 + 菜单/背包按钮 + 背包面板 + 施法条 + 技能选择面板
-- ============================================================================

local UI = require("urhox-libs/UI")
local CharacterClass = require("scripts.CharacterClass")
local Inventory = require("scripts.Inventory")
local PlayerAnim = require("scripts.PlayerAnim")
local DivineBeast = require("scripts.DivineBeast")
require "urhox-libs.UI.GameHUD"

local GameUI = {}

-- UI 颜色
local C = CharacterClass.Colors

-- [调试] 显示玩家与敌人的距离开关（由 main.lua 按键切换）
GameUI.debugShowDistance = false

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
-- 启动 Logo 状态
-- ============================================================================
local startupLogoState = {
    active = false,
    timer = 0,
    duration = 2.8,
    onComplete = nil,
    root = nil,
    finished = false,
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
-- 相机/场景引用
-- ============================================================================
local cameraRef = nil
local playerNodeRef = nil  -- 玩家节点引用（用于地图系统）
local sceneRef = nil       -- 场景引用（用于暂停 timeScale）

-- ============================================================================
-- 地图系统状态
-- ============================================================================
local mapState = {
    fullMapOpen = false,
    arenaSize = 120,  -- 竞技场边长(米)
    obstacles = {
        -- 石头（灰色圆点）
        { x = 8, z = 12 }, { x = -15, z = 8 }, { x = 20, z = -5 },
        { x = -10, z = -18 }, { x = 5, z = -25 }, { x = -22, z = 15 },
        { x = 30, z = 10 }, { x = -5, z = 30 }, { x = 18, z = 22 },
        -- 柱子（方块标记）
        { x = 15, z = 15, isPillar = true }, { x = -15, z = 15, isPillar = true },
        { x = 15, z = -15, isPillar = true }, { x = -15, z = -15, isPillar = true },
    },
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
    toasts = {},        -- { text, timer, duration }
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
-- 启动 Logo 展示
-- ============================================================================
local function _CreateLogoGlyph()
    local shadow = UI.Panel {
        position = "absolute",
        left = 12, top = 18,
        width = 256, height = 116,
        borderRadius = 12,
        backgroundColor = {0, 0, 0, 105},
        boxShadow = {
            { x = 0, y = 18, blur = 30, spread = 0, color = {0, 0, 0, 150} },
        },
    }

    local plaque = UI.Panel {
        position = "absolute",
        left = 0, top = 0,
        width = 280, height = 128,
        borderRadius = 10,
        backgroundGradient = {
            type = "linear",
            direction = "to-bottom",
            from = {88, 88, 86, 255},
            to = {24, 24, 23, 255},
        },
        borderWidth = 3,
        borderColor = {136, 136, 132, 235},
        boxShadow = {
            { x = 0, y = 2, blur = 8, spread = 0, color = {0, 0, 0, 140}, inset = true },
            { x = 0, y = 0, blur = 18, spread = 1, color = {120, 120, 115, 65} },
        },
    }

    local inner = UI.Panel {
        position = "absolute",
        left = 14, top = 14,
        width = 252, height = 100,
        borderRadius = 6,
        backgroundGradient = {
            type = "linear",
            direction = "to-bottom",
            from = {48, 48, 47, 255},
            to = {12, 12, 12, 255},
        },
        borderWidth = 1,
        borderColor = {98, 98, 94, 230},
    }

    local bladeLeft = UI.Panel {
        position = "absolute",
        left = 23, top = 58,
        width = 84, height = 6,
        rotate = -18,
        borderRadius = 3,
        backgroundGradient = {
            type = "linear",
            direction = "to-right",
            from = {48, 48, 48, 230},
            to = {162, 162, 156, 235},
        },
        borderWidth = 1,
        borderColor = {82, 82, 80, 220},
    }

    local bladeRight = UI.Panel {
        position = "absolute",
        left = 173, top = 58,
        width = 84, height = 6,
        rotate = 18,
        borderRadius = 3,
        backgroundGradient = {
            type = "linear",
            direction = "to-left",
            from = {48, 48, 48, 230},
            to = {162, 162, 156, 235},
        },
        borderWidth = 1,
        borderColor = {82, 82, 80, 220},
    }

    local gem = UI.Panel {
        position = "absolute",
        left = 121, top = 42,
        width = 38, height = 38,
        rotate = 45,
        borderRadius = 5,
        backgroundGradient = {
            type = "linear",
            direction = "to-bottom-right",
            from = {122, 122, 118, 255},
            to = {36, 36, 36, 255},
        },
        borderWidth = 2,
        borderColor = {176, 176, 168, 230},
    }

    local sigil = UI.Label {
        position = "absolute",
        left = 0, top = 35,
        width = 280,
        text = "暗夜传奇",
        fontSize = 32,
        fontColor = {214, 214, 206, 255},
        fontWeight = "bold",
        textAlign = "center",
    }

    local mark = UI.Panel {
        width = 280,
        height = 128,
        opacity = 0,
        scale = 0.88,
        transformOrigin = "center",
        children = { shadow, plaque, inner, bladeLeft, bladeRight, gem, sigil },
    }

    mark:Animate({
        keyframes = {
            [0] = { opacity = 0, scale = 0.82, translateY = 16 },
            [0.55] = { opacity = 1, scale = 1.03, translateY = -2 },
            [1] = { opacity = 1, scale = 1.0, translateY = 0 },
        },
        duration = 0.9,
        easing = "easeOutBack",
        fillMode = "forwards",
    })

    plaque:Animate({
        keyframes = {
            [0] = { opacity = 0.88 },
            [1] = { opacity = 1.0 },
        },
        duration = 1.5,
        easing = "easeInOut",
        loop = true,
        direction = "alternate",
    })

    return mark
end

function GameUI.ShowStartupLogo(onComplete)
    startupLogoState.active = true
    startupLogoState.timer = 0
    startupLogoState.duration = 2.8
    startupLogoState.onComplete = onComplete
    startupLogoState.finished = false

    local logo = _CreateLogoGlyph()
    local title = UI.Label {
        text = "RETRO LEGEND",
        fontSize = 14,
        fontColor = {156, 156, 150, 230},
        fontWeight = "bold",
        marginTop = 16,
        opacity = 0,
        translateY = 12,
    }
    title:Animate({
        keyframes = {
            [0] = { opacity = 0, translateY = 20 },
            [1] = { opacity = 1, translateY = 0 },
        },
        duration = 0.75,
        easing = "easeOutCubic",
        fillMode = "forwards",
    })

    local subtitle = UI.Label {
        text = "石门将启  英雄归来",
        fontSize = 13,
        fontColor = {118, 118, 114, 210},
        marginTop = 6,
        opacity = 0,
        translateY = 8,
    }
    subtitle:Animate({
        keyframes = {
            [0] = { opacity = 0, translateY = 10 },
            [1] = { opacity = 1, translateY = 0 },
        },
        duration = 0.85,
        easing = "easeOutCubic",
        fillMode = "forwards",
    })

    local hint = UI.Label {
        text = "暗黑灰石 · 复古传奇",
        fontSize = 13,
        fontColor = {150, 150, 144, 165},
        marginTop = 22,
        opacity = 0,
    }
    hint:Animate({
        keyframes = {
            [0] = { opacity = 0 },
            [0.5] = { opacity = 1 },
            [1] = { opacity = 0.72 },
        },
        duration = 1.4,
        easing = "easeInOut",
        loop = true,
        direction = "alternate",
    })

    startupLogoState.root = UI.Panel {
        id = "startupLogo",
        width = "100%",
        height = "100%",
        pointerEvents = "box-none",
        justifyContent = "center",
        alignItems = "center",
        backgroundGradient = {
            type = "linear",
            direction = "to-bottom",
            from = {7, 7, 7, 255},
            to = {26, 26, 25, 255},
        },
        children = {
            UI.Panel {
                position = "absolute",
                width = "100%",
                height = "100%",
                backgroundGradient = {
                    type = "radial",
                    innerRadius = 0,
                    outerRadius = 560,
                    from = {92, 92, 88, 54},
                    to = {7, 7, 7, 0},
                },
            },
            UI.Panel {
                alignItems = "center",
                justifyContent = "center",
                paddingHorizontal = 28,
                paddingVertical = 24,
                borderRadius = 28,
                backgroundColor = {10, 10, 10, 162},
                borderWidth = 1,
                borderColor = {88, 88, 84, 120},
                boxShadow = {
                    { x = 0, y = 18, blur = 40, spread = 0, color = {0, 0, 0, 160} },
                    { x = 0, y = 0, blur = 28, spread = 1, color = {92, 92, 88, 38} },
                },
                children = { logo, title, subtitle, hint },
            },
        },
    }

    UI.SetRoot(startupLogoState.root)
    print("[GameUI] Startup logo shown")
end

function GameUI.UpdateStartupLogo(dt)
    if not startupLogoState.active then return false end

    startupLogoState.timer = startupLogoState.timer + dt

    if startupLogoState.timer >= startupLogoState.duration and not startupLogoState.finished then
        startupLogoState.finished = true
        startupLogoState.active = false
        local cb = startupLogoState.onComplete
        startupLogoState.root = nil
        startupLogoState.onComplete = nil
        print("[GameUI] Startup logo complete")
        if cb then cb() end
        return true
    end

    return true
end

function GameUI.IsStartupLogoActive()
    return startupLogoState.active
end

-- ============================================================================
-- 设置相机引用
-- ============================================================================
function GameUI.SetCamera(cam)
    cameraRef = cam
end

function GameUI.SetPlayerNode(node)
    playerNodeRef = node
end

function GameUI.SetScene(scene)
    sceneRef = scene
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

    -- 全屏地图打开时跳过其他 NanoVG 绘制（地图已改用 UI 系统）
    if not mapState.fullMapOpen then
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
            -- 绘制神兽头顶血条和名字
            pcall(GameUI._DrawDivineBeastBar, nvgCtx, sw, sh)
        end

        -- 绘制伤害飘字
        if uiState.phase == "playing" and cameraRef then
            GameUI._DrawFloatingTexts(nvgCtx, sw, sh)
        end

        -- 绘制施法条
        if castBarState.active and uiState.phase == "playing" then
            GameUI._DrawCastBar(nvgCtx, sw, sh)
        end
    end

    -- 绘制开门过渡
    if doorState.active then
        GameUI._DrawDoorTransition(nvgCtx, sw, sh)
    end

    -- 命中闪光（全屏白色半透明瞬闪）
    if uiState.phase == "playing" and PlayerAnim.IsFlashing() then
        nvgBeginPath(nvgCtx)
        nvgRect(nvgCtx, 0, 0, sw, sh)
        nvgFillColor(nvgCtx, nvgRGBA(255, 255, 255, 40))
        nvgFill(nvgCtx)
    end

    -- Toast 提示（始终绘制，不受地图遮挡）
    GameUI._DrawToasts(nvgCtx, sw, sh)

    -- DEBUG: 屏幕左上角显示相机/角色/worldBBox 实时数据
    if uiState.phase == "playing" and cameraRef then
        local camNode = cameraRef:GetNode()
        local camPos = camNode.worldPosition
        local PlayerAnim = require("PlayerAnim")
        local mn = PlayerAnim.GetModelNode()
        local am = PlayerAnim.GetAnimModel()
        local mnScale = mn and mn.worldScale or Vector3(0,0,0)
        local mnPos = mn and mn.worldPosition or Vector3(0,0,0)
        -- worldBoundingBox: 实际渲染范围
        local wbbStr = "N/A"
        if am then
            local wbb = am.worldBoundingBox
            local sz = wbb.size
            local ct = wbb.center
            wbbStr = string.format("sz(%.1f,%.1f,%.1f) ct(%.1f,%.1f,%.1f)",
                sz.x, sz.y, sz.z, ct.x, ct.y, ct.z)
        end

        nvgFontSize(nvgCtx, 13)
        nvgFontFace(nvgCtx, "sans")
        nvgFillColor(nvgCtx, nvgRGBA(0, 255, 0, 220))
        nvgTextAlign(nvgCtx, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
        local line1 = string.format("CAM(%.1f,%.1f,%.1f) S=%.2f P(%.1f,%.1f,%.1f)",
            camPos.x, camPos.y, camPos.z,
            mnScale.x,
            mnPos.x, mnPos.y, mnPos.z)
        local line2 = "WBBox:" .. wbbStr
        nvgText(nvgCtx, 10, 10, line1)
        nvgText(nvgCtx, 10, 26, line2)
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

    -- 数值文字：左右错开，纯文字显示
    if nvgFontId >= 0 then
        local hpText = tostring(math.floor(player.hp))
        local mpText = tostring(math.floor(player.mp))
        local valueFontSize = math.floor(13 * scale)
        local hpX = cx - r * 0.50
        local mpX = cx + r * 0.50

        nvgFontFaceId(ctx, nvgFontId)
        nvgFontSize(ctx, valueFontSize)
        nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

        nvgFillColor(ctx, nvgRGBA(255, 210, 190, 245))
        nvgText(ctx, hpX, cy, hpText, nil)

        nvgFillColor(ctx, nvgRGBA(190, 220, 255, 245))
        nvgText(ctx, mpX, cy, mpText, nil)
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

    -- 药丸金属灰边框
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, pillX, pillY, pillW, pillH, pillH / 2)
    nvgStrokeColor(ctx, nvgRGBA(142, 146, 150, 220))
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
        -- 银灰文字
        nvgFillColor(ctx, nvgRGBA(234, 236, 232, 255))
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

    -- 经验条填充（银灰金属渐变）
    if expProg > 0 then
        local fillW = math.max(barH * 0.6, barW * expProg)
        nvgBeginPath(ctx)
        nvgRoundedRect(ctx, barX, barY, fillW, barH, barH / 2)
        local expGrad = nvgLinearGradient(ctx, barX, barY, barX, barY + barH,
            nvgRGBA(214, 218, 218, 245),
            nvgRGBA(116, 120, 124, 232))
        nvgFillPaint(ctx, expGrad)
        nvgFill(ctx)

        -- 顶部高光
        nvgBeginPath(ctx)
        nvgRoundedRect(ctx, barX + 2 * scale, barY + 1 * scale,
            fillW - 4 * scale, barH * 0.35, barH * 0.17)
        nvgFillColor(ctx, nvgRGBA(245, 248, 248, 48))
        nvgFill(ctx)
    end

    -- 经验条边框
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, barX, barY, barW, barH, barH / 2)
    nvgStrokeColor(ctx, nvgRGBA(116, 120, 124, 155))
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
        nvgFillColor(ctx, nvgRGBA(190, 194, 194, 215))
        nvgText(ctx, barX + barW + 5 * scale, barCenterY,
            math.floor(expProg * 100) .. "%", nil)
    end
end

-- ============================================================================
-- 药瓶 CD 转圈动画 (NanoVG 半透明扇形遮罩)
-- ============================================================================
function GameUI._DrawPotionCD(ctx, sw, sh)
    local cd = GameUI.potionCD
    if not cd then return end

    local scale = sh / 720
    local uiSysScale = UI.GetScale()
    -- 药瓶位置与 _CreatePotions 保持一致
    -- 物理像素 = UI base pixels × uiSysScale = (X * scale / uiSysScale) * uiSysScale = X * scale
    local btnSize = math.max(30 * uiSysScale, 38 * scale)  -- 匹配 potionSize (含下限)
    local gap = math.max(4 * uiSysScale, 6 * scale)
    local baseLeft = (72 + 52 + 10) * scale  -- 物理像素 (匹配 potionLeft)
    -- 球心距底 = 105*scale, 药瓶垂直居中于球心
    local baseBottom = 105 * scale - btnSize / 2  -- 药瓶底边距屏幕底 (物理像素)

    local potions = {
        { ratio = cd.hp, idx = 0 },
        { ratio = cd.mp, idx = 1 },
    }

    for _, p in ipairs(potions) do
        if p.ratio > 0.01 then
            local cx = baseLeft + p.idx * (btnSize + gap) + btnSize * 0.5
            local cy = sh - baseBottom - btnSize * 0.5
            local r = btnSize * 0.5

            -- 顺时针扇形遮罩: 从顶部开始，按 CD 比例覆盖
            local startAngle = -math.pi * 0.5
            local endAngle = startAngle + math.pi * 2 * p.ratio

            nvgSave(ctx)
            nvgBeginPath(ctx)
            nvgMoveTo(ctx, cx, cy)
            nvgArc(ctx, cx, cy, r, startAngle, endAngle, NVG_CW)
            nvgClosePath(ctx)
            nvgFillColor(ctx, nvgRGBA(0, 0, 0, 160))
            nvgFill(ctx)

            -- 前沿发光线
            local edgeX = cx + math.cos(endAngle) * r
            local edgeY = cy + math.sin(endAngle) * r
            nvgBeginPath(ctx)
            nvgMoveTo(ctx, cx, cy)
            nvgLineTo(ctx, edgeX, edgeY)
            nvgStrokeColor(ctx, nvgRGBA(255, 255, 255, 120))
            nvgStrokeWidth(ctx, 1.5 * scale)
            nvgStroke(ctx)
            nvgRestore(ctx)
        end
    end
end

-- (地图渲染已改用纯 UI 实现，见 _CreateMiniMapArea / _UpdateMiniMapUI / _UpdateFullMapUI)

--- 内部：根据面板状态同步 scene.timeScale（真正全局暂停）
local function _SyncPauseState()
    if not sceneRef then return end
    if mapState.fullMapOpen or uiState.charPanelOpen or uiState.systemPanelOpen then
        sceneRef.timeScale = 0
    else
        sceneRef.timeScale = 1
    end
end

-- ============================================================================
-- 全图 打开/关闭 控制
-- ============================================================================
function GameUI._OpenFullMap()
    mapState.fullMapOpen = true
    _SyncPauseState()
    local overlay = uiState.refs.fullMapOverlay
    if overlay then overlay:SetVisible(true) end
    -- 隐藏 HUD 其他元素避免交互干扰
    local skillBar = uiState.hudRoot and uiState.hudRoot:FindById("skillBar")
    local potions = uiState.hudRoot and uiState.hudRoot:FindById("potions")
    local topRight = uiState.hudRoot and uiState.hudRoot:FindById("topRight")
    if skillBar then skillBar:SetVisible(false) end
    if potions then potions:SetVisible(false) end
    if topRight then topRight:SetVisible(false) end
end

function GameUI._CloseFullMap()
    mapState.fullMapOpen = false
    _SyncPauseState()
    local overlay = uiState.refs.fullMapOverlay
    if overlay then overlay:SetVisible(false) end
    -- 恢复 HUD 显示
    local skillBar = uiState.hudRoot and uiState.hudRoot:FindById("skillBar")
    local potions = uiState.hudRoot and uiState.hudRoot:FindById("potions")
    local topRight = uiState.hudRoot and uiState.hudRoot:FindById("topRight")
    if skillBar then skillBar:SetVisible(true) end
    if potions then potions:SetVisible(true) end
    if topRight then topRight:SetVisible(true) end
    -- 强制重置摇杆状态
    GameUI._ResetJoystickState()
end

function GameUI.ToggleFullMap()
    if mapState.fullMapOpen then
        GameUI._CloseFullMap()
    else
        GameUI._OpenFullMap()
    end
end

function GameUI.IsFullMapOpen()
    return mapState.fullMapOpen
end

--- 判断游戏是否应暂停（任何面板打开时暂停）
function GameUI.IsGamePaused()
    return mapState.fullMapOpen or uiState.charPanelOpen or uiState.systemPanelOpen
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
    local hpFontSize = math.max(10, math.floor(13 * scale))
    local nameFontSize = math.max(11, math.floor(14 * scale))
    local yOffset = math.floor(28 * scale)  -- 血条在头顶上方的偏移
    local nameOffset = math.floor(12 * scale)  -- 名字在血条上方的额外偏移

    nvgFontFaceId(ctx, nvgFontId)
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
                nvgFontSize(ctx, hpFontSize)
                local hpText = math.floor(e.hp) .. "/" .. math.floor(e.maxHP)
                -- 阴影
                nvgFillColor(ctx, nvgRGBA(0, 0, 0, 200))
                nvgText(ctx, sx + 1, sy + 1, hpText, nil)
                -- 正文
                nvgFillColor(ctx, nvgRGBA(255, 255, 255, 240))
                nvgText(ctx, sx, sy, hpText, nil)

                -- 名字标签（血条上方）
                local nameText = (e.name or "???") .. " Lv." .. (e.level or 1)
                local nameSy = sy - barH / 2 - nameOffset
                nvgFontSize(ctx, nameFontSize)
                -- 阴影
                nvgFillColor(ctx, nvgRGBA(0, 0, 0, 180))
                nvgText(ctx, sx + 1, nameSy + 1, nameText, nil)
                -- 正文（白色）
                nvgFillColor(ctx, nvgRGBA(255, 255, 255, 255))
                nvgText(ctx, sx, nameSy, nameText, nil)

                -- [调试] 显示与玩家的距离 + 身位区间（开关开启时）
                if GameUI.debugShowDistance and playerNodeRef then
                    local d = (e.node.position - playerNodeRef.position):Length()
                    local mr = Combat.MELEE_REACH or 1.5
                    local ar = Combat.ASSASSIN_REACH or 3.0
                    local zone, zr, zg, zb
                    if d <= mr then
                        zone, zr, zg, zb = "挨着", 80, 230, 120
                    elseif d <= ar then
                        zone, zr, zg, zb = "隔身位", 245, 220, 60
                    else
                        zone, zr, zg, zb = "远", 180, 180, 180
                    end
                    local dText = string.format("%.2fm %s", d, zone)
                    local dSy = sy + barH / 2 + math.floor(13 * scale)
                    nvgFontSize(ctx, hpFontSize)
                    nvgFillColor(ctx, nvgRGBA(0, 0, 0, 200))
                    nvgText(ctx, sx + 1, dSy + 1, dText, nil)
                    nvgFillColor(ctx, nvgRGBA(zr, zg, zb, 255))
                    nvgText(ctx, sx, dSy, dText, nil)
                end
            end
        end
        ::continue_enemy::
    end
end

-- ============================================================================
-- 神兽头顶血条 + 等级名字（颜色随等级变化）
-- ============================================================================
function GameUI._DrawDivineBeastBar(ctx, sw, sh)
    if nvgFontId < 0 or not cameraRef then return end
    if not DivineBeast.IsAlive() then return end

    local info = DivineBeast.GetDisplayInfo()
    if not info then return end

    local beastPos = DivineBeast.GetPosition()
    if not beastPos then return end

    -- 头顶位置
    local headPos = beastPos + Vector3(0, 2.2, 0)

    -- 检查是否在相机前方
    local camNode = cameraRef:GetNode()
    local camPos = camNode.worldPosition
    local camForward = camNode.worldDirection
    local toTarget = headPos - camPos
    if toTarget:DotProduct(camForward) <= 0 then return end

    local screenPos = cameraRef:WorldToScreenPoint(headPos)
    if screenPos.x < -0.05 or screenPos.x > 1.05
        or screenPos.y < -0.05 or screenPos.y > 1.05 then
        return
    end

    local scale = sh / 720
    local barW = math.floor(90 * scale)
    local barH = math.floor(14 * scale)
    local borderW = math.floor(1.5 * scale)
    local hpFontSize = math.max(10, math.floor(13 * scale))
    local nameFontSize = math.max(12, math.floor(15 * scale))
    local yOffset = math.floor(30 * scale)
    local nameOffset = math.floor(14 * scale)

    local sx = screenPos.x * sw
    local sy = screenPos.y * sh - yOffset

    local hpRatio = math.max(0, math.min(1, info.hp / info.maxHP))

    nvgFontFaceId(ctx, nvgFontId)
    nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    -- 黑色背景框
    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, sx - barW / 2 - borderW, sy - barH / 2 - borderW,
        barW + borderW * 2, barH + borderW * 2, 2 * scale)
    nvgFillColor(ctx, nvgRGBA(0, 0, 0, 200))
    nvgFill(ctx)

    -- 绿色血条（区分于怪物的红色）
    if hpRatio > 0 then
        local fillW = math.max(1, barW * hpRatio)
        nvgBeginPath(ctx)
        nvgRoundedRect(ctx, sx - barW / 2, sy - barH / 2,
            fillW, barH, 1.5 * scale)
        if hpRatio > 0.5 then
            nvgFillColor(ctx, nvgRGBA(60, 200, 80, 230))
        elseif hpRatio > 0.25 then
            nvgFillColor(ctx, nvgRGBA(200, 200, 40, 230))
        else
            nvgFillColor(ctx, nvgRGBA(220, 80, 50, 255))
        end
        nvgFill(ctx)
    end

    -- HP 数字
    nvgFontSize(ctx, hpFontSize)
    local hpText = math.floor(info.hp) .. "/" .. math.floor(info.maxHP)
    nvgFillColor(ctx, nvgRGBA(0, 0, 0, 200))
    nvgText(ctx, sx + 1, sy + 1, hpText, nil)
    nvgFillColor(ctx, nvgRGBA(255, 255, 255, 240))
    nvgText(ctx, sx, sy, hpText, nil)

    -- 名字标签（等级颜色）
    local nameColor = info.nameColor  -- {r, g, b, a}
    local nameText = info.name .. " Lv." .. info.level
    local nameSy = sy - barH / 2 - nameOffset
    nvgFontSize(ctx, nameFontSize)
    -- 阴影
    nvgFillColor(ctx, nvgRGBA(0, 0, 0, 180))
    nvgText(ctx, sx + 1, nameSy + 1, nameText, nil)
    -- 正文（等级颜色）
    nvgFillColor(ctx, nvgRGBA(nameColor[1], nameColor[2], nameColor[3], nameColor[4] or 255))
    nvgText(ctx, sx, nameSy, nameText, nil)
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
-- Toast 提示绘制（屏幕上方居中）
-- ============================================================================
function GameUI._DrawToasts(ctx, sw, sh)
    if #uiState.toasts == 0 or nvgFontId < 0 then return end

    local scale = sh / 720
    nvgFontFaceId(ctx, nvgFontId)
    nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    local baseY = 60 * scale
    for i, toast in ipairs(uiState.toasts) do
        local t = toast.timer
        local dur = toast.duration
        -- 进入动画 (0~0.3s 从上滑入)
        local slideIn = math.min(1.0, t / 0.3)
        local offsetY = (1.0 - slideIn) * (-30 * scale)
        -- 淡出 (最后0.5s)
        local alpha = 1.0
        if t > dur - 0.5 then
            alpha = math.max(0, (dur - t) / 0.5)
        end

        local y = baseY + offsetY + (i - 1) * 36 * scale
        local fontSize = math.floor(16 * scale)
        nvgFontSize(ctx, fontSize)

        -- 背景圆角矩形
        local tw = nvgTextBounds(ctx, 0, 0, toast.text, nil, nil) + 24 * scale
        local th = 28 * scale
        local tx = (sw - tw) / 2
        nvgBeginPath(ctx)
        nvgRoundedRect(ctx, tx, y - th / 2, tw, th, 6 * scale)
        nvgFillColor(ctx, nvgRGBA(20, 18, 15, math.floor(200 * alpha)))
        nvgFill(ctx)
        nvgStrokeColor(ctx, nvgRGBA(138, 142, 146, math.floor(180 * alpha)))
        nvgStrokeWidth(ctx, 1.5 * scale)
        nvgStroke(ctx)

        -- 文字
        nvgFillColor(ctx, nvgRGBA(232, 234, 232, math.floor(255 * alpha)))
        nvgText(ctx, sw / 2, y, toast.text, nil)
    end
end

--- 显示一条 Toast 提示
function GameUI.ShowToast(text, duration)
    duration = duration or 2.5
    table.insert(uiState.toasts, { text = text, timer = 0, duration = duration })
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
            nvgFillColor(ctx, nvgRGBA(178, 184, 190, 225))
        end
        nvgFill(ctx)
    end

    nvgBeginPath(ctx)
    nvgRoundedRect(ctx, bx, by, barW, barH, 4 * scale)
    nvgStrokeColor(ctx, nvgRGBA(132, 136, 140, 185))
    nvgStrokeWidth(ctx, 1.5 * scale)
    nvgStroke(ctx)

    if nvgFontId >= 0 and castBarState.skillName ~= "" then
        nvgFontFaceId(ctx, nvgFontId)
        nvgFontSize(ctx, math.floor(10 * scale))
        nvgTextAlign(ctx, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(ctx, nvgRGBA(232, 234, 232, 230))
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
-- 存档槽位选择界面（传奇风格：双槽位 + 3D角色预览）
-- ============================================================================

-- 存储预览状态供 main.lua 查询
local previewClassIds_ = {}
-- 持久化选中的槽位索引（跨 ShowSaveSlots 重建保留）
local persistedSelectedSlot_ = nil

--- 获取当前预览界面各槽位的 classId（供 main.lua 更新动画用）
function GameUI.GetPreviewClassIds()
    return previewClassIds_
end

--- 设置默认选中槽位（在 ShowSaveSlots 之前调用）
function GameUI.SetSelectedSlot(index)
    persistedSelectedSlot_ = index
end

--- 清除持久化选中状态（退出存档界面时调用）
function GameUI.ClearSelectedSlot()
    persistedSelectedSlot_ = nil
end

-- ============================================================================
-- 删除确认弹框
-- ============================================================================
---@type Modal|nil
local deleteConfirmModal_ = nil

function GameUI._ShowDeleteConfirm(slotIndex, slots, callbacks)
    -- 如果已打开则先关闭
    if deleteConfirmModal_ then
        deleteConfirmModal_:Close()
        deleteConfirmModal_ = nil
    end

    deleteConfirmModal_ = UI.Modal {
        title = "确认删除",
        size = "sm",
        isOpen = false,
        showCloseButton = false,
        closeOnOverlay = true,
        backgroundColor = {45, 44, 40, 250},
        borderWidth = 2,
        borderColor = {90, 88, 82, 240},
        titleTextColor = {220, 100, 80, 255},
        titleFontSize = 16,
        onClose = function(self)
            deleteConfirmModal_ = nil
        end,
        children = {
            UI.Label {
                text = "确定要删除 NO." .. slotIndex .. " 的角色吗？\n删除后无法恢复！",
                fontSize = 13,
                fontColor = {200, 198, 190, 255},
                textAlign = "center",
                marginBottom = 16,
            },
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                justifyContent = "center",
                gap = 16,
                children = {
                    UI.Button {
                        text = "取消",
                        width = 90,
                        height = 32,
                        backgroundColor = {62, 60, 56, 240},
                        borderRadius = 3,
                        borderWidth = 1,
                        borderColor = {100, 98, 90, 200},
                        fontSize = 13,
                        fontColor = {190, 188, 180, 255},
                        onClick = function()
                            if deleteConfirmModal_ then
                                deleteConfirmModal_:Close()
                            end
                        end,
                    },
                    UI.Button {
                        text = "确认删除",
                        width = 90,
                        height = 32,
                        backgroundColor = {140, 55, 45, 240},
                        borderRadius = 3,
                        borderWidth = 1,
                        borderColor = {180, 70, 55, 220},
                        fontSize = 13,
                        fontColor = {255, 230, 220, 255},
                        onClick = function()
                            if deleteConfirmModal_ then
                                deleteConfirmModal_:Close()
                            end
                            if callbacks.onDelete then
                                callbacks.onDelete(slotIndex, function() end)
                            end
                        end,
                    },
                },
            },
        },
    }
    deleteConfirmModal_:Open()
end

---@param slots table[] 存档槽位数组 (最多2个，nil表示空槽)
---@param callbacks table { onSelect(idx), onContinue(idx), onCreate(idx), onDelete(idx, onDone) }
function GameUI.ShowSaveSlots(slots, callbacks)
    uiState.phase = "select"
    uiState.charPanelOpen = false
    uiState.charPanelRoot = nil
    uiState.systemPanelOpen = false
    uiState.systemPanelRoot = nil

    -- 当前选中的槽位索引（优先使用持久化值，否则默认选第一个有数据的，或1）
    local selectedSlot = persistedSelectedSlot_ or 1
    -- 验证范围合法
    if selectedSlot < 1 or selectedSlot > 2 then selectedSlot = 1 end

    -- 存储 classIds 供预览系统使用
    previewClassIds_ = {}
    for i = 1, 2 do
        if slots[i] then
            previewClassIds_[i] = slots[i].classId
        end
    end

    -- 职业名中文映射
    local classNames = {
        warrior = "武 士",
        mage    = "法 师",
        taoist  = "道 士",
    }

    -- ========================================================================
    -- 经典传奇风格角色选择界面（参照热血传奇原版布局）
    -- 上半：两个大角色展示窗（3D角色透出）
    -- 下半：左右角色信息卡 + 中间操作按钮
    -- ========================================================================

    -- 颜色配置（暗黑灰石 + 复古传奇金属质感）
    local C_BORDER_ACTIVE = {188, 188, 180, 255}   -- 选中：冷灰金属高亮
    local C_BORDER_NORMAL = {66, 66, 64, 210}      -- 未选中：暗灰边框
    local C_STONE_BG      = {24, 24, 23, 255}      -- 底部暗灰石板
    local C_INFO_BG       = {38, 38, 36, 255}      -- 信息卡底色
    local C_LABEL         = {210, 210, 202, 232}   -- 正文信息色
    local C_LABEL_DIM     = {132, 132, 126, 190}   -- 暗淡标签色
    local C_GOLD          = {222, 222, 212, 255}   -- 高亮文字（灰白）
    local C_ACCENT        = {158, 158, 150, 235}   -- 灰色强调色
    local C_BTN_BG        = {58, 58, 54, 242}      -- 按钮底色
    local C_BTN_BORDER    = {105, 105, 98, 225}    -- 按钮边框
    local C_BTN_DISABLED  = {34, 34, 32, 205}      -- 按钮禁用底色

    local function SelectSlot(index)
        if selectedSlot ~= index then
            persistedSelectedSlot_ = index
            if callbacks.onSelect then callbacks.onSelect(index) end
            GameUI.ShowSaveSlots(slots, callbacks)
        end
    end

    --- 构建角色展示窗口（上半部分，完全透明让3D角色透出）
    local function BuildViewport(index)
        local isSelected = (index == selectedSlot)
        local data = slots[index]
        local borderCol = isSelected and C_BORDER_ACTIVE or C_BORDER_NORMAL
        local statusText = isSelected and "当前角色" or "选择 NO." .. index
        local statusColor = isSelected and C_GOLD or {178, 172, 185, 205}

        return UI.Button {
            id = "viewport_" .. index,
            text = "",
            flexGrow = 1,
            height = "100%",
            backgroundColor = isSelected and {20, 20, 20, 42} or {0, 0, 0, 0},
            hoverBackgroundColor = {54, 54, 52, 70},
            pressedBackgroundColor = {68, 68, 64, 92},
            borderWidth = isSelected and 4 or 2,
            borderColor = borderCol,
            borderRadius = 8,
            transition = "backgroundColor 0.18s easeOut, borderColor 0.18s easeOut, scale 0.15s easeOut",
            boxShadow = isSelected and {
                { x = 0, y = 0, blur = 22, spread = 2, color = {160, 160, 150, 82} },
                { x = 0, y = 0, blur = 32, spread = 0, color = {70, 70, 68, 70} },
            } or {
                { x = 0, y = 6, blur = 16, spread = 0, color = {0, 0, 0, 90} },
            },
            children = {
                -- 顶部状态条：比单纯边框更容易被新人识别
                UI.Panel {
                    position = "absolute",
                    top = 10,
                    left = 12,
                    right = 12,
                    height = 32,
                    flexDirection = "row",
                    justifyContent = "space-between",
                    alignItems = "center",
                    paddingHorizontal = 10,
                    borderRadius = 16,
                    backgroundColor = isSelected and {26, 26, 24, 222} or {12, 12, 12, 170},
                    borderWidth = 1,
                    borderColor = isSelected and {170, 170, 162, 230} or {92, 92, 88, 170},
                    children = {
                        UI.Label {
                            text = "NO." .. index,
                            fontSize = 15,
                            fontWeight = "bold",
                            fontColor = isSelected and C_GOLD or {205, 200, 210, 220},
                        },
                        UI.Label {
                            text = statusText,
                            fontSize = 12,
                            fontColor = statusColor,
                        },
                    },
                },
                isSelected and UI.Panel {
                    position = "absolute",
                    bottom = 14,
                    left = 0,
                    right = 0,
                    alignItems = "center",
                    pointerEvents = "none",
                    children = {
                        UI.Panel {
                            paddingHorizontal = 14,
                            paddingVertical = 6,
                            borderRadius = 16,
                            backgroundColor = {44, 44, 41, 228},
                            borderWidth = 1,
                            borderColor = {150, 150, 142, 230},
                            children = {
                                UI.Label {
                                    text = data and "已选中该角色" or "将在这里创建角色",
                                    fontSize = 12,
                                    fontColor = {220, 220, 210, 255},
                                },
                            },
                        },
                    },
                } or nil,
            },
            onClick = function()
                SelectSlot(index)
            end,
        }
    end

    --- 构建角色信息卡（下半部分，NO.1 / NO.2 + 属性行）
    local function BuildInfoCard(index)
        local data = slots[index]
        local isEmpty = (data == nil)
        local isSelected = (index == selectedSlot)
        local borderCol = isSelected and C_BORDER_ACTIVE or C_BORDER_NORMAL
        local cName = "未创建"
        if not isEmpty then
            cName = classNames[data.classId] or data.className or "???"
        end

        local infoChildren = {
            -- 顶部 NO 标签 + 明确状态徽标
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                justifyContent = "space-between",
                alignItems = "center",
                marginBottom = 6,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        gap = 6,
                        children = {
                            UI.Label {
                                text = "NO." .. index,
                                fontSize = isSelected and 19 or 17,
                                fontWeight = "bold",
                                fontColor = isSelected and C_GOLD or {220, 215, 205, 235},
                            },
                            UI.Panel {
                                width = isSelected and 8 or 6,
                                height = isSelected and 8 or 6,
                                shape = "circle",
                                borderRadius = isSelected and 4 or 3,
                                backgroundColor = isSelected and {184, 184, 176, 255} or {105, 105, 100, 190},
                            },
                        },
                    },
                    UI.Label {
                        text = isSelected and "已选中" or "点击选择",
                        fontSize = 12,
                        fontColor = isSelected and {220, 220, 210, 255} or {170, 170, 164, 205},
                    },
                },
            },
            -- 选中横条：让状态比小按钮更醒目
            UI.Panel {
                width = "100%",
                height = isSelected and 4 or 2,
                borderRadius = 2,
                backgroundGradient = isSelected and {
                    type = "linear",
                    direction = "to-right",
                    from = {178, 178, 170, 255},
                    to = {82, 82, 78, 230},
                } or nil,
                backgroundColor = isSelected and nil or {70, 70, 66, 170},
                marginBottom = 8,
            },
        }

        if not isEmpty then
            table.insert(infoChildren, UI.Panel {
                width = "100%",
                flexDirection = "row",
                marginBottom = 3,
                children = {
                    UI.Label { text = "等级", fontSize = 13, fontColor = C_LABEL_DIM, width = 42 },
                    UI.Label { text = tostring(data.level or 1), fontSize = 13, fontColor = C_LABEL, fontWeight = "bold" },
                },
            })
            table.insert(infoChildren, UI.Panel {
                width = "100%",
                flexDirection = "row",
                marginBottom = 6,
                children = {
                    UI.Label { text = "职业", fontSize = 13, fontColor = C_LABEL_DIM, width = 42 },
                    UI.Label { text = cName, fontSize = 13, fontColor = C_GOLD, fontWeight = "bold" },
                },
            })
        else
            table.insert(infoChildren, UI.Panel {
                width = "100%",
                alignItems = "center",
                marginTop = 4,
                marginBottom = 4,
                children = {
                    UI.Label {
                        text = "未创建角色",
                        fontSize = 15,
                        fontColor = isSelected and {210, 210, 202, 240} or C_LABEL_DIM,
                        fontWeight = "bold",
                    },
                    UI.Label {
                        text = "点击创建新角色",
                        fontSize = 11,
                        fontColor = {150, 144, 160, 190},
                        marginTop = 3,
                    },
                },
            })
        end

        table.insert(infoChildren, UI.Button {
            text = isSelected and "当前角色" or "选择 NO." .. index,
            width = "100%",
            height = 30,
            marginTop = 4,
            backgroundGradient = isSelected and {
                type = "linear",
                direction = "to-bottom",
                from = {82, 82, 78, 245},
                to = {42, 42, 39, 245},
            } or nil,
            backgroundColor = isSelected and nil or {48, 48, 45, 230},
            hoverBackgroundColor = isSelected and {96, 96, 90, 245} or {58, 58, 55, 240},
            pressedBackgroundColor = {68, 68, 64, 245},
            borderRadius = 5,
            borderWidth = 1,
            borderColor = isSelected and {178, 178, 168, 235} or {96, 96, 90, 200},
            fontSize = 13,
            fontWeight = "bold",
            fontColor = isSelected and {230, 230, 220, 255} or {196, 196, 188, 230},
            transition = "backgroundColor 0.15s easeOut, scale 0.12s easeOut",
            onClick = function()
                SelectSlot(index)
            end,
        })

        return UI.Panel {
            id = "info_card_" .. index,
            flexGrow = 1,
            backgroundGradient = isSelected and {
                type = "linear",
                direction = "to-bottom",
                from = {56, 56, 52, 255},
                to = {28, 28, 27, 255},
            } or nil,
            backgroundColor = isSelected and nil or C_INFO_BG,
            borderWidth = isSelected and 3 or 1,
            borderColor = borderCol,
            borderRadius = 8,
            paddingHorizontal = 12,
            paddingVertical = 8,
            scale = isSelected and 1.02 or 1.0,
            transition = "backgroundColor 0.18s easeOut, borderColor 0.18s easeOut, scale 0.18s easeOut",
            boxShadow = isSelected and {
                { x = 0, y = 0, blur = 18, spread = 1, color = {145, 145, 136, 65} },
                { x = 0, y = 10, blur = 18, spread = 0, color = {0, 0, 0, 110} },
            } or {
                { x = 0, y = 5, blur = 12, spread = 0, color = {0, 0, 0, 85} },
            },
            onPointerUp = function()
                SelectSlot(index)
            end,
            children = infoChildren,
        }
    end

    -- 中间操作按钮（石砖浮雕风格：双层边框模拟凸起）
    local function MakeActionButton(text, enabled, onPress)
        -- 外层Panel模拟暗色外沿（石砖缝隙），内层Button亮色上边模拟高光
        return UI.Panel {
            width = 114,
            height = 36,
            backgroundColor = enabled and {42, 40, 37, 255} or {28, 27, 25, 200},
            borderRadius = 3,
            borderWidth = 2,
            borderColor = enabled and {75, 73, 68, 240} or {38, 36, 33, 160},
            justifyContent = "center",
            alignItems = "center",
            children = {
                UI.Button {
                    text = text,
                    width = 106,
                    height = 28,
                    backgroundColor = enabled and C_BTN_BG or C_BTN_DISABLED,
                    borderRadius = 2,
                    borderWidth = 1,
                    borderColor = enabled and {110, 108, 100, 200} or {45, 43, 40, 140},
                    fontSize = 14,
                    fontColor = enabled and C_GOLD or C_LABEL_DIM,
                    disabled = not enabled,
                    onClick = enabled and onPress or nil,
                },
            },
        }
    end

    local slotData = slots[selectedSlot]
    local hasData = (slotData ~= nil)

    local btnStart = MakeActionButton("开始游戏", hasData, function()
        if callbacks.onContinue then callbacks.onContinue(selectedSlot) end
    end)
    local btnCreate = MakeActionButton("创建角色", not hasData, function()
        if callbacks.onCreate then callbacks.onCreate(selectedSlot) end
    end)
    local btnDelete = MakeActionButton("删除角色", hasData, function()
        GameUI._ShowDeleteConfirm(selectedSlot, slots, callbacks)
    end)

    -- 构建完整界面
    -- 关键设计：上半部分（视口）无不透明背景，让3D角色透出
    -- 下半部分（信息卡）完全不透明
    local saveSlotRoot = UI.Panel {
        id = "saveSlotScreen",
        width = "100%",
        height = "100%",
        -- 全屏布局，无背景让3D透出
        children = {
            -- === 上半部分：角色展示区（透明，3D透出，占满上方空间）===
            UI.Panel {
                width = "100%",
                flexGrow = 5,
                flexDirection = "row",
                padding = 10,
                gap = 8,
                -- 无 backgroundColor！让3D角色可见
                children = {
                    BuildViewport(1),
                    BuildViewport(2),
                },
            },
            -- === 分隔线 ===
            UI.Panel {
                width = "100%",
                height = 2,
                backgroundColor = {65, 63, 58, 255},
            },
            -- === 下半部分：信息卡 + 操作按钮（不透明石头底色）===
            UI.Panel {
                width = "100%",
                flexGrow = 1,
                flexDirection = "row",
                padding = 10,
                paddingHorizontal = 20,
                gap = 10,
                alignItems = "stretch",
                backgroundColor = C_STONE_BG,
                children = {
                    -- 左侧信息卡
                    BuildInfoCard(1),
                    -- 中间按钮列
                    UI.Panel {
                        width = 120,
                        justifyContent = "center",
                        alignItems = "center",
                        gap = 8,
                        children = {
                            btnStart,
                            btnCreate,
                            btnDelete,
                        },
                    },
                    -- 右侧信息卡
                    BuildInfoCard(2),
                },
            },
        },
    }

    UI.SetRoot(saveSlotRoot)
    print("[GameUI] Save slot screen shown (selected=" .. selectedSlot .. ")")
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
    -- 角色头像贴图
    local classAvatars = {
        warrior = "image/avatar_warrior_20260611121040.png",
        mage    = "image/avatar_mage_20260611121045.png",
        taoist  = "image/avatar_taoist_20260611121042.png",
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
            backgroundColor = {18, 18, 19, 248},
            borderRadius = 8,
            borderWidth = 1.5,
            borderColor = {92, 94, 98, 215},
            boxShadow = {
                { x = 0, y = 10, blur = 24, spread = 0, color = {0, 0, 0, 110} },
                { x = 0, y = 0, blur = 18, spread = 0, color = {118, 122, 128, 34} },
            },
            children = {
                UI.Panel {
                    width = 88, height = 88,
                    borderRadius = 44,
                    backgroundColor = {8, 6, 5, 255},
                    borderWidth = 3,
                    borderColor = glow,
                    justifyContent = "center",
                    alignItems = "center",
                    overflow = "hidden",
                    children = {
                        UI.Panel {
                            backgroundImage = classAvatars[classId],
                            width = 82, height = 82,
                            borderRadius = 41,
                        },
                    },
                },
                UI.Label {
                    text = cls.name,
                    fontSize = 22,
                    fontColor = {224, 226, 224, 255},
                    marginTop = 14,
                },
                UI.Label {
                    text = classDescLines[classId],
                    fontSize = 11,
                    fontColor = {152, 154, 150, 198},
                    marginTop = 6,
                    textAlign = "center",
                },
                UI.Panel {
                    width = "80%",
                    height = 1,
                    backgroundColor = {74, 76, 78, 110},
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
                    text = "进入暗夜",
                    marginTop = 16,
                    width = 130,
                    height = 40,
                    backgroundColor = {48, 49, 50, 244},
                    borderRadius = 4,
                    borderWidth = 1,
                    borderColor = {104, 106, 110, 205},
                    fontSize = 14,
                    fontColor = {222, 224, 222, 255},
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
                text = "暗夜传奇",
                fontSize = 36,
                fontColor = {220, 221, 219, 255},
                marginBottom = 4,
            },
            UI.Label {
                text = "选择你的命运",
                fontSize = 13,
                fontColor = {138, 140, 138, 180},
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
    -- 清除旧的 VirtualControls 组件（防止多次调用 Create 导致摇杆重复注册）
    VirtualControls.Clear()
    local hud = GameHUD.Create({})
    uiState.joystick = hud.joystick
    -- 隐藏 WASD 按键提示（保留键盘响应）
    if hud.joystick then
        hud.joystick.showKeyHints = false
    end

    -- ════════════════════════════════════════════════════════════════
    -- 全屏地图（纯 UI 实现 - 清晰的竞技场俯瞰图）
    -- ════════════════════════════════════════════════════════════════

    -- 玩家标记（大号绿色方块 + 白色边框）
    local fullMapPlayerDot = UI.Panel {
        position = "absolute",
        width = 14, height = 14,
        backgroundColor = {50, 255, 100, 255},
        borderWidth = 2,
        borderColor = {255, 255, 255, 230},
    }

    -- 玩家朝向线（全图）
    local fullMapPlayerDir = UI.Panel {
        position = "absolute",
        width = 3, height = 16,
        backgroundColor = {50, 255, 100, 220},
    }

    -- 网格线（将竞技场分为 4x4 格）── 水平 3 条 + 垂直 3 条
    local fmGridLines = {}
    for i = 1, 3 do
        table.insert(fmGridLines, UI.Panel {
            position = "absolute", height = 1,
            backgroundColor = {100, 90, 50, 60},
        })
    end
    for i = 1, 3 do
        table.insert(fmGridLines, UI.Panel {
            position = "absolute", width = 1,
            backgroundColor = {100, 90, 50, 60},
        })
    end

    -- 坐标标签（四个角 + 中心）
    local fmCoordLabels = {}
    local coordTexts = { "NW", "NE", "SW", "SE", "中心" }
    for _, txt in ipairs(coordTexts) do
        table.insert(fmCoordLabels, UI.Label {
            position = "absolute",
            text = txt,
            fontSize = 10,
            fontColor = {160, 150, 100, 120},
        })
    end

    -- 全图子元素组合
    local fmChildren = {}
    for _, g in ipairs(fmGridLines) do table.insert(fmChildren, g) end
    for _, c in ipairs(fmCoordLabels) do table.insert(fmChildren, c) end
    table.insert(fmChildren, fullMapPlayerDir)
    table.insert(fmChildren, fullMapPlayerDot)

    -- 全图地图区域（居中正方形，竞技场填充色）
    -- 不用 position="absolute"，让父容器 flexbox 居中
    local fullMapArea = UI.Panel {
        id = "fullmap_area",
        backgroundColor = {25, 38, 25, 245},
        borderWidth = 3,
        borderColor = {126, 130, 134, 245},
        borderRadius = 4,
        overflow = "hidden",
        children = fmChildren,
    }

    -- 标题
    local fullMapTitle = UI.Label {
        text = "竞技场地图 (120m × 120m)",
        fontSize = 15,
        fontColor = {218, 220, 218, 240},
        fontWeight = "bold",
        marginBottom = 6,
    }

    -- 图例
    local fullMapLegend = UI.Panel {
        flexDirection = "row",
        gap = 20,
        marginTop = 6,
        children = {
            UI.Panel {
                flexDirection = "row", alignItems = "center", gap = 4,
                children = {
                    UI.Panel { width = 10, height = 10, backgroundColor = {50, 255, 100, 255}, borderWidth = 1, borderColor = {255, 255, 255, 200} },
                    UI.Label { text = "你的位置", fontSize = 11, fontColor = {200, 200, 190, 220} },
                },
            },
            UI.Panel {
                flexDirection = "row", alignItems = "center", gap = 4,
                children = {
                    UI.Panel { width = 14, height = 14, backgroundColor = {30, 32, 34, 245}, borderWidth = 2, borderColor = {126, 130, 134, 245} },
                    UI.Label { text = "竞技场范围", fontSize = 11, fontColor = {200, 200, 190, 220} },
                },
            },
        },
    }

    -- 关闭提示
    local fullMapHint = UI.Label {
        text = "点击任意位置关闭 | M键切换",
        fontSize = 11,
        fontColor = {180, 175, 160, 150},
        marginTop = 4,
    }

    local fullMapOverlay = UI.Panel {
        id = "fullmap_overlay",
        position = "absolute",
        width = "100%", height = "100%",
        backgroundColor = {0, 0, 0, 180},
        justifyContent = "center",
        alignItems = "center",
        visible = false,
        onPointerUp = function()
            GameUI._CloseFullMap()
        end,
        children = {
            fullMapTitle,
            fullMapArea,
            fullMapLegend,
            fullMapHint,
        },
    }

    -- 保存引用
    uiState.refs.fullMapOverlay = fullMapOverlay
    uiState.refs.fullMapArea = fullMapArea
    uiState.refs.fullMapPlayerDot = fullMapPlayerDot
    uiState.refs.fullMapPlayerDir = fullMapPlayerDir
    uiState.refs.fullMapGridLines = fmGridLines
    uiState.refs.fullMapCoordLabels = fmCoordLabels

    local hudRoot = UI.Panel {
        id = "gameHUD",
        width = "100%",
        height = "100%",
        pointerEvents = "box-none",
        children = {
            GameUI._CreateSkillBar(player),
            GameUI._CreatePotions(player),
            GameUI._CreateMiniMapArea(player),
            GameUI._CreateTopButtons(),
            fullMapOverlay,
        },
    }

    uiState.hudRoot = hudRoot
    UI.SetRoot(hudRoot)

    -- 开场动画期间隐藏 HUD 元素，等开门动画完成后再显示
    local skillBar = hudRoot:FindById("skillBar")
    local potions = hudRoot:FindById("potions")
    local topRight = hudRoot:FindById("topRight")
    if skillBar then skillBar:SetVisible(false) end
    if potions then potions:SetVisible(false) end
    if topRight then topRight:SetVisible(false) end
    uiState.hudRevealed = false

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
-- 技能栏图标映射（全局复用）
local _skillBarIcons = {
    w_basic = "image/icon_w_basic_20260617040401_round.png",
    w_thrust = "image/icon_w_thrust_20260617040358_round.png",
    w_crescent = "image/icon_w_crescent_20260617040403_round.png",
    w_charge = "image/icon_w_charge_20260617040402_round.png",
    w_fire = "image/icon_w_fire_20260617040854_round.png",
    w_shield = "image/icon_w_shield_20260617040850_round.png",
    m_fireball = "image/icon_m_fireball_20260617040402_round.png",
    m_thunder = "image/icon_m_thunder_20260617040400_round.png",
    m_explosion = "image/icon_m_explosion_20260617040418_round.png",
    m_firewall = "image/icon_m_firewall_20260617040402_round.png",
    m_blizzard = "image/icon_m_blizzard_20260617041138_round.png",
    m_shield = "image/icon_m_shield_20260617040936_round.png",
    t_talisman = "image/icon_t_talisman_20260617040933_round.png",
    t_divineBeast = "image/icon_t_divineBeast_20260617064005_round.png",
    t_beastRage = "image/icon_t_beastRage_20260617040936_round.png",
    t_poison = "image/icon_t_poison_20260617061314_round.png",
    t_heal = "image/icon_t_heal_20260617040935_round.png",
    t_trapDemon = "image/icon_t_trapDemon_20260617061330_round.png",
}

local function _CreateRoundSkillIcon(props)
    local size = props.size or 40
    local iconSrc = props.iconSrc
    local fallbackText = props.fallbackText or "◆"
    local fallbackColor = props.fallbackColor or {240, 220, 160, 240}
    local fallbackFontSize = props.fallbackFontSize or math.floor(size * 0.45)
    local children = nil

    if not iconSrc then
        children = {
            UI.Label {
                text = fallbackText,
                fontSize = fallbackFontSize,
                fontColor = fallbackColor,
                textAlign = "center",
            },
        }
    end

    return UI.Panel {
        id = props.id,
        width = size,
        height = size,
        shape = "circle",
        clipPath = "circle",
        borderRadius = math.floor(size / 2),
        backgroundColor = props.backgroundColor or {10, 8, 6, 255},
        backgroundImage = iconSrc,
        backgroundFit = iconSrc and "cover" or nil,
        borderWidth = props.borderWidth,
        borderColor = props.borderColor,
        borderAlign = "inside",
        opacity = props.opacity or 1.0,
        justifyContent = "center",
        alignItems = "center",
        children = children,
    }
end

local function _IsSkillUsable(player, skill)
    if not skill or not CharacterClass.IsSkillUnlocked(skill, player.level) then return false end
    if skill.id == "t_divineBeast" or skill.summonType == "divineBeast" then
        return not DivineBeast.IsAlive()
    elseif skill.id == "t_beastRage" then
        return DivineBeast.IsAlive()
    end
    return true
end

function GameUI._CreateSkillBar(player)
    local classDef = CharacterClass.Classes[player.classId]

    local btnSize = {80, 54, 54, 54, 54, 54}
    local positions = {
        {x = -50,  y = -50},
        {x = -125, y = -55},
        {x = -180, y = -95},
        {x = -215, y = -150},
        {x = -225, y = -215},
        {x = -80,  y = -135},
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
        local skillName = skill and string.sub(skill.name, 1, 6) or ""
        local unlocked = skill and CharacterClass.IsSkillUnlocked(skill, player.level) or false
        local usable = _IsSkillUsable(player, skill)

        local borderClr = {baseClr[1], baseClr[2], baseClr[3], 180}

        local btnId = "skill_" .. i
        local btn = UI.Panel {
            id = btnId,
            position = "absolute",
            right = -pos.x - size / 2,
            bottom = -pos.y - size / 2,
            width = size,
            height = size,
            borderRadius = size / 2,
            shape = "circle",
            clipPath = "circle",
            backgroundColor = usable and {25, 22, 18, 210} or {18, 18, 18, 210},
            borderWidth = 2,
            borderColor = borderClr,
            justifyContent = "center",
            alignItems = "center",
            overflow = "hidden",
            children = {
                (skill and _skillBarIcons[skill.id]) and _CreateRoundSkillIcon {
                    id = "skill_icon_" .. i,
                    iconSrc = _skillBarIcons[skill.id],
                    size = math.floor(size * 0.88),
                    opacity = usable and 1.0 or 0.35,
                } or UI.Label {
                    text = skillName,
                    fontSize = size <= 56 and 10 or 12,
                    fontColor = unlocked and {240, 235, 220, 255} or {100, 100, 100, 150},
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
                unlocked and UI.Panel {
                    position = "absolute",
                    bottom = 3,
                    width = 6, height = 6,
                    borderRadius = 3,
                    backgroundColor = {220, 210, 190, 255},
                } or nil,
            },
            onPointerUp = function()
                if not _IsSkillUsable(player, skill) then return end
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
            icon = (btn and skill) and btn:FindById("skill_icon_" .. i) or nil,
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



-- ============================================================================
-- 左下角 - 药瓶快捷键（球的右侧偏移）
-- ============================================================================
function GameUI._CreatePotions(player)
    local hpCount = Inventory.GetPotionCount("hp")
    local mpCount = Inventory.GetPotionCount("mp")

    -- 正确的坐标转换：NanoVG 设计单位 → UI base pixels
    -- NanoVG 使用 physScale = graphics.height / 720 (物理像素)
    -- UI 系统使用 UI.GetScale() 作为内部缩放 (base pixels × scale = 物理像素)
    -- 转换系数: toUI = physScale / uiSysScale
    local physH = graphics:GetHeight()
    local physScale = physH / 720               -- NanoVG 缩放系数
    local uiSysScale = UI.GetScale()            -- UI 系统缩放系数
    local toUI = physScale / uiSysScale         -- NanoVG 设计单位 → UI base pixels

    -- 血量球参数 (来自 _DrawOrbs): cx=72, r=52, cy_from_bottom=105 (NanoVG 设计单位)
    -- 药瓶放在球右边缘右侧
    local potionSize = math.floor(math.max(30, 38 * toUI))
    local innerSize = math.floor(potionSize * 0.74)
    local labelH = math.floor(math.max(14, 16 * toUI))
    local potionLeft = math.floor((72 + 52 + 10) * toUI)     -- 球右边缘 + 间距
    local potionBottom = math.floor(105 * toUI - potionSize / 2 - labelH * 0.55)  -- 图标垂直居中于球心，数字在下方
    local potionGap = math.floor(math.max(4, 6 * toUI))
    local potionFontSize = math.max(11, math.floor(12 * toUI))

    -- 药瓶图标贴图
    local potionIcons = {
        hp = "image/icon_potion_hp_20260611121043.png",
        mp = "image/icon_potion_mp_20260611121048.png",
    }

    local function makePotion(kind, count, cfg)
        local countLabel = UI.Label {
            id = "potion_" .. kind .. "_count",
            text = tostring(count),
            fontSize = potionFontSize,
            fontColor = {255, 255, 255, 255},
            fontWeight = "bold",
        }
        uiState.refs["potion_" .. kind .. "_count"] = countLabel

        -- CD 遮罩（半透明深色圆 + 秒数文字）
        local cdOverlay = UI.Panel {
            id = "potion_" .. kind .. "_cd",
            position = "absolute",
            width = potionSize, height = potionSize,
            borderRadius = math.floor(potionSize / 2),
            backgroundColor = {0, 0, 0, 150},
            justifyContent = "center",
            alignItems = "center",
            visible = false,
        }
        uiState.refs["potion_" .. kind .. "_cd"] = cdOverlay

        return UI.Panel {
            width = potionSize,
            height = potionSize + labelH,
            flexDirection = "column",
            alignItems = "center",
            justifyContent = "flex-start",
            gap = math.max(1, math.floor(1 * toUI)),
            onPointerUp = function()
                if kind == "hp" then
                    if GameUI.onUseHpPotion then GameUI.onUseHpPotion() end
                else
                    if GameUI.onUseMpPotion then GameUI.onUseMpPotion() end
                end
            end,
            children = {
                UI.Panel {
                    width = potionSize, height = potionSize,
                    borderRadius = math.floor(potionSize / 2),
                    backgroundColor = cfg.bodyBg,
                    borderWidth = math.max(2, math.floor(2.5 * toUI)),
                    borderColor = cfg.rimColor,
                    justifyContent = "center",
                    alignItems = "center",
                    overflow = "hidden",
                    children = {
                        UI.Panel {
                            backgroundImage = potionIcons[kind],
                            position = "absolute",
                            width = innerSize, height = innerSize,
                            borderRadius = math.floor(innerSize / 2),
                        },
                        cdOverlay,
                    },
                },
                countLabel,
            },
        }
    end

    return UI.Panel {
        id = "potions",
        position = "absolute",
        left = potionLeft, bottom = potionBottom,
        flexDirection = "row",
        gap = potionGap,
        children = {
            makePotion("hp", hpCount, {
                bodyBg     = {35, 8, 8, 230},
                rimColor   = {200, 60, 45, 230},
                liquidColor = {150, 28, 22, 210},
                highlight  = {255, 180, 160, 120},
            }),
            makePotion("mp", mpCount, {
                bodyBg     = {8, 10, 40, 230},
                rimColor   = {50, 110, 210, 230},
                liquidColor = {22, 50, 150, 210},
                highlight  = {160, 200, 255, 120},
            }),
        },
    }
end

-- ============================================================================
-- 药水数量动态更新
-- ============================================================================
function GameUI.UpdatePotionCount(kind, count)
    local ref = uiState.refs["potion_" .. kind .. "_count"]
    if ref then ref:SetText(tostring(count)) end
end

-- ============================================================================
-- 右上角 - 小地图 + 信息
-- ============================================================================
function GameUI._CreateMiniMapArea(player)
    -- ── 整合右上角：小地图(UI实现) + 信息条 + 角色/系统按钮 ──

    local mapSize = 72  -- 稍大一点，更清晰
    local mapRadius = mapSize / 2
    -- 竞技场在小地图中的区域：留圆边距后居中放一个正方形
    local arenaPad = 10  -- 圆形外边距
    local arenaDrawSize = mapSize - arenaPad * 2  -- 竞技场方块的像素尺寸

    -- ── 玩家标记（绿色方块）──
    local playerDot = UI.Panel {
        position = "absolute",
        width = 8, height = 8,
        backgroundColor = {50, 255, 100, 255},
        borderWidth = 1,
        borderColor = {255, 255, 255, 200},
    }

    -- ── 玩家朝向指示线 ──
    local playerDir = UI.Panel {
        position = "absolute",
        width = 2, height = 8,
        backgroundColor = {50, 255, 100, 200},
    }

    -- ── 网格线（将竞技场分为 4 象限）──
    local gridH = UI.Panel {
        position = "absolute",
        left = 0, top = math.floor(arenaDrawSize / 2),
        width = arenaDrawSize, height = 1,
        backgroundColor = {120, 110, 60, 80},
    }
    local gridV = UI.Panel {
        position = "absolute",
        left = math.floor(arenaDrawSize / 2), top = 0,
        width = 1, height = arenaDrawSize,
        backgroundColor = {120, 110, 60, 80},
    }

    -- ── 竞技场区域（实心方块，包含玩家和网格，overflow裁剪）──
    local arenaBlock = UI.Panel {
        position = "absolute",
        left = arenaPad, top = arenaPad,
        width = arenaDrawSize, height = arenaDrawSize,
        backgroundColor = {30, 32, 34, 200},  -- 深灰填充
        borderWidth = 2,
        borderColor = {126, 130, 134, 245},  -- 银灰粗边框
        overflow = "hidden",  -- 裁剪超出边界的玩家标记
        children = { gridH, gridV, playerDir, playerDot },
    }

    -- ── 指北标 "N"（固定在圆形顶部）──
    local northLabel = UI.Label {
        position = "absolute",
        text = "N",
        fontSize = 9,
        fontColor = {226, 228, 226, 240},
        fontWeight = "bold",
        top = 1, left = mapRadius - 4,
    }

    -- 组合所有子元素
    local mapChildren = { arenaBlock, northLabel }

    -- 小地图容器（圆形深色背景 + 银灰边框）
    local miniMap = UI.Panel {
        id = "minimap_ui",
        width = mapSize, height = mapSize,
        borderRadius = mapRadius,
        backgroundColor = {12, 13, 14, 232},
        borderWidth = 2,
        borderColor = {126, 130, 134, 225},
        overflow = "hidden",
        onPointerUp = function()
            GameUI._OpenFullMap()
        end,
        children = mapChildren,
    }

    -- 保存引用用于每帧更新
    uiState.refs.miniMapContainer = miniMap
    uiState.refs.miniMapPlayerDot = playerDot
    uiState.refs.miniMapPlayerDir = playerDir
    uiState.refs.miniMapNorthLabel = northLabel
    uiState.refs.miniMapSize = mapSize
    uiState.refs.miniMapArenaPad = arenaPad
    uiState.refs.miniMapArenaDrawSize = arenaDrawSize

    -- 信息条（击杀 + 金币，紧凑横排）
    local infoBar = UI.Panel {
        flexDirection = "row",
        alignItems = "center",
        backgroundColor = {18, 18, 19, 205},
        borderRadius = 10,
        borderWidth = 1,
        borderColor = {94, 98, 102, 140},
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
                    UI.Label { text = "💰", fontSize = 11, fontColor = {218, 220, 218, 230} },
                    (function()
                        local lbl = UI.Label {
                            text = "0", fontSize = 11, fontColor = {226, 228, 226, 240},
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
            paddingLeft = 14, paddingRight = 14,
            paddingTop = 8, paddingBottom = 8,
            borderRadius = 14,
            backgroundColor = bgColor,
            borderWidth = 1,
            borderColor = borderColor,
            onPointerUp = onTap,
            children = {
                UI.Label {
                    text = label,
                    fontSize = 13,
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
                {232, 234, 232, 255},
                {34, 35, 37, 214},
                {118, 122, 126, 170},
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

local function _FormatCooldown(value)
    local cd = tonumber(value) or 0
    if math.abs(cd - math.floor(cd + 0.5)) < 0.001 then
        return tostring(math.floor(cd + 0.5))
    end
    return string.format("%.1f", cd)
end

--- 构建技能 Tab 内容
local function _BuildSkillTabContent(player)
    local classDef = CharacterClass.Classes[player.classId]
    local allSkills = CharacterClass.GetSkillsSortedByLevel(player.classId)

    -- 技能菜单与 HUD 共用同一批圆形适配图，避免方形图标露出白边。
    -- 备用 emoji（当图标文件不存在时降级）
    local skillIcons = {
        melee  = "⚔", ranged = "🏹", aoe = "🔥",
        buff   = "✦", heal   = "✚", dot = "☠",
        dash   = "⚡", summon = "👁",
    }

    local skillRows = {}
    for _, skill in ipairs(allSkills) do
        local unlocked = CharacterClass.IsSkillUnlocked(skill, player.level)
        local locked = not unlocked
        local equippedSlot = 0
        for s = 1, 6 do
            if player.equippedSkills[s] and player.equippedSkills[s].id == skill.id then
                equippedSlot = s
                break
            end
        end

        local iconSrc = _skillBarIcons[skill.id]
        local iconFallback = skillIcons[skill.type] or "◆"
        local nameColor = locked and {92, 92, 92, 155} or {224, 226, 224, 255}
        local iconBg = locked and {30, 30, 31, 200} or equippedSlot > 0 and {54, 56, 60, 242} or {38, 39, 41, 232}
        local iconBorder = locked and {54, 54, 54, 135} or equippedSlot > 0 and {136, 140, 144, 210} or {92, 94, 98, 180}

        table.insert(skillRows, UI.Panel {
            width = "100%", flexDirection = "row", alignItems = "center",
            paddingVertical = 8, paddingHorizontal = 6, gap = 10,
            onPointerUp = not locked and function()
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
            end or nil,
            children = {
                -- 技能图标圆形容器
                UI.Panel {
                    width = 48, height = 48,
                    backgroundColor = iconBg,
                    shape = "circle",
                    clipPath = "circle",
                    borderRadius = 24,
                    borderWidth = 2,
                    borderColor = iconBorder,
                    borderAlign = "inside",
                    justifyContent = "center", alignItems = "center",
                    children = {
                        _CreateRoundSkillIcon {
                            iconSrc = iconSrc,
                            size = 42,
                            backgroundColor = iconBg,
                            opacity = locked and 0.35 or 1.0,
                            fallbackText = iconFallback,
                            fallbackFontSize = 22,
                            fallbackColor = locked and {92, 92, 92, 132} or {226, 228, 226, 240},
                        },
                    },
                },
                -- 右侧：技能名 + 描述 + 解锁规则
                UI.Panel {
                    flex = 1, flexShrink = 1, justifyContent = "center",
                    children = {
                        UI.Label {
                            text = skill.name,
                            fontSize = 16, fontWeight = "bold",
                            fontColor = nameColor,
                        },
                        UI.Label {
                            text = skill.desc or "",
                            fontSize = 11, fontColor = locked and {90, 90, 90, 125} or {174, 176, 176, 205},
                            marginTop = 2,
                        },
                        UI.Label {
                            text = string.format("Lv.%d 解锁  |  %s  CD:%ss",
                                math.floor((skill.unlockLevel or 1) + 0.5),
                                locked and "未解锁" or "已解锁",
                                _FormatCooldown(skill.cooldown)),
                            fontSize = 10,
                            fontColor = locked and {100, 100, 100, 155} or {178, 180, 178, 205},
                            marginTop = 2,
                        },
                    },
                },
                -- 装备状态指示
                equippedSlot > 0 and UI.Panel {
                    width = 20, height = 20, borderRadius = 10,
                    backgroundColor = {88, 90, 94, 220},
                    borderWidth = 1, borderColor = {126, 130, 134, 220},
                    justifyContent = "center", alignItems = "center",
                    children = {
                        UI.Label { text = tostring(equippedSlot), fontSize = 10, fontColor = {236, 238, 236, 255}, fontWeight = "bold" },
                    },
                } or nil,
            },
        })

        -- 分隔线（除最后一项）
        if _ < #allSkills then
            table.insert(skillRows, UI.Panel {
                width = "100%", height = 1, backgroundColor = {70, 72, 74, 85},
            })
        end
    end

    return UI.Panel {
        width = "100%", flex = 1, flexShrink = 1, overflow = "scroll",
        children = skillRows,
    }
end

-- ============================================================================
-- 装备面板 Tab（传奇风格：人物轮廓 + 10槽位环绕）
-- ============================================================================
local function _BuildEquipTabContent(player)
    local inv = Inventory.playerData
    local SLOT = Inventory.SLOT
    local SLOT_NAMES = Inventory.SLOT_NAMES
    local RARITY = Inventory.RARITY

    local function refreshPanel()
        GameUI.HideCharacterPanel()
        GameUI.ShowCharacterPanel(player, "equip")
    end

    -- 装备详情弹窗
    local function showItemDetail(item, slotKey)
        local rarity = RARITY[item.rarity]
        local rarityClr = rarity and rarity.color or {200, 200, 200}
        local nameColor = {rarityClr[1], rarityClr[2], rarityClr[3], 255}
        local rarityName = rarity and rarity.name or "普通"
        local slotLabel = SLOT_NAMES[slotKey] or slotKey

        -- 构建属性列表
        local statRows = {}
        if item.atk > 0 then
            table.insert(statRows, UI.Panel { flexDirection = "row", gap = 6, children = {
                UI.Label { text = "攻击力", fontSize = 13, fontColor = {160, 150, 130, 200} },
                UI.Label { text = "+" .. item.atk, fontSize = 13, fontColor = {255, 100, 80, 240}, fontWeight = "bold" },
            }})
        end
        if item.def > 0 then
            table.insert(statRows, UI.Panel { flexDirection = "row", gap = 6, children = {
                UI.Label { text = "防御力", fontSize = 13, fontColor = {160, 150, 130, 200} },
                UI.Label { text = "+" .. item.def, fontSize = 13, fontColor = {80, 180, 255, 240}, fontWeight = "bold" },
            }})
        end
        if item.hp > 0 then
            table.insert(statRows, UI.Panel { flexDirection = "row", gap = 6, children = {
                UI.Label { text = "生命值", fontSize = 13, fontColor = {160, 150, 130, 200} },
                UI.Label { text = "+" .. item.hp, fontSize = 13, fontColor = {80, 230, 100, 240}, fontWeight = "bold" },
            }})
        end

        local capturedSlot = slotKey
        local detailPanel = UI.Panel {
            position = "absolute", width = "100%", height = "100%",
            justifyContent = "center", alignItems = "center",
            backgroundColor = {0, 0, 0, 180},
            onPointerUp = function()
                -- 关闭弹窗：刷新面板
                refreshPanel()
            end,
            children = {
                UI.Panel {
                    width = 220, minHeight = 160,
                    backgroundColor = {25, 20, 15, 250},
                    borderRadius = 10, borderWidth = 2,
                    borderColor = {rarityClr[1], rarityClr[2], rarityClr[3], 200},
                    paddingHorizontal = 16, paddingVertical = 14,
                    alignItems = "center",
                    children = {
                        -- 品质标签
                        UI.Label { text = "[" .. rarityName .. "]", fontSize = 11, fontColor = nameColor, marginBottom = 4 },
                        -- 物品名称
                        UI.Label { text = item.name, fontSize = 18, fontWeight = "bold", fontColor = nameColor, marginBottom = 2 },
                        -- 槽位类型
                        UI.Label { text = slotLabel, fontSize = 11, fontColor = {140, 130, 110, 160}, marginBottom = 10 },
                        -- 分隔线
                        UI.Panel { width = "80%", height = 1, backgroundColor = {100, 90, 70, 100}, marginBottom = 10 },
                        -- 属性行
                        UI.Panel { alignItems = "flex-start", gap = 6, marginBottom = 14, children = statRows },
                        -- 卸下按钮
                        UI.Button {
                            text = "卸下装备", variant = "outline",
                            width = 140, height = 34,
                            onClick = function()
                                Inventory.UnequipSlot(capturedSlot)
                                refreshPanel()
                            end,
                        },
                    },
                },
            },
        }
        -- 将详情弹窗附加到面板上层
        if uiState.charPanelRoot then
            uiState.charPanelRoot:AddChild(detailPanel)
        end
    end

    -- 单个装备槽 UI 构建
    local function makeSlotCell(slotKey, w, h)
        w = w or 72
        h = h or 78
        local item = inv.equipped[slotKey]
        local label = SLOT_NAMES[slotKey] or slotKey
        local rarity = item and RARITY[item.rarity] or nil
        local rarityClr = rarity and rarity.color or nil
        local nameColor = rarityClr and {rarityClr[1], rarityClr[2], rarityClr[3], 255} or {120, 115, 100, 180}
        local borderClr = rarityClr and {rarityClr[1], rarityClr[2], rarityClr[3], 200} or {55, 50, 42, 150}
        local bgColor = item and {30, 24, 18, 250} or {22, 18, 14, 200}

        -- 属性简述
        local statParts = {}
        if item then
            if item.atk > 0 then table.insert(statParts, "攻" .. item.atk) end
            if item.def > 0 then table.insert(statParts, "防" .. item.def) end
            if item.hp  > 0 then table.insert(statParts, "血" .. item.hp) end
        end
        local statText = table.concat(statParts, " ")

        local capturedSlot = slotKey
        local capturedItem = item

        -- 卸下按钮（右上角小 ✕ 图标）
        local unequipBtn = nil
        if item then
            unequipBtn = UI.Panel {
                position = "absolute", top = 2, right = 2,
                width = 16, height = 16,
                backgroundColor = {80, 20, 20, 200},
                borderRadius = 8,
                justifyContent = "center", alignItems = "center",
                onPointerUp = function()
                    Inventory.UnequipSlot(capturedSlot)
                    refreshPanel()
                end,
                children = {
                    UI.Label { text = "✕", fontSize = 10, fontColor = {255, 120, 100, 240} },
                },
            }
        end

        return UI.Panel {
            width = w, height = h, overflow = "visible",
            backgroundColor = bgColor, borderRadius = 5,
            borderWidth = item and 1.5 or 1, borderColor = borderClr,
            justifyContent = "center", alignItems = "center",
            paddingHorizontal = 3, paddingVertical = 3,
            -- 点击装备区域 → 弹出详情
            onPointerUp = capturedItem and function()
                showItemDetail(capturedItem, capturedSlot)
            end or nil,
            children = {
                -- 卸下按钮（右上角）
                unequipBtn,
                -- 槽位标签
                UI.Label { text = label, fontSize = 9, fontColor = {140, 130, 100, 160} },
                -- 物品名称
                UI.Label {
                    text = item and item.name or "—",
                    fontSize = item and 11 or 10,
                    fontWeight = item and "bold" or "normal",
                    fontColor = nameColor, marginTop = 2,
                    textAlign = "center",
                },
                -- 属性
                (item and statText ~= "") and UI.Label {
                    text = statText, fontSize = 9,
                    fontColor = {180, 175, 155, 190}, marginTop = 1,
                    textAlign = "center",
                } or nil,
            },
        }
    end

    -- 计算总属性
    local totalAtk = inv.bonusAtk or 0
    local totalDef = inv.bonusDef or 0
    local totalHP  = inv.bonusHP  or 0

    -- 布局：传奇经典三列布局
    -- 左列：头盔、项链、左手镯、左戒指、腰带
    -- 中间：人物轮廓 + 属性
    -- 右列：武器、盔甲、右手镯、右戒指、鞋子

    local leftCol = UI.Panel {
        width = 78, alignItems = "center", gap = 4,
        children = {
            makeSlotCell(SLOT.HELMET, 72, 72),
            makeSlotCell(SLOT.NECKLACE, 72, 72),
            makeSlotCell(SLOT.BRACELET1, 72, 72),
            makeSlotCell(SLOT.RING1, 72, 72),
            makeSlotCell(SLOT.BELT, 72, 72),
        },
    }

    local rightCol = UI.Panel {
        width = 78, alignItems = "center", gap = 4,
        children = {
            makeSlotCell(SLOT.WEAPON, 72, 72),
            makeSlotCell(SLOT.ARMOR, 72, 72),
            makeSlotCell(SLOT.BRACELET2, 72, 72),
            makeSlotCell(SLOT.RING2, 72, 72),
            makeSlotCell(SLOT.BOOTS, 72, 72),
        },
    }

    -- 中间人物轮廓区域
    local classDef = CharacterClass.Classes[player.classId]
    local classColor = classDef and classDef.color or {200, 180, 120}
    local centerCol = UI.Panel {
        flex = 1, alignItems = "center", justifyContent = "center",
        paddingVertical = 8,
        children = {
            -- 人物轮廓（简化用文字符号表示）
            UI.Panel {
                width = 100, height = 200,
                backgroundColor = {12, 10, 8, 200},
                borderRadius = 8, borderWidth = 1,
                borderColor = {60, 50, 35, 120},
                justifyContent = "center", alignItems = "center",
                children = {
                    UI.Label {
                        text = classDef and classDef.name or "角色",
                        fontSize = 14, fontWeight = "bold",
                        fontColor = {classColor[1], classColor[2], classColor[3], 220},
                    },
                    UI.Label { text = "Lv." .. player.level, fontSize = 12, fontColor = {200, 190, 160, 200}, marginTop = 4 },
                    -- 人物轮廓符号
                    UI.Label { text = "⚔", fontSize = 40, fontColor = {classColor[1], classColor[2], classColor[3], 140}, marginTop = 8 },
                },
            },
            -- 属性总计
            UI.Panel {
                width = "100%", marginTop = 10, alignItems = "center", gap = 3,
                children = {
                    UI.Label { text = "— 装备属性 —", fontSize = 10, fontColor = {172, 174, 174, 180} },
                    UI.Panel {
                        flexDirection = "row", gap = 8, marginTop = 4,
                        children = {
                            UI.Label { text = "攻+" .. totalAtk, fontSize = 12, fontColor = {255, 100, 80, 230}, fontWeight = "bold" },
                            UI.Label { text = "防+" .. totalDef, fontSize = 12, fontColor = {80, 180, 255, 230}, fontWeight = "bold" },
                            UI.Label { text = "血+" .. totalHP, fontSize = 12, fontColor = {80, 230, 100, 230}, fontWeight = "bold" },
                        },
                    },
                },
            },
        },
    }

    return UI.Panel {
        width = "100%", flexShrink = 1, overflow = "scroll",
        children = {
            -- 提示
            UI.Label {
                text = "点击装备查看详情 · ✕卸下",
                fontSize = 10, fontColor = {150, 152, 152, 165},
                textAlign = "center", marginBottom = 6,
            },
            -- 三列布局
            UI.Panel {
                flexDirection = "row", width = "100%",
                justifyContent = "space-between", alignItems = "flex-start",
                children = { leftCol, centerCol, rightCol },
            },
        },
    }
end

--- 构建背包 Tab 内容
local function _BuildBagTabContent(player)
    local inv = Inventory.playerData
    if not inv.potions then inv.potions = { hp = 5, mp = 3 } end
    local RARITY = Inventory.RARITY

    local function refreshPanel()
        GameUI.HideCharacterPanel()
        GameUI.ShowCharacterPanel(player, "bag")
    end

    -- 背包格子：固定60x68，5列排布，点击装备
    local bagCells = {}
    for i = 1, 20 do
        local item = inv.bag[i]
        local rarity = item and RARITY[item.rarity] or nil
        local rarityClr = rarity and rarity.color or nil
        local nameColor = rarityClr and {rarityClr[1], rarityClr[2], rarityClr[3], 235} or {80, 78, 70, 100}
        local bgColor = item and {28, 23, 17, 240} or {18, 15, 12, 120}
        local borderClr = rarityClr and {rarityClr[1], rarityClr[2], rarityClr[3], 130} or {42, 38, 32, 90}

        local statParts = {}
        if item then
            if item.atk > 0 then table.insert(statParts, "攻" .. item.atk) end
            if item.def > 0 then table.insert(statParts, "防" .. item.def) end
            if item.hp  > 0 then table.insert(statParts, "血" .. item.hp) end
        end
        local briefStat = table.concat(statParts, " ")

        local capturedItem = item
        table.insert(bagCells, UI.Panel {
            width = 66, height = 70, overflow = "hidden",
            backgroundColor = bgColor, borderRadius = 5,
            borderWidth = 1, borderColor = borderClr,
            justifyContent = "center", alignItems = "center",
            paddingHorizontal = 4, paddingVertical = 4,
            onPointerUp = capturedItem and function()
                Inventory.EquipItem(capturedItem, player.classId)
                refreshPanel()
            end or nil,
            children = {
                item and UI.Label {
                    text = item.name, fontSize = 11, fontWeight = "bold",
                    fontColor = nameColor, textAlign = "center",
                } or nil,
                item and briefStat ~= "" and UI.Label {
                    text = briefStat,
                    fontSize = 9, fontColor = {175, 170, 155, 185}, marginTop = 1, textAlign = "center",
                } or nil,
                item and UI.Label {
                    text = "▲装备",
                    fontSize = 9, fontColor = {110, 190, 110, 150}, marginTop = 1,
                } or nil,
            },
        })
    end

    return UI.Panel {
        width = "100%", flexShrink = 1, overflow = "scroll",
        children = {
            -- 金币行
            UI.Panel {
                flexDirection = "row", alignItems = "center", gap = 6, marginBottom = 10,
                children = {
                    UI.Label { text = "💰", fontSize = 16 },
                    UI.Label { text = tostring(inv.gold), fontSize = 16, fontColor = {226, 228, 226, 255}, fontWeight = "bold" },
                },
            },
            -- 药水区
            UI.Panel {
                flexDirection = "row", gap = 10, marginBottom = 12, alignItems = "center",
                children = {
                    UI.Label { text = "药水", fontSize = 12, fontColor = {178, 180, 178, 205} },
                    -- HP 药水购买
                    UI.Panel {
                        flexDirection = "row", alignItems = "center", gap = 4,
                        paddingHorizontal = 8, paddingVertical = 5,
                        backgroundColor = {60, 18, 18, 180}, borderRadius = 8,
                        borderWidth = 1, borderColor = {160, 60, 50, 150},
                        onPointerUp = function()
                            local ok, msg = Inventory.BuyPotion("hp")
                            if ok then
                                GameUI.UpdatePotionCount("hp", Inventory.GetPotionCount("hp"))
                            end
                            refreshPanel()
                        end,
                        children = {
                            UI.Label { text = "血药", fontSize = 11, fontColor = {240, 100, 80, 255}, fontWeight = "bold" },
                            UI.Label { text = inv.potions.hp .. "/" .. Inventory.POTION_CONFIG.hp.max, fontSize = 10, fontColor = {200, 190, 170, 200} },
                            UI.Label { text = "💰" .. Inventory.POTION_CONFIG.hp.price, fontSize = 10, fontColor = {220, 222, 220, 220} },
                        },
                    },
                    -- MP 药水购买
                    UI.Panel {
                        flexDirection = "row", alignItems = "center", gap = 4,
                        paddingHorizontal = 8, paddingVertical = 5,
                        backgroundColor = {18, 18, 60, 180}, borderRadius = 8,
                        borderWidth = 1, borderColor = {55, 100, 170, 150},
                        onPointerUp = function()
                            local ok, msg = Inventory.BuyPotion("mp")
                            if ok then
                                GameUI.UpdatePotionCount("mp", Inventory.GetPotionCount("mp"))
                            end
                            refreshPanel()
                        end,
                        children = {
                            UI.Label { text = "蓝药", fontSize = 11, fontColor = {80, 150, 230, 255}, fontWeight = "bold" },
                            UI.Label { text = inv.potions.mp .. "/" .. Inventory.POTION_CONFIG.mp.max, fontSize = 10, fontColor = {200, 190, 170, 200} },
                            UI.Label { text = "💰" .. Inventory.POTION_CONFIG.mp.price, fontSize = 10, fontColor = {220, 222, 220, 220} },
                        },
                    },
                },
            },
            -- 分隔
            UI.Panel { width = "100%", height = 1, backgroundColor = {72, 74, 76, 105}, marginBottom = 10 },
            -- 背包区
            UI.Label { text = "背包 " .. #inv.bag .. "/20", fontSize = 12, fontColor = {178, 180, 178, 205}, marginBottom = 8 },
            UI.Panel { flexDirection = "row", flexWrap = "wrap", gap = 6, children = bagCells },
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
    _SyncPauseState()

    local activeTab = tab or "skill"
    local classDef = CharacterClass.Classes[player.classId]

    -- Tab 按钮样式
    local function makeTab(label, tabId)
        local active = (activeTab == tabId)
        return UI.Panel {
            flex = 1, height = 36, borderRadius = 6,
            backgroundColor = active and {62, 64, 68, 245} or {30, 31, 33, 195},
            borderWidth = active and 1.5 or 0,
            borderColor = {126, 130, 134, 180},
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
                    fontColor = active and {236, 238, 236, 255} or {176, 178, 180, 200},
                    fontWeight = active and "bold" or "normal",
                },
            },
        }
    end

    -- 构建内容区
    local content
    if activeTab == "equip" then
        content = _BuildEquipTabContent(player)
    elseif activeTab == "skill" then
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
                width = 320, height = 520,
                backgroundColor = {16, 12, 10, 248},
                borderRadius = 10, borderWidth = 2,
                borderColor = {124, 126, 130, 198},
                padding = 14, overflow = "hidden",
                children = {
                    -- 标题栏
                    UI.Panel {
                        flexDirection = "row", justifyContent = "space-between", alignItems = "center",
                        width = "100%", marginBottom = 10,
                        children = {
                            UI.Label { text = "角色 — " .. classDef.name, fontSize = 18, fontColor = {234, 236, 234, 255}, fontWeight = "bold" },
                            UI.Label { text = "Lv." .. player.level, fontSize = 15, fontColor = {200, 190, 170, 220} },
                        },
                    },
                    -- Tab 栏
                    UI.Panel {
                        flexDirection = "row", width = "100%", gap = 8, marginBottom = 12,
                        children = {
                            makeTab("装备", "equip"),
                            makeTab("技能", "skill"),
                            makeTab("背包", "bag"),
                        },
                    },
                    -- 分隔线
                    UI.Panel { width = "100%", height = 1, backgroundColor = {72, 74, 76, 120}, marginBottom = 10 },
                    -- 内容区
                    content,
                    -- 关闭按钮
                    UI.Panel {
                        width = "100%", alignItems = "center", marginTop = 12,
                        children = {
                            UI.Button {
                                text = "关闭",
                                width = 120, height = 38,
                                backgroundColor = {48, 49, 50, 244},
                                borderRadius = 6, borderWidth = 1,
                                borderColor = {126, 130, 134, 205},
                                fontSize = 15, fontColor = {222, 224, 222, 255},
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
    _SyncPauseState()
    uiState.charPanelRoot = nil
    if uiState.hudRoot then
        UI.SetRoot(uiState.hudRoot)
    end
    -- 强制重置摇杆状态，防止面板操作期间触摸被误捕获导致摇杆卡住
    GameUI._ResetJoystickState()
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
    _SyncPauseState()

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
                borderColor = {124, 126, 130, 198},
                padding = 20,
                alignItems = "center",
                gap = 10,
                children = {
                    -- 标题
                    UI.Label { text = "系统", fontSize = 18, fontColor = {228, 230, 228, 240} },
                    -- 分隔线
                    UI.Panel { width = "100%", height = 1, backgroundColor = {72, 74, 76, 110} },
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
                    UI.Panel { width = "100%", height = 1, backgroundColor = {70, 72, 74, 90} },
                    -- DBG 区域
                    UI.Panel {
                        width = "100%",
                        backgroundColor = {18, 19, 20, 172},
                        borderRadius = 6, borderWidth = 1,
                        borderColor = {86, 90, 94, 118},
                        padding = 8,
                        alignItems = "center",
                        gap = 6,
                        children = {
                            UI.Label { text = "调试", fontSize = 10, fontColor = {146, 150, 154, 165} },
                            UI.Panel {
                                flexDirection = "row", gap = 10, alignItems = "center",
                                children = {
                                    UI.Panel {
                                        width = 60, height = 36, borderRadius = 6,
                                        backgroundColor = {58, 60, 64, 220},
                                        justifyContent = "center", alignItems = "center",
                                        onPointerUp = function()
                                            if GameUI.onDebugLevelChange then GameUI.onDebugLevelChange(1) end
                                            GameUI.HideSystemPanel()
                                            GameUI.ShowSystemPanel()
                                        end,
                                        children = {
                                            UI.Label { text = "Lv+", fontSize = 13, fontColor = {232, 234, 232, 255} },
                                        },
                                    },
                                    (function()
                                        local lbl = UI.Label {
                                            text = "Lv." .. (uiState.player and uiState.player.level or 1),
                                            fontSize = 14,
                                            fontColor = {214, 216, 214, 240},
                                        }
                                        uiState.debugLevelLabel = lbl
                                        return lbl
                                    end)(),
                                    UI.Panel {
                                        width = 60, height = 36, borderRadius = 6,
                                        backgroundColor = {70, 58, 58, 220},
                                        justifyContent = "center", alignItems = "center",
                                        onPointerUp = function()
                                            if GameUI.onDebugLevelChange then GameUI.onDebugLevelChange(-1) end
                                            GameUI.HideSystemPanel()
                                            GameUI.ShowSystemPanel()
                                        end,
                                        children = {
                                            UI.Label { text = "Lv-", fontSize = 13, fontColor = {236, 200, 200, 255} },
                                        },
                                    },
                                },
                            },
                            -- 一键满级+技能全开
                            UI.Panel {
                                width = 140, height = 36, borderRadius = 6,
                                backgroundColor = {66, 68, 72, 220},
                                justifyContent = "center", alignItems = "center",
                                marginTop = 4,
                                onPointerUp = function()
                                    if GameUI.onDebugMaxLevel then GameUI.onDebugMaxLevel() end
                                    GameUI.HideSystemPanel()
                                    GameUI.ShowSystemPanel()
                                end,
                                children = {
                                    UI.Label { text = "一键满级", fontSize = 13, fontColor = {236, 238, 236, 255} },
                                },
                            },
                        },
                    },
                    -- 关闭按钮
                    UI.Button {
                        text = "关闭",
                        width = 130, height = 40,
                        backgroundColor = {36, 36, 38, 240},
                        borderRadius = 6, borderWidth = 1,
                        borderColor = {124, 126, 130, 180},
                        fontSize = 15, fontColor = {220, 222, 220, 240},
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
    _SyncPauseState()
    uiState.systemPanelRoot = nil
    if uiState.hudRoot then
        UI.SetRoot(uiState.hudRoot)
    end
    -- 强制重置摇杆状态，防止面板操作期间触摸被误捕获导致摇杆卡住
    GameUI._ResetJoystickState()
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
        GameUI._UpdateToasts(dt)
        return
    end

    if not uiState.hudRoot then return end

    uiState.player = player

    for i = 1, 6 do
        local sb = uiState.skillButtons[i]
        if sb and sb.skill then
            local cd = player.cooldowns[sb.skill.id] or 0
            local usable = _IsSkillUsable(player, sb.skill)
            local cdPanel = uiState.refs["skill_" .. i .. "_cd"]
            local cdText  = uiState.refs["skill_" .. i .. "_cdText"]
            if cd > 0 then
                if cdPanel then cdPanel:SetStyle({ backgroundColor = {0, 0, 0, 140} }) end
                if cdText then cdText:SetText(string.format("%.0f", math.ceil(cd))) end
            else
                if cdPanel then cdPanel:SetStyle({ backgroundColor = {0, 0, 0, 0} }) end
                if cdText then cdText:SetText("") end
            end
            if sb.panel then
                sb.panel:SetStyle({ backgroundColor = usable and {25, 22, 18, 210} or {18, 18, 18, 210} })
            end
            if sb.icon then
                sb.icon:SetStyle({ opacity = usable and 1.0 or 0.35 })
            end
            if not usable and cd <= 0 then
                if cdPanel then cdPanel:SetStyle({ backgroundColor = {0, 0, 0, 135} }) end
                if cdText then cdText:SetText("") end
            end
        end
    end

    if doorState.active then
        doorState.progress = doorState.progress + dt / doorState.duration
        if doorState.progress >= 1 then
            doorState.progress = 1
            doorState.active = false
            if doorState.onComplete then doorState.onComplete() end
            print("[GameUI] Door transition complete")
        end
        -- 门打开 70% 时显示 HUD 元素
        if not uiState.hudRevealed and doorState.progress >= 0.7 then
            uiState.hudRevealed = true
            local skillBar = uiState.hudRoot and uiState.hudRoot:FindById("skillBar")
            local potions = uiState.hudRoot and uiState.hudRoot:FindById("potions")
            local topRight = uiState.hudRoot and uiState.hudRoot:FindById("topRight")
            if skillBar then skillBar:SetVisible(true) end
            if potions then potions:SetVisible(true) end
            if topRight then topRight:SetVisible(true) end
        end
    elseif not uiState.hudRevealed and uiState.hudRoot then
        -- 如果没有开门动画（如重新ShowGameHUD），直接显示
        uiState.hudRevealed = true
        local skillBar = uiState.hudRoot:FindById("skillBar")
        local potions = uiState.hudRoot:FindById("potions")
        local topRight = uiState.hudRoot:FindById("topRight")
        if skillBar then skillBar:SetVisible(true) end
        if potions then potions:SetVisible(true) end
        if topRight then topRight:SetVisible(true) end
    end

    -- 更新 debug 等级标签
    if uiState.debugLevelLabel and player then
        uiState.debugLevelLabel:SetText("Lv." .. player.level)
    end

    -- 更新药瓶 CD 遮罩（UI 层）
    GameUI._UpdatePotionCDOverlay()

    -- 更新地图系统（UI 实现）
    GameUI._UpdateMiniMapUI()
    GameUI._UpdateFullMapUI()

    GameUI._UpdateFloatingTexts(dt)
    GameUI._UpdateToasts(dt)
end

-- ============================================================================
-- 药瓶 CD 遮罩更新（UI 实现，覆盖在药瓶按钮上方）
-- ============================================================================
function GameUI._UpdatePotionCDOverlay()
    local cd = GameUI.potionCD
    if not cd then return end

    local kinds = {"hp", "mp"}
    for _, kind in ipairs(kinds) do
        local overlay = uiState.refs["potion_" .. kind .. "_cd"]
        if overlay then
            local ratio = cd[kind] or 0
            if ratio > 0.01 then
                overlay:SetVisible(true)
                -- 更新透明度随 CD 比例变化（CD 越满越暗）
                local alpha = math.floor(120 + 60 * ratio)
                overlay:SetStyle({ backgroundColor = {0, 0, 0, alpha} })
            else
                overlay:SetVisible(false)
            end
        end
    end
end

-- ============================================================================
-- 小地图 UI 更新（每帧调用）
-- ============================================================================
function GameUI._UpdateMiniMapUI()
    if not playerNodeRef then return end
    local playerDot = uiState.refs.miniMapPlayerDot
    local playerDir = uiState.refs.miniMapPlayerDir
    local arenaDrawSize = uiState.refs.miniMapArenaDrawSize
    if not arenaDrawSize then return end

    local halfArena = mapState.arenaSize / 2  -- 60m
    local playerPos = playerNodeRef.worldPosition

    -- 玩家世界坐标 → arenaBlock 内部像素坐标（相对于 arenaBlock content area）
    -- 世界 (-60, +60) → 像素 (0, 0)  左上角=西北
    -- 世界 (+60, -60) → 像素 (arenaDrawSize, arenaDrawSize)  右下角=东南
    local normX = (playerPos.x + halfArena) / (halfArena * 2)  -- 0~1
    local normZ = (halfArena - playerPos.z) / (halfArena * 2)  -- 0~1
    -- 不 clamp，让 overflow:hidden 自动裁剪

    local dotX = normX * arenaDrawSize
    local dotY = normZ * arenaDrawSize

    -- 更新玩家标记位置（相对于 arenaBlock 内部）
    if playerDot then
        playerDot:SetStyle({ left = math.floor(dotX - 4), top = math.floor(dotY - 4) })
    end

    -- 更新朝向指示线
    if playerDir then
        local camNode = cameraRef and cameraRef:GetNode() or nil
        local camYaw = 0
        if camNode then camYaw = camNode.worldRotation:YawAngle() end
        local yawRad = math.rad(camYaw)
        -- 从玩家点向前方延伸 6px
        local endX = dotX + math.sin(yawRad) * 6
        local endY = dotY - math.cos(yawRad) * 6
        local midX = (dotX + endX) / 2
        local midY = (dotY + endY) / 2
        playerDir:SetStyle({ left = math.floor(midX - 1), top = math.floor(midY - 4) })
    end
end

-- ============================================================================
-- 全屏地图 UI 更新（仅在全图打开时调用）
-- ============================================================================
function GameUI._UpdateFullMapUI()
    if not mapState.fullMapOpen or not playerNodeRef then return end

    local fullMapArea = uiState.refs.fullMapArea
    local playerDot = uiState.refs.fullMapPlayerDot
    local playerDir = uiState.refs.fullMapPlayerDir
    local gridLines = uiState.refs.fullMapGridLines
    local coordLabels = uiState.refs.fullMapCoordLabels
    if not fullMapArea or not playerDot then return end

    -- 使用屏幕尺寸的 55% 作为地图正方形尺寸
    local sw = graphics.width / UI.GetScale()
    local sh = graphics.height / UI.GetScale()
    local mapSize = math.floor(math.min(sw, sh) * 0.55)
    local halfArena = mapState.arenaSize / 2  -- 60m

    -- 设置地图区域尺寸（居中由 flexbox 处理，此处只设宽高）
    fullMapArea:SetStyle({ width = mapSize, height = mapSize })

    -- 地图内边距（边框内）
    local pad = math.floor(mapSize * 0.04)
    local innerSize = mapSize - pad * 2

    -- 更新网格线位置（3 水平 + 3 垂直，分为 4x4 格）
    if gridLines then
        for i = 1, 3 do
            -- 水平线
            local yPos = pad + math.floor(innerSize * i / 4)
            gridLines[i]:SetStyle({ left = pad, top = yPos, width = innerSize })
        end
        for i = 1, 3 do
            -- 垂直线
            local xPos = pad + math.floor(innerSize * i / 4)
            gridLines[3 + i]:SetStyle({ left = xPos, top = pad, height = innerSize })
        end
    end

    -- 更新坐标标签位置（NW, NE, SW, SE, 中心）
    if coordLabels then
        local offset = 4
        coordLabels[1]:SetStyle({ left = pad + offset, top = pad + offset })           -- NW
        coordLabels[2]:SetStyle({ left = pad + innerSize - 18, top = pad + offset })   -- NE
        coordLabels[3]:SetStyle({ left = pad + offset, top = pad + innerSize - 14 })   -- SW
        coordLabels[4]:SetStyle({ left = pad + innerSize - 18, top = pad + innerSize - 14 }) -- SE
        coordLabels[5]:SetStyle({ left = pad + math.floor(innerSize / 2) - 10, top = pad + math.floor(innerSize / 2) - 6 }) -- 中心
    end

    -- 坐标转换：世界坐标 → 全图像素
    local playerPos = playerNodeRef.worldPosition
    local normX = (playerPos.x + halfArena) / (halfArena * 2)  -- 0~1
    local normZ = (halfArena - playerPos.z) / (halfArena * 2)  -- 0~1
    normX = math.max(0, math.min(1, normX))
    normZ = math.max(0, math.min(1, normZ))

    local dotX = pad + normX * innerSize
    local dotY = pad + normZ * innerSize

    -- 更新玩家标记
    playerDot:SetStyle({ left = math.floor(dotX - 7), top = math.floor(dotY - 7) })

    -- 更新朝向指示线
    if playerDir then
        local camNode = cameraRef and cameraRef:GetNode() or nil
        local camYaw = 0
        if camNode then camYaw = camNode.worldRotation:YawAngle() end
        local yawRad = math.rad(camYaw)
        local endX = dotX + math.sin(yawRad) * 12
        local endY = dotY - math.cos(yawRad) * 12
        local midX = (dotX + endX) / 2
        local midY = (dotY + endY) / 2
        playerDir:SetStyle({ left = math.floor(midX - 1), top = math.floor(midY - 8) })
    end
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

function GameUI._UpdateToasts(dt)
    local i = 1
    while i <= #uiState.toasts do
        local toast = uiState.toasts[i]
        toast.timer = toast.timer + dt
        if toast.timer >= toast.duration then
            table.remove(uiState.toasts, i)
        else
            i = i + 1
        end
    end
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
-- 强制重置摇杆状态（面板关闭后调用，清除可能的触摸残留）
-- ============================================================================
function GameUI._ResetJoystickState()
    local joystick = uiState.joystick
    if not joystick then return end
    -- 如果摇杆当前处于激活状态（有触摸绑定），强制释放
    if joystick.isActive and joystick.touchId then
        joystick:handleTouchEnd(joystick.touchId)
    end
    -- 确保方向值归零
    joystick.x = 0
    joystick.y = 0
    joystick.magnitude = 0
    joystick.isActive = false
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
GameUI.onDebugMaxLevel = nil     -- function() : 一键满级+技能栏填充

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
