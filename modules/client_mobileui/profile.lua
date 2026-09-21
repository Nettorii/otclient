local computeProfile
local createProfileService

local function expectEqual(actual, expected, message)
  assert(actual == expected,
    string.format('%s: expected %s, got %s', message, tostring(expected), tostring(actual)))
end

function runSelfTests()
  local compact = computeProfile(800, 390, 0, 0, 0, 0, 0)
  expectEqual(compact.class, 'compact', 'height 390 class')
  expectEqual(compact.target, 48, 'compact target')
  expectEqual(compact.joystick, 112, 'compact joystick')
  expectEqual(compact.hotbarSlots, 6, 'compact hotbar slots')

  local comfortable = computeProfile(800, 391, 0, 0, 0, 0, 0)
  expectEqual(comfortable.class, 'comfortable', 'height 391 class')
  expectEqual(comfortable.target, 56, 'comfortable target')
  expectEqual(comfortable.joystick, 136, 'comfortable joystick')
  expectEqual(comfortable.hotbarSlots, 6, 'comfortable hotbar slots')
  expectEqual(computeProfile(800, 599, 0, 0, 0, 0, 0).class,
    'comfortable', 'height 599 class')

  local tablet = computeProfile(1024, 600, 0, 0, 0, 0, 0)
  expectEqual(tablet.class, 'tablet', 'height 600 class')
  expectEqual(tablet.target, 56, 'tablet target')
  expectEqual(tablet.joystick, 160, 'tablet joystick')
  expectEqual(tablet.hotbarSlots, 8, 'tablet hotbar slots')

  local occluded = computeProfile(500, 400, 10, 20, 30, 40, 50)
  expectEqual(occluded.usableWidth, 460, 'safe horizontal insets')
  expectEqual(occluded.usableHeight, 290, 'safe and keyboard vertical insets')
  expectEqual(occluded.class, 'compact', 'class uses usable height')

  local normalized = computeProfile(100, 100, -1, -2, -3, -4, -5)
  expectEqual(normalized.usableWidth, 100, 'negative horizontal insets')
  expectEqual(normalized.usableHeight, 100, 'negative vertical insets')
  expectEqual(normalized.safe.left, 0, 'negative left inset')
  expectEqual(normalized.safe.top, 0, 'negative top inset')
  expectEqual(normalized.safe.right, 0, 'negative right inset')
  expectEqual(normalized.safe.bottom, 0, 'negative bottom inset')
  expectEqual(normalized.keyboardHeight, 0, 'negative keyboard height')

  local fullyOccluded = computeProfile(10, 10, 8, 8, 8, 8, 8)
  expectEqual(fullyOccluded.usableWidth, 0, 'usable width floor')
  expectEqual(fullyOccluded.usableHeight, 0, 'usable height floor')

  local metrics = { 800, 390, 0, 0, 0, 0, 0 }
  local boundRefresh
  local unboundRefresh
  local service = createProfileService(
    function() return unpack(metrics) end,
    function(refresh) boundRefresh = refresh end,
    function(refresh) unboundRefresh = refresh end)
  service.start()
  assert(boundRefresh, 'profile service must subscribe to metric changes')

  local first = service.get()
  first.safe.left = 999
  expectEqual(service.get().safe.left, 0, 'getProfile returns a fresh safe table')

  local notifications = 0
  local unsubscribe = service.subscribe(function(profile)
    notifications = notifications + 1
    profile.safe.left = 999
  end)
  boundRefresh()
  expectEqual(notifications, 0, 'duplicate profiles do not notify')
  metrics[2] = 391
  boundRefresh()
  expectEqual(notifications, 1, 'changed profile notifies once')
  expectEqual(service.get().safe.left, 0, 'subscriber receives a fresh profile')
  unsubscribe()
  unsubscribe()
  metrics[2] = 600
  boundRefresh()
  expectEqual(notifications, 1, 'unsubscribe closure is idempotent')

  local firstCycleCalls = 0
  local removedDuringCycleCalls = 0
  local addedDuringCycleCalls = 0
  local unsubscribeDuringCycle
  service.subscribe(function()
    firstCycleCalls = firstCycleCalls + 1
    unsubscribeDuringCycle()
    service.subscribe(function()
      addedDuringCycleCalls = addedDuringCycleCalls + 1
    end)
  end)
  unsubscribeDuringCycle = service.subscribe(function()
    removedDuringCycleCalls = removedDuringCycleCalls + 1
  end)
  metrics[2] = 599
  boundRefresh()
  expectEqual(firstCycleCalls, 1, 'cycle-start subscriber called once')
  expectEqual(removedDuringCycleCalls, 1,
    'subscriber removed during notification still runs in current cycle')
  expectEqual(addedDuringCycleCalls, 0,
    'subscriber added during notification waits until next cycle')
  metrics[2] = 390
  boundRefresh()
  expectEqual(addedDuringCycleCalls, 1,
    'subscriber added during notification runs in next cycle')

  service.stop()
  expectEqual(unboundRefresh, boundRefresh, 'profile service disconnects its refresh callback')

  if runStateSelfTests then
    runStateSelfTests()
  end
  if runActivationSelfTests then
    runActivationSelfTests()
  end

  g_logger.info('[mobile-ui-test] profile PASS')
end

local PROFILE_VALUES = {
  compact = { target = 48, joystick = 112, hotbarSlots = 6, drawerWidth = 280 },
  comfortable = { target = 56, joystick = 136, hotbarSlots = 6, drawerWidth = 320 },
  tablet = { target = 56, joystick = 160, hotbarSlots = 8, drawerWidth = 400 }
}

