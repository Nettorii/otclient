MobileHotbar = {}

local Adapter = {}
Adapter.__index = Adapter

local PAGE_SETTING = 'mobile-hotbar-page'
local SOURCE_BAR = 1

local function validPage(value)
  value = tonumber(value)
  if value == 1 or value == 2 then
    return value
  end
  return nil
end

local function emptySnapshot()
  return {
    assigned = false,
    itemId = 0,
    imageSource = '',
    imageClip = '',
    text = '',
    cooldownPercent = 100,
    cooldownText = '',
    enabled = false
  }
end

function Adapter:_active()
  return self.isActive() == true
end

function Adapter:_readPage()
  if self.settings then
    return self.settings:getNumber(PAGE_SETTING, 1)
  end
  return g_settings.getNumber(PAGE_SETTING, 1)
end

function Adapter:_writePage(page)
  if self.settings then
    self.settings:set(PAGE_SETTING, page)
  else
    g_settings.set(PAGE_SETTING, page)
  end
end

function Adapter:getPage()
  return self.page
end

function Adapter:_sourceSlotId(visibleIndex)
  return (self.page - 1) * self.slotCount + visibleIndex
end

function Adapter:_renderSnapshot(slot, snapshot)
  snapshot = snapshot or emptySnapshot()
  local item = slot:getChildById('item')
  local text = slot:getChildById('text')
  local cooldown = slot:getChildById('cooldown')

  item:setItemId(snapshot.itemId or 0)
  local imageSource = snapshot.imageSource or ''
  text:setImageSource(imageSource)
  if imageSource ~= '' and snapshot.imageClip then
    text:setImageClip(snapshot.imageClip)
  end
  text:setText(snapshot.text or '')

  local cooldownPercent = tonumber(snapshot.cooldownPercent) or 100
  cooldown:setPercent(cooldownPercent)
  cooldown:setText(snapshot.cooldownText or '')
  cooldown:setVisible(snapshot.assigned == true and cooldownPercent < 100)

  if not snapshot.assigned then
    slot:setOpacity(0.35)
  elseif not snapshot.enabled then
    slot:setOpacity(0.55)
  else
    slot:setOpacity(0.9)
  end
  slot.snapshot = snapshot
  if not self.refreshingCooldown then
    self:_syncCooldownRefresh()
  end
end

function Adapter:_hasActiveCooldown()
  for _, slot in ipairs(self.slots) do
    local snapshot = slot.snapshot
    if snapshot and snapshot.assigned and
        (tonumber(snapshot.cooldownPercent) or 100) < 100 then
      return true
    end
  end
  return false
end

function Adapter:_cancelCooldownRefresh()
  if not self.cooldownEvent then
    return
  end
  self.cancel(self.cooldownEvent)
  self.cooldownEvent = nil
end

function Adapter:_syncCooldownRefresh()
  if not self.running or not self:_hasActiveCooldown() then
    self:_cancelCooldownRefresh()
    return
  end
  if self.cooldownEvent then
    return
  end

  self.cooldownEvent = self.schedule(function()
    self.cooldownEvent = nil
    if not self.running then
      return
    end

    self.refreshingCooldown = true
    for _, slot in ipairs(self.slots) do
      local snapshot = slot.snapshot
      if snapshot and snapshot.assigned and
          (tonumber(snapshot.cooldownPercent) or 100) < 100 then
        self:_renderSnapshot(slot, self.actionbar.getSlotSnapshot(
          SOURCE_BAR, slot.sourceSlotId))
      end
    end
    self.refreshingCooldown = false
    self:_syncCooldownRefresh()
  end, self.cooldownRefreshInterval)
end

function Adapter:_renderSlot(index)
  local slot = self.slots[index]
  if not slot then
    return
  end
  local sourceSlotId = self:_sourceSlotId(index)
  slot.sourceSlotId = sourceSlotId
  self:_renderSnapshot(
    slot, self.actionbar.getSlotSnapshot(SOURCE_BAR, sourceSlotId))
end

function Adapter:_renderPage()
  for index = 1, self.slotCount do
    self:_renderSlot(index)
  end
end

function Adapter:_setPage(page)
  page = validPage(page)
  if not page or page == self.page then
    return false
  end
  self.page = page
  self:_writePage(page)
  self:_renderPage()
  return true
end

