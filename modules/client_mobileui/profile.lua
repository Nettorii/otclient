local computeProfile
local createProfileService

local function expectEqual(actual, expected, message)
  assert(actual == expected,
    string.format('%s: expected %s, got %s', message, tostring(expected), tostring(actual)))
end

function runSelfTests()
  local compact = computeProfile(
    800, 390, 0, 0, 0, 0, 0, 'compact', 'standard', 0.86)
  expectEqual(compact.class, 'compact', 'height 390 class')
  expectEqual(compact.target, 48, 'compact target')
  expectEqual(compact.joystick, 112, 'compact joystick')
  expectEqual(compact.hotbarSlots, 6, 'compact hotbar slots')
  expectEqual(compact.handedness, 'standard', 'standard handedness')
  expectEqual(computeProfile(
    800, 390, 0, 0, 0, 0, 0, 'compact', 'mirrored', 0.86).handedness,
    'mirrored', 'mirrored handedness')
  expectEqual(computeProfile(
    800, 390, 0, 0, 0, 0, 0, 'compact', 'invalid', 0.86).handedness,
    'standard', 'invalid handedness fallback')
  expectEqual(computeProfile(800, 390, 0, 0, 0, 0, 0).handedness,
    'standard', 'missing handedness fallback')

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

  -- Unknown metrics deliberately use zero insets and the compact fallback.
  local unknown = computeProfile(nil, nil, nil, nil, nil, nil, nil)
  expectEqual(unknown.class, 'compact', 'unknown metrics class')
  expectEqual(unknown.controlClass, 'compact',
    'unknown metrics control class')
  expectEqual(unknown.safe.left, 0, 'unknown metrics left inset')
  expectEqual(unknown.safe.top, 0, 'unknown metrics top inset')
  expectEqual(unknown.safe.right, 0, 'unknown metrics right inset')
  expectEqual(unknown.safe.bottom, 0, 'unknown metrics bottom inset')

  local metrics = { 800, 390, 0, 0, 0, 0, 0, 'standard' }
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
  metrics[8] = 'mirrored'
  boundRefresh()
  expectEqual(notifications, 2, 'handedness change notifies once')
  expectEqual(service.get().handedness, 'mirrored',
    'profile service preserves mirrored handedness')
  unsubscribe()
  unsubscribe()
  metrics[2] = 600
  boundRefresh()
  expectEqual(notifications, 2, 'unsubscribe closure is idempotent')

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
  if runPortraitSelfTests then
    runPortraitSelfTests()
  end
  if runActivationSelfTests then
    runActivationSelfTests()
  end

  g_logger.info('[mobile-ui-test] profile PASS')
end

local PROFILE_VALUES = {
  compact = {
    target = 48, joystick = 112, hotbarSlots = 6, drawerWidth = 280,
    margin = 4, gap = 4
  },
  comfortable = {
    target = 56, joystick = 136, hotbarSlots = 6, drawerWidth = 320,
    margin = 12, gap = 8
  },
  tablet = {
    target = 56, joystick = 160, hotbarSlots = 8, drawerWidth = 400,
    margin = 16, gap = 8
  }
}

local PROFILE_MINIMUMS = {
  compact = { width = 316, height = 224 },
  comfortable = { width = 400, height = 288 },
  tablet = { width = 536, height = 320 }
}

local MOBILE_OPACITY_DEFAULT = 0.86
local MOBILE_OPACITY_MIN = 0.72
local MOBILE_OPACITY_MAX = 1.0
local preparedMobileSettings

local function nonNegative(value)
  return math.max(0, tonumber(value) or 0)
end

local function classForHeight(height)
  if height <= 390 then return 'compact' end
  if height < 600 then return 'comfortable' end
  return 'tablet'
end

local function sanitizeHandedness(handedness)
  if handedness == 'mirrored' then
    return 'mirrored'
  end
  return 'standard'
end

local function sanitizeControlPreset(preset)
  if preset == 'compact' then
    return 'compact'
  end
  return 'comfortable'
end

local function sanitizeOverlayOpacity(value)
  value = tonumber(value)
  if value == nil or value ~= value then
    return MOBILE_OPACITY_DEFAULT
  end
  if value == math.huge then
    return MOBILE_OPACITY_MAX
  end
  if value == -math.huge then
    return MOBILE_OPACITY_MIN
  end
  return math.max(MOBILE_OPACITY_MIN, math.min(MOBILE_OPACITY_MAX, value))
end

