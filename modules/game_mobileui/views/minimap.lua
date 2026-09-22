MobileMinimapDrawer = {}

local View = {}
View.__index = View

function View:_widget(id)
  return self.root and self.root:recursiveGetChildById(id) or nil
end

function View:_updateFloor()
  if not self.map or self.map:isDestroyed() then
    return
  end
  local position = self.map:getCameraPosition()
  self:_widget('minimapFloorValue'):setText(
    position and ('Floor ' .. tostring(position.z)) or 'Floor')
end

function View:_restoreFlagInput()
  if not self.map or self.map:isDestroyed() then
    return
  end
  for _, flag in pairs(self.map.flags or {}) do
    if flag.mobileDrawerOnMouseRelease then
      flag.onMousePress = function()
        return true
      end
      flag.onMouseMove = function()
        return true
      end
      flag.onMouseRelease = flag.mobileDrawerOnMouseRelease
    end
  end
end

function View:_isolateMapInput()
  local map = self.map
  if not map or map:isDestroyed() then
    return
  end
  map.onMousePress = function(widget, position, button)
    UIMinimap.onMousePress(widget, position, button)
    return true
  end
  map.onMouseMove = function()
    return true
  end
  map.onMouseRelease = function(widget, position, button)
    UIMinimap.onMouseRelease(widget, position, button)
    self:_restoreFlagInput()
    return true
  end
  map.onClick = function()
    return true
  end
  self:_restoreFlagInput()
end

function View:_configureControls()
  self:_widget('minimapZoomOut').onClick = function()
    return self.minimap.zoomDrawerMinimap(self.map, -1)
  end
  self:_widget('minimapZoomIn').onClick = function()
    return self.minimap.zoomDrawerMinimap(self.map, 1)
  end
  self:_widget('minimapCenter').onClick = function()
    local accepted = self.minimap.centerDrawerMinimap(self.map)
    self:_updateFloor()
    return accepted
  end
  self:_widget('minimapFloorUp').onClick = function()
    local accepted = self.minimap.floorDrawerMinimap(self.map, -1)
    self:_updateFloor()
    return accepted
  end
  self:_widget('minimapFloorDown').onClick = function()
    local accepted = self.minimap.floorDrawerMinimap(self.map, 1)
    self:_updateFloor()
    return accepted
  end
end

function View:create(parent)
  self.holder = parent
  local content = parent:getParent()
  parent:setWidth(content and content:getWidth() or parent:getWidth())
  parent:setHeight(330)
  self.root = g_ui.createWidget('MobileMinimapView', parent)
  self.root:setWidth(parent:getWidth())
  self.map = self.minimap.createDrawerMinimap(
    self:_widget('mobileMinimapHost'))
  if not self.map then
    return self.root
  end

  local previousCameraChange = self.map.onCameraPositionChange
  self.map.onCameraPositionChange = function(widget, position, oldPosition)
    if previousCameraChange then
      previousCameraChange(widget, position, oldPosition)
    end
    self:_updateFloor()
  end
  self:_configureControls()
  self:_updateFloor()
  return self.root
end

function View:onShow()
  if not self.root or self.root:isDestroyed() or
      not self.map or self.map:isDestroyed() then
    return false
  end
  self.released = false
  self:_isolateMapInput()
  self:_updateFloor()
  return true
end

function View:onHide()
  if not self.released and self.map and not self.map:isDestroyed() then
    self.released = true
    self.minimap.releaseDrawerMinimap(self.map)
  end
end

function View:destroy()
  self:onHide()
  if self.root and not self.root:isDestroyed() then
    self.root:destroy()
  end
  self.map = nil
  self.root = nil
  self.holder = nil
end

function MobileMinimapDrawer.createDescriptor(options)
  options = options or {}
  local view = setmetatable({
    minimap = options.minimap or modules.game_minimap
  }, View)
  return {
    title = 'Minimap',
    icon = '',
    create = function(parent) return view:create(parent) end,
    onShow = function() return view:onShow() end,
    onHide = function() view:onHide() end,
    destroy = function() view:destroy() end
  }
end
