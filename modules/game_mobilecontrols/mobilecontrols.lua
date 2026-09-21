--[[
  Touch controls for phones and tablets. Active only when g_platform.isMobile()
  (Android build, or the browser client in mobile mode - see
  canary/docker/webclient/site-src/index.html, which also forwards the flag
  through /webclient.lua).

  What it adds on top of the stock mobile modules (game_joystick, game_shortcuts):
    * HUD scale chosen from the screen size (phones 1.0, tablets 1.25/1.5) instead
      of the fixed 1.5 that only fits Android's physical-pixel windows;
    * a bigger joystick;
    * an action cluster (bottom right, above the look/use/attack/follow modes):
        attack  - attack the nearest monster, tap again to cycle to the next one
        stop    - stop attacking/following and stop walking
        loot    - quick-loot all corpses around you
        chat    - show/hide the chat panel and focus its input line
        menu    - the client options (Ctrl+O equivalent)
    * a hotbar mirroring the first slots of action bar 1 (bigger buttons; assign
      spells/items to action bar 1 on the desktop or through its right-click menu).
]]

local controls -- root widget (mobilecontrols.otui)
local hotbar
local cluster
local refreshEvent
local scaleEvent
local targetCycle = {} -- creature ids we already offered in this cycle
local HOTBAR_SLOTS = 8
local layoutApplied = false
local clampedWindows = setmetatable({}, { __mode = 'k' }) -- windows already fitted to the screen

MobileControls = {}

-- Widget geometry is in UI units: the window size divided by the HUD scale
-- (a 1080x810 iPad at scale 1.5 is a 720x540 UI). g_window reports the raw size.
local function uiSize()
  local root = g_ui.getRootWidget()
  if root and root:getWidth() > 0 then
    return root:getWidth(), root:getHeight()
  end
  local scale = g_window.getDisplayDensity()
  if not scale or scale <= 0 then
    scale = 1
  end
  return math.floor(g_window.getWidth() / scale), math.floor(g_window.getHeight() / scale)
end

-- ---------------------------------------------------------------- HUD scale
-- g_window size is in CSS pixels in the browser. A 6" phone is ~860x390 of them:
-- the stock 1.5 HUD scale leaves ~570x260 for the whole UI (dialogs do not fit).
local function chooseScale()
  local h = g_window.getHeight()
  if h < 500 then
    return 1.0
  elseif h < 800 then
    return 1.25
  end
  return 1.5
end

