local iconTopMenu = nil
-- @ Minimap
local minimapWidget = nil -- bot fix
local otmm = true
local oldPos = nil
local fullscreenWidget
local drawerMinimapState = nil
local drawerMinimapSessionActive = false
local drawerMinimapSessionGeneration = 0
local virtualFloor = 7
local currentDayTime = {
    h = 12,
    m = 0
}

local function copyPosition(position)
    if not position then
        return nil
    end
    return {
        x = position.x,
        y = position.y,
        z = position.z
    }
end

local function desktopMinimap()
    return mapController and mapController.ui and
        mapController.ui.minimapBorder and
        mapController.ui.minimapBorder.minimap or nil
end

local function configureDrawerFlag(widget, flag, source)
    if not flag or flag.mobileDrawerConfigured then
        return flag
    end
    flag.mobileDrawerConfigured = true
    flag.mobileDrawerOnMouseRelease = flag.onMouseRelease
    local previousDestroy = flag.onDestroy
    flag.onDestroy = function(...)
        if previousDestroy then
            previousDestroy(...)
        end
        if not widget.mobileDrawerDestroying and
            not widget.mobileDrawerSyncing and source and
            not source:isDestroyed() then
            source:removeFlag(flag.pos, flag.icon, flag.description)
        end
    end
    return flag
end

local function configureDrawerFlags(widget, source)
    for _, flag in pairs(widget.flags or {}) do
        configureDrawerFlag(widget, flag, source)
    end
end

function createDrawerMinimap(parent)
    if not parent then
        return nil
    end
    local widget = g_ui.createWidget('MobileDrawerMinimap', parent)
    if not widget then
        return nil
    end

    local source = desktopMinimap()
    widget.mobileDrawerSource = source
    widget.mobileDrawerSessionGeneration = drawerMinimapSessionGeneration
    local baseAddFlag = widget.addFlag
    widget.addFlag = function(self, position, icon, description, temporary)
        self.mobileDrawerSyncing = true
        baseAddFlag(self, copyPosition(position), icon, description, temporary)
        self.mobileDrawerSyncing = false
        local flag = self:getFlag(position)
        configureDrawerFlag(self, flag, self.mobileDrawerSource)
        if not temporary and self.mobileDrawerSource and
            not self.mobileDrawerSource:isDestroyed() and
            not self.mobileDrawerSource:getFlag(position) then
            self.mobileDrawerSource:addFlag(
                copyPosition(position), icon, description)
        end
        return flag
    end

    widget.mobileDrawerSyncing = true
    if source and source.flags then
        for _, flag in pairs(source.flags) do
            baseAddFlag(widget, copyPosition(flag.pos), flag.icon,
                flag.description, flag.temporary)
        end
    end
    widget.mobileDrawerSyncing = false
    configureDrawerFlags(widget, source)

    for _, id in ipairs({
        'floorUpButton', 'floorDownButton', 'zoomInButton',
        'zoomOutButton', 'resetButton'
    }) do
        local control = widget:getChildById(id)
        if control then
            control:hide()
        end
    end

    local initial = drawerMinimapState
    if not initial and source then
        initial = {
            camera = copyPosition(source:getCameraPosition()),
            zoom = source:getZoom()
        }
    end
    local player = g_game.getLocalPlayer()
    local camera = initial and initial.camera or
        (player and copyPosition(player:getPosition()) or nil)
    if initial and initial.zoom ~= nil then
        widget:setZoom(initial.zoom)
    end
    if camera then
        widget:setCameraPosition(camera)
    end
    if player then
        widget:setCrossPosition(copyPosition(player:getPosition()))
    end
    return widget
end

function releaseDrawerMinimap(widget)
    if not widget or widget:isDestroyed() then
        return false
    end
    if drawerMinimapSessionActive and
        widget.mobileDrawerSessionGeneration ==
            drawerMinimapSessionGeneration then
        drawerMinimapState = {
            camera = copyPosition(widget:getCameraPosition()),
            zoom = widget:getZoom()
        }
    end
    widget.mobileDrawerDestroying = true
    widget:destroy()
    return true
end

function zoomDrawerMinimap(widget, direction)
    if not widget or widget:isDestroyed() then
        return false
    end
    if direction == 1 then
        return widget:zoomIn()
    elseif direction == -1 then
        return widget:zoomOut()
    end
    return false
end

function floorDrawerMinimap(widget, direction)
    if not widget or widget:isDestroyed() then
        return false
    end
    if direction == -1 then
        return widget:floorUp(1)
    elseif direction == 1 then
        return widget:floorDown(1)
    end
    return false
end

