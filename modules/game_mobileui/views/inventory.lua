MobileInventory = {}

local View = {}
View.__index = View

local SLOT_NAMES = {
  'Head', 'Neck', 'Back', 'Body', 'Right hand', 'Left hand',
  'Legs', 'Feet', 'Finger', 'Ammo', 'Purse'
}

local FIGHT_MODES = {
  { id = 'fightOffensive', text = 'Attack', value = FightOffensive },
  { id = 'fightBalanced', text = 'Balanced', value = FightBalanced },
  { id = 'fightDefensive', text = 'Defend', value = FightDefensive }
}

local CHASE_MODES = {
  { id = 'chaseStand', text = 'Stand', value = DontChase },
  { id = 'chaseFollow', text = 'Follow', value = ChaseOpponent }
}

local PVP_MODES = {
  { id = 'pvpDove', text = 'Dove', value = PVPWhiteDove },
  { id = 'pvpWhiteHand', text = 'White', value = PVPWhiteHand },
  { id = 'pvpYellowHand', text = 'Yellow', value = PVPYellowHand },
  { id = 'pvpRedFist', text = 'Red', value = PVPRedFist }
}

local BASE_ROOT_HEIGHT = 760
local BASE_CONTAINER_SECTION_HEIGHT = 242
local BASE_CONTAINER_DETAILS_HEIGHT = 158
local BASE_CONTAINER_ITEMS_HEIGHT = 52

local function setActive(button, active)
  if button then
    button:setOn(active == true)
  end
end

local function displayNumber(value)
  value = tonumber(value) or 0
  if value == math.floor(value) then
    return tostring(math.floor(value))
  end
  return tostring(value)
end

function View:_widget(id)
  return self.root and self.root:recursiveGetChildById(id) or nil
end

function View:_releaseDynamicGestures()
  for index = #self.dynamicGestureUnbinds, 1, -1 do
    self.dynamicGestureUnbinds[index]()
  end
  self.dynamicGestureUnbinds = {}
end

