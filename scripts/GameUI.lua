-- ============================================================================
-- GameUI.lua — 暗夜传奇 完整 UI 系统
-- 暗黑地牢风角色选择 + NanoVG 圆球 HP/MP (左下角) + EXP条 + 开门过渡
-- + 技能栏 + 飘字 + 菜单/背包按钮 + 背包面板 + 施法条 + 技能选择面板
-- ============================================================================

local UI = require("urhox-libs/UI")
local CharacterClass = require("scripts.CharacterClass")
local Inventory = require("scripts.Inventory")
local EquipmentPanel = require("scripts.EquipmentPanel")
local BlacksmithPanel = require("scripts.BlacksmithPanel")
local Quest = require("scripts.Quest")
local MapZone = require("scripts.MapZone")
local NPC = require("scripts.NPC")
local PlayerAnim = require("scripts.PlayerAnim")
local DivineBeast = require("scripts.DivineBeast")
local ServiceScrollView = require("scripts.ServiceScrollView")
local SoundManager = require("scripts.SoundManager")
require "urhox-libs.UI.GameHUD"

local GameUI = {}

-- UI.SetRoot 不会自动刷新鼠标悬停目标。打开商店/铁匠浮层后，如果鼠标
-- 没有再次移动，滚轮事件仍可能沿着已销毁的 HUD 节点查找，导致列表看似
-- 无法滚动；切换根节点后主动同步一次桌面端 hover 状态。
local function _RefreshMouseHoverAfterRootSwitch()
    local inputAdapter = UI.Input and UI.Input.GetAdapter and UI.Input.GetAdapter()
    if not inputAdapter or not inputAdapter.IsDesktop or not inputAdapter:IsDesktop() then
        return
    end
    local sx, sy = UI.Input.GetLastPosition(0)
    -- SetRoot 只标记布局脏；先计算一次新树布局，命中测试才能找到
    -- 刚打开的滚动容器。
    if UI.Layout then UI.Layout() end
    if UI.HandleMouseMove then
        UI.HandleMouseMove(sx, sy)
    end
end

-- UI 颜色
local C = CharacterClass.Colors

-- [调试] 显示玩家与敌人的距离开关（由 main.lua 按键切换）
GameUI.debugShowDistance = false
-- [调试] 显示相机/模型包围盒信息（正式游戏默认关闭）
GameUI.debugShowOverlay = false
-- 调试入口默认不进入正式菜单；本地排错时可由宿主显式设为 true。
GameUI.debugMode = false
---@type table|nil
GameUI.potionCD = nil

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

-- NanoVG 使用系统逻辑分辨率；UI 库内部会自行处理 DPR。
-- 统一从 GetWidth/GetHeight 读取，避免高 DPI 设备上混用物理像素和逻辑像素。
local function _GetScreenMetrics()
    local physW = graphics:GetWidth()
    local physH = graphics:GetHeight()
    local dpr = tonumber(graphics:GetDPR()) or 1
    if dpr <= 0 then dpr = 1 end
    return physW, physH, dpr, physW / dpr, physH / dpr
end

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
---@type Node|nil
local playerNodeRef = nil  -- 玩家节点引用（用于地图系统）
local sceneRef = nil       -- 场景引用（用于暂停 timeScale）

-- ============================================================================
-- 地图系统状态
-- ============================================================================
local mapState = {
    fullMapOpen = false,
    arenaSize = MapZone.ARENA_SIZE,
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
    saveSlotRoot = nil,
    selectRoot = nil,
    classSelectOverlayMode = false,
    onClassSelectCancelled = nil,
    refs = {},
    charPanelOpen = false,
    charPanelRoot = nil,
    itemDetailRoot = nil,
    systemPanelOpen = false,
    systemPanelRoot = nil,
    teleportPanelOpen = false,
    teleportPanelRoot = nil,
    npcPanelOpen = false,
    npcPanelRoot = nil,
    blacksmithTab = "forge",
    blacksmithSelectedItem = nil,
    npcInteractBtn = nil,  -- HUD 上的 NPC 交互按钮（靠近时显示）
    dialogueActive = false,
    dialogueLines = nil,      -- 待播放的对话行列表
    dialogueIndex = 0,
    dialogueRoot = nil,
    dialogueOnDone = nil,
    deathMarkRoot = nil,
    deathLossModal = nil,
    deathReviveCallback = nil,
}

GameUI.state = uiState

-- 游戏内浮层统一使用固定标题栏，确保返回入口不会被长列表挤出屏幕。
-- 保持在用户代码中实现；urhox-libs/UI 参考副本只读，不能修改。
local function _CreateOverlayHeader(title, onBack, options)
    options = options or {}
    local headingChildren = {
        UI.Label {
            text = title,
            fontSize = options.titleFontSize or 18,
            fontColor = options.titleColor or {234, 236, 234, 255},
            fontWeight = "bold",
        },
    }
    if options.subtitle then
        table.insert(headingChildren, UI.Label {
            text = options.subtitle,
            fontSize = options.subtitleFontSize or 11,
            fontColor = options.subtitleColor or {164, 164, 158, 205},
            marginTop = 2,
        })
    end

    return UI.Panel {
        width = "100%",
        minHeight = 38,
        flexShrink = 0,
        flexDirection = "row",
        justifyContent = "space-between",
        alignItems = "center",
        gap = 10,
        marginBottom = options.marginBottom or 10,
        children = {
            UI.Panel {
                flexGrow = 1,
                flexShrink = 1,
                alignItems = "flex-start",
                children = headingChildren,
            },
            UI.Button {
                text = options.backText or "← 返回",
                width = options.backWidth or 82,
                height = 34,
                flexShrink = 0,
                variant = "outline",
                fontSize = 13,
                onClick = onBack,
            },
        },
    }
end

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

    -- InputAdapter 先通知 Gesture、再通知 UI 的 pointer dispatcher；如果
    -- Gesture 在 PointerDown 时没有拿到目标，PanStart 只能按当前坐标猜测
    -- 目标，拖动商店/锻造列表时就容易被按钮截住。提前补上初始命中目标，
    -- 让滚动手势沿着按下位置稳定地冒泡到 ScrollView。
    if UI.Gesture and UI.Gesture.HandlePointerDown
        and not UI.Gesture._makerTargetPatch then
        local originalHandlePointerDown = UI.Gesture.HandlePointerDown
        UI.Gesture.HandlePointerDown = function(event)
            if event and not event.target and UI.FindWidgetAt then
                local scale = (UI.GetScale and UI.GetScale()) or 1
                if scale <= 0 then scale = 1 end
                event.target = UI.FindWidgetAt(event.x / scale, event.y / scale)
            end
            return originalHandlePointerDown(event)
        end
        UI.Gesture._makerTargetPatch = true
    end
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
    local _, _, dpr, sw, sh = _GetScreenMetrics()
    nvgBeginFrame(nvgCtx, sw, sh, dpr)

    -- urhox-libs/UI 与本模块的 HUD 使用不同 NanoVG context；HUD context
    -- 后创建、通常后绘制。死亡演出期间不再绘制底层 HUD，避免血球、血条、
    -- 飘字或 Toast 盖到中央“死”字和结算弹窗上。
    if uiState.deathMarkRoot or uiState.deathLossModal then
        nvgEndFrame(nvgCtx)
        return
    end

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
    if GameUI.debugShowOverlay and uiState.phase == "playing" and cameraRef then
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
    local _, _, dpr = _GetScreenMetrics()
    local uiSysScale = math.max(UI.GetScale(), 0.001)
    local toRaw = uiSysScale / dpr
    -- 药瓶位置与 _CreatePotions 保持一致
    -- UI base pixels → NanoVG logical pixels，需要乘 UI scale / DPR。
    local btnSize = math.max(30 * toRaw, 38 * scale)  -- 匹配 potionSize (含下限)
    local gap = math.max(4 * toRaw, 6 * scale)
    local baseLeft = (72 + 52 + 10) * scale
    -- 球心距底 = 105*scale, 药瓶垂直居中于球心
    local baseBottom = 105 * scale - btnSize / 2

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
    if mapState.fullMapOpen or uiState.charPanelOpen or uiState.systemPanelOpen
        or uiState.teleportPanelOpen or uiState.npcPanelOpen or uiState.dialogueActive
        or uiState.deathMarkRoot or uiState.deathLossModal then
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
        return true
    end

    -- 任何其他模态界面打开时，不允许 M 键把全图压到其上方。
    -- 关闭当前模态后，玩家可以再主动打开全图。
    if uiState.charPanelOpen or uiState.systemPanelOpen or uiState.teleportPanelOpen
        or uiState.npcPanelOpen or uiState.dialogueActive then
        return false
    else
        GameUI._OpenFullMap()
        return true
    end
end

function GameUI.IsFullMapOpen()
    return mapState.fullMapOpen
end

--- 判断游戏是否应暂停（任何面板打开时暂停）
function GameUI.IsGamePaused()
    return mapState.fullMapOpen or uiState.charPanelOpen or uiState.systemPanelOpen
        or uiState.teleportPanelOpen or uiState.dialogueActive or uiState.npcPanelOpen
        or uiState.deathMarkRoot ~= nil or uiState.deathLossModal ~= nil
end

--- 统一处理键盘 ESC / Android 返回键。
--- 每次只关闭最上层界面；主线对话不在这里跳过，仍由玩家点击逐句推进。
---@return boolean handled 是否消费了本次返回操作
function GameUI.HandleBackAction()
    -- 死亡演出和结算不能用返回键跳过；必须看完结算并点击“复活”。
    if uiState.deathMarkRoot or uiState.deathLossModal then
        return true
    end

    -- 删除、出售、分解确认等 UI.Modal 必须先于宿主面板关闭，
    -- 避免一次返回同时退出确认框和商店/角色面板。
    ---@type any
    local topOverlay = UI.GetTopOverlay and UI.GetTopOverlay() or nil
    if topOverlay then
        if type(topOverlay.Close) == "function" then
            topOverlay:Close()
        end
        return true
    end

    if GameUI.IsItemDetailOpen and GameUI.IsItemDetailOpen() then
        GameUI.HideItemDetail()
        return true
    end
    if uiState.npcPanelOpen then
        GameUI.HideNPCPanel()
        return true
    end
    if uiState.teleportPanelOpen then
        GameUI.HideTeleportPanel()
        return true
    end
    if uiState.systemPanelOpen then
        GameUI.HideSystemPanel()
        return true
    end
    if uiState.charPanelOpen then
        GameUI.CloseCharacterPanel()
        return true
    end
    if mapState.fullMapOpen then
        GameUI._CloseFullMap()
        return true
    end
    if uiState.selectRoot and uiState.classSelectOverlayMode then
        GameUI.CancelClassSelect()
        return true
    end

    return false
end

-- ============================================================================
-- 角色死亡演出与结算弹窗
-- ============================================================================

--- 清理中央“死”字演出，但保留之后可能打开的死亡结算弹窗。
function GameUI.HideDeathMark()
    if uiState.deathMarkRoot then
        uiState.deathMarkRoot:Remove()
        uiState.deathMarkRoot = nil
        _SyncPauseState()
    end
end

