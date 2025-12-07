-- Notepad Script
-- A simple text editor script

Plugin = {
    name = "notepad_script",
    display_name = "Lua Notepad",
    version = "1.0.0",
    plugin_type = "notepad"
}

-- Text content
text = "Welcome to Lua Notepad!\n\nThis is a simple text editor powered by a Lua script.\n\nYou can:\n- Type and edit text\n- Clear all content\n- See character/line count"
word_wrap = true
line_count = 0
char_count = 0

function Plugin.on_init()
    print("[LuaNotepad] Initialized!")
    update_stats()
end

function Plugin.on_deinit()
    print("[LuaNotepad] Deinitialized!")
end

function Plugin.get_text()
    return text
end

function Plugin.set_text(new_text)
    text = new_text or ""
    update_stats()
end

function Plugin.clear()
    text = ""
    update_stats()
end

function Plugin.get_word_wrap()
    return word_wrap
end

function Plugin.set_word_wrap(enabled)
    word_wrap = enabled
end

function Plugin.get_stats()
    return char_count, line_count
end

function update_stats()
    char_count = #text
    line_count = 1
    for i = 1, #text do
        if text:sub(i, i) == "\n" then
            line_count = line_count + 1
        end
    end
end

return Plugin
