/// Application configuration constants
/// UI layout and styling values used across the application

pub const ui = struct {
    /// Width of the left sidebar panel in pixels
    pub const sidebar_width: f32 = 250.0;

    /// Height of the status bar at the bottom in pixels
    pub const status_bar_height: f32 = 30.0;

    /// Default window dimensions
    pub const default_window_width: u32 = 1280;
    pub const default_window_height: u32 = 720;

    /// Font size base (will be scaled by display scale factor)
    pub const base_font_size: f32 = 16.0;

    /// Status message display duration in seconds
    pub const status_message_duration: f32 = 3.0;
};
