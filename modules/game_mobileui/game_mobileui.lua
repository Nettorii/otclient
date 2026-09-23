local hud
local status
local menu
local joystickHost
local hotbar
local actions
local drawerHandle
local statusAdapter
local actionAdapter
local hotbarAdapter
local chatAdapter
local drawerHost
local placeholderUnregisters = {}
local drawerViewUnregisters = {}
local unregisterChatHandler
local unsubscribeProfile
local layoutEvent
local windowCallbacks
local gameActive = false
local controlsFit = false
local controlsSuppressed = false
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
  if profile.margin and profile.gap then
    return profile.margin, profile.gap
  end
  if profile.controlClass == 'tablet' or profile.class == 'tablet' then
    return 16, 8
  end
  if profile.controlClass == 'comfortable' or
      profile.class == 'comfortable' then
    return 12, 8
  end
  return 4, 4
end

local function applyOverlayProfile(profile)
  local mobileUi = modules.client_mobileui
  if not mobileUi or type(mobileUi.applyOverlayTree) ~= 'function' then
    return
  end
  mobileUi.applyOverlayTree(hud, profile)
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
    math.min(280, math.floor(usableWidth * 0.52)))
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

local function actionsAreActive()
  if not gameActive or not controlsFit or not hud or
      hud:isDestroyed() or not hud:isVisible() then
    return false
  end
  local state, owner = modules.client_mobileui.getForeground()
  return state == 'gameplay' and owner == foregroundOwner
end

local function synchronizeActions()
  if actionAdapter then
    actionAdapter:updateEnabled()
  end
end

local function synchronizeHotbar()
  if hotbarAdapter then
    hotbarAdapter:updateEnabled()
  end
end

local function synchronizeInputTargets()
  local enabled = actionsAreActive()
  if menu then
    menu:setEnabled(enabled)
  end
  if drawerHandle then
    drawerHandle:setEnabled(
      enabled and drawerHost ~= nil and drawerHost:hasViews())
  end
end

local function cancelOwnedGestures()
  local gameInterface = modules.game_interface
  local gameMap = gameInterface and gameInterface.getMapPanel and
    gameInterface.getMapPanel()
  if gameMap and gameMap.cancelPendingRelease then
    gameMap:cancelPendingRelease()
  end
  local joystick = modules.game_joystick
  if joystick and joystick.cancelGesture then
    joystick.cancelGesture()
  end
  if actionAdapter and actionAdapter.cancelGestures then
    actionAdapter:cancelGestures()
  end
  if hotbarAdapter and hotbarAdapter.cancelGestures then
    hotbarAdapter:cancelGestures()
  end
  local shortcuts = modules.game_shortcuts
  if shortcuts and shortcuts.resetShortcuts then
    shortcuts.resetShortcuts()
  end
end

local function configureInputTarget(widget)
  widget.onMousePress = function(_, _, mouseButton)
    return mouseButton == (MouseLeftButton or 1) or
      mouseButton == (MouseRightButton or 2)
  end
  widget.onMouseMove = function()
    return true
  end
  widget.onMouseRelease = function(_, _, mouseButton)
    return mouseButton == (MouseLeftButton or 1) or
      mouseButton == (MouseRightButton or 2)
  end
end

local function configureDrawerHandle(widget)
  widget.onMousePress = function(_, _, mouseButton)
    return mouseButton ~= (MouseLeftButton or 1)
  end
  widget.onMouseMove = function()
    return true
  end
  widget.onMouseRelease = function(target, position, mouseButton)
    if mouseButton ~= (MouseLeftButton or 1) then
      return true
    end
    return UIButton.onMouseRelease(target, position, mouseButton)
  end
  widget.onClick = function()
    return actionAdapter and actionAdapter:toggleDrawer() or false
  end
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
  synchronizeActions()
  synchronizeHotbar()
  synchronizeInputTargets()
end

