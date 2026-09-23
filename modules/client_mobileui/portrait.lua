local portraitWidget
local unsubscribeProfile
local active = false
local terminating = false
local releasing = false
local generation = 0
local restoreState
local restoreOwner
local baseRestoreState
local baseRestoreOwner
local listeners = {}
local nextListenerId = 0
local portraitOwner = {}

local function profileRequiresPortraitGate(profile)
  return type(profile) == 'table' and
    (tonumber(profile.usableHeight) or 0) >
      (tonumber(profile.usableWidth) or 0)
end

function runPortraitSelfTests()
  assert(profileRequiresPortraitGate({
    usableWidth = 390, usableHeight = 844
  }), 'phone portrait must require landscape')
  assert(profileRequiresPortraitGate({
    usableWidth = 768, usableHeight = 1024
  }), 'tablet portrait must require landscape')
  assert(not profileRequiresPortraitGate({
    usableWidth = 844, usableHeight = 390
  }), 'phone landscape must release portrait gate')
  assert(not profileRequiresPortraitGate({
    usableWidth = 1024, usableHeight = 768
  }), 'tablet landscape must release portrait gate')
  assert(not profileRequiresPortraitGate({
    usableWidth = 600, usableHeight = 600
  }), 'square viewport must not enter portrait gate')
end

