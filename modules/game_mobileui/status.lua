MobileStatus = {}

local vocationNames = {
  [0] = 'No vocation',
  [1] = 'Knight',
  [2] = 'Paladin',
  [3] = 'Sorcerer',
  [4] = 'Druid',
  [5] = 'Monk',
  [11] = 'Elite Knight',
  [12] = 'Royal Paladin',
  [13] = 'Master Sorcerer',
  [14] = 'Elder Druid',
  [15] = 'Exalted Monk'
}

local function finiteNumber(value)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or
      value == -math.huge then
    return nil
  end
  return value
end

function MobileStatus.percentage(current, maximum)
  current = finiteNumber(current)
  maximum = finiteNumber(maximum)
  if not current or not maximum or maximum <= 0 then
    return nil
  end
  return math.max(0, math.min(100, current * 100 / maximum))
end

local function read(player, getter)
  if not player or type(player[getter]) ~= 'function' then
    return nil
  end
  return player[getter](player)
end

local function displayNumber(value)
  value = finiteNumber(value)
  if not value then
    return nil
  end
  if value == math.floor(value) then
    return tostring(math.floor(value))
  end
  return tostring(value)
end

local Adapter = {}
Adapter.__index = Adapter

function Adapter:_widget(id)
  return self.widgets and self.widgets[id] or nil
end

function Adapter:_setVisible(id, visible)
  local widget = self:_widget(id)
  if not widget or self.rendered[id .. ':visible'] == visible then
    return
  end
  self.rendered[id .. ':visible'] = visible
  widget:setVisible(visible)
end

function Adapter:_setText(id, text)
  local widget = self:_widget(id)
  if not widget or self.rendered[id .. ':text'] == text then
    return
  end
  self.rendered[id .. ':text'] = text
  widget:setText(text)
end

function Adapter:_setPercent(id, percent)
  local widget = self:_widget(id)
  if not widget or self.rendered[id .. ':percent'] == percent then
    return
  end
  self.rendered[id .. ':percent'] = percent
  widget:setPercent(percent)
end

function Adapter:_renderText(id, prefix, value)
  local text = displayNumber(value)
  local visible = text ~= nil
  self:_setVisible(id, visible)
  if visible then
    self:_setText(id, prefix .. text)
  end
end

function Adapter:_renderMeter(id, labelId, prefix, current, maximum)
  local percent = MobileStatus.percentage(current, maximum)
  local currentText = displayNumber(current)
  local maximumText = displayNumber(maximum)
  local visible = percent ~= nil and currentText ~= nil and maximumText ~= nil
  self:_setVisible(id, visible)
  self:_setVisible(labelId, visible)
  if not visible then
    return
  end
  self:_setPercent(id, percent)
  self:_setText(labelId,
    string.format('%s %s/%s', prefix, currentText, maximumText))
end

function Adapter:_renderLevel(level)
  local text = displayNumber(level)
  local visible = text ~= nil
  self:_setVisible('level', visible)
  if visible then
    self:_setText('level', 'Lv ' .. text)
  end
end

function Adapter:_renderVocation()
  local vocation = read(self.player, 'getVocation')
  local name
  if vocation ~= nil and self.player and
      type(self.player.getVocationNameByClientId) == 'function' then
    name = self.player:getVocationNameByClientId()
  end
  if not name or name == '' then
    name = vocationNames[tonumber(vocation)]
  end
  local visible = name ~= nil and name ~= ''
  self:_setVisible('vocation', visible)
  if visible then
    self:_setText('vocation', tostring(name))
  end
end

function Adapter:_renderName()
  local name = read(self.player, 'getName')
  local visible = name ~= nil and name ~= ''
  self:_setVisible('statusName', visible)
  if visible then
    self:_setText('statusName', tostring(name))
  end
end

function Adapter:_refreshAll()
  local player = self.player
  self:_renderName()
  self:_renderMeter(
    'health', 'healthValue', 'HP',
    read(player, 'getHealth'), read(player, 'getMaxHealth'))
  self:_renderMeter(
    'mana', 'manaValue', 'MP',
    read(player, 'getMana'), read(player, 'getMaxMana'))
  self:_renderLevel(read(player, 'getLevel'))
  self:_renderVocation()
  self:_renderText('soul', 'Soul ', read(player, 'getSoul'))
  self:_renderText('capacity', 'Cap ', read(player, 'getFreeCapacity'))
  self:_renderText('stamina', 'Stam ', read(player, 'getStamina'))
end

function Adapter:_clear()
  for _, id in ipairs({
    'statusName', 'health', 'healthValue', 'mana', 'manaValue',
    'level', 'vocation', 'soul', 'capacity', 'stamina'
  }) do
    self:_setVisible(id, false)
  end
end

function Adapter:bind(surface)
  self.surface = surface
  self.widgets = {}
  self.rendered = {}
  for _, id in ipairs({
    'statusName', 'health', 'healthValue', 'mana', 'manaValue',
    'level', 'vocation', 'soul', 'capacity', 'stamina'
  }) do
    self.widgets[id] = surface and surface:getChildById(id) or nil
  end
  if surface then
    surface:setVisible(true)
  end
  self:_refreshAll()
end

function Adapter:onGameStart(player)
  self:onGameEnd()
  self.player = player or self.game.getLocalPlayer()
  if self.player then
    self.connect(self.player, self.callbacks)
    self.connected = true
  end
  self:_refreshAll()
end

function Adapter:onGameEnd()
  if self.connected and self.player then
    self.disconnect(self.player, self.callbacks)
  end
  self.connected = false
  self.player = nil
  self:_clear()
end

function Adapter:terminate()
  self:onGameEnd()
  self.surface = nil
  self.widgets = nil
  self.rendered = {}
end

function MobileStatus.create(options)
  options = options or {}
  local adapter = setmetatable({
    game = options.game or g_game,
    connect = options.connect or connect,
    disconnect = options.disconnect or disconnect,
    rendered = {},
    connected = false
  }, Adapter)

  adapter.callbacks = {
    onHealthChange = function(_, health, maxHealth)
      adapter:_renderMeter(
        'health', 'healthValue', 'HP', health, maxHealth)
    end,
    onManaChange = function(_, mana, maxMana)
      adapter:_renderMeter('mana', 'manaValue', 'MP', mana, maxMana)
    end,
    onLevelChange = function(_, level)
      adapter:_renderLevel(level)
    end,
    onVocationChange = function()
      adapter:_renderVocation()
    end,
    onSoulChange = function(_, soul)
      adapter:_renderText('soul', 'Soul ', soul)
    end,
    onFreeCapacityChange = function(_, capacity)
      adapter:_renderText('capacity', 'Cap ', capacity)
    end,
    onStaminaChange = function(_, stamina)
      adapter:_renderText('stamina', 'Stam ', stamina)
    end
  }

  return adapter
end
