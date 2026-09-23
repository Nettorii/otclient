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

function Adapter:_nextGeneration()
  self.generation = self.generation + 1
  return self.generation
end

function Adapter:_bindActions(generation)
  if self.retry and not self.retry:isDestroyed() then
    self.retry.onClick = function()
      return self:retryNow(generation)
    end
  end
  if self.logout and not self.logout:isDestroyed() then
    self.logout.onClick = function()
      return self:logOut(generation)
    end
  end
end

function Adapter:_applyProfile(profile)
  if not self.active then
    return false
  end
  if self.fallbackUi then
    return self.backdrop and not self.backdrop:isDestroyed()
  end
  if not self.surface or self.surface:isDestroyed() then
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
  self.fallbackUi = false
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

  local partialBackdrop
  local safeCreate = self.mobileUi.safeCreateMobileView
  if type(safeCreate) ~= 'function' then
    safeCreate = function(config)
      local ok, result = pcall(config.create)
      if ok then
        return result
      end
      if config.cleanup then
        pcall(config.cleanup)
      end
      self.logError(result)
      return nil
    end
  end
  local shell, fallback = safeCreate({
    module = 'game_mobileui',
    view = 'reconnecting',
    profile = self.mobileUi.getProfile(),
    state = 'reconnecting',
    owner = self.foregroundOwner,
    title = tr('Reconnecting'),
    message = tr('Connection lost.'),
    actions = {
      { text = tr('Retry'), callback = function()
        return self:retryNow(self.generation)
      end },
      { text = tr('Log out'), callback = function()
        return self:logOut(self.generation)
      end }
    },
    create = function()
      partialBackdrop = self.createWidget(
        'MobileReconnectBackdrop', self.getRoot())
      local result = {
        backdrop = partialBackdrop,
        surface =
          partialBackdrop:recursiveGetChildById('reconnectSurface'),
        reasonLabel =
          partialBackdrop:recursiveGetChildById('reconnectReason'),
        retry =
          partialBackdrop:recursiveGetChildById('reconnectRetry'),
        logout =
          partialBackdrop:recursiveGetChildById('reconnectLogout')
      }
      assert(result.surface and result.reasonLabel and result.retry and
        result.logout, 'reconnect UI is incomplete')
      return result
    end,
    cleanup = function()
      if partialBackdrop and not partialBackdrop:isDestroyed() then
        partialBackdrop:destroy()
      end
    end
  })
  if not shell then
    if not fallback then
      return false
    end
    shell = {
      backdrop = fallback.widget,
      surface = fallback.surface,
      reasonLabel = fallback.label,
      retry = fallback.buttons[1],
      logout = fallback.buttons[2]
    }
    self.fallbackUi = true
  end

  self.backdrop = shell.backdrop
  self.surface = shell.surface
  self.reasonLabel = shell.reasonLabel
  self.retry = shell.retry
  self.logout = shell.logout
  if not self.backdrop or
      (not self.fallbackUi and (not self.surface or not self.reasonLabel or
        not self.retry or not self.logout)) then
    self:_destroyUi()
    return false
  end

  local backdrop = self.backdrop
  local fallbackOnDestroy = self.backdrop.onDestroy
  backdrop.onMousePress = function() return true end
  backdrop.onMouseMove = function() return true end
  backdrop.onMouseRelease = function() return true end
  backdrop.onKeyDown = function() return true end
  backdrop.onDestroy = function(...)
    if fallbackOnDestroy then
      fallbackOnDestroy(...)
    end
    if not self.destroying and self.active then
      self:_abandon()
    end
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

function Adapter:_schedulePresent()
  if not self.active or self.terminated then
    return false
  end
  removeEvent(self.raiseEvent)
  local generation = self.generation
  self.raiseEvent = addEvent(function()
    self.raiseEvent = nil
    if self.active and not self.terminated and
        self.generation == generation then
      self:_reclaimForeground()
    end
  end)
  return true
end

