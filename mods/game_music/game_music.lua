-- In-game background music.
-- OTClient parses but ignores the server's music packets, so this module
-- plays the client's own music tracks (shuffled, looping) while in game and
-- restores the login-screen track afterwards. Toggle with the Music option in
-- Options > Sound (the Music channel is respected) or the !music chat command
-- is not needed: the option "Enable music" controls it.

-- Sound ids of the MUSIC_TYPE_MUSIC templates in the 15.25 sound catalogue
-- (sounds-*.dat, music_template.sound_id). Missing ids are skipped.
local MUSIC_SOUND_IDS = { 561, 719, 720, 721, 722, 723, 724, 725, 726, 727, 728, 729, 730, 732, 733, 735, 736, 774, 828, 873 }
local LOGIN_MUSIC = 'sounds/startup'
local FADE = 3

local musicChannel
local playing = false

local function musicDirectory()
    local version = g_game.getClientVersion()
    if not version or version == 0 then
        return nil
    end
    return string.format('/data/sounds/%d/', version)
end

local function trackList()
    local dir = musicDirectory()
    if not dir then
        return {}
    end
    local tracks = {}
    for _, id in ipairs(MUSIC_SOUND_IDS) do
        local ok, name = pcall(g_sounds.getAudioFileNameById, id)
        if ok and name and name ~= '' then
            local path = dir .. name
            if g_resources.fileExists(path) then
                tracks[#tracks + 1] = path
            end
        end
    end
    return tracks
end

local function onGameStart()
    if not musicChannel then
        return
    end
    local tracks = trackList()
    if #tracks == 0 then
        g_logger.info('[game_music] no music tracks found for this client version')
        return
    end
    -- modules/client/client.lua fades the music channel out (stop(3)) on
    -- game start as well; depending on handler order that would silence the
    -- tracks queued here. Queue them after that fade has finished.
    playing = true
    scheduleEvent(function()
        if not playing or not g_game.isOnline() then
            return
        end
        musicChannel:stop()
        for _, path in ipairs(tracks) do
            musicChannel:enqueue(path, FADE)
        end
        g_logger.info(string.format('[game_music] %d tracks queued', #tracks))
    end, (FADE + 1) * 1000)
end

local function onGameEnd()
    if not musicChannel or not playing then
        return
    end
    playing = false
    -- client.lua already re-queued the login track; keep only that one.
    musicChannel:stop()
    musicChannel:enqueue(LOGIN_MUSIC, FADE)
end

function init()
    musicChannel = g_sounds.getChannel(SoundChannels.Music)
    connect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
    if g_game.isOnline() then
        onGameStart()
    end
end

function terminate()
    disconnect(g_game, { onGameStart = onGameStart, onGameEnd = onGameEnd })
    if playing then
        onGameEnd()
    end
end