function View:_bindDynamic(widget)
  local mobile = modules.game_mobileui
  if not widget or not mobile or
      type(mobile.bindDrawerGestureWidget) ~= 'function' then
    return
  end
  local unbind = mobile.bindDrawerGestureWidget(widget)
  if type(unbind) == 'function' then
    self.dynamicGestureUnbinds[#self.dynamicGestureUnbinds + 1] = unbind
  end
end

function View:_positionInside(widget, position)
  return widget and position and
    position.x >= widget:getX() and
    position.x < widget:getX() + widget:getWidth() and
    position.y >= widget:getY() and
    position.y < widget:getY() + widget:getHeight()
end

function View:_isCurrentItemWidget(widget)
  return widget and not widget:isDestroyed() and
    widget:getClassName() == 'UIItem' and widget:isVisible() and
    widget:isEnabled() and widget:isDraggable() and
    widget.currentDragThing and
    widget.mobileInventoryBindingGeneration == self.itemBindingGeneration
end

function View:_installMapDropBridge()
  self:_removeMapDropBridge()
  local root = g_ui.getRootWidget()
  local backdrop = root and root:recursiveGetChildById('drawerBackdrop')
  local surface = backdrop and
    backdrop:recursiveGetChildById('drawerSurface')
  local gameMap = modules.game_interface and
    modules.game_interface.getMapPanel()
  if not backdrop or not surface or not gameMap then
    return
  end

  local binding = {
    backdrop = backdrop,
    surface = surface,
    gameMap = gameMap,
    previousDragEnter = backdrop.onDragEnter,
    previousDragLeave = backdrop.onDragLeave,
    previousDrop = backdrop.onDrop
  }
  binding.onDragEnter = function(widget, position)
    if not self:_positionInside(surface, position) then
      return true
    end
    return binding.previousDragEnter and
      binding.previousDragEnter(widget, position) or false
  end
  binding.onDragLeave = function(widget, droppedWidget, position)
    if not self:_positionInside(surface, position) then
      return true
    end
    return binding.previousDragLeave and
      binding.previousDragLeave(widget, droppedWidget, position) or false
  end
  binding.onDrop = function(widget, droppedWidget, position)
    if self:_positionInside(surface, position) or
        not self:_isCurrentItemWidget(droppedWidget) or
        not gameMap:containsPoint(position) then
      return binding.previousDrop and
        binding.previousDrop(widget, droppedWidget, position) or false
    end

    local wasPhantom = backdrop:isPhantom()
    backdrop:setPhantom(true)
    local ok, result = pcall(function()
      if not gameMap:canAcceptDrop(droppedWidget, position) then
        return false
      end
      return gameMap:onDrop(droppedWidget, position)
    end)
    if not backdrop:isDestroyed() then
      backdrop:setPhantom(wasPhantom)
    end
    if not ok then
      error(result, 0)
    end
    return result
  end
  backdrop.onDragEnter = binding.onDragEnter
  backdrop.onDragLeave = binding.onDragLeave
  backdrop.onDrop = binding.onDrop
  self.mapDropBinding = binding
end

function View:_removeMapDropBridge()
  local binding = self.mapDropBinding
  if not binding then
    return
  end
  self.mapDropBinding = nil
  local backdrop = binding.backdrop
  if backdrop and not backdrop:isDestroyed() then
    if backdrop.onDragEnter == binding.onDragEnter then
      backdrop.onDragEnter = binding.previousDragEnter
    end
    if backdrop.onDragLeave == binding.onDragLeave then
      backdrop.onDragLeave = binding.previousDragLeave
    end
    if backdrop.onDrop == binding.onDrop then
      backdrop.onDrop = binding.previousDrop
    end
  end
end

function View:_configureModeButtons()
  for _, mode in ipairs(FIGHT_MODES) do
    local button = self:_widget(mode.id)
    local modeValue = mode.value
    button.onClick = function()
      return self.inventory.setInventoryFightMode(modeValue)
    end
  end
  for _, mode in ipairs(CHASE_MODES) do
    local button = self:_widget(mode.id)
    local modeValue = mode.value
    button.onClick = function()
      return self.inventory.setInventoryChaseMode(modeValue)
    end
  end
  for _, mode in ipairs(PVP_MODES) do
    local button = self:_widget(mode.id)
    local modeValue = mode.value
    button.onClick = function()
      return self.inventory.setInventoryPVPMode(modeValue)
    end
  end
  self:_widget('safeFight').onClick = function()
    local snapshot = self.inventorySnapshot
    return snapshot and
      self.inventory.setInventorySafeFight(not snapshot.safeFight) or false
  end
end

function View:_createEquipmentItems()
  local panel = self:_widget('equipmentGrid')
  for slot = InventorySlotFirst, InventorySlotPurse do
    local item = g_ui.createWidget('MobileEquipmentItem', panel)
    item:setId('equipment' .. slot)
    item:setTooltip(SLOT_NAMES[slot] or tostring(slot))
    item:setDraggable(true)
    item.position = { x = 65535, y = slot, z = 0 }
    item.mobileInventoryBindingGeneration = self.itemBindingGeneration
    self.equipmentItems[slot] = item
  end
end

function View:create(parent)
  self.itemBindingGeneration = self.itemBindingGeneration + 1
  self.containerItems = {}
  self.holder = parent
  local content = parent:getParent()
  local width = content and content:getWidth() or parent:getWidth()
  parent:setWidth(width)
  parent:setHeight(BASE_ROOT_HEIGHT)
  self.root = g_ui.createWidget('MobileInventoryView', parent)
  self.root:setWidth(width)
  self:_createEquipmentItems()
  self:_configureModeButtons()
  return self.root
end

function View:_renderInventory(snapshot)
  self.inventorySnapshot = snapshot
  local available = snapshot and snapshot.available == true
  self:_widget('inventoryUnavailable'):setVisible(not available)
  self:_widget('inventorySummary'):setVisible(available)
  self:_widget('equipmentGrid'):setEnabled(available)
  self:_widget('combatSection'):setEnabled(available)

  if not snapshot then
    return
  end
  self:_widget('capacityValue'):setText(
    'Capacity ' .. displayNumber(snapshot.capacity))
  self:_widget('soulValue'):setText(
    'Soul ' .. displayNumber(snapshot.soul))

  for _, slotSnapshot in ipairs(snapshot.slots or {}) do
    local itemWidget = self.equipmentItems[slotSnapshot.slot]
    if itemWidget then
      itemWidget:setItem(slotSnapshot.item)
    end
  end
  for slot = InventorySlotFirst, InventorySlotPurse do
    local itemWidget = self.equipmentItems[slot]
    if itemWidget then
      local slotAvailable = available and
        (slot ~= InventorySlotPurse or snapshot.purseAvailable == true)
      local slotVisible = slot ~= InventorySlotPurse or
        snapshot.purseAvailable == true
      itemWidget:setVisible(slotVisible)
      itemWidget:setEnabled(slotAvailable)
      itemWidget:setDraggable(slotAvailable)
      itemWidget:setPhantom(not slotAvailable)
    end
  end
  for _, mode in ipairs(FIGHT_MODES) do
    setActive(self:_widget(mode.id), snapshot.fightMode == mode.value)
  end
  for _, mode in ipairs(CHASE_MODES) do
    setActive(self:_widget(mode.id), snapshot.chaseMode == mode.value)
  end
  setActive(self:_widget('safeFight'), snapshot.safeFight)

  local pvpPanel = self:_widget('pvpModes')
  pvpPanel:setVisible(snapshot.pvpModeAvailable == true)
  for _, mode in ipairs(PVP_MODES) do
    setActive(self:_widget(mode.id), snapshot.pvpMode == mode.value)
  end
end

function View:_findContainer(containerId)
  for _, snapshot in ipairs(self.containerSnapshots or {}) do
    if snapshot.id == containerId then
      return snapshot
    end
  end
  return nil
end

function View:_selectContainer(containerId)
  if not self:_findContainer(containerId) then
    return false
  end
  self.activeContainerId = containerId
  self:_renderContainers()
  return true
end

function View:_renderContainerStack()
  local stack = self:_widget('containerStack')
  stack:destroyChildren()
  for _, snapshot in ipairs(self.containerSnapshots) do
    local button = g_ui.createWidget('MobileContainerTab', stack)
    button:setId('containerTab' .. snapshot.id)
    button:setText(snapshot.name ~= '' and snapshot.name or
      ('Container ' .. snapshot.id))
    button:setOn(snapshot.id == self.activeContainerId)
    local containerId = snapshot.id
    button.onClick = function()
      return self:_selectContainer(containerId)
    end
  end
end

function View:_renderContainerItems(snapshot)
  local panel = self:_widget('containerItems')
  for _, item in ipairs(self.containerItems) do
    item.mobileInventoryBindingGeneration = nil
  end
  self.containerItems = {}
  panel:destroyChildren()
  local width = math.max(48, panel:getWidth())
  local columns = math.max(1, math.floor((width + 4) / 52))
  local rows = math.max(1, math.ceil(snapshot.capacity / columns))
  local itemsHeight = rows * 52
  panel:setHeight(itemsHeight)
  self:_widget('containerDetails'):setHeight(104 + itemsHeight)
  self:_widget('containersSection'):setHeight(184 + itemsHeight)
  local contentHeight = math.max(BASE_ROOT_HEIGHT, 650 + itemsHeight)
  self.root:setHeight(contentHeight)
  if self.holder then
    self.holder:setHeight(contentHeight)
  end
  for _, itemSnapshot in ipairs(snapshot.items) do
    local item = g_ui.createWidget('MobileContainerItem', panel)
    item:setId('containerItem' .. itemSnapshot.slot)
    item:setItem(itemSnapshot.item)
    item:setDraggable(true)
    item.position = itemSnapshot.position
    item.mobileInventoryBindingGeneration = self.itemBindingGeneration
    self.containerItems[#self.containerItems + 1] = item
  end
end

function View:_resetContainerLayout()
  local panel = self:_widget('containerItems')
  for _, item in ipairs(self.containerItems) do
    item.mobileInventoryBindingGeneration = nil
  end
  self.containerItems = {}
  panel:destroyChildren()
  panel:setHeight(BASE_CONTAINER_ITEMS_HEIGHT)
  self:_widget('containerDetails'):setHeight(
    BASE_CONTAINER_DETAILS_HEIGHT)
  self:_widget('containersSection'):setHeight(
    BASE_CONTAINER_SECTION_HEIGHT)
  self.root:setHeight(BASE_ROOT_HEIGHT)
  if self.holder then
    self.holder:setHeight(BASE_ROOT_HEIGHT)
  end
end

function View:_renderContainers()
  self:_releaseDynamicGestures()
  local snapshots = self.containerSnapshots or {}
  local empty = #snapshots == 0
  self:_widget('containersEmpty'):setVisible(empty)
  self:_widget('containerDetails'):setVisible(not empty)
  self:_renderContainerStack()

  if empty then
    self.activeContainerId = nil
    self:_resetContainerLayout()
    self:_bindDynamic(self:_widget('containerStack'))
    return
  end

  local active = self:_findContainer(self.activeContainerId)
  if not active then
    active = snapshots[#snapshots]
    self.activeContainerId = active.id
    self:_renderContainerStack()
  end

  self:_widget('containerBreadcrumb'):setText(
    'Open containers / ' .. active.name)
  local back = self:_widget('containerBack')
  back:setVisible(active.canGoBack)
  back.onClick = function()
    return self.containers.openParentContainer(active.id)
  end
  local close = self:_widget('containerClose')
  close.onClick = function()
    return self.containers.closeContainer(active.id)
  end

  local page = active.page
  self:_widget('containerPage'):setText(
    string.format('%d / %d', page.current, page.total))
  local previous = self:_widget('containerPrevious')
  previous:setEnabled(page.canPrevious)
  previous.onClick = function()
    if not page.canPrevious then
      return false
    end
    return self.containers.seekContainerPage(
      active.id, page.firstIndex - active.capacity)
  end
  local nextPage = self:_widget('containerNext')
  nextPage:setEnabled(page.canNext)
  nextPage.onClick = function()
    if not page.canNext then
      return false
    end
    return self.containers.seekContainerPage(
      active.id, page.firstIndex + active.capacity)
  end

  self:_renderContainerItems(active)
  self:_bindDynamic(self:_widget('containerStack'))
  self:_bindDynamic(self:_widget('containerDetails'))
end

function View:_onContainers(snapshots, change)
  self.containerSnapshots = snapshots or {}
  if change and (change.type == 'open' or change.type == 'page') then
    self.activeContainerId = change.containerId
  elseif change and change.type == 'close' and
      change.containerId == self.activeContainerId then
    self.activeContainerId = nil
  end
  self:_renderContainers()
end

function View:onShow()
  self:onHide()
  if not self.root or self.root:isDestroyed() then
    return false
  end
  self:_renderInventory(self.inventory.getInventorySnapshot())
  self:_onContainers(self.containers.getOpenContainerSnapshots())
  self:_installMapDropBridge()
  self.unsubscribeInventory = self.inventory.subscribeInventory(
    function(snapshot)
      if self.root and not self.root:isDestroyed() then
        self:_renderInventory(snapshot)
      end
    end)
  self.unsubscribeContainers = self.containers.subscribeContainers(
    function(snapshots, change)
      if self.root and not self.root:isDestroyed() then
        self:_onContainers(snapshots, change)
      end
    end)
  return true
end

function View:onHide()
  self:_removeMapDropBridge()
  if self.unsubscribeInventory then
    self.unsubscribeInventory()
    self.unsubscribeInventory = nil
  end
  if self.unsubscribeContainers then
    self.unsubscribeContainers()
    self.unsubscribeContainers = nil
  end
  self:_releaseDynamicGestures()
end

function View:destroy()
  self:onHide()
  if self.root and not self.root:isDestroyed() then
    self.root:destroy()
  end
  self.root = nil
  self.holder = nil
  self.equipmentItems = {}
  self.containerItems = {}
  self.inventorySnapshot = nil
  self.containerSnapshots = {}
  self.activeContainerId = nil
end

function MobileInventory.createDescriptor(options)
  options = options or {}
  local view = setmetatable({
    inventory = options.inventory or modules.game_inventory,
    containers = options.containers or modules.game_containers,
    equipmentItems = {},
    containerItems = {},
    itemBindingGeneration = 0,
    containerSnapshots = {},
    dynamicGestureUnbinds = {}
  }, View)
  return {
    title = 'Inventory',
    icon = '',
    create = function(parent) return view:create(parent) end,
    onShow = function() return view:onShow() end,
    onHide = function() view:onHide() end,
    destroy = function() view:destroy() end
  }
end
