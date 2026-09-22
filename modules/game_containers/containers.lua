containerSettings = nil

local containerObservers = {}
local nextContainerObserverId = 0
local containerRevision = 0
local containerDispatching = false
local pendingContainerChange = nil

local function containerSnapshot(container)
    local capacity = math.max(0, tonumber(container:getCapacity()) or 0)
    local size = math.max(0, tonumber(container:getSize()) or 0)
    local firstIndex = math.max(
        0, tonumber(container:getFirstIndex()) or 0)
    local hasPages = container:hasPages() == true
    local pageCount = capacity > 0 and
        1 + math.floor(math.max(0, size - 1) / capacity) or 1
    local currentPage = capacity > 0 and
        1 + math.floor(firstIndex / capacity) or 1
    local items = {}
    for slot = 0, capacity - 1 do
        items[#items + 1] = {
            slot = slot,
            index = firstIndex + slot,
            item = container:getItem(slot),
            position = container:getSlotPosition(slot)
        }
    end
    local hasParent = container:hasParent() == true
    return {
        id = container:getId(),
        name = container:getName() or '',
        capacity = capacity,
        size = size,
        itemCount = math.max(
            0, tonumber(container:getItemsCount()) or 0),
        items = items,
        parent = hasParent,
        canGoBack = hasParent,
        page = {
            enabled = hasPages,
            firstIndex = firstIndex,
            current = currentPage,
            total = pageCount,
            canPrevious = hasPages and firstIndex > 0,
            canNext = hasPages and firstIndex + capacity < size
        }
    }
end

local function cloneContainerSnapshot(snapshot)
    local copy = {
        id = snapshot.id,
        name = snapshot.name,
        capacity = snapshot.capacity,
        size = snapshot.size,
        itemCount = snapshot.itemCount,
        parent = snapshot.parent,
        canGoBack = snapshot.canGoBack,
        page = {
            enabled = snapshot.page.enabled,
            firstIndex = snapshot.page.firstIndex,
            current = snapshot.page.current,
            total = snapshot.page.total,
            canPrevious = snapshot.page.canPrevious,
            canNext = snapshot.page.canNext
        },
        items = {}
    }
    for index, item in ipairs(snapshot.items) do
        copy.items[index] = {
            slot = item.slot,
            index = item.index,
            item = item.item,
            position = item.position
        }
    end
    return copy
end

local function cloneContainerSnapshots(snapshots)
    local copies = {}
    for index, snapshot in ipairs(snapshots) do
        copies[index] = cloneContainerSnapshot(snapshot)
    end
    copies.revision = snapshots.revision
    return copies
end

