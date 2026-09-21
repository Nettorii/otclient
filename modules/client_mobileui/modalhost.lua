local activeModal
local replacementSnapshot
local keyboardReceiverTracker

function initModalHost()
  if keyboardReceiverTracker then
    return true
  end
  if not isV2Enabled or not isV2Enabled() then
    return false
  end

  local tracker = {
    nativeGrabKeyboard = UIWidget.grabKeyboard,
    nativeUngrabKeyboard = UIWidget.ungrabKeyboard
  }

  tracker.grabKeyboard = function(widget)
    tracker.nativeGrabKeyboard(widget)
    if not widget:isDestroyed() and g_ui.isKeyboardGrabbed() then
      tracker.receiver = widget
    else
      tracker.receiver = nil
    end
  end

  tracker.ungrabKeyboard = function(widget)
    tracker.nativeUngrabKeyboard(widget)
    if tracker.receiver == widget then
      tracker.receiver = nil
    end
  end

  UIWidget.grabKeyboard = tracker.grabKeyboard
  UIWidget.ungrabKeyboard = tracker.ungrabKeyboard
  UIWidget.mobileModalKeyboardReceiverTracker = tracker
  keyboardReceiverTracker = tracker
  return true
end

local function uninstallKeyboardReceiverTracker()
  local tracker = keyboardReceiverTracker
  if not tracker then
    return
  end

  UIWidget.grabKeyboard = tracker.nativeGrabKeyboard
  UIWidget.ungrabKeyboard = tracker.nativeUngrabKeyboard
  if UIWidget.mobileModalKeyboardReceiverTracker == tracker then
    UIWidget.mobileModalKeyboardReceiverTracker = nil
  end
  tracker.receiver = nil
  keyboardReceiverTracker = nil
end

local function getKeyboardReceiver()
  if not keyboardReceiverTracker then
    return nil
  end
  if not g_ui.isKeyboardGrabbed() then
    keyboardReceiverTracker.receiver = nil
    return nil
  end

  local receiver = keyboardReceiverTracker.receiver
  if receiver and receiver:isDestroyed() then
    keyboardReceiverTracker.receiver = nil
    return nil
  end
  return receiver
end

local function safeCall(callback, ...)
  if not callback then
    return
  end

  local ok, errorMessage = pcall(callback, ...)
  if not ok then
    g_logger.error('[client_mobileui] modal callback failed: ' .. tostring(errorMessage))
  end
end

local function isMouseButtonBlocked(button)
  return button == MouseLeftButton or button == MouseRightButton
end

local function createBodyScroller(scrollBar)
  local lastY
  local dragDistance = 0
  local dragged = false

  local function onMousePress(_, position, button)
    if button ~= MouseLeftButton then
      return false
    end
    lastY = position.y
    dragDistance = 0
    dragged = false
    return false
  end

  local function onMouseMove(_, position)
    if not lastY or not g_mouse.isPressed(MouseLeftButton) then
      return false
    end

    local delta = lastY - position.y
    lastY = position.y
    dragDistance = dragDistance + math.abs(delta)
    if dragDistance >= 6 then
      dragged = true
      scrollBar:setValue(scrollBar:getValue() + delta)
    end
    return dragged
  end

  local function onMouseRelease(_, _, button)
    if button ~= MouseLeftButton then
      return false
    end
    lastY = nil
    return dragged
  end

  local scroller = {}

  function scroller.bind(widget)
    if not widget or widget:isDestroyed() or widget.mobileModalScrollBound then
      return
    end
    widget.mobileModalScrollBound = true
    connect(widget, {
      onMousePress = onMousePress,
      onMouseMove = onMouseMove,
      onMouseRelease = onMouseRelease
    })
  end

  function scroller.consume()
    local consumed = dragged
    dragged = false
    return consumed
  end

  return scroller
end

local function createFooterScroller(scrollBar)
  local lastX
  local dragDistance = 0
  local dragged = false

  local function onMousePress(_, position, button)
    if button ~= MouseLeftButton then
      return false
    end
    lastX = position.x
    dragDistance = 0
    dragged = false
    return false
  end

  local function onMouseMove(_, position)
    if not lastX or not g_mouse.isPressed(MouseLeftButton) then
      return false
    end

    local delta = lastX - position.x
    lastX = position.x
    dragDistance = dragDistance + math.abs(delta)
    if dragDistance >= 6 then
      dragged = true
      scrollBar:setValue(scrollBar:getValue() + delta)
    end
    return dragged
  end

  local function onMouseRelease(_, _, button)
    if button ~= MouseLeftButton then
      return false
    end
    lastX = nil
    return dragged
  end

  local scroller = {}

  function scroller.bind(widget)
    if not widget or widget:isDestroyed() or widget.mobileModalFooterScrollBound then
      return
    end
    widget.mobileModalFooterScrollBound = true
    connect(widget, {
      onMousePress = onMousePress,
      onMouseMove = onMouseMove,
      onMouseRelease = onMouseRelease
    })
  end

  function scroller.consume()
    local consumed = dragged
    dragged = false
    return consumed
  end

  return scroller
