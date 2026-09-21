local hud
local status
local menu
local joystickHost
local hotbar
local actions
local drawerHandle
local unsubscribeProfile
local layoutEvent
local gameActive = false
local controlsFit = false
local foregroundOwner = {}

local function nonNegative(value)
  return math.max(0, tonumber(value) or 0)
end

local function integer(value)
  return math.floor(nonNegative(value))
end

local function rect(x, y, width, height)
  return {
    x = integer(x),
    y = integer(y),
    width = integer(width),
    height = integer(height)
  }
end

local function intersects(left, right)
  return left.x < right.x + right.width and
    right.x < left.x + left.width and
    left.y < right.y + right.height and
    right.y < left.y + left.height
end

local function profileSpacing(profile)
  if profile.class == 'tablet' then
    return 16, 8
  end
  if profile.class == 'comfortable' then
    return 12, 8
  end
  return 4, 4
end

local function computeLayout(profile)
  profile = profile or {}
  local safe = profile.safe or {}
  local safeLeft = integer(safe.left)
  local safeTop = integer(safe.top)
  local usableWidth = integer(profile.usableWidth)
  local usableHeight = integer(profile.usableHeight)
  local usableRight = safeLeft + usableWidth
  local usableBottom = safeTop + usableHeight
  local margin, gap = profileSpacing(profile)
  local target = math.max(48, integer(profile.target))
  local joystickSize = math.max(target, integer(profile.joystick))
  local slotCount = math.max(1, math.min(8, integer(profile.hotbarSlots)))
  local hotbarWidth = slotCount * target + (slotCount - 1) * gap
  local actionSize = target * 2 + gap
  local controlRowHeight = math.max(joystickSize, actionSize)
  local minimumWidth = margin * 2 + hotbarWidth
  local minimumHeight = margin * 2 + target * 2 +
    controlRowHeight + gap * 2

  -- Minimum envelopes derived from margin + top row + tallest control row +
  -- hotbar, retaining the class target and gap without shrinking:
  -- compact     316x224 = 4 + (6*48 + 5*4) + 4,
  --                       4 + 48 + 4 + 112 + 4 + 48 + 4
  -- comfortable 400x288 = 12 + (6*56 + 5*8) + 12,
  --                       12 + 56 + 8 + 136 + 8 + 56 + 12
  -- tablet      536x320 = 16 + (8*56 + 7*8) + 16,
  --                       16 + 56 + 8 + 160 + 8 + 56 + 16
  if usableWidth < minimumWidth or usableHeight < minimumHeight then
    return {
      controlsFit = false,
      minimumWidth = minimumWidth,
      minimumHeight = minimumHeight,
      slotCount = slotCount
    }
  end

  local hotbarRect = rect(
    safeLeft + math.floor((usableWidth - hotbarWidth) / 2),
    usableBottom - margin - target,
    hotbarWidth,
    target)

  local leftEdge = safeLeft + margin
  local rightEdge = usableRight - margin
  local controlBottom = hotbarRect.y - gap
  local mirrored = profile.handedness == 'mirrored'
  local joystickX = mirrored and rightEdge - joystickSize or leftEdge
  local actionsX = mirrored and leftEdge or rightEdge - actionSize

  local actionButtons = {}
  for index = 1, 4 do
    local column = (index - 1) % 2
    local row = math.floor((index - 1) / 2)
    actionButtons[index] = rect(
      column * (target + gap),
      row * (target + gap),
      target,
      target)
  end

  local hotbarSlots = {}
  for index = 1, 8 do
    hotbarSlots[index] = rect(
      (index - 1) * (target + gap),
      0,
      target,
      target)
  end

  local statusWidth = math.max(
    target * 3,
    math.min(240, math.floor(usableWidth * 0.34)))
  local statusRect = rect(leftEdge, safeTop + margin, statusWidth, target)
  local menuRect = rect(rightEdge - target, safeTop + margin, target, target)
  local joystickRect = rect(
    joystickX, controlBottom - joystickSize, joystickSize, joystickSize)
  local actionsRect = rect(
    actionsX, controlBottom - actionSize, actionSize, actionSize)
  local drawerRect = rect(
    statusRect.x + statusRect.width + gap,
    safeTop + margin,
    target,
    target)

  return {
    controlsFit = true,
    minimumWidth = minimumWidth,
    minimumHeight = minimumHeight,
    target = target,
    slotCount = slotCount,
    status = statusRect,
    menu = menuRect,
    joystickHost = joystickRect,
    hotbar = hotbarRect,
    actions = actionsRect,
    drawerHandle = drawerRect,
    actionButtons = actionButtons,
    hotbarSlots = hotbarSlots
  }
end

local function applyRect(widget, geometry)
  if widget then
    widget:setRect(geometry)
  end
end

local function synchronizeJoystick(bounds)
  local joystick = modules.game_joystick
  if not joystick or not joystick.setEnabled then
    return
  end

  if bounds and joystick.setBounds then
    joystick.setEnabled(false)
    joystick.setBounds(bounds)
  end

  local visible = gameActive and controlsFit and hud and
    not hud:isDestroyed() and hud:isVisible()
  if visible then
    joystick.show()
  else
    joystick.hide()
  end

  local state, owner = modules.client_mobileui.getForeground()
  joystick.setEnabled(
    visible and state == 'gameplay' and owner == foregroundOwner)
