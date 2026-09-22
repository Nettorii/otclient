MobileBattle = {}

local View = {}
View.__index = View

local ROW_HEIGHT = 56
local LONG_PRESS_MILLIS = 400

local FILTER_OPTIONS = {
  { id = 'hidePlayers', text = 'Hide players' },
  { id = 'hideNPCs', text = 'Hide NPCs' },
  { id = 'hideMonsters', text = 'Hide monsters' },
  { id = 'hideSkulls', text = 'Hide players without skulls' },
  { id = 'hideParty', text = 'Hide party members' },
  { id = 'hideKnights', text = 'Hide knights' },
  { id = 'hidePaladins', text = 'Hide paladins' },
  { id = 'hideDruids', text = 'Hide druids' },
  { id = 'hideSorcerers', text = 'Hide sorcerers' },
  { id = 'hideMonks', text = 'Hide monks' },
  { id = 'hideSummons', text = 'Hide summons' },
  { id = 'hideMembersOwnGuild', text = 'Hide guild members' }
}

local SORT_OPTIONS = {
  { id = 'sortAscByDisplayTime', text = 'Display time ascending' },
  { id = 'sortDescByDisplayTime', text = 'Display time descending' },
  { id = 'sortAscByDistance', text = 'Distance ascending' },
  { id = 'sortDescByDistance', text = 'Distance descending' },
  { id = 'sortAscByHitPoints', text = 'Health ascending' },
  { id = 'sortDescByHitPoints', text = 'Health descending' },
  { id = 'sortAscByName', text = 'Name ascending' },
  { id = 'sortDescByName', text = 'Name descending' }
}

local function menuPosition(widget, position)
  if position then
    return position
  end
  return widget and widget:getPosition() or { x = 0, y = 0 }
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

function View:_showOptions(widget, position, options)
  local menu = g_ui.createWidget('PopupMenu')
  menu:setGameMenu(true)
  local filters = self.snapshot and self.snapshot.filters or {}
  for _, option in ipairs(options) do
    local id = option.id
    local label = tr(option.text)
    if filters[id] then
      label = '[x] ' .. label
    end
    menu:addOption(label, function()
      return self.battle.toggleBattleOption(id)
    end)
  end
  menu:display(menuPosition(widget, position))
  return true
end

function View:_configureControls()
  local filter = self:_widget('battleFilter')
  filter.onClick = function(widget, position)
    return self:_showOptions(widget, position, FILTER_OPTIONS)
  end
  local sort = self:_widget('battleSort')
  sort.onClick = function(widget, position)
    return self:_showOptions(widget, position, SORT_OPTIONS)
  end
end

function View:_configureRow(row, description)
  local id = description.id
  row:setId('battleRow_' .. tostring(id))
  row:setOn(description.currentTarget == true)
  row:getChildById('type'):setText((description.type or 'creature'):upper())
  row:getChildById('name'):setText(description.name or '')
  row:getChildById('health'):setText(
    description.healthPercent == nil and '' or
      (tostring(description.healthPercent) .. '%'))
  local state = {}
  if description.currentTarget then state[#state + 1] = tr('Target') end
  if description.following then state[#state + 1] = tr('Following') end
  if description.visible == false then state[#state + 1] = tr('Hidden') end
  row:getChildById('state'):setText(table.concat(state, '  •  '))

  row.onMousePress = function(_, position, button)
    row.mobileBattleSuppressClick = false
    row.mobileBattlePressPosition = position
    if button == (MouseRightButton or 2) then
      row.mobileBattleSuppressClick = true
      return self.battle.openBattleCreatureContext(id, position)
    end
    if button ~= (MouseLeftButton or 1) then
      row.mobileBattleSuppressClick = true
      return true
    end
    row.mobileBattlePressedAt = self.now()
    return false
  end
  row.onMouseRelease = function(_, position, button)
    if button ~= (MouseLeftButton or 1) then
      return true
    end
    local pressedAt = row.mobileBattlePressedAt
    row.mobileBattlePressedAt = nil
    if pressedAt and self.now() - pressedAt >= LONG_PRESS_MILLIS then
      row.mobileBattleSuppressClick = true
      return self.battle.openBattleCreatureContext(
        id, position or row.mobileBattlePressPosition)
    end
    return false
  end
  row.onClick = function()
    if row.mobileBattleSuppressClick then
      row.mobileBattleSuppressClick = false
      return true
    end
    row.mobileBattlePressedAt = nil
    return self.battle.attackBattleCreature(id)
  end
end

function View:_render(snapshot)
  self.snapshot = snapshot
  self:_releaseDynamicGestures()
  local rows = self:_widget('battleRows')
  rows:destroyChildren()
  local available = snapshot and snapshot.available == true
  local descriptions = available and snapshot.rows or {}
  local empty = #descriptions == 0
  local emptyLabel = self:_widget('battleEmpty')
  emptyLabel:setText(available and tr('No creatures nearby') or
    tr('Battle list unavailable'))
  emptyLabel:setVisible(empty)
  rows:setVisible(not empty)

  for _, description in ipairs(descriptions) do
    local row = g_ui.createWidget('MobileBattleRow', rows)
    self:_configureRow(row, description)
    self:_bindDynamic(row)
  end

  local rowsHeight = math.max(ROW_HEIGHT, #descriptions * ROW_HEIGHT)
  rows:setHeight(rowsHeight)
  local rootHeight = ROW_HEIGHT + rowsHeight + 6
  self.root:setHeight(rootHeight)
  if self.holder then
    self.holder:setHeight(rootHeight)
  end
end

function View:create(parent)
  self.holder = parent
  local content = parent:getParent()
  parent:setWidth(content and content:getWidth() or parent:getWidth())
  self.root = g_ui.createWidget('MobileBattleView', parent)
  self.root:setWidth(parent:getWidth())
  self:_configureControls()
  return self.root
end

function View:onShow()
  self:onHide()
  if not self.root or self.root:isDestroyed() then
    return false
  end
  self:_render(self.battle.getBattleSnapshot())
  self.unsubscribe = self.battle.subscribeBattle(function(snapshot)
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

local function wallMillis()
  if g_clock and type(g_clock.realMillis) == 'function' then
    return g_clock.realMillis()
  end
  return g_clock.millis()
end

function MobileBattle.createDescriptor(options)
  options = options or {}
  local view = setmetatable({
    battle = options.battle or modules.game_battle,
    now = options.now or wallMillis,
    dynamicGestureUnbinds = {}
  }, View)
  return {
    title = 'Battle',
    icon = '',
    create = function(parent) return view:create(parent) end,
    onShow = function() return view:onShow() end,
    onHide = function() view:onHide() end,
    destroy = function() view:destroy() end
  }
end
