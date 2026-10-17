# Desktop Icons App

A Windows PowerShell WinForms app specifically designed for OLED monitors. It can show desktop icons only in selected screen areas and hide the system cursor after it has been idle.

## Requirements

- Windows with Windows PowerShell 5.1
- The app uses the primary display, refreshes its screen measurements when Windows reports a display-settings change, and requires no additional dependencies.

## Install and run

Download or copy `IconsAndMouse.ps1` to a folder on your computer. Open PowerShell in that folder and run:

```powershell
powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File ".\IconsAndMouse.ps1"
```

The execution-policy bypass in this command applies only to the launched PowerShell process; it does not change your system-wide policy. Review the script before running it, especially if you obtained it from someone else.

## Use

In the screen preview, drag to add areas where desktop icons should be visible. Select an area and choose **Remove selected** to delete it. With **Show desktop icons only inside these areas** enabled, icons appear while the pointer is inside an area and hide after the configured delay outside all areas.

Enable **Hide cursor when idle** to hide the system cursor after the configured idle time. Mouse movement or a button press restores it.

Choose **Start** to apply the selected behavior. **Stop** restores the desktop icon visibility that was in effect when you started, restores system cursors, and stops any headless sign-in instance. Closing the window minimizes the app to the notification area; use the notification-area **Exit** menu to quit and restore the desktop state.

Choose one of the **Start with Windows** options to create a shortcut in the current user's Startup folder:

- **With notification-area icon** starts the desktop effects silently, without opening a window. The notification-area icon is available to open the settings window.
- **No notification-area icon** starts the desktop effects silently in the background, without a window or notification-area icon. Open the app manually to change settings or stop it.

The options are mutually exclusive; uncheck the selected option to disable automatic startup. The startup shortcut uses Windows Script Host to launch PowerShell without briefly opening a console window. Existing shortcuts are updated to this silent launcher when you next open the app. A second manual launch brings the existing settings window forward, and the app prevents multiple instances of the desktop effects from running.

## Mouse polling and responsiveness

While the desktop effects are running, the app checks the pointer position and mouse buttons on a 250 ms timer (about 6–7 checks per second). To adjust the responsiveness-versus-polling tradeoff, edit `$script:timer.Interval` in `IconsAndMouse.ps1` (the value is in milliseconds), then restart the app.  
A shorter interval checks more often and can respond sooner, at the cost of more frequent polling; a longer interval polls less often but may respond later or miss very brief mouse-button presses. The display resolution is updated from a Windows display-change event, not by this timer.

## Optional wallpaper slideshow

To use changing desktop wallpapers, open **Settings > Personalization > Background** and choose **Slideshow**. Select the folder containing your wallpapers and set the change interval in Windows settings.

For an advanced alternative, the per-user slideshow interval may be adjusted in Registry Editor at:

```text
HKEY_CURRENT_USER\Control Panel\Personalization\Desktop Slideshow
```

Edit the `Interval` DWORD value. For example, hexadecimal `4e20` (decimal `20000`) represents a 20-second interval in milliseconds. Back up the key before editing it, change only the intended value, and note that Windows may apply or interpret this setting differently across versions. This registry setting is optional and is not required by the app.

## Settings and troubleshooting

Settings are saved to `%APPDATA%\DesktopIconsApp\settings.json`. Errors from the headless sign-in instance are logged to `%APPDATA%\DesktopIconsApp\errors.log`.

If the desktop effects fail, open the app and choose **Stop** to restore the desktop state. While the cursor is hidden, a small hidden recovery process monitors the app and restores system cursors if the app exits unexpectedly. If a headless instance reports an error, check the log file above. You can disable automatic startup by unchecking the selected **Start with Windows** option in the app.

## License

This project is licensed under the MIT License. See [LICENSE](./LICENSE).
