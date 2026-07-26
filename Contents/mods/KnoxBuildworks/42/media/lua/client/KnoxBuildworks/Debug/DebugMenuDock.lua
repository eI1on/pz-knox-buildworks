local MenuDock = require("ElyonLib/UI/MenuDock/MenuDock")

local DebugMenuDock = {}

local function visibleWhen()
    return isDebugEnabled() == true
end

local function openBuildTests(playerNum)
    local player = getSpecificPlayer(playerNum)
    local Window = require("KnoxBuildworks/UI/DebugBuildTestWindow")
    Window.open(player)
end

local function openTileBrowser(playerNum)
    local player = getSpecificPlayer(playerNum)
    local Browser = require("KnoxBuildworks/UI/DebugTileBrowser")
    Browser.open(player)
end

function DebugMenuDock.register()
    MenuDock.registerButton({
        id = "KnoxBuildworks.DebugBuildTests",
        title = getText("IGUI_KBW_DebugTestDockTooltip"),
        label = getText("IGUI_KBW_DebugTestDockLabel"),
        onClick = openBuildTests,
        visibleWhen = visibleWhen
    })
    MenuDock.registerButton({
        id = "KnoxBuildworks.DebugTileBrowser",
        title = getText("IGUI_KBW_DebugTilesDockTooltip"),
        label = getText("IGUI_KBW_DebugTilesDockLabel"),
        onClick = openTileBrowser,
        visibleWhen = visibleWhen
    })
end

DebugMenuDock.register()

return DebugMenuDock
