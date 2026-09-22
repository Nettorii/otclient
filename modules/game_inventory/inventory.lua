local iconTopMenu = nil

local inventoryShrink = false

local pvpModeRadioGroup = nil 
local monkMirrorItem = nil
local inventoryObservers = {}
local nextInventoryObserverId = 0
local inventoryRevision = 0
local inventoryDispatching = false
local pendingInventoryChange = nil
local inventoryNotificationsMuted = false
local inventoryAvailable = g_game.isOnline() == true

local function inventorySlotSnapshot(player, slot)
    return {
        slot = slot,
        item = player and player:getInventoryItem(slot) or nil
    }
end

local function cloneInventorySnapshot(snapshot)
    local copy = {
        available = snapshot.available,
        capacity = snapshot.capacity,
        totalCapacity = snapshot.totalCapacity,
        soul = snapshot.soul,
        fightMode = snapshot.fightMode,
        chaseMode = snapshot.chaseMode,
        safeFight = snapshot.safeFight,
        pvpMode = snapshot.pvpMode,
        pvpModeAvailable = snapshot.pvpModeAvailable,
        purseAvailable = snapshot.purseAvailable,
        revision = snapshot.revision,
        slots = {}
    }
    for index, slot in ipairs(snapshot.slots) do
        copy.slots[index] = {
            slot = slot.slot,
            item = slot.item
        }
    end
    return copy
end

