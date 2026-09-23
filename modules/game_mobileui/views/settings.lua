MobileSettings = {}

local View = {}
View.__index = View

local MOBILE_DEFAULTS = {
  mobileControlPreset = 'comfortable',
  mobileHandedness = 'standard',
  mobileOverlayOpacity = 0.86
}

local CATEGORIES = {
  graphics = {
    title = 'Graphics',
    options = {
      { key = 'vsync', text = 'Vertical sync' },
      { key = 'fullscreen', text = 'Fullscreen' },
      { key = 'enableLights', text = 'Lights' },
      { key = 'optimizeFps', text = 'Optimize frame rate' }
    }
  },
  audio = {
    title = 'Audio',
    options = {
      { key = 'enableAudio', text = 'Audio' },
      { key = 'enableMusicSound', text = 'Music' },
      { key = 'footstepSounds', text = 'Footsteps' }
    }
  },
  interface = {
    title = 'Interface',
    options = {
      { key = 'showFps', text = 'Show FPS' },
      { key = 'showPing', text = 'Show ping' },
      { key = 'displayNames', text = 'Creature names' },
      { key = 'displayHealth', text = 'Health bars' },
      { key = 'displayMana', text = 'Mana bars' },
      { key = 'displayText', text = 'Game text' },
      { key = 'showAnimatedCursor', text = 'Animated cursor' }
    }
  },
  gameplay = {
    title = 'Gameplay',
    options = {
      { key = 'smartWalk', text = 'Smart walk' },
      { key = 'autoChaseOverride', text = 'Override auto chase' },
      { key = 'returnDisablesChat', text = 'Return closes chat' },
      { key = 'showLootMessagesOnScreen', text = 'Loot messages' },
      { key = 'showPrivateMessagesOnScreen', text = 'Private messages' }
    }
  }
}

local function displayPreset(value)
  return value == 'compact' and tr('Compact') or tr('Comfortable')
end

local function displayHandedness(value)
  return value == 'mirrored' and tr('Mirrored') or tr('Standard')
end

local function displayOpacity(value)
  return string.format('%d%%', math.floor((tonumber(value) or 0.86) * 100 + 0.5))
end

local function displayBoolean(value)
  return value == true and tr('On') or tr('Off')
end

function View:_widget(id)
  return self.root and self.root:recursiveGetChildById(id) or nil
end

function View:_renderMobileValues(profile)
  profile = profile or self.mobileUi.getProfile()
  local presetValue = self:_widget('mobileControlPresetValue')
  local handednessValue = self:_widget('mobileHandednessValue')
  local opacityValue = self:_widget('mobileOverlayOpacityValue')
  if presetValue then
    presetValue:setText(displayPreset(profile.controlPreset))
  end
  if handednessValue then
    handednessValue:setText(displayHandedness(profile.handedness))
  end
  if opacityValue then
    opacityValue:setText(displayOpacity(profile.overlayOpacity))
  end
end

function View:_setOption(key, value)
  self.options.setOption(key, value)
  return true
end

function View:_configureMobileControls()
  local preset = self:_widget('mobileControlPreset')
  preset:getChildById('name'):setText(tr('Control size'))
  preset:getChildById('value'):setId('mobileControlPresetValue')
  preset.onClick = function()
    local current = self.options.getOption('mobileControlPreset')
    return self:_setOption('mobileControlPreset',
      current == 'compact' and 'comfortable' or 'compact')
  end
  local handedness = self:_widget('mobileHandedness')
  handedness:getChildById('name'):setText(tr('Handedness'))
  handedness:getChildById('value'):setId('mobileHandednessValue')
  handedness.onClick = function()
    local current = self.options.getOption('mobileHandedness')
    return self:_setOption('mobileHandedness',
      current == 'mirrored' and 'standard' or 'mirrored')
  end
  self:_widget('mobileOverlayOpacityMinus').onClick = function()
    local current = self.options.getOption('mobileOverlayOpacity')
    return self:_setOption(
      'mobileOverlayOpacity', (tonumber(current) or 0.86) - 0.02)
  end
  self:_widget('mobileOverlayOpacityPlus').onClick = function()
    local current = self.options.getOption('mobileOverlayOpacity')
    return self:_setOption(
      'mobileOverlayOpacity', (tonumber(current) or 0.86) + 0.02)
  end
  self:_widget('mobileSettingsReset').onClick = function()
    for key, value in pairs(MOBILE_DEFAULTS) do
      self.options.setOption(key, value)
    end
    return true
  end
end

