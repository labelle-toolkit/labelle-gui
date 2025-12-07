-- Color Script
-- A script that manages color data

Plugin = {
    name = "color_script",
    display_name = "Lua Color Picker",
    version = "1.0.0",
    plugin_type = "color"
}

-- Color state (RGBA)
r = 1.0
g = 0.5
b = 0.2
a = 1.0
brightness = 1.0

function Plugin.on_init()
    print("[LuaColor] Initialized!")
end

function Plugin.on_deinit()
    print("[LuaColor] Deinitialized!")
end

function Plugin.get_color()
    return r, g, b, a
end

function Plugin.set_color(new_r, new_g, new_b, new_a)
    r = math.max(0, math.min(1, new_r or r))
    g = math.max(0, math.min(1, new_g or g))
    b = math.max(0, math.min(1, new_b or b))
    a = math.max(0, math.min(1, new_a or a))
end

function Plugin.get_brightness()
    return brightness
end

function Plugin.set_brightness(value)
    brightness = math.max(0, math.min(2, value))
end

-- Preset colors
function Plugin.set_red()
    r, g, b, a = 1.0, 0.0, 0.0, 1.0
end

function Plugin.set_green()
    r, g, b, a = 0.0, 1.0, 0.0, 1.0
end

function Plugin.set_blue()
    r, g, b, a = 0.0, 0.0, 1.0, 1.0
end

function Plugin.set_white()
    r, g, b, a = 1.0, 1.0, 1.0, 1.0
end

return Plugin
