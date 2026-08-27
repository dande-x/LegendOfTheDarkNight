-- ============================================================================
-- BlacksmithPanel.lua — 铁匠“锻造 / 强化”双页容器
-- ============================================================================

local UI = require("urhox-libs/UI")
local ForgePanel = require("ForgePanel")
local EnhancePanel = require("EnhancePanel")
local ServiceScrollView = require("ServiceScrollView")

local BlacksmithPanel = {}

-- Tab 内容不会挂在 Tabs.children 上，因此 UI.Update 不会自动遍历到
-- 内层 ScrollView。这里给每个页根节点补一个轻量递归更新器，确保
-- ScrollView 每帧都能重新计算 contentHeight 并处理拖拽惯性。
local function UpdateDescendants(widget, dt)
    for _, child in ipairs(widget.children or {}) do
        if child.Update then
            child:Update(dt)
        end
        UpdateDescendants(child, dt)
    end
end

local function EnableTabContentUpdates(content)
    if content and not content.Update then
        content.Update = function(self, dt)
            UpdateDescendants(self, dt)
        end
    end
    return content
end

local function NormalizeTab(tabId)
    return tabId == "enhance" and "enhance" or "forge"
end

local function BuildForgePage(options)
    local content = ForgePanel.Build {
        showToast = options.showToast,
        onRefresh = options.onRefresh,
        onGoldChanged = options.onGoldChanged,
        onSuccess = options.onForgeSuccess,
    }
    return EnableTabContentUpdates(UI.Panel {
        width = "100%",
        height = "100%",
        paddingTop = 9,
        overflow = "hidden",
        children = {
            ServiceScrollView.Build {
                width = "100%",
                flexGrow = 1,
                flexBasis = 0,
                showScrollbar = true,
                children = { content },
            },
        },
    })
end

local function BuildEnhancePage(options)
    return EnableTabContentUpdates(UI.Panel {
        width = "100%",
        height = "100%",
        paddingTop = 9,
        overflow = "hidden",
        children = {
            EnhancePanel.Build {
                player = options.player,
                selectedItem = options.selectedEnhanceItem,
                showToast = options.showToast,
                onSelect = options.onEnhanceSelect,
                onSelectionResolved = options.onEnhanceSelectionResolved,
                onRefresh = options.onRefresh,
                onGoldChanged = options.onGoldChanged,
                applyDerivedStats = options.applyDerivedStats,
                onSuccess = options.onEnhanceSuccess,
            },
        },
    })
end

--- 构建铁匠双页服务区。Tabs 必须提供明确高度，否则只会显示标签栏。
---@param options table
---@return table
function BlacksmithPanel.Build(options)
    options = options or {}
    local activeTab = NormalizeTab(options.activeTab)
    local tabs = UI.Tabs {
        tabs = {
            { id = "forge", label = "锻造" },
            { id = "enhance", label = "强化" },
        },
        activeTab = activeTab,
        variant = "enclosed",
        orientation = "horizontal",
        width = "100%",
        -- UI.Tabs 必须拿到确定高度，否则内容区会只剩标签栏。
        height = "100%",
        flexGrow = 1,
        flexShrink = 1,
        flexBasis = 0,
        tabHeight = 40,
        tabGap = 4,
        enclosedPadding = 3,
        borderRadius = 8,
        fontSize = 13,
        variantContainerBgColor = {
            enclosed = {24, 20, 15, 245},
        },
        variantContainerBorderColor = {
            enclosed = {112, 78, 35, 190},
        },
        variantContainerBorderWidth = {
            enclosed = 1,
        },
        variantActiveBgColor = {
            enclosed = {105, 70, 27, 245},
        },
        variantInactiveBgColor = {
            enclosed = {35, 30, 24, 225},
        },
        variantActiveTextColor = {
            enclosed = {255, 221, 145, 255},
        },
        variantInactiveTextColor = {
            enclosed = {176, 168, 151, 220},
        },
        variantActiveBorderColor = {
            enclosed = {214, 155, 61, 225},
        },
        variantActiveBorderWidth = {
            enclosed = 1,
        },
        onChange = function(_, tabId)
            if options.onTabChanged then
                options.onTabChanged(NormalizeTab(tabId))
            end
        end,
    }

    tabs:SetTabContent("forge", BuildForgePage(options))
    tabs:SetTabContent("enhance", BuildEnhancePage(options))
    return tabs
end

return BlacksmithPanel