function centerDrawerMinimap(widget)
    if not widget or widget:isDestroyed() then
        return false
    end
    widget:reset()
    local player = g_game.getLocalPlayer()
    if player then
        widget:setCrossPosition(copyPosition(player:getPosition()))
    end
    return true
end

local function refreshVirtualFloors()
    mapController.ui.layersPanel.layersMark:setMarginTop(((virtualFloor + 1) * 4) - 3)
    mapController.ui.layersPanel.automapLayers:setImageClip((virtualFloor * 14) .. ' 0 14 67')
end

local function onPositionChange()
    local player = g_game.getLocalPlayer()
    if not player then
        return
    end

    local pos = player:getPosition()
    if not pos then
        return
    end

    local minimapWidget = mapController.ui.minimapBorder.minimap
    if not (minimapWidget) or minimapWidget:isDragging() then
        return
    end

    if not minimapWidget.fullMapView then
        minimapWidget:setCameraPosition(pos)
    end

    minimapWidget:setCrossPosition(pos)
    virtualFloor = pos.z
    refreshVirtualFloors()
end

mapController = Controller:new()
mapController:setUI('minimap', modules.game_interface.getMainRightPanel())

function onChangeWorldTime(hour, minute)
--[[ 

check 
tfs c++ (old) : void ProtocolGame::sendWorldTime()
tfs lua (new) : function Player.sendWorldTime(self, time)
Canary: void ProtocolGame::sendTibiaTime(int32_t time)
 ]]

    currentDayTime = {
        h = hour % 24,
        m = minute
    }

    mapController:scheduleEvent(function()
        local nextH = currentDayTime.h
        local nextM = currentDayTime.m + 12
        if nextM >= 60 then
            nextH = nextH + 1
            nextM = nextM - 60
        end

        onChangeWorldTime(nextH, nextM)
    end, 30000, 'dayTime')

    local position = math.floor((124 / (24 * 60)) * ((hour * 60) + minute))
    local mainWidth = 31
    local secondaryWidth = 0

    if (position + 31) >= 124 then
        secondaryWidth = ((position + 31) - 124) + 1
        mainWidth = 31 - secondaryWidth
    end

    mapController.ui.rosePanel.ambients.main:setWidth(mainWidth)
    mapController.ui.rosePanel.ambients.secondary:setWidth(secondaryWidth)

    if secondaryWidth == 0 then
        mapController.ui.rosePanel.ambients.secondary:hide()
    else
        mapController.ui.rosePanel.ambients.secondary:setImageClip('0 0 ' .. secondaryWidth .. ' 31')
        mapController.ui.rosePanel.ambients.secondary:show()
    end

    if mainWidth == 0 then
        mapController.ui.rosePanel.ambients.main:hide()
    else
        mapController.ui.rosePanel.ambients.main:setImageClip(position .. ' 0 ' .. mainWidth .. ' 31')
        mapController.ui.rosePanel.ambients.main:show()
    end
end

function mapController:onInit()
    self.ui.minimapBorder.minimap:getChildById('floorUpButton'):hide()
    self.ui.minimapBorder.minimap:getChildById('floorDownButton'):hide()
    self.ui.minimapBorder.minimap:getChildById('zoomInButton'):hide()
    self.ui.minimapBorder.minimap:getChildById('zoomOutButton'):hide()
    self.ui.minimapBorder.minimap:getChildById('resetButton'):hide()
end

function mapController:onGameStart()
    drawerMinimapSessionGeneration = drawerMinimapSessionGeneration + 1
    drawerMinimapSessionActive = true
    drawerMinimapState = nil
    mapController:registerEvents(g_game, {
        onChangeWorldTime = onChangeWorldTime
    })

    mapController:registerEvents(LocalPlayer, {
        onPositionChange = onPositionChange
    }):execute()

    -- Load Map
    g_minimap.clean()

    local minimapFile = '/minimap'
    local loadFnc = nil

    if otmm then
        minimapFile = minimapFile .. '.otmm'
        loadFnc = g_minimap.loadOtmm
    else
        minimapFile = minimapFile .. '_' .. g_game.getClientVersion() .. '.otcm'
        loadFnc = g_map.loadOtcm
    end

    if g_resources.fileExists(minimapFile) then
        loadFnc(minimapFile)
    end

    self.ui.minimapBorder.minimap:load()
end

function mapController:onGameEnd()
    drawerMinimapSessionActive = false
    drawerMinimapState = nil
    -- Save Map
    if otmm then
        g_minimap.saveOtmm('/minimap.otmm')
    else
        g_map.saveOtcm('/minimap_' .. g_game.getClientVersion() .. '.otcm')
    end

    self.ui.minimapBorder.minimap:save()