local function safeNotify(blocked, profile)
  local snapshot = {}
  for _, callback in pairs(listeners) do
    snapshot[#snapshot + 1] = callback
  end
  for _, callback in ipairs(snapshot) do
    local ok, errorMessage = pcall(callback, blocked, profile, generation)
    if not ok then
      g_logger.error(
        '[client_mobileui] portrait callback failed: ' ..
        tostring(errorMessage))
    end
  end
end

local function cancelGlobalInput()
  local gameMobileUi = modules and modules.game_mobileui
  if gameMobileUi and type(gameMobileUi.cancelInput) == 'function' then
    gameMobileUi.cancelInput()
  end

  local gameInterface = modules and modules.game_interface
  local gameMap = gameInterface and gameInterface.getMapPanel and
    gameInterface.getMapPanel()
  if gameMap and gameMap.cancelPendingRelease then
    gameMap:cancelPendingRelease()
  end

  local joystick = modules and modules.game_joystick
  if joystick and joystick.cancelGesture then
    joystick.cancelGesture()
  end

  local shortcuts = modules and modules.game_shortcuts
  if shortcuts and shortcuts.resetShortcuts then
    shortcuts.resetShortcuts()
  end

  if g_window and g_window.hideVirtualKeyboard then
    g_window.hideVirtualKeyboard()
  end
end

local function consumePointer(_, _, button)
  return button == (MouseLeftButton or 1) or
    button == (MouseRightButton or 2)
end

local function destroyPortraitWidget()
  local widget = portraitWidget
  portraitWidget = nil
  if widget and not widget:isDestroyed() then
    if widget.ungrabKeyboard then
      widget:ungrabKeyboard()
    end
    widget:destroy()
  end
end

local function ensurePortraitWidget()
  if portraitWidget and not portraitWidget:isDestroyed() then
    return true
  end

  local ok, widget = pcall(
    g_ui.createWidget, 'MobilePortraitGate', g_ui.getRootWidget())
  if not ok or not widget or widget:isDestroyed() then
    g_logger.error(
      '[client_mobileui] portrait view creation failed module=' ..
      'client_mobileui view=portrait profile=portrait: ' ..
      tostring(widget))
    return false
  end

  portraitWidget = widget
  widget.onMousePress = consumePointer
  widget.onMouseMove = function() return true end
  widget.onMouseRelease = consumePointer
  widget.onKeyDown = function() return true end
  widget.onDestroy = function()
    if portraitWidget == widget then
      portraitWidget = nil
    end
  end
  return true
end

local function normalizeRestoreForeground(state, owner)
  if state == 'modal' and owner then
    return normalizeRestoreForeground(
      owner.previousForegroundState or 'gameplay',
      owner.previousForegroundOwner)
  end
  if state == 'gameplay' or state == 'drawer' or state == 'chat' or
      state == 'portrait' then
    return 'gameplay', nil
  end
  return state or 'gameplay', owner
end

local function enterPortrait(profile)
  if active or terminating then
    return false
  end

  cancelGlobalInput()
  if not ensurePortraitWidget() then
    return false
  end

  local state, owner = getForeground()
  baseRestoreState, baseRestoreOwner =
    normalizeRestoreForeground(state, owner)
  restoreState, restoreOwner = baseRestoreState, baseRestoreOwner
  active = true
  generation = generation + 1

  setForeground('portrait', portraitOwner)
  local acquiredState, acquiredOwner = getForeground()
  if acquiredState ~= 'portrait' or acquiredOwner ~= portraitOwner then
    active = false
    destroyPortraitWidget()
    return false
  end

  if type(supersedeModal) == 'function' then
    supersedeModal()
  end
  cancelGlobalInput()
  portraitWidget:show()
  portraitWidget:raise()
  portraitWidget:focus()
  if portraitWidget.grabKeyboard then
    portraitWidget:grabKeyboard()
  end
  safeNotify(true, profile)
  return true
end

local function leavePortrait(profile)
  if not active then
    return false
  end

  generation = generation + 1
  cancelGlobalInput()
  releasing = true
  local state, owner = getForeground()
  if state == 'portrait' and owner == portraitOwner then
    setForeground(restoreState or 'gameplay', restoreOwner)
  end
  active = false
  safeNotify(false, profile)
  destroyPortraitWidget()
  restoreState = nil
  restoreOwner = nil
  baseRestoreState = nil
  baseRestoreOwner = nil
  releasing = false
  return true
end

local function applyPortraitProfile(profile)
  if profileRequiresPortraitGate(profile) then
    if active then
      cancelGlobalInput()
      if portraitWidget and not portraitWidget:isDestroyed() then
        portraitWidget:raise()
      end
      return false
    end
    return enterPortrait(profile)
  end
  return leavePortrait(profile)
end

function portraitOwner:onForegroundGained()
  if not active or not portraitWidget or portraitWidget:isDestroyed() then
    return
  end
  cancelGlobalInput()
  portraitWidget:show()
  portraitWidget:raise()
  portraitWidget:focus()
end

function portraitOwner:onForegroundLost(nextState, nextOwner)
  if releasing or terminating or not active then
    return
  end
  if nextState == 'reconnecting' then
    restoreState = nextState
    restoreOwner = nextOwner
  end
  cancelGlobalInput()
  setForeground('portrait', portraitOwner)
end

function isPortraitGateActive()
  return active
end

function isPortraitProfile(profile)
  return profileRequiresPortraitGate(profile)
end

function getPortraitGeneration()
  return generation
end

function subscribePortraitGate(callback)
  assert(type(callback) == 'function',
    'portrait callback must be a function')
  nextListenerId = nextListenerId + 1
  local id = nextListenerId
  listeners[id] = callback
  local subscribed = true
  return function()
    if not subscribed then
      return
    end
    subscribed = false
    listeners[id] = nil
  end
end

function deferPortraitForeground(state, owner)
  if not active or state ~= 'reconnecting' or not owner then
    return false
  end
  restoreState = state
  restoreOwner = owner
  return true
end

function clearPortraitDeferredForeground(owner)
  if not active or restoreOwner ~= owner then
    return false
  end
  restoreState = baseRestoreState or 'gameplay'
  restoreOwner = baseRestoreOwner
  return true
end

function initPortrait()
  if unsubscribeProfile or not isV2Enabled or not isV2Enabled() then
    return
  end
  unsubscribeProfile = subscribeProfile(applyPortraitProfile)
  applyPortraitProfile(getProfile())
end

function terminatePortrait()
  if terminating then
    return
  end
  terminating = true
  if unsubscribeProfile then
    unsubscribeProfile()
    unsubscribeProfile = nil
  end
  if active then
    releasing = true
    local state, owner = getForeground()
    if state == 'portrait' and owner == portraitOwner then
      setForeground('gameplay', nil)
    end
    active = false
    releasing = false
  end
  destroyPortraitWidget()
  listeners = {}
  restoreState = nil
  restoreOwner = nil
  baseRestoreState = nil
  baseRestoreOwner = nil
  terminating = false
end
