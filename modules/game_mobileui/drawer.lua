MobileDrawer = {}

-- A finger wobbles several pixels during a tap, so a press only becomes a
-- scroll once it has moved this many logical pixels away from where it began.
local TOUCH_SLOP = 12

local NAVIGATION_ORDER = {
  'inventory',
  'character',
  'minimap',
  'battle',
  'vip',
  'settings'
}

local DESCRIPTOR_FIELDS = {
  title = 'string',
  icon = 'string',
  create = 'function',
  onShow = 'function',
  onHide = 'function',
  destroy = 'function'
}

local function nonNegativeInteger(value)
  return math.max(0, math.floor(tonumber(value) or 0))
end

local function validId(id)
  return type(id) == 'string' and id ~= '' and
    id:match('^[%w_-]+$') ~= nil
end

local function validDescriptor(descriptor)
  if type(descriptor) ~= 'table' then
    return false
  end
  for field, fieldType in pairs(DESCRIPTOR_FIELDS) do
    if type(descriptor[field]) ~= fieldType then
      return false
    end
  end
  for field in pairs(descriptor) do
    if not DESCRIPTOR_FIELDS[field] then
      return false
    end
  end
  return true
end

function MobileDrawer.computeGeometry(profile)
  if type(profile) ~= 'table' then
    return nil
  end

  local safe = profile.safe or {}
  local usableWidth = nonNegativeInteger(profile.usableWidth)
  local usableHeight = nonNegativeInteger(profile.usableHeight)
  local safeLeft = nonNegativeInteger(safe.left)
  local safeTop = nonNegativeInteger(safe.top)
  local headerHeight = 48
  local footerHeight = 48

  if usableWidth < 72 or usableHeight <= headerHeight + footerHeight then
    return nil
  end

  local requestedWidth
  if profile.class == 'tablet' then
    requestedWidth = 360
  else
    requestedWidth = math.max(280, math.floor(usableWidth * 0.42))
  end
  local width = math.min(requestedWidth, usableWidth - 24)
  if width < 48 then
    return nil
  end

  local mirrored = profile.handedness == 'mirrored'
  return {
    x = mirrored and safeLeft or safeLeft + usableWidth - width,
    y = safeTop,
    width = width,
    height = usableHeight,
    headerHeight = headerHeight,
    footerHeight = footerHeight,
    contentHeight = usableHeight - headerHeight - footerHeight,
    mirrored = mirrored,
    swipeThreshold = math.max(48, math.floor(width * 0.25))
  }
end

function MobileDrawer.contentHeight(widget)
  local layout = widget:getLayout()
  if layout then
    layout:update()
  end
  local top = widget:getY()
  local bottom = widget:getPaddingTop()
  for _, child in ipairs(widget:getChildren()) do
    if child:isExplicitlyVisible() then
      bottom = math.max(bottom,
        child:getY() - top + child:getHeight() + child:getMarginBottom())
    end
  end
  return bottom + widget:getPaddingBottom()
end

function MobileDrawer.runSelfTests()
  local compact = MobileDrawer.computeGeometry({
    class = 'compact',
    usableWidth = 800,
    usableHeight = 390,
    safe = { left = 0, top = 0, right = 0, bottom = 0 },
    handedness = 'standard'
  })
  assert(compact and compact.width == 336 and compact.x == 464,
    'compact drawer must use responsive right-side geometry')

  local mirrored = MobileDrawer.computeGeometry({
    class = 'compact',
    usableWidth = 800,
    usableHeight = 300,
    safe = { left = 17, top = 11, right = 9, bottom = 7 },
    keyboardHeight = 83,
    handedness = 'mirrored'
  })
  assert(mirrored and mirrored.x == 17 and mirrored.y == 11 and
    mirrored.height == 300, 'mirrored drawer must respect usable bounds')

  local tablet = MobileDrawer.computeGeometry({
    class = 'tablet',
    usableWidth = 1000,
    usableHeight = 650,
    safe = { left = 20, top = 18, right = 24, bottom = 16 },
    handedness = 'standard'
  })
  assert(tablet and tablet.width == 360 and tablet.x == 660,
    'tablet drawer must use capped 360 width')

  assert(MobileDrawer.computeGeometry({
    class = 'compact',
    usableWidth = 60,
    usableHeight = 120,
    safe = { left = 0, top = 0, right = 0, bottom = 0 }
  }) == nil, 'drawer must reject geometry that cannot fit')
end

local Host = {}
Host.__index = Host

