MobileDrawer = {}

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
    return false, nil
  end
  return true, result
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
  self.gesture.dragged = false
  self.gesture.closeReady = false
  self.gesture.suppressClick = false
end

function Host:_moveGesture(position, scrollBar)
  if self.gesture.startX == nil then
    return false
  end

  local x = position and position.x or self.gesture.lastX
  local y = position and position.y or self.gesture.startY
  local deltaX = x - self.gesture.startX
  local deltaY = y - self.gesture.startY
  local movement = math.max(math.abs(deltaX), math.abs(deltaY))
  if movement >= 6 then
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
    scrollBar:setValue(scrollBar:getValue() + self.gesture.lastX - x)
  end
  self.gesture.lastX = x
  return self.gesture.dragged
end

function Host:_finishGesture(button)
  if button ~= MouseLeftButton then
    self.gesture.startX = nil
    return true
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

function Host:_bindGestureWidget(widget, scrollBar)
  if not widget or widget:isDestroyed() then
    return false
  end
  if self.gestureBindings[widget] then
    return true
  end
  self.gestureBindings[widget] = true

  local callbacks = {
    onMousePress = function(_, position, button)
      if button == MouseRightButton then
        self.gesture.suppressClick = true
        return true
      end
      if button ~= MouseLeftButton then
        return true
      end
      self:_beginGesture(position)
      return false
    end,
    onMouseMove = function(_, position)
      return self:_moveGesture(position, scrollBar)
    end,
    onMouseRelease = function(_, _, button)
      return self:_finishGesture(button)
    end
  }

  if self.connectWidget then
    self.connectWidget(widget, callbacks)
  else
    for event, callback in pairs(callbacks) do
      local previous = widget[event]
      local gestureCallback = callback
      local featureCallback = previous
      widget[event] = function(...)
        if gestureCallback(...) then
          return true
        end
        return featureCallback and featureCallback(...) or false
      end
    end
  end
  return true
end

function Host:_bindGestureTree(widget)
  if not widget or widget:isDestroyed() then
    return
  end
  if widget ~= self.surface then
    self:_bindGestureWidget(widget)
  end
  if widget.getChildren then
    for _, child in ipairs(widget:getChildren()) do
      self:_bindGestureTree(child)
    end
  end
end

function Host:bindGestureWidget(widget)
  if not widget or widget:isDestroyed() then
    return false
  end
  self:_bindGestureTree(widget)
  return true
end

function Host:_clearNavigation()
  for _, button in ipairs(self.navigationButtons) do
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
  for _, id in ipairs(self:_orderedIds()) do
    local entry = self.registry[id]
    local button = self.createWidget('MobileDrawerNavigationButton', self.navigation)
    button.drawerViewId = id
    button:setText(entry.descriptor.title)
    if entry.descriptor.icon ~= '' and button.setImageSource then
      button:setImageSource(entry.descriptor.icon)
    end
    button:setEnabled(true)
    self:_bindGestureWidget(button, self.navigationScrollBar)
    button.onClick = function()
      if self.gesture.suppressClick then
        return true
      end
      if self.active and self.active.entry == entry then
        self:close()
      else
        self:open(id)
      end
      return true
    end
    self.navigationButtons[#self.navigationButtons + 1] = button
  end
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

function Host:_destroyBackdrop()
  if self.unsubscribeProfile then
    self.unsubscribeProfile()
    self.unsubscribeProfile = nil
  end

  local backdrop = self.backdrop
  self.backdrop = nil
  self.surface = nil
  self.title = nil
  self.content = nil
  self.navigation = nil
  self.navigationScrollBar = nil
  self.navigationButtons = {}
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
    return false
  end

  local surface = backdrop:recursiveGetChildById('drawerSurface')
  local title = backdrop:recursiveGetChildById('drawerTitle')
  local content = backdrop:recursiveGetChildById('drawerContent')
  local navigation = backdrop:recursiveGetChildById('drawerNavigation')
  local navigationScrollBar =
    backdrop:recursiveGetChildById('drawerNavigationScrollBar')
  if not surface or not title or not content or not navigation or
      not navigationScrollBar then
    backdrop:destroy()
    return false
  end

  self.backdrop = backdrop
  self.surface = surface
  self.title = title
  self.content = content
  self.navigation = navigation
  self.navigationScrollBar = navigationScrollBar
  backdrop:setPhantom(false)
  backdrop:setEnabled(true)
  backdrop:hide()

  backdrop.onMousePress = function(_, position, button)
    self.cancelGestures()
    if button == MouseLeftButton then
      self.backdropPressOutside = not self:_positionInsideSurface(position)
      if self.backdropPressOutside then
        self:_beginGesture(position)
      end
    else
      self.backdropPressOutside = false
      self.gesture.suppressClick = true
    end
    return true
  end
  backdrop.onMouseMove = function(_, position)
    if self.backdropPressOutside then
      self:_moveGesture(position)
    end
    return true
  end
  backdrop.onMouseRelease = function(_, position, button)
    if button == MouseLeftButton then
      local pressedOutside = self.backdropPressOutside
      local releasedOutside = not self:_positionInsideSurface(position)
      self.backdropPressOutside = false
      if pressedOutside then
        self:_moveGesture(position)
      end
      local tap = pressedOutside and not self.gesture.dragged
      if pressedOutside then
        self:_finishGesture(button)
      end
      if tap and releasedOutside then
        self:close()
      end
    else
      self.backdropPressOutside = false
      self:_finishGesture(button)
    end
    return true
  end
  backdrop.onDestroy = function()
    if not self.destroyingBackdrop then
      self.backdrop = nil
      self:close()
    end
  end

  self:_bindGestureWidget(surface)
  self:_renderNavigation()
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
    self:close()
    return true
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
  local holder = self.createWidget('MobileDrawerViewHost', self.content)
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
  self:_bindGestureTree(holder)

  local shown, showResult = self:_callRecord(
    record, entry.descriptor.onShow)
  if not shown or showResult == false then
    return self:_rollbackOpening(record, transition)
  end
  if not self:_openingIsCurrent(record, transition) then
    self:_requestCleanup(record)
    return false
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
  self:_renderNavigation()
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
  self.cancelGestures()
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
    connectWidget = options.connectWidget or
      (connect and function(widget, callbacks) connect(widget, callbacks) end),
    cancelGestures = options.cancelGestures or function() end,
    registerActionHandler = options.registerActionHandler,
    onAvailabilityChange = options.onAvailabilityChange,
    logError = options.logError or defaultLogError,
    registry = {},
    viewCount = 0,
    navigationButtons = {},
    gesture = {},
    gestureBindings = setmetatable({}, { __mode = 'k' }),
    callbackDepth = 0,
    transition = 0,
    terminated = false
  }, Host)

  host.foregroundOwner = {}
  function host.foregroundOwner:onForegroundGained()
    if host.acquiringForeground then
      return
    end
    if host.terminated or not host.active then
      host:_restorePreviousForeground()
      return
    end
    if host.backdrop and not host.backdrop:isDestroyed() then
      host.backdrop:show()
      host.backdrop:raise()
    end
  end
  function host.foregroundOwner:onForegroundLost()
    host.cancelGestures()
    if host.active or host.pending then
      host:close()
    end
  end

  return host
end
