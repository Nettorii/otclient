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

local function staminaText(minutes)
  minutes = finiteNumber(minutes)
  if not minutes then
    return nil
  end
  minutes = math.max(0, math.floor(minutes))
  return string.format('%d:%02d', math.floor(minutes / 60), minutes % 60)
end

local EDGE_LEFT = 8
local EDGE_RIGHT = 6
local ROW_GAP = 6
local METER_LABEL_EDGE = 5

local Adapter = {}
Adapter.__index = Adapter

function Adapter:_widget(id)
  return self.widgets and self.widgets[id] or nil
end

function Adapter:_dataVisible(id)
  return self.rendered[id .. ':visible'] == true
end

function Adapter:_textWidth(id)
  local widget = self:_widget(id)
  local size = widget and widget:getTextSize()
  return size and size.width or 0
end

-- When row one is too narrow, stamina is dropped first, then vocation, then
-- the name is shortened.
function Adapter:_layout()
  local surface = self.surface
  if self.layoutDeferred or not surface or not self.widgets then
    return
  end
  local width = surface:getWidth()
  if not width or width <= 0 then
    return
  end

  local nameWidget = self:_widget('statusName')
  local name = self.fullName or ''
  if nameWidget and self:_dataVisible('statusName') then
    nameWidget:setText(name)
  end
  local nameWidth = self:_textWidth('statusName')
  local available = width - EDGE_LEFT - EDGE_RIGHT

  local shown = {}
  for _, id in ipairs({ 'level', 'stamina', 'vocation' }) do
    shown[id] = self:_dataVisible(id)
  end
  local function clusterWidth()
    local total = 0
    for _, id in ipairs({ 'level', 'stamina', 'vocation' }) do
      if shown[id] then
        total = total + self:_textWidth(id) + ROW_GAP
      end
    end
    return total
  end
  for _, id in ipairs({ 'stamina', 'vocation' }) do
    if nameWidth <= available - clusterWidth() then
      break
    end
    shown[id] = false
  end

  local nameRoom = math.max(0, available - clusterWidth())
  if nameWidget and self:_dataVisible('statusName') and nameWidth > nameRoom then
    local shortened = name
    while #shortened > 1 do
      shortened = shortened:sub(1, -2)
      nameWidget:setText(shortened .. '..')
      if self:_textWidth('statusName') <= nameRoom then
        break
      end
    end
    nameWidth = self:_textWidth('statusName')
  end

  local cursor = EDGE_LEFT
  if nameWidget then
    nameWidget:setMarginLeft(EDGE_LEFT)
    nameWidget:setWidth(math.max(1, nameWidth))
    cursor = EDGE_LEFT + nameWidth + ROW_GAP
  end
  for _, id in ipairs({ 'level', 'stamina', 'vocation' }) do
    local widget = self:_widget(id)
    if widget then
      local textWidth = self:_textWidth(id)
      widget:setWidth(math.max(1, textWidth))
      if id == 'vocation' then
        widget:setMarginLeft(width - EDGE_RIGHT - textWidth)
      else
        widget:setMarginLeft(cursor)
        if shown[id] then
          cursor = cursor + textWidth + ROW_GAP
        end
      end
      widget:setVisible(shown[id])
    end
  end

  local meterLabelWidth = 1
  for _, id in ipairs({ 'soul', 'capacity' }) do
    if self:_dataVisible(id) then
      meterLabelWidth = math.max(meterLabelWidth, self:_textWidth(id))
    end
  end
  for _, id in ipairs({ 'soul', 'capacity' }) do
    local widget = self:_widget(id)
    if widget then
      widget:setWidth(math.min(meterLabelWidth,
        math.max(1, width - EDGE_LEFT - METER_LABEL_EDGE - 64)))
    end
  end
end

function Adapter:_setVisible(id, visible)
  local widget = self:_widget(id)
  if not widget or self.rendered[id .. ':visible'] == visible then
    return
  end
  self.rendered[id .. ':visible'] = visible
  widget:setVisible(visible)
  self:_layout()
end

function Adapter:_setText(id, text)
  local widget = self:_widget(id)
  if not widget or self.rendered[id .. ':text'] == text then
    return
  end
  self.rendered[id .. ':text'] = text
  if id == 'statusName' then
    self.fullName = text
  end
  widget:setText(text)
  self:_layout()
end

function Adapter:_setPercent(id, percent)
  local widget = self:_widget(id)
  if not widget or self.rendered[id .. ':percent'] == percent then
    return
  end
  self.rendered[id .. ':percent'] = percent
  widget:setPercent(percent)
end

function Adapter:_renderText(id, prefix, value, format)
  local text = (format or displayNumber)(value)
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
  self.layoutDeferred = true
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
  self:_renderText('stamina', 'Stam ', read(player, 'getStamina'), staminaText)
  self.layoutDeferred = false
  self:_layout()
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
    self.geometryCallbacks = {
      onGeometryChange = function()
        self:_layout()
      end
    }
    self.connect(surface, self.geometryCallbacks)
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
  if self.surface and self.geometryCallbacks then
    self.disconnect(self.surface, self.geometryCallbacks)
  end
  self.geometryCallbacks = nil
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
      adapter:_renderText('stamina', 'Stam ', stamina, staminaText)
    end
  }

  return adapter
end
