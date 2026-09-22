MobileActions = {}

local Adapter = {}
Adapter.__index = Adapter

local function callBoolean(object, method)
  return object and type(object[method]) == 'function' and
    object[method](object) == true
end

local function creatureId(creature)
  if not creature or type(creature.getId) ~= 'function' then
    return nil
  end
  return creature:getId()
end

local function isSummon(creature)
  if callBoolean(creature, 'isSummon') then
    return true
  end
  if type(creature.getType) ~= 'function' then
    return false
  end
  local creatureType = creature:getType()
  local ownSummon = CreatureTypeSummonOwn or 3
  local otherSummon = CreatureTypeSummonOther or 4
  return creatureType == ownSummon or creatureType == otherSummon
end

local function isHostileMonster(creature, player)
  if not creature or creature == player or
      callBoolean(creature, 'isDead') or
      not callBoolean(creature, 'isMonster') or isSummon(creature) then
    return false
  end

  local name = ''
  if type(creature.getName) == 'function' then
    name = creature:getName() or ''
  end
  return not name:find('^Adventurer ') and
    not name:find('^Companion ') and
    not name:find('^Pet ') and
    name ~= 'Town Guard'
end

local function distance(left, right)
  return math.max(math.abs(left.x - right.x), math.abs(left.y - right.y))
end

function Adapter:_active()
  return self.isActive() == true
end

function Adapter:_message(text)
  self.displayMessage(self.translate(text))
end

function Adapter:_resetCycle()
  self.targetCycle = {}
  self.requestedTargetId = nil
end

function Adapter:_candidates(player)
  if not player or type(player.getPosition) ~= 'function' then
    return {}
  end
  local playerPosition = player:getPosition()
  if not playerPosition then
    return {}
  end

  local candidates = {}
  for _, creature in ipairs(
      self.map.getSpectators(playerPosition, false) or {}) do
    if isHostileMonster(creature, player) and
        type(creature.getPosition) == 'function' then
      local position = creature:getPosition()
      if position and position.z == playerPosition.z then
        local range = distance(position, playerPosition)
        if range <= 7 then
          candidates[#candidates + 1] = {
            creature = creature,
            distance = range
          }
        end
      end
    end
  end

  table.sort(candidates, function(left, right)
    if left.distance ~= right.distance then
      return left.distance < right.distance
    end
    return creatureId(left.creature) < creatureId(right.creature)
  end)
  return candidates
end

function Adapter:attackNearest()
  if not self:_active() then
    return false
  end

  local player = self.game.getLocalPlayer()
  local candidates = self:_candidates(player)
  if #candidates == 0 then
    self:_resetCycle()
    if self.game.getAttackingCreature() then
      self.game.cancelAttackAndFollow()
    end
    self:_message('There is nothing to attack nearby.')
    return false
  end

  local currentId = creatureId(self.game.getAttackingCreature())
  local target
  for _, candidate in ipairs(candidates) do
    local id = creatureId(candidate.creature)
    if id ~= currentId and not self.targetCycle[id] then
      target = candidate.creature
      break
    end
  end

  if not target then
    self:_resetCycle()
    target = candidates[1].creature
    if creatureId(target) == currentId then
      if #candidates == 1 then
        return true
      end
      target = candidates[2].creature
    end
  end

  local targetId = creatureId(target)
  self.targetCycle[targetId] = true
  self.requestedTargetId = targetId
  self.game.attack(target)
  return true
end

function Adapter:onAttackingCreatureChange(creature)
  local id = creatureId(creature)
  if self.requestedTargetId and id == self.requestedTargetId then
    self.requestedTargetId = nil
    return
  end
  self:_resetCycle()
end

local function shortcutButton(shortcuts, id)
  if not shortcuts or type(shortcuts.getPanel) ~= 'function' then
    return nil
  end
  local panel = shortcuts.getPanel()
  local icons = panel and panel:getChildById('shortcutIcons')
  return icons and icons:getChildById(id) or nil
end

function Adapter:interact()
  if not self:_active() then
    return false
  end

  if self.shortcuts and type(self.shortcuts.activateShortcut) == 'function' then
    return self.shortcuts.activateShortcut('use') ~= false
  end
  if self.shortcuts and type(self.shortcuts.setShortcut) == 'function' then
    return self.shortcuts.setShortcut('use') ~= false
  end
  if self.gameInterface and
      type(self.gameInterface.activateUseMode) == 'function' then
    return self.gameInterface.activateUseMode() ~= false
  end

  local use = shortcutButton(self.shortcuts, 'use')
  if not use or type(use.onClick) ~= 'function' then
    self:_message('Interact mode is not available.')
    return false
  end
  self.shortcuts.resetShortcuts()
  use.onClick(use)
  return true
