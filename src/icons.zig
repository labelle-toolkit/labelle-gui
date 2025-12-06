// FontAwesome 6 Solid Icons
// Icon codes from https://fontawesome.com/icons

/// FontAwesome icon range for ImGui font loading
pub const FA_ICON_MIN: u16 = 0xe000;
pub const FA_ICON_MAX: u16 = 0xf8ff;

/// Icon glyph ranges for font loading (null-terminated pairs)
pub const FA_ICON_RANGES = [_:0]u16{ FA_ICON_MIN, FA_ICON_MAX, 0 };

// Folder/File icons
pub const FA_FOLDER = "\u{f07b}"; // folder
pub const FA_FOLDER_OPEN = "\u{f07c}"; // folder-open
pub const FA_FILE = "\u{f15b}"; // file
pub const FA_FILE_CODE = "\u{f1c9}"; // file-code

// Project folder icons
pub const FA_CUBE = "\u{f1b2}"; // cube (for 3D models)
pub const FA_WRENCH = "\u{f0ad}"; // wrench (for fixtures)
pub const FA_BOX = "\u{f466}"; // box (for prefabs)
pub const FA_SCROLL = "\u{f70e}"; // scroll (for scripts)
pub const FA_DATABASE = "\u{f1c0}"; // database (for resources)

// Common UI icons
pub const FA_PLUS = "\u{2b}"; // plus
pub const FA_MINUS = "\u{f068}"; // minus
pub const FA_TIMES = "\u{f00d}"; // times/close
pub const FA_CHECK = "\u{f00c}"; // check
pub const FA_SAVE = "\u{f0c7}"; // floppy-disk (save)
pub const FA_UNDO = "\u{f0e2}"; // undo
pub const FA_REDO = "\u{f01e}"; // redo
