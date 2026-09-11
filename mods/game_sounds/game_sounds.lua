-- In-game sound effects.
--
-- The server sends a *numeric sound effect id* (SoundEffect_t) with magic
-- effects: spells, hits, monster noises, potions, food, doors, item moves,
-- level-ups (the last three added server-side in scripts/custom/sound_effects.lua).
-- The stock client discards it; our patched client forwards it as
-- g_game.onSoundEffect(pos, source, soundId, secondary). This module resolves
-- the effect through the official sound catalogue (random variants, volume and
-- pitch ranges) and plays the file from data/sounds/<version>/.
--
-- Client-generated sounds (never sent by the server, the official client makes
-- them locally too): footsteps, container open/close, VIP login/logout, and
-- item ambience (waterfalls, campfires, ...) looping while such items are on
-- screen.
--
-- Settings: enableAudio (Options > Sound) gates everything,
--           soundEffectsVolume (0-100, default 100), footstepSounds (bool).

local effectChannel
local ambientChannel
local lastPlayed = {}
local MIN_INTERVAL_MS = 60
local MAX_DISTANCE = 9

local function soundDirectory()
    local version = g_game.getClientVersion()
    if not version or version == 0 then
        return nil
    end
    return string.format('/data/sounds/%d/', version)
end

local function volume()
    local v = g_settings.getNumber('soundEffectsVolume', 100)
    if not v or v < 0 then v = 0 end
    if v > 100 then v = 100 end
    return v / 100
end

local function debug(msg)
    if g_settings.getBoolean('soundDebug', false) then
        g_logger.info('[game_sounds] ' .. msg)
    end
end

-- Resolve an effect id to file path, volume factor and pitch. Uses the
-- catalogue lookups when the client has them, otherwise treats the id as an
-- audio file id (older binary).
local function resolveEffect(effectId)
    local dir = soundDirectory()
    if not dir then
        return nil
    end
    local name, gain, pitch = nil, 1, 1
    if g_sounds.getSoundEffectFileName then
        name = g_sounds.getSoundEffectFileName(effectId)
        if name and name ~= '' then
            gain = g_sounds.getSoundEffectVolume(effectId) or 1
            pitch = g_sounds.getSoundEffectPitch(effectId) or 1
        end
    end
    if not name or name == '' then
        local ok, fallback = pcall(g_sounds.getAudioFileNameById, effectId)
        if ok then name = fallback end
    end
    if not name or name == '' then
        return nil
    end
    local path = dir .. name
    if not g_resources.fileExists(path) then
        return nil
    end
    if gain <= 0 then gain = 1 end
    if pitch <= 0 then pitch = 1 end
    return path, gain, pitch
end

local function playEffect(effectId, gainFactor)
    if not effectChannel or not g_sounds.isAudioEnabled() or not effectId or effectId == 0 then
        return false
    end
    local path, gain, pitch = resolveEffect(effectId)
    if not path then
        debug('no file for effect ' .. tostring(effectId))
        return false
    end
    effectChannel:play(path, 0, gain * (gainFactor or 1) * volume(), pitch)
    debug(string.format('effect %d -> %s gain=%.2f pitch=%.2f', effectId, path, gain * (gainFactor or 1), pitch))
    return true
end

-- ---------------------------------------------------------------------------
-- Server sound effects
-- ---------------------------------------------------------------------------
function onSoundEffect(pos, source, soundId, secondary)
    if not soundId or soundId == 0 then
        return
    end
    local gainFactor = 1
    local player = g_game.getLocalPlayer()
    if player and pos then
        local ppos = player:getPosition()
        if ppos then
            if pos.z ~= ppos.z then
                return
            end
            local distance = math.max(math.abs(pos.x - ppos.x), math.abs(pos.y - ppos.y))
            if distance > MAX_DISTANCE then
                return
            end
            gainFactor = math.max(0.15, 1 - distance * 0.09)
        end
    end
    local now = g_clock.millis()
    if lastPlayed[soundId] and now - lastPlayed[soundId] < MIN_INTERVAL_MS then
        return
    end
    lastPlayed[soundId] = now
    playEffect(soundId, gainFactor)
end

-- ---------------------------------------------------------------------------
-- Client-generated sounds
-- ---------------------------------------------------------------------------
local SOUND = {
    FOOTSTEPS_SLOW = 2705,
    QUICK_STEPS = 2752,
    STEP_LEAVES = 2725,
    STEP_SNOW = 2746,
    STEP_WATER = 2740,
    STEP_HORSE = 2732,
    OPEN_BACKPACK = 2786,
    VIP_LOGIN = 2807,
    VIP_LOGOUT = 2806,
}

local lastStepAt = 0
local function footstepFor(player)
    local outfit = player:getOutfit()
    if outfit and outfit.mount and outfit.mount > 0 then
        return SOUND.STEP_HORSE
    end
    local tile = g_map.getTile(player:getPosition())
    local ground = tile and tile:getGround()
    if ground then
        local ok, color = pcall(function() return g_things.getThingType(ground:getId(), ThingCategoryItem):getMinimapColor() end)
        if ok and color then
            local r, g, b = math.floor(color / 36) % 6, math.floor(color / 6) % 6, color % 6
            if r >= 4 and g >= 4 and b >= 4 then
                return SOUND.STEP_SNOW
            elseif b >= 3 and r <= 1 then
                return SOUND.STEP_WATER
            elseif g >= 2 and g > r and g > b then
                return SOUND.STEP_LEAVES
            end
        end
    end
    return SOUND.FOOTSTEPS_SLOW
