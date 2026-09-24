local resolveMobileUiVersion

function runActivationSelfTests()
  assert(resolveMobileUiVersion(false, 'v2', 'v2') == 'legacy',
    'non-mobile must remain legacy')
  assert(resolveMobileUiVersion(true, 'v2', 'legacy') == 'v2',
    'runtime v2 must win over persisted legacy')
  assert(resolveMobileUiVersion(true, 'legacy', 'v2') == 'legacy',
    'runtime legacy must win over persisted v2')
  assert(resolveMobileUiVersion(true, nil, 'v2') == 'v2',
    'persisted v2 must be used without runtime config')
  assert(resolveMobileUiVersion(true, 'invalid', 'v2') == 'v2',
    'invalid runtime config must fall back to persisted config')
  assert(resolveMobileUiVersion(true, nil, nil) == 'v2',
    'mobile rollout default must be v2')
end

local function isKnownVersion(version)
  return version == 'v2' or version == 'legacy'
end

resolveMobileUiVersion = function(isMobile, runtimeVersion, persistedVersion)
  if not isMobile then
    return 'legacy'
  end
  if isKnownVersion(runtimeVersion) then
    return runtimeVersion
  end
  if isKnownVersion(persistedVersion) then
    return persistedVersion
  end
  return 'v2'
end

local function configuredVersion()
  local runtimeVersion
  if type(WebClientConfig) == 'table' then
    runtimeVersion = WebClientConfig.mobileUiVersion
  end

  local persistedVersion
  if g_settings and g_settings.getString then
    persistedVersion = g_settings.getString('mobile-ui-version', '')
  end

  return resolveMobileUiVersion(
    g_platform.isMobile(), runtimeVersion, persistedVersion)
end

function isV2Enabled()
  return configuredVersion() == 'v2'
end

function selectVersionAndRestart(version)
  assert(isKnownVersion(version), 'unknown mobile UI version')
  g_settings.set('mobile-ui-version', version)
  g_settings.save()
  if g_platform.isBrowser and g_platform.isBrowser() then
    local recoveryUrl = type(WebClientConfig) == 'table' and
      WebClientConfig.mobileUiLegacyUrl or nil
    if version == 'legacy' and type(recoveryUrl) == 'string' and
        recoveryUrl ~= '' and g_platform.openUrl and
        g_platform.openUrl(recoveryUrl, true) then
      return true
    end
    return false
  end
  if not g_app.restart then
    return false
  end
  g_app.restart()
  return true
end

function init()
  g_ui.importStyle('mobileui.otui')
  g_ui.importStyle('modalhost.otui')
  g_ui.importStyle('portrait.otui')
  initProfile()
  if isV2Enabled() then
    initFallback()
    initModalHost()
    initPortrait()
  end
end

function terminate()
  terminatePortrait()
  terminateModalHost()
  terminateFallback()
  terminateProfile()
end
