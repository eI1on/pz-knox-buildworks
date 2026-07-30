---Options provides the Knox Buildworks client layer.
require "PZAPI/ModOptions"
local Log = require("KnoxBuildworks/Log")
local Theme = require("KnoxBuildworks/UI/Theme")

local Options = PZAPI.ModOptions:create("KnoxBuildworks", "Knox Buildworks")
Options:addKeyBind(
    "OpenCatalog", "UI_optionscreen_KBW_OpenCatalog", Keyboard.KEY_F7, "UI_optionscreen_KBW_OpenCatalog_Tooltip"
)
Options:addTickBox("Debug", "UI_optionscreen_KBW_Debug", false, "UI_optionscreen_KBW_Debug_Tooltip")
Options:addTickBox("Profile", "UI_optionscreen_KBW_Profile", false, "UI_optionscreen_KBW_Profile_Tooltip")
Options:addSlider(
    "PanelOpacity", "UI_optionscreen_KBW_PanelOpacity", 35, 100, 5, 86,
    "UI_optionscreen_KBW_PanelOpacity_Tooltip"
)
local panelTone = Options:addComboBox(
    "PanelTone", "UI_optionscreen_KBW_PanelTone", "UI_optionscreen_KBW_PanelTone_Tooltip"
)
panelTone:addItem("UI_optionscreen_KBW_PanelTone_Warm", true)
panelTone:addItem("UI_optionscreen_KBW_PanelTone_Charcoal", false)
panelTone:addItem("UI_optionscreen_KBW_PanelTone_Slate", false)
panelTone:addItem("UI_optionscreen_KBW_PanelTone_Forest", false)
panelTone:addItem("UI_optionscreen_KBW_PanelTone_Midnight", false)
panelTone:addItem("UI_optionscreen_KBW_PanelTone_Aubergine", false)
panelTone:addItem("UI_optionscreen_KBW_PanelTone_Sandstone", false)
Options:addTickBox(
    "HighContrast", "UI_optionscreen_KBW_HighContrast", false, "UI_optionscreen_KBW_HighContrast_Tooltip"
)
local previewBackground = Options:addComboBox(
    "PreviewBackground", "UI_optionscreen_KBW_PreviewBackground", "UI_optionscreen_KBW_PreviewBackground_Tooltip"
)
previewBackground:addItem("UI_optionscreen_KBW_PreviewBackground_Checker", true)
previewBackground:addItem("UI_optionscreen_KBW_PreviewBackground_Light", false)
previewBackground:addItem("UI_optionscreen_KBW_PreviewBackground_Dark", false)
previewBackground:addItem("UI_optionscreen_KBW_PreviewBackground_Custom", false)
Options:addColorPicker(
    "BuildableBackgroundColor", "UI_optionscreen_KBW_BuildableBackgroundColor", 0.35, 0.35, 0.35, 1,
    "UI_optionscreen_KBW_BuildableBackgroundColor_Tooltip"
)
local pinnedAlignment = Options:addComboBox(
    "PinnedAlignment", "UI_optionscreen_KBW_PinnedAlignment", "UI_optionscreen_KBW_PinnedAlignment_Tooltip"
)
pinnedAlignment:addItem("UI_optionscreen_KBW_PinnedAlignment_Auto", true)
pinnedAlignment:addItem("UI_optionscreen_KBW_PinnedAlignment_Left", false)
pinnedAlignment:addItem("UI_optionscreen_KBW_PinnedAlignment_Right", false)
pinnedAlignment:addItem("UI_optionscreen_KBW_PinnedAlignment_Center", false)
local pinnedMode = Options:addComboBox(
    "PinnedPositionMode", "UI_optionscreen_KBW_PinnedPositionMode", "UI_optionscreen_KBW_PinnedPositionMode_Tooltip"
)
pinnedMode:addItem("UI_optionscreen_KBW_PinnedPositionMode_Auto", true)
pinnedMode:addItem("UI_optionscreen_KBW_PinnedPositionMode_Manual", false)
Options:addSlider(
    "PinnedOpacity", "UI_optionscreen_KBW_PinnedOpacity", 15, 100, 5, 85, "UI_optionscreen_KBW_PinnedOpacity_Tooltip"
)
local pinnedBar = Options:addComboBox(
    "PinnedBar", "UI_optionscreen_KBW_PinnedBar", "UI_optionscreen_KBW_PinnedBar_Tooltip"
)
pinnedBar:addItem("UI_optionscreen_KBW_PinnedBar_Left", true)
pinnedBar:addItem("UI_optionscreen_KBW_PinnedBar_Right", false)
pinnedBar:addItem("UI_optionscreen_KBW_PinnedBar_Top", false)
pinnedBar:addItem("UI_optionscreen_KBW_PinnedBar_None", false)
local pinnedContent = Options:addComboBox(
    "PinnedContent", "UI_optionscreen_KBW_PinnedContent", "UI_optionscreen_KBW_PinnedContent_Tooltip"
)
pinnedContent:addItem("UI_optionscreen_KBW_PinnedContent_Icons", true)
pinnedContent:addItem("UI_optionscreen_KBW_PinnedContent_Text", false)

local function clampPercent(value)
    value = tonumber(value) or 85
    if value <= 1 then value = value * 100 end
    value = math.floor((value / 5) + 0.5) * 5
    if value < 15 then value = 15 end
    if value > 100 then value = 100 end
    return value
end

function Options:apply()
    -- Log:setDebug(self:getOption("Debug"):getValue())
    Theme.applyAccessibility(self)
    local profile = self:getOption("Profile")
    if profile and profile.getValue then
        KnoxBuildworks.Runtime.profile = profile:getValue() == true
    end
    local opacity = self:getOption("PinnedOpacity")
    if opacity and opacity.getValue and opacity.setValue then
        local rounded = clampPercent(opacity:getValue())
        if tonumber(opacity:getValue()) ~= rounded then opacity:setValue(rounded) end
    end
    local panelOpacity = self:getOption("PanelOpacity")
    if panelOpacity and panelOpacity.getValue and panelOpacity.setValue then
        local rounded = clampPercent(panelOpacity:getValue())
        if rounded < 35 then rounded = 35 end
        if tonumber(panelOpacity:getValue()) ~= rounded then panelOpacity:setValue(rounded) end
    end
end

return Options
