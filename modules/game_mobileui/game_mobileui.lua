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
local reconnectAdapter
local placeholderUnregisters = {}
local drawerViewUnregisters = {}
local unregisterChatHandler
local unsubscribeProfile
local unsubscribePortrait
local layoutEvent
local windowCallbacks
local gameActive = false
local controlsFit = false
local controlsSuppressed = false
local initialized = false
local terminating = false
local lastProfileKey
local fallbackModal
local foregroundOwner = {}
local initializeGameplay
local zoomOutButton
local zoomInButton
local currentLayout
local lastShellDockMessage

local SHELL_DOCK_BUTTONS = 3

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

  local topRowLeft = drawerRect.x + drawerRect.width + gap
  local topRowRight = menuRect.x - gap
  local topRowBottom = menuRect.y + menuRect.height + gap
  local bottomRowLeft = {
    x = leftEdge, right = hotbarRect.x - gap
  }
  local bottomRowRight = {
    x = hotbarRect.x + hotbarRect.width + gap, right = rightEdge
  }
  local actionsZone = mirrored and bottomRowLeft or bottomRowRight
  local joystickZone = mirrored and bottomRowRight or bottomRowLeft

  -- The browser shell's keyboard, fullscreen and music buttons are fixed
  -- 48 px DOM buttons; the dock is where the shell may place them.
  local dockWidth = SHELL_DOCK_BUTTONS * 48 + (SHELL_DOCK_BUTTONS - 1) * gap
  local shellDock
  if topRowRight - topRowLeft >= dockWidth then
    shellDock = rect(topRowRight - dockWidth, safeTop + margin, dockWidth, target)
  elseif joystickZone.right - joystickZone.x >= dockWidth then
    shellDock = rect(mirrored and joystickZone.right - dockWidth or joystickZone.x,
      hotbarRect.y, dockWidth, target)
  end

  local zoomWidth = target * 2 + gap
  local zoomOutRect
  local zoomInRect
  local actionsTop = controlBottom - actionSize
  local outerColumn = mirrored and leftEdge or rightEdge - target
  if actionsZone.right - actionsZone.x >= zoomWidth then
    local zoomX = mirrored and actionsZone.x or actionsZone.right - zoomWidth
    zoomOutRect = rect(zoomX, hotbarRect.y, target, target)
    zoomInRect = rect(zoomX + target + gap, hotbarRect.y, target, target)
  elseif actionsTop - gap - topRowBottom >= target * 2 + gap then
    zoomInRect = rect(outerColumn, actionsTop - gap - target * 2 - gap,
      target, target)
    zoomOutRect = rect(outerColumn, actionsTop - gap - target, target, target)
  else
    local zoomRight = shellDock and shellDock.y == menuRect.y and
      shellDock.x - gap or topRowRight
    if zoomRight - topRowLeft >= zoomWidth then
      zoomOutRect = rect(zoomRight - zoomWidth, menuRect.y, target, target)
      zoomInRect = rect(zoomRight - target, menuRect.y, target, target)
    end
  end

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
    zoomOut = zoomOutRect,
    zoomIn = zoomInRect,
    shellDock = shellDock,
    actionButtons = actionButtons,
    hotbarSlots = hotbarSlots
  }
end

function computeGameplayLayout(profile)
  return computeLayout(profile)
end

local function applyRect(widget, geometry)
  if widget then
    widget:setRect(geometry)
  end
end

local function applyJoystickAppearance(joystick)
  local pad = joystick.getPanel and joystick.getPanel()
  if not pad or pad:isDestroyed() or pad.mobileV2Appearance then
    return
  end
  pad.mobileV2Appearance = true
  pad:setBackgroundColor('alpha')
  pad:setImageSource('/modules/game_mobileui/images/joystick_base')
  pad:setImageRect({ x = 0, y = 0, width = 0, height = 0 })
  local pointer = pad:getChildById('pointer')
  if pointer then
    pointer:setImageSource('/modules/game_mobileui/images/joystick_thumb')
  end
end