function applyProfile(profile)
  if not hud or hud:isDestroyed() then
    return false
  end

  cancelOwnedGestures()
  if hotbarAdapter then
    hotbarAdapter:applyProfile(profile)
  end
  applyOverlayProfile(profile)
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

  visible = visible == true and gameActive and controlsFit and
    not controlsSuppressed
  if not visible then
    cancelOwnedGestures()
  end
  hud:setEnabled(visible)
  if hud:isVisible() ~= visible then
    hud:setVisible(visible)
  end
  synchronizeJoystick()
  synchronizeActions()
  synchronizeHotbar()
  synchronizeInputTargets()
  return true
end

local function hideGameplayControls()
  controlsSuppressed = true
  setControlsVisible(false)
end

local function showGameplayControls()
  controlsSuppressed = false
  if gameActive then
    setControlsVisible(true)
  end
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
  cancelOwnedGestures()
  if not gameActive then
    synchronizeJoystick()
    synchronizeActions()
    synchronizeHotbar()
    synchronizeInputTargets()
    releaseGameplayForeground()
    return
  end
  controlsSuppressed = false
  setControlsVisible(true)
  synchronizeJoystick()
  synchronizeActions()
  synchronizeHotbar()
  synchronizeInputTargets()
  raiseGameplayHud()
end

function foregroundOwner:onForegroundLost()
  cancelOwnedGestures()
  synchronizeJoystick()
  synchronizeActions()
  synchronizeHotbar()
  synchronizeInputTargets()
end

local function onGameStart()
  cancelOwnedGestures()
  if gameActive then
    setControlsVisible(true)
    return
  end

  gameActive = true
  controlsSuppressed = false
  if statusAdapter then
    statusAdapter:onGameStart()
  end
  if actionAdapter then
    actionAdapter:onGameStart()
  end
  if hotbarAdapter then
    hotbarAdapter:onGameStart()
  end
  applyProfile(modules.client_mobileui.getProfile())
  local acquiredForeground = acquireGameplayForeground()
  setControlsVisible(true)
  if acquiredForeground then
    raiseGameplayHud()
  end
end

local function onGameEnd()
  cancelOwnedGestures()
  if chatAdapter then
    chatAdapter:onGameEnd()
  end
  controlsSuppressed = false
  if drawerHost then
    drawerHost:close()
  end
  if statusAdapter then
    statusAdapter:onGameEnd()
  end
  if actionAdapter then
    actionAdapter:onGameEnd()
  end
  if hotbarAdapter then
    hotbarAdapter:onGameEnd()
  end
  if not gameActive then
    return
  end

  gameActive = false
  setControlsVisible(false)
  releaseGameplayForeground()
end

function attackNearest()
  return actionAdapter and actionAdapter:attackNearest() or false
end

function interact()
  return actionAdapter and actionAdapter:interact() or false
end

function toggleChat()
  if chatAdapter then
    return chatAdapter:toggle()
  end
  return false
end

function openChat()
  return chatAdapter and chatAdapter:openChat() or false
end

function closeChat()
  return chatAdapter and chatAdapter:close() or false
end

function isChatOpen()
  return chatAdapter and chatAdapter:isChatOpen() or false
end

function toggleDrawer()
  return actionAdapter and actionAdapter:toggleDrawer() or false
end

function registerChatHandler(handler)
  if not actionAdapter then
    return false
  end
  return actionAdapter:registerChatHandler(handler)
end

function registerDrawerHandler(handler)
  if not actionAdapter then
    return false
  end
  return actionAdapter:registerDrawerHandler(handler)
end

function registerDrawerView(id, descriptor)
  if not drawerHost then
    return false
  end
  return drawerHost:register(id, descriptor)
end

function bindDrawerGestureWidget(widget)
  return drawerHost and drawerHost:bindGestureWidget(widget) or false
end

function openDrawer(id)
  return drawerHost and drawerHost:open(id) or false
end

function closeDrawer()
  return drawerHost and drawerHost:close() or false
end

