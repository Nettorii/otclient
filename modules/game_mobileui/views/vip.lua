MobileVip = {}

local View = {}
View.__index = View

local ROW_HEIGHT = 56
local GROUP_HEADER_HEIGHT = 48

local function positionFor(widget, position)
  return position or (widget and widget:getPosition()) or { x = 0, y = 0 }
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

function View:_showEntryMenu(entry, widget, position)
  local menu = g_ui.createWidget('PopupMenu')
  menu:setGameMenu(true)
  if entry.canMessage then
    menu:addOption(tr('Message to %s', entry.name), function()
      return self.vip.messageVipEntry(entry.id)
    end)
  end
  if entry.canEdit then
    menu:addOption(tr('Edit %s', entry.name), function()
      return self.vip.editVipEntry(entry.id)
    end)
  end
  if entry.canRemove then
    menu:addOption(tr('Remove %s', entry.name), function()
      return self.vip.removeVipEntry(entry.id)
    end)
  end
  menu:display(positionFor(widget, position))
  return true
end

function View:_showGroupMenu(group, widget, position)
  local menu = g_ui.createWidget('PopupMenu')
  menu:setGameMenu(true)
  if group.editable then
    menu:addOption(tr('Edit group %s', group.name), function()
      return self.vip.editVipGroup(group.id)
    end)
    menu:addOption(tr('Remove group %s', group.name), function()
      return self.vip.removeVipGroup(group.id)
    end)
    menu:addSeparator()
  end
  menu:addOption(tr('Add new group'), function()
    return self.vip.addVipGroup()
  end)
  menu:display(positionFor(widget, position))
  return true
end

function View:_configureControls()
  self:_widget('vipAdd').onClick = function()
    return self.vip.addVipEntry()
  end
  self:_widget('vipGroups').onClick = function()
    return self.vip.addVipGroup()
  end
end

local function containsGroup(entry, groupId)
  for _, entryGroupId in ipairs(entry.groups or {}) do
    if tostring(entryGroupId) == tostring(groupId) then
      return true
    end
  end
  return false
end

