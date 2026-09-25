MobileSession = {}

local Session = {}
Session.__index = Session

-- The server answers a refused logout ("You may not logout during a fight")
-- with a text message and keeps the connection; an accepted one disconnects
-- well within this window.
local LOGOUT_REFUSAL_MS = 3000

function MobileSession.isNativeApp(platform)
  platform = platform or g_platform
  return platform.isMobile() and not platform.isBrowser()
end

function Session:canExit()
  return MobileSession.isNativeApp(self.platform)
end

function Session:isModalOpen()
  return self.modal ~= nil and self.modal.handle ~= nil and
    self.modal.handle:isOpen()
end

function Session:closeModal()
  local modal = self.modal
  self.modal = nil
  if modal and modal.handle and modal.handle:isOpen() then
    modal.handle:close()
  end
end

function Session:_cancelRefusalCheck()
  if self.refusalEvent then
    self.removeEvent(self.refusalEvent)
    self.refusalEvent = nil
  end
end

function Session:_exitNow()
  self.exitPending = false
  self:_cancelRefusalCheck()
  self.scheduleEvent(self.exitApp, 10)
end

function Session:_logout(force)
  local characterList = self.characterList()
  if characterList and characterList.beginIntentionalLogout then
    characterList.beginIntentionalLogout()
  end
  self:_cancelRefusalCheck()
  if force then
    self.game.forceLogout()
    return
  end
  self.game.safeLogout()
  self.refusalEvent = self.scheduleEvent(function()
    self.refusalEvent = nil
    if not self.game.isOnline() then
      return
    end
    self.exitPending = false
    local current = self.characterList()
    if current and current.abortIntentionalLogout then
      current.abortIntentionalLogout()
    end
  end, LOGOUT_REFUSAL_MS)
end

function Session:_confirm(exitAfter)
  self:closeModal()
  if exitAfter and not self.game.isOnline() then
    self:_exitNow()
    return
  end
  if not self.game.isOnline() then
    return
  end
  if self.onBeforeLogout then
    self.onBeforeLogout()
  end
  local force = not self.game.isConnectionOk()
  self.exitPending = exitAfter == true
  self:_logout(force)
end

function Session:_open(exitAfter)
  self:closeModal()
  local failing = self.game.isOnline() and not self.game.isConnectionOk()
  local title, message, confirmText
  if failing then
    title = exitAfter and tr('Exit game') or tr('Log out')
    message = tr('Your connection is failing. If you log out now your character may stay online. Force log out?')
    confirmText = tr('Force log out')
  elseif exitAfter then
    title = tr('Exit game')
    message = self.game.isOnline() and
      tr('Log out and close the game?') or tr('Close the game?')
    confirmText = tr('Exit game')
  else
    title = tr('Log out')
    message = tr('Are you sure you want to log out?')
    confirmText = tr('Log out')
  end

  local modal = {}
  self.modal = modal
  local function isCurrent()
    return self.modal == modal
  end
  local function cancel()
    if isCurrent() then
      self:closeModal()
    end
  end
  local function confirm()
    if isCurrent() then
      self:_confirm(exitAfter)
    end
  end

  local handle = self.mobileUi.showModal({
    title = title,
    body = self.createMessage(message),
    buttons = {
      { id = 'mobileSessionCancel', text = tr('Cancel'), callback = cancel },
      { id = 'mobileSessionConfirm', text = confirmText, callback = confirm }
    },
    onEscape = cancel,
    onClose = function()
      if isCurrent() then
        self.modal = nil
      end
    end
  })
  if not isCurrent() then
    return false
  end
  modal.handle = handle
  if not handle or not handle:isOpen() then
    self.modal = nil
    return false
  end
  return true
end

function Session:confirmLogout()
  return self:_open(false)
end

function Session:confirmExit()
  if not self:canExit() then
    return false
  end
  return self:_open(true)
end

function Session:handleSystemBack()
  if not self:canExit() or not self.game.isOnline() or
      not self.isGameplayIdle() then
    return false
  end
  return self:confirmLogout()
end

function Session:onGameEnd()
  self:closeModal()
  self:_cancelRefusalCheck()
  if self.exitPending then
    self:_exitNow()
  end
end

function Session:terminate()
  self:closeModal()
  self:_cancelRefusalCheck()
  self.exitPending = false
end

function MobileSession.create(options)
  options = options or {}
  return setmetatable({
    game = options.game or g_game,
    platform = options.platform or g_platform,
    mobileUi = options.mobileUi or modules.client_mobileui,
    characterList = options.characterList or function()
      local enterGame = modules.client_entergame
      return enterGame and enterGame.CharacterList
    end,
    exitApp = options.exitApp or function()
      g_game.cancelLogin()
      g_app.exit()
    end,
    scheduleEvent = options.scheduleEvent or scheduleEvent,
    removeEvent = options.removeEvent or removeEvent,
    createMessage = options.createMessage or function(text)
      local label = g_ui.createWidget('MobileSessionMessage')
      label:setText(text)
      return label
    end,
    onBeforeLogout = options.onBeforeLogout,
    isGameplayIdle = options.isGameplayIdle or function() return false end,
    exitPending = false
  }, Session)
end
