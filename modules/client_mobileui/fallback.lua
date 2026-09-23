local emergency
local emergencyProfileUnsubscribe
local emergencyAppCallbacks
local emergencyGameCallbacks
local emergencyRaiseEvent

local function alive(widget)
  return widget and not widget:isDestroyed()
end

local function destroyWidget(widget)
  if alive(widget) then
    widget:destroy()
  end
end

local function profileText(profile)
  profile = profile or {}
  return string.format('%s/%sx%s',
    tostring(profile.controlClass or profile.class or 'compact'),
    tostring(profile.usableWidth or 0),
    tostring(profile.usableHeight or 0))
end

local function logCreationError(config, errorMessage)
  local activeState = 'unknown'
  if type(getForeground) == 'function' then
    local ok, state = pcall(getForeground)
    if ok then
      activeState = state
    end
  end
  g_logger.error(string.format(
    '[mobile-ui-fallback] view creation failed module=%s view=%s profile=%s activeState=%s requestedState=%s: %s',
    tostring(config.module or 'unknown'),
    tostring(config.view or 'unknown'),
    profileText(config.profile),
    tostring(activeState or 'none'),
    tostring(config.state or 'none'),
    tostring(errorMessage)))
end

local function consumePointer()
  return true
end

local function rootRect(root)
  return {
    x = 0,
    y = 0,
    width = math.max(0, root:getWidth()),
    height = math.max(0, root:getHeight())
  }
end

local function fallbackGeometry(root, profile)
  profile = profile or {}
  local rootWidth = math.max(0, root:getWidth())
  local rootHeight = math.max(0, root:getHeight())
  local safe = profile.safe or {}
  local left = math.max(0, tonumber(safe.left) or 0)
  local top = math.max(0, tonumber(safe.top) or 0)
  local usableWidth = math.max(0,
    tonumber(profile.usableWidth) or rootWidth - left -
      math.max(0, tonumber(safe.right) or 0))
  local usableHeight = math.max(0,
    tonumber(profile.usableHeight) or rootHeight - top -
      math.max(0, tonumber(safe.bottom) or 0))
  if usableWidth == 0 then
    usableWidth = rootWidth
    left = 0
  end
  if usableHeight == 0 then
    usableHeight = rootHeight
    top = 0
  end

  local margin = math.min(24, math.floor(usableWidth / 12))
  local width = math.max(0, math.min(
    tonumber(profile.modalMaxWidth) or usableWidth,
    usableWidth - margin * 2))
  local height = math.max(0, math.min(
    tonumber(profile.modalMaxHeight) or usableHeight,
    usableHeight - margin * 2))
  return {
    x = left + math.floor((usableWidth - width) / 2),
    y = top + math.floor((usableHeight - height) / 2),
    width = width,
    height = height
  }
end

local function applyEmergencyProfile(record, profile)
  if not record or not alive(record.widget) then
    return false
  end
  local root = g_ui.getRootWidget()
  record.widget:setRect(rootRect(root))
  local geometry = fallbackGeometry(root, profile)
  if alive(record.surface) then
    record.surface:setRect(geometry)
  end

  local padding = math.min(20, math.max(8,
    math.floor(geometry.width / 24)))
  local buttonHeight = math.min(56, math.max(48,
    tonumber(profile and profile.touchTarget) or 48))
  local actionGap = 8
  local buttonCount = #record.buttons
  local actionsHeight = buttonCount > 0 and buttonHeight or 0
  local titleHeight = math.min(52,
    math.max(32, math.floor(geometry.height * 0.16)))
  local contentTop = padding + titleHeight
  local contentHeight = math.max(0,
    geometry.height - contentTop - padding - actionsHeight -
      (buttonCount > 0 and actionGap or 0))

  if alive(record.title) then
    record.title:setRect({
      x = padding, y = padding,
      width = math.max(0, geometry.width - padding * 2),
      height = titleHeight
    })
  end
  if alive(record.label) then
    record.label:setRect({
      x = padding, y = contentTop,
      width = math.max(0, geometry.width - padding * 2),
      height = contentHeight
    })
  end
  if buttonCount > 0 then
    local availableWidth = math.max(0,
      geometry.width - padding * 2 - actionGap * (buttonCount - 1))
    local buttonWidth = math.floor(availableWidth / buttonCount)
    local y = geometry.height - padding - buttonHeight
    for index, button in ipairs(record.buttons) do
      if alive(button) then
        button:setRect({
          x = padding + (index - 1) * (buttonWidth + actionGap),
          y = y,
          width = buttonWidth,
          height = buttonHeight
        })
      end
    end
  end
  return true
end

local function raiseEmergency()
  if not emergency or not alive(emergency.widget) then
    return false
  end
  emergency.widget:show()
  emergency.widget:raise()
  emergency.widget:focus()
  if emergency.widget.grabKeyboard then
    emergency.widget:grabKeyboard()
  end
  return true
end

local function scheduleEmergencyRaise()
  if not emergency then
    return false
  end
  removeEvent(emergencyRaiseEvent)
  local expected = emergency
  emergencyRaiseEvent = addEvent(function()
    emergencyRaiseEvent = nil
    if emergency == expected then
      raiseEmergency()
    end
  end)
  return true
end