local function nonNegative(value)
  return math.max(0, tonumber(value) or 0)
end

local function classForHeight(height)
  if height <= 390 then return 'compact' end
  if height < 600 then return 'comfortable' end
  return 'tablet'
end

computeProfile = function(width, height, safeLeft, safeTop, safeRight, safeBottom, keyboardHeight)
  width = nonNegative(width)
  height = nonNegative(height)
  safeLeft = nonNegative(safeLeft)
  safeTop = nonNegative(safeTop)
  safeRight = nonNegative(safeRight)
  safeBottom = nonNegative(safeBottom)
  keyboardHeight = nonNegative(keyboardHeight)

  local usableWidth = math.max(0, width - safeLeft - safeRight)
  local usableHeight = math.max(0, height - safeTop - safeBottom - keyboardHeight)
  local class = classForHeight(usableHeight)
  local values = PROFILE_VALUES[class]

  return {
    class = class,
    usableWidth = usableWidth,
    usableHeight = usableHeight,
    safe = {
      left = safeLeft,
      top = safeTop,
      right = safeRight,
      bottom = safeBottom
    },
    keyboardHeight = keyboardHeight,
    target = values.target,
    joystick = values.joystick,
    hotbarSlots = values.hotbarSlots,
    drawerWidth = math.min(usableWidth, values.drawerWidth)
  }
end

local function copyProfile(profile)
  return {
    class = profile.class,
    usableWidth = profile.usableWidth,
    usableHeight = profile.usableHeight,
    safe = {
      left = profile.safe.left,
      top = profile.safe.top,
      right = profile.safe.right,
      bottom = profile.safe.bottom
    },
    keyboardHeight = profile.keyboardHeight,
    target = profile.target,
    joystick = profile.joystick,
    hotbarSlots = profile.hotbarSlots,
    drawerWidth = profile.drawerWidth
  }
end

local function profilesEqual(left, right)
  return left and right and
    left.class == right.class and
    left.usableWidth == right.usableWidth and
    left.usableHeight == right.usableHeight and
    left.safe.left == right.safe.left and
    left.safe.top == right.safe.top and
    left.safe.right == right.safe.right and
    left.safe.bottom == right.safe.bottom and
    left.keyboardHeight == right.keyboardHeight and
    left.target == right.target and
    left.joystick == right.joystick and
    left.hotbarSlots == right.hotbarSlots and
    left.drawerWidth == right.drawerWidth
end

createProfileService = function(readMetrics, bindRefresh, unbindRefresh)
  local activeProfile
  local subscribers = {}
  local nextSubscriberId = 0
  local started = false
  local service = {}

  function service.refresh()
    local nextProfile = computeProfile(readMetrics())
    if profilesEqual(activeProfile, nextProfile) then
      return false
    end

    activeProfile = nextProfile
    local notificationSnapshot = {}
    for _, callback in pairs(subscribers) do
      table.insert(notificationSnapshot, callback)
    end
    for _, callback in ipairs(notificationSnapshot) do
      callback(copyProfile(activeProfile))
    end
    return true
  end

  function service.start()
    if started then return end
    started = true
    bindRefresh(service.refresh)
    service.refresh()
  end

  function service.stop()
    if not started then return end
    started = false
    unbindRefresh(service.refresh)
  end

  function service.get()
    if not activeProfile then
      service.refresh()
    end
    return copyProfile(activeProfile)
  end

  function service.subscribe(callback)
    assert(type(callback) == 'function', 'profile callback must be a function')
    nextSubscriberId = nextSubscriberId + 1
    local subscriberId = nextSubscriberId
    subscribers[subscriberId] = callback
    local subscribed = true

    return function()
      if not subscribed then return end
      subscribed = false
      subscribers[subscriberId] = nil
    end
  end

  return service
end

local rootWidget
local profileService

local function getWindowMetric(name)
  local getter = g_window[name]
  if not getter then return 0 end
  return getter()
end

local function readViewportMetrics()
  rootWidget = rootWidget or g_ui.getRootWidget()
  return rootWidget:getWidth(),
    rootWidget:getHeight(),
    getWindowMetric('getSafeAreaInsetLeft'),
    getWindowMetric('getSafeAreaInsetTop'),
    getWindowMetric('getSafeAreaInsetRight'),
    getWindowMetric('getSafeAreaInsetBottom'),
    getWindowMetric('getKeyboardHeight')
end

local function bindViewportChanges(refresh)
  rootWidget = g_ui.getRootWidget()
  connect(g_window, { onViewportMetricsChange = refresh })
  connect(rootWidget, { onGeometryChange = refresh })
end

local function unbindViewportChanges(refresh)
  disconnect(g_window, { onViewportMetricsChange = refresh })
  if rootWidget then
    disconnect(rootWidget, { onGeometryChange = refresh })
  end
end

function initProfile()
  if profileService then return end
  profileService = createProfileService(
    readViewportMetrics, bindViewportChanges, unbindViewportChanges)
  profileService.start()
end

function terminateProfile()
  if not profileService then return end
  profileService.stop()
  profileService = nil
  rootWidget = nil
end

function refreshProfile()
  if not profileService then initProfile() end
  return profileService.refresh()
end

function getProfile()
  if not profileService then initProfile() end
  return profileService.get()
end

function subscribeProfile(callback)
  if not profileService then initProfile() end
  return profileService.subscribe(callback)
end
