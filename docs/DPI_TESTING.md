# Cross-Platform DPI Testing Guide

This document describes the manual testing procedures for verifying DPI/high-DPI behavior across macOS and Windows platforms.

## Overview

GUI testing for DPI behavior cannot be fully automated in CI (no display available). This guide provides testing procedures and checklists for contributors making changes that affect rendering or scaling.

## Testing Environment Setup

### macOS Requirements

- Mac with Retina display (MacBook Pro/Air, iMac 4K/5K)
- Optionally: external non-Retina display for multi-monitor testing
- macOS 12+ recommended

### Windows Requirements

- Windows 10 (version 1703+) or Windows 11
- Display with scaling support
- Optionally: multiple monitors with different DPI settings

## Test Scenarios

### Scenario 1: Fresh Launch (Single Monitor)

| Platform | Scale | Test Steps | Expected Result |
|----------|-------|------------|-----------------|
| macOS Retina | 2.0x | Launch app | Crisp text, correctly sized UI |
| macOS non-Retina | 1.0x | Launch app | Normal size, crisp text |
| Windows 100% | 1.0x | Launch app | Normal size, crisp text |
| Windows 125% | 1.25x | Launch app | Scaled UI, crisp text |
| Windows 150% | 1.5x | Launch app | Scaled UI, readable text |
| Windows 200% | 2.0x | Launch app | Double-sized UI, crisp text |

### Scenario 2: Window Interactions

For each platform/scale combination:

1. **Window Resize**
   - Resize window by dragging edges
   - Verify UI elements reflow correctly
   - Verify no rendering artifacts

2. **Menu Interactions**
   - Open File menu
   - Verify menu renders at correct scale
   - Verify mouse hover highlights correct items

3. **Dialog Windows**
   - Open "New Project" dialog
   - Verify dialog is correctly scaled
   - Verify input fields work correctly

4. **Tree View**
   - Open a project with multiple folders
   - Expand/collapse folders
   - Verify icons and text align correctly

### Scenario 3: Multi-Monitor (if available)

1. Launch app on primary monitor
2. Move window to secondary monitor (different DPI)
3. Verify:
   - A warning dialog appears if DPI changed significantly
   - Mouse coordinates still accurate
4. Move window back to primary
5. Restart app to verify UI returns to original scale

### Scenario 4: Runtime Scale Change

**macOS:**
1. Launch app
2. System Preferences > Displays > Resolution
3. Change to scaled resolution
4. Verify app shows warning about scale change

**Windows:**
1. Launch app
2. Settings > Display > Scale
3. Change scale factor
4. Verify app shows warning about scale change

## Visual Verification Checklist

### Text Quality
- [ ] Default font is crisp, not blurry
- [ ] Font size is comfortable to read
- [ ] No double-rendering or ghosting

### UI Elements
- [ ] Buttons are correctly sized
- [ ] Spacing between elements is consistent
- [ ] Borders/separators are visible
- [ ] Scrollbars are usable size

### Icons
- [ ] FontAwesome icons render correctly
- [ ] Icons align with adjacent text
- [ ] No clipping or overflow

### Mouse Interaction
- [ ] Click targets match visual elements
- [ ] Hover states trigger at correct positions
- [ ] Drag operations work correctly

## Known Limitations

1. **Dynamic Font Scaling**: Full dynamic font rebuilding when DPI changes at runtime requires an app restart. A warning dialog is shown when this occurs.

2. **Fractional Scaling Artifacts**: At 125%/175% scaling, some text may appear slightly soft due to subpixel positioning.

3. **Runtime DPI on Older Windows**: Windows 10 before version 1703 may require app restart for DPI changes.

4. **Linux/Wayland**: Not currently tested or supported.

## How to Report Issues

When reporting a DPI-related bug, include:

1. **Platform**: OS version (e.g., Windows 11 23H2, macOS 14.2)
2. **Display**: Resolution and scale factor
3. **Screenshot**: Showing the visual issue
4. **Steps**: Exact reproduction steps
5. **Expected vs Actual**: What should happen vs what does happen

## Implementation Notes

This testing should be performed:
- Before any release
- After changes to `main.zig` rendering code
- After updates to zgui/zglfw dependencies
- After changes to font loading

## Technical Details

### Windows DPI Awareness

The application includes a Windows manifest (`assets/labelle-gui.manifest`) that declares Per-Monitor V2 DPI awareness. This ensures:
- Correct rendering on high-DPI Windows displays
- No bitmap scaling/blurriness
- Proper window sizes on high-DPI displays

### Content Scale Callback

The application registers a GLFW content scale callback that detects when the window moves to a monitor with different DPI. Since full dynamic font rebuilding is complex with the current zgui backend, users are notified to restart the application for best results.

### Framebuffer Scaling

The application manually calculates and sets the framebuffer scale to ensure correct rendering on Retina/HiDPI displays while maintaining accurate mouse coordinates.
