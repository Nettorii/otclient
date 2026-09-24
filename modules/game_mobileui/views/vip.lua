MobileVip = {}

local View = {}
View.__index = View

local ROW_HEIGHT = 56
local GROUP_HEADER_HEIGHT = 56

local function containsGroup(entry, groupId)
  for _, entryGroupId in ipairs(entry.groups or {}) do
    if tostring(entryGroupId) == tostring(groupId) then
      return true
    end
  end
  return false
end

function View:_widget(id)
  return self.root and self.root:recursiveGetChildById(id) or nil
end

function View:_releaseDynamicGestures()
  for index = #self.dynamicGestureUnbinds, 1, -1 do
    self.dynamicGestureUnbinds[index]()
  end
  self.dynamicGestureUnbinds = {}
end

function View:_bindDynamic(widget)
  local mobile = modules.game_mobileui
  if not widget or not mobile or
      type(mobile.bindDrawerGestureWidget) ~= 'function' then
    return
  end
  local unbind = mobile.bindDrawerGestureWidget(widget)
  if type(unbind) == 'function' then
    self.dynamicGestureUnbinds[#self.dynamicGestureUnbinds + 1] = unbind
  end
end

function View:_closeOwnedModal()
  local session = self.modalSession
  if not session then
    return
  end
  self.modalGeneration = self.modalGeneration + 1
  self.modalSession = nil
  session.cancelled = true
  if session.handle and session.handle:isOpen() then
    session.handle:close()
  elseif session.body and not session.body:isDestroyed() then
    session.body:destroy()
  end
end

function View:_fitModalBody(body, session, generation)
  local function fit()
    if self.modalSession ~= session or
        self.modalGeneration ~= generation or
        not body or body:isDestroyed() then
      return
    end
    local bodyY = type(body.getY) == 'function' and body:getY() or 0
    local bottom = 0
    for _, child in ipairs(body:getChildren()) do
      local childY = type(child.getY) == 'function' and child:getY() or bodyY
      local margin = type(child.getMarginBottom) == 'function' and
        (tonumber(child:getMarginBottom()) or 0) or 0
      bottom = math.max(bottom, childY - bodyY + child:getHeight() + margin)
    end
    body:setHeight(math.max(ROW_HEIGHT, bottom))
  end
  if type(addEvent) == 'function' then
    addEvent(fit)
  else
    fit()
  end
end

function View:_showOwnedModal(title, body, handlers)
  local mobileUi = self.mobileUi or modules.client_mobileui
  if not mobileUi or type(mobileUi.showModal) ~= 'function' then
    self:_closeOwnedModal()
    body:destroy()
    return nil
  end
  handlers = handlers or {}
  self.modalGeneration = self.modalGeneration + 1
  local generation = self.modalGeneration
  local current = self.modalSession
  if current and current.handle and current.handle:isOpen() and
      type(current.handle.setBody) == 'function' and
      current.handle.title and
      type(current.handle.title.setText) == 'function' then
    current.generation = generation
    current.body = body
    current.submitted = false
    current.cancelled = false
    current.onEnter = handlers.onEnter
    current.onClose = handlers.onClose
    current.handle.title:setText(title)
    current.handle:setBody(body)
    self:_fitModalBody(body, current, generation)
    return current, generation
  end
  self:_closeOwnedModal()
  self.modalGeneration = self.modalGeneration + 1
  generation = self.modalGeneration
  local session = {
    body = body,
    generation = generation,
    onEnter = handlers.onEnter,
    onClose = handlers.onClose,
    submitted = false
  }
  self.modalSession = session
  function session.close(expectedGeneration)
    expectedGeneration = expectedGeneration or session.generation
    if self.modalSession == session and
        self.modalGeneration == expectedGeneration and
        session.generation == expectedGeneration then
      self:_closeOwnedModal()
    end
  end
  local handle = mobileUi.showModal({
    title = title,
    body = body,
    buttons = {},
    onEnter = function()
      if self.modalSession == session and session.onEnter then
        return session.onEnter()
      end
      return true
    end,
    onEscape = function() session.close(session.generation) end,
    onClose = function()
      if self.modalSession == session then
        self.modalSession = nil
      end
      if session.onClose then
        session.onClose()
      end
    end
  })
  session.handle = handle
  if session.cancelled and handle and handle:isOpen() then
    handle:close()
  end
  if not handle or not handle:isOpen() then
    if self.modalSession == session then
      self.modalSession = nil
    end
  else
    self:_fitModalBody(body, session, generation)
  end
  return session, generation
end

function View:_runModalAction(session, generation, callback)
  if not session or self.modalSession ~= session or
      self.modalGeneration ~= generation or
      session.generation ~= generation or session.submitted then
    return true
  end
  session.submitted = true
  if callback() == false then
    if self.modalSession == session and session.generation == generation then
      session.submitted = false
    end
  elseif self.modalSession == session and session.generation == generation then
    session.close(generation)
  end
  return true
end

function View:_showActionSheet(title, actions)
  local body = g_ui.createWidget('MobileVipActionSheet')
  local session, generation
  for index, action in ipairs(actions) do
    local button = g_ui.createWidget('MobileVipAction', body)
    button:setId('vipAction_' .. tostring(action.id or index))
    button:setText(action.text)
    button.onClick = function()
      return self:_runModalAction(session, generation, action.callback)
    end
  end
  local cancel = g_ui.createWidget('MobileVipAction', body)
  cancel:setId('vipAction_cancel')
  cancel:setText(tr('Cancel'))
  cancel.onClick = function()
    if session then session.close(generation) end
    return true
  end
  session, generation = self:_showOwnedModal(title, body)
  return session ~= nil
end

local function createForm()
  return g_ui.createWidget('MobileVipForm')
end

local function addLabel(body, id, text)
  local label = g_ui.createWidget('MobileVipFormLabel', body)
  label:setId(id)
  label:setText(text)
  return label
end

local function addTextField(body, id, text)
  local field = g_ui.createWidget('MobileVipFormTextEdit', body)
  field:setId(id)
  field:setText(text or '')
  return field
end

local function addFormAction(body, id, text)
  local button = g_ui.createWidget('MobileVipFormAction', body)
  button:setId(id)
  button:setText(text)
  return button
end

function View:_showNameForm(title, fieldLabel, initialValue, submit)
  local body = createForm()
  addLabel(body, 'formNameLabel', fieldLabel)
  local name = addTextField(body, 'formName', initialValue)
  local save = addFormAction(body, 'formSave', tr('Save'))
  local cancel = addFormAction(body, 'formCancel', tr('Cancel'))
  local session, generation
  local function saveForm()
    return self:_runModalAction(session, generation, function()
      return submit(name:getText())
    end)
  end
  save.onClick = saveForm
  cancel.onClick = function()
    if session then session.close(generation) end
    return true
  end
  session, generation =
    self:_showOwnedModal(title, body, { onEnter = saveForm })
  if session and type(name.focus) == 'function' then
    name:focus()
  end
  return session ~= nil
end

function View:_showAddVipForm()
  return self:_showNameForm(
    tr('Add VIP'), tr('Character name'), '',
    function(name) return self.vip.addVipEntry(name) end)
end

function View:_showAddGroupForm()
  local snapshot = self.vip.getVipSnapshot()
  if not snapshot.canAddGroup then
    return false
  end
  return self:_showNameForm(
    tr('Add VIP group'), tr('Group name'), '',
    function(name) return self.vip.addVipGroup(name) end)
end

function View:_showEditGroupForm(id)
  local group = self.vip.getVipGroupById(id)
  if not group or not group.editable then
    return false
  end
  return self:_showNameForm(
    tr('Edit VIP group'), tr('Group name'), group.name,
    function(name) return self.vip.editVipGroup(id, name) end)
end

function View:_showEditVipForm(id)
  local entry = self.vip.getVipEntryById(id)
  if not entry or not entry.canEdit then
    return false
  end
  local snapshot = self.vip.getVipSnapshot()
  local body = createForm()
  local save = addFormAction(body, 'formSave', tr('Save'))
  local cancel = addFormAction(body, 'formCancel', tr('Cancel'))
  addLabel(body, 'formVipName', entry.name)
  addLabel(body, 'formDescriptionLabel', tr('Description'))
  local description = addTextField(
    body, 'formDescription', entry.description or '')
  addLabel(body, 'formIconLabel', tr('Icon'))
  local icon = addTextField(body, 'formIcon', tostring(entry.icon or 0))
  local notify = entry.notify == true
  local notifyButton = addFormAction(body, 'formNotify', '')
  local function updateNotify()
    notifyButton:setText(notify and tr('Notify on login: On') or
      tr('Notify on login: Off'))
  end
  updateNotify()
  notifyButton.onClick = function()
    notify = not notify
    updateNotify()
    return true
  end

  local selectedGroups = {}
  for _, groupId in ipairs(entry.groups or {}) do
    selectedGroups[tostring(groupId)] = true
  end
  if snapshot.groupsAvailable then
    addLabel(body, 'formGroupsLabel', tr('Groups'))
    for _, group in ipairs(snapshot.groups) do
      local groupId = group.id
      local button = addFormAction(
        body, 'formGroup_' .. tostring(groupId), '')
      local function updateGroup()
        button:setText((selectedGroups[tostring(groupId)] and '[x] ' or
          '[ ] ') .. group.name)
      end
      updateGroup()
      button.onClick = function()
        local key = tostring(groupId)
        selectedGroups[key] = not selectedGroups[key]
        updateGroup()
        return true
      end
    end
  end

  local session, generation
  local function saveForm()
    return self:_runModalAction(session, generation, function()
      local groups = {}
      for _, group in ipairs(self.vip.getVipSnapshot().groups or {}) do
        if selectedGroups[tostring(group.id)] then
          groups[#groups + 1] = group.id
        end
      end
      return self.vip.editVipEntry(
        id, description:getText(), tonumber(icon:getText()), notify, groups)
    end)
  end
  save.onClick = saveForm
  cancel.onClick = function()
    if session then session.close(generation) end
    return true
  end
  session, generation = self:_showOwnedModal(
    tr('Edit %s', entry.name), body, { onEnter = saveForm })
  return session ~= nil
end

function View:_showEntryMenu(id)
  local entry = self.vip.getVipEntryById(id)
  if not entry then
    return false
  end
  local actions = {}
  if entry.canMessage then
    actions[#actions + 1] = {
      id = 'message',
      text = tr('Message to %s', entry.name),
      callback = function() return self.vip.messageVipEntry(id) end
    }
  end
  if entry.canEdit then
    actions[#actions + 1] = {
      id = 'edit',
      text = tr('Edit %s', entry.name),
      callback = function() return self:_showEditVipForm(id) end
    }
  end
  if entry.canRemove then
    actions[#actions + 1] = {
      id = 'remove',
      text = tr('Remove %s', entry.name),
      callback = function() return self.vip.removeVipEntry(id) end
    }
  end
  return self:_showActionSheet(entry.name, actions)
end

function View:_showGroupMenu(id)
  local group = self.vip.getVipGroupById(id)
  if not group then
    return false
  end
  local actions = {}
  if group.editable then
    actions[#actions + 1] = {
      id = 'editGroup',
      text = tr('Edit group %s', group.name),
      callback = function() return self:_showEditGroupForm(id) end
    }
    actions[#actions + 1] = {
      id = 'removeGroup',
      text = tr('Remove group %s', group.name),
      callback = function() return self.vip.removeVipGroup(id) end
    }
  end
  if self.vip.getVipSnapshot().canAddGroup then
    actions[#actions + 1] = {
      id = 'addGroup',
      text = tr('Add new group'),
      callback = function() return self:_showAddGroupForm() end
    }
  end
  return self:_showActionSheet(group.name, actions)
end

function View:_showAddMenu()
  local snapshot = self.vip.getVipSnapshot()
  if not snapshot.available then
    return false
  end
  local actions = {
    {
      id = 'addVip',
      text = tr('Add new VIP'),
      callback = function() return self:_showAddVipForm() end
    }
  }
  if snapshot.canAddGroup then
    actions[#actions + 1] = {
      id = 'addGroup',
      text = tr('Add new group'),
      callback = function() return self:_showAddGroupForm() end
    }
  end
  return self:_showActionSheet(tr('Add'), actions)
end

function View:_showOptionsMenu()
  local snapshot = self.vip.getVipSnapshot()
  if not snapshot.available then
    return false
  end
  local actions = {
    {
      id = 'offline',
      text = snapshot.hideOffline and tr('Show offline VIPs') or
        tr('Hide offline VIPs'),
      callback = function()
        return self.vip.setVipHideOffline(not snapshot.hideOffline)
      end
    }
  }
  if snapshot.groupsAvailable then
    actions[#actions + 1] = {
      id = 'grouped',
      text = snapshot.grouped and tr('Show flat list') or tr('Show groups'),
      callback = function()
        return self.vip.setVipGrouped(not snapshot.grouped)
      end
    }
  end
  return self:_showActionSheet(tr('VIP options'), actions)
end

function View:_configureControls()
  self:_widget('vipAdd').onClick = function()
    return self:_showAddMenu()
  end
  self:_widget('vipGroups').onClick = function()
    return self:_showOptionsMenu()
  end
end

function View:_groupedEntries(snapshot)
  local visibleEntries = {}
  for _, entry in ipairs(snapshot.entries or {}) do
    if not snapshot.hideOffline or entry.online then
      visibleEntries[#visibleEntries + 1] = entry
    end
  end
  if not snapshot.groupsAvailable or not snapshot.grouped then
    return {
      {
        key = 'flat',
        id = nil,
        name = '',
        editable = false,
        flat = true,
        entries = visibleEntries
      }
    }
  end

  local groups = {}
  for _, group in ipairs(snapshot.groups or {}) do
    local described = {
      key = tostring(group.id),
      id = group.id,
      name = group.name,
      editable = group.editable,
      entries = {}
    }
    for _, entry in ipairs(visibleEntries) do
      if containsGroup(entry, group.id) then
        described.entries[#described.entries + 1] = entry
      end
    end
    groups[#groups + 1] = described
  end
  local ungrouped = {
    key = 'ungrouped',
    id = nil,
    name = tr('Ungrouped'),
    editable = false,
    entries = {}
  }
  for _, entry in ipairs(visibleEntries) do
    if #(entry.groups or {}) == 0 then
      ungrouped.entries[#ungrouped.entries + 1] = entry
    end
  end
  if #ungrouped.entries > 0 or #groups == 0 then
    groups[#groups + 1] = ungrouped
  end
  return groups
end

function View:_createEntry(parent, group, entry)
  local id = entry.id
  local row = g_ui.createWidget('MobileVipRow', parent)
  row:setId('vipRow_' .. group.key .. '_' .. tostring(id))
  row:getChildById('state'):setText(
    entry.online and tr('Online') or tr('Offline'))
  row:getChildById('state'):setColor(
    entry.online and '#7de27d' or '#df8686')
  row:getChildById('name'):setText(entry.name)
  row:getChildById('description'):setText(
    entry.description ~= '' and entry.description or tr('No description'))
  row:getChildById('description'):setTooltip(entry.description)
  row:getChildById('actions').onClick = function()
    return self:_showEntryMenu(id)
  end
  row.onClick = function()
    return self:_showEntryMenu(id)
  end
  self:_bindDynamic(row)
end

function View:_createGroup(parent, group)
  local groupWidget = g_ui.createWidget('MobileVipGroup', parent)
  groupWidget:setId('vipGroup_' .. group.key)
  local header = groupWidget:recursiveGetChildById('groupHeader')
  header:setVisible(not group.flat)
  groupWidget:recursiveGetChildById('groupName'):setText(group.name)
  local actions = groupWidget:recursiveGetChildById('groupActions')
  actions:setId('groupActions_' .. group.key)
  actions:setVisible(group.id ~= nil)
  if group.id ~= nil then
    local id = group.id
    actions.onClick = function() return self:_showGroupMenu(id) end
    header.onClick = function() return self:_showGroupMenu(id) end
  end
  local rows = groupWidget:recursiveGetChildById('groupRows')
  for _, entry in ipairs(group.entries) do
    self:_createEntry(rows, group, entry)
  end
  local rowsHeight = #group.entries * ROW_HEIGHT
  rows:setHeight(rowsHeight)
  local headerHeight = group.flat and 0 or GROUP_HEADER_HEIGHT
  groupWidget:setHeight(headerHeight + rowsHeight)
  self:_bindDynamic(groupWidget)
  return headerHeight + rowsHeight
end

function View:_render(snapshot)
  self.snapshot = snapshot
  if not snapshot or snapshot.available ~= true then
    self:_closeOwnedModal()
  end
  self:_releaseDynamicGestures()
  local list = self:_widget('vipGroupsList')
  list:destroyChildren()
  local available = snapshot and snapshot.available == true
  local entries = {}
  for _, entry in ipairs(available and snapshot.entries or {}) do
    if not snapshot.hideOffline or entry.online then
      entries[#entries + 1] = entry
    end
  end
  local empty = #entries == 0
  local emptyLabel = self:_widget('vipEmpty')
  emptyLabel:setText(available and tr('VIP list is empty') or
    tr('VIP list unavailable'))
  emptyLabel:setVisible(empty)
  list:setVisible(not empty)
  self:_widget('vipAdd'):setEnabled(available)
  self:_widget('vipGroups'):setEnabled(available)

  local listHeight = 0
  if available and not empty then
    for _, group in ipairs(self:_groupedEntries(snapshot)) do
      listHeight = listHeight + self:_createGroup(list, group)
    end
  end
  list:setHeight(math.max(ROW_HEIGHT, listHeight))
  local rootHeight = ROW_HEIGHT + math.max(ROW_HEIGHT, listHeight) + 6
  self.root:setHeight(rootHeight)
  if self.holder then
    self.holder:setHeight(rootHeight)
  end
end

function View:create(parent)
  self.holder = parent
  local content = parent:getParent()
  parent:setWidth(content and content:getWidth() or parent:getWidth())
  self.root = g_ui.createWidget('MobileVipView', parent)
  self.root:setWidth(parent:getWidth())
  self:_configureControls()
  return self.root
end

function View:onShow()
  self:onHide()
  if not self.root or self.root:isDestroyed() then
    return false
  end
  self:_render(self.vip.getVipSnapshot())
  self.unsubscribe = self.vip.subscribeVips(function(snapshot)
    if self.root and not self.root:isDestroyed() then
      self:_render(snapshot)
    end
  end)
  return true
end

function View:onHide()
  if self.unsubscribe then
    self.unsubscribe()
    self.unsubscribe = nil
  end
  self:_releaseDynamicGestures()
  self:_closeOwnedModal()
end

function View:destroy()
  self:onHide()
  if self.root and not self.root:isDestroyed() then
    self.root:destroy()
  end
  self.root = nil
  self.holder = nil
  self.snapshot = nil
end

function MobileVip.createDescriptor(options)
  options = options or {}
  local view = setmetatable({
    vip = options.vip or modules.game_viplist,
    mobileUi = options.mobileUi,
    modalGeneration = 0,
    dynamicGestureUnbinds = {}
  }, View)
  return {
    title = 'VIP',
    icon = '',
    create = function(parent) return view:create(parent) end,
    onShow = function() return view:onShow() end,
    onHide = function() view:onHide() end,
    destroy = function() view:destroy() end
  }
end
