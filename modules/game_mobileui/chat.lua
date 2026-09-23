MobileChat = {}

local Adapter = {}
Adapter.__index = Adapter

local MAX_VISIBLE_ROWS = 80
local MAX_SENT_HISTORY = 100

local function integer(value)
  return math.max(0, math.floor(tonumber(value) or 0))
end

local function validHotbarPage(page)
  page = tonumber(page)
  if page == 1 or page == 2 then
    return page
  end
  return nil
end

local function isContinuationByte(byte)
  return byte and byte >= 0x80 and byte < 0xC0
end

local function boundaryBeforeOrAt(text, cursor)
  cursor = math.max(0, math.min(#text, tonumber(cursor) or #text))
  while cursor > 0 and isContinuationByte(text:byte(cursor + 1)) do
    cursor = cursor - 1
  end
  return cursor
end

local function boundaryAfter(text, boundary)
  if boundary >= #text then
    return #text
  end
  local cursor = boundary + 1
  while cursor < #text and isContinuationByte(text:byte(cursor + 1)) do
    cursor = cursor + 1
  end
  return cursor
end

function MobileChat.computeGeometry(profile)
  profile = profile or {}
  local safe = profile.safe or {}
  local left = integer(safe.left)
  local top = integer(safe.top)
  local usableWidth = integer(profile.usableWidth)
  local usableHeight = integer(profile.usableHeight)
  if usableWidth == 0 or usableHeight == 0 then
    return nil
  end

  local margin = math.min(12, math.floor(usableWidth / 20))
  local width = math.max(0, math.min(720, usableWidth - margin * 2))
  local availableHeight = math.max(0, usableHeight - margin)
  local desiredHeight = math.min(480, math.floor(usableHeight * 0.72))
  local height = math.min(availableHeight, math.max(160, desiredHeight))
  local headerHeight = 48
  local footerHeight = 56

  return {
    x = left + math.floor((usableWidth - width) / 2),
    y = top + usableHeight - height,
    width = width,
    height = height,
    headerHeight = headerHeight,
    footerHeight = footerHeight
  }
end

local function messageText(message)
  local text = tostring(message.text or '')
  local name = tostring(message.name or '')
  if name == '' then
    return text
  end
  local level = tonumber(message.level) or 0
  if level > 0 then
    return string.format('%s [%d]: %s', name, level, text)
  end
  return name .. ': ' .. text
end

function Adapter:_foreground()
  return self.mobileUi.getForeground()
end

function Adapter:_ownsForeground()
  local state, owner = self:_foreground()
  return state == 'chat' and owner == self.foregroundOwner
end

function Adapter:_activeTab()
  if self.activeTab then
    return self.activeTab()
  end
  if self.console and type(self.console.getCurrentTab) == 'function' then
    return self.console.getCurrentTab()
  end
  return nil
end

function Adapter:_activeChannelName()
  local tab = self:_activeTab()
  if tab and type(tab.getText) == 'function' then
    return tab:getText()
  end
  return self.currentChannel
end

function Adapter:_destroyRows()
  self.rows = {}
  if self.messageList and not self.messageList:isDestroyed() then
    self.messageList:destroyChildren()
  end
end

function Adapter:_scrollToBottom(row)
  if self.messageList and self.messageList.ensureChildVisible and row then
    self.messageList:ensureChildVisible(row)
  end
  if self.messageScrollBar and self.messageScrollBar.setValue and
      self.messageScrollBar.getMaximum then
    self.messageScrollBar:setValue(self.messageScrollBar:getMaximum())
  end
end

function Adapter:_appendMessage(message)
  if not self.messageList or self.messageList:isDestroyed() then
    return false
  end
  local row = self.createWidget('MobileChatMessageRow', self.messageList)
  row:setText(messageText(message))
  if message.color and message.color ~= '' then
    row:setColor(message.color)
  end
  row.semanticMessage = {
    channel = message.channel,
    name = message.name,
    level = message.level,
    mode = message.mode,
    text = message.text,
    color = message.color,
    timestamp = message.timestamp
  }
  self.rows[#self.rows + 1] = row
  if #self.rows > self.maxVisibleRows then
    local oldest = table.remove(self.rows, 1)
    if oldest and not oldest:isDestroyed() then
      oldest:destroy()
    end
  end
  self:_scrollToBottom(row)
  return true
end

function Adapter:_loadChannel(channelName)
  channelName = channelName and tostring(channelName) or nil
  self.currentChannel = channelName
  if self.channelLabel and not self.channelLabel:isDestroyed() then
    self.channelLabel:setText(channelName or '')
  end
  self:_destroyRows()
  if not channelName or not self.console or
      type(self.console.getRecentMessages) ~= 'function' then
    self:_updateChannelControls()
    return
  end
  for _, message in ipairs(
      self.console.getRecentMessages(channelName, self.maxVisibleRows)) do
    self:_appendMessage(message)
  end
  self:_updateChannelControls()
end

function Adapter:_updateChannelControls()
  local count = 0
  if self.console and
      type(self.console.getOpenChannelNames) == 'function' then
    count = #self.console.getOpenChannelNames()
  end
  local enabled = self.currentChannel ~= nil and count > 1
  for _, button in ipairs({
    self.previousChannel, self.nextChannel
  }) do
    if button and button.setEnabled and
        (not button.isDestroyed or not button:isDestroyed()) then
      button:setEnabled(enabled)
    end
  end
end

function Adapter:_reconcileChannel(preferredChannel)
  local names = {}
  local hasChannelList = self.console and
    type(self.console.getOpenChannelNames) == 'function'
  if hasChannelList then
    names = self.console.getOpenChannelNames()
  end
  local selected = preferredChannel
  if selected == nil and self.console and
      type(self.console.getCurrentChannelName) == 'function' then
    selected = self.console.getCurrentChannelName()
  end
  if selected == nil then
    selected = self:_activeChannelName()
  end

  local valid = not hasChannelList and selected ~= nil
  if hasChannelList then
    for _, name in ipairs(names) do
      if name == selected then
        valid = true
        break
      end
    end
  end
  if not valid then
    selected = nil
    local activeName = self:_activeChannelName()
    for _, name in ipairs(names) do
      if name == activeName then
        selected = activeName
        break
      end
    end
    if not selected then
      selected = names[1]
    end
  end

  if selected ~= self.currentChannel then
    self:_loadChannel(selected)
  else
    self:_updateChannelControls()
  end
  return selected
end

function Adapter:_onChannelChange(change, session)
  if not self.open or self.session ~= session then
    return
  end
  self:_reconcileChannel(change and change.current or nil)
end

function Adapter:_onMessage(message, session)
  if not self.open or self.session ~= session then
    return
  end
  self:_reconcileChannel()
  if message.channel ~= self.currentChannel then
    return
  end
  self:_appendMessage(message)
end

function Adapter:_applyProfile(profile)
  if not self.open or not self.surface or self.surface:isDestroyed() then
    return false
  end
  local geometry = MobileChat.computeGeometry(profile)
  if not geometry then
    return false
  end
  self.profile = profile
  self.surface:setRect(geometry)
  if self.mobileUi.applyOverlayTree then
    self.mobileUi.applyOverlayTree(self.backdrop, profile)
  end
  if not self.keyboardDismissed then
    self:_focusInput(false)
  end
  return true
end

function Adapter:_hideKeyboard()
  if self.hideKeyboard then
    pcall(self.hideKeyboard)
  end
end

function Adapter:_releaseKeyboardFocus(hideKeyboard)
  if self.focusEvent then
    self.cancel(self.focusEvent)
    self.focusEvent = nil
  end
  if self.input and not self.input:isDestroyed() and
      self.input.ungrabKeyboard then
    self.input:ungrabKeyboard()
  end
  local root = self.getRoot()
  if root and root.focus then
    root:focus()
  end
  if hideKeyboard then
    self:_hideKeyboard()
  end
end

function Adapter:_focusInput(showKeyboard)
  local input = self.input
  if not self.open or not input or input:isDestroyed() then
    return false
  end

  local child = input
  local parent = child:getParent()
  while parent do
    if parent.focusChild then
      parent:focusChild(child, ActiveFocusReason or MouseFocusReason)
    end
    child = parent
    parent = parent:getParent()
  end
  if input.focus then
    input:focus(ActiveFocusReason)
  end
  if input.grabKeyboard then
    input:grabKeyboard()
  end

  if showKeyboard and UITextEdit and UITextEdit.onMousePress then
    self.keyboardDismissed = false
    local position = {
      x = input:getX() + math.max(1, input:getWidth() - 4),
      y = input:getY() + math.max(1, math.floor(input:getHeight() / 2))
    }
    pcall(UITextEdit.onMousePress, input, position, MouseLeftButton or 1)
  end
  return true
end

function Adapter:_scheduleFocus(session)
  if self.focusEvent then
    self.cancel(self.focusEvent)
  end
  self.focusEvent = self.schedule(function()
    self.focusEvent = nil
    if self.open and self.session == session and self:_ownsForeground() then
      self:_focusInput(true)
    end
  end)
end

function Adapter:_switchChannel(direction)
  if not self.open then
    return false
  end
  local channelName
  if direction < 0 and
      type(self.console.selectPreviousChannel) == 'function' then
    channelName = self.console.selectPreviousChannel()
  elseif direction > 0 and
      type(self.console.selectNextChannel) == 'function' then
    channelName = self.console.selectNextChannel()
  else
    local tabBar = self.console and self.console.consoleTabBar
    if not tabBar then
      return false
    end
    if direction < 0 and tabBar.selectPrevTab then
      tabBar:selectPrevTab()
    elseif direction > 0 and tabBar.selectNextTab then
      tabBar:selectNextTab()
    else
      return false
    end
  end
  self:_reconcileChannel(channelName)
  self:_focusInput(false)
  return true
end

function Adapter:navigateHistory(step)
  if not self.input then
    return nil
  end
  local count = #self.sentHistory
  if count == 0 then
    return nil
  end
  if self.historyIndex == 0 then
    self.historyDraft = self.input:getText()
  end
  self.historyIndex = math.min(
    count, math.max(0, self.historyIndex + (tonumber(step) or 0)))
  local text
  if self.historyIndex == 0 then
    text = self.historyDraft or ''
  else
    text = self.sentHistory[count - self.historyIndex + 1]
  end
  self.input:setText(text)
  self.input:setCursorPos(-1)
  return text
end

function Adapter:_setCursorWithSelection(target, keyboardModifiers)
  local input = self.input
  if not input then
    return false
  end
  local current = input:getCursorPos()
  if keyboardModifiers == KeyboardShiftModifier and input.setSelection then
    local anchor = current
    if input.hasSelection and input:hasSelection() and
        input.getSelectionStart and input.getSelectionEnd then
      local selectionStart = input:getSelectionStart()
      local selectionEnd = input:getSelectionEnd()
      anchor = current == selectionStart and selectionEnd or selectionStart
    end
    input:setSelection(anchor, target)
  elseif input.clearSelection then
    input:clearSelection()
  end
  input:setCursorPos(target)
  return true
end

function Adapter:_deleteCodepoint(deleteRight)
  local input = self.input
  if not input then
    return false
  end
  if input.hasSelection and input:hasSelection() and
      input.deleteSelection then
    input:deleteSelection()
    return true
  end

  local text = input:getText()
  local cursor = input.getCursorPos and input:getCursorPos() or #text
  cursor = math.max(0, math.min(#text, tonumber(cursor) or #text))
  local start = boundaryBeforeOrAt(text, cursor)
  local finish
  if start ~= cursor then
    finish = boundaryAfter(text, start)
  elseif deleteRight then
    if start >= #text then
      input:setCursorPos(#text)
      return true
    end
    finish = boundaryAfter(text, start)
  else
    if start == 0 then
      input:setCursorPos(0)
      return true
    end
    finish = start
    start = boundaryBeforeOrAt(text, start - 1)
  end
  input:setText(text:sub(1, start) .. text:sub(finish + 1))
  input:setCursorPos(start)
  return true
end

function Adapter:_backspace()
  return self:_deleteCodepoint(false)
end

function Adapter:_handleEditKey(keyCode, keyboardModifiers)
  if keyboardModifiers ~= KeyboardNoModifier and
      keyboardModifiers ~= KeyboardShiftModifier then
    return false
  end
  if keyCode == KeyBackspace and
      keyboardModifiers == KeyboardNoModifier then
    return self:_deleteCodepoint(false)
  end
  if keyCode == KeyDelete and
      keyboardModifiers == KeyboardNoModifier then
    return self:_deleteCodepoint(true)
  end

  local input = self.input
  if not input then
    return false
  end
  local text = input:getText()
  local cursor = math.max(0, math.min(
    #text, tonumber(input:getCursorPos()) or #text))
  local normalized = boundaryBeforeOrAt(text, cursor)
  local target
  if keyCode == KeyLeft then
    target = normalized
    if normalized == cursor and normalized > 0 then
      target = boundaryBeforeOrAt(text, normalized - 1)
    end
  elseif keyCode == KeyRight then
    target = boundaryAfter(text, normalized)
  elseif keyCode == KeyHome then
    target = 0
  elseif keyCode == KeyEnd then
    target = #text
  else
    return false
  end
  return self:_setCursorWithSelection(target, keyboardModifiers)
end

function Adapter:_restoreHotbar(session, openedGameSession)
  local page = self.previousHotbarPage
  if not page or self.session ~= session or
      self.gameSession ~= openedGameSession or not self.gameActive() then
    return false
  end
  self.previousHotbarPage = nil
  self.setHotbarPage(page)
  return true
end

function Adapter:_clearSessionSnapshot(session)
  if self.session ~= session then
    return true
  end
  self.previousForegroundOwner = nil
  self.previousHotbarPage = nil
  self.openedGameSession = nil
end

function Adapter:send()
  if not self.input or not self.console or
      type(self.console.sendMessage) ~= 'function' then
    return false
  end
  local text = self.input:getText()
  if not text or not text:find('%S') then
    return false
  end
  self:_reconcileChannel()
  local tab = self:_activeTab()
  local tabName = tab and type(tab.getText) == 'function' and
    tab:getText() or nil
  if not tab or tabName ~= self.currentChannel then
    return false
  end

  local session = self.session
  local input = self.input
  local ok, errorMessage = pcall(self.console.sendMessage, text, tab)
  if not ok then
    if self.onError then
      self.onError(errorMessage)
    end
    return false
  end

  if #self.sentHistory == 0 or
      self.sentHistory[#self.sentHistory] ~= text then
    self.sentHistory[#self.sentHistory + 1] = text
    if #self.sentHistory > self.maxSentHistory then
      table.remove(self.sentHistory, 1)
    end
  end
  self.historyIndex = 0
  self.historyDraft = ''
  if self.session == session and self.input == input then
    input:clearText()
    self:_focusInput(false)
  end
  return true
end

function Adapter:_handleEscape()
  local profile = self.profile or self.mobileUi.getProfile()
  if integer(profile and profile.keyboardHeight) > 0 then
    self.keyboardDismissed = true
    self:_releaseKeyboardFocus(true)
    return true
  end
  return self:close()
end

function Adapter:_onKeyDown(keyCode, keyboardModifiers)
  if keyCode == KeyEscape then
    return self:_handleEscape()
  end
  if keyCode == KeyEnter and
      keyboardModifiers == KeyboardNoModifier then
    self:send()
    return true
  end
  if keyCode == KeyUp and keyboardModifiers == KeyboardNoModifier then
    self:navigateHistory(1)
    return true
  end
  if keyCode == KeyDown and keyboardModifiers == KeyboardNoModifier then
    self:navigateHistory(-1)
    return true
  end
  if keyCode == KeyTab then
    if keyboardModifiers == KeyboardShiftModifier then
      return self:_switchChannel(-1)
    elseif keyboardModifiers == KeyboardNoModifier then
      return self:_switchChannel(1)
    end
  end
  return false
end

function Adapter:_configureUi()
  self.surface = self.backdrop:recursiveGetChildById('chatSurface')
  self.messageList = self.backdrop:recursiveGetChildById('chatMessages')
  self.messageScrollBar =
    self.backdrop:recursiveGetChildById('chatMessagesScrollBar')
  self.input = self.backdrop:recursiveGetChildById('chatInput')
  self.channelLabel = self.backdrop:recursiveGetChildById('chatChannel')
  local send = self.backdrop:recursiveGetChildById('chatSend')
  local close = self.backdrop:recursiveGetChildById('chatClose')
  self.previousChannel =
    self.backdrop:recursiveGetChildById('chatPreviousChannel')
  self.nextChannel =
    self.backdrop:recursiveGetChildById('chatNextChannel')
  assert(self.surface and self.messageList and self.input and
    self.channelLabel and send and close and self.previousChannel and
    self.nextChannel,
    'mobile chat UI is incomplete')

  send.onClick = function() return self:send() end
  close.onClick = function() return self:close() end
  self.previousChannel.onClick =
    function() return self:_switchChannel(-1) end
  self.nextChannel.onClick =
    function() return self:_switchChannel(1) end
  self.input.onKeyPress = function(_, keyCode, keyboardModifiers)
    return self:_handleEditKey(keyCode, keyboardModifiers)
  end
  local onKeyDown = function(_, keyCode, keyboardModifiers)
    return self:_onKeyDown(keyCode, keyboardModifiers)
  end
  self.input.onKeyDown = onKeyDown
  self.backdrop.onKeyDown = onKeyDown
  self.backdrop.onDestroy = function()
    if not self.destroying then
      self:_supersede(self.session)
    end
  end
end

function Adapter:_createUi(session)
  self.backdrop = self.createWidget('MobileChatBackdrop', self.getRoot())
  self:_configureUi()
  self:_loadChannel(self:_activeChannelName())
  self.unsubscribeMessages = self.console.subscribeMessages(function(message)
    self:_onMessage(message, session)
  end)
  if type(self.console.subscribeChannelChanges) == 'function' then
    self.unsubscribeChannels =
      self.console.subscribeChannelChanges(function(change)
        self:_onChannelChange(change, session)
      end)
  end
  self.unsubscribeProfile = self.mobileUi.subscribeProfile(function(profile)
    if self.open and self.session == session then
      self:_applyProfile(profile)
    end
  end)
  self:_applyProfile(self.mobileUi.getProfile())
  self.backdrop:show()
  self.backdrop:raise()
  self.backdrop:focus()
  self.backdrop:grabKeyboard()
  self:_scheduleFocus(session)
end

function Adapter:_cleanupUi()
  if self.unsubscribeMessages then
    self.unsubscribeMessages()
    self.unsubscribeMessages = nil
  end
  if self.unsubscribeProfile then
    self.unsubscribeProfile()
    self.unsubscribeProfile = nil
  end
  if self.unsubscribeChannels then
    self.unsubscribeChannels()
    self.unsubscribeChannels = nil
  end
  self:_releaseKeyboardFocus(true)
  if self.backdrop and not self.backdrop:isDestroyed() then
    self.destroying = true
    self.backdrop:ungrabKeyboard()
    self.backdrop:destroy()
    self.destroying = false
  end
  self.backdrop = nil
  self.surface = nil
  self.messageList = nil
  self.messageScrollBar = nil
  self.input = nil
  self.channelLabel = nil
  self.previousChannel = nil
  self.nextChannel = nil
  self.rows = {}
end

function Adapter:_restoreStaleForeground()
  local session = self.session
  if self:_ownsForeground() then
    local owner = self.gameActive() and
      (self.staleForegroundOwner or self.previousForegroundOwner) or nil
    self.mobileUi.setForeground('gameplay', owner)
    local state, restoredOwner = self:_foreground()
    if self.gameActive() and state == 'gameplay' and
        restoredOwner == owner then
      self.showControls()
      self.focusMap()
    end
  end
  if self.session == session then
    self.previousForegroundOwner = nil
    self.staleForegroundOwner = nil
    self.previousHotbarPage = nil
    self.openedGameSession = nil
  end
end

function Adapter:_supersede(session)
  if not self.open or self.session ~= session then
    return
  end
  local openedGameSession = self.openedGameSession
  self.staleForegroundOwner = self.previousForegroundOwner
  self.open = false
  self:_cleanupUi()
  self:_restoreHotbar(session, openedGameSession)
  self:_clearSessionSnapshot(session)
  self.session = self.session + 1
end

function Adapter:openChat()
  if self.terminated or not self.gameActive() then
    return false
  end
  if self.open and self:_ownsForeground() then
    self:_scheduleFocus(self.session)
    return true
  end

  local state, owner = self:_foreground()
  if state ~= 'gameplay' or owner == nil then
    return false
  end
  self.session = self.session + 1
  local session = self.session
  self.open = true
  self.closing = false
  self.previousForegroundOwner = owner
  self.staleForegroundOwner = nil
  self.previousHotbarPage = validHotbarPage(self.getHotbarPage())
  self.openedGameSession = self.gameSession
  self.keyboardDismissed = false
  self.cancelGestures()
  self.hideControls()

  self.opening = true
  local accepted = self.mobileUi.setForeground('chat', self.foregroundOwner)
  self.opening = false
  if not accepted or not self:_ownsForeground() or
      not self.open or self.session ~= session then
    self.open = false
    self:_cleanupUi()
    self:_restoreHotbar(session, self.openedGameSession)
    local currentState, currentOwner = self:_foreground()
    if currentState == 'gameplay' and currentOwner == owner and
        self.gameActive() then
      self.showControls()
    end
    self:_clearSessionSnapshot(session)
    self.session = session + 1
    return false
  end

  local ok, errorMessage = pcall(function()
    self:_createUi(session)
  end)
  if not ok then
    self:_cleanupUi()
    self.open = false
    self:_restoreHotbar(session, self.openedGameSession)
    if self:_ownsForeground() and self.session == session then
      self.mobileUi.setForeground('gameplay', owner)
    end
    if self.session ~= session then
      return false
    end
    self:_clearSessionSnapshot(session)
    self.session = session + 1
    if self.onError then
      self.onError(errorMessage)
    end
    local currentState, currentOwner = self:_foreground()
    if currentState == 'gameplay' and currentOwner == owner and
        self.gameActive() then
      self.showControls()
    end
    return false
  end
  return true
end

function Adapter:close()
  if not self.open then
    return false
  end
  local session = self.session
  local previousOwner = self.previousForegroundOwner
  local openedGameSession = self.openedGameSession
  local ownsForeground = self:_ownsForeground()
  self.closing = true
  self.open = false
  self:_cleanupUi()
  self:_restoreHotbar(session, openedGameSession)

  if ownsForeground and self.session == session then
    self.mobileUi.setForeground('gameplay', previousOwner)
  end
  if self.session ~= session then
    self.closing = false
    return false
  end
  local state, owner = self:_foreground()
  local restored = ownsForeground and self.session == session and
    state == 'gameplay' and owner == previousOwner and self.gameActive()
  if restored then
    self.showControls()
    self.focusMap()
  end

  self:_clearSessionSnapshot(session)
  self.closing = false
  self.session = session + 1
  return restored
end

function Adapter:isChatOpen()
  return self.open and self:_ownsForeground() and
    self.backdrop ~= nil and not self.backdrop:isDestroyed()
end

function Adapter:toggle()
  if self:isChatOpen() then
    return self:close()
  end
  return self:openChat()
end

function Adapter:onGameEnd()
  self.gameSession = self.gameSession + 1
  self.open = false
  self.session = self.session + 1
  self:_cleanupUi()
  if self:_ownsForeground() then
    self.mobileUi.setForeground('gameplay', nil)
  end
  self.previousForegroundOwner = nil
  self.staleForegroundOwner = nil
  self.previousHotbarPage = nil
  self.openedGameSession = nil
end

function Adapter:terminate()
  if self.terminated then
    return
  end
  self.terminated = true
  self:onGameEnd()
end

function MobileChat.create(options)
  options = options or {}
  local mobileUi = options.mobileUi or modules.client_mobileui
  local adapter = setmetatable({
    console = options.console or modules.game_console,
    mobileUi = mobileUi,
    activeTab = options.activeTab,
    createWidget = options.createWidget or (g_ui and g_ui.createWidget),
    getRoot = options.getRoot or (g_ui and g_ui.getRootWidget),
    schedule = options.schedule or addEvent,
    cancel = options.cancel or removeEvent,
    cancelGestures = options.cancelGestures or function() end,
    hideControls = options.hideControls or function() end,
    showControls = options.showControls or function() end,
    gameActive = options.gameActive or function() return g_game.isOnline() end,
    getHotbarPage = options.getHotbarPage or function() return nil end,
    setHotbarPage = options.setHotbarPage or function() end,
    focusMap = options.focusMap or function()
      local gameInterface = modules.game_interface
      local map = gameInterface and gameInterface.getMapPanel and
        gameInterface.getMapPanel()
      if map then map:focus() end
    end,
    hideKeyboard = options.hideKeyboard or function()
      if g_window and g_window.hideVirtualKeyboard then
        g_window.hideVirtualKeyboard()
      end
    end,
    onError = options.onError or function() end,
    maxVisibleRows = MAX_VISIBLE_ROWS,
    maxSentHistory = MAX_SENT_HISTORY,
    sentHistory = {},
    historyIndex = 0,
    rows = {},
    session = 0,
    gameSession = 1,
    open = false,
    terminated = false
  }, Adapter)

  adapter.foregroundOwner = {}
  function adapter.foregroundOwner:onForegroundLost()
    if not adapter.opening and not adapter.closing then
      adapter:_supersede(adapter.session)
    end
  end
  function adapter.foregroundOwner:onForegroundGained()
    if adapter.open then
      if adapter.backdrop and not adapter.backdrop:isDestroyed() then
        adapter.backdrop:show()
        adapter.backdrop:raise()
        adapter:_scheduleFocus(adapter.session)
      end
    else
      adapter:_restoreStaleForeground()
    end
  end
  return adapter
end
