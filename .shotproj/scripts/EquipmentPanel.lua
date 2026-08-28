-- ============================================================================
-- EquipmentPanel.lua — 角色装备 / 背包界面与装备详情交互
-- 所有可选 UI 子节点都通过 table.insert 构建，避免 children 中间出现 nil
-- 后被 urhox-libs/UI 的 ipairs 提前截断。
-- ============================================================================

local UI = require("urhox-libs/UI")
local CharacterClass = require("CharacterClass")
local Inventory = require("Inventory")

local EquipmentPanel = {}

local STAT_DEFS = {
    {
        key = "atk", baseKey = "baseAtk", bonusKey = "bonusAtk",
        label = "攻击", color = {255, 108, 86, 245},
    },
    {
        key = "def", baseKey = "baseDef", bonusKey = "bonusDef",
        label = "防御", color = {90, 184, 255, 245},
    },
    {
        key = "hp", baseKey = "baseHP", bonusKey = "bonusHP",
        label = "生命", color = {92, 226, 116, 245},
    },
}

local CLASS_UI_COLORS = {
    warrior = {196, 72, 58},
    mage = {72, 146, 194},
    taoist = {58, 164, 96},
}

local function Integer(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end

local function GetStats(item)
    return Inventory.GetItemStats(item) or {
        atk = 0, def = 0, hp = 0,
        baseAtk = 0, baseDef = 0, baseHP = 0,
        bonusAtk = 0, bonusDef = 0, bonusHP = 0,
        enhance = 0,
    }
end

local function GetClassName(classId)
    if not classId then return "通用" end
    local classDef = CharacterClass.Classes[classId]
    return classDef and classDef.name or tostring(classId)
end

local function FormatItemName(item)
    if not item then return "空" end
    local level = Integer(item.enhance)
    return (item.name or "装备") .. (level > 0 and (" +" .. level) or "")
end

local function BuildBriefStats(item)
    local stats = GetStats(item)
    local parts = {}
    if stats.atk > 0 then table.insert(parts, "攻" .. stats.atk) end
    if stats.def > 0 then table.insert(parts, "防" .. stats.def) end
    if stats.hp > 0 then table.insert(parts, "血" .. stats.hp) end
    return #parts > 0 and table.concat(parts, " ") or "无属性"
end

local function BuildStatRows(item, comparedItem, compareEnabled)
    local itemStats = GetStats(item)
    local compareStats = compareEnabled and GetStats(comparedItem) or nil
    local rows = {}

    for _, def in ipairs(STAT_DEFS) do
        local total = Integer(itemStats[def.key])
        local base = Integer(itemStats[def.baseKey])
        local bonus = Integer(itemStats[def.bonusKey])
        local valueText = "+" .. total
        if bonus > 0 then
            valueText = valueText .. "  基础 " .. base .. " + 强化 " .. bonus
        end

        local rowChildren = {
            UI.Label {
                text = def.label,
                width = 44,
                fontSize = 12,
                fontColor = {170, 164, 150, 220},
            },
            UI.Label {
                text = valueText,
                flex = 1,
                fontSize = 12,
                fontColor = def.color,
                fontWeight = "bold",
            },
        }

        if compareStats then
            local delta = total - Integer(compareStats[def.key])
            local deltaText = "持平"
            local deltaColor = {170, 172, 170, 205}
            if delta > 0 then
                deltaText = "▲ +" .. delta
                deltaColor = {100, 225, 120, 245}
            elseif delta < 0 then
                deltaText = "▼ " .. delta
                deltaColor = {245, 105, 90, 245}
            end
            table.insert(rowChildren, UI.Label {
                text = deltaText,
                width = 58,
                fontSize = 11,
                textAlign = "right",
                fontColor = deltaColor,
                fontWeight = "bold",
            })
        end

        table.insert(rows, UI.Panel {
            width = "100%",
            minHeight = 26,
            flexDirection = "row",
            alignItems = "center",
            gap = 6,
            children = rowChildren,
        })
    end

    return rows
end

local function ShowToast(options, message)
    if options.showToast then options.showToast(message) end
end

local function Refresh(options)
    if options.refresh then options.refresh() end
end

local function CloseDetail(options)
    if options.closeDetail then options.closeDetail() end
end

local function ShowItemDetail(options, item, sourceSlot)
    if type(item) ~= "table" then return end

    local player = options.player
    local inv = Inventory.playerData
    local rarity = Inventory.RARITY[item.rarity]
    local rarityColor = rarity and rarity.color or {200, 200, 200, 255}
    local nameColor = {rarityColor[1], rarityColor[2], rarityColor[3], 255}
    local rarityName = rarity and rarity.name or "普通"
    local itemTypeName = Inventory.GetItemTypeName(item.itemType or item.slot)
    local requiredClassName = GetClassName(item.classReq)
    local classMatches = not item.classReq or item.classReq == player.classId
    local targetSlot = sourceSlot or Inventory.GetSuggestedEquipSlot(item)
    local targetItem = (not sourceSlot and targetSlot) and inv.equipped[targetSlot] or nil
    local targetName = targetSlot and (Inventory.SLOT_NAMES[targetSlot] or targetSlot) or "未知槽位"
    local bagFull = #inv.bag >= Inventory.MAX_BAG_SLOTS
    local enhanceLevel = Integer(item.enhance)
    -- 背包装备只保留查看、穿戴和前往商人出售的路径；分解操作仅保留在
    -- 已穿戴装备详情中，避免玩家在背包里直接把掉落物变成金币。
    local recycleReward = sourceSlot and Inventory.Enhance.Recycle(item) or nil
    local sellPrice = Inventory.GetItemSellPrice(item)

    local function doEquip()
        local ok, reason, equippedSlot = Inventory.EquipItem(item, player.classId, targetSlot)
        if not ok then
            ShowToast(options, reason or "穿戴失败")
            return
        end
        local slotName = Inventory.SLOT_NAMES[equippedSlot] or targetName
        if targetItem then
            ShowToast(options, "已替换 " .. slotName .. "，原装备已放回背包")
        else
            ShowToast(options, "已穿戴至 " .. slotName)
        end
        Refresh(options)
    end

    local function doUnequip()
        local ok, reason = Inventory.UnequipSlot(sourceSlot)
        if not ok then
            ShowToast(options, reason or "卸下失败")
            return
        end
        ShowToast(options, "已卸下 " .. (item.name or "装备"))
        Refresh(options)
    end

    local function doRecycle()
        local ok, reward, reason = Inventory.RecycleItem(item)
        if not ok then
            ShowToast(options, reason or "分解失败")
            return
        end
        ShowToast(options, "已分解，获得 " .. reward.gold .. " 金币")
        Refresh(options)
    end

    local function requestRecycle()
        local isLegendary = item.rarity == "LEGENDARY"
        local isEquipped = sourceSlot ~= nil
        if isLegendary or isEquipped then
            local warning = isEquipped and "这件装备当前正在穿戴。" or ""
            UI.Modal.Confirm {
                title = isLegendary and "确认分解传说装备" or "确认分解穿戴中装备",
                message = warning .. "【" .. (item.name or "装备") .. "】分解后无法恢复，确定继续吗？",
                confirmText = "确认分解",
                cancelText = "保留装备",
                onConfirm = doRecycle,
            }
            return
        end
        doRecycle()
    end

    local bodyChildren = {
        UI.Label {
            text = "[" .. rarityName .. "]",
            fontSize = 11,
            fontColor = nameColor,
            textAlign = "center",
        },
        UI.Label {
            text = FormatItemName(item),
            fontSize = 19,
            fontWeight = "bold",
            fontColor = nameColor,
            textAlign = "center",
            marginTop = 2,
        },
        UI.Panel {
            width = "100%",
            flexDirection = "row",
            flexWrap = "wrap",
            justifyContent = "center",
            gap = 8,
            marginTop = 5,
            children = {
                UI.Label { text = itemTypeName, fontSize = 11, fontColor = {174, 168, 154, 210} },
                UI.Label {
                    text = item.classReq and ("仅限 " .. requiredClassName) or "职业通用",
                    fontSize = 11,
                    fontColor = classMatches and {174, 168, 154, 210} or {246, 112, 92, 245},
                },
            },
        },
        UI.Panel {
            width = "100%", height = 1,
            backgroundColor = {104, 94, 74, 105},
            marginTop = 10, marginBottom = 9,
        },
        UI.Label {
            text = "实际属性",
            width = "100%",
            fontSize = 12,
            fontColor = {212, 204, 184, 235},
            fontWeight = "bold",
        },
        UI.Panel {
            width = "100%",
            gap = 3,
            marginTop = 4,
            children = BuildStatRows(
                item, targetItem,
                not sourceSlot and targetSlot ~= nil and classMatches),
        },
    }

    if sourceSlot then
        table.insert(bodyChildren, UI.Label {
            text = "当前穿戴：" .. targetName,
            width = "100%",
            fontSize = 11,
            fontColor = {132, 196, 234, 230},
            marginTop = 8,
        })
    elseif targetSlot then
        table.insert(bodyChildren, UI.Label {
            text = targetItem
                and ("对比 " .. targetName .. " · " .. FormatItemName(targetItem))
                or ("目标 " .. targetName .. " · 当前为空"),
            width = "100%",
            fontSize = 11,
            fontColor = targetItem and {202, 188, 156, 220} or {110, 214, 130, 230},
            marginTop = 8,
        })
    end

    table.insert(bodyChildren, UI.Label {
        text = sourceSlot
            and ("卸下后可出售 " .. sellPrice .. " 金 · 分解可得 "
                .. recycleReward.gold .. " 金")
            or ("出售可得 " .. sellPrice .. " 金 · 请前往安全区商人"),
        width = "100%",
        fontSize = 10,
        fontColor = {165, 158, 144, 195},
        marginTop = 7,
    })

    table.insert(bodyChildren, UI.Panel {
        width = "100%", height = 1,
        backgroundColor = {104, 94, 74, 105},
        marginTop = 10, marginBottom = 9,
    })

    if sourceSlot then
        table.insert(bodyChildren, UI.Button {
            text = bagFull and "背包已满，无法卸下" or "卸下到背包",
            width = "100%", height = 40,
            variant = "primary",
            disabled = bagFull,
            onClick = not bagFull and doUnequip or nil,
        })
        if bagFull then
            table.insert(bodyChildren, UI.Label {
                text = "先清理一个背包格，或直接用背包装备进行原位替换。",
                width = "100%",
                fontSize = 10,
                fontColor = {241, 151, 92, 230},
                marginTop = 4,
            })
        end
    else
        local canEquip = targetSlot ~= nil and classMatches
        local equipText = targetItem and ("替换到 " .. targetName) or ("穿戴到 " .. targetName)
        if not classMatches then
            equipText = "职业不符 · 仅限 " .. requiredClassName
        elseif not targetSlot then
            equipText = "没有可用装备槽位"
        end
        table.insert(bodyChildren, UI.Button {
            text = equipText,
            width = "100%", height = 40,
            variant = "primary",
            disabled = not canEquip,
            onClick = canEquip and doEquip or nil,
        })
    end

    table.insert(bodyChildren, UI.Label {
        text = "强化",
        width = "100%",
        fontSize = 12,
        fontColor = {222, 202, 150, 235},
        fontWeight = "bold",
        marginTop = 12,
    })

    table.insert(bodyChildren, UI.Panel {
        width = "100%",
        marginTop = 5,
        padding = 9,
        backgroundColor = enhanceLevel >= 12
            and {30, 48, 31, 205} or {45, 34, 19, 205},
        borderRadius = 7,
        borderWidth = 1,
        borderColor = enhanceLevel >= 12
            and {92, 168, 105, 175} or {174, 126, 54, 175},
        gap = 3,
        children = {
            UI.Label {
                text = enhanceLevel >= 12
                    and "当前 +12 · 已达到强化上限"
                    or ("当前 +" .. enhanceLevel .. " · 下一等级请前往安全区铁匠"),
                fontSize = 11,
                fontWeight = "bold",
                fontColor = enhanceLevel >= 12
                    and {142, 220, 151, 240} or {238, 198, 116, 240},
            },
            UI.Label {
                text = "铁匠会在操作前展示金币费用、成功率、失败结果与保护选项。",
                fontSize = 9,
                lineHeight = 1.35,
                whiteSpace = "normal",
                fontColor = {174, 168, 154, 205},
            },
        },
    })

    if sourceSlot then
        table.insert(bodyChildren, UI.Button {
            text = "分解穿戴中装备",
            width = "100%", height = 36,
            marginTop = 12,
            variant = "danger",
            onClick = requestRecycle,
        })
    end
    table.insert(bodyChildren, UI.Panel { width = "100%", height = 8 })

    local detailPanel = UI.Panel {
        position = "absolute",
        width = "100%", height = "100%",
        justifyContent = "center", alignItems = "center",
        backgroundColor = {0, 0, 0, 190},
        onClick = function() CloseDetail(options) end,
        children = {
            UI.Panel {
                width = "88%", maxWidth = 360,
                height = "86%", maxHeight = 500,
                backgroundColor = {25, 20, 15, 252},
                borderRadius = 10, borderWidth = 2,
                borderColor = {rarityColor[1], rarityColor[2], rarityColor[3], 205},
                padding = 14,
                overflow = "hidden",
                onClick = function() end,
                children = {
                    UI.Panel {
                        width = "100%", minHeight = 38,
                        flexShrink = 0,
                        flexDirection = "row",
                        justifyContent = "space-between",
                        alignItems = "center",
                        marginBottom = 8,
                        children = {
                            UI.Label {
                                text = "装备详情",
                                fontSize = 16,
                                fontColor = {234, 236, 234, 255},
                                fontWeight = "bold",
                            },
                            UI.Button {
                                text = "← 返回",
                                width = 82, height = 34,
                                variant = "secondary",
                                onClick = function() CloseDetail(options) end,
                            },
                        },
                    },
                    UI.ScrollView {
                        width = "100%",
                        flexGrow = 1,
                        flexBasis = 0,
                        showScrollbar = true,
                        children = {
                            UI.Panel {
                                width = "100%",
                                alignItems = "stretch",
                                children = bodyChildren,
                            },
                        },
                    },
                },
            },
        },
    }

    if options.openDetail then options.openDetail(detailPanel) end
end

local function MakeSlotCell(options, slotKey, width, height)
    local inv = Inventory.playerData
    local item = inv.equipped[slotKey]
    local label = Inventory.SLOT_NAMES[slotKey] or slotKey
    local rarity = item and Inventory.RARITY[item.rarity] or nil
    local rarityColor = rarity and rarity.color or nil
    local nameColor = rarityColor
        and {rarityColor[1], rarityColor[2], rarityColor[3], 255}
        or {122, 118, 104, 190}
    local borderColor = rarityColor
        and {rarityColor[1], rarityColor[2], rarityColor[3], 205}
        or {58, 53, 44, 165}
    local children = {
        UI.Label {
            text = label,
            fontSize = 9,
            fontColor = {145, 136, 112, 175},
        },
    }

    if item then
        table.insert(children, UI.Label {
            text = FormatItemName(item),
            fontSize = 10,
            fontWeight = "bold",
            fontColor = nameColor,
            marginTop = 2,
            textAlign = "center",
        })
        table.insert(children, UI.Label {
            text = BuildBriefStats(item),
            fontSize = 8,
            fontColor = {190, 183, 164, 205},
            marginTop = 2,
            textAlign = "center",
        })
    else
        table.insert(children, UI.Label {
            text = "空",
            fontSize = 11,
            fontColor = {104, 100, 90, 145},
            marginTop = 5,
        })
    end

    local capturedItem = item
    local capturedSlot = slotKey
    local function handleCellClick()
        local handled = false
        if type(options.onEquipmentSlotClick) == "function" then
            -- GameUI 统一维护连续点击状态；返回 true 表示本次点击已被
            -- 隐藏调试入口消费，不能再打开装备详情。
            handled = options.onEquipmentSlotClick(capturedSlot) == true
        end

        if handled then return end
        if capturedItem then
            ShowItemDetail(options, capturedItem, capturedSlot)
        end
    end

    return UI.Panel {
        width = width or 72,
        height = height or 72,
        overflow = "hidden",
        backgroundColor = item and {30, 24, 18, 250} or {22, 18, 14, 205},
        borderRadius = 5,
        borderWidth = item and 1.5 or 1,
        borderColor = borderColor,
        justifyContent = "center",
        alignItems = "center",
        paddingHorizontal = 3,
        paddingVertical = 3,
        onClick = handleCellClick,
        children = children,
    }
end

function EquipmentPanel.BuildEquipTab(options)
    local player = options.player
    local inv = Inventory.playerData
    local SLOT = Inventory.SLOT
    local classDef = CharacterClass.Classes[player.classId]
    local classColor = CLASS_UI_COLORS[player.classId] or {200, 180, 120}

    local leftColumn = UI.Panel {
        width = 78,
        alignItems = "center",
        gap = 4,
        children = {
            MakeSlotCell(options, SLOT.HELMET),
            MakeSlotCell(options, SLOT.NECKLACE),
            MakeSlotCell(options, SLOT.BRACELET1),
            MakeSlotCell(options, SLOT.RING1),
            MakeSlotCell(options, SLOT.BELT),
        },
    }
    local rightColumn = UI.Panel {
        width = 78,
        alignItems = "center",
        gap = 4,
        children = {
            MakeSlotCell(options, SLOT.WEAPON),
            MakeSlotCell(options, SLOT.ARMOR),
            MakeSlotCell(options, SLOT.BRACELET2),
            MakeSlotCell(options, SLOT.RING2),
            MakeSlotCell(options, SLOT.BOOTS),
        },
    }
    local centerColumn = UI.Panel {
        flex = 1,
        alignItems = "center",
        justifyContent = "center",
        paddingVertical = 8,
        children = {
            UI.Panel {
                width = 100,
                height = 178,
                backgroundColor = {12, 10, 8, 205},
                borderRadius = 8,
                borderWidth = 1,
                borderColor = {62, 53, 38, 130},
                justifyContent = "center",
                alignItems = "center",
                children = {
                    UI.Label {
                        text = classDef and classDef.name or "角色",
                        fontSize = 14,
                        fontWeight = "bold",
                        fontColor = {classColor[1], classColor[2], classColor[3], 225},
                    },
                    UI.Label {
                        text = "Lv." .. player.level,
                        fontSize = 12,
                        fontColor = {204, 194, 170, 205},
                        marginTop = 4,
                    },
                    UI.Label {
                        text = "⚔",
                        fontSize = 38,
                        fontColor = {classColor[1], classColor[2], classColor[3], 145},
                        marginTop = 8,
                    },
                },
            },
            UI.Panel {
                width = "100%",
                marginTop = 9,
                alignItems = "center",
                gap = 3,
                children = {
                    UI.Label {
                        text = "装备总加成",
                        fontSize = 10,
                        fontColor = {174, 176, 174, 185},
                    },
                    UI.Label { text = "攻击 +" .. Integer(inv.bonusAtk), fontSize = 11, fontColor = {255, 108, 86, 235}, fontWeight = "bold" },
                    UI.Label { text = "防御 +" .. Integer(inv.bonusDef), fontSize = 11, fontColor = {90, 184, 255, 235}, fontWeight = "bold" },
                    UI.Label { text = "生命 +" .. Integer(inv.bonusHP), fontSize = 11, fontColor = {92, 226, 116, 235}, fontWeight = "bold" },
                    UI.Label {
                        text = "背包 " .. #inv.bag .. "/" .. Inventory.MAX_BAG_SLOTS,
                        fontSize = 9,
                        fontColor = #inv.bag >= Inventory.MAX_BAG_SLOTS
                            and {245, 112, 92, 235} or {164, 160, 148, 190},
                        marginTop = 3,
                    },
                },
            },
        },
    }

    return UI.Panel {
        width = "100%",
        children = {
            UI.Label {
                text = "点击已穿戴装备查看属性、分解或卸下；背包装备可出售，强化请前往安全区铁匠",
                fontSize = 10,
                fontColor = {154, 156, 154, 175},
                textAlign = "center",
                marginBottom = 6,
            },
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                justifyContent = "space-between",
                alignItems = "flex-start",
                children = {leftColumn, centerColumn, rightColumn},
            },
        },
    }