end

function mapController:onTerminate()
    drawerMinimapSessionActive = false
    drawerMinimapSessionGeneration = drawerMinimapSessionGeneration + 1
    drawerMinimapState = nil
    if iconTopMenu then
        iconTopMenu:destroy()
        iconTopMenu = nil
    end
end

function zoomIn()
    mapController.ui.minimapBorder.minimap:zoomIn()
end

function zoomOut()
    mapController.ui.minimapBorder.minimap:zoomOut()
end

function openCyclopediaMap()
    if g_game.getClientVersion() >= 1310 then
        modules.game_cyclopedia.toggle('map')
    else
        return fullscreen()
    end
end

function fullscreen()
    local minimapWidget = mapController.ui.minimapBorder.minimap
    if not minimapWidget then
        minimapWidget = fullscreenWidget
    end
    local zoom;

    if not minimapWidget then
        return
    end

    if minimapWidget.fullMapView then
        fullscreenWidget = nil
        minimapWidget:setParent(mapController.ui.minimapBorder)
        minimapWidget:fill('parent')
        mapController.ui:show()
        zoom = minimapWidget.zoomMinimap
        g_keyboard.unbindKeyDown('Escape')
        minimapWidget.fullMapView = false
    else
        fullscreenWidget = minimapWidget
        mapController.ui:hide(true)
        minimapWidget:setParent(modules.game_interface.getRootPanel())
        minimapWidget:fill('parent')
        zoom = minimapWidget.zoomFullmap
        g_keyboard.bindKeyDown('Escape', fullscreen)
        minimapWidget.fullMapView = true
    end

    local pos = oldPos or minimapWidget:getCameraPosition()
    oldPos = minimapWidget:getCameraPosition()
    minimapWidget:setZoom(zoom)
    minimapWidget:setCameraPosition(pos)
end

function upLayer()
    if virtualFloor == 0 then
        return
    end

    mapController.ui.minimapBorder.minimap:floorUp(1)
    virtualFloor = virtualFloor - 1
    refreshVirtualFloors()
end

function downLayer()
    if virtualFloor == 15 then
        return
    end

    mapController.ui.minimapBorder.minimap:floorDown(1)
    virtualFloor = virtualFloor + 1
    refreshVirtualFloors()
end

function onClickRoseButton(dir)
    if dir == 'north' then
        mapController.ui.minimapBorder.minimap:move(0, 1)
    elseif dir == 'north-east' then
        mapController.ui.minimapBorder.minimap:move(-1, 1)
    elseif dir == 'east' then
        mapController.ui.minimapBorder.minimap:move(-1, 0)
    elseif dir == 'south-east' then
        mapController.ui.minimapBorder.minimap:move(-1, -1)
    elseif dir == 'south' then
        mapController.ui.minimapBorder.minimap:move(0, -1)
    elseif dir == 'south-west' then
        mapController.ui.minimapBorder.minimap:move(1, -1)
    elseif dir == 'west' then
        mapController.ui.minimapBorder.minimap:move(1, 0)
    elseif dir == 'north-west' then
        mapController.ui.minimapBorder.minimap:move(1, 1)
    end
end

function resetMap()
    mapController.ui.minimapBorder.minimap:reset()
    local player = g_game.getLocalPlayer()
    if player then
        virtualFloor = player:getPosition().z
        refreshVirtualFloors()
    end
end

function getMiniMapUi()
    return mapController.ui.minimapBorder.minimap
end

function extendedView(extendedView)
    if extendedView then
        if not iconTopMenu then
            iconTopMenu = modules.client_topmenu.addTopRightToggleButton('miniMap', tr('Show miniMap'),
                '/images/topbuttons/minimap', toggle)
            iconTopMenu:setOn(mapController.ui:isVisible())
            mapController.ui:setBorderColor('black')
            mapController.ui:setBorderWidth(2)
        end
    else
        if iconTopMenu then
            iconTopMenu:destroy()
            iconTopMenu = nil
        end
        mapController.ui:setBorderColor('alpha')
        mapController.ui:setBorderWidth(0)
        local mainRightPanel = modules.game_interface.getMainRightPanel()
        if not mainRightPanel:hasChild(mapController.ui) then
            mainRightPanel:insertChild(1, mapController.ui)
        end
        mapController.ui:show()

    end
    mapController.ui.moveOnlyToMain = not extendedView
end

function toggle()
    if iconTopMenu:isOn() then
        mapController.ui:hide()
        iconTopMenu:setOn(false)
    else
        mapController.ui:show()
        iconTopMenu:setOn(true)
    end
end
