MobilePinch = {}

MobilePinch.DEFAULT_THRESHOLD = 48
MobilePinch.DEFAULT_LATCH_MS = 150

local Gesture = {}
Gesture.__index = Gesture

local function distance(points)
  local dx = points[2].x - points[1].x
  local dy = points[2].y - points[1].y
  return math.sqrt(dx * dx + dy * dy)
end

local function isWithin(widget, ancestor)
  while widget do
    if widget == ancestor then
      return true
    end
    widget = widget:getParent()
  end
  return false
end

-- pressed is the widget holding the first finger's synthesized press; it is still
-- nil when both fingers land in the same frame.
function MobilePinch.touchesOwnedByMap(map, points, pressed)
  if not map or (pressed and not isWithin(pressed, map)) then
    return false
  end
  for _, point in ipairs(points) do
    if not map:acceptsMobileTouchAt(point) then
      return false
    end
  end
  return true
end

function MobilePinch.create(options)
  options = options or {}
  return setmetatable({
    threshold = options.threshold or MobilePinch.DEFAULT_THRESHOLD,
    latchMs = options.latchMs or MobilePinch.DEFAULT_LATCH_MS,
    accept = options.accept or function() return false end,
    onBegin = options.onBegin or function() end,
    onStep = options.onStep or function() return false end,
    onFinish = options.onFinish or function() end,
    -- the browser's synthesized long-touch right click reaches the UI two dispatcher
    -- polls after the last touchend, whatever the frame time
    schedule = options.schedule or function(callback, delay)
      return scheduleEvent(function()
        addEvent(function() addEvent(callback) end)
      end, delay)
    end,
    cancel = options.cancel or function(event) removeEvent(event) end,
    state = 'idle',
    anchor = nil,
    latchEvent = nil
  }, Gesture)
end

function Gesture:isActive()
  return self.state == 'pinching'
end

function Gesture:_cancelLatch()
  if self.latchEvent then
    self.cancel(self.latchEvent)
    self.latchEvent = nil
  end
end

function Gesture:reset()
  self:_cancelLatch()
  self.state = 'idle'
  self.anchor = nil
end

function Gesture:_finish(latch)
  if self.latchEvent ~= latch then
    return
  end
  self.latchEvent = nil
  self.state = 'idle'
  self.anchor = nil
  self.onFinish()
end

function Gesture:_track(points)
  local current = distance(points)
  if not self.anchor then
    self.anchor = current
    return
  end
  while math.abs(current - self.anchor) >= self.threshold do
    local direction = current > self.anchor and 1 or -1
    if self.onStep(direction) == false then
      self.anchor = current
      return
    end
    self.anchor = self.anchor + direction * self.threshold
  end
end

-- points: the logical positions of the fingers still down after this event.
function Gesture:handle(phase, points)
  local count = #points

  if self.state == 'idle' then
    if count < 2 then
      return
    end
    if count == 2 and self.accept(points) then
      self.state = 'pinching'
      self.anchor = distance(points)
      self.onBegin()
    else
      self.state = 'ignored'
    end
    return
  end

  if self.state == 'ignored' then
    if count == 0 then
      self.state = 'idle'
    end
    return
  end

  if count == 0 then
    self.anchor = nil
    if not self.latchEvent then
      local latch
      latch = self.schedule(function() self:_finish(latch) end, self.latchMs)
      self.latchEvent = latch
    end
    return
  end

  if self.latchEvent then
    self:_cancelLatch()
    self.anchor = nil
    self.onBegin()
  end

  if count == 2 then
    self:_track(points)
  else
    self.anchor = nil
  end
end