end

function Adapter:_toggle(handler, unavailable)
  if not self:_active() then
    return false
  end
  if not handler then
    self:_message(unavailable)
    return false
  end
  handler()
  return true
end

function Adapter:toggleChat()
  return self:_toggle(self.chatHandler, 'Chat is not available.')
end

function Adapter:toggleDrawer()
  return self:_toggle(self.drawerHandler, 'Drawer is not available.')
end

local function registerHandler(adapter, field, handler)
  assert(type(handler) == 'function', 'handler must be a function')
  adapter[field] = handler
  local removed = false
  return function()
    if removed then
      return
    end
    removed = true
    if adapter[field] == handler then
      adapter[field] = nil
    end
  end
end

function Adapter:registerChatHandler(handler)
  return registerHandler(self, 'chatHandler', handler)
end

function Adapter:registerDrawerHandler(handler)
  return registerHandler(self, 'drawerHandler', handler)
end

function Adapter:updateEnabled()
  local enabled = self:_active()
  if not enabled then
    self:cancelGestures()
  end
  for _, button in pairs(self.buttons or {}) do
    button:setEnabled(enabled)
  end
end

function Adapter:cancelGestures()
  for _, button in pairs(self.buttons or {}) do
    button.mobileActionPressedAt = nil
    button.mobileActionSuppress = true
  end
end

local function configureButton(button, now, action)
  button.onMousePress = function(_, _, mouseButton)
    if mouseButton == (MouseRightButton or 2) then
      button.mobileActionSuppress = true
      return true
    end
    button.mobileActionSuppress = false
    button.mobileActionPressedAt = now()
    return false
  end
  button.onMouseRelease = function(widget, position, mouseButton)
    if mouseButton == (MouseRightButton or 2) then
      button.mobileActionSuppress = true
      return true
    end
    return UIButton.onMouseRelease(widget, position, mouseButton)
  end
  button.onClick = function()
    local pressedAt = button.mobileActionPressedAt
    local held = pressedAt and now() - pressedAt >= 200
    local suppressed = button.mobileActionSuppress
    button.mobileActionPressedAt = nil
    button.mobileActionSuppress = false
    if held or suppressed then
      return true
    end
    return action()
  end
end

function Adapter:bind(panel)
  self.buttons = {
    attack = panel:getChildById('attack'),
    use = panel:getChildById('use'),
    chat = panel:getChildById('chat'),
    inventory = panel:getChildById('inventory')
  }
  local handlers = {
    attack = function() return self:attackNearest() end,
    use = function() return self:interact() end,
    chat = function() return self:toggleChat() end,
    inventory = function() return self:toggleDrawer() end
  }
  for id, button in pairs(self.buttons) do
    configureButton(button, self.now, handlers[id])
  end
  self:updateEnabled()
end

function Adapter:onGameStart()
  self:onGameEnd()
  self:_resetCycle()
  self.connect(self.game, self.gameCallbacks)
  self.targetConnected = true
  self:updateEnabled()
end

function Adapter:onGameEnd()
  self:cancelGestures()
  if self.targetConnected then
    self.disconnect(self.game, self.gameCallbacks)
  end
  self.targetConnected = false
  self:_resetCycle()
  self:updateEnabled()
end

function Adapter:terminate()
  self:onGameEnd()
  self.buttons = nil
  self.chatHandler = nil
  self.drawerHandler = nil
end

local function wallMillis(clock)
  if clock and type(clock.realMillis) == 'function' then
    return clock.realMillis()
  end
  return clock.millis()
end

function MobileActions.create(options)
  options = options or {}
  local clock = options.clock or g_clock
  local adapter = setmetatable({
    game = options.game or g_game,
    map = options.map or g_map,
    shortcuts = options.shortcuts or
      (modules and modules.game_shortcuts),
    gameInterface = options.gameInterface or
      (modules and modules.game_interface),
    displayMessage = options.displayMessage or function(text)
      modules.game_textmessage.displayGameMessage(text)
    end,
    translate = options.translate or tr,
    connect = options.connect or connect,
    disconnect = options.disconnect or disconnect,
    isActive = options.isActive or function() return true end,
    now = function() return wallMillis(clock) end,
    targetCycle = {},
    targetConnected = false
  }, Adapter)

  adapter.gameCallbacks = {
    onAttackingCreatureChange = function(creature)
      adapter:onAttackingCreatureChange(creature)
    end
  }
  return adapter
end
