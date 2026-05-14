-- ============================================================================
-- GameUI.lua — 传奇·山海 完整 UI 系统
-- 技能栏(弧形) + HP/MP条 + 摇杆 + 角色选择界面 + 伤害飘字
-- ============================================================================

local UI = require("urhox-libs/UI")
local CharacterClass = require("scripts.CharacterClass")
require "urhox-libs.UI.GameHUD"

local GameUI = {}

-- UI 颜色
local C = CharacterClass.Colors

-- ============================================================================
-- 状态
-- ============================================================================
local uiState = {
    phase = "select",   -- "select" | "playing"
    selectedClass = nil,
    player = nil,
    joystick = nil,
    skillButtons = {},
    floatingTexts = {},  -- 伤害飘字
    onClassSelected = nil,
    hudRoot = nil,
    selectRoot = nil,
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
-- 角色选择界面
-- ============================================================================
function GameUI.ShowClassSelect(onSelected)
    uiState.phase = "select"
    uiState.onClassSelected = onSelected

    local classOrder = {"warrior", "mage", "taoist"}
    local classIcons = {
        warrior = "剑",
        mage    = "火",
        taoist  = "道",
    }
    local classColors = {
        warrior = {190, 60, 50, 255},
        mage    = {70, 140, 175, 255},
        taoist  = {55, 155, 95, 255},
    }

    local cards = {}
    for _, classId in ipairs(classOrder) do
        local cls = CharacterClass.Classes[classId]
        local clr = classColors[classId]

        table.insert(cards, UI.Panel {
            width = 200,
            paddingVertical = 24,
            paddingHorizontal = 16,
            alignItems = "center",
            backgroundColor = {30, 30, 35, 220},
            borderRadius = 16,
            borderWidth = 2,
            borderColor = clr,
            children = {
                -- 职业图标圆圈
                UI.Panel {
                    width = 72, height = 72,
                    borderRadius = 36,
                    backgroundColor = clr,
                    justifyContent = "center",
                    alignItems = "center",
                    children = {
                        UI.Label {
                            text = classIcons[classId],
                            fontSize = 28,
                            fontColor = {255, 255, 255, 255},
                        },
                    },
                },
                -- 职业名
                UI.Label {
                    text = cls.name,
                    fontSize = 22,
                    fontColor = {240, 235, 220, 255},
                    marginTop = 12,
                },
                -- 职业描述
                UI.Label {
                    text = cls.desc,
                    fontSize = 12,
                    fontColor = {180, 175, 165, 180},
                    marginTop = 6,
                    textAlign = "center",
                },
                -- 属性预览
                UI.Label {
                    text = "HP " .. cls.baseHP .. "  ATK " .. cls.baseATK .. "  DEF " .. cls.baseDEF,
                    fontSize = 11,
                    fontColor = {160, 155, 145, 160},
                    marginTop = 8,
                },
                -- 选择按钮
                UI.Button {
                    label = "选择",
                    marginTop = 16,
                    width = 120,
                    height = 36,
                    backgroundColor = clr,
                    borderRadius = 8,
                    fontSize = 14,
                    fontColor = {255, 255, 255, 255},
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
        backgroundColor = {20, 20, 25, 240},
        justifyContent = "center",
        alignItems = "center",
        children = {
            -- 标题
            UI.Label {
                text = "传奇 · 山海",
                fontSize = 36,
                fontColor = {210, 180, 80, 255},
                marginBottom = 8,
            },
            UI.Label {
                text = "选择你的职业",
                fontSize = 14,
                fontColor = {160, 155, 145, 180},
                marginBottom = 32,
            },
            -- 三个卡片横排
            UI.Panel {
                flexDirection = "row",
                gap = 20,
                children = cards,
            },
        },
    }

    UI.SetRoot(uiState.selectRoot)
    print("[GameUI] Class select screen shown")
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
            -- 左上角：角色信息
            GameUI._CreatePlayerInfo(player),
            -- 右下角：技能栏
            GameUI._CreateSkillBar(player),
            -- 左下角：药瓶快捷键
            GameUI._CreatePotions(player),
            -- 右上角：小地图占位 + 等级
            GameUI._CreateMiniMapArea(player),
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
        warrior = {190, 60, 50, 255},
        mage    = {70, 140, 175, 255},
        taoist  = {55, 155, 95, 255},
    }
    local clr = classColors[player.classId]

    return UI.Panel {
        id = "playerInfo",
        position = "absolute",
        top = 12, left = 12,
        width = 200,
        padding = 10,
        backgroundColor = {20, 20, 25, 180},
        borderRadius = 10,
        borderWidth = 1,
        borderColor = {80, 80, 85, 120},
        children = {
            -- 职业名 + 等级
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                marginBottom = 6,
                children = {
                    UI.Panel {
                        width = 28, height = 28,
                        borderRadius = 14,
                        backgroundColor = clr,
                        justifyContent = "center",
                        alignItems = "center",
                        children = {
                            UI.Label {
                                text = string.sub(classDef.name, 1, 3),
                                fontSize = 11,
                                fontColor = {255, 255, 255, 255},
                            },
                        },
                    },
                    UI.Label {
                        id = "playerLevel",
                        text = "Lv." .. player.level .. " " .. classDef.name,
                        fontSize = 13,
                        fontColor = {220, 215, 200, 255},
                        marginLeft = 8,
                    },
                },
            },
            -- HP 条
            UI.Panel {
                marginBottom = 4,
                children = {
                    UI.ProgressBar {
                        id = "hpBar",
                        width = "100%",
                        height = 14,
                        value = player.hp / player.maxHP,
                        backgroundColor = {40, 20, 20, 200},
                        fillColor = C.HpRed,
                        borderRadius = 3,
                    },
                    UI.Label {
                        id = "hpText",
                        text = math.floor(player.hp) .. "/" .. player.maxHP,
                        fontSize = 9,
                        fontColor = {255, 255, 255, 200},
                        position = "absolute",
                        top = 1, left = 0, right = 0,
                        textAlign = "center",
                    },
                },
            },
            -- MP 条
            UI.Panel {
                children = {
                    UI.ProgressBar {
                        id = "mpBar",
                        width = "100%",
                        height = 14,
                        value = player.mp / player.maxMP,
                        backgroundColor = {20, 20, 40, 200},
                        fillColor = C.MpBlue,
                        borderRadius = 3,
                    },
                    UI.Label {
                        id = "mpText",
                        text = math.floor(player.mp) .. "/" .. player.maxMP,
                        fontSize = 9,
                        fontColor = {255, 255, 255, 200},
                        position = "absolute",
                        top = 1, left = 0, right = 0,
                        textAlign = "center",
                    },
                },
            },
            -- EXP 条
            UI.ProgressBar {
                id = "expBar",
                width = "100%",
                height = 6,
                marginTop = 4,
                value = player.exp / math.max(1, player.expToNext),
                backgroundColor = {30, 30, 20, 150},
                fillColor = C.ExpGold,
                borderRadius = 2,
            },
        },
    }
end

-- ============================================================================
-- 右下角 - 技能栏 (弧形排列)
-- ============================================================================
function GameUI._CreateSkillBar(player)
    local classDef = CharacterClass.Classes[player.classId]

    -- 弧形布局参数 (右下角为基准)
    -- 以 ① 普攻按钮为原点(右下角)，其他按钮沿弧形向左上排列
    local btnSize = {72, 56, 56, 56, 56, 64}  -- 各按钮大小
    -- 从右下角开始，弧形坐标 (相对于右下角锚点的偏移)
    local positions = {
        {x = -50,  y = -50},   -- ① 普攻 (最右下)
        {x = -120, y = -65},   -- ②
        {x = -175, y = -105},  -- ③
        {x = -215, y = -160},  -- ④
        {x = -235, y = -225},  -- ⑤
        {x = -90,  y = -130},  -- ⑥ 终极技 (独立位置)
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

        -- 按钮边框颜色
        local borderClr
        if isUltimate then
            borderClr = C.ExpGold  -- 鎏金边框
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
            backgroundColor = {30, 30, 35, 200},
            borderWidth = isUltimate and 3 or 2,
            borderColor = borderClr,
            justifyContent = "center",
            alignItems = "center",
            children = {
                -- 技能名
                UI.Label {
                    text = skillName,
                    fontSize = size <= 56 and 10 or 12,
                    fontColor = skillLvl > 0 and {240, 235, 220, 255} or {100, 100, 100, 150},
                    textAlign = "center",
                },
                -- 冷却覆盖层
                UI.Panel {
                    id = btnId .. "_cd",
                    position = "absolute",
                    top = 0, left = 0,
                    width = size, height = size,
                    borderRadius = size / 2,
                    backgroundColor = {0, 0, 0, 0},  -- 初始透明
                    justifyContent = "center",
                    alignItems = "center",
                    children = {
                        UI.Label {
                            id = btnId .. "_cdText",
                            text = "",
                            fontSize = 14,
                            fontColor = {255, 255, 255, 220},
                        },
                    },
                },
                -- 等级点
                skillLvl > 0 and UI.Panel {
                    position = "absolute",
                    bottom = 2,
                    flexDirection = "row",
                    gap = 2,
                    children = GameUI._CreateLevelDots(skillLvl),
                } or nil,
            },
            -- 点击释放技能
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
            -- HP 药瓶
            UI.Panel {
                width = 44, height = 44,
                borderRadius = 22,
                backgroundColor = {50, 20, 20, 200},
                borderWidth = 2,
                borderColor = {180, 60, 50, 200},
                justifyContent = "center",
                alignItems = "center",
                onPointerUp = function()
                    if GameUI.onUseHpPotion then GameUI.onUseHpPotion() end
                end,
                children = {
                    UI.Label {
                        text = "HP",
                        fontSize = 11,
                        fontColor = {220, 80, 70, 255},
                    },
                },
            },
            -- MP 药瓶
            UI.Panel {
                width = 44, height = 44,
                borderRadius = 22,
                backgroundColor = {20, 20, 50, 200},
                borderWidth = 2,
                borderColor = {60, 120, 180, 200},
                justifyContent = "center",
                alignItems = "center",
                onPointerUp = function()
                    if GameUI.onUseMpPotion then GameUI.onUseMpPotion() end
                end,
                children = {
                    UI.Label {
                        text = "MP",
                        fontSize = 11,
                        fontColor = {70, 140, 200, 255},
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
            -- 小地图占位
            UI.Panel {
                width = 80, height = 80,
                borderRadius = 40,
                backgroundColor = {20, 20, 25, 160},
                borderWidth = 1,
                borderColor = {80, 80, 85, 100},
                justifyContent = "center",
                alignItems = "center",
                children = {
                    UI.Label {
                        text = "MAP",
                        fontSize = 10,
                        fontColor = {100, 100, 100, 120},
                    },
                },
            },
            -- 击杀数
            UI.Label {
                id = "killCount",
                text = "击杀: 0",
                fontSize = 11,
                fontColor = {180, 175, 165, 180},
                marginTop = 8,
                textAlign = "right",
            },
        },
    }
end

-- ============================================================================
-- HUD 更新
-- ============================================================================
function GameUI.UpdateHUD(player, dt)
    if uiState.phase ~= "playing" or not uiState.hudRoot then return end

    -- 更新 HP/MP 条
    local hpBar = UI.FindById("hpBar")
    local mpBar = UI.FindById("mpBar")
    local hpText = UI.FindById("hpText")
    local mpText = UI.FindById("mpText")
    local expBar = UI.FindById("expBar")
    local lvLabel = UI.FindById("playerLevel")

    if hpBar then hpBar:SetProps({ value = player.hp / player.maxHP }) end
    if mpBar then mpBar:SetProps({ value = player.mp / player.maxMP }) end
    if hpText then hpText:SetProps({ text = math.floor(player.hp) .. "/" .. player.maxHP }) end
    if mpText then mpText:SetProps({ text = math.floor(player.mp) .. "/" .. player.maxMP }) end
    if expBar then expBar:SetProps({ value = player.exp / math.max(1, player.expToNext) }) end
    if lvLabel then
        local classDef = CharacterClass.Classes[player.classId]
        lvLabel:SetProps({ text = "Lv." .. player.level .. " " .. classDef.name })
    end

    -- 更新技能冷却显示
    for i = 1, 6 do
        local sb = uiState.skillButtons[i]
        if sb and sb.skill then
            local cd = player.cooldowns[sb.skill.id] or 0
            local cdPanel = UI.FindById("skill_" .. i .. "_cd")
            local cdText  = UI.FindById("skill_" .. i .. "_cdText")
            if cd > 0 then
                if cdPanel then cdPanel:SetProps({ backgroundColor = {0, 0, 0, 140} }) end
                if cdText then cdText:SetProps({ text = string.format("%.0f", math.ceil(cd)) }) end
            else
                if cdPanel then cdPanel:SetProps({ backgroundColor = {0, 0, 0, 0} }) end
                if cdText then cdText:SetProps({ text = "" }) end
            end
        end
    end

    -- 更新飘字
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
    local label = UI.FindById("killCount")
    if label then
        label:SetProps({ text = "击杀: " .. count })
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
    UI.Shutdown()
end

return GameUI