-- Fixed-size, picture-based windows (the Newhaven vocation tutorial: 957x453,
-- more than twice a phone's height) cannot be clamped like the others: while
-- one is shown the HUD scale is lowered so it fits, and restored when it closes.
local FIT_BY_SCALE = { tutorialSelectionWindow = true }
local scaleFitWidget = nil

function MobileControls.applyScale()
  removeEvent(scaleEvent)
  scaleEvent = nil
  if scaleFitWidget then
    return -- an oversized window dictates the scale for now
  end
  local wanted = chooseScale()
  if math.abs(g_window.getDisplayDensity() - wanted) > 0.01 then
    g_app.setHUDScale(wanted)
    g_logger.info(string.format('[mobilecontrols] HUD scale %.2f for %dx%d', wanted, g_window.getWidth(), g_window.getHeight()))
    -- the UI size changed: windows fitted to the old size need fitting again
    clampedWindows = setmetatable({}, { __mode = 'k' })
  end
end

local function scheduleScale(delay)
  removeEvent(scaleEvent)
  -- client_options applies its own hudScale 250 ms after init; run after it
  scaleEvent = scheduleEvent(MobileControls.applyScale, delay or 600)
end

-- ---------------------------------------------------------------- small screens
-- Many stock windows (character list 745x430, options, ...) are taller than a
-- phone in landscape (~360 px). Clamp any top-level window to the screen when
-- it appears; scrollable content keeps working, only the frame shrinks.
local function fitOversizedByScale(root)
  local shown
  for id in pairs(FIT_BY_SCALE) do
    -- html windows may sit inside a wrapper widget under the root
    local w = root:getChildById(id)
    if not w then
      for _, child in ipairs(root:getChildren()) do
        w = child:getChildById(id)
        if w then
          break
        end
      end
    end
    if w and w:isVisible() then
      shown = w
      break
    end
  end
  if shown then
    local winW, winH = g_window.getWidth(), g_window.getHeight()
    -- the tutorial's crest/banner hang 33 px above the frame: leave headroom
    local wanted = math.min(winW / (shown:getWidth() + 12), winH / (shown:getHeight() + 44), chooseScale())
    wanted = math.max(0.5, math.floor(wanted * 20) / 20)
    if math.abs(g_window.getDisplayDensity() - wanted) > 0.01 then
      removeEvent(scaleEvent)
      scaleEvent = nil
      g_app.setHUDScale(wanted)
      clampedWindows = setmetatable({}, { __mode = 'k' })
      g_logger.info(string.format('[mobilecontrols] HUD scale %.2f to fit %s (%dx%d)', wanted, shown:getId(), shown:getWidth(), shown:getHeight()))
    end
    scaleFitWidget = shown
  elseif scaleFitWidget then
    scaleFitWidget = nil
    MobileControls.applyScale()
  end
end

local function clampWindows()
  local root = g_ui.getRootWidget()
  if not root then
    return
  end
  fitOversizedByScale(root)
  local uiW, uiH = uiSize()
  local maxW, maxH = uiW - 6, uiH - 6
  -- first-run language picker: its flag grid (128 px rows) starts below the
  -- screen centre; on a 340 px screen the second row is cut off
  local locales = root:getChildById('localesWindow')
  if locales and locales:isVisible() and not clampedWindows[locales] then
    local label = locales:getChildByIndex(1)
    local grid = locales:getChildById('localesPanel')
    if label and grid then
      -- one row when it fits (5 flags = 608 px wide): two 128 px rows do not fit
      -- in a 340 px tall phone screen; if even one row is too wide, start at the top
      local oneRow = false
      local layout = grid:getLayout()
      local n = grid:getChildCount()
      if layout and n > 0 and layout.getCellSize then
        local cell = layout:getCellSize()
        for _, spacing in ipairs({ layout:getCellSpacing(), 12, 4 }) do
          local width = cell.width * n + spacing * (n - 1)
          if width <= uiW - 16 then
            layout:setCellSpacing(spacing)
            grid:setWidth(width)
            oneRow = true
            break
          end
        end
      end
      if oneRow then
        label:setMarginTop(-100)
        grid:setMarginTop(50)
      else
        label:setMarginTop(-math.floor(uiH / 2) + 14)
        grid:setMarginTop(6)
      end
      clampedWindows[locales] = true
    end
  end
  for _, w in ipairs(root:getChildren()) do
    local style = w:getStyle()
    local class = style and style.__class or ''
    if w:isVisible() and w ~= scaleFitWidget and w ~= (scaleFitWidget and scaleFitWidget:getParent()) and (class == 'UIWindow' or class == 'UIMainWindow' or (w:getStyleName() or ''):find('Window')) then
      local changed = false
      if w:getHeight() > maxH then
        w:setHeight(maxH)
        changed = true
      end
      if w:getWidth() > maxW then
        w:setWidth(maxW)
        changed = true
      end
      if changed or w:getY() < 0 or w:getY() + w:getHeight() > uiH then
        w:centerIn('parent')
        clampedWindows[w] = true
      end
    end
  end
end

-- Bottom status messages ("You are full", "There is nothing to attack") would
-- sit under the hotbar: lift them above it.
local function liftStatusMessages()
  local tm = modules.game_textmessage
  local panel = tm and tm.messagesPanel
  local label = panel and panel:recursiveGetChildById('statusLabel')
  if label then
    label:setMarginBottom(64)
  end
end

-- ---------------------------------------------------------------- joystick
local function enlargeJoystick()
  if not modules.game_joystick or not modules.game_joystick.getPanel then
    return
  end
  local pad = modules.game_joystick.getPanel()
  if not pad then
    return
  end
  local _, h = uiSize()
  local size = h < 400 and 190 or 230
  pad:setSize({ width = size + 25, height = size })
  pad:setMarginBottom(10)
  pad:setMarginLeft(6)
  local pointer = pad:getChildById('pointer')
  if pointer then
    pointer:setSize({ width = math.floor(size / 3), height = math.floor(size / 3) })
  end
end

-- ---------------------------------------------------------------- targeting
local function hostile(creature, player)
  if not creature or creature == player or creature:isDead() then
    return false
  end
  if not creature:isMonster() then
    return false
  end
  -- summons of the player and friendly kingdom creatures (adventurers, pets)
  local name = creature:getName() or ''
  if name:find('^Adventurer ') or name:find('^Companion ') or name:find('^Pet ') or name == 'Town Guard' then
    return false
  end
  return true
end

function MobileControls.attackNearest()
  local player = g_game.getLocalPlayer()
  if not player then
    return
  end
  local pos = player:getPosition()
  local candidates = {}
  for _, creature in ipairs(g_map.getSpectators(pos, false)) do
    if hostile(creature, player) and creature:getPosition().z == pos.z then
      local cp = creature:getPosition()
      local dist = math.max(math.abs(cp.x - pos.x), math.abs(cp.y - pos.y))
      if dist <= 7 then
        table.insert(candidates, { creature = creature, dist = dist })
      end
    end
  end
  if #candidates == 0 then
    targetCycle = {}
    if g_game.getAttackingCreature() then
      g_game.cancelAttackAndFollow()
    end
    modules.game_textmessage.displayGameMessage(tr('There is nothing to attack nearby.'))
    return
  end
  table.sort(candidates, function(a, b)
    if a.dist ~= b.dist then
      return a.dist < b.dist
    end
    return a.creature:getId() < b.creature:getId()
  end)
  local current = g_game.getAttackingCreature()
  local currentId = current and current:getId() or nil
  -- cycle: skip the current target and the ones already offered this round
  local pick
  for _, c in ipairs(candidates) do
    local id = c.creature:getId()
    if id ~= currentId and not targetCycle[id] then
      pick = c.creature
      break
    end
  end
  if not pick then
    targetCycle = {}
    pick = candidates[1].creature
    if pick:getId() == currentId and #candidates > 1 then
      pick = candidates[2].creature
    end
  end
  targetCycle[pick:getId()] = true
  g_game.attack(pick)
end

function MobileControls.stopAll()
  targetCycle = {}
  g_game.cancelAttackAndFollow()
  g_game.stop()
end

function MobileControls.lootNearby()
  if g_game.getFeature(GameThingQuickLoot) then
    g_game.sendQuickLoot(2)
  else
    modules.game_textmessage.displayGameMessage(tr('Quick loot is not available.'))
  end
end

-- Chat panel shown/hidden with our button; when shown, chat mode is switched on
-- (letters go to the chat line, not to walking) and the input line gets focus so
-- the device keyboard has somewhere to type. The console's own floating
-- "chat"/"hello" buttons (created by extendedViewHide) are removed: ours replace them.
local chatWasEnabled = nil

function MobileControls.isChatOpen()
  local bottom = modules.game_interface.getBottomPanel()
  return bottom ~= nil and bottom:isVisible()
end

function MobileControls.setChatOpen(open)
  local bottom = modules.game_interface.getBottomPanel()
  local console = modules.game_console
  if not bottom or not console then
    return
  end
  if open then
    if console.extendedViewHide then
      console.extendedViewHide(false)
    else
      bottom:setVisible(true)
    end
    bottom:raise()
    controls:raise()
    -- chat mode on: letters go to the chat line (no WASD walking on a phone anyway)
    if console.switchChat then
      console.switchChat(true)
    end
    -- focus once the panel is really shown (show() may be deferred a frame)
    scheduleEvent(function()
      local line = console.getConsole and console.getConsole()
      if line and MobileControls.isChatOpen() then
        -- focus() only marks the widget in its parent; a click focuses the whole
        -- chain up to the root, which is what key input follows
        local w = line
        while w and w:getParent() do
          w:getParent():focusChild(w, ActiveFocusReason)
          w = w:getParent()
        end
      end
    end, 150)
    -- the hotbar and the look/use/attack modes sit where the chat input line is
    hotbar:setVisible(false)
    if modules.game_shortcuts and modules.game_shortcuts.getPanel then
      modules.game_shortcuts.getPanel():setVisible(false)
    end
  else
    if console.extendedViewHide then
      console.extendedViewHide(true)
    else
      bottom:setVisible(false)
    end
    if console.destroyButtonChat then
      console.destroyButtonChat()
    end
    chatWasEnabled = nil
    hotbar:setVisible(true)
    if modules.game_shortcuts and modules.game_shortcuts.getPanel and not bagOpen then
      modules.game_shortcuts.getPanel():setVisible(true)
    end
    modules.game_interface.getRootPanel():focus()
  end
end

function MobileControls.toggleChat()
  MobileControls.setChatOpen(not MobileControls.isChatOpen())
end

-- Phone layout: full-screen map, no side panels, chat hidden; the right panel
-- (inventory, minimap, skills...) opens with the "bag" button and the controls
-- move out of its way while it is open.
local bagOpen = false

-- both right-hand panels: gameMainRightPanel holds minimap/health/inventory in
-- this client, gameRightPanel the extra windows (skills, battle, vip...)
local function rightPanels()
  local iface = modules.game_interface
  local out = {}
  for _, getter in ipairs({ 'getMainRightPanel', 'getRightPanel' }) do
    local p = iface[getter] and iface[getter]()
    if p then
      table.insert(out, p)
    end
  end
  return out
end

-- Hiding the side panels breaks their vertical-box layout (they come back with
-- height 1), so they are parked off-screen to the right instead and pulled back
-- with the "bag" button.
local PARK_MARGIN = -400

function MobileControls.setBagOpen(open)
  local panels = rightPanels()
  if #panels == 0 then
    return
  end
  bagOpen = open
  local width = 0
  for _, p in ipairs(panels) do
    p:setMarginRight(open and 0 or PARK_MARGIN)
    if open then
      p:raise()
      width = math.max(width, p:getWidth())
    end
  end
  if open then
    cluster:setMarginRight(width + 6)
    if modules.game_shortcuts and modules.game_shortcuts.getPanel then
      modules.game_shortcuts.getPanel():setVisible(false)
    end
  else
    cluster:setMarginRight(6)
    if modules.game_shortcuts and modules.game_shortcuts.getPanel and not MobileControls.isChatOpen() then
      modules.game_shortcuts.getPanel():setVisible(true)
    end
  end
  controls:raise()
end

function MobileControls.toggleBag()
  MobileControls.setBagOpen(not bagOpen)
end

local function applyPhoneLayout()
  local iface = modules.game_interface
  local left = iface.getLeftPanel()
  if left then
    left:setVisible(false)
  end
  local leftExtra = iface.getLeftExtraPanel and iface.getLeftExtraPanel()
  if leftExtra then
    leftExtra:setVisible(false)
  end
  -- the small stock action bars (34 px slots) are replaced by the hotbar below
  for _, getter in ipairs({ 'getBottomActionPanel', 'getLeftActionPanel', 'getRightActionPanel' }) do
    local panel = iface[getter] and iface[getter]()
    if panel then
      panel:setVisible(false)
    end
  end
  -- the draggable splitter between map and chat draws a line across the map
  local root = iface.getRootPanel()
  local splitter = root and root:getChildById('bottomSplitter')
  if splitter then
    splitter:setVisible(false)
  end
  -- the spell-group cooldown strip above the chat costs 30 of a phone's ~340 px;
  -- the hotbar slots show cooldowns anyway (setting untouched, tablets keep it)
  local _, uiH = uiSize()
  if uiH < 400 and modules.game_cooldown and modules.game_cooldown.setSpellGroupCooldownsVisible then
    modules.game_cooldown.setSpellGroupCooldownsVisible(false)
  end
  MobileControls.setBagOpen(false)
  MobileControls.setChatOpen(false)
  liftStatusMessages()
end

-- game_interface re-shows the side panels on some events (view mode, option
-- changes); keep the phone layout in force.
local function enforceLayout()
  local iface = modules.game_interface
  for _, p in ipairs(rightPanels()) do
    local parked = p:getMarginRight() < 0
    if parked == bagOpen then
      p:setMarginRight(bagOpen and 0 or PARK_MARGIN)
    end
  end
  local left = iface.getLeftPanel()
  if left and left:isVisible() then
    left:setVisible(false)
  end
  local actionPanel = iface.getBottomActionPanel and iface.getBottomActionPanel()
  if actionPanel and actionPanel:isVisible() then
    actionPanel:setVisible(false)
  end
end

function MobileControls.openMenu()
  if modules.client_options and modules.client_options.toggle then
    modules.client_options.toggle()
  end
end

-- ---------------------------------------------------------------- hotbar
local function sourceButton(i)
  local bottom = modules.game_interface.getBottomPanel()
  local root = bottom and bottom:recursiveGetChildById('1.' .. i)
  if root and root:getChildById('item') then
    return root
  end
  -- action bars may live in the root panel when the bottom panel is hidden
  root = modules.game_interface.getRootPanel():recursiveGetChildById('1.' .. i)
  if root and root:getChildById('item') then
    return root
  end
  return nil
end

local function mirrorSlot(slot, src)
  local item = slot:getChildById('item')
  local text = slot:getChildById('text')
  local cooldown = slot:getChildById('cooldown')
  if not src then
    item:setItemId(0)
    text:setImageSource('')
    text:setText('')
    cooldown:setVisible(false)
    slot:setOpacity(0.35)
    slot.src = nil
    return false
  end
  slot.src = src
  local srcItem = src:getChildById('item')
  local itemId = srcItem and srcItem:getItemId() or 0
  local used = false
  if itemId > 100 then
    if item:getItemId() ~= itemId then
      item:setItemId(itemId)
    end
    text:setImageSource('')
    text:setText('')
    used = true
  else
    item:setItemId(0)
    local srcText = srcItem and srcItem:getChildById('text')
    local source = srcText and srcText:getImageSource() or ''
    if source ~= '' then
      text:setImageSource(source)
      text:setImageClip(srcText:getImageClip())
      text:setText('')
      used = true
    else
      text:setImageSource('')
      local param = src:getChildById('parameterText')
      local label = (srcText and srcText:getText() or '')
      if label == '' and param then
        label = param:getText() or ''
      end
      text:setText(label)
      used = label ~= ''
    end
  end
  local srcCooldown = src:getChildById('cooldown')
  if srcCooldown and srcCooldown:isVisible() and srcCooldown:getPercent() < 100 then
    cooldown:setVisible(true)
    cooldown:setPercent(srcCooldown:getPercent())
    cooldown:setText(srcCooldown:getText())
  else
    cooldown:setVisible(false)
  end
  slot:setOpacity(used and 0.9 or 0.35)
  return used
end

local function refreshHotbar()
  if not hotbar or not g_game.isOnline() then
    return
  end
  if layoutApplied then
    enforceLayout()
  end
  local anyUsed = false
  for i = 1, HOTBAR_SLOTS do
    local slot = hotbar:getChildById('slot' .. i)
    if slot then
      anyUsed = mirrorSlot(slot, sourceButton(i)) or anyUsed
    end
  end
  if not MobileControls.isChatOpen() then
    hotbar:setVisible(true)
  end
end

-- A finger held on a button for >200 ms is released as a right click by the browser
-- platform; buttons do not consume right clicks, so it would fall through to the map
-- (tile context menu) or a window underneath. Swallow them on our touch buttons.
local function swallowRightClicks(button)
  button.onMousePress = function(w, pos, mouseButton)
    return mouseButton == MouseRightButton
  end
  button.onMouseRelease = function(w, pos, mouseButton)
    if mouseButton == MouseRightButton then
      return true
    end
    return UIButton.onMouseRelease(w, pos, mouseButton)
  end
end

local function buildHotbar()
  hotbar:destroyChildren()
  for i = 1, HOTBAR_SLOTS do
    local slot = g_ui.createWidget('MobileHotbarSlot', hotbar)
    slot:setId('slot' .. i)
    swallowRightClicks(slot)
    slot.onClick = function()
      if slot.src and modules.game_actionbar and modules.game_actionbar.onExecuteAction then
        modules.game_actionbar.onExecuteAction(slot.src, false)
      end
    end
  end
  local size = 50
  hotbar:setWidth(HOTBAR_SLOTS * size + (HOTBAR_SLOTS - 1) * 4)
end

-- ---------------------------------------------------------------- lifecycle
local layoutEvent
local windowClampEvent

local function onGameStart()
  enlargeJoystick()
  scheduleScale(800)
  buildHotbar()
  cluster:show()
  cluster:raise()
  hotbar:raise()
  removeEvent(refreshEvent)
  refreshEvent = cycleEvent(refreshHotbar, 400)
  controls:raise()
  -- game_interface finishes its own view-mode setup in the same tick; ours after it
  removeEvent(layoutEvent)
  layoutApplied = false
  layoutEvent = scheduleEvent(function()
    applyPhoneLayout()
    layoutApplied = true
  end, 400)
end

local function onGameEnd()
  removeEvent(refreshEvent)
  refreshEvent = nil
  removeEvent(layoutEvent)
  layoutEvent = nil
  layoutApplied = false
  if cluster then
    cluster:hide()
  end
  if hotbar then
    hotbar:hide()
  end
end

local function onResize()
  scheduleScale(300)
  enlargeJoystick()
end

function init()
  if not g_platform.isMobile() or modules.client_mobileui.isV2Enabled() then
    return
  end
  controls = g_ui.displayUI('mobilecontrols')
  hotbar = controls:getChildById('hotbar')
  cluster = controls:getChildById('cluster')

  cluster:getChildById('attack').onClick = MobileControls.attackNearest
  cluster:getChildById('stop').onClick = MobileControls.stopAll
  cluster:getChildById('loot').onClick = MobileControls.lootNearby
  cluster:getChildById('chat').onClick = MobileControls.toggleChat
  cluster:getChildById('menu').onClick = MobileControls.openMenu
  cluster:getChildById('bag').onClick = MobileControls.toggleBag
  for _, id in ipairs({ 'attack', 'stop', 'loot', 'chat', 'menu', 'bag' }) do
    swallowRightClicks(cluster:getChildById(id))
  end

  connect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
  windowClampEvent = cycleEvent(clampWindows, 300)
  -- the root widget follows the window: geometry changes = resize / rotation
  controls.onGeometryChange = onResize
  scheduleScale(600)
  if g_game.isOnline() then
    onGameStart()
  end
end

function terminate()
  if not controls then
    return
  end
  disconnect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
  removeEvent(refreshEvent)
  removeEvent(scaleEvent)
  removeEvent(layoutEvent)
  removeEvent(windowClampEvent)
  controls:destroy()
  controls = nil
  hotbar = nil
  cluster = nil
  MobileControls = nil
end