end

local function applyComputedLayout(layout)
  if not hud or hud:isDestroyed() then
    return
  end

  controlsFit = layout.controlsFit
  hud.controlsFit = controlsFit
  if not controlsFit then
    setControlsVisible(false)
    return
  end

  applyRect(status, layout.status)
  applyRect(menu, layout.menu)
  applyRect(joystickHost, layout.joystickHost)
  applyRect(hotbar, layout.hotbar)
  applyRect(actions, layout.actions)
  applyRect(drawerHandle, layout.drawerHandle)

  for index, geometry in ipairs(layout.hotbarSlots) do
    local slot = hotbar:getChildById('slot' .. index)
    if slot then
      applyRect(slot, {
        x = layout.hotbar.x + geometry.x,
        y = layout.hotbar.y + geometry.y,
        width = geometry.width,
        height = geometry.height
      })
      slot:setVisible(index <= layout.slotCount)
    end
  end

  local actionIds = { 'attack', 'use', 'chat', 'inventory' }
  for index, id in ipairs(actionIds) do
    local button = actions:getChildById(id)
    local geometry = layout.actionButtons[index]
    if button and geometry then
      applyRect(button, {
        x = layout.actions.x + geometry.x,
        y = layout.actions.y + geometry.y,
        width = geometry.width,
        height = geometry.height
      })
    end
  end

  synchronizeJoystick(layout.joystickHost)
  setControlsVisible(true)
end

function applyProfile(profile)
  if not hud or hud:isDestroyed() then
    return false
  end

  local layout = computeLayout(profile)
  removeEvent(layoutEvent)
  layoutEvent = addEvent(function()
    layoutEvent = nil
    applyComputedLayout(layout)
  end)
  return true
end

function getHud()
  return hud
end

function setControlsVisible(visible)
  if not hud or hud:isDestroyed() then
    return false
  end

  visible = visible == true and gameActive and controlsFit
  hud:setEnabled(visible)
  if hud:isVisible() ~= visible then
    hud:setVisible(visible)
  end
  synchronizeJoystick()
  return true
end

local function raiseGameplayHud()
  if not hud or hud:isDestroyed() or not gameActive or
      not controlsFit or not hud:isVisible() then
    return false
  end

  local state, owner = modules.client_mobileui.getForeground()
  if state ~= 'gameplay' or owner ~= foregroundOwner then
    return false
  end

  hud:raise()
  return true
end

local function acquireGameplayForeground()
  local mobileUi = modules.client_mobileui
  local state, owner = mobileUi.getForeground()
  if state == 'gameplay' and owner == foregroundOwner then
    return true
  end
  if state ~= 'gameplay' or owner ~= nil then
    return false
  end

  if not mobileUi.setForeground('gameplay', foregroundOwner) then
    return false
  end
  local acquiredState, acquiredOwner = mobileUi.getForeground()
  return acquiredState == 'gameplay' and acquiredOwner == foregroundOwner
end

local function releaseGameplayForeground()
  local mobileUi = modules.client_mobileui
  local state, owner = mobileUi.getForeground()
  if state == 'gameplay' and owner == foregroundOwner then
    mobileUi.setForeground('gameplay', nil)
  end
end

function foregroundOwner:onForegroundGained()
  if not gameActive then
    synchronizeJoystick()
    releaseGameplayForeground()
    return
  end
  synchronizeJoystick()
  raiseGameplayHud()
end

function foregroundOwner:onForegroundLost()
  synchronizeJoystick()
end

local function onGameStart()
  if gameActive then
    setControlsVisible(true)
    return
  end

  gameActive = true
  applyProfile(modules.client_mobileui.getProfile())
  local acquiredForeground = acquireGameplayForeground()
  setControlsVisible(true)
  if acquiredForeground then
    raiseGameplayHud()
  end
end

local function onGameEnd()
  if not gameActive then
    return
  end

  gameActive = false
  setControlsVisible(false)
  releaseGameplayForeground()
end

