---CatalogSettings provides a small, live appearance menu for Knox Buildworks windows.
require "ISUI/ISCollapsableWindow"
require "ISUI/ISButton"
require "ISUI/ISComboBox"
require "ISUI/ISTickBox"
require "ISUI/ISColorPicker"
require "RadioCom/ISUIRadio/ISSliderPanel"

local Options = require("KnoxBuildworks/Options")
local Theme = require("KnoxBuildworks/UI/Theme")

---@class KBW.CatalogSettingsModule
---@type KBW.CatalogSettingsModule
local CatalogSettings = {
    settingsPanel = nil
}

local THEME_LABELS = {
    "UI_optionscreen_KBW_PanelTone_Warm",
    "UI_optionscreen_KBW_PanelTone_Charcoal",
    "UI_optionscreen_KBW_PanelTone_Slate",
    "UI_optionscreen_KBW_PanelTone_Forest",
    "UI_optionscreen_KBW_PanelTone_Midnight",
    "UI_optionscreen_KBW_PanelTone_Aubergine",
    "UI_optionscreen_KBW_PanelTone_Sandstone"
}

local BACKGROUND_LABELS = {
    "UI_optionscreen_KBW_PreviewBackground_Checker",
    "UI_optionscreen_KBW_PreviewBackground_Light",
    "UI_optionscreen_KBW_PreviewBackground_Dark",
    "UI_optionscreen_KBW_PreviewBackground_Custom"
}

local SIZE_LABELS = {
    "UI_optionscreen_KBW_Size_Default",
    "UI_optionscreen_KBW_Size_Large",
    "UI_optionscreen_KBW_Size_ExtraLarge"
}

local function option(id)
    return Options and Options.getOption and Options:getOption(id) or nil
end

local function optionValue(id, fallback)
    local target = option(id)
    return target and target.getValue and target:getValue() or fallback
end

local function applyOptions(persist)
    if Options and Options.apply then Options:apply() end
    if persist ~= false and PZAPI and PZAPI.ModOptions and PZAPI.ModOptions.save then
        PZAPI.ModOptions:save()
    end
end

local function setOption(id, value, persist)
    local target = option(id)
    if target and target.setValue then target:setValue(value) end
    if persist == false then
        Theme.applyAccessibility(Options)
    else
        applyOptions(true)
    end
end

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function configureButton(button)
    button:initialise()
    Theme.applyButton(button, false)
    return button
end

---@class KBWCatalogAppearanceSettings: ISCollapsableWindow
KBWCatalogAppearanceSettings = ISCollapsableWindow:derive("KBWCatalogAppearanceSettings")

---@param player IsoPlayer
---@param target KBWCatalog|nil
---@return KBWCatalogAppearanceSettings
function KBWCatalogAppearanceSettings:new(player, target)
    local fontHeight = getTextManager():getFontHeight(UIFont.Small)
    local controlHeight = math.max(26, fontHeight + 10)
    local rowHeight = controlHeight + 10
    local titleBarHeight = math.max(16, fontHeight + 1)
    local height = math.max(390, titleBarHeight + 36 + rowHeight * 7 + controlHeight * 2)
    local o = ISCollapsableWindow:new(120, 120, 460, height)
    setmetatable(o, self)
    self.__index = self
    o.player = player
    o.target = target
    o.minimumWidth = 420
    o.minimumHeight = height
    o.resizable = false
    o.title = getText("IGUI_KBW_AppearanceSettings")
    o.backgroundColor = Theme.color(Theme.backdrop)
    o.borderColor = Theme.color(Theme.border)
    o.controlHeight = controlHeight
    o.rowHeight = rowHeight
    o.syncingOptions = true
    o:setWantKeyEvents(true)
    return o
end

