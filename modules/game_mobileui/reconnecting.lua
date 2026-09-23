MobileReconnecting = {}

local Adapter = {}
Adapter.__index = Adapter

local function integer(value)
  return math.max(0, math.floor(tonumber(value) or 0))
end

function MobileReconnecting.computeGeometry(profile)
  profile = profile or {}
  local safe = profile.safe or {}
  local usableWidth = integer(profile.usableWidth)
  local usableHeight = integer(profile.usableHeight)
  if usableWidth == 0 or usableHeight == 0 then
    return nil
  end

  local margin = 12
  local width = math.min(560, math.max(0, usableWidth - margin * 2))
  local height = math.min(280, math.max(0, usableHeight - margin * 2))
  if width < 48 or height < 144 then
    return nil
  end
  return {
    x = integer(safe.left) + math.floor((usableWidth - width) / 2),
    y = integer(safe.top) + math.floor((usableHeight - height) / 2),
    width = width,
    height = height
  }
end

function MobileReconnecting.runSelfTests()
  for _, profile in ipairs({
    {
      usableWidth = 844,
      usableHeight = 390,
      safe = { left = 0, top = 0, right = 0, bottom = 0 }
    },
    {
      usableWidth = 980,
      usableHeight = 720,
      safe = { left = 22, top = 18, right = 22, bottom = 18 }
    }
  }) do
    local geometry = MobileReconnecting.computeGeometry(profile)
    assert(geometry and geometry.width >= 48 and geometry.height >= 144,
      'reconnect sheet must remain bounded and touch sized')
    assert(geometry.x >= profile.safe.left and
      geometry.y >= profile.safe.top and
      geometry.x + geometry.width <=
        profile.safe.left + profile.usableWidth and
      geometry.y + geometry.height <=
        profile.safe.top + profile.usableHeight,
      'reconnect sheet must remain inside usable bounds')
  end
end

local function defaultLogError(message)
  g_logger.error(
    '[game_mobileui] reconnect callback failed: ' .. tostring(message))
end

function Adapter:_foreground()
  return self.mobileUi.getForeground()
end

function Adapter:_ownsForeground()
  local state, owner = self:_foreground()
  return state == 'reconnecting' and owner == self.foregroundOwner
end

function Adapter:_setButtonsEnabled()
  if self.retry and not self.retry:isDestroyed() then
    self.retry:setEnabled(self.active and not self.retryPending)
  end
  if self.logout and not self.logout:isDestroyed() then
    self.logout:setEnabled(self.active and not self.logoutPending)
  end
end

function Adapter:_applyProfile(profile)
  if not self.active or not self.surface or self.surface:isDestroyed() then
    return false
  end
  local geometry = MobileReconnecting.computeGeometry(profile)
  if not geometry then
    return false
  end
  self.surface:setRect(geometry)
  if self.mobileUi.applyOverlayTree then
    self.mobileUi.applyOverlayTree(self.backdrop, profile)
  end
  return true
end

function Adapter:_destroyUi()
  if self.unsubscribeProfile then
    self.unsubscribeProfile()
    self.unsubscribeProfile = nil
  end
  local backdrop = self.backdrop
  self.backdrop = nil
  self.surface = nil
  self.reasonLabel = nil
  self.retry = nil
  self.logout = nil
  if backdrop and not backdrop:isDestroyed() then
    self.destroying = true
    if backdrop.ungrabKeyboard then
      backdrop:ungrabKeyboard()
    end
    backdrop:destroy()
    self.destroying = false
  end
end

function Adapter:_createUi()
  if self.backdrop and not self.backdrop:isDestroyed() then
    return true
  end
  local ok, backdrop = pcall(
    self.createWidget, 'MobileReconnectBackdrop', self.getRoot())
  if not ok or not backdrop or backdrop:isDestroyed() then
    self.logError(backdrop)
    return false
  end

  self.backdrop = backdrop
  self.surface = backdrop:recursiveGetChildById('reconnectSurface')
  self.reasonLabel = backdrop:recursiveGetChildById('reconnectReason')
  self.retry = backdrop:recursiveGetChildById('reconnectRetry')
  self.logout = backdrop:recursiveGetChildById('reconnectLogout')
  if not self.surface or not self.reasonLabel or not self.retry or
      not self.logout then
    self:_destroyUi()
    self.logError('reconnect UI is incomplete')
    return false
  end

  backdrop.onMousePress = function() return true end
  backdrop.onMouseMove = function() return true end
  backdrop.onMouseRelease = function() return true end
  backdrop.onKeyDown = function() return true end
  backdrop.onDestroy = function()
    if not self.destroying and self.active then
      self:_abandon()
    end
  end
  self.retry.onClick = function()
    return self:retryNow()
  end
  self.logout.onClick = function()
    return self:logOut()
  end
  self.unsubscribeProfile = self.mobileUi.subscribeProfile(function(profile)
    if self.active and not self:_applyProfile(profile) then
      self.logError('reconnect profile cannot fit')
    end
  end)
  if not self:_applyProfile(self.mobileUi.getProfile()) then
    self:_destroyUi()
    return false
  end
  return true