local function synchronizeJoystick(bounds)
  local joystick = modules.game_joystick
  if not joystick or not joystick.setEnabled then
    return
  end

  applyJoystickAppearance(joystick)
  if bounds and joystick.setBounds then
    joystick.setEnabled(false)
    joystick.setBounds(bounds)
    local pad = joystick.getPanel and joystick.getPanel()
    local pointer = pad and pad:getChildById('pointer')
    if pointer then
      local thumb = math.floor(math.min(bounds.width, bounds.height) * 0.42)
      pointer:setSize({ width = thumb, height = thumb })
    end
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

local function gameMapPanel()
  local gameInterface = modules.game_interface
  return gameInterface and gameInterface.getMapPanel and
    gameInterface.getMapPanel() or nil
end

local function synchronizeZoomTargets(enabled)
  local map = gameMapPanel()
  local zoom = map and map.getZoom and map:getZoom()
  if zoomInButton then
    zoomInButton:setEnabled(enabled and zoom ~= nil and
      zoom > map:getMaxZoomIn())
  end
  if zoomOutButton then
    zoomOutButton:setEnabled(enabled and zoom ~= nil and
      zoom < map:getMaxZoomOut())
  end
end

local function publishShellDock()
  local message
  local layout = currentLayout
  if actionsAreActive() and layout and layout.controlsFit and
      layout.shellDock then
    local dock = layout.shellDock
    message = string.format('[mobile-shell] dock %d %d %d %d',
      dock.x, dock.y, dock.width, dock.height)
  elseif gameActive and hud and not hud:isDestroyed() then
    message = '[mobile-shell] dock hidden'
  else
    message = '[mobile-shell] dock reset'
  end
  if message ~= lastShellDockMessage then
    lastShellDockMessage = message
    g_logger.info(message)
  end
end

local function synchronizeInputTargets()
  local enabled = actionsAreActive()
  if menu then
    menu:setEnabled(enabled and drawerHost ~= nil and drawerHost:hasViews())
  end
  if drawerHandle then
    drawerHandle:setEnabled(
      enabled and drawerHost ~= nil and drawerHost:hasViews())
  end
  synchronizeZoomTargets(enabled)
  publishShellDock()
end

-- direction > 0 zooms in (fewer tiles), direction < 0 zooms out.
function zoomMap(direction)
  if not actionsAreActive() then
    return false
  end
  local map = gameMapPanel()
  if not map then
    return false
  end
  local changed
  if direction > 0 then
    changed = map:zoomIn()
  elseif direction < 0 then
    changed = map:zoomOut()
  end
  synchronizeZoomTargets(true)
  return changed == true
end

function getMapZoom()
  local map = gameMapPanel()
  return map and map:getZoom() or nil
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

function cancelInput()
  cancelOwnedGestures()
end

local function profileKey(profile)
  profile = profile or {}
  local safe = profile.safe or {}
  return table.concat({
    tostring(profile.class),
    tostring(profile.controlClass),
    tostring(profile.controlPreset),
    tostring(profile.usableWidth),
    tostring(profile.usableHeight),
    tostring(safe.left),
    tostring(safe.top),
    tostring(safe.right),
    tostring(safe.bottom),
    tostring(profile.keyboardHeight),
    tostring(profile.handedness),
    tostring(profile.overlayOpacity)
  }, '|')
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
  currentLayout = layout
  for _, entry in ipairs({
    { widget = zoomOutButton, geometry = layout.zoomOut },
    { widget = zoomInButton, geometry = layout.zoomIn }
  }) do
    if entry.widget then
      if entry.geometry then
        applyRect(entry.widget, entry.geometry)
      end
      entry.widget:setVisible(entry.geometry ~= nil)
    end
  end

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