local function sanitizePersistedOverlayOpacity(value)
  local number = tonumber(value)
  if number == nil or number ~= number or number == math.huge or
      number == -math.huge or number < MOBILE_OPACITY_MIN or
      number > MOBILE_OPACITY_MAX then
    return MOBILE_OPACITY_DEFAULT
  end
  return number
end

local function mobileV2Runtime()
  return g_platform and g_platform.isMobile and g_platform.isMobile() and
    type(isV2Enabled) == 'function' and isV2Enabled()
end

function prepareMobileProfileSettings()
  if preparedMobileSettings or not mobileV2Runtime() then
    return preparedMobileSettings
  end

  local values = {
    mobileControlPreset = g_settings.getString(
      'mobileControlPreset', 'comfortable'),
    mobileHandedness = g_settings.getString(
      'mobileHandedness', 'standard'),
    mobileOverlayOpacity = g_settings.getNumber(
      'mobileOverlayOpacity', MOBILE_OPACITY_DEFAULT)
  }
  local normalized = {
    mobileControlPreset = sanitizeControlPreset(values.mobileControlPreset),
    mobileHandedness = sanitizeHandedness(values.mobileHandedness),
    mobileOverlayOpacity = sanitizePersistedOverlayOpacity(
      values.mobileOverlayOpacity)
  }
  local corrected = false
  for _, key in ipairs({
    'mobileControlPreset',
    'mobileHandedness',
    'mobileOverlayOpacity'
  }) do
    if values[key] ~= normalized[key] then
      g_settings.set(key, normalized[key])
      corrected = true
    end
  end
  if corrected then
    g_settings.save()
  end
  preparedMobileSettings = normalized
  return preparedMobileSettings
end

local function overlayColor(baseColor, opacity)
  local rgb = tostring(baseColor or '#000000'):match('^#?(%x%x%x%x%x%x)')
  if not rgb then
    rgb = '000000'
  end
  local alpha = math.floor(sanitizeOverlayOpacity(opacity) * 255 + 0.5)
  return string.format('#%s%02x', rgb, alpha)
end

function applyOverlaySurface(widget, baseColor, profileOrOpacity)
  if not widget or widget:isDestroyed() or
      type(widget.setBackgroundColor) ~= 'function' then
    return false
  end
  local opacity = type(profileOrOpacity) == 'table' and
    profileOrOpacity.overlayOpacity or profileOrOpacity
  widget:setBackgroundColor(overlayColor(baseColor, opacity))
  return true
end

function applyDeclaredOverlay(widget, profileOrOpacity)
  if not widget or widget:isDestroyed() or
      type(widget.getStyle) ~= 'function' then
    return false
  end
  local style = widget:getStyle()
  local baseColor = style and style['mobile-overlay-base']
  if not baseColor then
    return false
  end
  return applyOverlaySurface(
    widget, baseColor, profileOrOpacity or getProfile())
end

function applyOverlayTree(root, profileOrOpacity)
  if not root or root:isDestroyed() then
    return false
  end

  local applied = false
  applied = applyDeclaredOverlay(root, profileOrOpacity) or applied

  if type(root.getChildren) == 'function' then
    for _, child in ipairs(root:getChildren()) do
      applied = applyOverlayTree(child, profileOrOpacity) or applied
    end
  end
  return applied
end

local function controlClassFor(viewportClass, preset, usableWidth, usableHeight)
  if preset == 'compact' then
    return 'compact'
  end
  local requested = viewportClass == 'tablet' and 'tablet' or 'comfortable'
  local minimum = PROFILE_MINIMUMS[requested]
  if usableWidth < minimum.width or usableHeight < minimum.height then
    return 'compact'
  end
  return requested
end

computeProfile = function(width, height, safeLeft, safeTop, safeRight, safeBottom,
    keyboardHeight, controlPreset, handedness, overlayOpacity)
  -- Preserve the pre-settings helper signature for existing profile contracts.
  if (controlPreset == 'standard' or controlPreset == 'mirrored') and
      handedness == nil then
    handedness = controlPreset
    controlPreset = nil
  end
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
  controlPreset = sanitizeControlPreset(controlPreset)
  local controlClass = controlClassFor(
    class, controlPreset, usableWidth, usableHeight)
  local values = PROFILE_VALUES[controlClass]
  local viewportValues = PROFILE_VALUES[class]

  return {
    class = class,
    controlClass = controlClass,
    controlPreset = controlPreset,
    usableWidth = usableWidth,
    usableHeight = usableHeight,
    safe = {
      left = safeLeft,
      top = safeTop,
      right = safeRight,
      bottom = safeBottom
    },
    keyboardHeight = keyboardHeight,
    handedness = sanitizeHandedness(handedness),
    overlayOpacity = sanitizeOverlayOpacity(overlayOpacity),
    target = values.target,
    joystick = values.joystick,
    hotbarSlots = values.hotbarSlots,
    margin = values.margin,
    gap = values.gap,
    drawerWidth = math.min(usableWidth, viewportValues.drawerWidth)
  }