function getInventorySnapshot()
    local player = g_game.getLocalPlayer()
    local available = inventoryAvailable and g_game.isOnline() and player ~= nil
    local snapshot = {
        available = available,
        capacity = available and player:getFreeCapacity() or 0,
        totalCapacity = available and player:getTotalCapacity() or 0,
        soul = available and player:getSoul() or 0,
        fightMode = available and g_game.getFightMode() or nil,
        chaseMode = available and g_game.getChaseMode() or nil,
        safeFight = available and g_game.isSafeFight() or false,
        pvpMode = available and g_game.getFeature(GamePVPMode) and
            g_game.getPVPMode() or nil,
        pvpModeAvailable = available and g_game.getFeature(GamePVPMode),
        purseAvailable = available and g_game.getFeature(GamePurseSlot),
        revision = inventoryRevision,
        slots = {}
    }
    for slot = InventorySlotFirst, InventorySlotPurse do
        snapshot.slots[#snapshot.slots + 1] =
            inventorySlotSnapshot(available and player or nil, slot)
    end
    return snapshot
end

function subscribeInventory(callback)
    assert(type(callback) == 'function',
        'inventory callback must be a function')
    nextInventoryObserverId = nextInventoryObserverId + 1
    local observerId = nextInventoryObserverId
    inventoryObservers[observerId] = callback
    local subscribed = true
    return function()
        if not subscribed then
            return
        end
        subscribed = false
        inventoryObservers[observerId] = nil
    end
end

local function notifyInventory(changeType, slot)
    if inventoryNotificationsMuted then
        return false
    end
    inventoryRevision = inventoryRevision + 1
    pendingInventoryChange = {
        type = changeType,
        slot = slot,
        revision = inventoryRevision
    }
    if inventoryDispatching then
        return true
    end

    inventoryDispatching = true
    local ok, dispatchError = pcall(function()
        while pendingInventoryChange do
            local change = pendingInventoryChange
            pendingInventoryChange = nil
            local snapshot = getInventorySnapshot()
            local observers = {}
            for observerId, callback in pairs(inventoryObservers) do
                observers[#observers + 1] = {
                    id = observerId,
                    callback = callback
                }
            end
            table.sort(observers, function(left, right)
                return left.id < right.id
            end)
            for _, observer in ipairs(observers) do
                if inventoryObservers[observer.id] == observer.callback then
                    observer.callback(cloneInventorySnapshot(snapshot), {
                        type = change.type,
                        slot = change.slot,
                        revision = change.revision
                    })
                end
                if inventoryRevision ~= change.revision then
                    break
                end
            end
        end
    end)
    inventoryDispatching = false
    pendingInventoryChange = nil
    if not ok then
        error(dispatchError, 0)
    end
    return true
end

local function inventoryCommandsAvailable()
    return getInventorySnapshot().available
end

function setInventoryFightMode(mode)
    if not inventoryCommandsAvailable() or
        (mode ~= FightOffensive and mode ~= FightBalanced and
            mode ~= FightDefensive) then
        return false
    end
    g_game.setFightMode(mode)
    return true
end

function setInventoryChaseMode(mode)
    if not inventoryCommandsAvailable() or
        (mode ~= DontChase and mode ~= ChaseOpponent) then
        return false
    end
    g_game.setChaseMode(mode)
    return true
end

function setInventorySafeFight(enabled)
    if not inventoryCommandsAvailable() or type(enabled) ~= 'boolean' then
        return false
    end
    g_game.setSafeFight(enabled)
    return true
end

function setInventoryPVPMode(mode)
    if not inventoryCommandsAvailable() or
        not g_game.getFeature(GamePVPMode) or
        (mode ~= PVPWhiteDove and mode ~= PVPWhiteHand and
            mode ~= PVPYellowHand and mode ~= PVPRedFist) then
        return false
    end
    g_game.setPVPMode(mode)
    return true
end

local function getInventoryUi()
    if inventoryShrink then
        return inventoryController.ui.offPanel
    end

    return inventoryController.ui.onPanel
end

local getSlotPanelBySlot = {
    [InventorySlotHead] = function(ui) return ui.helmet, ui.helmet.helmet end,
    [InventorySlotNeck] = function(ui) return ui.amulet, ui.amulet.amulet end,
    [InventorySlotBack] = function(ui) return ui.backpack, ui.backpack.backpack end,
    [InventorySlotBody] = function(ui) return ui.armor, ui.armor.armor end,
    [InventorySlotRight] = function(ui) return ui.shield, ui.shield.shield end,
    [InventorySlotLeft] = function(ui) return ui.sword, ui.sword.sword end,
    [InventorySlotLeg] = function(ui) return ui.legs, ui.legs.legs end,
    [InventorySlotFeet] = function(ui) return ui.boots, ui.boots.boots end,
    [InventorySlotFinger] = function(ui) return ui.ring, ui.ring.ring end,
    [InventorySlotAmmo] = function(ui) return ui.tools, ui.tools.tools end
}

local function isPlayerMonk()
    local player = g_game.getLocalPlayer()
    if not player then
        return false
    end
    return player:isMonk()
end

local function updateMonkMirrorItem(leftItem)
    if not g_game.getFeature(GameVocationMonk) then
        return
    end
    if inventoryShrink then
        return
    end

    local ui = getInventoryUi()
    if not ui or not ui.shield or not ui.shield.item then
        return
    end

    local shieldSlot = ui.shield
    local shieldItemWidget = shieldSlot.item

    if not isPlayerMonk() then
        if monkMirrorItem then
            monkMirrorItem = nil
        end
        return
    end

    local player = g_game.getLocalPlayer()
    local realShieldItem = player and player:getInventoryItem(InventorySlotRight)

    if realShieldItem then
        monkMirrorItem = nil
        return
    end

    if leftItem then
        monkMirrorItem = leftItem
        shieldItemWidget:setItem(leftItem)
        shieldItemWidget:setOpacity(0.5)
        shieldItemWidget:setDraggable(false)
        shieldItemWidget:setEnabled(false)
        shieldItemWidget:setFlipDirection(FlipDirection.Horizontal)
        shieldSlot.shield:setEnabled(false)
    else
        monkMirrorItem = nil
        shieldItemWidget:setItem(nil)
        shieldItemWidget:setOpacity(1.0)
        shieldItemWidget:setDraggable(true)
        shieldItemWidget:setEnabled(true)
        shieldItemWidget:setFlipDirection(FlipDirection.None)
        shieldSlot.shield:setEnabled(true)
        if shieldItemWidget.tier then
            shieldItemWidget.tier:setVisible(false)
        end
    end
end


local function walkEvent()
    if modules.client_options.getOption('autoChaseOverride') then
        if g_game.isAttacking() and g_game.getChaseMode() == ChaseOpponent then
            selectPosture('stand', false)
        end
    end
end

local function combatEvent()
    notifyInventory('combat')
    if g_game.getChaseMode() == ChaseOpponent then
        selectPosture('follow', true)
    else
        selectPosture('stand', true)
    end
    
    if g_game.getFightMode() == FightOffensive then
        selectCombat('attack', true)
    elseif g_game.getFightMode() == FightBalanced then
        selectCombat('balanced', true)
    elseif g_game.getFightMode() == FightDefensive then
        selectCombat('defense', true)
    end
end

local function inventoryEvent(player, slot, item, oldItem)
    notifyInventory('inventory', slot)
    if inventoryShrink then
        return
    end

    local ui = getInventoryUi()
    local getSlotInfo = getSlotPanelBySlot[slot]
    if not getSlotInfo then
        return
    end

    if slot == InventorySlotRight and isPlayerMonk() and not item and monkMirrorItem then
        return
    end

    if slot == InventorySlotRight and item then
        local slotPanel, toggler = getSlotInfo(ui)
        slotPanel.item:setOpacity(1.0)
        slotPanel.item:setDraggable(true)
        slotPanel.item:setEnabled(true)
        slotPanel.item:setFlipDirection(FlipDirection.None)
        monkMirrorItem = nil
    end

    local slotPanel, toggler = getSlotInfo(ui)

    slotPanel.item:setItem(item)
    toggler:setEnabled(not item)
    slotPanel.item:setWidth(34)
    slotPanel.item:setHeight(34)
    
    slotPanel.item:setShowDuration(g_game.getFeature(GameThingClock) and modules.client_options.getOption('showExpiryInInvetory'))
    slotPanel.item:setShowCharges(g_game.getFeature(GameThingCounter) and modules.client_options.getOption('showExpiryInInvetory'))
    ItemsDatabase.setTier(slotPanel.item, item)

    if slot == InventorySlotLeft then
        if item and modules.game_proficiency then
            g_game.sendWeaponProficiencyAction(WeaponProficiency.WEAPON_PROFICIENCY_ITEM_INFO, item:getId())
            modules.game_proficiency.updateTopBarProficiency()
        end
        updateMonkMirrorItem(item)
    end
end

local function onSoulChange(localPlayer, soul)
    notifyInventory('soul')
    local ui = getInventoryUi()
    if not localPlayer then
        return
    end
    if not soul then
        return
    end

    if ui.soulPanel and ui.soulPanel.soul then
        ui.soulPanel.soul:setText(soul)
    end

    if ui.soulAndCapacity and ui.soulAndCapacity.soul then
        ui.soulAndCapacity.soul:setText(soul)
    end
end

local function onFreeCapacityChange(player, freeCapacity)
    notifyInventory('capacity')
    if not player then
        return
    end

    if not freeCapacity then
        return
    end
    if freeCapacity > 99999 then
        freeCapacity = math.min(9999, math.floor(freeCapacity / 1000)) .. "k"
    elseif freeCapacity > 999 then
        freeCapacity = math.floor(freeCapacity)
    elseif freeCapacity > 99 then
        freeCapacity = math.floor(freeCapacity * 10) / 10
    end
    local ui = getInventoryUi()
    if ui.capacityPanel and ui.capacityPanel.capacity then
        ui.capacityPanel.capacity:setText(freeCapacity)
    end
    if ui.soulAndCapacity and ui.soulAndCapacity.capacity then
        ui.soulAndCapacity.capacity:setText(freeCapacity)
    end
end

function getIconsPanelOn()
    return inventoryController.ui.onPanel.icons
end

function getIconsPanelOff()
    return inventoryController.ui.offPanel.icons
end

local function refreshInventory_panel()
    local player = g_game.getLocalPlayer()
    if player then
        onSoulChange(player, player:getSoul())
        onFreeCapacityChange(player, player:getFreeCapacity())
    end
    if inventoryShrink then
        return
    end

    for i = InventorySlotFirst, InventorySlotPurse do
        if g_game.isOnline() then
            inventoryEvent(player, i, player:getInventoryItem(i))
        else
            inventoryEvent(player, i, nil)
        end
    end
end

local function refreshInventorySizes()
    if inventoryShrink then
        inventoryController.ui:setOn(false)
        inventoryController.ui.onPanel:hide()
        inventoryController.ui.offPanel:show()
    else
        inventoryController.ui:setOn(true)
        inventoryController.ui.onPanel:show()
        inventoryController.ui.offPanel:hide()
        refreshInventory_panel()
    end
    combatEvent()
    walkEvent()
    modules.game_mainpanel.reloadMainPanelSizes()
end

function onSetChaseMode(self, selectedChaseModeButton)
    if selectedChaseModeButton == nil then
        return
    end
    
    local buttonId = selectedChaseModeButton:getId()
    local chaseMode
    if buttonId == 'followPosture' then
        chaseMode = ChaseOpponent
    else
        chaseMode = DontChase
    end
    g_game.setChaseMode(chaseMode)
end

inventoryController = Controller:new()
inventoryController:setUI('inventory', modules.game_interface.getMainRightPanel())

function inventoryController:onInit()
    refreshInventory_panel()
    local ui = getInventoryUi()

    connect(inventoryController.ui.onPanel.pvp, {
        onCheckChange = onSetSafeFight
    })
    connect(inventoryController.ui.offPanel.pvp, {
        onCheckChange = onSetSafeFight
    })
    connect(inventoryController.ui.onPanel.expert, {
        onCheckChange = expertMode
    })
    pvpModeRadioGroup = UIRadioGroup.create()
    pvpModeRadioGroup:addWidget(inventoryController.ui.onPanel.whiteDoveBox)
    pvpModeRadioGroup:addWidget(inventoryController.ui.onPanel.whiteHandBox)
    pvpModeRadioGroup:addWidget(inventoryController.ui.onPanel.yellowHandBox)
    pvpModeRadioGroup:addWidget(inventoryController.ui.onPanel.redFistBox)
    connect(pvpModeRadioGroup, {
        onSelectionChange = onSetPVPMode
    })
end

function inventoryController:onGameStart()
    inventoryNotificationsMuted = true
    inventoryAvailable = true
    local player = g_game.getLocalPlayer()
    if player then
        local char = g_game.getCharacterName()
        local lastCombatControls = g_settings.getNode('LastCombatControls')
        if not table.empty(lastCombatControls) then
            if lastCombatControls[char] then
                g_game.setFightMode(lastCombatControls[char].fightMode)
                g_game.setChaseMode(lastCombatControls[char].chaseMode)
                g_game.setSafeFight(lastCombatControls[char].safeFight)
                if lastCombatControls[char].pvpMode then
                    g_game.setPVPMode(lastCombatControls[char].pvpMode)
                end
            end
        end
    end
    inventoryController:registerEvents(LocalPlayer, {
        onInventoryChange = inventoryEvent,
        onSoulChange = onSoulChange,
        onFreeCapacityChange = onFreeCapacityChange
    }):execute()

    inventoryController:registerEvents(g_game, {
        onWalk = walkEvent,
        onAutoWalk = walkEvent,
        onFightModeChange = combatEvent,
        onChaseModeChange = combatEvent,
        onSafeFightChange = combatEvent,
        onPVPModeChange = combatEvent
    }):execute()

    inventoryShrink = g_settings.getBoolean('mainpanel_shrink_inventory')
    refreshInventorySizes()
    refreshInventory_panel()

    local elements = {
        {inventoryController.ui.offPanel.blessings, inventoryController.ui.onPanel.blessings},
        {inventoryController.ui.offPanel.expert, inventoryController.ui.onPanel.expert},
        {inventoryController.ui.onPanel.whiteDoveBox},
        {inventoryController.ui.onPanel.whiteHandBox},
        {inventoryController.ui.onPanel.yellowHandBox},
        {inventoryController.ui.onPanel.redFistBox}
    }
    
    local showBlessings = g_game.getClientVersion() >= 1000
    local showPVPMode = g_game.getFeature(GamePVPMode)
    
    for i, elementGroup in ipairs(elements) do
        local show = (i == 1 and showBlessings) or (i > 1 and showPVPMode)
        for _, element in ipairs(elementGroup) do
            if show then
                element:show()
            else
                element:hide()
            end
        end
    end
    inventoryController.ui.onPanel.purseButton:setVisible(g_game.getFeature(GamePurseSlot))

    if isPlayerMonk() and player then
        local leftItem = player:getInventoryItem(InventorySlotLeft)
        if leftItem then
            updateMonkMirrorItem(leftItem)
        end
    end
    inventoryNotificationsMuted = false
    notifyInventory('start')
end

function inventoryController:onGameEnd()
    inventoryAvailable = false
    notifyInventory('end')
    monkMirrorItem = nil

    local lastCombatControls = g_settings.getNode('LastCombatControls')
    if not lastCombatControls then
        lastCombatControls = {}
    end
    local player = g_game.getLocalPlayer()
    if player then
        local char = g_game.getCharacterName()
        lastCombatControls[char] = {
            fightMode = g_game.getFightMode(),
            chaseMode = g_game.getChaseMode(),
            safeFight = g_game.isSafeFight()
        }
        if g_game.getFeature(GamePVPMode) then
            lastCombatControls[char].pvpMode = g_game.getPVPMode()
        end
        g_settings.setNode('LastCombatControls', lastCombatControls)
    end
    toggleAdventurerStyle(false)
end

function inventoryController:onTerminate()
    inventoryObservers = {}
    pendingInventoryChange = nil
    inventoryDispatching = false
    if iconTopMenu then
        iconTopMenu:destroy()
        iconTopMenu = nil
    end
    if pvpModeRadioGroup then
        disconnect(pvpModeRadioGroup, {
            onSelectionChange = onSetPVPMode
        })
        pvpModeRadioGroup:destroy()
        pvpModeRadioGroup = nil
    end
end

function onSetSafeFight(self, checked)
    if not checked then
        inventoryController.ui.onPanel.pvp:setChecked(false)
        inventoryController.ui.offPanel.pvp:setChecked(false)
      else
        inventoryController.ui.onPanel.pvp:setChecked(true)  
        inventoryController.ui.offPanel.pvp:setChecked(true)  
      end
    g_game.setSafeFight(not checked)
    if not checked then
        g_game.cancelAttack()
    end
end

function selectPosture(key, ignoreUpdate)
    local ui = getInventoryUi()
    if key == 'stand' then
        ui.standPosture:setEnabled(false)
        ui.followPosture:setEnabled(true)
        if not ignoreUpdate then
            g_game.setChaseMode(DontChase)
        end
    elseif key == 'follow' then
        ui.standPosture:setEnabled(true)
        ui.followPosture:setEnabled(false)
        if not ignoreUpdate then
            g_game.setChaseMode(ChaseOpponent)
        end
    end
end

function selectCombat(combat, ignoreUpdate)
    local ui = getInventoryUi()
    if combat == 'attack' then
        ui.attack:setEnabled(false)
        ui.balanced:setEnabled(true)
        ui.defense:setEnabled(true)
        if not ignoreUpdate then
            g_game.setFightMode(FightOffensive)
        end
    elseif combat == 'balanced' then
        ui.attack:setEnabled(true)
        ui.balanced:setEnabled(false)
        ui.defense:setEnabled(true)
        if not ignoreUpdate then
            g_game.setFightMode(FightBalanced)
        end
    elseif combat == 'defense' then
        ui.attack:setEnabled(true)
        ui.balanced:setEnabled(true)
        ui.defense:setEnabled(false)
        if not ignoreUpdate then
            g_game.setFightMode(FightDefensive)
        end
    end
end

function expertMode(self, checked)
    local ui = getInventoryUi()

    ui.whiteDoveBox:setVisible(checked)
    ui.whiteHandBox:setVisible(checked)
    ui.yellowHandBox:setVisible(checked)
    ui.redFistBox:setVisible(checked)
end

function onSetPVPMode(self, selectedPVPButton)
    if selectedPVPButton == nil then
        return
    end

    local buttonId = selectedPVPButton:getId()
    local pvpMode = PVPWhiteDove

    if buttonId == 'whiteDoveBox' then
        pvpMode = PVPWhiteDove
    elseif buttonId == 'whiteHandBox' then
        pvpMode = PVPWhiteHand
    elseif buttonId == 'yellowHandBox' then
        pvpMode = PVPYellowHand
    elseif buttonId == 'redFistBox' then
        pvpMode = PVPRedFist
    end
    g_game.setPVPMode(pvpMode)
end

function changeInventorySize()
    inventoryShrink = not inventoryShrink
    g_settings.set('mainpanel_shrink_inventory', inventoryShrink)
    refreshInventorySizes()
    modules.game_mainpanel.reloadMainPanelSizes()
    local player = g_game.getLocalPlayer()
    if player and g_game.isOnline() then
        onFreeCapacityChange(player, player:getFreeCapacity())
        onSoulChange(player, player:getSoul())
    end
end

function getSlot5()
    return inventoryController.ui.onPanel.shield
end

function reloadInventory()
    
    for slot, getSlotInfo in pairs(getSlotPanelBySlot) do
        local ui = getInventoryUi()
        local slotPanel, toggler = getSlotInfo(ui)
        if slotPanel then
            local player = g_game.getLocalPlayer()
            if player then
                inventoryEvent(player, slot, player:getInventoryItem(slot))
            end
        end
    end
end

function extendedView(extendedView)
    if extendedView then
        if not iconTopMenu then
            iconTopMenu = modules.client_topmenu.addTopRightToggleButton('inventory', tr('Show inventory'),
                '/images/topbuttons/inventory', toggle)
            iconTopMenu:setOn(inventoryController.ui:isVisible())
            inventoryController.ui:setBorderColor('black')
            inventoryController.ui:setBorderWidth(2)
        end
    else
        if iconTopMenu then
            iconTopMenu:destroy()
            iconTopMenu = nil
        end
        inventoryController.ui:setBorderColor('alpha')
        inventoryController.ui:setBorderWidth(0)
        local mainRightPanel = modules.game_interface.getMainRightPanel()
        if not mainRightPanel:hasChild(inventoryController.ui) then
            mainRightPanel:insertChild(3, inventoryController.ui)
        end
        inventoryController.ui:show()
    end
    inventoryController.ui.moveOnlyToMain = not extendedView

end

function toggle()
    if iconTopMenu:isOn() then
        inventoryController.ui:hide()
        iconTopMenu:setOn(false)
    else
        inventoryController.ui:show()
        iconTopMenu:setOn(true)
    end
end

function toggleAdventurerStyle(hasBlessing)
    for slot, getSlotInfo in pairs(getSlotPanelBySlot) do
        local ui = getInventoryUi()
        local slotPanel, toggler = getSlotInfo(ui)
        if slotPanel then
            slotPanel:setOn(hasBlessing)
        end
    end
end

function getButtonBlessings()
    return getInventoryUi().blessings
end
