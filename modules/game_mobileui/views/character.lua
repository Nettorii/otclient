MobileCharacter = {}

local View = {}
View.__index = View

local SECTION_ORDER = {
  'progress',
  'vitals',
  'skills',
  'training',
  'resources'
}

local SECTION_WIDGETS = {
  progress = { section = 'characterProgressSection', rows = 'characterProgressRows' },
  vitals = { section = 'characterVitalsSection', rows = 'characterVitalsRows' },
  skills = { section = 'characterSkillsSection', rows = 'characterSkillsRows' },
  training = { section = 'characterTrainingSection', rows = 'characterTrainingRows' },
  resources = { section = 'characterResourcesSection', rows = 'characterResourcesRows' }
}

local function displayNumber(value)
  if value == nil then
    return ''
  end
  value = tonumber(value)
  if value and value == math.floor(value) then
    return tostring(math.floor(value))
  end
  return tostring(value)
end

local function displayPercent(value)
  return value == nil and '' or (displayNumber(value) .. '%')
end

local function displayPair(value, maximum)
  if maximum == nil then
    return displayNumber(value)
  end
  return displayNumber(value) .. ' / ' .. displayNumber(maximum)
end

local function displayTrainingTime(minutes)
  minutes = math.max(0, math.floor(tonumber(minutes) or 0))
  return string.format('%d:%02d', math.floor(minutes / 60), minutes % 60)
end

