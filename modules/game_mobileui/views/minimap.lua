MobileMinimapDrawer = {}

local View = {}
View.__index = View

local CONTROL_SIZE = 48
local MAP_HEIGHT = 222
local SECTION_SPACING = 6
local CONTROL_IDS = {
  'minimapZoomOut',
  'minimapCenter',
  'minimapZoomIn',
  'minimapFloorUp',
  'minimapFloorValue',
  'minimapFloorDown'
}

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

function View:_layoutControls(width)
  width = math.floor(tonumber(width) or 0)
  if width < CONTROL_SIZE then
    return false
  end
  local controls = self:_widget('minimapControls')
  if not controls then
    return false
  end
  local columns = math.max(1, math.min(
    #CONTROL_IDS, math.floor(width / CONTROL_SIZE)))
  local rows = math.ceil(#CONTROL_IDS / columns)
  local controlsHeight = rows * CONTROL_SIZE
  if self.layoutWidth == width and
      controls:getHeight() == controlsHeight then
    return true
  end
  self.layoutWidth = width
  controls:setWidth(width)
  controls:setHeight(controlsHeight)
  local origin = controls:getPosition()
  for index, id in ipairs(CONTROL_IDS) do
    local control = self:_widget(id)
    if control then
      local offset = index - 1
      control:setRect({
        x = origin.x + (offset % columns) * CONTROL_SIZE,
        y = origin.y + math.floor(offset / columns) * CONTROL_SIZE,
        width = CONTROL_SIZE,
        height = CONTROL_SIZE
      })
    end
  end
  local height = MAP_HEIGHT + SECTION_SPACING + controlsHeight
  self.root:setHeight(height)
  self.root:setVisible(true)
  if self.holder then
    self.holder:setHeight(height)
  end
  return true
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
  local width = content and content:getWidth() or parent:getWidth()
  parent:setWidth(width)
  if width < CONTROL_SIZE then
    parent:setHeight(0)
    return nil
  end
  self.root = g_ui.createWidget('MobileMinimapView', parent)
  self.root:setWidth(width)
  if not self:_layoutControls(width) then
    self.root:destroy()
    self.root = nil
    parent:setHeight(0)
    return nil
  end
  local previousGeometryChange = self.root.onGeometryChange
  self.root.onGeometryChange = function(widget, ...)
    if previousGeometryChange then
      previousGeometryChange(widget, ...)
    end
    local nextWidth = widget:getWidth()
    if nextWidth < CONTROL_SIZE then
      self.layoutWidth = nil
      widget:setVisible(false)
      if self.holder then
        self.holder:setHeight(0)
      end
      return
    end
    self:_layoutControls(nextWidth)
  end
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
  self.layoutWidth = nil
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