end

local function onLocalWalk(player, newPos, oldPos)
    if not g_settings.getBoolean('footstepSounds', true) then
        return
    end
    if not oldPos or not newPos or (oldPos.x == newPos.x and oldPos.y == newPos.y and oldPos.z == newPos.z) then
        return
    end
    local now = g_clock.millis()
    if now - lastStepAt < 180 then
        return
    end
    lastStepAt = now
    playEffect(footstepFor(player), 0.45)
end

local function onContainerOpen(container, previousContainer)
    if not previousContainer then
        playEffect(SOUND.OPEN_BACKPACK, 0.8)
    end
end

local function onContainerClose(container)
    playEffect(SOUND.OPEN_BACKPACK, 0.6)
end

local function onVipStateChange(id, state)
    if not g_game.isOnline() then
        return
    end
    if state == VipState.Online then
        playEffect(SOUND.VIP_LOGIN, 0.8)
    elseif state == VipState.Offline then
        playEffect(SOUND.VIP_LOGOUT, 0.8)
    end
end

-- ---------------------------------------------------------------------------
-- Item ambience: waterfalls, campfires, swamps ... loop while on screen.
-- ---------------------------------------------------------------------------
local ambientItemIds = nil     -- set of item client ids that have ambience
local ambientEvent = nil
local currentAmbient = nil     -- { audioId = n, source = SoundSource }

local function stopAmbient()
    if ambientChannel then
        ambientChannel:stop(1)
    end
    currentAmbient = nil
end

local function updateAmbience()
    if not g_game.isOnline() or not ambientItemIds or not g_sounds.isAudioEnabled() then
        return
    end
    local player = g_game.getLocalPlayer()
    if not player then
        return
    end
    local ppos = player:getPosition()
    if not ppos then
        return
    end
    -- count ambient items in the visible area
    local counts = {}
    for dx = -8, 8 do
        for dy = -6, 6 do
            local tile = g_map.getTile({ x = ppos.x + dx, y = ppos.y + dy, z = ppos.z })
            if tile then
                for _, thing in ipairs(tile:getItems()) do
                    local id = thing:getId()
                    if ambientItemIds[id] then
                        counts[id] = (counts[id] or 0) + 1
                    end
                end
            end
        end
    end
    -- pick the loudest candidate (most items)
    local bestId, bestCount = nil, 0
    for id, count in pairs(counts) do
        if count > bestCount then
            bestId, bestCount = id, count
        end
    end
    local audioId = bestId and g_sounds.getItemAmbientAudioId(bestId, bestCount) or 0
    if audioId == 0 then
        if currentAmbient then
            stopAmbient()
        end
        return
    end
    if currentAmbient and currentAmbient.audioId == audioId then
        return
    end
    local dir = soundDirectory()
    local name = dir and g_sounds.getAudioFileNameById(audioId) or ''
    if not dir or name == '' then
        return
    end
    local path = dir .. name
    if not g_resources.fileExists(path) then
        return
    end
    stopAmbient()
    local source = ambientChannel:play(path, 1.5, 0.5 * volume())
    if source then
        pcall(function() source:setLooping(true) end)
    end
    currentAmbient = { audioId = audioId }
    debug('ambience ' .. path .. ' (item ' .. bestId .. ' x' .. bestCount .. ')')
end

local function startAmbience()
    if not g_sounds.getItemAmbientItemIds then
        return -- older binary without the catalogue API
    end
    ambientItemIds = {}
    for _, id in ipairs(g_sounds.getItemAmbientItemIds() or {}) do
        ambientItemIds[id] = true
    end
    if ambientEvent then
        removeEvent(ambientEvent)
    end
    ambientEvent = cycleEvent(updateAmbience, 1500)
end

local function stopAmbience()
    if ambientEvent then
        removeEvent(ambientEvent)
        ambientEvent = nil
    end
    stopAmbient()
end

-- ---------------------------------------------------------------------------
local function onGameStart()
    lastStepAt = g_clock.millis() + 1500 -- no step burst while the map loads
    startAmbience()
end

local function onGameEnd()
    stopAmbience()
end

function init()
    effectChannel = g_sounds.getChannel(SoundChannels.Effect)
    ambientChannel = g_sounds.getChannel(SoundChannels.Ambient)
    connect(g_game, { onSoundEffect = onSoundEffect, onGameStart = onGameStart, onGameEnd = onGameEnd, onVipStateChange = onVipStateChange })
    connect(LocalPlayer, { onPositionChange = onLocalWalk })
    connect(Container, { onOpen = onContainerOpen, onClose = onContainerClose })
    if g_game.isOnline() then
        onGameStart()
    end
    g_logger.info('[game_sounds] sound effects enabled' .. (g_sounds.getSoundEffectFileName and ' (catalogue lookups available)' or ' (legacy id lookup)'))
end

function terminate()
    stopAmbience()
    disconnect(g_game, { onSoundEffect = onSoundEffect, onGameStart = onGameStart, onGameEnd = onGameEnd, onVipStateChange = onVipStateChange })
    disconnect(LocalPlayer, { onPositionChange = onLocalWalk })
    disconnect(Container, { onOpen = onContainerOpen, onClose = onContainerClose })
end