end

local function bindWidgetTree(scroller, widget)
  if not widget or widget:isDestroyed() then
    return
  end
  scroller.bind(widget)
  for _, child in ipairs(widget:getChildren()) do
    bindWidgetTree(scroller, child)
  end
end

local function getFocusedWidget()
  local root = g_ui.getRootWidget()
  local focused = root:getFocusedChild()
  while focused do
    local child = focused:getFocusedChild()
    if not child then
      return focused
    end
    focused = child
  end
  return nil
end

local function isRestorableWidget(widget, requireFocusable)
  if not widget or widget:isDestroyed() or
      (requireFocusable and not widget:isFocusable()) then
    return false
  end

  local root = g_ui.getRootWidget()
  local current = widget
  while current and current ~= root do
    if current:isDestroyed() or not current:isVisible() or not current:isEnabled() then
      return false
    end
    current = current:getParent()
  end
  return current == root
end

function showModal(config)
  assert(type(config) == 'table', 'modal config must be a table')
  initModalHost()

  local previousState
  local previousOwner
  local previousFocusedWidget
  local previousKeyboardReceiver
  local supersededDuringReplacement = false
  if activeModal and activeModal:isOpen() then
    previousState = activeModal.previousForegroundState
    previousOwner = activeModal.previousForegroundOwner
    previousFocusedWidget = activeModal.previousFocusedWidget
    previousKeyboardReceiver = activeModal.previousKeyboardReceiver
    local outerSnapshot = replacementSnapshot
    replacementSnapshot = {
      state = previousState,
      owner = previousOwner,
      focusedWidget = previousFocusedWidget,
      keyboardReceiver = previousKeyboardReceiver
    }
    activeModal:replace()
    replacementSnapshot = outerSnapshot
    supersededDuringReplacement = activeModal ~= nil
  elseif replacementSnapshot then
    previousState = replacementSnapshot.state
    previousOwner = replacementSnapshot.owner
    previousFocusedWidget = replacementSnapshot.focusedWidget
    previousKeyboardReceiver = replacementSnapshot.keyboardReceiver
  else
    previousState, previousOwner = getForeground()
    previousFocusedWidget = getFocusedWidget()
    previousKeyboardReceiver = getKeyboardReceiver()
  end

  local root = g_ui.getRootWidget()
  local backdrop = g_ui.createWidget('MobileModalBackdrop', root)
  local surface = backdrop:getChildById('modalSurface')
  local titleLabel = surface:recursiveGetChildById('modalTitle')
  local bodyArea = surface:recursiveGetChildById('modalBody')
  local bodyScrollBar = surface:recursiveGetChildById('modalBodyScrollBar')
  local footer = surface:recursiveGetChildById('modalFooter')
  local footerScrollBar = surface:recursiveGetChildById('modalFooterScrollBar')
  local bodyScroller = createBodyScroller(bodyScrollBar)
  local footerScroller = createFooterScroller(footerScrollBar)
  local bodyWidget
  local buttons = {}
  local handle = {}
  local open = true
  local replacing = false
  local unsubscribeProfile

  handle.widget = backdrop
  handle.previousForegroundState = previousState
  handle.previousForegroundOwner = previousOwner
  handle.previousFocusedWidget = previousFocusedWidget
  handle.previousKeyboardReceiver = previousKeyboardReceiver
  handle.title = titleLabel
  handle.holder = footer
  handle.footerScrollBar = footerScrollBar

  local function updateButtonWidths()
    local count = #buttons
    if count == 0 then
      return
    end

    local spacing = math.max(0, count - 1) * 8
    local availableWidth = math.max(0,
      footer:getWidth() - footer:getPaddingLeft() - footer:getPaddingRight())
    local width = 48
    if count * width + spacing <= availableWidth then
      width = math.max(48, math.floor((availableWidth - spacing) / count))
    end
    for _, button in ipairs(buttons) do
      button:setWidth(width)
      button:setHeight(48)
    end
  end

  local function applyGeometry(profile)
    if not open or backdrop:isDestroyed() then
      return
    end

    local surfaceWidth = math.max(0, math.min(720, math.floor(profile.usableWidth * 0.88)))
    local surfaceHeight = math.max(0, math.min(640, profile.usableHeight - 24))
    surface:setWidth(surfaceWidth)
    surface:setHeight(surfaceHeight)
    surface:setX(profile.safe.left + math.floor((profile.usableWidth - surfaceWidth) / 2))
    surface:setY(profile.safe.top + math.floor((profile.usableHeight - surfaceHeight) / 2))

    if bodyWidget and not bodyWidget:isDestroyed() then
      bodyWidget:setWidth(math.max(0, bodyArea:getWidth() - 8))
    end
    updateButtonWidths()
  end

  local function finish(destroyWidget)
    if not open then
      return
    end
    open = false

    if activeModal == handle then
      activeModal = nil
    end
    if unsubscribeProfile then
      unsubscribeProfile()
      unsubscribeProfile = nil
    end

    safeCall(config.onClose)

    local state, owner = getForeground()
    local ownsForeground = state == 'modal' and owner == handle

    if destroyWidget and not backdrop:isDestroyed() then
      backdrop:ungrabKeyboard()
      backdrop:destroy()
    end

    if not replacing and ownsForeground then
      local currentState, currentOwner = getForeground()
      if currentState ~= 'modal' or currentOwner ~= handle then
        return
      end
      setForeground(previousState or 'gameplay', previousOwner)
      local restoredState, restoredOwner = getForeground()
      if restoredState == (previousState or 'gameplay') and
          restoredOwner == previousOwner then
        if isRestorableWidget(previousFocusedWidget, true) then
          previousFocusedWidget:focus()
          local focusState, focusOwner = getForeground()
          if focusState ~= restoredState or focusOwner ~= restoredOwner then
            return
          end
        end
        if isRestorableWidget(previousKeyboardReceiver, false) then
          previousKeyboardReceiver:grabKeyboard()
        end
      end
    end
  end

  function handle:setBody(widget)
    if not open or not widget or widget:isDestroyed() then
      return false
    end
    if bodyWidget and bodyWidget ~= widget and not bodyWidget:isDestroyed() then
      bodyWidget:destroy()
    end
    bodyWidget = widget
    self.content = widget
    widget:setParent(bodyArea)
    widget:setWidth(math.max(0, bodyArea:getWidth() - 8))
    bindWidgetTree(bodyScroller, bodyArea)
    return true
  end

  function handle:close()
    finish(true)
  end

  function handle:isOpen()
    return open and not backdrop:isDestroyed()
  end

  function handle:replace()
    if not open then
      return
    end
    replacing = true
    finish(true)
  end

  function handle:consumeBodyGesture()
    return bodyScroller.consume()
  end

  function handle:bindBodyWidget(widget)
    bindWidgetTree(bodyScroller, widget)
  end

  backdrop.onDestroy = function()
    finish(false)
  end
  backdrop.onMouseRelease = function(_, _, button)
    return isMouseButtonBlocked(button)
  end
  backdrop.onKeyDown = function(_, keyCode, keyboardModifiers)
    if keyboardModifiers ~= KeyboardNoModifier then
      return true
    end
    if keyCode == KeyEnter then
      safeCall(config.onEnter)
      return true
    end
    if keyCode == KeyEscape then
      safeCall(config.onEscape)
      return true
    end
    if config.onKeyDown then
      config.onKeyDown(keyCode, keyboardModifiers)
    end
    return true
  end

  titleLabel:setText(config.title or '')
  applyGeometry(getProfile())

  for _, buttonConfig in ipairs(config.buttons or {}) do
    local button = g_ui.createWidget('MobileModalButton', footer)
    button:setText(buttonConfig.text or '')
    button.onClick = function()
      if footerScroller.consume() then
        return
      end
      safeCall(buttonConfig.callback)
    end
    footerScroller.bind(button)
    table.insert(buttons, button)
  end
  footerScroller.bind(footer)
  updateButtonWidths()

  if config.body then
    handle:setBody(config.body)
  end

  if supersededDuringReplacement then
    replacing = true
    finish(true)
    return handle
  end

  unsubscribeProfile = subscribeProfile(applyGeometry)
  activeModal = handle
  setForeground('modal', handle)

  local state, owner = getForeground()
  if state ~= 'modal' or owner ~= handle then
    replacing = true
    finish(true)
    return handle
  end

  backdrop:show()
  backdrop:raise()
  backdrop:focus()
  state, owner = getForeground()
  if not open or state ~= 'modal' or owner ~= handle then
    replacing = true
    finish(true)
    return handle
  end
  backdrop:grabKeyboard()
  addEvent(function()
    if open then
      applyGeometry(getProfile())
    end
  end)
  return handle
end

function terminateModalHost()
  if activeModal and activeModal:isOpen() then
    activeModal:close()
  end
  activeModal = nil
  replacementSnapshot = nil
  uninstallKeyboardReceiverTracker()
end