function applyProfile(profile, immediate)
  if not hud or hud:isDestroyed() then
    return false
  end

  local mobileUi = modules.client_mobileui
  if mobileUi.isPortraitProfile(profile) or
      mobileUi.isPortraitGateActive() then
    cancelOwnedGestures()
    removeEvent(layoutEvent)
    layoutEvent = nil
    controlsSuppressed = true
    setControlsVisible(false)
    return false
  end

  local nextProfileKey = profileKey(profile)
  if nextProfileKey == lastProfileKey then
    return true
  end
  lastProfileKey = nextProfileKey
  cancelOwnedGestures()
  if hotbarAdapter then
    hotbarAdapter:applyProfile(profile)
  end
  applyOverlayProfile(profile)
  local layout = computeLayout(profile)
  removeEvent(layoutEvent)
  layoutEvent = nil
  if immediate then
    applyComputedLayout(layout)
  else
    layoutEvent = addEvent(function()
      layoutEvent = nil
      applyComputedLayout(layout)
    end)
  end
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
  local enterGame = modules.client_entergame
  local characterList = enterGame and enterGame.CharacterList
  if characterList and characterList.isIntentionalExitPending and
      characterList.isIntentionalExitPending() then
    setControlsVisible(false)
    return
  end
  if reconnectAdapter then
    reconnectAdapter:onGameStart()
  end
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

function openMenu()
  if not actionsAreActive() or not drawerHost then
    return false
  end
  return drawerHost:open('settings') or false
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

function showReconnecting(reason)
  if not reconnectAdapter then
    return false
  end
  cancelOwnedGestures()
  if reconnectAdapter:isOpen() then
    return reconnectAdapter:updateReason(reason)
  end
  return reconnectAdapter:show(reason)
end

function closeReconnecting()
  return reconnectAdapter and reconnectAdapter:close() or false
end

function isReconnecting()
  return reconnectAdapter and reconnectAdapter:isOpen() or false
end

local function profileDescription(profile)
  profile = profile or {}
  return string.format('%s/%sx%s',
    tostring(profile.controlClass or profile.class or 'compact'),
    tostring(profile.usableWidth or 0),
    tostring(profile.usableHeight or 0))
end