function runSelfTests()
  local function insideUsable(geometry, profile)
    local left = profile.safe.left
    local top = profile.safe.top
    return geometry.x >= left and geometry.y >= top and
      geometry.x + geometry.width <= left + profile.usableWidth and
      geometry.y + geometry.height <= top + profile.usableHeight
  end

  local function assertVisibleLayout(profile)
    local layout = computeLayout(profile)
    assert(layout.controlsFit, 'gameplay controls must fit supported profile')
    local direct = {
      layout.status,
      layout.menu,
      layout.joystickHost,
      layout.hotbar,
      layout.actions,
      layout.drawerHandle
    }
    for index, geometry in ipairs(direct) do
      assert(insideUsable(geometry, profile),
        'gameplay direct control must remain inside usable rect: ' .. index)
      for otherIndex = index + 1, #direct do
        assert(not intersects(geometry, direct[otherIndex]),
          'gameplay direct controls must not overlap')
      end
    end
    for index = 1, layout.slotCount do
      local slot = layout.hotbarSlots[index]
      assert(insideUsable(rect(
        layout.hotbar.x + slot.x,
        layout.hotbar.y + slot.y,
        slot.width,
        slot.height), profile),
        'gameplay hotbar slot must remain inside usable rect')
    end
    return layout
  end

  local profiles = {
    {
      class = 'compact', usableWidth = 800, usableHeight = 390,
      safe = { left = 0, top = 0, right = 0, bottom = 0 },
      target = 48, joystick = 112, hotbarSlots = 6
    },
    {
      class = 'comfortable', usableWidth = 900, usableHeight = 520,
      safe = { left = 12, top = 10, right = 16, bottom = 14 },
      target = 56, joystick = 136, hotbarSlots = 6
    },
    {
      class = 'tablet', usableWidth = 1180, usableHeight = 720,
      safe = { left = 20, top = 18, right = 24, bottom = 16 },
      target = 56, joystick = 160, hotbarSlots = 8
    }
  }

  for _, profile in ipairs(profiles) do
    local layout = assertVisibleLayout(profile)
    assert(layout.target >= 48, 'gameplay target must be at least 48')
    assert(layout.joystickHost.width == profile.joystick,
      'gameplay joystick size must follow profile')
    assert(layout.slotCount == profile.hotbarSlots,
      'gameplay hotbar slot count must follow profile')
    assert(not intersects(layout.joystickHost, layout.hotbar),
      'gameplay joystick must not intersect hotbar')
    assert(not intersects(layout.actions, layout.hotbar),
      'gameplay actions must not intersect hotbar')
  end

  local standard = assertVisibleLayout(profiles[1])
  profiles[1].handedness = 'mirrored'
  local mirrored = assertVisibleLayout(profiles[1])
  assert(mirrored.joystickHost.x > standard.joystickHost.x,
    'mirrored joystick must use right zone')
  assert(mirrored.actions.x < standard.actions.x,
    'mirrored actions must use left zone')
  assert(not intersects(mirrored.joystickHost, mirrored.hotbar),
    'mirrored joystick must not intersect hotbar')
  assert(not intersects(mirrored.actions, mirrored.hotbar),
    'mirrored actions must not intersect hotbar')

  local minimumCompact = {
    class = 'compact', usableWidth = 316, usableHeight = 224,
    safe = { left = 17, top = 11, right = 9, bottom = 7 },
    target = 48, joystick = 112, hotbarSlots = 6,
    handedness = 'standard'
  }
  local minimumLayout = assertVisibleLayout(minimumCompact)
  assert(minimumLayout.minimumWidth == 316 and
    minimumLayout.minimumHeight == 224,
    'compact minimum envelope must remain 316x224')

  minimumCompact.usableWidth = 406
  assertVisibleLayout(minimumCompact)
  minimumCompact.handedness = 'mirrored'
  assertVisibleLayout(minimumCompact)

  for _, emergency in ipairs({
    { width = 315, height = 224 },
    { width = 316, height = 223 },
    { width = 300, height = 224 },
    { width = 406, height = 200 }
  }) do
    local layout = computeLayout({
      class = 'compact',
      usableWidth = emergency.width,
      usableHeight = emergency.height,
      safe = { left = 13, top = 7, right = 5, bottom = 3 },
      target = 48,
      joystick = 112,
      hotbarSlots = 6,
      handedness = 'standard'
    })
    assert(not layout.controlsFit,
      'undersized gameplay profile must use controlsFit fallback')
  end

  g_logger.info('[mobile-ui-test] gameplay-layout PASS')
end

function init()
  local mobileUi = modules.client_mobileui
  if not g_platform.isMobile() or not mobileUi.isV2Enabled() then
    return
  end

  g_ui.importStyle('styles.otui')
  hud = g_ui.displayUI('game_mobileui')
  status = hud:getChildById('status')
  menu = hud:getChildById('menu')
  joystickHost = hud:getChildById('joystickHost')
  hotbar = hud:getChildById('hotbar')
  actions = hud:getChildById('actions')
  drawerHandle = hud:getChildById('drawerHandle')

  gameActive = false
  controlsFit = false
  hud.controlsFit = false
  setControlsVisible(false)
  applyProfile(mobileUi.getProfile())
  unsubscribeProfile = mobileUi.subscribeProfile(applyProfile)
  connect(g_game, {
    onGameStart = onGameStart,
    onGameEnd = onGameEnd
  })

  if g_game.isOnline() then
    onGameStart()
  end
end

function terminate()
  if not hud then
    return
  end

  disconnect(g_game, {
    onGameStart = onGameStart,
    onGameEnd = onGameEnd
  })
  if unsubscribeProfile then
    unsubscribeProfile()
    unsubscribeProfile = nil
  end
  removeEvent(layoutEvent)
  layoutEvent = nil
  onGameEnd()
  hud:destroy()
  hud = nil
  status = nil
  menu = nil
  joystickHost = nil
  hotbar = nil
  actions = nil
  drawerHandle = nil
  gameActive = false
  controlsFit = false
end
