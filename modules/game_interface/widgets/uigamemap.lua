UIGameMap = extends(UIMap, 'UIGameMap')

function UIGameMap.create()
    local gameMap = UIGameMap.internalCreate()
    gameMap:setKeepAspectRatio(true)
    gameMap:setVisibleDimension({
        width = 15,
        height = 11
    })
    gameMap:setDrawLights(true)
    return gameMap
end

function UIGameMap:onDragEnter(mousePos)
    local tile = self:getTile(mousePos)
    if not tile then
        return false
    end

    local thing = tile:getTopMoveThing()
    if not thing then
        return false
    end

    if thing:isItem() and not thing:isNotMoveable() then
        UIDragIcon:display(thing)
    end

    self.currentDragThing = thing

    -- Use native cursor when enabled, otherwise use custom cursor
    if modules.client_options and modules.client_options.getOption('nativeCursor') then
        g_window.setSystemCursor('cross')
    else
        g_mouse.pushCursor('target')
    end
    self.allowNextRelease = false
    return true
end

function UIGameMap:onDragLeave(droppedWidget, mousePos)
    self.currentDragThing = nil
    self.hoveredWho = nil
    -- Restore cursor
    if modules.client_options and modules.client_options.getOption('nativeCursor') then
        g_window.restoreMouseCursor()
    else
        g_mouse.popCursor('target')
    end
    UIDragIcon:hide()
    return true
end

function UIGameMap:onDrop(widget, mousePos)
    if not self:canAcceptDrop(widget, mousePos) then
        return false
    end

    local tile = self:getTile(mousePos)
    if not tile then
        return false
    end

    local thing = widget.currentDragThing
    local thingPos = thing:getPosition()
    if not thingPos then
        return false
    end

    local thingTile = thing:getTile()
    if thingPos.x ~= 65535 then
        if not thingTile then
            return false
        end
        if thingTile:getThingStackPos(thing) == -1 then
            return false
        end
    end

    local toPos = tile:getPosition()
    if thingPos.x == toPos.x and thingPos.y == toPos.y and thingPos.z == toPos.z then
        return false
    end

    if thing:isItem() and thing:getCount() > 1 then
        modules.game_interface.moveStackableItem(thing, toPos)
    else
        g_game.move(thing, toPos, 1)
    end

    UIDragIcon:hide()
    return true
end

local function isMobileV2Enabled()
    return g_platform.isMobile() and modules.client_mobileui and
        modules.client_mobileui.isV2Enabled()
end

local function mobileV2BrowserWindowIsUnfocused()
    return isMobileV2Enabled() and g_window and g_window.hasFocus and
        g_window.getPlatformType and
        g_window.getPlatformType() == 'BROWSER-WEBGL' and
        not g_window.hasFocus()
end

function UIGameMap:onMousePress()
    if mobileV2BrowserWindowIsUnfocused() then
        self:cancelPendingRelease()
        return true
    end
    if not self:isDragging() then
        self.allowNextRelease = true
    end
end

function UIGameMap:cancelPendingRelease()
    self.allowNextRelease = false
end

function UIGameMap:onMouseMove()
    return false
end

local function topEligibleWidgetAt(widget, mousePosition, checkContainsPoint)
    if widget:isClipping() and
        not widget:containsPaddingPoint(mousePosition) then
        return nil
    end

    for index = widget:getChildCount(), 1, -1 do
        local child = widget:getChildByIndex(index)
        if child:isExplicitlyEnabled() and child:isExplicitlyVisible() then
            local eligible = topEligibleWidgetAt(child, mousePosition, true)
            if eligible then
                return eligible
            end
        end
    end

    if (not checkContainsPoint or widget:containsPoint(mousePosition)) and
        ((not widget:isPhantom() and not widget:isOnHtml()) or
            widget:isDraggable()) then
        return widget
    end
    return nil
end

local function isEffectivelyInputEligible(widget)
    local candidate = widget
    local current = widget
    -- UI propagation starts at the root regardless of its own flags, then
    -- requires every child on the selected branch to be explicitly active.
    while current and current:getParent() do
        if not current:isExplicitlyEnabled() or
            not current:isExplicitlyVisible() then
            return false
        end
        current = current:getParent()
    end
    return (not candidate:isPhantom() and not candidate:isOnHtml()) or
        candidate:isDraggable()
end

local function mobileV2InputBlocksMap(gameMap, mousePosition)
    if not isMobileV2Enabled() then
        return false
    end

    local state = modules.client_mobileui.getForeground()
    if state ~= 'gameplay' then
        return true
    end

    -- Match UIWidget::propagateOnMouseEvent: disabled/invisible subtrees do not
    -- participate, children are visited in reverse (topmost) order, and
    -- phantom/HTML-only widgets do not stop propagation unless draggable.
    local root = g_ui.getRootWidget()
    local top = root:recursiveGetChildByPos(mousePosition, false)
    if not top or not isEffectivelyInputEligible(top) then
        top = topEligibleWidgetAt(root, mousePosition, false)
    end
    while top do
        if top == gameMap then
            return false
        end
        top = top:getParent()
    end
    return true
end

function UIGameMap:onMouseRelease(mousePosition, mouseButton)
    if mobileV2BrowserWindowIsUnfocused() then
        self:cancelPendingRelease()
        return true
    end
    if not self.allowNextRelease then
        return true
    end

    -- Browser touch releases propagate through every eligible widget under the
    -- pointer. A gameplay control, drawer, chat, reconnecting screen, or modal
    -- owns that release ahead of the map even when its own handler declines it.
    if mobileV2InputBlocksMap(self, mousePosition) then
        self:cancelPendingRelease()
        return true
    end

    local autoWalkPos = self:getPosition(mousePosition)

    -- happens when clicking outside of map boundaries
    if not autoWalkPos then
        return false
    end

    local localPlayerPos = g_game.getLocalPlayer():getPosition()
    if autoWalkPos.z ~= localPlayerPos.z then
        local dz = autoWalkPos.z - localPlayerPos.z
        autoWalkPos.x = autoWalkPos.x + dz
        autoWalkPos.y = autoWalkPos.y + dz
        autoWalkPos.z = localPlayerPos.z
    end

    local lookThing
    local useThing
    local creatureThing
    local multiUseThing
    local attackCreature

    local tile = self:getTile(mousePosition)
    if tile then
        lookThing = tile:getTopLookThing()
        useThing = tile:getTopUseThing()
        creatureThing = tile:getTopCreature()
    end

    local autoWalkTile = g_map.getTile(autoWalkPos)
    if autoWalkTile then
        attackCreature = autoWalkTile:getTopCreature()
    end

    local ret = modules.game_interface.processMouseAction(mousePosition, mouseButton, autoWalkPos, lookThing, useThing,
        creatureThing, attackCreature)
    if ret then
        self.allowNextRelease = false
    end

    return ret
end

function UIGameMap:canAcceptDrop(widget, mousePos)
    if not widget or not widget.currentDragThing then
        return false
    end

    local children = rootWidget:recursiveGetChildrenByPos(mousePos)
    for i = 1, #children do
        local child = children[i]
        if child == self then
            return true
        elseif not child:isPhantom() then
            return false
        end
    end

    error('Widget ' .. self:getId() .. ' not in drop list.')
    return false
end
