-- In-game sound effects.
-- The server sends a sound id with magic effects (spells, hits, doors, ...).
-- The stock client discards it; our patched client forwards it as
-- g_game.onSoundEffect(pos, source, soundId, secondary) and this module plays
-- the matching file from the official sound package (data/sounds/<version>/).
-- Volume falls off with distance from the player. Settings:
--   enableAudio (Options > Sound) gates everything,
--   soundEffectsVolume (0-100, default 100).

local effectChannel
local lastPlayed = {}
local MIN_INTERVAL_MS = 60 -- same sound id at most every 60 ms (stacked hits)
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

function onSoundEffect(pos, source, soundId, secondary)
    if not effectChannel or not g_sounds.isAudioEnabled() then
        return
    end
    if not soundId or soundId == 0 then
        return
    end
    local dir = soundDirectory()
    if not dir then
        return
    end

    local gain = 1
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
            gain = math.max(0.15, 1 - distance * 0.09)
        end
    end

    local now = g_clock.millis()
    if lastPlayed[soundId] and now - lastPlayed[soundId] < MIN_INTERVAL_MS then
        return
    end
    lastPlayed[soundId] = now

    local ok, name = pcall(g_sounds.getAudioFileNameById, soundId)
    if not ok or not name or name == '' then
        return
    end
    local path = dir .. name
    if not g_resources.fileExists(path) then
        return
    end
    effectChannel:play(path, 0, gain * volume())
end

function init()
    effectChannel = g_sounds.getChannel(SoundChannels.Effect)
    connect(g_game, { onSoundEffect = onSoundEffect })
    g_logger.info('[game_sounds] sound effects enabled')
end

function terminate()
    disconnect(g_game, { onSoundEffect = onSoundEffect })
end