local function showViewCreationFallback(viewId, errorMessage, profile)
  local mobileUi = modules.client_mobileui
  return mobileUi.showMobileViewError({
    module = 'game_mobileui',
    view = viewId,
    profile = profile,
    state = 'modal',
    title = tr('Unable to open'),
    message = tr(
      'This view could not be opened. Reload the client to continue safely.'),
    actions = {
      {
        text = tr('Reload'),
        callback = function()
          if g_app.restart then
            g_app.restart()
          end
          return true
        end
      }
    }
  }, errorMessage)
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
  MobileReconnecting.runSelfTests()

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
    for _, optional in ipairs({ 'zoomOut', 'zoomIn', 'shellDock' }) do
      if layout[optional] then
        direct[#direct + 1] = layout[optional]
      end
    end
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
    assert(layout.zoomIn and layout.zoomOut and layout.shellDock,
      'gameplay zoom controls and shell dock must fit supported profiles')
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

initializeGameplay = function(initialProfile, atomicProfile)
  local mobileUi = modules.client_mobileui
  local profile = initialProfile or mobileUi.getProfile()
  if initialized or terminating or
      mobileUi.isPortraitProfile(profile) then
    return false
  end

  local partialHud
  local shell = mobileUi.safeCreateMobileView({
    module = 'game_mobileui',
    view = 'hud',
    profile = profile,
    state = 'modal',
    title = tr('Unable to start mobile controls'),
    message = tr(
      'The gameplay controls could not be loaded. Reload the client to continue safely.'),
    actions = {
      {
        text = tr('Reload'),
        callback = function()
          if g_app.restart then
            g_app.restart()
          end
          return true
        end
      }
    },
    create = function()
      partialHud = g_ui.displayUI('game_mobileui')
      local created = {
        hud = partialHud,
        status = partialHud:getChildById('status'),
        menu = partialHud:getChildById('menu'),
        joystickHost = partialHud:getChildById('joystickHost'),
        hotbar = partialHud:getChildById('hotbar'),
        actions = partialHud:getChildById('actions'),
        drawerHandle = partialHud:getChildById('drawerHandle'),
        zoomOut = partialHud:getChildById('zoomOut'),
        zoomIn = partialHud:getChildById('zoomIn')
      }
      assert(created.status and created.menu and created.joystickHost and
        created.hotbar and created.actions and created.drawerHandle and
        created.zoomOut and created.zoomIn,
        'mobile HUD is incomplete')
      return created
    end,
    cleanup = function()
      if partialHud and not partialHud:isDestroyed() then
        partialHud:destroy()
      end
    end
  })
  if not shell then
    return false
  end
  hud = shell.hud
  status = shell.status
  menu = shell.menu
  joystickHost = shell.joystickHost
  hotbar = shell.hotbar
  actions = shell.actions
  drawerHandle = shell.drawerHandle
  zoomOutButton = shell.zoomOut
  zoomInButton = shell.zoomIn
  configureInputTarget(menu)
  menu.onClick = function()
    return openMenu()
  end
  configureInputTarget(zoomOutButton)
  zoomOutButton.onClick = function()
    return zoomMap(-1)
  end
  configureInputTarget(zoomInButton)
  zoomInButton.onClick = function()
    return zoomMap(1)
  end

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
      end,
      onError = function(errorMessage)
        showViewCreationFallback(
          'chat', errorMessage, mobileUi.getProfile())
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
    onAvailabilityChange = synchronizeInputTargets,
    onViewCreateError = showViewCreationFallback,
    onShellCreateError = showViewCreationFallback
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
  initialized = true
  applyProfile(initialProfile or mobileUi.getProfile(), atomicProfile)
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
  return true
end

local function suspendForPortrait()
  cancelOwnedGestures()
  removeEvent(layoutEvent)
  layoutEvent = nil
  lastProfileKey = nil
  controlsSuppressed = true
  if hud and not hud:isDestroyed() then
    setControlsVisible(false)
  end
end

local function onPortraitGate(blocked, profile)
  if blocked then
    suspendForPortrait()
    return
  end
  if not initialized then
    initializeGameplay(profile, true)
  end

  applyProfile(profile, true)
  local foregroundState = modules.client_mobileui.getForeground()
  if foregroundState ~= 'gameplay' then
    controlsSuppressed = true
    setControlsVisible(false)
    return
  end

  controlsSuppressed = false
  if gameActive then
    acquireGameplayForeground()
    setControlsVisible(true)
    raiseGameplayHud()
  end
end

function init()
  local mobileUi = modules.client_mobileui
  if not g_platform.isMobile() or not mobileUi.isV2Enabled() then
    return
  end

  g_ui.importStyle('styles.otui')
  g_ui.importStyle('drawer.otui')
  g_ui.importStyle('chat.otui')
  g_ui.importStyle('reconnecting.otui')
  g_ui.importStyle('views/inventory.otui')
  g_ui.importStyle('views/container.otui')
  g_ui.importStyle('views/character.otui')
  g_ui.importStyle('views/minimap.otui')
  g_ui.importStyle('views/battle.otui')
  g_ui.importStyle('views/vip.otui')
  g_ui.importStyle('views/settings.otui')

  reconnectAdapter = MobileReconnecting.create({
    cancelGestures = cancelOwnedGestures,
    onRetry = function(generation)
      local enterGame = modules.client_entergame
      local characterList = enterGame and enterGame.CharacterList
      return characterList and characterList.retryCurrentCharacter and
        characterList.retryCurrentCharacter(generation) or false
    end,
    onLogout = function(generation)
      local enterGame = modules.client_entergame
      local characterList = enterGame and enterGame.CharacterList
      return characterList and characterList.cancelReconnect and
        characterList.cancelReconnect(generation) or false
    end
  })
  unsubscribePortrait = mobileUi.subscribePortraitGate(onPortraitGate)
  local profile = mobileUi.getProfile()
  if mobileUi.isPortraitGateActive() or mobileUi.isPortraitProfile(profile) then
    suspendForPortrait()
    return
  end
  initializeGameplay(profile)
end

function terminate()
  if terminating then
    return
  end
  terminating = true
  if unsubscribePortrait then
    unsubscribePortrait()
    unsubscribePortrait = nil
  end
  if reconnectAdapter then
    reconnectAdapter:terminate()
    reconnectAdapter = nil
  end
  if fallbackModal and fallbackModal:isOpen() then
    fallbackModal:close()
  end
  fallbackModal = nil
  if not hud then
    initialized = false
    terminating = false
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
  zoomOutButton = nil
  zoomInButton = nil
  currentLayout = nil
  gameActive = false
  controlsFit = false
  controlsSuppressed = false
  initialized = false
  lastProfileKey = nil
  publishShellDock()
  terminating = false
end