function getOpenDrawerId()
  return drawerHost and drawerHost:getOpenId() or nil
end

local function registerPlaceholderDrawerViews()
  local views = {
    { id = 'inventory', title = 'Inventory' },
    { id = 'character', title = 'Character' },
    { id = 'minimap', title = 'Minimap' },
    { id = 'battle', title = 'Battle' },
    { id = 'vip', title = 'VIP' },
    { id = 'settings', title = 'Settings' }
  }

  for _, view in ipairs(views) do
    local viewId = view.id
    local viewTitle = view.title
    local content
    local unregister = registerDrawerView(viewId, {
      title = viewTitle,
      icon = '',
      create = function(parent)
        content = g_ui.createWidget('Panel', parent)
        content:setWidth(math.max(0, parent:getWidth()))
        content:setHeight(96)
        local label = g_ui.createWidget('Label', content)
        label:setText(viewTitle)
        label:setColor('#dbe6ee')
        label:setTextAlign(AlignCenter)
        label:setRect({
          x = 0,
          y = 0,
          width = math.max(0, parent:getWidth()),
          height = 96
        })
        label:setPhantom(true)
        return content
      end,
      onShow = function()
      end,
      onHide = function()
      end,
      destroy = function()
        if content and not content:isDestroyed() then
          content:destroy()
        end
        content = nil
      end
    })
    if type(unregister) == 'function' then
      placeholderUnregisters[viewId] = unregister
    end
  end
end

local function replacePlaceholderDrawerView(id, descriptor)
  local unregisterPlaceholder = placeholderUnregisters[id]
  if unregisterPlaceholder then
    placeholderUnregisters[id] = nil
    unregisterPlaceholder()
  end
  local unregister = registerDrawerView(id, descriptor)
  if type(unregister) ~= 'function' then
    return false
  end
  drawerViewUnregisters[id] = unregister
  return true
end

function runSelfTests()
  MobileDrawer.runSelfTests()

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

  for _, keyboardProfile in ipairs({
    {
      usableWidth = 390, usableHeight = 326,
      safe = { left = 0, top = 47, right = 0, bottom = 34 },
      keyboardHeight = 253
    },
    {
      usableWidth = 393, usableHeight = 295,
      safe = { left = 0, top = 24, right = 0, bottom = 24 },
      keyboardHeight = 249
    },
    {
      usableWidth = 1024, usableHeight = 491,
      safe = { left = 20, top = 24, right = 20, bottom = 20 },
      keyboardHeight = 233
    }
  }) do
    local geometry = MobileChat.computeGeometry(keyboardProfile)
    assert(geometry and geometry.headerHeight >= 48 and
      geometry.footerHeight >= 48,
      'mobile chat controls must remain touch sized')
    assert(geometry.x >= keyboardProfile.safe.left and
      geometry.y >= keyboardProfile.safe.top and
      geometry.x + geometry.width <=
        keyboardProfile.safe.left + keyboardProfile.usableWidth and
      geometry.y + geometry.height <=
        keyboardProfile.safe.top + keyboardProfile.usableHeight,
      'mobile chat must remain inside keyboard-safe usable rect')
  end

  g_logger.info('[mobile-ui-test] gameplay-layout PASS')
end