function KBWCatalogAppearanceSettings:createChildren()
    ISCollapsableWindow.createChildren(self)
    local top = self:titleBarHeight() + 12
    local controlX = 222
    local controlWidth = self.width - controlX - 18

    self.themeCombo = ISComboBox:new(controlX, top, controlWidth, self.controlHeight, self, self.onThemeChanged)
    self.themeCombo:initialise()
    self:addChild(self.themeCombo)
    for labelIndex = 1, #THEME_LABELS do
        self.themeCombo:addOption(getText(THEME_LABELS[labelIndex]))
    end

    self.backgroundCombo = ISComboBox:new(
        controlX, top + self.rowHeight, controlWidth, self.controlHeight, self, self.onBackgroundChanged
    )
    self.backgroundCombo:initialise()
    self:addChild(self.backgroundCombo)
    for labelIndex = 1, #BACKGROUND_LABELS do
        self.backgroundCombo:addOption(getText(BACKGROUND_LABELS[labelIndex]))
    end

    self.colorButton = configureButton(
        ISButton:new(
            controlX, top + self.rowHeight * 2, controlWidth, self.controlHeight, "",
            self, self.onChooseColor
        )
    )
    self:addChild(self.colorButton)

    self.highContrast = ISTickBox:new(
        18, top + self.rowHeight * 3, self.width - 36, self.controlHeight, "", self, self.onHighContrastChanged
    )
    self.highContrast:initialise()
    self.highContrast:addOption(getText("IGUI_KBW_HighContrast"))
    self:addChild(self.highContrast)

    self.fadeUnavailableIcons = ISTickBox:new(
        18, top + self.rowHeight * 4, self.width - 36, self.controlHeight, "",
        self, self.onFadeUnavailableIconsChanged
    )
    self.fadeUnavailableIcons:initialise()
    self.fadeUnavailableIcons:addOption(getText("IGUI_KBW_FadeUnavailableIcons"))
    self.fadeUnavailableIcons.tooltip = getText("IGUI_KBW_FadeUnavailableIconsTooltip")
    self:addChild(self.fadeUnavailableIcons)

    self.iconSizeSlider = ISSliderPanel:new(
        controlX, top + self.rowHeight * 5, controlWidth - 54, self.controlHeight, self, self.onIconSizeChanged
    )
    self.iconSizeSlider:initialise()
    self.iconSizeSlider:instantiate()
    self.iconSizeSlider:setValues(75, 175, 5, 10, true)
    self.iconSizeSlider:setDoButtons(true)
    self:addChild(self.iconSizeSlider)

    self.hoverPreviewCombo = ISComboBox:new(
        controlX, top + self.rowHeight * 6, controlWidth, self.controlHeight, self, self.onHoverPreviewSizeChanged
    )
    self.hoverPreviewCombo:initialise()
    self.hoverPreviewCombo.tooltip = getText("IGUI_KBW_HoverPreviewSizeTooltip")
    self:addChild(self.hoverPreviewCombo)
    for labelIndex = 1, #SIZE_LABELS do
        local label = getText(SIZE_LABELS[labelIndex])
        self.hoverPreviewCombo:addOption(label)
    end

    local opacityY = top + self.rowHeight * 7
    self.opacityDown = configureButton(
        ISButton:new(controlX, opacityY, 42, self.controlHeight, "-", self, self.onOpacityDown)
    )
    self:addChild(self.opacityDown)
    self.opacityUp = configureButton(
        ISButton:new(controlX + controlWidth - 42, opacityY, 42, self.controlHeight, "+", self, self.onOpacityUp)
    )
    self:addChild(self.opacityUp)

    self.resetButton = configureButton(
        ISButton:new(
            18, opacityY + self.controlHeight + 12, self.width - 36, self.controlHeight,
            getText("IGUI_KBW_ResetAppearance"), self, self.onReset
        )
    )
    self:addChild(self.resetButton)
    self:syncFromOptions()
    self:notifyTarget(true)
end

function KBWCatalogAppearanceSettings:notifyTarget(livePreview, relayout)
    self.backgroundColor = Theme.color(Theme.backdrop)
    self.borderColor = Theme.color(Theme.border)
    Theme.applyCombo(self.themeCombo)
    Theme.applyCombo(self.backgroundCombo)
    Theme.applyCombo(self.hoverPreviewCombo)
    Theme.applyTickBox(self.highContrast)
    Theme.applyTickBox(self.fadeUnavailableIcons)
    Theme.applySlider(self.iconSizeSlider)
    Theme.applyButton(self.opacityDown, false)
    Theme.applyButton(self.opacityUp, false)
    Theme.applyButton(self.resetButton, false)
    self:refreshColorButton()
    if self.target and self.target.onAppearanceChanged then
        self.target:onAppearanceChanged(livePreview, relayout)
    end
end

function KBWCatalogAppearanceSettings:syncFromOptions()
    self.syncingOptions = true
    if self.themeCombo then self.themeCombo.selected = tonumber(optionValue("PanelTone", 1)) or 1 end
    if self.backgroundCombo then
        self.backgroundCombo.selected = tonumber(optionValue("PreviewBackground", 1)) or 1
    end
    if self.highContrast then
        self.highContrast.selected[1] = optionValue("HighContrast", false) == true
    end
    if self.fadeUnavailableIcons then
        self.fadeUnavailableIcons.selected[1] = optionValue("FadeUnavailableIcons", true) ~= false
    end
    if self.iconSizeSlider then
        local value = tonumber(optionValue("CatalogIconSize", 100)) or 100
        if value <= 3 then value = ({100, 130, 170})[math.max(1, math.floor(value))] end
        self.iconSizeSlider:setCurrentValue(value, true)
    end
    if self.hoverPreviewCombo then
        self.hoverPreviewCombo.selected = tonumber(optionValue("HoverPreviewSize", 1)) or 1
    end
    self:refreshColorButton()
    self.syncingOptions = nil
