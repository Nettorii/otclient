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
    position and ('F' .. tostring(position.z)) or 'F')
end

function View:_restoreFlagInput()
  if not self.map or self.map:isDestroyed() then
    return
  end
  for _, flag in pairs(self.map.flags or {}) do
    if flag.mobileDrawerOnMouseRelease then
      local currentFlag = flag
      flag.onMousePress = function()
        return true
      end
      flag.onMouseMove = function()
        return true
      end
      flag.onMouseRelease = function(widget, position, button)
        if button == MouseRightButton then
          return self:_showFlagDeleteModal(currentFlag)
        end
        return currentFlag.mobileDrawerOnMouseRelease(
          widget, position, button)
      end
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
    if button == MouseRightButton then
      widget.allowNextRelease = false
      local mapPosition = widget:getTilePosition(position)
      if mapPosition then
        self:_showFlagModal(mapPosition)
      end
      return true
    end
    UIMinimap.onMouseRelease(widget, position, button)
    self:_restoreFlagInput()
    return true
  end
  map.onClick = function()
    return true
  end
  self:_restoreFlagInput()
end

function View:_closeFlagModal()
  local handle = self.flagModal
  self.flagModal = nil
  if handle and handle.isOpen and handle:isOpen() then
    handle:close()
  end
end

function View:_showFlagModal(position)
  if not position or not self.map or self.map:isDestroyed() then
    return false
  end
  self:_closeFlagModal()

  local body = g_ui.createWidget('MobileMinimapMarkBody')
  local positionLabel =
    body:recursiveGetChildById('minimapMarkPosition')
  local description =
    body:recursiveGetChildById('minimapMarkDescription')
  local flags = body:recursiveGetChildById('minimapMarkFlags')
  assert(positionLabel and description and flags,
    'mobile minimap mark form is incomplete')
  positionLabel:setText(string.format(
    '%i, %i, %i', position.x, position.y, position.z))

  local selectedIcon = 0
  local flagButtons = {}
  local function selectIcon(icon)
    selectedIcon = icon
    for candidate, button in pairs(flagButtons) do
      button:setOn(candidate == icon)
    end
  end
  for icon = 0, 19 do
    local flagIcon = icon
    local button = g_ui.createWidget('MobileMinimapMarkFlag', flags)
    button:setId('minimapMarkFlag' .. tostring(flagIcon))
    button:setText(tostring(flagIcon + 1))
    button:setTooltip(tr('Map mark %d', flagIcon + 1))
    if button.setImageSource then
      button:setImageSource(
        '/images/game/minimap/flag' .. tostring(flagIcon))
    end
    button.onClick = function()
      selectIcon(flagIcon)
      return true
    end
    flagButtons[flagIcon] = button
  end
  selectIcon(0)

  local handle
  local function close()
    if handle and handle:isOpen() then
      handle:close()
    end
    return true
  end
  local function save()
    if not self.map or self.map:isDestroyed() then
      close()
      return false
    end
    self.map:addFlag(position, selectedIcon, description:getText())
    self:_restoreFlagInput()
    close()
    return true
  end
  handle = modules.client_mobileui.showModal({
    title = tr('Create Map Mark'),
    body = body,
    buttons = {
      { id = 'minimapMarkSave', text = tr('Save'), callback = save },
      { id = 'minimapMarkCancel', text = tr('Cancel'), callback = close }
    },
    onEnter = save,
    onEscape = close,
    onClose = function()
      if self.flagModal == handle then
        self.flagModal = nil
      end
    end
  })
  if not handle or not handle:isOpen() then
    if body and not body:isDestroyed() then
      body:destroy()
    end
    return false
  end
  self.flagModal = handle
  return true
end

function View:_showFlagDeleteModal(flag)
  if not flag or flag:isDestroyed() then
    return false
  end
  self:_closeFlagModal()

  local body = g_ui.createWidget('MobileMinimapDeleteBody')
  local message =
    body:recursiveGetChildById('minimapMarkDeleteMessage')
  assert(message, 'mobile minimap delete form is incomplete')
  local description = type(flag.description) == 'string' and
    flag.description or ''
  message:setText(description ~= '' and description or
    tr('Delete this map mark?'))

  local handle
  local function close()
    if handle and handle:isOpen() then
      handle:close()
    end
    return true
  end
  local function remove()
    if flag and not flag:isDestroyed() then
      flag:destroy()
    end
    close()
    return true
  end
  handle = modules.client_mobileui.showModal({
    title = tr('Delete Map Mark'),
    body = body,
    buttons = {
      { id = 'minimapMarkDelete', text = tr('Delete'), callback = remove },
      { id = 'minimapMarkDeleteCancel', text = tr('Cancel'), callback = close }
    },
    onEnter = remove,
    onEscape = close,
    onClose = function()
      if self.flagModal == handle then
        self.flagModal = nil
      end
    end
  })
  if not handle or not handle:isOpen() then
    if body and not body:isDestroyed() then
      body:destroy()
    end
    return false
  end
  self.flagModal = handle
  return true
end

function View:_layoutControls(width)
  if self.layingOut then
    return true
  end
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
  local origin = controls:getPosition()
  if self.layoutWidth == width and
      self.layoutX == origin.x and self.layoutY == origin.y and
      controls:getHeight() == controlsHeight then
    return true
  end
  self.layoutWidth = width
  self.layoutX = origin.x
  self.layoutY = origin.y
  self.layingOut = true
  controls:setWidth(width)
  controls:setHeight(controlsHeight)
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
  self.layingOut = false
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
  local controls = self:_widget('minimapControls')
  local previousControlsGeometryChange = controls.onGeometryChange
  controls.onGeometryChange = function(widget, ...)
    if previousControlsGeometryChange then
      previousControlsGeometryChange(widget, ...)
    end
    if self.root and not self.root:isDestroyed() then
      self:_layoutControls(self.root:getWidth())
      self.controlsLayoutGeneration =
        (self.controlsLayoutGeneration or 0) + 1
      local generation = self.controlsLayoutGeneration
      scheduleEvent(function()
        if self.controlsLayoutGeneration == generation and self.root and
            not self.root:isDestroyed() then
          self:_layoutControls(self.root:getWidth())
        end
      end)
    end
  end
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
  self.map.createFlagWindow = function(_, position)
    return self:_showFlagModal(position)
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
  self:_layoutControls(self.root:getWidth())
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
  self.controlsLayoutGeneration =
    (self.controlsLayoutGeneration or 0) + 1
  self:_closeFlagModal()
  self:onHide()
  if self.root and not self.root:isDestroyed() then
    self.root:destroy()
  end
  self.map = nil
  self.root = nil
  self.holder = nil
  self.layoutWidth = nil
  self.layoutX = nil
  self.layoutY = nil
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