end

function Adapter:_present()
  if not self.backdrop or self.backdrop:isDestroyed() then
    return false
  end
  self.backdrop:show()
  self.backdrop:raise()
  self.backdrop:focus()
  if self.backdrop.grabKeyboard then
    self.backdrop:grabKeyboard()
  end
  self:_setButtonsEnabled()
  return true
end

function Adapter:_abandon()
  if not self.active then
    return
  end
  self.generation = self.generation + 1
  self.active = false
  self.retryPending = false
  self.logoutPending = false
  self.mobileUi.clearPortraitDeferredForeground(self.foregroundOwner)
  self:_destroyUi()
end

function Adapter:show(reason)
  if self.terminated then
    return false
  end

  self.cancelGestures()
  if self.mobileUi.supersedeModal then
    self.mobileUi.supersedeModal()
  end
  self.generation = self.generation + 1
  self.active = true
  self.retryPending = false
  self.logoutPending = false
  if not self:_createUi() then
    self.active = false
    return false
  end

  self.reasonLabel:setText(tostring(reason or tr('Connection lost.')))
  self:_setButtonsEnabled()
  if self.mobileUi.isPortraitGateActive() then
    self.mobileUi.deferPortraitForeground(
      'reconnecting', self.foregroundOwner)
    self.backdrop:hide()
    return true
  end

  self.acquiring = true
  local accepted = self.mobileUi.setForeground(
    'reconnecting', self.foregroundOwner)
  self.acquiring = false
  if not accepted or not self:_ownsForeground() then
    self:_abandon()
    return false
  end
  return self:_present()
end

function Adapter:retryNow()
  if not self.active or self.retryPending or self.logoutPending then
    return false
  end
  if not self:_ownsForeground() and
      not self.mobileUi.isPortraitGateActive() then
    return false
  end

  self.retryPending = true
  self:_setButtonsEnabled()
  local generation = self.generation
  local ok, result = pcall(self.onRetry)
  if not ok then
    self.logError(result)
  end
  if self.active and self.generation == generation and
      (not ok or result == false) then
    self.retryPending = false
    self:_setButtonsEnabled()
  end
  return ok and result ~= false
end

function Adapter:logOut()
  if not self.active or self.logoutPending then
    return false
  end
  self.logoutPending = true
  self.retryPending = false
  self:_setButtonsEnabled()
  local generation = self.generation
  local ok, result = pcall(self.onLogout)
  if not ok then
    self.logError(result)
  end
  if self.active and self.generation == generation then
    self:close()
  end
  return ok and result ~= false
end

function Adapter:updateReason(reason)
  if not self.active then
    return self:show(reason)
  end
  self.generation = self.generation + 1
  self.retryPending = false
  self.logoutPending = false
  if self.reasonLabel and not self.reasonLabel:isDestroyed() then
    self.reasonLabel:setText(tostring(reason or tr('Connection lost.')))
  end
  self:_setButtonsEnabled()
  if self:_ownsForeground() then
    self:_present()
  end
  return true
end

function Adapter:close()
  if not self.active and not self.backdrop then
    return false
  end
  self.closing = true
  self.generation = self.generation + 1
  self.active = false
  self.retryPending = false
  self.logoutPending = false
  self.mobileUi.clearPortraitDeferredForeground(self.foregroundOwner)
  local ownsForeground = self:_ownsForeground()
  self:_destroyUi()
  if ownsForeground then
    self.mobileUi.setForeground('gameplay', nil)
  end
  self.closing = false
  return true
end

function Adapter:isOpen()
  return self.active and self.backdrop ~= nil and
    not self.backdrop:isDestroyed()
end

function Adapter:onGameStart()
  self:close()
end

function Adapter:terminate()
  if self.terminated then
    return
  end
  self.terminated = true
  self:close()
end

function MobileReconnecting.create(options)
  options = options or {}
  local mobileUi = options.mobileUi or modules.client_mobileui
  local adapter = setmetatable({
    mobileUi = mobileUi,
    createWidget = options.createWidget or g_ui.createWidget,
    getRoot = options.getRoot or g_ui.getRootWidget,
    cancelGestures = options.cancelGestures or function() end,
    onRetry = options.onRetry or function() return false end,
    onLogout = options.onLogout or function() return false end,
    logError = options.logError or defaultLogError,
    generation = 0,
    active = false,
    retryPending = false,
    logoutPending = false,
    terminated = false
  }, Adapter)

  adapter.foregroundOwner = {}
  function adapter.foregroundOwner:onForegroundLost(nextState)
    adapter.cancelGestures()
    if adapter.closing or adapter.acquiring or not adapter.active then
      return
    end
    if nextState == 'portrait' or nextState == 'modal' then
      if adapter.backdrop and not adapter.backdrop:isDestroyed() then
        adapter.backdrop:hide()
      end
      return
    end
    adapter:_abandon()
  end
  function adapter.foregroundOwner:onForegroundGained()
    if adapter.active then
      adapter:_present()
    end
  end
  return adapter
end