function View:_closeOwnedModal()
  local session = self.modalSession
  if not session then
    return
  end
  self.modalGeneration = self.modalGeneration + 1
  self.modalSession = nil
  if session.handle and session.handle:isOpen() then
    session.handle:close()
  elseif session.body and not session.body:isDestroyed() then
    session.body:destroy()
  end
  session.handle = nil
  session.body = nil
end

local function consumeModalGesture(session)
  local handle = session and session.handle
  return handle and type(handle.consumeBodyGesture) == 'function' and
    handle:consumeBodyGesture() == true
end

function View:_showCategory(categoryId)
  local category = CATEGORIES[categoryId]
  if not category or not self.mobileUi or
      type(self.mobileUi.showModal) ~= 'function' then
    return false
  end

  self:_closeOwnedModal()
  self.modalGeneration = self.modalGeneration + 1
  local generation = self.modalGeneration
  local body = g_ui.createWidget('MobileSettingsOptionSheet')
  local session = {
    body = body,
    generation = generation
  }
  self.modalSession = session
  local close = g_ui.createWidget('MobileSettingsModalClose', body)
  close:setId('mobileSettingsModalClose')
  close:setText(tr('Close'))
  close.onClick = function()
    if consumeModalGesture(session) then
      return true
    end
    if self.modalSession == session and
        self.modalGeneration == generation then
      self:_closeOwnedModal()
    end
    return true
  end

  for index, definition in ipairs(category.options) do
    local row = g_ui.createWidget('MobileSettingsOptionRow', body)
    row:setId('mobileOption_' .. definition.key)
    row:getChildById('name'):setText(tr(definition.text))
    local value = self.options.getOption(definition.key)
    row:getChildById('value'):setText(displayBoolean(value))
    row.onClick = function()
      if consumeModalGesture(session) then
        return true
      end
      if self.modalSession ~= session or
          self.modalGeneration ~= generation then
        return true
      end
      local current = self.options.getOption(definition.key)
      local nextValue = not (current == true)
      self.options.setOption(definition.key, nextValue, false, false, true)
      if not row:isDestroyed() then
        row:getChildById('value'):setText(displayBoolean(nextValue))
      end
      return true
    end
  end

  body:setHeight(
    (#category.options + 1) * 56 + #category.options * 4)

  local handle = self.mobileUi.showModal({
    title = tr(category.title),
    body = body,
    buttons = {},
    onEscape = function()
      if self.modalSession == session then
        self:_closeOwnedModal()
      end
    end,
    onClose = function()
      if self.modalSession == session then
        self.modalSession = nil
      end
      session.handle = nil
      session.body = nil
    end
  })
  session.handle = handle
  if self.modalSession ~= session and handle and handle:isOpen() then
    handle:close()
  elseif not handle or not handle:isOpen() then
    if self.modalSession == session then
      self.modalSession = nil
    end
  end
  return handle ~= nil and handle:isOpen()
end

function View:_configureCategories()
  for _, categoryId in ipairs({
    'graphics', 'audio', 'interface', 'gameplay'
  }) do
    local id = categoryId
    local button = self:_widget(
      'settings' .. categoryId:sub(1, 1):upper() .. categoryId:sub(2))
    button.onClick = function()
      return self:_showCategory(id)
    end
  end
end

function View:create(parent)
  self.holder = parent
  self.root = g_ui.createWidget('MobileSettingsView', parent)
  self.root:setWidth(math.max(0, parent:getWidth()))
  self.holder:setHeight(self.root:getHeight())
  self:_configureMobileControls()
  self:_configureCategories()
  self:_renderMobileValues(self.mobileUi.getProfile())
  return self.root
end

function View:onShow()
  self:onHide()
  if not self.root or self.root:isDestroyed() then
    return false
  end
  self:_renderMobileValues(self.mobileUi.getProfile())
  self.unsubscribeProfile = self.mobileUi.subscribeProfile(function(profile)
    if self.root and not self.root:isDestroyed() then
      self:_renderMobileValues(profile)
    end
  end)
  return true
end

function View:onHide()
  self:_closeOwnedModal()
  if self.unsubscribeProfile then
    self.unsubscribeProfile()
    self.unsubscribeProfile = nil
  end
end

function View:destroy()
  self:onHide()
  if self.root and not self.root:isDestroyed() then
    self.root:destroy()
  end
  self.root = nil
  self.holder = nil
end

function MobileSettings.createDescriptor(options)
  options = options or {}
  local view = setmetatable({
    options = options.options or modules.client_options,
    mobileUi = options.mobileUi or modules.client_mobileui,
    modalGeneration = 0
  }, View)
  return {
    title = 'Settings',
    icon = '',
    create = function(parent) return view:create(parent) end,
    onShow = function() return view:onShow() end,
    onHide = function() view:onHide() end,
    destroy = function() view:destroy() end
  }
end
