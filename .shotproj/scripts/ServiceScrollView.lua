-- ============================================================================
-- ServiceScrollView.lua — 商店 / 铁匠服务面板的可拖动滚动容器
--
-- 引擎 ScrollView 默认只在 touch 指针上接管 PanStart，桌面预览用鼠标拖动
-- 时事件会继续落到列表按钮，表现为按钮被按住但列表不滚动。这里保留
-- 引擎组件的布局、滚动条和惯性逻辑，只在实例上补齐服务面板需要的交互。
-- ============================================================================

local UI = require("urhox-libs/UI")

local ServiceScrollView = {}

---@param props table?
---@return ScrollView
function ServiceScrollView.Build(props)
    props = props or {}

    -- 复制一份属性，避免修改调用方后续可能复用的配置表。
    local scrollProps = {}
    for key, value in pairs(props) do
        scrollProps[key] = value
    end

    scrollProps.scrollX = scrollProps.scrollX == true
    scrollProps.scrollY = scrollProps.scrollY ~= false
    scrollProps.bounces = false
    scrollProps.scrollbarInteractive = true
    scrollProps.showScrollbar = scrollProps.showScrollbar ~= false
    -- 让 ScrollView 在有限高度的服务面板中优先分配剩余空间。
    if scrollProps.minHeight == nil then
        scrollProps.minHeight = 0
    end

    local scroll = UI.ScrollView(scrollProps)
    local baseOnPointerCancel = scroll.OnPointerCancel
    local baseOnPointerUp = scroll.OnPointerUp

    -- 接管 touch、mouse、pen 三类指针的拖动；PanStart 会从按钮逐层冒泡
    -- 到这里，因此拖动列表项时不会触发误点击。
    function scroll:OnPanStart(event)
        local pointerType = event and event.pointerType
        if pointerType ~= "touch" and pointerType ~= "mouse" and pointerType ~= "pen" then
            return false
        end
        if not self.props.scrollX and not self.props.scrollY then
            return false
        end

        self:CancelSnap_()
        UI.CancelPointer(event.pointerId, event.pointerType)

        self.state.isDragging = true
        self.dragStartScrollX_ = self.state.scrollX
        self.dragStartScrollY_ = self.state.scrollY
        self.state.velocityX = 0
        self.state.velocityY = 0
        self.scrollbarOpacity_ = 1
        self.scrollbarFadeTimer_ = 1
        return true
    end

    function scroll:OnPanMove(event)
        if not self.state.isDragging then return end

        local dx = self.props.scrollX and -event.totalDeltaX or 0
        local dy = self.props.scrollY and -event.totalDeltaY or 0
        self:SetScroll(
            self.dragStartScrollX_ + dx,
            self.dragStartScrollY_ + dy
        )

        -- 保留引擎的惯性滚动，但 SetScroll 已关闭回弹，拖到底部后不会反复
        -- 拉回边界造成“卡住”的感觉。
        self.state.velocityX = -event.deltaX
        self.state.velocityY = -event.deltaY
        self.scrollbarOpacity_ = 1
        self.scrollbarFadeTimer_ = 1
    end

    function scroll:OnPanEnd()
        self.state.isDragging = false
    end

    function scroll:OnPointerUp(event)
        self.state.isDragging = false
        if baseOnPointerUp then
            baseOnPointerUp(self, event)
        end
    end

    -- 某些系统事件会直接取消指针而不经过普通 PanEnd；清掉全部拖动状态，
    -- 避免下一次打开服务面板时滚动容器永久处于“按住”状态。
    function scroll:OnPointerCancel(event)
        self.state.isDragging = false
        self.state.velocityX = 0
        self.state.velocityY = 0
        self.isDraggingScrollbarV_ = false
        self.isDraggingScrollbarH_ = false
        self:CancelSnap_()
        if baseOnPointerCancel then
            baseOnPointerCancel(self, event)
        end
    end

    return scroll
end

return ServiceScrollView