--- 显示屏幕中央红色“死”字。使用 UI Widget 而不是 raw NanoVG，确保它在
--- HUD 之上、能拦截触摸，并自动适配 DPR 与小屏 UI 缩放。
---@param duration number|nil
function GameUI.ShowDeathMark(duration)
    if uiState.deathLossModal then
        local oldModal = uiState.deathLossModal
        uiState.deathLossModal = nil
        uiState.deathReviveCallback = nil
        oldModal:Close()
    end
    GameUI.HideDeathMark()

    local effectDuration = math.max(0.6, tonumber(duration) or 1.2)
    local glyph = UI.Label {
        text = "死",
        width = 260,
        height = 210,
        fontSize = 154,
        fontWeight = "bold",
        textAlign = "center",
        verticalAlign = "middle",
        fontColor = {238, 28, 30, 255},
        textStroke = { width = 4, color = {72, 0, 0, 255} },
        textShadow = { offsetX = 0, offsetY = 8, blur = 16, color = {255, 20, 20, 190} },
        opacity = 0,
        scale = 2.15,
        rotate = -8,
        transformOrigin = "center",
    }
    local outerRing = UI.Panel {
        position = "absolute",
        left = 20, top = 6,
        width = 220, height = 220,
        borderRadius = 110,
        borderWidth = 3,
        borderColor = {205, 24, 28, 175},
        backgroundColor = {95, 0, 0, 42},
        opacity = 0,
        scale = 0.45,
        transformOrigin = "center",
        pointerEvents = "none",
    }
    local innerRing = UI.Panel {
        position = "absolute",
        left = 45, top = 31,
        width = 170, height = 170,
        borderRadius = 85,
        borderWidth = 1,
        borderColor = {255, 92, 72, 150},
        backgroundColor = {135, 4, 6, 36},
        opacity = 0,
        scale = 0.65,
        transformOrigin = "center",
        pointerEvents = "none",
    }
    local subtitle = UI.Label {
        text = "魂归安全区",
        fontSize = 14,
        fontWeight = "bold",
        fontColor = {220, 154, 144, 230},
        letterSpacing = 5,
        marginTop = -8,
        opacity = 0,
        translateY = 10,
    }

    glyph:Animate({
        keyframes = {
            [0] = { opacity = 0, scale = 2.15, rotate = -8 },
            [0.28] = { opacity = 1, scale = 0.88, rotate = 2 },
            [0.50] = { opacity = 1, scale = 1.08, rotate = -1 },
            [0.78] = { opacity = 1, scale = 1.0, rotate = 0 },
            [1] = { opacity = 0.82, scale = 1.03, rotate = 0 },
        },
        duration = effectDuration,
        easing = "easeOutCubic",
        fillMode = "forwards",
    })
    outerRing:Animate({
        keyframes = {
            [0] = { opacity = 0, scale = 0.45 },
            [0.35] = { opacity = 0.9, scale = 1.0 },
            [1] = { opacity = 0.12, scale = 1.35 },
        },
        duration = effectDuration,
        easing = "easeOutCubic",
        fillMode = "forwards",
    })
    innerRing:Animate({
        keyframes = {
            [0] = { opacity = 0, scale = 0.65 },
            [0.42] = { opacity = 0.8, scale = 1.0 },
            [1] = { opacity = 0.18, scale = 1.18 },
        },
        duration = effectDuration,
        easing = "easeOutCubic",
        fillMode = "forwards",
    })
    subtitle:Animate({
        keyframes = {
            [0] = { opacity = 0, translateY = 10 },
            [0.45] = { opacity = 0, translateY = 10 },
            [0.75] = { opacity = 1, translateY = 0 },
            [1] = { opacity = 0.75, translateY = 0 },
        },
        duration = effectDuration,
        easing = "easeOutCubic",
        fillMode = "forwards",
    })

    uiState.deathMarkRoot = UI.Panel {
        id = "deathMarkOverlay",
        position = "absolute",
        left = 0, top = 0,
        width = "100%", height = "100%",
        zIndex = 10000,
        justifyContent = "center",
        alignItems = "center",
        pointerEvents = "auto",
        backgroundGradient = {
            type = "radial",
            innerRadius = 0,
            outerRadius = 520,
            from = {112, 0, 0, 178},
            to = {0, 0, 0, 220},
        },
        onClick = function() end,
        children = {
            UI.Panel {
                width = 260,
                height = 258,
                justifyContent = "center",
                alignItems = "center",
                pointerEvents = "none",
                children = { outerRing, innerRing, glyph, subtitle },
            },
        },
    }

    if uiState.hudRoot then
        uiState.hudRoot:AddChild(uiState.deathMarkRoot)
    else
        UI.SetRoot(uiState.deathMarkRoot)
    end
    _SyncPauseState()
end

--- 显示死亡损失明细。弹窗只能通过“复活”按钮关闭，避免返回键绕过流程。
---@param lossInfo table|nil {goldLost,goldRemaining,lossRatio}
---@param onRevive function|nil
function GameUI.ShowDeathLossDialog(lossInfo, onRevive)
    GameUI.HideDeathMark()
    if uiState.deathLossModal then
        local oldModal = uiState.deathLossModal
        uiState.deathLossModal = nil
        oldModal:Close()
    end

    lossInfo = type(lossInfo) == "table" and lossInfo or {}
    local goldLost = math.max(0, math.floor(tonumber(lossInfo.goldLost) or 0))
    local goldRemaining = math.max(0, math.floor(tonumber(lossInfo.goldRemaining) or 0))
    local lossPercent = math.max(0, math.floor((tonumber(lossInfo.lossRatio) or 0) * 100 + 0.5))
    local lossText = goldLost > 0 and ("-" .. goldLost .. " 金币") or "本次未损失金币"
    local lossColor = goldLost > 0 and {246, 72, 62, 255} or {166, 190, 166, 255}

    local modal
    local function ConfirmRevive()
        local callback = uiState.deathReviveCallback
        uiState.deathReviveCallback = nil
        if uiState.deathLossModal then
            local activeModal = uiState.deathLossModal
            uiState.deathLossModal = nil
            activeModal:Close()
        end
        if callback then callback() end
        _SyncPauseState()
    end

    modal = UI.Modal {
        title = "死亡结算",
        size = "sm",
        isOpen = false,
        showCloseButton = false,
        closeOnOverlay = false,
        closeOnEscape = false,
        backgroundColor = {26, 14, 13, 252},
        borderWidth = 2,
        borderColor = {151, 48, 43, 240},
        titleTextColor = {246, 92, 78, 255},
        titleFontSize = 18,
        children = {
            UI.Panel {
                width = "100%",
                alignItems = "center",
                gap = 8,
                children = {
                    UI.Label {
                        text = "你在战斗中倒下了",
                        fontSize = 14,
                        fontColor = {224, 214, 206, 255},
                    },
                    UI.Panel {
                        width = "100%",
                        paddingVertical = 12,
                        paddingHorizontal = 14,
                        alignItems = "center",
                        backgroundColor = {68, 20, 18, 220},
                        borderWidth = 1,
                        borderColor = {162, 55, 48, 220},
                        borderRadius = 6,
                        children = {
                            UI.Label {
                                text = "金币损失（当前金币的 " .. lossPercent .. "%）",
                                fontSize = 12,
                                fontColor = {190, 158, 150, 230},
                            },
                            UI.Label {
                                text = lossText,
                                fontSize = 24,
                                fontWeight = "bold",
                                fontColor = lossColor,
                                marginTop = 3,
                            },
                            UI.Label {
                                text = "剩余金币：" .. goldRemaining,
                                fontSize = 12,
                                fontColor = {198, 190, 180, 230},
                                marginTop = 3,
                            },
                        },
                    },
                    UI.Label {
                        text = "经验、装备、任务进度均保留",
                        fontSize = 12,
                        fontColor = {170, 196, 168, 240},
                    },
                    UI.Label {
                        text = "复活时，存活的怪物、精英和 Boss 将恢复满血",
                        width = "100%",
                        fontSize = 12,
                        fontColor = {198, 170, 158, 235},
                        textAlign = "center",
                        whiteSpace = "normal",
                    },
                    UI.Button {
                        text = "复活",
                        width = 132,
                        height = 38,
                        marginTop = 6,
                        variant = "primary",
                        backgroundColor = {168, 42, 37, 255},
                        borderWidth = 1,
                        borderColor = {235, 92, 76, 240},
                        fontSize = 14,
                        fontWeight = "bold",
                        onClick = ConfirmRevive,
                    },
                },
            },
        },
    }

    uiState.deathLossModal = modal
    uiState.deathReviveCallback = onRevive
    modal:Open()
    _SyncPauseState()
end

--- 强制清理死亡演出与弹窗（退出角色会话、重建 HUD、关闭游戏时使用）。
function GameUI.HideDeathPresentation()
    uiState.deathReviveCallback = nil
    GameUI.HideDeathMark()
    if uiState.deathLossModal then
        local modal = uiState.deathLossModal
        uiState.deathLossModal = nil
        modal:Close()
    end
    _SyncPauseState()
end

function GameUI.IsDeathPresentationActive()
    return uiState.deathMarkRoot ~= nil or uiState.deathLossModal ~= nil
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
-- 剧情对话演出系统
-- ============================================================================

--- 播放一段对话（逐句）
---@param lines table[] {speaker=说话人, text=台词}
---@param onDone function|nil 全部播完后的回调
function GameUI.PlayDialogue(lines, onDone)
    if not lines or #lines == 0 then
        if onDone then onDone() end
        return
    end

    uiState.dialogueActive = true
    uiState.dialogueLines = lines
    -- 首句已经在下面立即显示，因此索引从 1 开始；否则第一次点击会重复首句。
    uiState.dialogueIndex = 1
    uiState.dialogueOnDone = onDone

    _SyncPauseState()

    GameUI._ShowDialogueLine(lines[1])
end

--- 显示单句对话
function GameUI._ShowDialogueLine(line)
    -- 清除旧对话框
    if uiState.dialogueRoot then
        uiState.dialogueRoot:Remove()
        uiState.dialogueRoot = nil
    end

    local speaker = line.speaker or "旁白"
    local isNarrator = (line.speaker == nil or line.speaker == "旁白")
    local nameColor = isNarrator and {200, 190, 160, 255} or {255, 210, 90, 255}

    uiState.dialogueRoot = UI.Panel {
        id = "dialogueOverlay",
        position = "absolute",
        left = 0, right = 0, bottom = 0,
        height = "30%",
        pointerEvents = "auto",
        paddingHorizontal = 40, paddingVertical = 16,
        children = {
            UI.Panel {
                width = "100%", height = "100%",
                backgroundColor = {8, 6, 5, 232},
                borderRadius = 10, borderWidth = 2,
                borderColor = {150, 120, 70, 180},
                padding = 18,
                justifyContent = "flex-start",
                onClick = function()
                    GameUI._AdvanceDialogue()
                end,
                children = {
                    UI.Label {
                        text = speaker,
                        fontSize = 15, fontWeight = "bold",
                        fontColor = nameColor, marginBottom = 8,
                    },
                    UI.Label {
                        text = line.text,
                        fontSize = 16,
                        fontColor = {235, 232, 222, 255},
                        lineHeight = 1.4,
                    },
                    UI.Label {
                        text = "▼ 点击继续",
                        fontSize = 11, fontColor = {140, 138, 130, 180},
                        position = "absolute", right = 16, bottom = 12,
                    },
                },
            },
        },
    }

    -- 挂到当前 HUD 根（若存在）
    if uiState.hudRoot then
        uiState.hudRoot:AddChild(uiState.dialogueRoot)
    else
        UI.SetRoot(uiState.dialogueRoot)
    end
end

--- 推进到下一句对话
function GameUI._AdvanceDialogue()
    if not uiState.dialogueActive then return end

    uiState.dialogueIndex = uiState.dialogueIndex + 1
    local lines = uiState.dialogueLines
    local idx = uiState.dialogueIndex

    if idx > #lines then
        -- 播放完毕
        GameUI._EndDialogue()
        return
    end

    GameUI._ShowDialogueLine(lines[idx])
end

--- 结束对话
function GameUI._EndDialogue()
    if uiState.dialogueRoot then
        uiState.dialogueRoot:Remove()
        uiState.dialogueRoot = nil
    end
    uiState.dialogueActive = false
    uiState.dialogueLines = nil
    uiState.dialogueIndex = 0
    local onDone = uiState.dialogueOnDone
    uiState.dialogueOnDone = nil
    _SyncPauseState()
    if onDone then onDone() end