end

local function copyProfile(profile)
  return {
    class = profile.class,
    controlClass = profile.controlClass,
    controlPreset = profile.controlPreset,
    usableWidth = profile.usableWidth,
    usableHeight = profile.usableHeight,
    safe = {
      left = profile.safe.left,
      top = profile.safe.top,
      right = profile.safe.right,
      bottom = profile.safe.bottom
    },
    keyboardHeight = profile.keyboardHeight,
    handedness = profile.handedness,
    overlayOpacity = profile.overlayOpacity,
    target = profile.target,
    joystick = profile.joystick,
    hotbarSlots = profile.hotbarSlots,
    margin = profile.margin,
    gap = profile.gap,
    drawerWidth = profile.drawerWidth
  }
end

local function profilesEqual(left, right)
  return left and right and
    left.class == right.class and
    left.controlClass == right.controlClass and
    left.controlPreset == right.controlPreset and
    left.usableWidth == right.usableWidth and
    left.usableHeight == right.usableHeight and
    left.safe.left == right.safe.left and
    left.safe.top == right.safe.top and
    left.safe.right == right.safe.right and
    left.safe.bottom == right.safe.bottom and
    left.keyboardHeight == right.keyboardHeight and
    left.handedness == right.handedness and
    left.overlayOpacity == right.overlayOpacity and
    left.target == right.target and
    left.joystick == right.joystick and
    left.hotbarSlots == right.hotbarSlots and
    left.margin == right.margin and
    left.gap == right.gap and
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
  local ok, value = pcall(getter)
  if not ok then
    g_logger.warning(string.format(
      '[client_mobileui] unavailable viewport metric %s: %s',
      tostring(name), tostring(value)))
    return 0
  end
  return value
end

local function readMobileOption(key, defaultValue, settingGetter)
  if not mobileV2Runtime() then
    return defaultValue
  end
  local clientOptions = modules and modules.client_options
  local optionsReady = clientOptions and
    type(clientOptions.isReady) == 'function' and clientOptions.isReady()
  if optionsReady and type(clientOptions.getOption) == 'function' then
    local value = clientOptions.getOption(key)
    if value ~= nil then
      return value
    end
  end
  local prepared = prepareMobileProfileSettings()
  if prepared and prepared[key] ~= nil then
    return prepared[key]
  end
  if g_settings and type(g_settings[settingGetter]) == 'function' then
    return g_settings[settingGetter](key, defaultValue)
  end
  return defaultValue
end

local function readViewportMetrics()
  rootWidget = rootWidget or g_ui.getRootWidget()
  local viewportWidth = getWindowMetric('getViewportWidth')
  local viewportHeight = getWindowMetric('getViewportHeight')
  if viewportWidth <= 0 then
    viewportWidth = rootWidget:getWidth()
  end
  if viewportHeight <= 0 then
    viewportHeight = rootWidget:getHeight()
  end
  local controlPreset = readMobileOption(
    'mobileControlPreset', 'comfortable', 'getString')
  local handedness = readMobileOption(
    'mobileHandedness', 'standard', 'getString')
  local overlayOpacity = readMobileOption(
    'mobileOverlayOpacity', MOBILE_OPACITY_DEFAULT, 'getNumber')
  return viewportWidth,
    viewportHeight,
    getWindowMetric('getSafeAreaInsetLeft'),
    getWindowMetric('getSafeAreaInsetTop'),
    getWindowMetric('getSafeAreaInsetRight'),
    getWindowMetric('getSafeAreaInsetBottom'),
    getWindowMetric('getKeyboardHeight'),
    controlPreset,
    handedness,
    overlayOpacity
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
  prepareMobileProfileSettings()
  profileService = createProfileService(
    readViewportMetrics, bindViewportChanges, unbindViewportChanges)
  profileService.start()
end

function terminateProfile()
  if not profileService then return end
  profileService.stop()
  profileService = nil
  rootWidget = nil
  preparedMobileSettings = nil
end

function refreshProfile()
  if not profileService then initProfile() end
  return profileService.refresh()
end

function refreshProfileSettings()
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