function Adapter:_configureGesture(slot)
  slot.onMousePress = function(_, position, mouseButton)
    if mouseButton == (MouseRightButton or 2) then
      slot.mobileHotbarSuppress = true
      return true
    end
    if not self:_active() then
      slot.mobileHotbarSuppress = true
      return true
    end
    slot.mobileHotbarSuppress = false
    slot.mobileHotbarSwiped = false
    slot.mobileHotbarPressX = position and position.x or 0
    slot.mobileHotbarPressedAt = self.now()
    return false
  end

  slot.onMouseMove = function(_, position)
    local startX = slot.mobileHotbarPressX
    if not self:_active() or startX == nil or
        slot.mobileHotbarSwiped then
      return true
    end
    local delta = (position and position.x or startX) - startX
    if math.abs(delta) >= self.swipeThreshold then
      slot.mobileHotbarSuppress = true
      slot.mobileHotbarSwiped = true
      self:_setPage(delta < 0 and 2 or 1)
    end
    return true
  end

  slot.onMouseRelease = function(widget, position, mouseButton)
    if mouseButton == (MouseRightButton or 2) then
      slot.mobileHotbarSuppress = true
      return true
    end

    local startX = slot.mobileHotbarPressX
    local pressedAt = slot.mobileHotbarPressedAt
    slot.mobileHotbarPressX = nil
    slot.mobileHotbarPressedAt = nil
    if slot.mobileHotbarSwiped then
      slot.mobileHotbarSwiped = false
      slot.mobileHotbarSuppress = true
      return true
    end
    if not self:_active() or startX == nil then
      slot.mobileHotbarSuppress = true
      return true
    end

    local delta = (position and position.x or startX) - startX
    if math.abs(delta) >= self.swipeThreshold then
      slot.mobileHotbarSuppress = true
      self:_setPage(delta < 0 and 2 or 1)
      return true
    end
    if pressedAt and self.now() - pressedAt >= 200 then
      slot.mobileHotbarSuppress = true
      return true
    end
    return UIButton.onMouseRelease(widget, position, mouseButton)
  end

  slot.onClick = function()
    local suppressed = slot.mobileHotbarSuppress
    slot.mobileHotbarSuppress = false
    if suppressed or not self:_active() then
      return true
    end
    local snapshot = slot.snapshot or emptySnapshot()
    if not snapshot.assigned or not snapshot.enabled then
      return true
    end
    return self.actionbar.executeSlot(
      SOURCE_BAR, slot.sourceSlotId, false)
  end
end

function Adapter:_rebuildSlots()
  if not self.panel or self.slotCount == 0 then
    return
  end
  self:_cancelCooldownRefresh()
  self.panel:destroyChildren()
  self.slots = {}
  for index = 1, self.slotCount do
    local slot = self.createWidget('MobileHotbarSlot', self.panel)
    slot:setId('slot' .. index)
    self:_configureGesture(slot)
    self.slots[index] = slot
  end
  self:_renderPage()
  self:updateEnabled()
end

function Adapter:bind(panel)
  self.panel = panel
  if self.slotCount > 0 then
    self:_rebuildSlots()
  end
end

function Adapter:applyProfile(profile)
  local count = tonumber(profile and profile.hotbarSlots) or 6
  count = count >= 8 and 8 or 6
  if count == self.slotCount and #self.slots == count then
    self:_renderPage()
    return false
  end
  self.slotCount = count
  self:_rebuildSlots()
  return true
end

function Adapter:updateEnabled()
  local enabled = self:_active()
  if self.panel then
    self.panel:setEnabled(enabled)
  end
  for _, slot in ipairs(self.slots) do
    slot:setEnabled(enabled)
  end
end

function Adapter:onSlotChange(barId, slotId, snapshot)
  if tonumber(barId) ~= SOURCE_BAR then
    return
  end
  local first = (self.page - 1) * self.slotCount + 1
  local index = tonumber(slotId) - first + 1
  if index < 1 or index > self.slotCount then
    return
  end
  local slot = self.slots[index]
  if slot then
    self:_renderSnapshot(slot, snapshot)
  end
end

function Adapter:onGameStart()
  self:onGameEnd()
  self.running = true
  self.unsubscribe = self.actionbar.subscribeSlotChanges(
    function(barId, slotId, snapshot)
      self:onSlotChange(barId, slotId, snapshot)
    end)
  self:_renderPage()
  self:updateEnabled()
end

function Adapter:onGameEnd()
  self.running = false
  self:_cancelCooldownRefresh()
  if self.unsubscribe then
    self.unsubscribe()
    self.unsubscribe = nil
  end
  self:updateEnabled()
end

function Adapter:terminate()
  self:onGameEnd()
  self.panel = nil
  self.slots = {}
end

function MobileHotbar.create(options)
  options = options or {}
  local adapter = setmetatable({
    actionbar = options.actionbar or modules.game_actionbar,
    settings = options.settings,
    isActive = options.isActive or function() return true end,
    now = options.now or function()
      if g_clock.realMillis then
        return g_clock.realMillis()
      end
      return g_clock.millis()
    end,
    createWidget = options.createWidget or g_ui.createWidget,
    schedule = options.schedule or scheduleEvent,
    cancel = options.cancel or removeEvent,
    cooldownRefreshInterval =
      tonumber(options.cooldownRefreshInterval) or 100,
    swipeThreshold = tonumber(options.swipeThreshold) or 36,
    page = 1,
    slotCount = 0,
    slots = {},
    running = false,
    refreshingCooldown = false
  }, Adapter)

  local persisted = validPage(adapter:_readPage())
  if persisted then
    adapter.page = persisted
  else
    adapter:_writePage(1)
  end
  return adapter
end
