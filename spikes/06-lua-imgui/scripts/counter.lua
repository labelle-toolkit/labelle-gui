-- Counter Script
-- A simple script that maintains a counter value

Plugin = {
    name = "counter_script",
    display_name = "Lua Counter",
    version = "1.0.0",
    plugin_type = "counter"
}

-- Script state
counter = 0
min_value = -100
max_value = 100
step = 1

function Plugin.on_init()
    print("[LuaCounter] Initialized!")
    counter = 0
end

function Plugin.on_deinit()
    print("[LuaCounter] Deinitialized! Final count: " .. counter)
end

-- Called by host to get current state
function Plugin.get_counter()
    return counter
end

function Plugin.set_counter(value)
    counter = value
    if counter < min_value then counter = min_value end
    if counter > max_value then counter = max_value end
end

function Plugin.increment(amount)
    Plugin.set_counter(counter + (amount or step))
end

function Plugin.decrement(amount)
    Plugin.set_counter(counter - (amount or step))
end

function Plugin.reset()
    counter = 0
end

return Plugin