function getOpenContainerSnapshots()
    local snapshots = {}
    for _, container in pairs(g_game.getContainers()) do
        if container and
            (not container.isClosed or not container:isClosed()) then
            snapshots[#snapshots + 1] = containerSnapshot(container)
        end
    end
    table.sort(snapshots, function(left, right)
        return left.id < right.id
    end)
    snapshots.revision = containerRevision
    return snapshots
end

function subscribeContainers(callback)
    assert(type(callback) == 'function',
        'container callback must be a function')
    nextContainerObserverId = nextContainerObserverId + 1
    local observerId = nextContainerObserverId
    containerObservers[observerId] = callback
    local subscribed = true
    return function()
        if not subscribed then
            return
        end
        subscribed = false
        containerObservers[observerId] = nil
    end
end

local function notifyContainers(changeType, container, slot)
    containerRevision = containerRevision + 1
    pendingContainerChange = {
        type = changeType,
        containerId = container and container:getId() or nil,
        slot = slot,
        revision = containerRevision
    }
    if containerDispatching then
        return true
    end

    containerDispatching = true
    local ok, dispatchError = pcall(function()
        while pendingContainerChange do
            local change = pendingContainerChange
            pendingContainerChange = nil
            local snapshots = getOpenContainerSnapshots()
            local observers = {}
            for observerId, callback in pairs(containerObservers) do
                observers[#observers + 1] = {
                    id = observerId,
                    callback = callback
                }
            end
            table.sort(observers, function(left, right)
                return left.id < right.id
            end)
            for _, observer in ipairs(observers) do
                if containerObservers[observer.id] == observer.callback then
                    observer.callback(cloneContainerSnapshots(snapshots), {
                        type = change.type,
                        containerId = change.containerId,
                        slot = change.slot,
                        revision = change.revision
                    })
                end
                if containerRevision ~= change.revision then
                    break
                end
            end
        end
    end)
    containerDispatching = false
    pendingContainerChange = nil
    if not ok then
        error(dispatchError, 0)
    end
    return true
end

local function openContainerById(containerId)
    containerId = tonumber(containerId)
    if not containerId then
        return nil
    end
    return g_game.getContainer(containerId)
end

function openParentContainer(containerId)
    local container = openContainerById(containerId)
    if not container or not container:hasParent() then
        return false
    end
    g_game.openParent(container)
    return true
end

function seekContainerPage(containerId, firstIndex)
    local container = openContainerById(containerId)
    firstIndex = tonumber(firstIndex)
    if not container or not container:hasPages() or not firstIndex or
        firstIndex < 0 then
        return false
    end
    g_game.seekInContainer(container:getId(), math.floor(firstIndex))
    return true
end

function closeContainer(containerId)
    local container = openContainerById(containerId)
    if not container then
        return false
    end
    g_game.close(container)
    return true
end

-- Local addition: remember which side panel (and slot) each bag was docked in,
-- keyed per character by the bag's item id and its opening order, so that
-- bags reopened after a relog/death go back where they were instead of being
-- stacked into whichever panel has room.
local placementCounters = {}

local function placementChar()
    local char = g_game.getCharacterName()
    if not char or #char == 0 then
        return nil
    end
    return char
end

local function placementKey(container)
    local item = container:getContainerItem()
    if not item then
        return nil
    end
    -- item id + name (pet bags are all backpacks but have distinct names) +
    -- ordinal for identical bags, in opening order
    local base = string.format('%d:%s', item:getId(), container:getName() or '')
    placementCounters[base] = (placementCounters[base] or 0) + 1
    return string.format('%s#%d', base, placementCounters[base])
end

local function savedPlacements(char)
    local all = g_settings.getNode('CharContainerPanels') or {}
    return all, all[char] or {}
end

local function findSavedPanel(entry)
    if not entry or not entry.parentId then
        return nil
    end
    local root = modules.game_interface.getRootPanel()
    local panel = root and root:recursiveGetChildById(entry.parentId)
    if panel and panel:isVisible() and panel:getClassName() == 'UIMiniWindowContainer' then
        return panel
    end
    return nil
end

function rememberContainerPlacements()
    local char = placementChar()
    if not char then
        return
    end
    local all, mine = savedPlacements(char)
    for _, container in pairs(g_game.getContainers()) do
        local window = container.window
        if window and window.placementKey and not window:isDestroyed() then
            local parent = window:getParent()
            if parent and parent:getClassName() == 'UIMiniWindowContainer' then
                mine[window.placementKey] = { parentId = parent:getId(), index = parent:getChildIndex(window) }
            end
        end
    end
    all[char] = mine
    g_settings.setNode('CharContainerPanels', all)
end

local function placeContainerWindow(containerWindow, container, minContentHeight)
    containerWindow.placementKey = placementKey(container)
    local panel = modules.game_interface.findContentPanelAvailable(containerWindow, minContentHeight)
    panel:addChild(containerWindow)
end

-- Must run after containerWindow:setup(): setup() re-applies the position
-- stored under the server-assigned window id ("container3"), which differs
-- between sessions and is what used to shuffle bags around on relog.
local function applySavedPlacement(containerWindow)
    local char = placementChar()
    local key = containerWindow.placementKey
    if not char or not key then
        return
    end
    local _, mine = savedPlacements(char)
    local entry = mine[key]
    local panel = findSavedPanel(entry)
    if not panel then
        return
    end
    local current = containerWindow:getParent()
    if current == panel then
        return
    end
    if current then
        current:removeChild(containerWindow)
    end
    local index = entry.index
    if index and index >= 1 and index <= panel:getChildCount() + 1 then
        panel:insertChild(index, containerWindow)
    else
        panel:addChild(containerWindow)
    end
end

local placementEvent = nil
local function onPlacementGameStart()
    placementCounters = {}
    if placementEvent then
        removeEvent(placementEvent)
    end
    placementEvent = cycleEvent(rememberContainerPlacements, 3000)
end

local function onPlacementGameEnd()
    rememberContainerPlacements()
    if placementEvent then
        removeEvent(placementEvent)
        placementEvent = nil
    end
    placementCounters = {}
end

function init()
    g_ui.importStyle('container')

    -- Initialize container settings
    containerSettings = g_settings.getNode('containers')
    if not containerSettings then
        containerSettings = {}
        -- Set useManualSortMode as default
        containerSettings['useManualSortMode'] = 1
        -- Set default sorting mode to none
        containerSettings['currentSortMode'] = 'none'
        -- Initialize sorting options
        containerSettings['sortContainersFirst'] = 0
        containerSettings['sortNestedContainers'] = 0
        g_settings.setNode('containers', containerSettings)
    end

    -- Ensure all required settings exist
    if containerSettings['sortNestedContainers'] == nil then
        containerSettings['sortNestedContainers'] = 0
    end
    if containerSettings['sortContainersFirst'] == nil then
        containerSettings['sortContainersFirst'] = 0
    end

    connect(Container, {
        onOpen = onContainerOpen,
        onClose = onContainerClose,
        onSizeChange = onContainerChangeSize,
        onUpdateItem = onContainerUpdateItem
    })
    connect(Game, {
        onGameEnd = clean()
    })
    connect(g_game, {
        onGameStart = onPlacementGameStart,
        onGameEnd = onPlacementGameEnd
    })
    if g_game.isOnline() then
        onPlacementGameStart()
    end

    reloadContainers()
end

function terminate()
    disconnect(Container, {
        onOpen = onContainerOpen,
        onClose = onContainerClose,
        onSizeChange = onContainerChangeSize,
        onUpdateItem = onContainerUpdateItem
    })
    disconnect(Game, {
        onGameEnd = clean()
    })
    disconnect(g_game, {
        onGameStart = onPlacementGameStart,
        onGameEnd = onPlacementGameEnd
    })
    if placementEvent then
        removeEvent(placementEvent)
        placementEvent = nil
    end
    containerObservers = {}
    pendingContainerChange = nil
    containerDispatching = false
end

function reloadContainers()
    clean()
    for _, container in pairs(g_game.getContainers()) do
        onContainerOpen(container)
    end
end

function clean()
    for containerid, container in pairs(g_game.getContainers()) do
        destroy(container)
    end
end

function destroy(container)
    if container.window then
        container.window:destroy()
        container.window = nil
        container.itemsPanel = nil
    end
end

function showContainersContextMenu(widget, mousePos, mouseButton)
    local menu = g_ui.createWidget('ContainersSubMenu')
    if not menu then
        return false
    end
    menu:setGameMenu(true)
    for _, choice in ipairs(menu:getChildren()) do
        local choiceId = choice:getId()
        if choiceId and choiceId ~= 'HorizontalSeparator' then
            local widgetClass = choice:getClassName()
            local isSortingAction = choiceId:find('sortAsc') or choiceId:find('sortDesc')
            local isActionButton = isSortingAction or choiceId == 'moveToObtainContainers'
            if isActionButton then
                choice.onClick = function()
                    onContainersMenuAction(choiceId)
                    menu:destroy()
                end
                choice.onMouseRelease = function(widget, mousePos, mouseButton)
                    if mouseButton == MouseLeftButton then
                        onContainersMenuAction(choiceId)
                        menu:destroy()
                        return true
                    end
                    return false
                end
                if isSortingAction then
                    local currentSortMode = containerSettings and containerSettings['currentSortMode'] or 'none'
                    local isActive = (currentSortMode == choiceId)
                    local isManualSortEnabled = containerSettings and containerSettings['useManualSortMode'] == 1
                    if isManualSortEnabled then
                        choice:setEnabled(false)
                        choice:setColor('#808080')
                    else
                        choice:setEnabled(true)
                        if isActive then
                            choice:setColor('#ffff00')
                        else
                            choice:setColor('#ffffff')
                        end
                    end
                else
                    choice:setEnabled(true)
                    choice:setColor('#ffffff')
                end
            else
                local currentState = getContainerOptionState(choiceId)
                choice:setChecked(currentState)
                local isManualSortEnabled = containerSettings and containerSettings['useManualSortMode'] == 1
                if isManualSortEnabled and (choiceId == 'sortContainersFirst' or choiceId == 'sortNestedContainers') then
                    choice:setEnabled(false)
                    choice:setColor('#808080')
                else
                    choice:setEnabled(true)
                    choice:setColor('#ffffff')
                end
                choice.onCheckChange = function()
                    onContainersMenuAction(choiceId)
                    menu:destroy()
                end
            end
        end
    end
    local buttonPos = widget:getPosition()
    local buttonSize = widget:getSize()
    local menuWidth = menu:getWidth()
    local buttonCenterX = buttonPos.x + buttonSize.width / 2
    local buttonCenterY = buttonPos.y + buttonSize.height / 2
    local menuX = buttonCenterX - menuWidth
    local menuY = buttonCenterY
    menu:display({x = menuX, y = menuY})
    return true
end

function getContainerOptionState(optionId)
    -- Return the current state of container options
    -- These are stored in settings similar to skills module
    if not containerSettings then
        return false
    end
    
    if optionId == 'sortContainersFirst' then
        return containerSettings['sortContainersFirst'] == 1
    elseif optionId == 'sortNestedContainers' then
        return containerSettings['sortNestedContainers'] == 1
    elseif optionId == 'useManualSortMode' then
        return containerSettings['useManualSortMode'] == 1
    elseif optionId == 'moveNestedContainers' then
        return containerSettings['moveNestedContainers'] == 1
    end
    return false
end

function sortContainerItems(container, sortMode)
    if not container or not container.itemsPanel then
        return
    end
    
    -- Don't sort if manual sort mode is enabled
    local isManualSortEnabled = containerSettings and containerSettings['useManualSortMode'] == 1
    if isManualSortEnabled then
        return
    end
    
    -- Check if Sort Nested Containers is enabled when manual sort mode is disabled
    local sortNestedContainers = containerSettings and containerSettings['sortNestedContainers'] == 1
    if sortNestedContainers then
    end
    
    -- Get all items with their slot information (only non-nil items)
    local items = {}
    local totalCapacity = container:getCapacity()
    
    for slot = 0, totalCapacity - 1 do
        local item = container:getItem(slot)
        if item and item:getId() > 0 then -- Check for valid item
            table.insert(items, {
                slot = slot,
                item = item,
                widget = container.itemsPanel:getChildById('item' .. slot)
            })
        end
    end
    
    -- Only sort if we have items
    if #items == 0 then
        return
    end
    
    -- Check if Sort Containers First and Sort Nested Containers are enabled
    local sortContainersFirst = containerSettings and containerSettings['sortContainersFirst'] == 1
    local sortNestedContainers = containerSettings and containerSettings['sortNestedContainers'] == 1
    
    -- Helper function to check if an item is a container
    local function isContainer(item)
        local success, result = pcall(function()
            if item.isContainer and type(item.isContainer) == "function" then
                return item:isContainer()
            end
            return false
        end)
        return success and result
    end
    
    -- Helper function to check if a container has items inside (is nested)
    local function isNestedContainer(item)
        if not isContainer(item) then
            return false
        end
        
        local success, result = pcall(function()
            -- Try to get the container's item count
            if item.getItemsCount and type(item.getItemsCount) == "function" then
                local itemCount = item:getItemsCount()
                return itemCount and itemCount > 0
            end
            
            -- Alternative: Check if container has capacity and items
            if item.getCapacity and type(item.getCapacity) == "function" then
                local capacity = item:getCapacity()
                if capacity and capacity > 0 then
                    -- Check if any slot has an item
                    for slot = 0, capacity - 1 do
                        if item.getItem and type(item.getItem) == "function" then
                            local slotItem = item:getItem(slot)
                            if slotItem and slotItem:getId() > 0 then
                                return true
                            end
                        end
                    end
                end
            end
            
            return false
        end)
        
        if not success then
            return false
        end
        
        return result
    end
    
    -- Helper function for container-first sorting with nested container support
    local function sortWithContainersFirst(items, compareFn)
        local sortContainersFirst = containerSettings and containerSettings['sortContainersFirst'] == 1
        local sortNestedContainers = containerSettings and containerSettings['sortNestedContainers'] == 1
        
        -- Sort Nested Containers feature:
        -- When enabled, containers that have items inside them are prioritized at the top,
        -- followed by empty containers (if Sort Containers First is also enabled),
        -- and finally non-container items.
        -- 
        -- Priority order when both options are enabled:
        -- 1. Nested containers (containers with items inside) - HIGHEST PRIORITY
        -- 2. Empty containers (only if Sort Containers First is enabled)
        -- 3. Non-container items - LOWEST PRIORITY
        -- 
        -- This feature can work together with Sort Containers First but not with Manual Sort Mode.
        
        -- If neither option is enabled, just sort normally
        if not sortContainersFirst and not sortNestedContainers then
            table.sort(items, compareFn)
            return
        end
        
        -- Separate items into categories
        local nestedContainers = {}      -- Containers with items inside
        local emptyContainers = {}       -- Empty containers
        local nonContainers = {}         -- Non-container items
        
        for _, itemData in ipairs(items) do
            if isContainer(itemData.item) then
                if sortNestedContainers and isNestedContainer(itemData.item) then
                    table.insert(nestedContainers, itemData)
                else
                    table.insert(emptyContainers, itemData)
                end
            else
                table.insert(nonContainers, itemData)
            end
        end
        
        -- Sort each group separately
        table.sort(nestedContainers, compareFn)
        table.sort(emptyContainers, compareFn)
        table.sort(nonContainers, compareFn)
        
        -- Merge groups based on enabled options with proper priority order
        local sortedItems = {}
        
        -- Priority 1: Nested containers (if Sort Nested Containers is enabled)
        if sortNestedContainers then
            for _, itemData in ipairs(nestedContainers) do
                table.insert(sortedItems, itemData)
            end
        end
        
        -- Priority 2: Empty containers (if Sort Containers First is enabled)
        -- Note: This comes after nested containers even if both options are enabled
        if sortContainersFirst then
            for _, itemData in ipairs(emptyContainers) do
                table.insert(sortedItems, itemData)
            end
            
            -- Add nested containers here only if sortNestedContainers is not enabled
            if not sortNestedContainers then
                for _, itemData in ipairs(nestedContainers) do
                    table.insert(sortedItems, itemData)
                end
            end
        else
            -- If sortContainersFirst is disabled but sortNestedContainers is disabled too,
            -- add all containers together after nested containers
            if not sortNestedContainers then
                for _, itemData in ipairs(nestedContainers) do
                    table.insert(sortedItems, itemData)
                end
            end
            
            -- Add empty containers without priority
            for _, itemData in ipairs(emptyContainers) do
                table.insert(sortedItems, itemData)
            end
        end
        
        -- Priority 3 (Last): Non-container items
        for _, itemData in ipairs(nonContainers) do
            table.insert(sortedItems, itemData)
        end
        
        -- Replace original items array
        for i = 1, #items do
            items[i] = sortedItems[i]
        end
    end
    
    -- Sort the items based on the sort mode
    if sortMode == 'sortAscByName' then
        sortWithContainersFirst(items, function(a, b) 
            if not a or not a.item or not b or not b.item then 
                return false 
            end
            
            local nameA = ""
            local nameB = ""
            
            -- Use pcall for extra safety and try getName from the item
            local success, result = pcall(function()
                if a.item.getName and type(a.item.getName) == "function" then
                    return a.item:getName() or ""
                end
                -- Try getting name from the item type if direct getName fails
                local itemType = g_things.getThingType(a.item:getId(), ThingCategoryItem)
                if itemType and itemType.getName and type(itemType.getName) == "function" then
                    return itemType:getName() or ""
                end
                return ""
            end)
            if success then nameA = result end
            
            success, result = pcall(function()
                if b.item.getName and type(b.item.getName) == "function" then
                    return b.item:getName() or ""
                end
                -- Try getting name from the item type if direct getName fails
                local itemType = g_things.getThingType(b.item:getId(), ThingCategoryItem)
                if itemType and itemType.getName and type(itemType.getName) == "function" then
                    return itemType:getName() or ""
                end
                return ""
            end)
            if success then nameB = result end
            
            return nameA:lower() < nameB:lower() 
        end)
    elseif sortMode == 'sortDescByName' then
        sortWithContainersFirst(items, function(a, b) 
            if not a or not a.item or not b or not b.item then 
                return false 
            end
            
            local nameA = ""
            local nameB = ""
            
            -- Use pcall for extra safety and try getName from the item
            local success, result = pcall(function()
                if a.item.getName and type(a.item.getName) == "function" then
                    return a.item:getName() or ""
                end
                -- Try getting name from the item type if direct getName fails
                local itemType = g_things.getThingType(a.item:getId(), ThingCategoryItem)
                if itemType and itemType.getName and type(itemType.getName) == "function" then
                    return itemType:getName() or ""
                end
                return ""
            end)
            if success then nameA = result end
            
            success, result = pcall(function()
                if b.item.getName and type(b.item.getName) == "function" then
                    return b.item:getName() or ""
                end
                -- Try getting name from the item type if direct getName fails
                local itemType = g_things.getThingType(b.item:getId(), ThingCategoryItem)
                if itemType and itemType.getName and type(itemType.getName) == "function" then
                    return itemType:getName() or ""
                end
                return ""
            end)
            if success then nameB = result end
            
            return nameA:lower() > nameB:lower() 
        end)
    elseif sortMode == 'sortAscByWeight' then
        -- TODO: Implement functionality to retrieve item weights and sort accordingly
        return
    elseif sortMode == 'sortDescByWeight' then
        -- TODO: Implement weight-based sorting (descending)
        return
    elseif sortMode == 'sortAscByExpiry' then
        sortWithContainersFirst(items, function(a, b) 
            if not a or not a.item or not b or not b.item then return false end
            
            local aExpiry = 0
            local bExpiry = 0
            
            -- Use getDurationTime() for expiry - this exists on Item objects
            local success, result = pcall(function()
                if a.item.getDurationTime and type(a.item.getDurationTime) == "function" then
                    return a.item:getDurationTime() or 0
                end
                return 0
            end)
            if success then aExpiry = result end
            
            success, result = pcall(function()
                if b.item.getDurationTime and type(b.item.getDurationTime) == "function" then
                    return b.item:getDurationTime() or 0
                end
                return 0
            end)
            if success then bExpiry = result end
            
            return aExpiry < bExpiry
        end)
    elseif sortMode == 'sortDescByExpiry' then
        sortWithContainersFirst(items, function(a, b) 
            if not a or not a.item or not b or not b.item then return false end
            
            local aExpiry = 0
            local bExpiry = 0
            
            -- Use getDurationTime() for expiry - this exists on Item objects
            local success, result = pcall(function()
                if a.item.getDurationTime and type(a.item.getDurationTime) == "function" then
                    return a.item:getDurationTime() or 0
                end
                return 0
            end)
            if success then aExpiry = result end
            
            success, result = pcall(function()
                if b.item.getDurationTime and type(b.item.getDurationTime) == "function" then
                    return b.item:getDurationTime() or 0
                end
                return 0
            end)
            if success then bExpiry = result end
            
            return aExpiry > bExpiry
        end)
    elseif sortMode == 'sortAscByStackSize' then
        sortWithContainersFirst(items, function(a, b) 
            if not a or not a.item or not b or not b.item then return false end
            
            local countA = 1
            local countB = 1
            local chargesA = 0
            local chargesB = 0
            
            -- Use getCount() - this exists on Item objects
            local success, result = pcall(function()
                if a.item.getCount and type(a.item.getCount) == "function" then
                    return a.item:getCount() or 1
                end
                return 1
            end)
            if success then countA = result end
            
            success, result = pcall(function()
                if b.item.getCount and type(b.item.getCount) == "function" then
                    return b.item:getCount() or 1
                end
                return 1
            end)
            if success then countB = result end
            
            -- Get charges
            success, result = pcall(function()
                if a.item.getCharges and type(a.item.getCharges) == "function" then
                    return a.item:getCharges() or 0
                end
                return 0
            end)
            if success then chargesA = result end
            
            success, result = pcall(function()
                if b.item.getCharges and type(b.item.getCharges) == "function" then
                    return b.item:getCharges() or 0
                end
                return 0
            end)
            if success then chargesB = result end
            
            -- Use charges if available, otherwise use count
            local valueA = chargesA > 0 and chargesA or countA
            local valueB = chargesB > 0 and chargesB or countB
            
            return valueA < valueB 
        end)
    elseif sortMode == 'sortDescByStackSize' then
        sortWithContainersFirst(items, function(a, b) 
            if not a or not a.item or not b or not b.item then return false end
            
            local countA = 1
            local countB = 1
            local chargesA = 0
            local chargesB = 0
            
            -- Use getCount() - this exists on Item objects
            local success, result = pcall(function()
                if a.item.getCount and type(a.item.getCount) == "function" then
                    return a.item:getCount() or 1
                end
                return 1
            end)
            if success then countA = result end
            
            success, result = pcall(function()
                if b.item.getCount and type(b.item.getCount) == "function" then
                    return b.item:getCount() or 1
                end
                return 1
            end)
            if success then countB = result end
            
            -- Get charges
            success, result = pcall(function()
                if a.item.getCharges and type(a.item.getCharges) == "function" then
                    return a.item:getCharges() or 0
                end
                return 0
            end)
            if success then chargesA = result end
            
            success, result = pcall(function()
                if b.item.getCharges and type(b.item.getCharges) == "function" then
                    return b.item:getCharges() or 0
                end
                return 0
            end)
            if success then chargesB = result end
            
            -- Use charges if available, otherwise use count
            local valueA = chargesA > 0 and chargesA or countA
            local valueB = chargesB > 0 and chargesB or countB
            
            return valueA > valueB 
        end)
    else
        -- No sorting or unknown mode
        return
    end
    
    -- Clear all item widgets first
    for slot = 0, totalCapacity - 1 do
        local itemWidget = container.itemsPanel:getChildById('item' .. slot)
        if itemWidget then
            itemWidget:setItem(nil)
        end
    end
    
    -- Place sorted items back into the container display starting from slot 0
    for i, itemData in ipairs(items) do
        local targetSlot = i - 1 -- Convert to 0-based index
        
        if targetSlot < totalCapacity then
            local itemWidget = container.itemsPanel:getChildById('item' .. targetSlot)
            if itemWidget then
                -- Set the visual item (this doesn't change the actual container data)
                itemWidget:setItem(itemData.item)
                -- Preserve the original slot position for drag-and-drop operations
                itemWidget.position = container:getSlotPosition(itemData.slot)
                
                ItemsDatabase.setRarityItem(itemWidget, itemData.item)
                ItemsDatabase.setTier(itemWidget, itemData.item)
                itemWidget:setShowDuration(g_game.getFeature(GameThingClock) and modules.client_options.getOption('showExpiryInContainers'))
                itemWidget:setShowCharges(g_game.getFeature(GameThingCounter) and modules.client_options.getOption('showExpiryInContainers'))

                local itemName = "unnamed"
                local success, result = pcall(function()
                    if itemData.item.getName and type(itemData.item.getName) == "function" then
                        return itemData.item:getName() or "unnamed"
                    end
                    -- Try getting name from the item type if direct getName fails
                    local itemType = g_things.getThingType(itemData.item:getId(), ThingCategoryItem)
                    if itemType and itemType.getName and type(itemType.getName) == "function" then
                        return itemType:getName() or "unnamed"
                    end
                    return "unnamed"
                end)
                if success then itemName = result end
            else
            end
        else
        end
    end
end

-- Function to determine quick loot category for an item

function onContainersMenuAction(actionId)
    local isToggleOption = actionId == 'sortContainersFirst' or actionId == 'sortNestedContainers' or 
                          actionId == 'useManualSortMode' or actionId == 'moveNestedContainers'
    local isActionButton = actionId == 'moveToObtainContainers' or actionId:find('sortAsc') or actionId:find('sortDesc')
    if isActionButton then
        -- Handle action buttons (non-toggle actions)
        if actionId == 'moveToObtainContainers' then
            -- TODO: Need to create function to use quickloot sorting.
            return
        elseif actionId:find('sortAsc') or actionId:find('sortDesc') then
            -- When a sorting action is selected, automatically disable manual sort mode
            local isManualSortEnabled = containerSettings and containerSettings['useManualSortMode'] == 1
            if isManualSortEnabled then
                containerSettings['useManualSortMode'] = 0
            end
            
            -- Sorting actions - these are mutually exclusive
            containerSettings['currentSortMode'] = actionId
            g_settings.setNode('containers', containerSettings)
            
            -- Apply sorting to all open containers
            for _, container in pairs(g_game.getContainers()) do
                if container.window and container.window:isVisible() then
                    sortContainerItems(container, actionId)
                end
            end
            return
        end
    end
    
    if isToggleOption then
        -- Toggle options
        local currentState = getContainerOptionState(actionId)
        local newState = not currentState
        
        -- Special handling for useManualSortMode
        if actionId == 'useManualSortMode' then
            if newState then
                -- When enabling manual sort mode, clear any active sorting mode and disable other sorting options
                containerSettings['currentSortMode'] = 'none'
                containerSettings['sortContainersFirst'] = 0
                containerSettings['sortNestedContainers'] = 0
            else
                -- When disabling manual sort mode, sorting options become available again
            end
        elseif actionId == 'sortContainersFirst' then
            -- Prevent enabling if manual sort mode is active
            local isManualSortEnabled = containerSettings and containerSettings['useManualSortMode'] == 1
            if newState and isManualSortEnabled then
                return -- Don't change the setting
            end
            
            -- When Sort Containers First is toggled, re-apply current sorting if active
            local currentSortMode = containerSettings and containerSettings['currentSortMode']
            if currentSortMode and currentSortMode ~= 'none' then
                -- Apply sorting to all open containers after toggling
                scheduleEvent(function()
                    for _, container in pairs(g_game.getContainers()) do
                        if container.window and container.window:isVisible() then
                            sortContainerItems(container, currentSortMode)
                        end
                    end
                end, 50) -- Small delay to ensure setting is saved first
            end
        elseif actionId == 'sortNestedContainers' then
            -- Prevent enabling if manual sort mode is active
            local isManualSortEnabled = containerSettings and containerSettings['useManualSortMode'] == 1
            if newState and isManualSortEnabled then
                return -- Don't change the setting
            end
            
            -- When Sort Nested Containers is toggled, re-apply current sorting if active
            local currentSortMode = containerSettings and containerSettings['currentSortMode']
            if currentSortMode and currentSortMode ~= 'none' then
                -- Apply sorting to all open containers after toggling
                scheduleEvent(function()
                    for _, container in pairs(g_game.getContainers()) do
                        if container.window and container.window:isVisible() then
                            sortContainerItems(container, currentSortMode)
                        end
                    end
                end, 50) -- Small delay to ensure setting is saved first
            end
        elseif actionId == 'moveNestedContainers' then
            -- TODO: Implement functionality to automatically move nested containers (containers with items inside)
            -- to specific locations or positions within containers. This feature should work in conjunction
            -- with container sorting and could help organize containers by moving filled containers to
            -- preferred positions (e.g., top of container, specific slots, etc.).
            -- Implementation should consider:
            -- 1. Identify containers that have items inside (nested containers)
            -- 2. Define target positions/rules for where to move them
            -- 3. Handle conflicts with existing sorting modes
            -- 4. Respect manual sort mode settings
            -- 5. Provide user feedback on move operations
            
            -- For now, just toggle the setting - actual move functionality to be implemented
        end
        
        -- Save the new state to settings
        containerSettings[actionId] = newState and 1 or 0
        g_settings.setNode('containers', containerSettings)
    end
end

function refreshContainerItems(container)
    -- Check if we should preserve sorting during refresh
    local currentSortMode = containerSettings and containerSettings['currentSortMode']
    local isManualSortEnabled = containerSettings and containerSettings['useManualSortMode'] == 1
    local shouldSort = currentSortMode and currentSortMode ~= 'none' and not isManualSortEnabled
    
    for slot = 0, container:getCapacity() - 1 do
        local itemWidget = container.itemsPanel:getChildById('item' .. slot)
        itemWidget:setItem(container:getItem(slot))
        ItemsDatabase.setRarityItem(itemWidget, container:getItem(slot))
        ItemsDatabase.setTier(itemWidget, container:getItem(slot))
        itemWidget:setShowDuration(g_game.getFeature(GameThingClock) and modules.client_options.getOption('showExpiryInContainers'))
        itemWidget:setShowCharges(g_game.getFeature(GameThingCounter) and modules.client_options.getOption('showExpiryInContainers'))
    end

    if container:hasPages() then
        refreshContainerPages(container)
    end
    
    -- Apply current sorting if one is set and manual sort mode is disabled
    if shouldSort then
        sortContainerItems(container, currentSortMode)
    end
end

function toggleContainerPages(containerWindow, pages)
    local scrollbar = containerWindow:getChildById('miniwindowScrollBar')
    local pagePanel = containerWindow:getChildById('pagePanel')
    local separator = containerWindow:getChildById('separator')
    local contentsPanel = containerWindow:getChildById('contentsPanel')
    local upButton = containerWindow:getChildById('upButton')
    local contextMenuButton = containerWindow:recursiveGetChildById('contextMenuButton')
    local lockButton = containerWindow:recursiveGetChildById('lockButton')
    local minimizeButton = containerWindow:recursiveGetChildById('minimizeButton')
    
    if pages then
        -- When pages are visible, anchor scrollbar to close button bottom and separator top
        scrollbar:breakAnchors()
        scrollbar:addAnchor(AnchorTop, 'closeButton', AnchorBottom)
        scrollbar:addAnchor(AnchorRight, 'parent', AnchorRight)
        scrollbar:addAnchor(AnchorBottom, 'separator', AnchorTop)
        scrollbar:setMarginTop(2)  -- Small margin from close button
        scrollbar:setMarginRight(3)
        scrollbar:setMarginBottom(2)
        
        -- Content panel anchors to separator when pages are visible
        contentsPanel:breakAnchors()
        contentsPanel:addAnchor(AnchorTop, 'miniwindowTopBar', AnchorBottom)
        contentsPanel:addAnchor(AnchorLeft, 'parent', AnchorLeft)
        contentsPanel:addAnchor(AnchorRight, 'miniwindowScrollBar', AnchorLeft)
        contentsPanel:addAnchor(AnchorBottom, 'separator', AnchorTop)
        contentsPanel:setMarginLeft(3)
        contentsPanel:setMarginBottom(1)
        contentsPanel:setMarginTop(-2)
        contentsPanel:setMarginRight(1)
        
        -- When pages are active, move upButton to toggleFilterButton position if it's visible
        if upButton and upButton:isVisible() and contextMenuButton and minimizeButton then
            -- Position upButton where toggleFilterButton was
            upButton:breakAnchors()
            upButton:addAnchor(AnchorTop, minimizeButton:getId(), AnchorTop)
            upButton:addAnchor(AnchorRight, minimizeButton:getId(), AnchorLeft)
            upButton:setMarginRight(7)
            upButton:setMarginTop(0)
            
            -- Move contextMenuButton to the left of upButton
            contextMenuButton:breakAnchors()
            contextMenuButton:addAnchor(AnchorTop, upButton:getId(), AnchorTop)
            contextMenuButton:addAnchor(AnchorRight, upButton:getId(), AnchorLeft)
            contextMenuButton:setMarginRight(2)
            contextMenuButton:setMarginTop(0)
            
            -- Position lockButton to the left of contextMenu
            if lockButton then
                lockButton:breakAnchors()
                lockButton:addAnchor(AnchorTop, contextMenuButton:getId(), AnchorTop)
                lockButton:addAnchor(AnchorRight, contextMenuButton:getId(), AnchorLeft)
                lockButton:setMarginRight(2)
                lockButton:setMarginTop(0)
            end
        end
    else
        -- When pages are hidden, use normal bottom anchor
        scrollbar:breakAnchors()
        scrollbar:addAnchor(AnchorTop, 'parent', AnchorTop)
        scrollbar:addAnchor(AnchorRight, 'parent', AnchorRight)
        scrollbar:addAnchor(AnchorBottom, 'parent', AnchorBottom)
        scrollbar:setMarginTop(16)
        scrollbar:setMarginRight(3)
        scrollbar:setMarginBottom(3)
        
        -- Content panel extends to bottom when pages are hidden
        contentsPanel:breakAnchors()
        contentsPanel:addAnchor(AnchorTop, 'miniwindowTopBar', AnchorBottom)
        contentsPanel:addAnchor(AnchorLeft, 'parent', AnchorLeft)
        contentsPanel:addAnchor(AnchorRight, 'miniwindowScrollBar', AnchorLeft)
        contentsPanel:addAnchor(AnchorBottom, 'parent', AnchorBottom)
        contentsPanel:setMarginLeft(3)
        contentsPanel:setMarginBottom(3)
        contentsPanel:setMarginTop(-2)
        contentsPanel:setMarginRight(1)
        
        -- When pages are not active, reset button positions based on upButton visibility
        if upButton and contextMenuButton and minimizeButton then
            if upButton:isVisible() then
                -- Reset upButton to original position
                upButton:breakAnchors()
                upButton:addAnchor(AnchorTop, minimizeButton:getId(), AnchorTop)
                upButton:addAnchor(AnchorRight, minimizeButton:getId(), AnchorLeft)
                upButton:setMarginRight(3)
                upButton:setMarginTop(0)
                
                -- Position contextMenuButton to the left of upButton
                contextMenuButton:breakAnchors()
                contextMenuButton:addAnchor(AnchorTop, upButton:getId(), AnchorTop)
                contextMenuButton:addAnchor(AnchorRight, upButton:getId(), AnchorLeft)
                contextMenuButton:setMarginRight(2)
                contextMenuButton:setMarginTop(0)
            else
                -- Position contextMenuButton where toggleFilterButton was
                contextMenuButton:breakAnchors()
                contextMenuButton:addAnchor(AnchorTop, minimizeButton:getId(), AnchorTop)
                contextMenuButton:addAnchor(AnchorRight, minimizeButton:getId(), AnchorLeft)
                contextMenuButton:setMarginRight(7)
                contextMenuButton:setMarginTop(0)
            end
            
            -- Position lockButton to the left of contextMenu
            if lockButton then
                lockButton:breakAnchors()
                lockButton:addAnchor(AnchorTop, contextMenuButton:getId(), AnchorTop)
                lockButton:addAnchor(AnchorRight, contextMenuButton:getId(), AnchorLeft)
                lockButton:setMarginRight(2)
                lockButton:setMarginTop(0)
            end
        end
    end
    
    pagePanel:setVisible(pages)
    separator:setVisible(pages)
end

function refreshContainerPages(container)
    local currentPage = 1 + math.floor(container:getFirstIndex() / container:getCapacity())
    local pages = 1 + math.floor(math.max(0, (container:getSize() - 1)) / container:getCapacity())
    container.window:recursiveGetChildById('pageLabel'):setText(string.format('Page %i of %i', currentPage, pages))

    local prevPageButton = container.window:recursiveGetChildById('prevPageButton')
    local nextPageButton = container.window:recursiveGetChildById('nextPageButton')
    
    -- If there's only one page, hide both navigation buttons
    if pages == 1 then
        prevPageButton:setVisible(false)
        nextPageButton:setVisible(false)
    else
        -- Multiple pages logic
        if currentPage == 1 then
            -- Hide the back button when on the first page of multiple pages
            prevPageButton:setVisible(false)
        else
            prevPageButton:setVisible(true)
            prevPageButton:setEnabled(true)
            prevPageButton.onClick = function()
                -- Store current height before page change
                local currentHeight = container.window:getHeight()
                container.window.preservedHeight = currentHeight
                g_game.seekInContainer(container:getId(), container:getFirstIndex() - container:getCapacity())
            end
        end

        if currentPage >= pages then
            nextPageButton:setVisible(false)
        else
            nextPageButton:setVisible(true)
            nextPageButton:setEnabled(true)
            nextPageButton.onClick = function()
                -- Store current height before page change
                local currentHeight = container.window:getHeight()
                container.window.preservedHeight = currentHeight
                g_game.seekInContainer(container:getId(), container:getFirstIndex() + container:getCapacity())
            end
        end
    end
end

function onContainerOpen(container, previousContainer)
    local containerWindow
    if previousContainer then
        containerWindow = previousContainer.window
        previousContainer.window = nil
        previousContainer.itemsPanel = nil
    else
        containerWindow = g_ui.createWidget('ContainerWindow')
    end
    containerWindow:setId('container' .. container:getId())
    local containerPanel = containerWindow:getChildById('contentsPanel')
    local containerItemWidget = containerWindow:getChildById('containerItemWidget')
    containerWindow.onClose = function()
        g_game.close(container)
        containerWindow:hide()
    end

    -- this disables scrollbar auto hiding
    local scrollbar = containerWindow:getChildById('miniwindowScrollBar')
    scrollbar:mergeStyle({
        ['$!on'] = {}
    })
    
    -- Scrollbar positioning will be handled by toggleContainerPages function

    local upButton = containerWindow:getChildById('upButton')
    upButton.onClick = function()
        g_game.openParent(container)
    end
    upButton:setVisible(container:hasParent())

    -- Add minimize/maximize event handlers to manage pagePanel visibility
    containerWindow.onMinimize = function()
        local pagePanel = containerWindow:getChildById('pagePanel')
        if pagePanel and pagePanel:isVisible() then
            pagePanel.wasVisibleBeforeMinimize = true
            pagePanel:setVisible(false)
        end
    end
    
    containerWindow.onMaximize = function()
        local pagePanel = containerWindow:getChildById('pagePanel')
        if pagePanel and pagePanel.wasVisibleBeforeMinimize then
            pagePanel:setVisible(true)
            pagePanel.wasVisibleBeforeMinimize = nil
        end
    end

    -- Hide toggleFilterButton and adjust button positioning
    local toggleFilterButton = containerWindow:recursiveGetChildById('toggleFilterButton')
    if toggleFilterButton then
        toggleFilterButton:setVisible(false)
        toggleFilterButton:setOn(false)
    end
    
    -- Hide newWindowButton
    local newWindowButton = containerWindow:recursiveGetChildById('newWindowButton')
    if newWindowButton then
        newWindowButton:setVisible(false)
    end
    
    local contextMenuButton = containerWindow:recursiveGetChildById('contextMenuButton')
    local lockButton = containerWindow:recursiveGetChildById('lockButton')
    local minimizeButton = containerWindow:recursiveGetChildById('minimizeButton')
    
    -- Make sure contextMenuButton is visible
    if contextMenuButton then
        contextMenuButton:setVisible(true)
    end
    
    if contextMenuButton and minimizeButton then
        if container:hasParent() then
            -- When upButton is visible, position contextMenuButton to its left
            contextMenuButton:breakAnchors()
            contextMenuButton:addAnchor(AnchorTop, upButton:getId(), AnchorTop)
            contextMenuButton:addAnchor(AnchorRight, upButton:getId(), AnchorLeft)
            contextMenuButton:setMarginRight(2)
            contextMenuButton:setMarginTop(0)
        else
            -- When upButton is not visible, position contextMenuButton where toggleFilterButton was
            contextMenuButton:breakAnchors()
            contextMenuButton:addAnchor(AnchorTop, minimizeButton:getId(), AnchorTop)
            contextMenuButton:addAnchor(AnchorRight, minimizeButton:getId(), AnchorLeft)
            contextMenuButton:setMarginRight(7)
            contextMenuButton:setMarginTop(0)
        end
        
        -- Position lockButton to the left of contextMenu
        if lockButton then
            lockButton:breakAnchors()
            lockButton:addAnchor(AnchorTop, contextMenuButton:getId(), AnchorTop)
            lockButton:addAnchor(AnchorRight, contextMenuButton:getId(), AnchorLeft)
            lockButton:setMarginRight(2)
            lockButton:setMarginTop(0)
        end
        
        -- Add onClick handler for context menu
        contextMenuButton.onClick = function(widget, mousePos, mouseButton)
            return showContainersContextMenu(widget, mousePos, mouseButton)
        end
    end

    local name = container:getName()
    name = name:sub(1, 1):upper() .. name:sub(2)

    if name:len() > 14 then
        name = name:sub(1, 14) .. "..."
    end

    -- Set the title in the new miniwindowTitle element
    local titleWidget = containerWindow:getChildById('miniwindowTitle')
    if titleWidget then
        titleWidget:setText(name)
    else
        -- Fallback to old method if miniwindowTitle doesn't exist
        containerWindow:setText(name)
    end

    containerItemWidget:setItem(container:getContainerItem())
    containerItemWidget:setPhantom(true)

    containerPanel:destroyChildren()
    for slot = 0, container:getCapacity() - 1 do
        local itemWidget = g_ui.createWidget('Item', containerPanel)
        itemWidget:setId('item' .. slot)
        itemWidget:setItem(container:getItem(slot))
        ItemsDatabase.setRarityItem(itemWidget, container:getItem(slot))
        ItemsDatabase.setTier(itemWidget, container:getItem(slot))
        itemWidget:setShowDuration(g_game.getFeature(GameThingClock) and modules.client_options.getOption('showExpiryInContainers'))
        itemWidget:setShowCharges(g_game.getFeature(GameThingCounter) and modules.client_options.getOption('showExpiryInContainers'))
        itemWidget:setMargin(0)
        itemWidget.position = container:getSlotPosition(slot)

        if not container:isUnlocked() then
            itemWidget:setBorderColor('red')
        end
    end

    container.window = containerWindow
    container.itemsPanel = containerPanel

    toggleContainerPages(containerWindow, container:hasPages())
    refreshContainerPages(container)

    local layout = containerPanel:getLayout()
    local cellSize = layout:getCellSize()
    local step = cellSize.height + layout:getCellSpacing()
    local numLines = math.max(layout:getNumLines(), 1)
    local chromeHeight = container:hasPages() and 55 or 31
    containerWindow:setContentMinimumHeight(cellSize.height)

    local resizeBorder = containerWindow:getChildById('bottomResizeBorder')
    if resizeBorder then
        resizeBorder:setMinimum(step + chromeHeight)
        resizeBorder:setMaximum(numLines * step + chromeHeight)
    end
    -- Enables dragging only when mouse press occurs within window bounds (with tolerance margins)
    -- and not over the containerPanel child widget
    -- On Drop: When an item is dropped, it is placed at the nearest valid parent location, such as in a grid.
    local TOLERANCE_HORIZONTAL = 5
    local TOLERANCE_VERTICAL = 2
    containerWindow.onMousePress = function(widget, mousePos, mouseButton)
        if mouseButton ~= MouseLeftButton then
            return false
        end
        local winX, winY = containerWindow:getX(), containerWindow:getY()
        local winW, winH = containerWindow:getWidth(), containerWindow:getHeight()
        local inBounds = mousePos.x >= winX + TOLERANCE_HORIZONTAL and 
                        mousePos.x <= winX + winW - TOLERANCE_HORIZONTAL and
                        mousePos.y >= winY + TOLERANCE_VERTICAL and 
                        mousePos.y <= winY + winH - TOLERANCE_VERTICAL
        containerWindow:setDraggable(inBounds and containerWindow:getChildByPos(mousePos) ~= containerPanel)
        return inBounds
    end
    containerWindow.onMouseRelease = function(widget, mousePos, mouseButton)
        containerWindow:setDraggable(true)
    end
    containerWindow.onDrop = function(container, widget, mousePos)
        if containerPanel:getChildByPos(mousePos) then
            return false
        end
        local child = containerPanel:getNearestChild(mousePos)
        if child then
            child:onDrop(widget, mousePos, true)
        end
    end

    if not previousContainer then
        placeContainerWindow(containerWindow, container, cellSize.height)
    end

    if not previousContainer or previousContainer:getCapacity() >= container:getCapacity() then
        -- Always set the content height based on the current container's content, with a minimum of one row
        local minRows = 1
        if modules.client_options.getOption('openMaximized') then
            local numLines = math.max(layout:getNumLines(), minRows)
            containerWindow:setContentHeight(numLines * step + chromeHeight)
        else
            local numColumns = math.max(layout:getNumColumns(), 1)
            local filledLines = math.max(math.ceil(container:getItemsCount() / numColumns), minRows)
            containerWindow:setContentHeight(filledLines * step + chromeHeight)
        end
    end

    containerWindow:setup()
    if not previousContainer then
        applySavedPlacement(containerWindow)
        -- setup() may still move the window via a deferred insert; re-apply.
        for _, delay in ipairs({ 300, 1500 }) do
            scheduleEvent(function()
                if not containerWindow:isDestroyed() then
                    applySavedPlacement(containerWindow)
                end
            end, delay)
        end
    end
    
    -- Apply current sorting mode if one is active and manual sort mode is disabled
    local currentSortMode = containerSettings and containerSettings['currentSortMode']
    local isManualSortEnabled = containerSettings and containerSettings['useManualSortMode'] == 1
    if currentSortMode and currentSortMode ~= 'none' and not isManualSortEnabled then
        sortContainerItems(container, currentSortMode)
    end
    local changeType = previousContainer and
        previousContainer:getFirstIndex() ~= container:getFirstIndex() and
        'page' or 'open'
    notifyContainers(changeType, container)
end

function onContainerClose(container)
    destroy(container)
    local current = g_game.getContainer(container:getId())
    if not current or current == container then
        notifyContainers('close', container)
    end
end

function onContainerChangeSize(container, size)
    notifyContainers('resize', container)
    if not container.window then
        return
    end
    
    -- Store the current height if one was preserved from page navigation
    local preservedHeight = container.window.preservedHeight
    
    refreshContainerItems(container)
    
    -- Restore the preserved height if it exists (from page switching)
    if preservedHeight then
        container.window:setHeight(preservedHeight)
        container.window.preservedHeight = nil -- Clear the preserved height
    end
end

function onContainerUpdateItem(container, slot, item, oldItem)
    notifyContainers('update', container, slot)
    if not container.window then
        return
    end
    local itemWidget = container.itemsPanel:getChildById('item' .. slot)
    itemWidget:setItem(item)
    ItemsDatabase.setRarityItem(itemWidget, item)
    ItemsDatabase.setTier(itemWidget, item)
    itemWidget:setShowDuration(g_game.getFeature(GameThingClock) and modules.client_options.getOption('showExpiryInContainers'))
    itemWidget:setShowCharges(g_game.getFeature(GameThingCounter) and modules.client_options.getOption('showExpiryInContainers'))
    
    -- Note: Removed automatic re-sorting to prevent interference with manual item movement
    -- Sorting should only happen when explicitly requested by the user
end
