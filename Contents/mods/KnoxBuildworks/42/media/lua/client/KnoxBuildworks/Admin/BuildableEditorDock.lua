local MenuDock = require("ElyonLib/UI/MenuDock/MenuDock")

local EditorDock = {}

local function openEditor(playerNum)
    local player = getSpecificPlayer(playerNum)
    if not player then return end
    local Editor = require("KnoxBuildworks/Admin/BuildableEditor")
    Editor.open(player)
end

function EditorDock.register()
    MenuDock.registerButton({
        id = "KnoxBuildworks.BuildableEditor",
        title = getText("IGUI_KBW_AdminEditorDockTooltip"),
        label = getText("IGUI_KBW_AdminEditorDockLabel"),
        icon = "media/ui/KBW_Dock_BuildableRules.png",
        onClick = openEditor,
        minimumAccessLevel = "Admin",
        allowSinglePlayer = true
    })
end

EditorDock.register()

return EditorDock