end

--- 是否正在播放对话
function GameUI.IsDialogueActive()
    return uiState.dialogueActive
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
-- 存档槽位选择界面（传奇风格：双槽位 + 动态职业立绘）
-- ============================================================================

-- 存储预览状态供 main.lua 查询
local previewClassIds_ = {}

-- 角色选择与存档页使用二维职业立绘，不再依赖三维模型预览。
-- 固定的暗色背景图，避免选择界面透出游戏场景的透视地图。
-- 资源位于 assets/image，运行时路径不带 assets/ 前缀。
local CHARACTER_SELECT_BACKGROUND = "image/tex_ground_dark_20260611064232.png"

local CLASS_PORTRAITS = {
    male = {
        warrior = "image/portrait_male_warrior_restrained_20260720115032.png",
        mage = "image/portrait_male_mage_refined_20260720120053.png",
        taoist = "image/portrait_male_taoist_restrained_20260720115037.png",
    },
    female = {
        warrior = "image/portrait_female_warrior_chinese_dark_20260720121212.png",
        mage = "image/portrait_female_mage_light_20260806063726.png",
        taoist = "image/portrait_female_taoist_refined_singlefan_20260720120323.png",
    },
}

local function GetClassPortrait(classId, gender)
    local genderSet = CLASS_PORTRAITS[gender or "male"] or CLASS_PORTRAITS.male
    return genderSet[classId] or CLASS_PORTRAITS.male.warrior