function init()
  local mobileUi = modules.client_mobileui
  if not g_platform.isMobile() or not mobileUi.isV2Enabled() then
    return
  end

  g_ui.importStyle('styles.otui')
  g_ui.importStyle('drawer.otui')
  g_ui.importStyle('chat.otui')
  g_ui.importStyle('views/inventory.otui')
  g_ui.importStyle('views/container.otui')
  g_ui.importStyle('views/character.otui')
  g_ui.importStyle('views/minimap.otui')
  g_ui.importStyle('views/battle.otui')
  g_ui.importStyle('views/vip.otui')
  g_ui.importStyle('views/settings.otui')
  hud = g_ui.displayUI('game_mobileui')
  status = hud:getChildById('status')
  menu = hud:getChildById('menu')
  joystickHost = hud:getChildById('joystickHost')
  hotbar = hud:getChildById('hotbar')
  actions = hud:getChildById('actions')
  drawerHandle = hud:getChildById('drawerHandle')
  configureInputTarget(menu)

  if MobileStatus then
    statusAdapter = MobileStatus.create()
    statusAdapter:bind(status)
  end
  if MobileActions then
    actionAdapter = MobileActions.create({
      isActive = actionsAreActive
    })
    actionAdapter:bind(actions)
  end
  if MobileHotbar then
    hotbarAdapter = MobileHotbar.create({
      isActive = actionsAreActive
    })
    hotbarAdapter:bind(hotbar)
  end
  if MobileChat then
    chatAdapter = MobileChat.create({
      cancelGestures = cancelOwnedGestures,
      hideControls = hideGameplayControls,
      showControls = showGameplayControls,
      gameActive = function() return gameActive end,
      getHotbarPage = function()
        return hotbarAdapter and hotbarAdapter:getPage() or nil
      end,
      setHotbarPage = function(page)
        if hotbarAdapter then
          hotbarAdapter:_setPage(page)
        end
      end,
      focusMap = function()
        local map = modules.game_interface.getMapPanel()
        if map then
          map:focus()
        end
      end
    })
    unregisterChatHandler = actionAdapter:registerChatHandler(function()
      return chatAdapter:toggle()
    end)
  end

  drawerHost = MobileDrawer.create({
    cancelGestures = cancelOwnedGestures,
    registerActionHandler = function(handler)
      return actionAdapter:registerDrawerHandler(handler)
    end,
    onAvailabilityChange = synchronizeInputTargets
  })
  configureDrawerHandle(drawerHandle)
  registerPlaceholderDrawerViews()
  if MobileInventory then
    replacePlaceholderDrawerView('inventory',
      MobileInventory.createDescriptor())
  end
  if MobileCharacter then
    replacePlaceholderDrawerView('character',
      MobileCharacter.createDescriptor())
  end
  if MobileMinimapDrawer then
    replacePlaceholderDrawerView('minimap',
      MobileMinimapDrawer.createDescriptor())
  end
  if MobileBattle then
    replacePlaceholderDrawerView('battle',
      MobileBattle.createDescriptor())
  end
  if MobileVip then
    replacePlaceholderDrawerView('vip',
      MobileVip.createDescriptor())
  end
  if MobileSettings then
    replacePlaceholderDrawerView('settings',
      MobileSettings.createDescriptor())
  end

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
  if g_window then
    windowCallbacks = {
      onFocusChange = function(focused)
        if focused == false then
          cancelOwnedGestures()
        end
      end
    }
    connect(g_window, windowCallbacks)
  end

  if g_game.isOnline() then
    onGameStart()
  end
end

function terminate()
  if not hud then
    return
  end

  if drawerHost then
    drawerHost:terminate()
    drawerHost = nil
  end
  placeholderUnregisters = {}
  drawerViewUnregisters = {}

  disconnect(g_game, {
    onGameStart = onGameStart,
    onGameEnd = onGameEnd
  })
  if windowCallbacks then
    disconnect(g_window, windowCallbacks)
    windowCallbacks = nil
  end
  if unsubscribeProfile then
    unsubscribeProfile()
    unsubscribeProfile = nil
  end
  removeEvent(layoutEvent)
  layoutEvent = nil
  onGameEnd()
  if unregisterChatHandler then
    unregisterChatHandler()
    unregisterChatHandler = nil
  end
  if chatAdapter then
    chatAdapter:terminate()
    chatAdapter = nil
  end
  if statusAdapter then
    statusAdapter:terminate()
    statusAdapter = nil
  end
  if actionAdapter then
    actionAdapter:terminate()
    actionAdapter = nil
  end
  if hotbarAdapter then
    hotbarAdapter:terminate()
    hotbarAdapter = nil
  end
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
  controlsSuppressed = false
end
