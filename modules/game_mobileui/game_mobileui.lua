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
  return 6, 4
end

local function sideRect(side, width, height, zone, bottom, hotbarRect, gap)
  local x
  if side == 'left' then
    x = zone.x
  else
    x = zone.x + zone.width - width
  end

  local y = bottom - height
  if width > zone.width then
    y = math.min(y, hotbarRect.y - gap - height)
  end
  return rect(x, y, width, height)
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
  local hotbarRect = rect(
    safeLeft + math.floor((usableWidth - hotbarWidth) / 2),
    usableBottom - margin - target,
    hotbarWidth,
    target)

  local leftEdge = safeLeft + margin
  local rightEdge = usableRight - margin
  local leftZone = rect(
    leftEdge,
    safeTop + margin,
    math.max(0, hotbarRect.x - gap - leftEdge),
    math.max(0, usableHeight - margin * 2))
  local rightZoneX = hotbarRect.x + hotbarRect.width + gap
  local rightZone = rect(
    rightZoneX,
    safeTop + margin,
    math.max(0, rightEdge - rightZoneX),
    math.max(0, usableHeight - margin * 2))

  local actionSize = target * 2 + gap
  local controlBottom = usableBottom - margin
  local mirrored = profile.handedness == 'mirrored'
  local joystickZone = mirrored and rightZone or leftZone
  local actionZone = mirrored and leftZone or rightZone
  local joystickSide = mirrored and 'right' or 'left'
  local actionSide = mirrored and 'left' or 'right'

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
  local joystickRect = sideRect(
    joystickSide, joystickSize, joystickSize, joystickZone,
    controlBottom, hotbarRect, gap)
  local actionsRect = sideRect(
    actionSide, actionSize, actionSize, actionZone,
    controlBottom, hotbarRect, gap)
  local rightControl = mirrored and joystickRect or actionsRect
  local drawerY = menuRect.y + menuRect.height + gap
  if drawerY + target > rightControl.y - gap then
    local belowControl = rightControl.y + rightControl.height + gap
    local latestDrawerY = usableBottom - margin - target
    if belowControl <= latestDrawerY then
      drawerY = belowControl
    else
      drawerY = math.max(
        safeTop + margin,
        math.min(latestDrawerY,
          safeTop + math.floor((usableHeight - target) / 2)))
    end
  end

  return {
    target = target,
    slotCount = slotCount,
    status = statusRect,
    menu = menuRect,
    joystickHost = joystickRect,
    hotbar = hotbarRect,
    actions = actionsRect,
    drawerHandle = rect(rightEdge - target, drawerY, target, target),
    actionButtons = actionButtons,
    hotbarSlots = hotbarSlots
  }
end

local function applyRect(widget, geometry)
  if widget then
    widget:setRect(geometry)
  end
end

local function applyComputedLayout(layout)
  if not hud or hud:isDestroyed() then
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

  visible = visible == true and gameActive
  if hud:isVisible() ~= visible then
    hud:setVisible(visible)
  end
  if visible then
    hud:raise()
  end
  return true
end

local function acquireGameplayForeground()
  local mobileUi = modules.client_mobileui
  local _, owner = mobileUi.getForeground()
  if owner ~= nil then
    return owner == foregroundOwner
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
    releaseGameplayForeground()
  end
end

local function onGameStart()
  if gameActive then
    setControlsVisible(true)
    return
  end

  gameActive = true
  applyProfile(modules.client_mobileui.getProfile())
  acquireGameplayForeground()
  setControlsVisible(true)
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
    local layout = computeLayout(profile)
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

  local standard = computeLayout(profiles[1])
  profiles[1].handedness = 'mirrored'
  local mirrored = computeLayout(profiles[1])
  assert(mirrored.joystickHost.x > standard.joystickHost.x,
    'mirrored joystick must use right zone')
  assert(mirrored.actions.x < standard.actions.x,
    'mirrored actions must use left zone')
  assert(not intersects(mirrored.joystickHost, mirrored.hotbar),
    'mirrored joystick must not intersect hotbar')
  assert(not intersects(mirrored.actions, mirrored.hotbar),
    'mirrored actions must not intersect hotbar')

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
end
