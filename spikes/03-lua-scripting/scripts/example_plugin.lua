-- Example Lua Plugin for Labelle
-- This demonstrates how a Lua script can define panels and menus

Plugin = {
    name = "lua_example",
    display_name = "Lua Example Plugin",
    version = "1.0.0"
}

-- Called when the plugin is loaded
function Plugin.on_init()
    print("[LuaPlugin] Initialized!")
end

-- Called when the plugin is unloaded
function Plugin.on_deinit()
    print("[LuaPlugin] Deinitialized!")
end

-- Called to render menu items
function Plugin.render_menu()
    print("[LuaPlugin] Rendering menu")
    -- In real implementation, this would call imgui functions
    -- imgui.menu_item("My Lua Tool")
end

-- Called to render panel content
function Plugin.render_panel()
    print("[LuaPlugin] Rendering panel")
    -- In real implementation, this would call imgui functions
    -- imgui.text("Hello from Lua!")
    -- if imgui.button("Click me") then
    --     print("Button clicked!")
    -- end
end

return Plugin