function Adapter:_reclaimForeground()
  if not self.active then
    return false
  end
  if self.mobileUi.isPortraitGateActive() then
    self.mobileUi.deferPortraitForeground(
      'reconnecting', self.foregroundOwner)
    if self.backdrop and not self.backdrop:isDestroyed() then
      self.backdrop:hide()
    end
    return true
  end
  if self.mobileUi.supersedeModal then
    self.mobileUi.supersedeModal()
  end
  self.cancelGestures()
  self.acquiring = true
  local accepted = self.mobileUi.setForeground(
    'reconnecting', self.foregroundOwner)
  self.acquiring = false
  if not accepted or not self:_ownsForeground() then
    return false
  end
  return self:_present()
end

function Adapter:_abandon()
  if not self.active then
    return
  end
  self:_nextGeneration()
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
  local generation = self:_nextGeneration()
  self.active = true
  self.retryPending = false
  self.logoutPending = false
  if not self:_createUi() then
    self.active = false
    return false
  end

  if self.reasonLabel and not self.reasonLabel:isDestroyed() then
    self.reasonLabel:setText(tostring(reason or tr('Connection lost.')))
  end
  self:_bindActions(generation)
  self:_setButtonsEnabled()
  if not self:_reclaimForeground() then
    self:_abandon()
    return false
  end
  return true, generation
end

function Adapter:retryNow(expectedGeneration)
  if expectedGeneration ~= nil and expectedGeneration ~= self.generation then
    return false
  end
  if not self.active or self.retryPending or self.logoutPending then
    return false
  end
  if not self:_ownsForeground() and
      not self.mobileUi.isPortraitGateActive() then
    return false
  end

  local generation = self:_nextGeneration()
  self.retryPending = true
  self:_bindActions(generation)
  self:_setButtonsEnabled()
  local ok, result = pcall(self.onRetry, generation)
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

function Adapter:logOut(expectedGeneration)
  if expectedGeneration ~= nil and expectedGeneration ~= self.generation then
    return false
  end
  if not self.active or self.logoutPending then
    return false
  end
  local generation = self:_nextGeneration()
  self.logoutPending = true
  self.retryPending = false
  self:_bindActions(generation)
  self:_setButtonsEnabled()
  local ok, result = pcall(self.onLogout, generation)
  if not ok then
    self.logError(result)
  end
  if result ~= 'pending' and self.active and
      self.generation == generation then
    self:close()
  end
  return ok and result ~= false
end

function Adapter:updateReason(reason)
  if not self.active then
    return self:show(reason)
  end
  local generation = self:_nextGeneration()
  self.retryPending = false
  self.logoutPending = false
  if self.reasonLabel and not self.reasonLabel:isDestroyed() then
    self.reasonLabel:setText(tostring(reason or tr('Connection lost.')))
  end
  self:_bindActions(generation)
  self:_setButtonsEnabled()
  return self:_reclaimForeground(), generation
end

function Adapter:close()
  if not self.active and not self.backdrop then
    return false
  end
  self.closing = true
  self:_nextGeneration()
  self.active = false
  self.retryPending = false
  self.logoutPending = false
  removeEvent(self.raiseEvent)
  self.raiseEvent = nil
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
  if self.appCallbacks then
    disconnect(g_app, self.appCallbacks)
    self.appCallbacks = nil
  end
  if self.gameCallbacks then
    disconnect(g_game, self.gameCallbacks)
    self.gameCallbacks = nil
  end
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
    if nextState == 'portrait' then
      if adapter.backdrop and not adapter.backdrop:isDestroyed() then
        adapter.backdrop:hide()
      end
      return
    end
    adapter:_reclaimForeground()
  end
  function adapter.foregroundOwner:onForegroundGained()
    if adapter.active then
      adapter:_present()
    end
  end
  adapter.appCallbacks = {
    onRun = function() adapter:_schedulePresent() end,
    onUpdateFinished = function() adapter:_schedulePresent() end
  }
  adapter.gameCallbacks = {
    onGameEnd = function() adapter:_schedulePresent() end
  }
  connect(g_app, adapter.appCallbacks)
  connect(g_game, adapter.gameCallbacks)
  return adapter
end