end

function EquipmentPanel.BuildBagTab(options)
    local player = options.player
    local inv = Inventory.playerData
    if not inv.potions then inv.potions = {hp = 5, mp = 3} end

    local bagCells = {}
    for index = 1, Inventory.MAX_BAG_SLOTS do
        local item = inv.bag[index]
        local rarity = item and Inventory.RARITY[item.rarity] or nil
        local rarityColor = rarity and rarity.color or nil
        local nameColor = rarityColor
            and {rarityColor[1], rarityColor[2], rarityColor[3], 240}
            or {90, 86, 76, 115}
        local borderColor = rarityColor
            and {rarityColor[1], rarityColor[2], rarityColor[3], 155}
            or {46, 42, 35, 105}
        local cellChildren = {
            UI.Label {
                text = tostring(index),
                position = "absolute",
                top = 2, left = 4,
                fontSize = 8,
                fontColor = {118, 114, 104, 135},
                pointerEvents = "none",
            },
        }

        if item then
            table.insert(cellChildren, UI.Label {
                text = item.name or "装备",
                fontSize = 10,
                fontWeight = "bold",
                fontColor = nameColor,
                textAlign = "center",
            })
            if Integer(item.enhance) > 0 then
                table.insert(cellChildren, UI.Label {
                    text = "+" .. Integer(item.enhance),
                    fontSize = 9,
                    fontColor = {255, 211, 92, 235},
                    marginTop = 1,
                })
            end
            table.insert(cellChildren, UI.Label {
                text = BuildBriefStats(item),
                fontSize = 8,
                fontColor = {184, 178, 160, 195},
                marginTop = 2,
                textAlign = "center",
            })
            table.insert(cellChildren, UI.Label {
                text = "点击查看",
                fontSize = 8,
                fontColor = {130, 190, 142, 185},
                marginTop = 2,
            })
        else
            table.insert(cellChildren, UI.Label {
                text = "空",
                fontSize = 10,
                fontColor = {96, 92, 82, 125},
            })
        end

        local capturedItem = item
        table.insert(bagCells, UI.Panel {
            width = 66,
            height = 72,
            overflow = "hidden",
            backgroundColor = item and {28, 23, 17, 242} or {18, 15, 12, 125},
            borderRadius = 5,
            borderWidth = 1,
            borderColor = borderColor,
            justifyContent = "center",
            alignItems = "center",
            paddingHorizontal = 4,
            paddingVertical = 4,
            onClick = capturedItem and function()
                ShowItemDetail(options, capturedItem, nil)
            end or nil,
            children = cellChildren,
        })
    end

    local capacityColor = #inv.bag >= Inventory.MAX_BAG_SLOTS
        and {245, 112, 92, 240} or {184, 186, 184, 215}

    return UI.Panel {
        width = "100%",
        children = {
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                flexWrap = "wrap",
                alignItems = "center",
                gap = 8,
                marginBottom = 10,
                children = {
                    UI.Label { text = "金币 " .. inv.gold, fontSize = 13, fontColor = {228, 230, 228, 255}, fontWeight = "bold" },
                    UI.Label { text = "保护石 " .. Inventory.GetProtectStones(), fontSize = 11, fontColor = {126, 190, 242, 225} },
                },
            },
            UI.Panel {
                width = "100%",
                gap = 6,
                marginBottom = 11,
                children = {
                    UI.Label {
                        text = "药水 · 仅可在安全区商人处购买",
                        fontSize = 11,
                        fontColor = {180, 182, 180, 205},
                    },
                    UI.Panel {
                        width = "100%",
                        flexDirection = "row",
                        flexWrap = "wrap",
                        gap = 8,
                        children = {
                            UI.Panel {
                                minHeight = 32,
                                paddingHorizontal = 10,
                                paddingVertical = 6,
                                backgroundColor = {40, 20, 18, 205},
                                borderRadius = 6,
                                borderWidth = 1,
                                borderColor = {142, 67, 55, 155},
                                children = {
                                    UI.Label {
                                        text = "血药 " .. inv.potions.hp .. "/" .. Inventory.POTION_CONFIG.hp.max
                                            .. " · 商人价 " .. Inventory.POTION_CONFIG.hp.price .. " 金币",
                                        fontSize = 10,
                                        fontColor = {224, 188, 178, 225},
                                    },
                                },
                            },
                            UI.Panel {
                                minHeight = 32,
                                paddingHorizontal = 10,
                                paddingVertical = 6,
                                backgroundColor = {18, 24, 43, 205},
                                borderRadius = 6,
                                borderWidth = 1,
                                borderColor = {61, 94, 157, 155},
                                children = {
                                    UI.Label {
                                        text = "蓝药 " .. inv.potions.mp .. "/" .. Inventory.POTION_CONFIG.mp.max
                                            .. " · 商人价 " .. Inventory.POTION_CONFIG.mp.price .. " 金币",
                                        fontSize = 10,
                                        fontColor = {178, 196, 228, 225},
                                    },
                                },
                            },
                        },
                    },
                },
            },
            UI.Panel {
                width = "100%", height = 1,
                backgroundColor = {74, 76, 78, 110},
                marginBottom = 9,
            },
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                justifyContent = "space-between",
                alignItems = "center",
                marginBottom = 4,
                children = {
                    UI.Label {
                        text = "背包 " .. #inv.bag .. "/" .. Inventory.MAX_BAG_SLOTS,
                        fontSize = 12,
                        fontColor = capacityColor,
                        fontWeight = "bold",
                    },
                    UI.Label {
                        text = "点击装备查看并穿戴 / 替换",
                        fontSize = 9,
                        fontColor = {148, 150, 148, 170},
                    },
                },
            },
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                flexWrap = "wrap",
                gap = 6,
                paddingBottom = 8,
                children = bagCells,
            },
        },
    }
end

return EquipmentPanel