local function defaultLogError(message)
  if g_logger and g_logger.error then
    g_logger.error('[game_mobileui] drawer callback failed: ' .. tostring(message))
  end
end

function Host:_safeCall(callback, ...)
  local ok, result = pcall(callback, ...)
  if not ok then
    self.logError(result)
    return false, result
  end
  return true, result
end

function Host:_reportShellCreateError(viewId, errorMessage)
  if not self.onShellCreateError then
    return
  end
  local reported, reportError = pcall(
    self.onShellCreateError, viewId, errorMessage, self.getProfile())
  if not reported then
    self.logError(reportError)
  end
end

function Host:_foreground()
  return self.mobileUi.getForeground()
end

function Host:_ownsForeground()
  local state, owner = self:_foreground()
  return state == 'drawer' and owner == self.foregroundOwner
end

function Host:_orderedIds()
  local ids = {}
  local included = {}
  for _, id in ipairs(NAVIGATION_ORDER) do
    if self.registry[id] then
      ids[#ids + 1] = id
      included[id] = true
    end
  end
  local remaining = {}
  for id in pairs(self.registry) do
    if not included[id] then
      remaining[#remaining + 1] = id
    end
  end
  table.sort(remaining)
  for _, id in ipairs(remaining) do
    ids[#ids + 1] = id
  end
  return ids
end

function Host:_defaultId()
  local ids = self:_orderedIds()
  return ids[1]
end

function Host:_removeActionHandler()
  if not self.unregisterActionHandler then
    return
  end
  local unregister = self.unregisterActionHandler
  self.unregisterActionHandler = nil
  unregister()
end

function Host:_updateAvailability()
  if self.viewCount > 0 and not self.unregisterActionHandler and
      self.registerActionHandler and not self.terminated then
    local unregister = self.registerActionHandler(function()
      if self.active then
        self:close()
        return true
      end
      local id = self:_defaultId()
      return id ~= nil and self:open(id) or false
    end)
    if type(unregister) == 'function' then
      self.unregisterActionHandler = unregister
    end
  elseif self.viewCount == 0 then
    self:_removeActionHandler()
  end

  if self.onAvailabilityChange then
    self.onAvailabilityChange(self.viewCount > 0)
  end
end

function Host:hasViews()
  return self.viewCount > 0
end

function Host:register(id, descriptor)
  if self.terminated or not validId(id) or
      not validDescriptor(descriptor) or self.registry[id] then
    return false
  end

  local entry = {
    id = id,
    descriptor = descriptor
  }
  self.registry[id] = entry
  self.viewCount = self.viewCount + 1
  self:_updateAvailability()
  self:_renderNavigation()

  local removed = false
  return function()
    if removed then
      return
    end
    removed = true
    if self.registry[id] ~= entry then
      return
    end
    self.registry[id] = nil
    self.viewCount = self.viewCount - 1
    if self.pending and self.pending.entry == entry then
      self.transition = self.transition + 1
      local transition = self.transition
      self:_detachPending()
      if not self.active then
        self:_requestShellClose(transition)
      end
    elseif self.active and self.active.entry == entry then
      self:close()
    end
    self:_renderNavigation()
    self:_updateAvailability()
  end
end

function Host:_beginGesture(position)
  self.gesture.startX = position and position.x or 0
  self.gesture.startY = position and position.y or 0
  self.gesture.lastX = self.gesture.startX
  self.gesture.lastY = self.gesture.startY
  self.gesture.dragged = false
  self.gesture.closeReady = false
  self.gesture.suppressClick = false
end

function Host:_moveGesture(position, scrollBar, scrollAxis)
  if self.gesture.startX == nil then
    return false
  end

  local x = position and position.x or self.gesture.lastX
  local y = position and position.y or self.gesture.startY
  local deltaX = x - self.gesture.startX
  local deltaY = y - self.gesture.startY
  local movement = math.max(math.abs(deltaX), math.abs(deltaY))
  if movement >= TOUCH_SLOP then
    self.gesture.dragged = true
    self.gesture.suppressClick = true
  end

  local geometry = self.geometry
  local towardEdge = geometry and
    (geometry.mirrored and -deltaX or deltaX) or 0
  self.gesture.closeReady = geometry ~= nil and
    towardEdge >= geometry.swipeThreshold

  if scrollBar and self.gesture.dragged and
      scrollBar.getValue and scrollBar.setValue then
    local delta = self.gesture.lastX - x
    if scrollAxis == 'vertical' then
      delta = self.gesture.lastY - y
    end
    scrollBar:setValue(scrollBar:getValue() + delta)
  end
  self.gesture.lastX = x
  self.gesture.lastY = y
  return self.gesture.dragged
end

function Host:_finishGesture(button)
  if button ~= MouseLeftButton then
    self.gesture.startX = nil
    return false
  end
  local consumed = self.gesture.dragged == true
  local closeReady = self.gesture.closeReady == true
  self.gesture.startX = nil
  self.gesture.dragged = false
  self.gesture.closeReady = false
  if closeReady then
    self:close()
    return true
  end
  return consumed
end

function Host:_bindGestureWidget(widget, scrollBar, scrollAxis)
  if self.terminated or not widget or widget:isDestroyed() then
    return false
  end
  local existing = self.gestureBindings[widget]
  if existing then
    return existing.unbind
  end

  local binding = {
    active = true,
    host = self,
    widget = widget,
    previous = {},
    wrappers = {},
    suppressNextClick = false
  }
  local interceptors = {
    onMousePress = function(host, _, position, button)
      if button == MouseRightButton then
        host.gesture.suppressClick = true
        return false
      end
      if button ~= MouseLeftButton then
        return true
      end
      binding.suppressNextClick = false
      host:_beginGesture(position)
      return false
    end,
    onMouseMove = function(host, _, position)
      return host:_moveGesture(position, scrollBar, scrollAxis)
    end,
    onMouseRelease = function(host, _, _, button)
      if button == MouseLeftButton and host.gesture.dragged then
        binding.suppressNextClick = true
      end
      return host:_finishGesture(button)
    end
  }

  for event, interceptor in pairs(interceptors) do
    local previous = widget[event]
    local gestureInterceptor = interceptor
    binding.previous[event] = previous
    binding.wrappers[event] = function(...)
      local host = binding.host
      if host and binding.active then
        if gestureInterceptor(host, ...) then
          return true
        end
      end
      return previous and previous(...) or false
    end
    widget[event] = binding.wrappers[event]
  end

  local previousClick = widget.onClick
  binding.previous.onClick = previousClick
  binding.wrappers.onClick = function(...)
    if binding.suppressNextClick then
      binding.suppressNextClick = false
      local boundWidget = binding.widget
      if not binding.active then
        if boundWidget and not boundWidget:isDestroyed() and
            boundWidget.onClick == binding.wrappers.onClick then
          boundWidget.onClick = previousClick
        end
        binding.widget = nil
      end
      return true
    end
    return previousClick and previousClick(...) or false
  end
  widget.onClick = binding.wrappers.onClick

  binding.unbind = function()
    if not binding.active then
      return
    end
    binding.active = false
    local host = binding.host
    local boundWidget = binding.widget
    if host and boundWidget and
        host.gestureBindings[boundWidget] == binding then
      host.gestureBindings[boundWidget] = nil
    end
    local keepClickWrapper = false
    if boundWidget and not boundWidget:isDestroyed() then
      for event, wrapper in pairs(binding.wrappers) do
        if boundWidget[event] == wrapper then
          if event == 'onClick' and binding.suppressNextClick then
            keepClickWrapper = true
          else
            boundWidget[event] = binding.previous[event]
          end
        end
      end
    elseif binding.suppressNextClick then
      keepClickWrapper = true
    end
    binding.host = nil
    if not keepClickWrapper then
      binding.widget = nil
    end
  end

  self.gestureBindings[widget] = binding
  return binding.unbind
end

function Host:_unbindGestureWidget(widget)
  local binding = widget and self.gestureBindings[widget]
  if binding then
    binding.unbind()
  end
end

function Host:_bindGestureTree(widget, scrollBar, scrollAxis)
  if not widget or widget:isDestroyed() then
    return
  end
  if widget ~= self.surface then
    self:_bindGestureWidget(widget, scrollBar, scrollAxis)
  end
  if widget.getChildren then
    for _, child in ipairs(widget:getChildren()) do
      self:_bindGestureTree(child, scrollBar, scrollAxis)
    end
  end
end

function Host:_unbindGestureTree(widget)
  if not widget then
    return
  end
  if widget.getChildren then
    for _, child in ipairs(widget:getChildren()) do
      self:_unbindGestureTree(child)
    end
  end
  self:_unbindGestureWidget(widget)
end

function Host:_unbindAllGestureWidgets()
  local bindings = {}
  for _, binding in pairs(self.gestureBindings) do
    bindings[#bindings + 1] = binding
  end
  for _, binding in ipairs(bindings) do
    binding.unbind()
  end
  self.gesture = {}
end

function Host:bindGestureWidget(widget)
  if self.terminated or not widget or widget:isDestroyed() then
    return false
  end
  local unbinds = {}
  local function bindTree(current)
    if not current or current:isDestroyed() then
      return
    end
    unbinds[#unbinds + 1] = self:_bindGestureWidget(current)
    if current.getChildren then
      for _, child in ipairs(current:getChildren()) do
        bindTree(child)
      end
    end
  end
  bindTree(widget)

  local released = false
  return function()
    if released then
      return
    end
    released = true
    for index = #unbinds, 1, -1 do
      unbinds[index]()
    end
  end
end

function Host:_clearNavigation()
  self.navigationGeneration = self.navigationGeneration + 1
  for _, button in ipairs(self.navigationButtons) do
    self.navigationOwners[button] = nil
    self:_unbindGestureWidget(button)
    button.onClick = nil
    if not button:isDestroyed() then
      button:destroy()
    end
  end
  self.navigationButtons = {}
end

function Host:_renderNavigation()
  if not self.navigation or self.navigation:isDestroyed() then
    return
  end

  self:_clearNavigation()
  local generation = self.navigationGeneration
  for _, id in ipairs(self:_orderedIds()) do
    local entry = self.registry[id]
    local button = self.createWidget('MobileDrawerNavigationButton', self.navigation)
    local owner = {
      entry = entry,
      generation = generation
    }
    self.navigationOwners[button] = owner
    button.drawerViewId = id
    button:setId('drawerTab_' .. id)
    button:setText(entry.descriptor.title)
    if entry.descriptor.icon ~= '' and button.setImageSource then
      button:setImageSource(entry.descriptor.icon)
    end
    button:setEnabled(true)
    if type(self.mobileUi.applyOverlayTree) == 'function' then
      self.mobileUi.applyOverlayTree(button, self.getProfile())
    end
    button.onClick = function()
      local currentOwner = self.navigationOwners[button]
      if self.terminated or button:isDestroyed() or
          self.navigationGeneration ~= generation or
          currentOwner ~= owner or currentOwner.entry ~= entry or
          self.registry[id] ~= entry then
        return false
      end
      if self.gesture.suppressClick then
        return true
      end
      if self.active and self.active.entry == entry then
        return self:close()
      end
      return self:open(id)
    end
    self:_bindGestureWidget(button, self.navigationScrollBar)
    self.navigationButtons[#self.navigationButtons + 1] = button
  end
end

function Host:_applyOverlay(profile)
  if type(self.mobileUi.applyOverlayTree) ~= 'function' then
    return
  end
  self.mobileUi.applyOverlayTree(self.backdrop, profile)
end

function Host:_applyGeometry(profile)
  local geometry = MobileDrawer.computeGeometry(profile)
  if not geometry then
    return false
  end
  self.geometry = geometry
  if self.surface and not self.surface:isDestroyed() then
    self.surface:setRect({
      x = geometry.x,
      y = geometry.y,
      width = geometry.width,
      height = geometry.height
    })
  end
  self:_applyOverlay(profile)
  return true
end

function Host:_positionInsideSurface(position)
  local geometry = self.geometry
  if not geometry or not position then
    return false
  end
  return position.x >= geometry.x and
    position.x < geometry.x + geometry.width and
    position.y >= geometry.y and
    position.y < geometry.y + geometry.height
end

function Host:_unbindBackdropHandlers(backdrop)
  local binding = self.backdropBinding
  if not binding then
    return
  end
  self.backdropBinding = nil
  local widget = backdrop or binding.widget
  if widget and not widget:isDestroyed() then
    for event, handler in pairs(binding.handlers) do
      if widget[event] == handler then
        widget[event] = binding.previous[event]
      end
    end
  end
  binding.host = nil
  binding.widget = nil
end

function Host:_destroyBackdrop()
  if self.unsubscribeProfile then
    self.unsubscribeProfile()
    self.unsubscribeProfile = nil
  end

  local backdrop = self.backdrop
  self:_unbindAllGestureWidgets()
  self:_clearNavigation()
  self:_unbindBackdropHandlers(backdrop)
  self.backdrop = nil
  self.surface = nil
  self.title = nil
  self.content = nil
  self.contentScrollBar = nil
  self.navigation = nil
  self.navigationScrollBar = nil
  self.geometry = nil
  self.backdropPressOutside = false

  if backdrop and not backdrop:isDestroyed() then
    self.destroyingBackdrop = true
    backdrop:destroy()
    self.destroyingBackdrop = false
  end
end

function Host:_ensureBackdrop(profile)
  if self.backdrop and not self.backdrop:isDestroyed() then
    return self:_applyGeometry(profile)
  end

  local ok, backdrop = self:_safeCall(self.createBackdrop)
  if not ok or not backdrop or backdrop:isDestroyed() then
    self:_reportShellCreateError('drawer',
      ok and 'drawer backdrop creation returned no live widget' or backdrop)
    return false
  end

  local configured, shell = pcall(function()
    local result = {
      surface = backdrop:recursiveGetChildById('drawerSurface'),
      title = backdrop:recursiveGetChildById('drawerTitle'),
      content = backdrop:recursiveGetChildById('drawerContent'),
      contentScrollBar =
        backdrop:recursiveGetChildById('drawerContentScrollBar'),
      navigation = backdrop:recursiveGetChildById('drawerNavigation'),
      navigationScrollBar =
        backdrop:recursiveGetChildById('drawerNavigationScrollBar')
    }
    assert(result.surface and result.title and result.content and
      result.contentScrollBar and result.navigation and
      result.navigationScrollBar, 'drawer shell is incomplete')
    return result
  end)
  if not configured then
    backdrop:destroy()
    self:_reportShellCreateError('drawer', shell)
    return false
  end

  self.backdrop = backdrop
  self.surface = shell.surface
  self.title = shell.title
  self.content = shell.content
  self.contentScrollBar = shell.contentScrollBar
  self.navigation = shell.navigation
  self.navigationScrollBar = shell.navigationScrollBar
  backdrop:setPhantom(false)
  backdrop:setEnabled(true)
  backdrop:hide()

  local binding = {
    host = self,
    widget = backdrop,
    previous = {
      onMousePress = backdrop.onMousePress,
      onMouseMove = backdrop.onMouseMove,
      onMouseRelease = backdrop.onMouseRelease,
      onKeyDown = backdrop.onKeyDown,
      onDestroy = backdrop.onDestroy
    },
    handlers = {}
  }
  -- Android system Back arrives as Escape.
  binding.handlers.onKeyDown = function(_, keyCode, keyboardModifiers)
    local host = binding.host
    if not host or keyCode ~= KeyEscape or
        keyboardModifiers ~= KeyboardNoModifier then
      return false
    end
    host:close()
    return true
  end
  binding.handlers.onMousePress = function(_, position, button)
    local host = binding.host
    if not host then
      return false
    end
    host.cancelGestures()
    if button == MouseLeftButton then
      host.backdropPressOutside = not host:_positionInsideSurface(position)
      if host.backdropPressOutside then
        host:_beginGesture(position)
      end
    else
      host.backdropPressOutside = false
      host.gesture.suppressClick = true
    end
    return true
  end
  binding.handlers.onMouseMove = function(_, position)
    local host = binding.host
    if not host then
      return false
    end
    if host.backdropPressOutside then
      host:_moveGesture(position)
    end
    return true
  end
  binding.handlers.onMouseRelease = function(_, position, button)
    local host = binding.host
    if not host then
      return false
    end
    if button == MouseLeftButton then
      local pressedOutside = host.backdropPressOutside
      local releasedOutside = not host:_positionInsideSurface(position)
      host.backdropPressOutside = false
      if pressedOutside then
        host:_moveGesture(position)
      end
      local tap = pressedOutside and not host.gesture.dragged
      if pressedOutside then
        host:_finishGesture(button)
      end
      if tap and releasedOutside then
        -- Keep the backdrop alive until this release has been consumed. Destroying
        -- it inline lets the same browser touch fall through to the game map.
        local transition = host.transition
        local active = host.active
        local navigationGeneration = host.navigationGeneration
        local suspensionGeneration = host.suspensionGeneration
        scheduleEvent(function()
          if binding.host == host and host.backdrop == backdrop and
              host.transition == transition and host.active == active and
              host.navigationGeneration == navigationGeneration and
              host.suspensionGeneration == suspensionGeneration and
              not backdrop:isDestroyed() then
            host:close()
          end
        end, 350)
      end
    else
      host.backdropPressOutside = false
      host:_finishGesture(button)
    end
    return true
  end
  binding.handlers.onDestroy = function(widget)
    local host = binding.host
    local previousDestroy = binding.previous.onDestroy
    if host and not host.destroyingBackdrop then
      host.backdrop = nil
      host:_unbindBackdropHandlers(widget)
      host:close()
    end
    if previousDestroy then
      previousDestroy(widget)
    end
  end
  self.backdropBinding = binding
  for event, handler in pairs(binding.handlers) do
    backdrop[event] = handler
  end

  self:_bindGestureWidget(self.surface)
  local closeButton = backdrop:recursiveGetChildById('drawerClose')
  if closeButton then
    closeButton.onClick = function()
      if self.terminated or self.backdrop ~= backdrop or
          self.gesture.suppressClick then
        return true
      end
      self:close()
      return true
    end
    self:_bindGestureWidget(closeButton)
  end
  local navigationRendered, navigationError =
    pcall(self._renderNavigation, self)
  if not navigationRendered then
    self:_destroyBackdrop()
    self:_reportShellCreateError('drawer', navigationError)
    return false
  end
  if not self:_applyGeometry(profile) then
    self:_destroyBackdrop()
    return false
  end

  self.unsubscribeProfile = self.subscribeProfile(function(nextProfile)
    if self.backdrop and not self:_applyGeometry(nextProfile) then
      self:close()
    end
  end)
  return true
end

function Host:_callRecord(record, callback, ...)
  record.callbackDepth = record.callbackDepth + 1
  self.callbackDepth = self.callbackDepth + 1
  local ok, result = pcall(callback, ...)
  record.callbackDepth = record.callbackDepth - 1
  self.callbackDepth = self.callbackDepth - 1
  if not ok then
    record.lastError = result
    self.logError(result)
  end
  if record.cleanupRequested and record.callbackDepth == 0 and
      not record.finalizing then
    self:_finalizeRecord(record)
  end
  if not record.finalizing then
    self:_completeDeferredClose()
  end
  return ok, result
end

function Host:_finalizeRecord(record)
  if not record or record.finalized then
    return
  end
  if record.callbackDepth > 0 then
    record.cleanupRequested = true
    return
  end

  record.finalizing = true
  self:_unbindGestureTree(record.holder)
  if record.holder and not record.holder:isDestroyed() then
    record.holder:setEnabled(false)
    record.holder:hide()
  end
  if not record.hideCalled then
    record.hideCalled = true
    self:_callRecord(record, record.entry.descriptor.onHide)
  end
  if not record.destroyCalled then
    record.destroyCalled = true
    self:_callRecord(record, record.entry.descriptor.destroy)
  end
  self:_unbindGestureTree(record.holder)
  record.finalized = true
  record.finalizing = false
  if record.holder and not record.holder:isDestroyed() then
    record.holder:destroy()
  end
end

function Host:_requestCleanup(record)
  if not record or record.finalized then
    return
  end
  record.cleanupRequested = true
  self:_unbindGestureTree(record.holder)
  if record.holder and not record.holder:isDestroyed() then
    record.holder:setEnabled(false)
    record.holder:hide()
  end
  if record.callbackDepth == 0 and not record.finalizing then
    self:_finalizeRecord(record)
  end
  self:_completeDeferredClose()
end

function Host:_detachActive()
  local record = self.active
  if not record then
    return
  end
  self.active = nil
  self:_requestCleanup(record)
end

function Host:_detachPending()
  local record = self.pending
  if not record then
    return
  end
  self.pending = nil
  self:_requestCleanup(record)
end

function Host:_requestShellClose(transition)
  if self.callbackDepth > 0 then
    self.deferredCloseTransition = transition
    return
  end
  if self.transition == transition and not self.active and not self.pending then
    self:_destroyBackdrop()
    self:_restorePreviousForeground()
  end
end

function Host:_completeDeferredClose()
  local transition = self.deferredCloseTransition
  if not transition or self.callbackDepth > 0 then
    return
  end
  self.deferredCloseTransition = nil
  self:_requestShellClose(transition)
end

function Host:_restorePreviousForeground()
  if not self:_ownsForeground() then
    return false
  end
  local state = self.previousForegroundState or 'gameplay'
  local owner = self.previousForegroundOwner
  self.previousForegroundState = nil
  self.previousForegroundOwner = nil
  self.mobileUi.setForeground(state, owner)
  return true
end

function Host:_suspendForModal(owner)
  if not self.active or not owner then
    return false
  end
  self.suspensionGeneration = self.suspensionGeneration + 1
  self.suspension = {
    record = self.active,
    transition = self.transition,
    generation = self.suspensionGeneration,
    modalOwner = owner
  }
  if self.backdrop and not self.backdrop:isDestroyed() then
    self.backdrop:setEnabled(false)
    self.backdrop:hide()
  end
  return true
end

function Host:_resumeFromModal()
  local suspension = self.suspension
  self.suspension = nil
  if not suspension or self.terminated or self.closing or
      self.active ~= suspension.record or
      self.transition ~= suspension.transition or
      suspension.record.finalized or suspension.record.cleanupRequested or
      self.registry[suspension.record.entry.id] ~= suspension.record.entry then
    self:_restorePreviousForeground()
    return false
  end
  if self.backdrop and not self.backdrop:isDestroyed() then
    self.backdrop:setEnabled(true)
    self.backdrop:show()
    self.backdrop:raise()
    self.backdrop:focus()
  end
  return true
end

function Host:_acquireForeground()
  if self:_ownsForeground() then
    return true
  end

  local state, owner = self:_foreground()
  if state ~= 'gameplay' then
    return false
  end

  self.previousForegroundState = state
  self.previousForegroundOwner = owner
  self.cancelGestures()
  self.acquiringForeground = true
  local accepted = self.mobileUi.setForeground('drawer', self.foregroundOwner)
  self.acquiringForeground = false
  if not accepted or not self:_ownsForeground() then
    self.previousForegroundState = nil
    self.previousForegroundOwner = nil
    return false
  end
  return true
end

function Host:_openingIsCurrent(record, transition)
  return self.transition == transition and not self.terminated and
    self.pending == record and not record.cleanupRequested and
    not record.finalized and self.registry[record.entry.id] == record.entry and
    self:_ownsForeground()
end

function Host:_rollbackOpening(record, transition)
  if self.pending == record then
    self.pending = nil
  end
  self:_requestCleanup(record)
  self:_requestShellClose(transition)
  return false
end

function Host:open(id)
  if self.terminated then
    return false
  end
  local entry = self.registry[id]
  if not entry then
    return false
  end

  if not self:_ownsForeground() then
    local state = self:_foreground()
    if state ~= 'gameplay' then
      return false
    end
  end

  local profile = self.getProfile()
  if not MobileDrawer.computeGeometry(profile) then
    return false
  end

  self.transition = self.transition + 1
  local transition = self.transition
  self:_detachPending()
  if self.transition ~= transition then
    return false
  end
  if self.active and self.active.entry == entry then
    return self:close()
  end

  self.cancelGestures()
  if not self:_acquireForeground() then
    return false
  end
  if self.transition ~= transition or not self:_ownsForeground() then
    return false
  end
  if not self:_ensureBackdrop(profile) then
    if self.transition == transition then
      self:_restorePreviousForeground()
    end
    return false
  end

  local previous = self.active
  local holderCreated, holder = self:_safeCall(
    self.createWidget, 'MobileDrawerViewHost', self.content)
  if not holderCreated or not holder or holder:isDestroyed() then
    self:_reportShellCreateError(entry.id,
      holderCreated and 'drawer view holder returned no live widget' or holder)
    self:_requestShellClose(transition)
    return false
  end
  holder:setEnabled(false)
  holder:hide()
  local record = {
    entry = entry,
    holder = holder,
    callbackDepth = 0,
    cleanupRequested = false,
    finalized = false,
    finalizing = false,
    hideCalled = false,
    destroyCalled = false
  }
  self.pending = record

  local created, view = self:_callRecord(
    record, entry.descriptor.create, holder)
  if not created then
    if self.onViewCreateError then
      local reported, reportError = pcall(
        self.onViewCreateError, entry.id, record.lastError, self.getProfile())
      if not reported then
        self.logError(reportError)
      end
    end
    if self.pending ~= record or self.transition ~= transition then
      self:_requestCleanup(record)
      return false
    end
    return self:_rollbackOpening(record, transition)
  end
  if not self:_openingIsCurrent(record, transition) then
    self:_requestCleanup(record)
    return false
  end
  if view and view ~= holder and view.setParent and
      not view:isDestroyed() and view:getParent() ~= holder then
    view:setParent(holder)
  end
  self:_bindGestureTree(holder, self.contentScrollBar, 'vertical')

  local shown, showResult = self:_callRecord(
    record, entry.descriptor.onShow)
  if not shown or showResult == false then
    return self:_rollbackOpening(record, transition)
  end
  if not self:_openingIsCurrent(record, transition) then
    self:_requestCleanup(record)
    return false
  end
  -- onShow may install feature-specific handlers (for example UIMinimap).
  -- Re-wrap the final handlers so vertical drawer scrolling remains first.
  self:_unbindGestureTree(holder)
  self:_bindGestureTree(holder, self.contentScrollBar, 'vertical')
  if type(self.mobileUi.applyOverlayTree) == 'function' then
    self.mobileUi.applyOverlayTree(holder, self.getProfile())
  end

  self.pending = nil
  self.active = record
  record.committed = true
  if previous and previous ~= record then
    self:_requestCleanup(previous)
  end
  if self.transition ~= transition or self.active ~= record or
      record.cleanupRequested or record.finalized or
      not self:_ownsForeground() then
    self:_requestCleanup(record)
    return false
  end

  holder:setEnabled(true)
  holder:show()
  self.title:setText(entry.descriptor.title)
  local navigationRendered, navigationError =
    pcall(self._renderNavigation, self)
  if not navigationRendered then
    self:_reportShellCreateError(entry.id, navigationError)
    self:close()
    return false
  end
  self.backdrop:show()
  self.backdrop:raise()
  self.backdrop:focus()
  return true
end

function Host:close()
  if self.closing then
    return self.active == nil
  end

  self.transition = self.transition + 1
  local transition = self.transition
  self.closing = true
  self.suspension = nil
  self.cancelGestures()
  self:_detachPending()
  self:_detachActive()
  self.closing = false

  if self.transition ~= transition then
    return self.active == nil
  end
  self:_requestShellClose(transition)
  return true
end

function Host:getOpenId()
  return self.active and self.active.entry.id or nil
end

function Host:applyProfile(profile)
  if not self.backdrop then
    return MobileDrawer.computeGeometry(profile) ~= nil
  end
  if not self:_applyGeometry(profile) then
    self:close()
    return false
  end
  return true
end

function Host:terminate()
  if self.terminated then
    return
  end
  self.terminated = true
  self.transition = self.transition + 1
  self.suspension = nil
  self.cancelGestures()
  self:_unbindAllGestureWidgets()
  self:_unbindBackdropHandlers(self.backdrop)
  self:_clearNavigation()
  if self.unsubscribeProfile then
    self.unsubscribeProfile()
    self.unsubscribeProfile = nil
  end
  self:_detachPending()
  self:_detachActive()
  self:_requestShellClose(self.transition)
  self:_removeActionHandler()
  self.registry = {}
  self.viewCount = 0
  if self.onAvailabilityChange then
    self.onAvailabilityChange(false)
  end
end

function MobileDrawer.create(options)
  options = options or {}
  local mobileUi = options.mobileUi or modules.client_mobileui
  local createBackdrop = options.createBackdrop or function()
    return g_ui.createWidget('MobileDrawerBackdrop', g_ui.getRootWidget())
  end
  local createWidget = options.createWidget or function(style, parent)
    return g_ui.createWidget(style, parent)
  end

  local host = setmetatable({
    mobileUi = mobileUi,
    getProfile = options.getProfile or mobileUi.getProfile,
    subscribeProfile = options.subscribeProfile or mobileUi.subscribeProfile,
    createBackdrop = createBackdrop,
    createWidget = createWidget,
    cancelGestures = options.cancelGestures or function() end,
    registerActionHandler = options.registerActionHandler,
    onAvailabilityChange = options.onAvailabilityChange,
    onViewCreateError = options.onViewCreateError,
    onShellCreateError = options.onShellCreateError,
    logError = options.logError or defaultLogError,
    registry = {},
    viewCount = 0,
    navigationButtons = {},
    navigationOwners = setmetatable({}, { __mode = 'k' }),
    navigationGeneration = 0,
    gesture = {},
    gestureBindings = setmetatable({}, { __mode = 'k' }),
    callbackDepth = 0,
    transition = 0,
    suspensionGeneration = 0,
    terminated = false
  }, Host)

  host.foregroundOwner = {}
  function host.foregroundOwner:onForegroundGained(oldState)
    if host.acquiringForeground then
      return
    end
    if oldState == 'modal' then
      host:_resumeFromModal()
      return
    end
    if host.terminated or host.closing or not host.active then
      host:_restorePreviousForeground()
      return
    end
    if host.backdrop and not host.backdrop:isDestroyed() then
      host.backdrop:show()
      host.backdrop:raise()
    end
  end
  function host.foregroundOwner:onForegroundLost(nextState, nextOwner)
    host.cancelGestures()
    if nextState == 'modal' and host:_suspendForModal(nextOwner) then
      return
    end
    if host.active or host.pending then
      host:close()
    end
  end

  return host
end