function createEmergencyBlocker(config)
  config = config or {}
  if emergency and alive(emergency.widget) then
    if emergency.widget.ungrabKeyboard then
      emergency.widget:ungrabKeyboard()
    end
    emergency.widget:destroy()
  end
  emergency = nil

  local root = g_ui.getRootWidget()
  local ok, blocker = pcall(g_ui.createWidget, 'Panel', root)
  if not ok or not alive(blocker) then
    g_logger.error('[mobile-ui-fallback] emergency blocker creation failed: ' ..
      tostring(blocker))
    return nil
  end

  local record = {
    widget = blocker,
    buttons = {},
    owner = config.owner or {},
    state = config.state or 'modal'
  }
  emergency = record
  blocker:setBackgroundColor('#081018f4')
  blocker:setFocusable(true)
  blocker.onMousePress = consumePointer
  blocker.onMouseMove = consumePointer
  blocker.onMouseRelease = consumePointer
  blocker.onKeyDown = function() return true end
  blocker.onDestroy = function()
    if emergency == record then
      emergency = nil
    end
  end

  setForeground(record.state, record.owner)
  applyEmergencyProfile(record, config.profile or getProfile())
  raiseEmergency()

  local function createContentWidget(style, parent, configure)
    local created, widget = pcall(g_ui.createWidget, style, parent)
    if not created or not alive(widget) then
      g_logger.error('[mobile-ui-fallback] emergency ' ..
        tostring(style) .. ' creation failed: ' .. tostring(widget))
      return nil
    end
    local configured, configureError = pcall(configure, widget)
    if not configured then
      g_logger.error('[mobile-ui-fallback] emergency ' ..
        tostring(style) .. ' configuration failed: ' ..
        tostring(configureError))
      destroyWidget(widget)
      return nil
    end
    return widget
  end

  record.surface = createContentWidget('Panel', blocker, function(surface)
    surface:setBackgroundColor('#16232fff')
  end)
  local contentParent = record.surface or blocker

  -- Actions are created before copy so a label/style failure cannot remove
  -- the only safe way out of a blocking mobile fallback.
  for _, action in ipairs(config.actions or {}) do
    local button = createContentWidget('Button', contentParent,
      function(createdButton)
        createdButton:setText(action.text or tr('Retry'))
        createdButton.onClick = function()
          if emergency ~= record then
            return false
          end
          local actionOk, result =
            pcall(action.callback or raiseEmergency)
          if not actionOk then
            g_logger.error(
              '[mobile-ui-fallback] emergency action failed: ' ..
              tostring(result))
            raiseEmergency()
            return false
          end
          return result
        end
      end)
    if button then
      record.buttons[#record.buttons + 1] = button
    end
  end

  record.title = createContentWidget('Label', contentParent,
    function(title)
      title:setText(config.title or tr('Unable to continue'))
      title:setColor('#f2f6f8')
      title:setTextAlign(AlignCenter)
      title:setTextWrap(true)
      title:setPhantom(true)
    end)
  record.label = createContentWidget('Label', contentParent,
    function(label)
      label:setText(config.message or
        tr('A required mobile view could not be opened.'))
      label:setColor('#dbe6ee')
      label:setTextAlign(AlignCenter)
      label:setTextWrap(true)
      label:setPhantom(true)
    end)

  applyEmergencyProfile(record, config.profile or getProfile())
  return record
end

function showMobileViewError(config, errorMessage)
  config = config or {}
  config.profile = config.profile or getProfile()
  logCreationError(config, errorMessage)
  return createEmergencyBlocker(config)
end

function safeCreateMobileView(config)
  assert(type(config) == 'table',
    'safe mobile view creation requires a config')
  assert(type(config.create) == 'function',
    'safe mobile view creation requires a create callback')

  local ok, result = pcall(config.create)
  if ok and result and
      (not result.isDestroyed or not result:isDestroyed()) then
    return result
  end

  if config.cleanup then
    local cleaned, cleanupError = pcall(config.cleanup, result)
    if not cleaned then
      g_logger.error('[mobile-ui-fallback] partial cleanup failed: ' ..
        tostring(cleanupError))
    end
  else
    destroyWidget(result)
  end
  local fallback = showMobileViewError(config,
    ok and 'creation returned no live widget' or result)
  return nil, fallback
end

function closeMobileViewError(owner)
  if not emergency or (owner and emergency.owner ~= owner) then
    return false
  end
  local record = emergency
  emergency = nil
  destroyWidget(record.widget)
  local state, activeOwner = getForeground()
  if activeOwner == record.owner then
    setForeground('gameplay', nil)
  end
  return true
end

function initFallback()
  emergencyProfileUnsubscribe = subscribeProfile(function(profile)
    if emergency then
      applyEmergencyProfile(emergency, profile)
      raiseEmergency()
    end
  end)
  emergencyAppCallbacks = {
    onRun = scheduleEmergencyRaise,
    onUpdateFinished = scheduleEmergencyRaise
  }
  emergencyGameCallbacks = {
    onGameStart = scheduleEmergencyRaise,
    onGameEnd = scheduleEmergencyRaise
  }
  connect(g_app, emergencyAppCallbacks)
  connect(g_game, emergencyGameCallbacks)
end

function terminateFallback()
  removeEvent(emergencyRaiseEvent)
  emergencyRaiseEvent = nil
  if emergencyProfileUnsubscribe then
    emergencyProfileUnsubscribe()
    emergencyProfileUnsubscribe = nil
  end
  if emergencyAppCallbacks then
    disconnect(g_app, emergencyAppCallbacks)
    emergencyAppCallbacks = nil
  end
  if emergencyGameCallbacks then
    disconnect(g_game, emergencyGameCallbacks)
    emergencyGameCallbacks = nil
  end
  if emergency and alive(emergency.widget) then
    if emergency.widget.ungrabKeyboard then
      emergency.widget:ungrabKeyboard()
    end
    emergency.widget:destroy()
  end
  emergency = nil
end