end

function KBWCatalogAppearanceSettings:refreshColorButton()
    if not self.colorButton then return end
    local color = optionValue("BuildableBackgroundColor", { r = .35, g = .35, b = .35, a = 1 })
    local enabled = (tonumber(optionValue("PreviewBackground", 1)) or 1) == 4
    self.colorButton.backgroundColor = {
        r = tonumber(color.r) or .35,
        g = tonumber(color.g) or .35,
        b = tonumber(color.b) or .35,
        a = 1
    }
    self.colorButton.backgroundColorMouseOver = Theme.color(self.colorButton.backgroundColor)
    self.colorButton.borderColor = Theme.color(enabled and Theme.accent or Theme.borderSoft)
    Theme.lockButtonColors(self.colorButton)
    Theme.setButtonEnabled(self.colorButton, enabled)
end

function KBWCatalogAppearanceSettings:onThemeChanged()
    if self.syncingOptions then return end
    setOption("PanelTone", self.themeCombo.selected or 1)
    self:notifyTarget()
end

function KBWCatalogAppearanceSettings:onBackgroundChanged()
    if self.syncingOptions then return end
    setOption("PreviewBackground", self.backgroundCombo.selected or 1)
    self:notifyTarget()
end

function KBWCatalogAppearanceSettings:onHighContrastChanged(clickedOption, enabled)
    if self.syncingOptions then return end
    setOption("HighContrast", enabled == true)
    self:notifyTarget()
end

function KBWCatalogAppearanceSettings:onFadeUnavailableIconsChanged(clickedOption, enabled)
    if self.syncingOptions then return end
    setOption("FadeUnavailableIcons", enabled == true)
    self:notifyTarget()
end

function KBWCatalogAppearanceSettings:onIconSizeChanged(value)
    if self.syncingOptions then return end
    setOption("CatalogIconSize", math.floor((tonumber(value) or 100) + .5), false)
    self.appearanceDirty = true
    self:notifyTarget(true, true)
end

function KBWCatalogAppearanceSettings:onHoverPreviewSizeChanged()
    if self.syncingOptions then return end
    setOption("HoverPreviewSize", self.hoverPreviewCombo.selected or 1)
    self:notifyTarget()
end

function KBWCatalogAppearanceSettings:onOpacityDown()
    local value = tonumber(optionValue("PanelOpacity", 86)) or 86
    if value <= 1 then value = value * 100 end
    setOption("PanelOpacity", clamp(value - 5, 35, 100))
    self:notifyTarget()
end

function KBWCatalogAppearanceSettings:onOpacityUp()
    local value = tonumber(optionValue("PanelOpacity", 86)) or 86
    if value <= 1 then value = value * 100 end
    setOption("PanelOpacity", clamp(value + 5, 35, 100))
    self:notifyTarget()
end

function KBWCatalogAppearanceSettings:onChooseColor()
    if self.colorPicker then self.colorPicker:removeSelf() end
    local color = optionValue("BuildableBackgroundColor", { r = .35, g = .35, b = .35, a = 1 })
    local picker = ISColorPicker:new(0, 0)
    picker:initialise()
    picker.pickedTarget = self
    picker.resetFocusTo = self
    picker.pickedFunc = KBWCatalogAppearanceSettings.onColorPicked
    picker:setInitialColor(ColorInfo.new(color.r or .35, color.g or .35, color.b or .35, color.a or 1))
    local playerNum = self.player and self.player:getPlayerNum() or 0
    local left = getPlayerScreenLeft(playerNum) + 4
    local top = getPlayerScreenTop(playerNum) + 4
    local right = left + getPlayerScreenWidth(playerNum) - 8
    local bottom = top + getPlayerScreenHeight(playerNum) - 8
    local x = clamp(self.colorButton:getAbsoluteX(), left, math.max(left, right - picker.width))
    local y = self.colorButton:getAbsoluteY() + self.colorButton:getHeight()
    if y + picker.height > bottom then y = self.colorButton:getAbsoluteY() - picker.height end
    picker:setX(x)
    picker:setY(math.max(top, y))
    picker:setCapture(true)
    picker:addToUIManager()
    picker:setAlwaysOnTop(true)
    picker:bringToTop()
    self.colorPicker = picker
end

function KBWCatalogAppearanceSettings:onColorPicked(color, mouseUp)
    if not color then return end
    setOption(
        "BuildableBackgroundColor", { r = color.r, g = color.g, b = color.b, a = 1 }, mouseUp ~= false
    )
    self:notifyTarget(mouseUp == false)
    if mouseUp ~= false then self.colorPicker = nil end