function View:_groupedEntries(snapshot)
  local visibleEntries = {}
  for _, entry in ipairs(snapshot.entries) do
    if not snapshot.hideOffline or entry.online then
      visibleEntries[#visibleEntries + 1] = entry
    end
  end
  if not snapshot.groupsAvailable then
    return {
      {
        key = 'all',
        id = nil,
        name = tr('VIPs'),
        editable = false,
        entries = visibleEntries
      }
    }
  end

  local groups = {}
  for _, group in ipairs(snapshot.groups) do
    local described = {
      key = tostring(group.id),
      id = group.id,
      name = group.name,
      editable = group.editable,
      entries = {}
    }
    for _, entry in ipairs(visibleEntries) do
      if containsGroup(entry, group.id) then
        described.entries[#described.entries + 1] = entry
      end
    end
    groups[#groups + 1] = described
  end
  local ungrouped = {
    key = 'ungrouped',
    id = nil,
    name = tr('Ungrouped'),
    editable = false,
    entries = {}
  }
  for _, entry in ipairs(visibleEntries) do
    if #(entry.groups or {}) == 0 then
      ungrouped.entries[#ungrouped.entries + 1] = entry
    end
  end
  if #ungrouped.entries > 0 or #groups == 0 then
    groups[#groups + 1] = ungrouped
  end
  return groups
end

function View:_createEntry(parent, group, entry)
  local row = g_ui.createWidget('MobileVipRow', parent)
  row:setId('vipRow_' .. group.key .. '_' .. tostring(entry.id))
  row:getChildById('state'):setText(
    entry.online and tr('Online') or tr('Offline'))
  row:getChildById('state'):setColor(
    entry.online and '#7de27d' or '#df8686')
  row:getChildById('name'):setText(entry.name)
  row:getChildById('description'):setText(
    entry.description ~= '' and entry.description or tr('No description'))
  row:getChildById('description'):setTooltip(entry.description)
  local actions = row:getChildById('actions')
  actions.onClick = function(widget, position)
    return self:_showEntryMenu(entry, widget, position)
  end
  row.onClick = function(widget, position)
    return self:_showEntryMenu(entry, widget, position)
  end
  self:_bindDynamic(row)
end

function View:_createGroup(parent, group)
  local groupWidget = g_ui.createWidget('MobileVipGroup', parent)
  groupWidget:setId('vipGroup_' .. group.key)
  groupWidget:recursiveGetChildById('groupName'):setText(group.name)
  local actions = groupWidget:recursiveGetChildById('groupActions')
  actions:setId('groupActions_' .. group.key)
  actions:setVisible(group.id ~= nil)
  actions.onClick = function(widget, position)
    return self:_showGroupMenu(group, widget, position)
  end
  local header = groupWidget:recursiveGetChildById('groupHeader')
  header.onClick = function(widget, position)
    if group.id == nil then
      return false
    end
    return self:_showGroupMenu(group, widget, position)
  end
  local rows = groupWidget:recursiveGetChildById('groupRows')
  for _, entry in ipairs(group.entries) do
    self:_createEntry(rows, group, entry)
  end
  local rowsHeight = #group.entries * ROW_HEIGHT
  rows:setHeight(rowsHeight)
  groupWidget:setHeight(GROUP_HEADER_HEIGHT + rowsHeight)
  self:_bindDynamic(groupWidget)
  return GROUP_HEADER_HEIGHT + rowsHeight
end

function View:_render(snapshot)
  self.snapshot = snapshot
  self:_releaseDynamicGestures()
  local list = self:_widget('vipGroupsList')
  list:destroyChildren()
  local available = snapshot and snapshot.available == true
  local entries = {}
  for _, entry in ipairs(available and snapshot.entries or {}) do
    if not snapshot.hideOffline or entry.online then
      entries[#entries + 1] = entry
    end
  end
  local empty = #entries == 0
  local emptyLabel = self:_widget('vipEmpty')
  emptyLabel:setText(available and tr('VIP list is empty') or
    tr('VIP list unavailable'))
  emptyLabel:setVisible(empty)
  list:setVisible(not empty)
  self:_widget('vipGroups'):setEnabled(
    available and snapshot.groupsAvailable == true)

  local listHeight = 0
  if available and not empty then
    for _, group in ipairs(self:_groupedEntries(snapshot)) do
      listHeight = listHeight + self:_createGroup(list, group)
    end
  end
  list:setHeight(math.max(ROW_HEIGHT, listHeight))
  local rootHeight = ROW_HEIGHT + math.max(ROW_HEIGHT, listHeight) + 6
  self.root:setHeight(rootHeight)
  if self.holder then
    self.holder:setHeight(rootHeight)
  end
end

function View:create(parent)
  self.holder = parent
  local content = parent:getParent()
  parent:setWidth(content and content:getWidth() or parent:getWidth())
  self.root = g_ui.createWidget('MobileVipView', parent)
  self.root:setWidth(parent:getWidth())
  self:_configureControls()
  return self.root
end

function View:onShow()
  self:onHide()
  if not self.root or self.root:isDestroyed() then
    return false
  end
  self:_render(self.vip.getVipSnapshot())
  self.unsubscribe = self.vip.subscribeVips(function(snapshot)
    if self.root and not self.root:isDestroyed() then
      self:_render(snapshot)
    end
  end)
  return true
end

function View:onHide()
  if self.unsubscribe then
    self.unsubscribe()
    self.unsubscribe = nil
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
  self.snapshot = nil
end

function MobileVip.createDescriptor(options)
  options = options or {}
  local view = setmetatable({
    vip = options.vip or modules.game_viplist,
    dynamicGestureUnbinds = {}
  }, View)
  return {
    title = 'VIP',
    icon = '',
    create = function(parent) return view:create(parent) end,
    onShow = function() return view:onShow() end,
    onHide = function() view:onHide() end,
    destroy = function() view:destroy() end
  }
end
