dofile 'neededtranslations'

-- private variables
local defaultLocaleName = 'en'
local installedLocales
local currentLocale

local function mobileUiModule()
    return modules and modules.client_mobileui
end

local function isMobileV2()
    local mobileUi = mobileUiModule()
    return mobileUi and mobileUi.isV2Enabled and mobileUi.isV2Enabled() or false
end

local function reloadModulesForLocale()
    if g_sounds then
        g_sounds.stopAll()
    end

    g_modules.reloadModules()

    if g_sounds and not g_game.isOnline() then
        g_sounds.getChannel(SoundChannels.Music):enqueue('/client/sounds/startup', 3)
    end
end

local function createTouchScroller(scrollBar)
    local lastY
    local dragDistance = 0
    local dragged = false

    local function onMousePress(widget, position, button)
        if button ~= MouseLeftButton then return false end
        lastY = position.y
        dragDistance = 0
        dragged = false
        return false
    end

    local function onMouseMove(widget, position)
        if not lastY or not g_mouse.isPressed(MouseLeftButton) then
            return false
        end

        local delta = lastY - position.y
        lastY = position.y
        dragDistance = dragDistance + math.abs(delta)
        if dragDistance >= 6 then
            dragged = true
            scrollBar:setValue(scrollBar:getValue() + delta)
        end
        return dragged
    end

    local function onMouseRelease(widget, position, button)
        if button ~= MouseLeftButton then return false end
        lastY = nil
        return dragged
    end

    return {
        bind = function(widget)
            connect(widget, {
                onMousePress = onMousePress,
                onMouseMove = onMouseMove,
                onMouseRelease = onMouseRelease
            })
        end,
        consumeClick = function()
            local consumed = dragged
            dragged = false
            return consumed
        end
    }
end

function sendLocale(localeName)
    local protocolGame = g_game.getProtocolGame()
    if protocolGame then
        protocolGame:sendExtendedOpcode(ExtendedIds.Locale, localeName)
        return true
    end
    return false
end

function createWindow()
    local mobileV2 = isMobileV2()
    localesWindow = g_ui.displayUI(mobileV2 and 'locales-mobile' or 'locales')
    local localesPanel = localesWindow:recursiveGetChildById('localesPanel')
    local layout = localesPanel:getLayout()
    local spacing = layout:getCellSpacing()
    local size = layout:getCellSize()
    local touchScroller
    if mobileV2 then
        local scrollBar = localesWindow:recursiveGetChildById('localesScrollBar')
        touchScroller = createTouchScroller(scrollBar)
        touchScroller.bind(localesPanel)
    end

    local count = 0
    local function createLocaleButton(name, locale)
        local widget = g_ui.createWidget('LocalesButton', localesPanel)
        widget:setImageSource('/images/flags/' .. name .. '')
        widget:setText(locale.languageName)
        widget.onClick = function()
            if touchScroller and touchScroller.consumeClick() then return end
            selectFirstLocale(name)
        end
        if touchScroller then touchScroller.bind(widget) end
        count = count + 1
    end

    if mobileV2 then
        local localeNames = {}
        for name in pairs(installedLocales) do
            table.insert(localeNames, name)
        end
        table.sort(localeNames, function(left, right)
            if left == defaultLocaleName then return true end
            if right == defaultLocaleName then return false end
            return left < right
        end)
        for _, name in ipairs(localeNames) do
            createLocaleButton(name, installedLocales[name])
        end

        local profile = mobileUiModule().getProfile()
        local surface = localesWindow:recursiveGetChildById('localesSurface')
        surface:setWidth(math.min(340, profile.usableWidth - 24))
        surface:setHeight(math.min(316, profile.usableHeight - 24))
    else
        for name, locale in pairs(installedLocales) do
            createLocaleButton(name, locale)
        end
        count = math.max(1, math.min(count, 3))
        localesPanel:setWidth(size.width * count + spacing * (count - 1))
    end

    addEvent(function()
        addEvent(function()
            localesWindow:raise()
            localesWindow:focus()
        end)
    end)
end

function selectFirstLocale(name)
    if localesWindow then
        localesWindow:destroy()
        localesWindow = nil
    end
    if setLocale(name) then
        reloadModulesForLocale()
    end
end

-- hooked functions
function onGameStart()
    sendLocale(currentLocale.name)
end