end
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
    local overlayMode = false
    if uiState.selectRoot then
        GameUI.HideClassSelect()
    end
    uiState.phase = "select"
    uiState.classSelectOverlayMode = false
    uiState.onClassSelected = nil
    uiState.onClassSelectCancelled = nil
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
    -- 上半：两个大角色立绘展示窗
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

        local portrait = data and GetClassPortrait(data.classId, data.gender) or nil
        local portraitPanel = portrait and UI.Panel {
            position = "absolute",
            top = 40,
            bottom = 8,
            left = 8,
            right = 8,
            backgroundImage = portrait,
            backgroundFit = "contain",
            pointerEvents = "none",
            opacity = isSelected and 1.0 or 0.72,
            transformOrigin = "bottom",
            boxShadow = isSelected and {
                { x = 0, y = 0, blur = 28, spread = 2, color = {180, 170, 135, 70} },
            } or nil,
        } or nil
        if portraitPanel and isSelected then
            portraitPanel:Animate({
                keyframes = {
                    [0] = { scale = 0.99, translateY = 2 },
                    [0.5] = { scale = 1.015, translateY = -3 },
                    [1] = { scale = 0.99, translateY = 2 },
                },
                duration = 3.2,
                easing = "easeInOut",
                loop = true,
            })
        end

        return UI.Button {
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
                portraitPanel,
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
            onClick = function()
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

    -- 构建完整界面：固定暗色图片覆盖底层 3D 场景，
    -- 上半部分只展示角色立绘，下半部分保持不透明信息卡。
    local saveSlotRoot = UI.Panel {
        id = "saveSlotScreen",
        width = "100%",
        height = "100%",
        -- 使用固定图片作为选择界面底图，不再让 3D 地图透出。
        backgroundImage = CHARACTER_SELECT_BACKGROUND,
        backgroundFit = "cover",
        backgroundImageOpacity = 0.72,
        backgroundColor = {8, 8, 10, 255},
        children = {
            -- === 上半部分：角色展示区（立绘叠加在固定暗色底图上）===
            UI.Panel {
                width = "100%",
                flexGrow = 5,
                flexDirection = "row",
                padding = 10,
                gap = 8,
                backgroundColor = {5, 5, 7, 72},
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

    uiState.saveSlotRoot = saveSlotRoot
    UI.SetRoot(saveSlotRoot)
    print("[GameUI] Save slot screen shown (selected=" .. selectedSlot .. ")")
end

-- ============================================================================
-- 角色选择界面 (暗黑地牢风格)
-- ============================================================================
---@param onSelected function
---@param overlayMode boolean|nil
---@param overlaySlotIndex integer|nil
---@param onCancelled function|nil
function GameUI.ShowClassSelect(onSelected, overlayMode, overlaySlotIndex, onCancelled)
    overlayMode = overlayMode == true
    overlaySlotIndex = overlaySlotIndex or 1
    uiState.phase = "select"
    uiState.onClassSelected = onSelected
    uiState.onClassSelectCancelled = onCancelled
    uiState.classSelectOverlayMode = overlayMode
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
    -- 职业立绘会按当前性别在运行时切换。
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

    local selectedGender = "male"
    local classPortraitRefs = {}

    -- 男 → 旧模型，女 → 新模型（不再提供独立的新旧模型选择）
    local function CurrentModelStyle()
        return selectedGender == "female" and "new" or "old"
    end

    local function UpdateClassPortraits()
        for classId, portrait in pairs(classPortraitRefs) do
            portrait:SetBackgroundImage(GetClassPortrait(classId, selectedGender))
        end
    end

    local function ChooseClass(classId)
        uiState.selectedClass = classId
        local onClassSelected = uiState.onClassSelected
        local modelStyle = CurrentModelStyle()
        local gender = selectedGender
        GameUI.HideClassSelect()
        if onClassSelected then
            onClassSelected(classId, modelStyle, gender)
        end
    end

    local cards = {}
    for _, classId in ipairs(classOrder) do
        local cls = CharacterClass.Classes[classId]
        local glow = classGlowColors[classId]
        local portrait = UI.Panel {
            backgroundImage = GetClassPortrait(classId, selectedGender),
            backgroundFit = "contain",
            width = overlayMode and 86 or 160,
            height = overlayMode and 126 or 250,
            transformOrigin = "bottom",
            pointerEvents = "none",
        }
        portrait:Animate({
            keyframes = {
                [0] = { scale = 0.99, translateY = 2 },
                [0.5] = { scale = 1.015, translateY = -3 },
                [1] = { scale = 0.99, translateY = 2 },
            },
            duration = 3.0 + (#cards * 0.18),
            easing = "easeInOut",
            loop = true,
        })
        classPortraitRefs[classId] = portrait

        table.insert(cards, UI.Panel {
            width = overlayMode and 104 or 185,
            paddingVertical = overlayMode and 10 or 22,
            paddingHorizontal = overlayMode and 6 or 14,
            alignItems = "center",
            backgroundColor = {18, 18, 19, 248},
            borderRadius = 8,
            borderWidth = 1.5,
            borderColor = {92, 94, 98, 215},
            boxShadow = {
                { x = 0, y = 10, blur = 24, spread = 0, color = {0, 0, 0, 110} },
                { x = 0, y = 0, blur = 18, spread = 0, color = {118, 122, 128, 34} },
            },
            onClick = function()
                ChooseClass(classId)
            end,
            children = {
                UI.Panel {
                    width = overlayMode and 88 or 162,
                    height = overlayMode and 128 or 252,
                    borderRadius = 6,
                    backgroundColor = {8, 8, 9, 180},
                    borderWidth = 1,
                    borderColor = {glow[1], glow[2], glow[3], 120},
                    justifyContent = "flex-end",
                    alignItems = "center",
                    overflow = "hidden",
                    children = {
                        portrait,
                    },
                },
                UI.Label {
                    text = cls.name,
                    fontSize = overlayMode and 16 or 22,
                    fontColor = {224, 226, 224, 255},
                    marginTop = overlayMode and 8 or 14,
                },
                (not overlayMode) and UI.Label {
                    text = classDescLines[classId],
                    fontSize = 11,
                    fontColor = {152, 154, 150, 198},
                    marginTop = 6,
                    textAlign = "center",
                } or nil,
                UI.Panel {
                    width = "80%",
                    height = 1,
                    backgroundColor = {74, 76, 78, 110},
                    marginTop = overlayMode and 7 or 12,
                    marginBottom = overlayMode and 5 or 8,
                },
                UI.Label {
                    text = "生命 " .. cls.baseHP,
                    fontSize = 11,
                    fontColor = {180, 80, 65, 200},
                },
                UI.Label {
                    text = "攻击 " .. cls.baseATK .. "  防御 " .. cls.baseDEF,
                    fontSize = overlayMode and 10 or 11,
                    fontColor = {140, 130, 115, 160},
                    marginTop = overlayMode and 1 or 3,
                },
                UI.Button {
                    text = overlayMode and "创建角色" or "进入暗夜",
                    marginTop = overlayMode and 8 or 16,
                    width = overlayMode and 92 or 130,
                    height = overlayMode and 30 or 40,
                    backgroundColor = {48, 49, 50, 244},
                    borderRadius = 4,
                    borderWidth = 1,
                    borderColor = {104, 106, 110, 205},
                    fontSize = 14,
                    fontColor = {222, 224, 222, 255},
                    onClick = function()
                        ChooseClass(classId)
                    end,
                },
            },
        })
    end

    uiState.selectRoot = UI.Panel {
        id = "classSelect",
        width = overlayMode and "50%" or "100%",
        height = overlayMode and "58%" or "100%",
        position = overlayMode and "absolute" or nil,
        top = overlayMode and 0 or nil,
        left = overlayMode and ((overlaySlotIndex == 2) and "50%" or 0) or nil,
        -- 存档页中的职业选择直接叠在同一张固定底图上；
        -- 独立打开时也使用该图片，不暴露游戏场景。
        backgroundImage = not overlayMode and CHARACTER_SELECT_BACKGROUND or nil,
        backgroundFit = "cover",
        backgroundImageOpacity = not overlayMode and 0.72 or nil,
        backgroundColor = overlayMode and {4, 4, 7, 205} or {10, 8, 6, 255},
        justifyContent = "center",
        alignItems = "center",
        children = {
            overlayMode and UI.Button {
                text = "← 返回",
                position = "absolute",
                left = 8, top = 8,
                width = 76, height = 32,
                variant = "outline",
                fontSize = 12,
                onClick = function()
                    GameUI.CancelClassSelect()
                end,
            } or nil,
            UI.Label {
                text = "暗夜传奇",
                fontSize = overlayMode and 18 or 36,
                fontColor = {220, 221, 219, 255},
                marginBottom = 4,
            },
            UI.Label {
                text = "选择你的命运",
                fontSize = 13,
                fontColor = {138, 140, 138, 180},
                marginBottom = overlayMode and 8 or 30,
            },
            UI.Panel {
                flexDirection = "row",
                gap = overlayMode and 5 or 18,
                children = cards,
            },
            UI.Panel {
                flexDirection = "row",
                gap = 10,
                marginTop = overlayMode and 8 or 20,
                alignItems = "center",
                children = {
                    UI.Label { text = "性别", fontSize = 12, fontColor = {180, 182, 180, 230} },
                    UI.Dropdown {
                        options = {
                            { value = "male", label = "男" },
                            { value = "female", label = "女" },
                        },
                        value = "male",
                        onChange = function(self, value)
                            selectedGender = value
                            UpdateClassPortraits()
                        end,
                    },
                },
            },
        },
    }

    if overlayMode and uiState.saveSlotRoot then
        uiState.saveSlotRoot:AddChild(uiState.selectRoot)
    else
        UI.SetRoot(uiState.selectRoot)
    end
    print("[GameUI] Class select screen shown (dungeon style)")
end

function GameUI.HideClassSelect()
    if uiState.selectRoot then
        uiState.selectRoot:Remove()
        uiState.selectRoot = nil
    end
    uiState.classSelectOverlayMode = false
    uiState.onClassSelected = nil
    uiState.onClassSelectCancelled = nil
end

--- 取消存档页上的职业选择，保留存档槽位页面。
---@return boolean cancelled
function GameUI.CancelClassSelect()
    if not uiState.selectRoot or not uiState.classSelectOverlayMode then
        return false
    end
    local onCancelled = uiState.onClassSelectCancelled
    GameUI.HideClassSelect()
    if onCancelled then onCancelled() end
    return true
end

-- ============================================================================
-- 游戏 HUD（去掉左上角 playerInfo，改由 NanoVG 绘制）
-- ============================================================================
function GameUI.ShowGameHUD(player)
    GameUI.HideDeathPresentation()
    uiState.phase = "playing"
    uiState.player = player
    uiState.charPanelOpen = false
    uiState.systemPanelOpen = false
    -- HUD 重建会替换小地图/全图的 widget 实例；旧位置缓存不能复用。
    uiState.miniMapVisuals = {}
    uiState.fullMapVisuals = {}

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
    -- 全屏地图（纯 UI 实现 - 当前区域俯瞰图）
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
        transformOrigin = "bottom",
    }

    -- 安全区与 NPC 标记。尺寸/位置在 _UpdateFullMapUI 中按世界坐标换算。
    local fullMapSafeZone = UI.Panel {
        position = "absolute",
        backgroundColor = {45, 125, 220, 48},
        borderWidth = 1,
        borderColor = {90, 185, 255, 210},
        pointerEvents = "none",
    }
    local fullMapStewardDot = UI.Panel {
        position = "absolute", width = 8, height = 8,
        borderRadius = 4,
        backgroundColor = {225, 188, 72, 255},
        borderWidth = 1, borderColor = {255, 240, 180, 230},
        pointerEvents = "none",
    }
    local fullMapMerchantDot = UI.Panel {
        position = "absolute", width = 8, height = 8,
        borderRadius = 4,
        backgroundColor = {70, 145, 235, 255},
        borderWidth = 1, borderColor = {185, 220, 255, 230},
        pointerEvents = "none",
    }
    local fullMapBlacksmithDot = UI.Panel {
        position = "absolute", width = 8, height = 8,
        borderRadius = 4,
        backgroundColor = {238, 104, 42, 255},
        borderWidth = 1, borderColor = {255, 205, 155, 230},
        pointerEvents = "none",
    }

    -- 每张地图目前有三个策划地标；复用固定 widget，切图时只更新文字与坐标，
    -- 避免像旧 HUD 一样在每帧重建控件。
    local fullMapLandmarks = {}
    for i = 1, 3 do
        local label = UI.Label {
            position = "absolute",
            left = 12, top = 0,
            text = "",
            fontSize = 10,
            fontColor = {235, 218, 164, 235},
            pointerEvents = "none",
        }
        local root = UI.Panel {
            position = "absolute",
            width = 100, height = 18,
            pointerEvents = "none",
            children = {
                UI.Panel {
                    position = "absolute", left = 0, top = 5,
                    width = 8, height = 8,
                    backgroundColor = {225, 166, 68, 245},
                    borderWidth = 1,
                    borderColor = {255, 232, 176, 230},
                    pointerEvents = "none",
                },
                label,
            },
        }
        table.insert(fullMapLandmarks, { root = root, label = label })
    end

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
    local fmChildren = { fullMapSafeZone }
    for _, g in ipairs(fmGridLines) do table.insert(fmChildren, g) end
    for _, c in ipairs(fmCoordLabels) do table.insert(fmChildren, c) end
    for _, landmark in ipairs(fullMapLandmarks) do table.insert(fmChildren, landmark.root) end
    table.insert(fmChildren, fullMapStewardDot)
    table.insert(fmChildren, fullMapMerchantDot)
    table.insert(fmChildren, fullMapBlacksmithDot)
    table.insert(fmChildren, fullMapPlayerDir)
    table.insert(fmChildren, fullMapPlayerDot)

    -- 全图地图区域（居中正方形，颜色由当前地图配置更新）
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
        text = "大陆地图 (" .. MapZone.ARENA_SIZE .. "m × " .. MapZone.ARENA_SIZE .. "m)",
        fontSize = 15,
        fontColor = {218, 220, 218, 240},
        fontWeight = "bold",
        marginBottom = 6,
    }

    -- 图例
    local fullMapLegend = UI.Panel {
        flexDirection = "row",
        flexWrap = "wrap",
        justifyContent = "center",
        rowGap = 4,
        gap = 14,
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
                    UI.Panel { width = 12, height = 12, backgroundColor = {45, 125, 220, 70}, borderWidth = 1, borderColor = {90, 185, 255, 220} },
                    UI.Label { text = "安全区 / NPC", fontSize = 11, fontColor = {200, 200, 190, 220} },
                },
            },
            UI.Panel {
                flexDirection = "row", alignItems = "center", gap = 4,
                children = {
                    UI.Panel { width = 9, height = 9, backgroundColor = {225, 166, 68, 245}, borderWidth = 1, borderColor = {255, 232, 176, 230} },
                    UI.Label { text = "地标", fontSize = 11, fontColor = {200, 200, 190, 220} },
                },
            },
            UI.Panel {
                flexDirection = "row", alignItems = "center", gap = 4,
                children = {
                    UI.Panel { width = 9, height = 9, backgroundColor = {238, 104, 42, 255}, borderWidth = 1, borderColor = {255, 205, 155, 230} },
                    UI.Label { text = "铁匠", fontSize = 11, fontColor = {200, 200, 190, 220} },
                },
            },
        },
    }

    -- 关闭提示
    local fullMapHint = UI.Label {
        text = "点击空白处关闭 | M / ESC 返回",
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
        onClick = function()
            GameUI._CloseFullMap()
        end,
        children = {
            UI.Button {
                text = "← 返回",
                position = "absolute",
                left = 16, top = 16,
                width = 86, height = 36,
                variant = "outline",
                fontSize = 13,
                onClick = function()
                    GameUI._CloseFullMap()
                end,
            },
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
    uiState.refs.fullMapSafeZone = fullMapSafeZone
    uiState.refs.fullMapStewardDot = fullMapStewardDot
    uiState.refs.fullMapMerchantDot = fullMapMerchantDot
    uiState.refs.fullMapBlacksmithDot = fullMapBlacksmithDot
    uiState.refs.fullMapLandmarks = fullMapLandmarks
    uiState.refs.fullMapTitle = fullMapTitle
    uiState.refs.fullMapGridLines = fmGridLines
    uiState.refs.fullMapCoordLabels = fmCoordLabels

    local hudRoot = UI.Panel {
        id = "gameHUD",
        width = "100%",
        height = "100%",
        pointerEvents = "box-none",
        children = {
            GameUI._CreateQuestTracker(),
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
-- 主线任务追踪条（HUD 左上角）
-- ============================================================================
function GameUI._CreateQuestTracker()
    uiState.refs.questTrackerRoot = UI.Panel {
        id = "questTracker",
        position = "absolute",
        top = 10, left = 10,
        width = 240,
        pointerEvents = "none",
        backgroundColor = {0, 0, 0, 0},
    }
    return uiState.refs.questTrackerRoot
end

--- 刷新任务追踪条（由 main.lua 在 Quest.onProgressUpdate / 完成时调用）
---@param quest table|nil 当前任务
---@param progress number 当前进度
---@param count number 目标数
function GameUI.UpdateQuestTracker(quest, progress, count)
    local root = uiState.refs.questTrackerRoot
    if not root then return end

    -- 清除旧子元素
    if uiState.refs.questTrackerInner then
        uiState.refs.questTrackerInner:Remove()
        uiState.refs.questTrackerInner = nil
    end

    local content
    if not quest then
        -- 主线已完成
        content = UI.Panel {
            flexDirection = "column",
            backgroundColor = {16, 14, 12, 215},
            borderRadius = 8,
            borderWidth = 1,
            borderColor = {140, 130, 90, 150},
            padding = 10,
            children = {
                UI.Label { text = "主线 · 已完结", fontSize = 13, fontColor = {255, 210, 90, 255}, fontWeight = "bold" },
                UI.Label { text = "你已是玛法大陆的传说", fontSize = 11, fontColor = {200, 195, 180, 200}, marginTop = 3 },
            },
        }
    else
        local done = progress >= count
        -- 使用任务的唯一地图路由，不能按章节硬编码：终章前段仍在沃玛寺庙。
        local targetMapId = Quest.GetTargetMapId(quest)
        local targetMap = targetMapId and MapZone.GetDef(targetMapId) or nil
        local mapName = targetMap and targetMap.name or ""
        local offTargetMap = targetMapId and MapZone.GetCurrentMapId() ~= targetMapId
        local objectiveText = Quest.GetObjectiveText(quest, progress, count)
        content = UI.Panel {
            flexDirection = "column",
            backgroundColor = {16, 14, 12, 215},
            borderRadius = 8,
            borderWidth = 1,
            borderColor = done and {140, 130, 90, 180} or {100, 90, 70, 150},
            padding = 10,
            children = {
                UI.Label {
                    text = quest.chapter or "主线",
                    fontSize = 10,
                    fontColor = {190, 180, 155, 190},
                },
                UI.Label {
                    text = quest.name,
                    fontSize = 14,
                    fontColor = {238, 232, 220, 255},
                    fontWeight = "bold",
                    marginTop = 2,
                },
                UI.Label {
                    text = done and "✓ 已完成" or ("目标：" .. objectiveText),
                    fontSize = 11,
                    fontColor = done and {140, 220, 140, 255} or {210, 200, 180, 230},
                    marginTop = 3,
                },
                (mapName ~= "") and UI.Label {
                    text = "📍 " .. mapName .. (offTargetMap and " · 返回后继续" or ""),
                    fontSize = 10,
                    fontColor = offTargetMap and {255, 190, 105, 225} or {140, 190, 220, 200},
                    marginTop = 2,
                } or nil,
            },
        }
    end

    uiState.refs.questTrackerInner = content
    root:AddChild(content)
end

-- ============================================================================
-- 右上角按钮（由 _CreateTopRightArea 统一管理，不再单独创建）
-- ============================================================================
function GameUI._CreateTopButtons()
    -- 已合并到 _CreateTopRightArea，返回空容器
    return UI.Panel { width = 0, height = 0 }
end

-- ============================================================================
-- 传送面板（地图选择）
-- ============================================================================

--- 打开传送面板（列出当前地图之外的可选目的地）
---@param maps table[]|nil {id, name, minLevel, maxLevel, cost, locked, current}
function GameUI.ShowTeleportPanel(maps)
    if uiState.teleportPanelOpen then return end
    SoundManager.Play("open_panel")
    uiState.teleportPanelOpen = true
    _SyncPauseState()

    local rows = {}
    local safeMaps = type(maps) == "table" and maps or {}
    for _, m in ipairs(safeMaps) do
        -- 显式捕获本轮数据，避免点击回调依赖循环变量后续变化。
        local option = m
        local isCurrent = option.current == true
        local locked = option.locked == true
        local questTarget = option.questTarget == true
        local minLevel = math.max(1, math.floor(tonumber(option.minLevel) or 1))
        local maxLevel = math.max(minLevel, math.floor(tonumber(option.maxLevel) or minLevel))
        local cost = math.max(0, math.floor(tonumber(option.cost) or 0))
        local costText = questTarget and "主线免费" or (cost > 0 and (tostring(cost) .. " 金币") or "免费")

        local function handleClick()
            if isCurrent then
                GameUI.ShowToast("你已经在当前地图")
                return
            end
            if locked then
                GameUI.ShowToast("等级不足，需要 Lv." .. minLevel, 1.5)
                return
            end

            -- 宿主返回 false 时代表校验未通过（如金币不足），面板保持打开，
            -- 玩家仍可查看其他路线或主动返回。
            local shouldClose = true
            if GameUI.onTeleportSelected then
                shouldClose = GameUI.onTeleportSelected(option.id, option) ~= false
            end
            if shouldClose then
                GameUI.HideTeleportPanel()
            end
        end

        table.insert(rows, UI.Panel {
            flexDirection = "row", alignItems = "center", justifyContent = "space-between",
            width = "100%",
            minHeight = 62,
            flexShrink = 0,
            paddingHorizontal = 12, paddingVertical = 9,
            backgroundColor = isCurrent and {40, 50, 40, 210}
                or locked and {28, 25, 24, 190}
                or {24, 22, 18, 200},
            borderRadius = 6,
            borderWidth = 1,
            borderColor = isCurrent and {140, 200, 140, 170}
                or locked and {70, 66, 56, 100}
                or {128, 112, 76, 145},
            onClick = handleClick,
            children = {
                UI.Panel {
                    flexGrow = 1,
                    flexShrink = 1,
                    alignItems = "flex-start",
                    children = {
                        UI.Label {
                            text = tostring(option.name or option.id or "未知地图")
                                .. (isCurrent and "（当前）" or questTarget and "（主线）" or ""),
                            fontSize = 14,
                            fontColor = isCurrent and {180, 230, 180, 255}
                                or locked and {138, 134, 128, 190}
                                or {230, 224, 204, 250},
                            fontWeight = isCurrent and "bold" or "normal",
                        },
                        UI.Label {
                            text = questTarget and "当前任务目标地图"
                                or locked and ("需要 Lv." .. minLevel)
                                or ("推荐 Lv." .. minLevel .. "-" .. maxLevel),
                            fontSize = 11,
                            fontColor = locked and {150, 128, 118, 190}
                                or {166, 160, 142, 205},
                            marginTop = 3,
                        },
                    },
                },
                UI.Panel {
                    flexShrink = 0,
                    alignItems = "flex-end",
                    marginLeft = 10,
                    children = {
                        UI.Label {
                            text = costText,
                            fontSize = 12,
                            fontColor = locked and {132, 126, 118, 175}
                                or {255, 210, 120, 235},
                            fontWeight = "bold",
                        },
                        UI.Label {
                            text = locked and "未解锁" or isCurrent and "当前位置" or "点击传送",
                            fontSize = 10,
                            fontColor = locked and {170, 105, 90, 205}
                                or isCurrent and {150, 205, 150, 215}
                                or {164, 174, 156, 205},
                            marginTop = 3,
                        },
                    },
                },
            },
        })
    end

    if #rows == 0 then
        table.insert(rows, UI.Panel {
            width = "100%",
            minHeight = 110,
            flexShrink = 0,
            justifyContent = "center",
            alignItems = "center",
            padding = 16,
            backgroundColor = {24, 22, 18, 190},
            borderRadius = 6,
            borderWidth = 1,
            borderColor = {70, 66, 56, 110},
            children = {
                UI.Label {
                    text = "暂无可用传送路线",
                    fontSize = 15,
                    fontColor = {220, 214, 198, 235},
                    fontWeight = "bold",
                },
                UI.Label {
                    text = "请返回游戏后重新靠近管家再试",
                    fontSize = 11,
                    fontColor = {156, 150, 138, 190},
                    marginTop = 6,
                },
            },
        })
    end

    uiState.teleportPanelRoot = UI.Panel {
        id = "teleportPanelOverlay",
        width = "100%", height = "100%",
        backgroundColor = {0, 0, 0, 170},
        justifyContent = "center", alignItems = "center",
        onClick = function() GameUI.HideTeleportPanel() end,
        children = {
            UI.Panel {
                width = "88%", maxWidth = 360,
                height = "86%", maxHeight = 500,
                backgroundColor = {16, 12, 10, 248},
                borderRadius = 10, borderWidth = 2,
                borderColor = {124, 126, 130, 198},
                padding = 16, alignItems = "center",
                overflow = "hidden",
                onClick = function() end,
                children = {
                    _CreateOverlayHeader("管家 · 传送", function()
                        GameUI.HideTeleportPanel()
                    end),
                    UI.Label {
                        text = "达到目的地等级后可传送，费用按当前地图收取",
                        fontSize = 10,
                        fontColor = {150, 150, 145, 180},
                        marginBottom = 12,
                    },
                    UI.ScrollView {
                        width = "100%",
                        flexGrow = 1,
                        flexBasis = 0,
                        showScrollbar = true,
                        children = {
                            UI.Panel {
                                width = "100%",
                                gap = 6,
                                children = rows,
                            },
                        },
                    },
                },
            },
        },
    }

    UI.SetRoot(uiState.teleportPanelRoot)
    print("[GameUI] Teleport panel opened")
end

function GameUI.HideTeleportPanel()
    if not uiState.teleportPanelOpen then return end
    SoundManager.Play("close_panel")
    uiState.teleportPanelOpen = false
    _SyncPauseState()
    uiState.teleportPanelRoot = nil
    if uiState.hudRoot then
        UI.SetRoot(uiState.hudRoot)
    end
    GameUI._ResetJoystickState()
    print("[GameUI] Teleport panel closed")
end

function GameUI.IsTeleportPanelOpen()
    return uiState.teleportPanelOpen
end

-- ============================================================================
-- NPC 交互面板（管家传送 / 商人商店 / 铁匠锻造）
-- ============================================================================

--- 显示/隐藏 HUD 上的 NPC 交互按钮（去重：状态不变时不重建，避免每帧销毁导致点击失效）
---@param show boolean
---@param label string|nil 按钮文案
---@param onTap function|nil 点击回调
function GameUI.SetNPCInteract(show, label, onTap)
    -- 状态缓存：避免每帧 Remove+AddChild 导致按钮无法被点击
    if uiState.npcInteractKey == show and not show then
        return  -- 连续隐藏，无需重复清理
    end
    if uiState.npcInteractKey == show and show and uiState.npcInteractLabel == label then
        return  -- 同状态同文案，保持现有按钮
    end

    -- 清理旧按钮
    if uiState.npcInteractBtn then
        uiState.npcInteractBtn:Remove()
        uiState.npcInteractBtn = nil
    end

    uiState.npcInteractKey = show
    uiState.npcInteractLabel = label

    if not show or not uiState.hudRoot then return end

    uiState.npcInteractBtn = UI.Panel {
        position = "absolute",
        left = 0, right = 0, bottom = "42%",
        alignItems = "center",
        pointerEvents = "box-none",
        children = {
            UI.Button {
                text = label or "交谈",
                fontSize = 14, fontWeight = "bold",
                -- 不再用固定宽度裁切文案；保留统一最小宽度，短文案在手机上
                -- 有足够留白，后续新增服务名称变长时也会自动扩展。
                minWidth = 148, height = 44,
                paddingHorizontal = 14,
                backgroundColor = {34, 30, 20, 240},
                borderRadius = 8, borderWidth = 1.5,
                borderColor = {170, 140, 70, 220},
                fontColor = {240, 230, 190, 255},
                onClick = function()
                    if onTap then onTap() end
                end,
            },
        },
    }
    uiState.hudRoot:AddChild(uiState.npcInteractBtn)
end

--- 打开 NPC 面板（管家传送 / 商人商店）
--- 支持多标签页：tabs = { {label=..., build=function() return rows end}, ... }
---@param title string 标题
---@param tabs table[] 标签页列表（每项含 label 和 build 函数返回 rows）
function GameUI.ShowNPCPanel(title, tabs, selectedTab)
    GameUI.HideNPCPanel()
    if type(tabs) ~= "table" or #tabs == 0 then
        GameUI.ShowToast("暂无可用服务")
        return
    end
    uiState.npcPanelOpen = true
    _SyncPauseState()

    local requestedTab = math.floor(tonumber(selectedTab) or 1)
    local activeTab = math.max(1, math.min(#tabs, requestedTab))

    -- 构建行列表
    local function buildRows(rows)
        local rowChildren = {}
        for _, r in ipairs(rows) do
            table.insert(rowChildren, UI.Button {
                text = "",
                width = "100%",
                minHeight = 52,
                flexShrink = 0,
                paddingHorizontal = 12, paddingVertical = 10,
                backgroundColor = {24, 22, 18, 220},
                borderRadius = 6, borderWidth = 1,
                borderColor = {70, 66, 56, 130},
                alignItems = "flex-start",
                onClick = r.onTap,
                children = {
                    -- Rows may provide a contextual title color (for example an
                    -- equipment rarity). Keep the neutral shop/service color as
                    -- the fallback so existing NPC rows remain unchanged.
                    UI.Label {
                        text = r.text,
                        fontSize = 14,
                        fontColor = r.fontColor or {230, 226, 210, 255},
                        textAlign = "left",
                    },
                    UI.Label { text = r.hint or "", fontSize = 11, fontColor = {255, 210, 120, 215}, marginTop = 2, textAlign = "left" },
                },
            })
        end
        return rowChildren
    end

    local contentRef = {}

    -- 构建整个面板（供 tab 切换时重建）
    local function buildPanel()
        local tabChildren = {}
        if #tabs > 1 then
            for i, t in ipairs(tabs) do
                local isActive = (i == activeTab)
                table.insert(tabChildren, UI.Panel {
                    flex = 1, height = 34, borderRadius = 6,
                    backgroundColor = isActive and {62, 64, 68, 245} or {30, 31, 33, 195},
                    borderWidth = isActive and 1.5 or 0,
                    borderColor = {126, 130, 134, 180},
                    justifyContent = "center", alignItems = "center",
                    onClick = function()
                        if activeTab ~= i then
                            activeTab = i
                            GameUI.HideNPCPanel()
                            GameUI.ShowNPCPanel(title, tabs, activeTab)
                        end
                    end,
                    children = {
                        UI.Label { text = t.label, fontSize = 13, fontColor = isActive and {236, 238, 236, 255} or {176, 178, 180, 200}, fontWeight = isActive and "bold" or "normal" },
                    },
                })
            end
        end

        local rows = tabs[activeTab].build()
        if type(rows) ~= "table" then rows = {} end
        local rowChildren = buildRows(rows)

        if #rowChildren == 0 then
            table.insert(rowChildren, UI.Panel {
                width = "100%",
                minHeight = 96,
                justifyContent = "center",
                alignItems = "center",
                children = {
                    UI.Label {
                        text = "暂无可用项目",
                        fontSize = 14,
                        fontColor = {176, 170, 158, 220},
                    },
                },
            })
        end

        -- children 必须是连续数组。单标签面板若在标题和列表之间直接放 nil，
        -- UI 库使用 ipairs 挂载时会在 nil 处提前结束，后面的 ScrollView 因而
        -- 完全不会进入界面（管家传送列表为空的根因）。
        local panelChildren = {
            _CreateOverlayHeader(title, function()
                GameUI.HideNPCPanel()
            end),
        }
        if #tabs > 1 then
            table.insert(panelChildren, UI.Panel {
                flexDirection = "row", width = "100%", gap = 6,
                marginBottom = 10, flexShrink = 0,
                children = tabChildren,
            })
        end
        table.insert(panelChildren, ServiceScrollView.Build {
            width = "100%",
            flexGrow = 1,
            flexBasis = 0,
            showScrollbar = true,
            children = {
                UI.Panel {
                    width = "100%",
                    gap = 8,
                    children = rowChildren,
                },
            },
        })

        uiState.npcPanelRoot = UI.Panel {
            id = "npcPanelOverlay",
            width = "100%", height = "100%",
            backgroundColor = {0, 0, 0, 170},
            justifyContent = "center", alignItems = "center",
            onClick = function() GameUI.HideNPCPanel() end,
            children = {
                UI.Panel {
                    width = "90%",
                    maxWidth = 500,
                    height = "84%",
                    maxHeight = 540,
                    backgroundColor = {16, 12, 10, 250},
                    borderRadius = 12, borderWidth = 2,
                    borderColor = {124, 126, 130, 200},
                    padding = 16, alignItems = "center",
                    overflow = "hidden",
                    onClick = function() end,
                    children = panelChildren,
                },
            },
        }
    UI.SetRoot(uiState.npcPanelRoot)
    _RefreshMouseHoverAfterRootSwitch()
end

    buildPanel()
end

--- 打开铁匠服务台。锻造与强化都不放在角色面板中，玩家必须在安全区
--- 靠近铁匠后使用；刷新时保留当前 Tab 和强化选中的装备。
---@param player table
function GameUI.ShowBlacksmithPanel(player)
    if not player then
        GameUI.ShowToast("角色数据不可用，暂时无法使用铁匠服务")
        return
    end

    if uiState.blacksmithTab ~= "enhance" then
        uiState.blacksmithTab = "forge"
    end
    if uiState.blacksmithSelectedItem
        and not Inventory.IsOwnedItem(uiState.blacksmithSelectedItem) then
        uiState.blacksmithSelectedItem = nil
    end

    GameUI.HideNPCPanel()
    uiState.npcPanelOpen = true
    _SyncPauseState()

    local function refreshBlacksmithPanel()
        if not uiState.npcPanelOpen then return end
        GameUI.HideNPCPanel()
        GameUI.ShowBlacksmithPanel(player)
    end

    local blacksmithContent = BlacksmithPanel.Build {
        player = player,
        activeTab = uiState.blacksmithTab,
        selectedEnhanceItem = uiState.blacksmithSelectedItem,
        showToast = function(message) GameUI.ShowToast(message) end,
        onRefresh = refreshBlacksmithPanel,
        onGoldChanged = function(gold) GameUI.UpdateGold(gold) end,
        onTabChanged = function(tabId)
            uiState.blacksmithTab = tabId
        end,
        onEnhanceSelect = function(item)
            if not Inventory.IsOwnedItem(item) then
                GameUI.ShowToast("装备状态已变化，请重新选择")
                refreshBlacksmithPanel()
                return
            end
            uiState.blacksmithTab = "enhance"
            uiState.blacksmithSelectedItem = item
            refreshBlacksmithPanel()
        end,
        onEnhanceSelectionResolved = function(item)
            uiState.blacksmithSelectedItem = item
        end,
        applyDerivedStats = function()
            -- 强化穿戴中的装备后必须立即同步角色实际攻防与生命上限。
            CharacterClass.ApplyDerivedStats(player, Inventory.playerData, false)
        end,
    }

    uiState.npcPanelRoot = UI.Panel {
        id = "blacksmithPanelOverlay",
        width = "100%", height = "100%",
        backgroundColor = {0, 0, 0, 178},
        justifyContent = "center", alignItems = "center",
        onClick = function() GameUI.HideNPCPanel() end,
        children = {
            UI.Panel {
                width = "94%", maxWidth = 620,
                height = "92%", maxHeight = 650,
                backgroundColor = {16, 12, 9, 252},
                borderRadius = 12, borderWidth = 2,
                borderColor = {164, 105, 43, 220},
                padding = 15,
                overflow = "hidden",
                onClick = function() end,
                children = {
                    _CreateOverlayHeader("铁匠铺", function()
                        GameUI.HideNPCPanel()
                    end, {
                        subtitle = "五件合成更高品质 · 金币强化至 +12",
                        titleColor = {244, 210, 142, 255},
                        subtitleColor = {202, 154, 92, 220},
                        marginBottom = 6,
                    }),
                    UI.Panel {
                        width = "100%",
                        flexGrow = 1,
                        flexBasis = 0,
                        minHeight = 0,
                        overflow = "hidden",
                        children = { blacksmithContent },
                    },
                },
            },
        },
    }

    UI.SetRoot(uiState.npcPanelRoot)
    _RefreshMouseHoverAfterRootSwitch()
    print("[GameUI] Blacksmith panel opened, tab=" .. uiState.blacksmithTab)
end

--- 旧入口兼容：默认打开锻造页。
---@param player table
function GameUI.ShowForgePanel(player)
    uiState.blacksmithTab = "forge"
    GameUI.ShowBlacksmithPanel(player)
end

function GameUI.HideNPCPanel()
    if not uiState.npcPanelOpen then return end
    uiState.npcPanelOpen = false
    _SyncPauseState()
    uiState.npcPanelRoot = nil
    if uiState.hudRoot then
        UI.SetRoot(uiState.hudRoot)
    end
    GameUI._ResetJoystickState()
end

function GameUI.IsNPCPanelOpen()
    return uiState.npcPanelOpen
end

-- ============================================================================
-- 右下角 - 技能栏
-- ============================================================================
-- 技能栏图标映射（全局复用）
local _skillBarIcons = {
    w_basic = "image/icon_w_basic_20260617040401_round.png",
    w_thrust = "image/icon_w_thrust_20260617040358_round.png",
    w_crescent = "image/icon_w_crescent_20260617040403_round.png",
    w_earthsplit = "image/icon_w_earthsplit_20260827_round.png",
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
            onClick = function()
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
    -- 新 HUD 会创建新遮罩实例，清空旧实例的视觉缓存。
    uiState.potionCooldownVisuals = {}
    local hpCount = Inventory.GetPotionCount("hp")
    local mpCount = Inventory.GetPotionCount("mp")

    -- 正确的坐标转换：NanoVG 设计单位 → UI base pixels。
    -- raw NanoVG 以逻辑像素绘制（每个逻辑像素对应 dpr 个物理像素），
    -- UI 组件以 UI.GetScale() 放大到物理像素，因此需要补上 dpr。
    local _, _, dpr, _, logicalH = _GetScreenMetrics()
    local rawScale = logicalH / 720
    local uiSysScale = math.max(UI.GetScale(), 0.001)
    local toUI = rawScale * dpr / uiSysScale

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
            onClick = function()
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
    -- 当前地图在小地图中的区域：留圆边距后居中放一个正方形
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
        transformOrigin = "bottom",
    }

    local miniSafeZone = UI.Panel {
        position = "absolute",
        backgroundColor = {45, 125, 220, 55},
        borderWidth = 1,
        borderColor = {90, 185, 255, 190},
        pointerEvents = "none",
    }
    local miniStewardDot = UI.Panel {
        position = "absolute", width = 3, height = 3,
        borderRadius = 2,
        backgroundColor = {235, 195, 72, 255},
        pointerEvents = "none",
    }
    local miniMerchantDot = UI.Panel {
        position = "absolute", width = 3, height = 3,
        borderRadius = 2,
        backgroundColor = {75, 150, 240, 255},
        pointerEvents = "none",
    }
    local miniBlacksmithDot = UI.Panel {
        position = "absolute", width = 3, height = 3,
        borderRadius = 2,
        backgroundColor = {238, 104, 42, 255},
        pointerEvents = "none",
    }

    -- 当前 Boss 任务目标（红点）。位置由 _UpdateMiniMapUI 按 Boss 实体实时更新。
    -- 使用独立 widget，避免每帧重建小地图树；Boss 离场/任务切换时直接隐藏。
    local miniBossDot = UI.Panel {
        position = "absolute", width = 6, height = 6,
        borderRadius = 3,
        backgroundColor = {245, 48, 48, 255},
        borderWidth = 1,
        borderColor = {255, 220, 220, 255},
        pointerEvents = "none",
        visible = false,
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

    -- ── 地图区域（实心方块，包含玩家和网格，overflow裁剪）──
    local arenaBlock = UI.Panel {
        position = "absolute",
        left = arenaPad, top = arenaPad,
        width = arenaDrawSize, height = arenaDrawSize,
        backgroundColor = {30, 32, 34, 200},  -- 深灰填充
        borderWidth = 2,
        borderColor = {126, 130, 134, 245},  -- 银灰粗边框
        overflow = "hidden",  -- 裁剪超出边界的玩家标记
        children = { miniSafeZone, gridH, gridV, miniStewardDot, miniMerchantDot, miniBlacksmithDot, miniBossDot, playerDir, playerDot },
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
        onClick = function()
            GameUI._OpenFullMap()
        end,
        children = mapChildren,
    }

    -- 保存引用用于每帧更新
    uiState.refs.miniMapContainer = miniMap
    uiState.refs.miniMapPlayerDot = playerDot
    uiState.refs.miniMapPlayerDir = playerDir
    uiState.refs.miniMapSafeZone = miniSafeZone
    uiState.refs.miniMapStewardDot = miniStewardDot
    uiState.refs.miniMapMerchantDot = miniMerchantDot
    uiState.refs.miniMapBlacksmithDot = miniBlacksmithDot
    uiState.refs.miniMapBossDot = miniBossDot
    uiState.refs.miniMapArenaBlock = arenaBlock
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
            onClick = onTap,
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
-- 角色面板（技能 + 装备 + 背包；锻造由安全区铁匠负责）
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
    local skillIconFallbacks = {
        w_earthsplit = "裂",
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
        local iconFallback = skillIconFallbacks[skill.id] or skillIcons[skill.type] or "◆"
        local nameColor = locked and {92, 92, 92, 155} or {224, 226, 224, 255}
        local iconBg = locked and {30, 30, 31, 200} or equippedSlot > 0 and {54, 56, 60, 242} or {38, 39, 41, 232}
        local iconBorder = locked and {54, 54, 54, 135} or equippedSlot > 0 and {136, 140, 144, 210} or {92, 94, 98, 180}

        table.insert(skillRows, UI.Panel {
            width = "100%", flexDirection = "row", alignItems = "center",
            paddingVertical = 8, paddingHorizontal = 6, gap = 10,
            onClick = not locked and function()
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
                            width = "100%",
                            fontSize = 11,
                            lineHeight = 1.35,
                            whiteSpace = "normal",
                            wordBreak = "break-word",
                            fontColor = locked and {90, 90, 90, 125} or {174, 176, 176, 205},
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
        width = "100%",
        children = skillRows,
    }
end

-- ============================================================================
-- 装备面板 Tab（传奇风格：人物轮廓 + 10槽位环绕）
-- ============================================================================
function GameUI.HideItemDetail()
    local detailRoot = uiState.itemDetailRoot
    if not detailRoot then return end
    uiState.itemDetailRoot = nil
    detailRoot:Remove()
end

function GameUI.IsItemDetailOpen()
    return uiState.itemDetailRoot ~= nil
end

local function _BuildEquipmentPanelOptions(player, tab)
    return {
        player = player,
        showToast = function(message) GameUI.ShowToast(message) end,
        closeDetail = GameUI.HideItemDetail,
        openDetail = function(detailPanel)
            GameUI.HideItemDetail()
            if uiState.charPanelRoot then
                uiState.itemDetailRoot = detailPanel
                uiState.charPanelRoot:AddChild(detailPanel)
            end
        end,
        refresh = function()
            GameUI.HideCharacterPanel()
            GameUI.ShowCharacterPanel(player, tab)
        end,
    }
end

local function _BuildEquipTabContent(player)
    return EquipmentPanel.BuildEquipTab(
        _BuildEquipmentPanelOptions(player, "equip"))
end

--- 构建背包 Tab 内容
local function _BuildBagTabContent(player)
    return EquipmentPanel.BuildBagTab(
        _BuildEquipmentPanelOptions(player, "bag"))
end

--- 玩家主动关闭角色面板时走此入口；Tab 切换仍使用 HideCharacterPanel，
--- 避免每次重建内容都触发 HUD 技能栏刷新。
---@return boolean closed
function GameUI.CloseCharacterPanel()
    if not uiState.charPanelOpen then return false end
    GameUI.HideCharacterPanel()
    if GameUI.onCharacterPanelClosed then
        GameUI.onCharacterPanelClosed()
    end
    return true
end

function GameUI.ShowCharacterPanel(player, tab)
    -- 关闭系统面板（互斥）
    if uiState.systemPanelOpen then GameUI.HideSystemPanel() end
    if uiState.charPanelOpen then
        -- 已打开则先关再开（用于 Tab 切换）
        GameUI.HideCharacterPanel()
    end
    SoundManager.Play("open_panel")
    uiState.charPanelOpen = true
    _SyncPauseState()

    local activeTab = tab or "skill"
    if activeTab ~= "equip" and activeTab ~= "skill" and activeTab ~= "bag" then
        activeTab = "equip"
    end
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
            onClick = function()
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
        onClick = function() GameUI.CloseCharacterPanel() end,
        children = {
            UI.Panel {
                -- 项目为横屏。使用确定的百分比高度 + 上限，既能让
                -- ScrollView 正确分配空间，也避免 360~430 逻辑像素高的手机裁切。
                width = "92%", maxWidth = 430,
                height = "90%", maxHeight = 540,
                backgroundColor = {16, 12, 10, 248},
                borderRadius = 10, borderWidth = 2,
                borderColor = {124, 126, 130, 198},
                padding = 14, overflow = "hidden",
                onClick = function() end,
                children = {
                    -- 标题栏
                    _CreateOverlayHeader("角色 — " .. classDef.name, GameUI.CloseCharacterPanel, {
                        subtitle = "Lv." .. player.level,
                    }),
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
                    -- 内容区必须使用真正的 ScrollView；Panel 的 overflow="scroll"
                    -- 不是可滚动容器，之前小屏会直接裁掉装备格和背包操作。
                    UI.ScrollView {
                        width = "100%",
                        flexGrow = 1,
                        flexBasis = 0,
                        showScrollbar = true,
                        children = { content },
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
    SoundManager.Play("close_panel")
    GameUI.HideItemDetail()
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
    local hudRoot = uiState.hudRoot
    if not hudRoot then
        GameUI.ShowGameHUD(player)
        return
    end

    -- 只替换技能栏。过去重建整个 HUD 会清空任务追踪、NPC 交互按钮和摇杆状态。
    local oldSkillBar = hudRoot:FindById("skillBar")
    local insertIndex = 1
    if oldSkillBar then
        local childCount = hudRoot:GetNumChildren()
        for i = 1, childCount do
            if hudRoot:GetChildAt(i) == oldSkillBar then
                insertIndex = i
                break
            end
        end
        oldSkillBar:Remove()
    end

    local newSkillBar = GameUI._CreateSkillBar(player)
    hudRoot:InsertChild(newSkillBar, insertIndex)
    newSkillBar:SetVisible(uiState.hudRevealed and not mapState.fullMapOpen)
    uiState.player = player
    print("[GameUI] Skill buttons refreshed")
end

-- ============================================================================
-- 系统面板（退出 + DBG）
-- ============================================================================
function GameUI.ShowSystemPanel()
    -- 关闭角色面板（互斥）
    if uiState.charPanelOpen then GameUI.HideCharacterPanel() end
    if uiState.systemPanelOpen then return end
    SoundManager.Play("open_panel")
    uiState.systemPanelOpen = true
    _SyncPauseState()

    local systemContent = {
        UI.Panel {
            width = "100%", height = 1,
            backgroundColor = {72, 74, 76, 110},
        },
        -- 音效开关：控制全部音效与背景音乐
        (function()
            local sfxEnabled = SoundManager.IsSoundEnabled()
            local sfxButton = UI.Button {
                text = (sfxEnabled and "开启" or "关闭"),
                width = 72, height = 32,
                backgroundColor = (sfxEnabled and {60, 90, 60, 240} or {70, 58, 58, 240}),
                borderRadius = 6, borderWidth = 1,
                borderColor = (sfxEnabled and {90, 160, 90, 200} or {160, 80, 80, 180}),
                fontSize = 13,
                fontColor = (sfxEnabled and {180, 255, 180, 255} or {236, 200, 200, 255}),
                onClick = function()
                    local newEnabled = not SoundManager.IsSoundEnabled()
                    SoundManager.SetSoundEnabled(newEnabled)
                    SoundManager.Play("click")
                    sfxButton:SetText(newEnabled and "开启" or "关闭")
                    sfxButton:SetStyle {
                        backgroundColor = (newEnabled and {60, 90, 60, 240} or {70, 58, 58, 240}),
                        borderColor = (newEnabled and {90, 160, 90, 200} or {160, 80, 80, 180}),
                        fontColor = (newEnabled and {180, 255, 180, 255} or {236, 200, 200, 255}),
                    }
                end,
            }
            return UI.Panel {
                width = "100%",
                flexDirection = "row",
                alignItems = "center",
                justifyContent = "space-between",
                paddingLeft = 4, paddingRight = 4,
                children = {
                    UI.Label {
                        text = "音效",
                        fontSize = 14,
                        fontColor = {214, 216, 214, 240},
                    },
                    sfxButton,
                },
            }
        end)(),
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
    }

    if GameUI.debugMode then
        table.insert(systemContent, UI.Panel {
            width = "100%", height = 1,
            backgroundColor = {70, 72, 74, 90},
        })
        table.insert(systemContent, UI.Panel {
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
                            onClick = function()
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
                            onClick = function()
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
                UI.Panel {
                    width = 140, height = 36, borderRadius = 6,
                    backgroundColor = {66, 68, 72, 220},
                    justifyContent = "center", alignItems = "center",
                    marginTop = 4,
                    onClick = function()
                        if GameUI.onDebugMaxLevel then GameUI.onDebugMaxLevel() end
                        GameUI.HideSystemPanel()
                        GameUI.ShowSystemPanel()
                    end,
                    children = {
                        UI.Label { text = "一键满级", fontSize = 13, fontColor = {236, 238, 236, 255} },
                    },
                },
            },
        })
    end

    uiState.systemPanelRoot = UI.Panel {
        id = "systemPanelOverlay",
        width = "100%", height = "100%",
        backgroundColor = {0, 0, 0, 170},
        justifyContent = "center", alignItems = "center",
        onClick = function() GameUI.HideSystemPanel() end,
        children = {
            UI.Panel {
                width = "88%", maxWidth = 320,
                height = GameUI.debugMode and "86%" or "58%",
                maxHeight = GameUI.debugMode and 480 or 250,
                backgroundColor = {16, 12, 10, 248},
                borderRadius = 8, borderWidth = 2,
                borderColor = {124, 126, 130, 198},
                padding = 16,
                alignItems = "center",
                overflow = "hidden",
                onClick = function() end,
                children = {
                    _CreateOverlayHeader("系统", function()
                        GameUI.HideSystemPanel()
                    end),
                    UI.ScrollView {
                        width = "100%",
                        flexGrow = 1,
                        flexBasis = 0,
                        showScrollbar = GameUI.debugMode,
                        children = {
                            UI.Panel {
                                width = "100%",
                                alignItems = "center",
                                gap = 10,
                                children = systemContent,
                            },
                        },
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
    SoundManager.Play("close_panel")
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
            local overlayAlpha = 0
            local cooldownText = ""
            if cd > 0 then
                overlayAlpha = 140
                cooldownText = string.format("%.0f", math.ceil(cd))
            elseif not usable then
                overlayAlpha = 135
            end

            -- SetStyle 会标记全局 Yoga 布局为脏；只有视觉状态变化时才调用。
            if cdPanel and sb.lastCooldownOverlayAlpha ~= overlayAlpha then
                cdPanel:SetStyle({ backgroundColor = {0, 0, 0, overlayAlpha} })
                sb.lastCooldownOverlayAlpha = overlayAlpha
            end
            if cdText and sb.lastCooldownText ~= cooldownText then
                cdText:SetText(cooldownText)
                sb.lastCooldownText = cooldownText
            end
            if sb.lastUsable ~= usable then
                if sb.panel then
                    sb.panel:SetStyle({ backgroundColor = usable and {25, 22, 18, 210} or {18, 18, 18, 210} })
                end
                if sb.icon then
                    sb.icon:SetStyle({ opacity = usable and 1.0 or 0.35 })
                end
                sb.lastUsable = usable
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
    local visuals = uiState.potionCooldownVisuals or {}
    uiState.potionCooldownVisuals = visuals
    for _, kind in ipairs(kinds) do
        local overlay = uiState.refs["potion_" .. kind .. "_cd"]
        if overlay then
            local ratio = cd[kind] or 0
            local previous = visuals[kind]
            if ratio > 0.01 then
                if not previous or not previous.visible then
                    overlay:SetVisible(true)
                end
                -- 更新透明度随 CD 比例变化（CD 越满越暗）
                local alpha = math.floor(120 + 60 * ratio)
                if not previous or previous.alpha ~= alpha then
                    overlay:SetStyle({ backgroundColor = {0, 0, 0, alpha} })
                end
                visuals[kind] = { visible = true, alpha = alpha }
            else
                if not previous or previous.visible then
                    overlay:SetVisible(false)
                end
                visuals[kind] = { visible = false }
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
    local arenaBlock = uiState.refs.miniMapArenaBlock
    local safeZone = uiState.refs.miniMapSafeZone
    local stewardDot = uiState.refs.miniMapStewardDot
    local merchantDot = uiState.refs.miniMapMerchantDot
    local blacksmithDot = uiState.refs.miniMapBlacksmithDot
    local bossDot = uiState.refs.miniMapBossDot
    local arenaDrawSize = uiState.refs.miniMapArenaDrawSize
    if not arenaDrawSize then return end

    local halfArena = mapState.arenaSize / 2  -- 60m
    local playerPos = playerNodeRef.worldPosition
    local visuals = uiState.miniMapVisuals or {}
    uiState.miniMapVisuals = visuals

    local mapId = MapZone.GetCurrentMapId()
    local mapDef = MapZone.GetDef(mapId)
    local function worldToMini(x, z)
        return (x + halfArena) / (halfArena * 2) * arenaDrawSize,
            (halfArena - z) / (halfArena * 2) * arenaDrawSize
    end

    if mapDef and visuals.mapId ~= mapId then
        local mapColor = mapDef.mapColor or {30, 32, 34, 220}
        if arenaBlock then
            arenaBlock:SetStyle({ backgroundColor = {mapColor[1], mapColor[2], mapColor[3], 220} })
        end

        local spawn = mapDef.spawnPos or Vector3.ZERO
        local safeHalf = MapZone.GetSafeZoneRadius(mapId)
        local safePixels = math.max(5, math.floor((safeHalf * 2 / mapState.arenaSize) * arenaDrawSize))
        local safeX, safeY = worldToMini(spawn.x, spawn.z)
        if safeZone then
            safeZone:SetStyle({
                left = math.floor(safeX - safePixels / 2),
                top = math.floor(safeY - safePixels / 2),
                width = safePixels, height = safePixels,
            })
        end

        local stewardPos = NPC.GetWorldPosition("steward", spawn)
        local merchantPos = NPC.GetWorldPosition("merchant", spawn)
        local blacksmithPos = NPC.GetWorldPosition("blacksmith", spawn)
        local stewardX, stewardY = worldToMini(stewardPos.x, stewardPos.z)
        local merchantX, merchantY = worldToMini(merchantPos.x, merchantPos.z)
        local blacksmithX, blacksmithY = worldToMini(blacksmithPos.x, blacksmithPos.z)
        if stewardDot then stewardDot:SetStyle({ left = math.floor(stewardX - 1), top = math.floor(stewardY - 1) }) end
        if merchantDot then merchantDot:SetStyle({ left = math.floor(merchantX - 1), top = math.floor(merchantY - 1) }) end
        if blacksmithDot then blacksmithDot:SetStyle({ left = math.floor(blacksmithX - 1), top = math.floor(blacksmithY - 1) }) end
        visuals.mapId = mapId
    end

    -- 巡逻、坚守与显式遭遇共用一个目标点。遭遇生成后跟随实体实时位置，
    -- 其它模式显示 Quest 提供的纯坐标；切图后不缓存任何已销毁节点。
    if bossDot then
        local marker = Quest.GetObjectiveMarker()
        local objectivePos = marker and marker.mapId == mapId and marker or nil
        if objectivePos and marker.mode == "encounter" then
            local Combat = require("scripts.Combat")
            for _, enemy in ipairs(Combat.enemies or {}) do
                if enemy and enemy.encounterId == marker.questId
                    and enemy.node and enemy.state ~= "dead" and enemy.state ~= "dying"
                    and type(enemy.hp) == "number" and enemy.hp > 0 then
                    local enemyPos = enemy.node.worldPosition or enemy.node.position
                    objectivePos = { x = enemyPos.x, z = enemyPos.z }
                    break
                end
            end
        end

        if objectivePos then
            local markerX, markerY = worldToMini(objectivePos.x, objectivePos.z)
            local markerLeft = math.floor(markerX - 3)
            local markerTop = math.floor(markerY - 3)
            if not visuals.bossVisible then
                bossDot:SetVisible(true)
            end
            if marker and visuals.objectiveMode ~= marker.mode then
                local markerColor = marker.mode == "encounter" and {245, 48, 48, 255}
                    or marker.mode == "survive" and {245, 150, 55, 255}
                    or {255, 220, 70, 255}
                bossDot:SetStyle({ backgroundColor = markerColor })
                visuals.objectiveMode = marker.mode
            end
            if visuals.bossLeft ~= markerLeft or visuals.bossTop ~= markerTop then
                bossDot:SetStyle({ left = markerLeft, top = markerTop })
                visuals.bossLeft, visuals.bossTop = markerLeft, markerTop
            end
            visuals.bossVisible = true
        else
            if visuals.bossVisible ~= false then
                bossDot:SetVisible(false)
            end
            visuals.bossVisible = false
            visuals.objectiveMode = nil
        end
    end

    -- 玩家世界坐标 → arenaBlock 内部像素坐标（相对于 arenaBlock content area）
    -- 世界 (-60, +60) → 像素 (0, 0)  左上角=西北
    -- 世界 (+60, -60) → 像素 (arenaDrawSize, arenaDrawSize)  右下角=东南
    local normX = (playerPos.x + halfArena) / (halfArena * 2)  -- 0~1
    local normZ = (halfArena - playerPos.z) / (halfArena * 2)  -- 0~1
    -- 不 clamp，让 overflow:hidden 自动裁剪

    local dotX = normX * arenaDrawSize
    local dotY = normZ * arenaDrawSize

    -- 更新玩家标记位置（相对于 arenaBlock 内部）
    local dotLeft = math.floor(dotX - 4)
    local dotTop = math.floor(dotY - 4)
    if playerDot and (visuals.dotLeft ~= dotLeft or visuals.dotTop ~= dotTop) then
        playerDot:SetStyle({ left = dotLeft, top = dotTop })
        visuals.dotLeft, visuals.dotTop = dotLeft, dotTop
    end

    -- 更新朝向指示线。线段底端固定在玩家中心，rotate 直接使用角色 yaw；
    -- 旧实现读取固定相机 yaw 且只移动竖线位置，视觉上从未真正旋转。
    if playerDir then
        local yaw = playerNodeRef.worldRotation:YawAngle()
        local dirLeft = math.floor(dotX - 1)
        local dirTop = math.floor(dotY - 8)
        local dirYaw = math.floor(yaw * 10 + 0.5) / 10
        if visuals.dirLeft ~= dirLeft or visuals.dirTop ~= dirTop or visuals.dirYaw ~= dirYaw then
            playerDir:SetStyle({ left = dirLeft, top = dirTop, rotate = dirYaw, transformOrigin = "bottom" })
            visuals.dirLeft, visuals.dirTop, visuals.dirYaw = dirLeft, dirTop, dirYaw
        end
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
    local safeZone = uiState.refs.fullMapSafeZone
    local stewardDot = uiState.refs.fullMapStewardDot
    local merchantDot = uiState.refs.fullMapMerchantDot
    local blacksmithDot = uiState.refs.fullMapBlacksmithDot
    local landmarkRefs = uiState.refs.fullMapLandmarks
    local title = uiState.refs.fullMapTitle
    local gridLines = uiState.refs.fullMapGridLines
    local coordLabels = uiState.refs.fullMapCoordLabels
    if not fullMapArea or not playerDot then return end

    -- 使用 UI base viewport 的 55% 作为地图正方形尺寸。
    -- 读取物理分辨率时使用引擎方法，避免高 DPI 下访问旧字段造成模式混用。
    local physW, physH = graphics:GetWidth(), graphics:GetHeight()
    local uiScale = math.max(UI.GetScale(), 0.001)
    local sw = physW / uiScale
    local sh = physH / uiScale
    local mapSize = math.floor(math.min(sw, sh) * 0.55)
    local halfArena = mapState.arenaSize / 2  -- 60m

    local visuals = uiState.fullMapVisuals or {}
    uiState.fullMapVisuals = visuals
    local mapId = MapZone.GetCurrentMapId()
    local mapDef = MapZone.GetDef(mapId)
    local mapChanged = visuals.mapId ~= mapId

    -- 设置地图区域尺寸（居中由 flexbox 处理，此处只设宽高）
    local layoutChanged = visuals.mapSize ~= mapSize
    if layoutChanged then
        fullMapArea:SetStyle({ width = mapSize, height = mapSize })
        visuals.mapSize = mapSize
    end
    if mapDef and mapChanged then
        local mapColor = mapDef.mapColor or {25, 38, 25, 245}
        fullMapArea:SetStyle({
            width = mapSize, height = mapSize,
            backgroundColor = {mapColor[1], mapColor[2], mapColor[3], mapColor[4] or 245},
        })
        if title then
            title:SetText(mapDef.name .. " · Lv." .. tostring(mapDef.minLevel or 1)
                .. "–" .. tostring(mapDef.maxLevel or 50) .. " (" .. MapZone.ARENA_SIZE
                .. "m × " .. MapZone.ARENA_SIZE .. "m)")
        end
        if landmarkRefs then
            for i, ref in ipairs(landmarkRefs) do
                local landmark = mapDef.landmarks and mapDef.landmarks[i] or nil
                ref.root:SetVisible(landmark ~= nil)
                if landmark then ref.label:SetText(landmark.name or "地标") end
            end
        end
        visuals.mapId = mapId
    end

    -- 地图内边距（边框内）
    local pad = math.floor(mapSize * 0.04)
    local innerSize = mapSize - pad * 2

    local function worldToFullMap(x, z)
        local nx = math.max(0, math.min(1, (x + halfArena) / (halfArena * 2)))
        local nz = math.max(0, math.min(1, (halfArena - z) / (halfArena * 2)))
        return pad + nx * innerSize, pad + nz * innerSize
    end

    -- 更新网格线位置（3 水平 + 3 垂直，分为 4x4 格）
    if layoutChanged and gridLines then
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
    if layoutChanged and coordLabels then
        local offset = 4
        coordLabels[1]:SetStyle({ left = pad + offset, top = pad + offset })           -- NW
        coordLabels[2]:SetStyle({ left = pad + innerSize - 18, top = pad + offset })   -- NE
        coordLabels[3]:SetStyle({ left = pad + offset, top = pad + innerSize - 14 })   -- SW
        coordLabels[4]:SetStyle({ left = pad + innerSize - 18, top = pad + innerSize - 14 }) -- SE
        coordLabels[5]:SetStyle({ left = pad + math.floor(innerSize / 2) - 10, top = pad + math.floor(innerSize / 2) - 6 }) -- 中心
    end

    if mapDef and (layoutChanged or mapChanged) then
        local spawn = mapDef.spawnPos or Vector3.ZERO
        local safeHalf = MapZone.GetSafeZoneRadius(mapId)
        local safePixels = math.max(8, math.floor((safeHalf * 2 / mapState.arenaSize) * innerSize))
        local safeX, safeY = worldToFullMap(spawn.x, spawn.z)
        if safeZone then
            safeZone:SetStyle({
                left = math.floor(safeX - safePixels / 2),
                top = math.floor(safeY - safePixels / 2),
                width = safePixels, height = safePixels,
            })
        end

        local stewardPos = NPC.GetWorldPosition("steward", spawn)
        local merchantPos = NPC.GetWorldPosition("merchant", spawn)
        local blacksmithPos = NPC.GetWorldPosition("blacksmith", spawn)
        local stewardX, stewardY = worldToFullMap(stewardPos.x, stewardPos.z)
        local merchantX, merchantY = worldToFullMap(merchantPos.x, merchantPos.z)
        local blacksmithX, blacksmithY = worldToFullMap(blacksmithPos.x, blacksmithPos.z)
        if stewardDot then stewardDot:SetStyle({ left = math.floor(stewardX - 4), top = math.floor(stewardY - 4) }) end
        if merchantDot then merchantDot:SetStyle({ left = math.floor(merchantX - 4), top = math.floor(merchantY - 4) }) end
        if blacksmithDot then blacksmithDot:SetStyle({ left = math.floor(blacksmithX - 4), top = math.floor(blacksmithY - 4) }) end

        if landmarkRefs and mapDef.landmarks then
            for i, landmark in ipairs(mapDef.landmarks) do
                local ref = landmarkRefs[i]
                if ref then
                    local landmarkX, landmarkY = worldToFullMap(landmark.x or 0, landmark.z or 0)
                    ref.root:SetStyle({ left = math.floor(landmarkX - 4), top = math.floor(landmarkY - 9) })
                end
            end
        end
    end

    -- 坐标转换：世界坐标 → 全图像素
    local playerPos = playerNodeRef.worldPosition
    local dotX, dotY = worldToFullMap(playerPos.x, playerPos.z)

    -- 更新玩家标记
    local dotLeft = math.floor(dotX - 7)
    local dotTop = math.floor(dotY - 7)
    if visuals.dotLeft ~= dotLeft or visuals.dotTop ~= dotTop then
        playerDot:SetStyle({ left = dotLeft, top = dotTop })
        visuals.dotLeft, visuals.dotTop = dotLeft, dotTop
    end

    -- 更新朝向指示线（底端锚定玩家，随角色而非相机旋转）。
    if playerDir then
        local yaw = playerNodeRef.worldRotation:YawAngle()
        local dirLeft = math.floor(dotX - 1.5)
        local dirTop = math.floor(dotY - 16)
        local dirYaw = math.floor(yaw * 10 + 0.5) / 10
        if visuals.dirLeft ~= dirLeft or visuals.dirTop ~= dirTop or visuals.dirYaw ~= dirYaw then
            playerDir:SetStyle({ left = dirLeft, top = dirTop, rotate = dirYaw, transformOrigin = "bottom" })
            visuals.dirLeft, visuals.dirTop, visuals.dirYaw = dirLeft, dirTop, dirYaw
        end
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
GameUI.onTeleportToggle = nil
GameUI.onTeleportSelected = nil
GameUI.onNPCInteract = nil
GameUI.onDebugLevelChange = nil  -- function(delta) : +1 升级, -1 降级
GameUI.onDebugMaxLevel = nil     -- function() : 一键满级+技能栏填充

-- ============================================================================
-- 清理
-- ============================================================================
function GameUI.Shutdown()
    GameUI.HideDeathPresentation()
    if nvgCtx then
        nvgDelete(nvgCtx)
        nvgCtx = nil
    end
    UI.Shutdown()
end

return GameUI