end

function KBWCatalogAppearanceSettings:onReset()
    local values = {
        PanelTone = 1,
        PreviewBackground = 1,
        BuildableBackgroundColor = { r = .35, g = .35, b = .35, a = 1 },
        HighContrast = false,
        FadeUnavailableIcons = true,
        CatalogIconSize = 100,
        HoverPreviewSize = 1,
        PanelOpacity = 86
    }
    for id, value in pairs(values) do
        local target = option(id)
        if target and target.setValue then target:setValue(value) end
    end
    applyOptions(true)
    self.appearanceDirty = nil
    self:syncFromOptions()
    self:notifyTarget()
end

function KBWCatalogAppearanceSettings:render()
    ISCollapsableWindow.render(self)
    local top = self:titleBarHeight() + 17
    local labelX = 18
    self:drawText(
        getText("IGUI_KBW_UITheme"), labelX, top, Theme.text.r, Theme.text.g, Theme.text.b, 1, UIFont.Small
    )
    self:drawText(
        getText("IGUI_KBW_BuildableBackground"), labelX, top + self.rowHeight,
        Theme.text.r, Theme.text.g, Theme.text.b, 1, UIFont.Small
    )
    self:drawText(
        getText("IGUI_KBW_CustomBackgroundColor"), labelX, top + self.rowHeight * 2,
        Theme.text.r, Theme.text.g, Theme.text.b, 1, UIFont.Small
    )
    self:drawText(
        getText("IGUI_KBW_CatalogIconSize"), labelX, top + self.rowHeight * 5,
        Theme.text.r, Theme.text.g, Theme.text.b, 1, UIFont.Small
    )
    local iconSize = tonumber(optionValue("CatalogIconSize", 100)) or 100
    if iconSize <= 3 then iconSize = ({100, 130, 170})[math.max(1, math.floor(iconSize))] end
    self:drawTextRight(
        tostring(math.floor(iconSize + .5)) .. "%", self.width - 18, top + self.rowHeight * 5,
        Theme.accent.r, Theme.accent.g, Theme.accent.b, 1, UIFont.Small
    )
    self:drawText(
        getText("IGUI_KBW_HoverPreviewSize"), labelX, top + self.rowHeight * 6,
        Theme.text.r, Theme.text.g, Theme.text.b, 1, UIFont.Small
    )
    self:drawText(
        getText("IGUI_KBW_PanelOpacity"), labelX, top + self.rowHeight * 7,
        Theme.text.r, Theme.text.g, Theme.text.b, 1, UIFont.Small
    )
    local value = tonumber(optionValue("PanelOpacity", 86)) or 86
    if value <= 1 then value = value * 100 end
    local centreX = self.opacityDown:getRight()
        + math.floor((self.opacityUp:getX() - self.opacityDown:getRight()) / 2)
    self:drawTextCentre(
        string.format("%d%%", math.floor(value + .5)), centreX, top + self.rowHeight * 7,
        Theme.accent.r, Theme.accent.g, Theme.accent.b, 1, UIFont.Small
    )
end

function KBWCatalogAppearanceSettings:close()
    if self.appearanceDirty then
        applyOptions(true)
        self.appearanceDirty = nil
    end
    if self.colorPicker then
        self.colorPicker:removeSelf()
        self.colorPicker = nil
    end
    ISCollapsableWindow.close(self)
    self:removeFromUIManager()
    CatalogSettings.settingsPanel = nil
end

---@param key string|number
function KBWCatalogAppearanceSettings:isKeyConsumed(key)
    return Keyboard and key == Keyboard.KEY_ESCAPE
end

---@param key string|number
function KBWCatalogAppearanceSettings:onKeyRelease(key)
    if self:isVisible() and self:isKeyConsumed(key) then
        self:close()
        return
    end
end

---@param player IsoPlayer
---@param target KBWCatalog|nil
function CatalogSettings.open(player, target)
    if CatalogSettings.settingsPanel then
        CatalogSettings.settingsPanel.player = player or getPlayer()
        CatalogSettings.settingsPanel.target = target
        CatalogSettings.settingsPanel:syncFromOptions()
        CatalogSettings.settingsPanel:setVisible(true)
        CatalogSettings.settingsPanel:bringToTop()
        return
    end
    local panel = KBWCatalogAppearanceSettings:new(player or getPlayer(), target)
    panel:initialise()
    panel:addToUIManager()
    CatalogSettings.settingsPanel = panel
end

---@param target KBWCatalog
function CatalogSettings.detach(target)
    if CatalogSettings.settingsPanel and CatalogSettings.settingsPanel.target == target then
        CatalogSettings.settingsPanel.target = nil
    end
end

return CatalogSettings
