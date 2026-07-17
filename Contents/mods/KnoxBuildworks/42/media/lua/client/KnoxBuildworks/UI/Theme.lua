---Theme provides the Knox Buildworks custom user-interface layer.
---@class KBW.ThemeModule
---@type KBW.ThemeModule
local Theme = {}

local good = getCore():getGoodHighlitedColor()

Theme.backdrop = { r = 0.025, g = 0.022, b = 0.020, a = 0.86 }
Theme.surface = { r = 0.070, g = 0.065, b = 0.060, a = 0.78 }
Theme.surfaceRaised = { r = 0.115, g = 0.100, b = 0.086, a = 0.90 }
Theme.selected = { r = 0.16, g = 0.18, b = 0.13, a = 0.92 }
Theme.selectedSoft = { r = 0.115, g = 0.135, b = 0.105, a = 0.72 }
Theme.accent = { r = 0.76, g = 0.70, b = 0.42, a = 1.0 }
Theme.border = { r = 0.48, g = 0.46, b = 0.42, a = 0.75 }
Theme.borderSoft = { r = 0.30, g = 0.29, b = 0.27, a = 0.65 }
Theme.text = { r = 0.92, g = 0.91, b = 0.88, a = 1.0 }
Theme.textMuted = { r = 0.64, g = 0.63, b = 0.60, a = 1.0 }
Theme.good = { r = good:getR(), g = good:getG(), b = good:getB(), a = 1.0 }
Theme.bad = { r = 0.84, g = 0.42, b = 0.24, a = 1.0 }
Theme.warn = { r = 0.86, g = 0.62, b = 0.28, a = 1.0 }
Theme.warnSoft = { r = 0.46, g = 0.32, b = 0.18, a = 0.80 }
Theme.dangerSoft = { r = 0.38, g = 0.24, b = 0.18, a = 0.85 }
Theme.primary = { r = 0.30, g = 0.44, b = 0.29, a = 0.88 }
Theme.primaryHover = { r = 0.38, g = 0.52, b = 0.35, a = 0.94 }
Theme.disabled = { r = 0.16, g = 0.15, b = 0.14, a = 0.55 }

-- Widgets must always receive their own copy of a palette color. Vanilla
-- widget code (ISButton:setEnable, setBorderRGBA, setBackgroundRGBA) writes
-- into the assigned color table IN PLACE, so a shared table would let one
-- disabled button repaint every panel in the mod red/black for the session.
local function cloneColor(c)
    return { r = c.r or 1, g = c.g or 1, b = c.b or 1, a = c.a or 1 }
end

Theme.color = cloneColor

-- Remembers the button's current border/background as its "enabled" look, so
-- toggling enabled state can restore them exactly.
function Theme.lockButtonColors(button)
    if not button then
        return
    end
    button.borderColorEnabled = cloneColor(button.borderColor)
    button.backgroundColorEnabled = cloneColor(button.backgroundColor)
end

-- Knox replacement for ISButton:setEnable. The vanilla method hardcodes a red
-- border and pure black background for disabled buttons, which fights the
-- Knox palette (and mutates color tables in place - see cloneColor above).
function Theme.setButtonEnabled(button, enabled)
    if not button then
        return
    end
    if not button.borderColorEnabled then Theme.lockButtonColors(button) end
    button.enable = enabled == true
    if button.enable then
        button.textureColor = { r = 1, g = 1, b = 1, a = 1 }
        button.textColor = cloneColor(Theme.text)
        button.borderColor = cloneColor(button.borderColorEnabled)
        button.backgroundColor = cloneColor(button.backgroundColorEnabled)
    else
        button.textureColor = { r = 0.42, g = 0.42, b = 0.42, a = 1 }
        button.textColor = cloneColor(Theme.textMuted)
        button.borderColor = cloneColor(Theme.borderSoft)
        button.backgroundColor = cloneColor(Theme.disabled)
    end
    button.textColorDisable = cloneColor(Theme.textMuted)
end

function Theme.applyButton(button, selected)
    if not button then
        return
    end
    button.backgroundColor = cloneColor(selected and Theme.selectedSoft or Theme.surface)
    button.backgroundColorMouseOver = cloneColor(Theme.surfaceRaised)
    button.backgroundColorPressed = nil
    button.borderColor = cloneColor(selected and Theme.accent or Theme.borderSoft)
    button.textColor = cloneColor(Theme.text)
    button.textColorMouseOver = cloneColor(Theme.text)
    button.textColorDisable = cloneColor(Theme.textMuted)
    Theme.lockButtonColors(button)
    Theme.setButtonEnabled(button, button.enable ~= false)
end

function Theme.applyActionButton(button, enabled, primary)
    if not button then
        return
    end
    button.backgroundColor = cloneColor(primary and Theme.primary or Theme.surface)
    button.backgroundColorMouseOver = cloneColor(primary and Theme.primaryHover or Theme.surfaceRaised)
    button.backgroundColorPressed = nil
    button.borderColor = cloneColor(primary and Theme.accent or Theme.borderSoft)
    button.textColor = cloneColor(Theme.text)
    button.textColorDisable = cloneColor(Theme.textMuted)
    Theme.lockButtonColors(button)
    Theme.setButtonEnabled(button, enabled == true)
end

return Theme
