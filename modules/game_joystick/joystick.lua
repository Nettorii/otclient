local overlay
local keypad
local keypadUpdateEvent
local keypadMousePos = {x=0.5, y=0.5}
local firstStep = true
local moveListener
local joystickEnabled = false
local gestureActive = false

function init()
  if not g_platform.isMobile() then return end

  overlay = g_ui.displayUI('joystick')
  keypad = overlay.keypad
  keypad:setEnabled(false)

  connect(keypad, {
    onMousePress = onKeypadTouchPress,
    onMouseRelease = onKeypadTouchRelease,  
    onMouseMove = onKeypadTouchMove
  })

  connect(g_game, {
    onGameStart = onGameStart,
    onGameEnd = onGameEnd 
  })
end

function terminate()
  if not g_platform.isMobile() then return end

  cancelGesture()

  disconnect(keypad, {
    onMousePress = onKeypadTouchPress,
    onMouseRelease = onKeypadTouchRelease,  
    onMouseMove = onKeypadTouchMove
  })

  disconnect(g_game, {
    onGameStart = onGameStart,
    onGameEnd = onGameEnd 
  })

  overlay:destroy()
  overlay = nil
  keypadUpdateEvent = nil
end

function hide()
  cancelGesture()
  overlay:hide()
end

function show()
  overlay:show()
end

function onGameStart()
  setEnabled(true)
  keypad:raise()
  keypad:show()
end

function onGameEnd()
  setEnabled(false)
  keypad:hide()
end

function addOnJoystickMoveListener(callback)
  moveListener = callback
end

function cancelGesture()
  removeEvent(keypadUpdateEvent)
  keypadUpdateEvent = nil
  gestureActive = false
  firstStep = true
  keypadMousePos = {x=0.5, y=0.5}

  if keypad and keypad.pointer then
    keypad.pointer:setMarginTop(0)
    keypad.pointer:setMarginLeft(0)
  end
end

function setEnabled(enabled)
  joystickEnabled = enabled == true
  if not joystickEnabled then
    cancelGesture()
  end
  if keypad then
    keypad:setEnabled(joystickEnabled)
  end
end

function setBounds(rect)
  if not keypad or not rect then return false end

  local wasEnabled = joystickEnabled
  setEnabled(false)
  keypad:breakAnchors()
  keypad:setRect(rect)

  local pointerSize = math.floor(math.min(rect.width, rect.height) / 3)
  keypad.pointer:setSize({width=pointerSize, height=pointerSize})

  if wasEnabled then
    setEnabled(true)
  end
  return true
end

function onKeypadTouchPress(widget, pos, button)
  -- a thumb held still on the pad is a "long press" (right click) on release: swallow
  -- it here so it does not fall through to the map / windows underneath
  if button == MouseRightButton then return true end
  if button ~= MouseLeftButton then return false end
  if not joystickEnabled then return true end

  keypadMousePos = {x=(pos.x - widget:getPosition().x) / widget:getWidth(), 
                    y=(pos.y - widget:getPosition().y) / widget:getHeight()}

  gestureActive = true
  firstStep = true
  executeWalk(true)

  return true
end

function onKeypadTouchMove(widget, pos, offset)
  if not joystickEnabled or not gestureActive then return true end

  keypadMousePos = {x=(pos.x - widget:getPosition().x) / widget:getWidth(), 
                    y=(pos.y - widget:getPosition().y) / widget:getHeight()}

  return true
end

function onKeypadTouchRelease(widget, pos, button)
  if button == MouseRightButton then return true end
  if button ~= MouseLeftButton then return false end
  if not gestureActive then return true end

  keypadMousePos = {x=(pos.x - widget:getPosition().x) / widget:getWidth(), 
                    y=(pos.y - widget:getPosition().y) / widget:getHeight()}

  cancelGesture()

  return true
end

function executeWalk(initialPress)
  removeEvent(keypadUpdateEvent)
  keypadUpdateEvent = nil

  if not joystickEnabled or not gestureActive or
      (not initialPress and not g_mouse.isPressed(MouseLeftButton)) then
    cancelGesture()
    return
  end

  keypadUpdateEvent = scheduleEvent(executeWalk, 20)
  keypadMousePos.x = math.min(1, math.max(0, keypadMousePos.x))
  keypadMousePos.y = math.min(1, math.max(0, keypadMousePos.y))
  local angle = math.atan2(keypadMousePos.x - 0.5, keypadMousePos.y - 0.5)
  -- pointer travel scales with the pad (game_mobilecontrols enlarges it on phones)
  local radius = keypad:getHeight() / 2
  local maxTop = math.abs(math.cos(angle)) * radius
  local marginTop = math.max(-maxTop, math.min(maxTop, (keypadMousePos.y - 0.5) * radius * 2))
  local maxLeft = math.abs(math.sin(angle)) * radius
  local marginLeft = math.max(-maxLeft, math.min(maxLeft, (keypadMousePos.x - 0.5) * radius * 2))
  keypad.pointer:setMarginTop(marginTop)
  keypad.pointer:setMarginLeft(marginLeft)
  local dir

  if keypadMousePos.y < 0.3 and keypadMousePos.x < 0.3 then
    dir = Directions.NorthWest     
  elseif keypadMousePos.y < 0.3 and keypadMousePos.x > 0.7 then
    dir = Directions.NorthEast
  elseif keypadMousePos.y > 0.7 and keypadMousePos.x < 0.3 then
    dir = Directions.SouthWest
  elseif keypadMousePos.y > 0.7 and keypadMousePos.x > 0.7 then
    dir = Directions.SouthEast
  end

  if not dir and (math.abs(keypadMousePos.y - 0.5) > 0.1 or math.abs(keypadMousePos.x - 0.5) > 0.1) then
    if math.abs(keypadMousePos.y - 0.5) > math.abs(keypadMousePos.x - 0.5) then
      if keypadMousePos.y < 0.5 then
        dir = Directions.North
      else
        dir = Directions.South
      end
    else
      if keypadMousePos.x < 0.5 then
        dir = Directions.West
      else
        dir = Directions.East
      end    
    end  
  end

  if dir and moveListener then
    moveListener(dir, firstStep)
  end
end

function getPanel()
  return keypad
end