local function displayRegeneration(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  return string.format('%02d:%02d:%02d',
    math.floor(seconds / 3600),
    math.floor(seconds / 60) % 60,
    seconds % 60)
end

local function addRow(rows, section, key, label, value)
  rows[#rows + 1] = {
    section = section,
    key = key,
    label = label,
    value = value
  }
end

function View:_widget(id)
  return self.root and self.root:recursiveGetChildById(id) or nil
end

function View:_describeRows(snapshot)
  local rows = {}
  if not snapshot or not snapshot.available then
    return rows
  end

  if snapshot.level then
    local value = displayNumber(snapshot.level.value)
    if snapshot.level.percent ~= nil then
      value = value .. ' / ' .. displayPercent(snapshot.level.percent)
    end
    addRow(rows, 'progress', 'level', 'Level', value)
  end
  if snapshot.experience then
    addRow(rows, 'progress', 'experience', 'Experience',
      displayNumber(snapshot.experience.value))
  end
  if snapshot.magic then
    local value = displayNumber(snapshot.magic.value)
    if snapshot.magic.base ~= nil then
      value = value .. '  (base ' .. displayNumber(snapshot.magic.base) .. ')'
    end
    if snapshot.magic.percent ~= nil then
      value = value .. ' / ' .. displayPercent(snapshot.magic.percent)
    end
    addRow(rows, 'progress', 'magic', 'Magic Level', value)
  end

  if snapshot.health then
    addRow(rows, 'vitals', 'health', 'Health',
      displayPair(snapshot.health.value, snapshot.health.maximum))
  end
  if snapshot.mana then
    addRow(rows, 'vitals', 'mana', 'Mana',
      displayPair(snapshot.mana.value, snapshot.mana.maximum))
  end

  for _, skill in ipairs(snapshot.skills or {}) do
    local value = displayNumber(skill.value)
    if skill.base ~= nil then
      value = value .. '  (base ' .. displayNumber(skill.base) .. ')'
    end
    if skill.percent ~= nil then
      value = value .. ' / ' .. displayPercent(skill.percent)
    end
    addRow(rows, 'skills', 'skill:' .. tostring(skill.id),
      skill.name, value)
  end

  if snapshot.stamina then
    addRow(rows, 'training', 'stamina', 'Stamina',
      displayTrainingTime(snapshot.stamina.value))
  end
  if snapshot.regeneration then
    addRow(rows, 'training', 'regeneration', 'Regeneration',
      displayRegeneration(snapshot.regeneration.value))
  end
  if snapshot.offlineTraining then
    addRow(rows, 'training', 'offlineTraining', 'Offline Training',
      displayTrainingTime(snapshot.offlineTraining.value))
  end
  if snapshot.soul then
    addRow(rows, 'training', 'soul', 'Soul',
      displayNumber(snapshot.soul.value))
  end
  if snapshot.capacity then
    addRow(rows, 'training', 'capacity', 'Capacity',
      displayPair(snapshot.capacity.free, snapshot.capacity.total))
  end
  if snapshot.speed then
    local value = displayNumber(snapshot.speed.value)
    if snapshot.speed.base ~= nil then
      value = value .. '  (base ' .. displayNumber(snapshot.speed.base) .. ')'
    end
    addRow(rows, 'training', 'speed', 'Speed', value)
  end

  for _, resource in ipairs(snapshot.resources or {}) do
    addRow(rows, 'resources', 'resource:' .. tostring(resource.id),
      resource.name, displayNumber(resource.value))
  end
  return rows
end

function View:_layoutSections()
  local rootHeight = 48
  for _, sectionId in ipairs(SECTION_ORDER) do
    local ids = SECTION_WIDGETS[sectionId]
    local section = self:_widget(ids.section)
    local rows = self:_widget(ids.rows)
    local count = rows and #rows:getChildren() or 0
    local visible = count > 0
    section:setVisible(visible)
    if visible then
      local height = 24 + count * 48
      section:setHeight(height)
      rows:setHeight(count * 48)
      rootHeight = rootHeight + height + 6
    end
  end
  self.root:setHeight(rootHeight)
  if self.holder then
    self.holder:setHeight(rootHeight)
  end
end

function View:_createRow(description)
  local ids = SECTION_WIDGETS[description.section]
  local parent = self:_widget(ids.rows)
  local row = g_ui.createWidget('MobileCharacterRow', parent)
  row:setId('characterRow_' ..
    description.key:gsub('[^%w_%-]', '_'))
  row:getChildById('name'):setText(description.label)
  row:getChildById('value'):setText(description.value)
  self.rows[description.key] = {
    widget = row,
    section = description.section
  }
  return row
end

function View:_renderSnapshot(snapshot)
  self.snapshot = snapshot
  self.rows = {}
  for _, ids in pairs(SECTION_WIDGETS) do
    self:_widget(ids.rows):destroyChildren()
  end
  local available = snapshot and snapshot.available == true
  self:_widget('characterUnavailable'):setVisible(not available)
  for _, description in ipairs(self:_describeRows(snapshot)) do
    self:_createRow(description)
  end
  self:_layoutSections()
end

function View:_updateRows(snapshot, change)
  if not snapshot or not snapshot.available or
      not self.snapshot or not self.snapshot.available then
    self:_renderSnapshot(snapshot)
    return
  end
  local requested = {}
  for _, key in ipairs(change and change.rows or {}) do
    if key == '*' then
      self:_renderSnapshot(snapshot)
      return
    end
    requested[key] = true
  end
  local descriptions = {}
  for _, description in ipairs(self:_describeRows(snapshot)) do
    descriptions[description.key] = description
  end
  local layoutChanged = false
  for key in pairs(requested) do
    local existing = self.rows[key]
    local description = descriptions[key]
    if existing and description then
      existing.widget:getChildById('name'):setText(description.label)
      existing.widget:getChildById('value'):setText(description.value)
    elseif existing then
      existing.widget:destroy()
      self.rows[key] = nil
      layoutChanged = true
    elseif description then
      self:_createRow(description)
      layoutChanged = true
    end
  end
  self.snapshot = snapshot
  if layoutChanged then
    self:_layoutSections()
  end
end

function View:create(parent)
  self.holder = parent
  local content = parent:getParent()
  parent:setWidth(content and content:getWidth() or parent:getWidth())
  self.root = g_ui.createWidget('MobileCharacterView', parent)
  self.root:setWidth(parent:getWidth())
  return self.root
end

function View:onShow()
  self:onHide()
  if not self.root or self.root:isDestroyed() then
    return false
  end
  self:_renderSnapshot(self.skills.getSkillSnapshot())
  self.unsubscribe = self.skills.subscribeSkills(
    function(snapshot, change)
      if self.root and not self.root:isDestroyed() then
        self:_updateRows(snapshot, change)
      end
    end)
  return true
end

function View:onHide()
  if self.unsubscribe then
    self.unsubscribe()
    self.unsubscribe = nil
  end
end

function View:destroy()
  self:onHide()
  if self.root and not self.root:isDestroyed() then
    self.root:destroy()
  end
  self.root = nil
  self.holder = nil
  self.rows = {}
  self.snapshot = nil
end

function MobileCharacter.createDescriptor(options)
  options = options or {}
  local view = setmetatable({
    skills = options.skills or modules.game_skills,
    rows = {}
  }, View)
  return {
    title = 'Character',
    icon = '',
    create = function(parent) return view:create(parent) end,
    onShow = function() return view:onShow() end,
    onHide = function() view:onHide() end,
    destroy = function() view:destroy() end
  }
end
