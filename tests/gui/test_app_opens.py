"""
SikuliX test to verify the Labelle GUI application opens correctly on Linux.
Run with: java -jar sikulixide.jar -r test_app_opens.py
"""

import sys
import time
import os

# SikuliX imports
from sikuli import *

# Configuration
TIMEOUT = 10  # seconds to wait for app to open

def main():
    """Test that the application window opens successfully."""
    print("=== Labelle GUI - SikuliX Test ===")
    print("Starting application...")

    # Get the app path from environment or use default
    app_path = os.environ.get("LABELLE_APP_PATH", "./zig-out/bin/labelle-gui")

    # Start the application
    try:
        app = App.open(app_path)
        print(f"Launched: {app_path}")
    except Exception as e:
        print(f"FAILED: Could not start application: {e}")
        sys.exit(1)

    # Give the app time to initialize
    time.sleep(3)

    # Check if window exists by looking for "Labelle" in window title
    try:
        # Try to find the app window
        labelle_window = App("Labelle")
        if labelle_window.window():
            print("SUCCESS: Found Labelle window!")

            # Take a screenshot for verification
            screenshot_path = capture(SCREEN)
            print(f"Screenshot saved: {screenshot_path}")

            # Close the app gracefully
            labelle_window.close()
            print("Application closed.")
            sys.exit(0)
        else:
            print("FAILED: Window not found")
            sys.exit(1)
    except Exception as e:
        print(f"FAILED: Error checking window: {e}")
        # Take debug screenshot
        try:
            capture(SCREEN, "debug_screenshot.png")
        except:
            pass
        sys.exit(1)

if __name__ == "__main__":
    main()
