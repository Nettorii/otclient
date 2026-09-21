local createStateController

function runStateSelfTests()
  local controller = createStateController()
  local events = {}
  local oldOwner = {}
  local newOwner = {}

  function oldOwner:onForegroundLost()
    local state, owner = controller.get()
    assert(state == 'chat' and owner == newOwner,
      'old owner callback must observe the updated foreground')
    table.insert(events, 'lost')
  end

  function newOwner:onForegroundGained()
    local state, owner = controller.get()
    assert(state == 'chat' and owner == newOwner,
      'new owner callback must observe the updated foreground')
    table.insert(events, 'gained')
  end

  assert(controller.set('drawer', oldOwner), 'drawer state must be accepted')
  events = {}
  assert(controller.set('chat', newOwner), 'chat state must be accepted')
  assert(events[1] == 'lost' and events[2] == 'gained' and #events == 2,
    'old owner loss must precede new owner gain')

  events = {}
  assert(controller.set('chat', newOwner), 'duplicate foreground remains valid')
  assert(#events == 0, 'duplicate foreground must not invoke callbacks')

  local stateBefore, ownerBefore = controller.get()
  assert(not controller.set('invalid', oldOwner), 'unknown state must be rejected')
  local stateAfter, ownerAfter = controller.get()
  assert(stateAfter == stateBefore and ownerAfter == ownerBefore,
    'rejected state must not change ownership')

  assert(not controller.release(oldOwner), 'non-owner cannot release foreground')
  assert(controller.release(newOwner), 'active owner can release foreground')
  local releasedState, releasedOwner = controller.get()
  assert(releasedState == 'gameplay' and releasedOwner == nil,
    'release restores unowned gameplay')

  local reentrantController = createStateController()
  local reentrantOwner = {}
  local supersededOwner = {}
  local reentrantOldOwner = {}
  local supersededGainCalls = 0
  local reentrantGainCalls = 0

  function supersededOwner:onForegroundGained()
    supersededGainCalls = supersededGainCalls + 1
  end

  function reentrantOwner:onForegroundGained()
    reentrantGainCalls = reentrantGainCalls + 1
  end

  function reentrantOldOwner:onForegroundLost()
    reentrantController.set('modal', reentrantOwner)
  end

  reentrantController.set('drawer', reentrantOldOwner)
  reentrantController.set('chat', supersededOwner)
  local reentrantState, activeReentrantOwner = reentrantController.get()
  assert(reentrantState == 'modal' and activeReentrantOwner == reentrantOwner,
    'reentrant transition must remain active')
  assert(reentrantGainCalls == 1,
    'reentrant transition owner must gain foreground once')
  assert(supersededGainCalls == 0,
    'superseded outer owner must not gain foreground')

  for _, acceptedState in ipairs({
    'gameplay', 'drawer', 'chat', 'modal', 'reconnecting'
  }) do
    assert(controller.set(acceptedState, nil),
      acceptedState .. ' state must be accepted')
  end
end

local VALID_STATES = {
  gameplay = true,
  drawer = true,
  chat = true,
  modal = true,
  reconnecting = true
}

createStateController = function()
  local activeState = 'gameplay'
  local activeOwner
  local controller = {}

  function controller.set(state, owner)
    if not VALID_STATES[state] then
      return false
    end
    if state == activeState and owner == activeOwner then
      return true
    end

    local oldState = activeState
    local oldOwner = activeOwner
    activeState = state
    activeOwner = owner

    if oldOwner and oldOwner.onForegroundLost then
      oldOwner:onForegroundLost(state, owner)
    end
    if activeState == state and activeOwner == owner and
        owner and owner.onForegroundGained then
      owner:onForegroundGained(oldState, oldOwner)
    end
    return true
  end

  function controller.get()
    return activeState, activeOwner
  end

  function controller.release(owner)
    if not owner or owner ~= activeOwner then
      return false
    end
    return controller.set('gameplay', nil)
  end

  return controller
end

local stateController = createStateController()

function setForeground(state, owner)
  return stateController.set(state, owner)
end

function getForeground()
  return stateController.get()
end

function releaseForeground(owner)
  return stateController.release(owner)
end