function onExtendedLocales(protocol, opcode, buffer)
    local locale = installedLocales[buffer]
    if locale and setLocale(locale.name) then
        reloadModulesForLocale()
    end
end

-- public functions
function init()
    installedLocales = {}

    installLocales('/locales')

    local userLocaleName = g_settings.get('locale', 'false')
    if userLocaleName ~= 'false' and setLocale(userLocaleName) then
        pdebug('Using configured locale: ' .. userLocaleName)
    else
        setLocale(defaultLocaleName)
        if g_app.hasUpdater() then
            connect(g_app, {
                onUpdateFinished = createWindow,
            })
        else
            connect(g_app, {
                onRun = createWindow,
            })
        end
    end

    ProtocolGame.registerExtendedOpcode(ExtendedIds.Locale, onExtendedLocales)
    connect(g_game, {
        onGameStart = onGameStart
    })
end

function terminate()
    installedLocales = nil
    currentLocale = nil

    ProtocolGame.unregisterExtendedOpcode(ExtendedIds.Locale)
    if g_app.hasUpdater() then
        disconnect(g_app, {
            onUpdateFinished = createWindow,
        })
    else
        disconnect(g_app, {
            onRun = createWindow,
        })
    end
    disconnect(g_game, {
        onGameStart = onGameStart
    })
end

function generateNewTranslationTable(localename)
    local locale = installedLocales[localename]
    for _i, k in pairs(neededTranslations) do
        local trans = locale.translation[k]
        k = k:gsub('\n', '\\n')
        k = k:gsub('\t', '\\t')
        k = k:gsub('\"', '\\\"')
        if trans then
            trans = trans:gsub('\n', '\\n')
            trans = trans:gsub('\t', '\\t')
            trans = trans:gsub('\"', '\\\"')
        end
        if not trans then
            print('    ["' .. k .. '"]' .. ' = false,')
        else
            print('    ["' .. k .. '"]' .. ' = "' .. trans .. '",')
        end
    end
end

function installLocale(locale)
    if not locale or not locale.name then
        error('Unable to install locale.')
    end

    if _G.allowedLocales and not _G.allowedLocales[locale.name] then
        return
    end

    if locale.name ~= defaultLocaleName then
        local updatesNamesMissing = {}
        for _, k in pairs(neededTranslations) do
            if locale.translation[k] == nil then
                updatesNamesMissing[#updatesNamesMissing + 1] = k
            end
        end

        if #updatesNamesMissing > 0 then
            pdebug('Locale \'' .. locale.name .. '\' is missing ' .. #updatesNamesMissing .. ' translations.')
            for _, name in pairs(updatesNamesMissing) do
                pdebug('["' .. name .. '"] = \"\",')
            end
        end
    end

    local installedLocale = installedLocales[locale.name]
    if installedLocale then
        for word, translation in pairs(locale.translation) do
            installedLocale.translation[word] = translation
        end
    else
        installedLocales[locale.name] = locale
    end
end

function installLocales(directory)
    dofiles(directory)
end

function setLocale(name)
    local locale = installedLocales[name]
    if locale == currentLocale then
        g_settings.set('locale', name)
        return
    end
    if not locale then
        pwarning('Locale ' .. name .. ' does not exist.')
        return false
    end
    if currentLocale then
        sendLocale(locale.name)
    end
    currentLocale = locale
    g_settings.set('locale', name)
    if onLocaleChanged then
        onLocaleChanged(name)
    end
    return true
end

function getInstalledLocales()
    return installedLocales
end

function getCurrentLocale()
    return currentLocale
end

-- global function used to translate texts
function _G.tr(text, ...)
    if currentLocale then
        if tonumber(text) and currentLocale.formatNumbers then
            local number = tostring(text):split('.')
            local out = ''
            local reverseNumber = number[1]:reverse()
            for i = 1, #reverseNumber do
                out = out .. reverseNumber:sub(i, i)
                if i % 3 == 0 and i ~= #number then
                    out = out .. currentLocale.thousandsSeperator
                end
            end

            if number[2] then
                out = number[2] .. currentLocale.decimalSeperator .. out
            end
            return out:reverse()
        elseif tostring(text) then
            local translation = currentLocale.translation[text]
            if not translation then
                if translation == nil then
                    if currentLocale.name ~= defaultLocaleName then
                        pdebug('Unable to translate: \"' .. text .. '\"')
                    end
                end
                translation = text
            end
            return string.format(translation, ...)
        end
    end
    return text
end
