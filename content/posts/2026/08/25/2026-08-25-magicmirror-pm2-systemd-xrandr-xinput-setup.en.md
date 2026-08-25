---
title: "Auto-Start Control, Screen Rotation, and Touch Coordinate System Calibration in MagicMirror²"
slug: "magicmirror-pm2-systemd-xrandr-xinput-setup"
date: 2026-08-25T10:10:42+09:00
draft: false
image: ""
description: "Explains process auto-start control using PM2 and Systemd, asynchronous screen and touch coordinate system transformation via xrandr and xinput, and module customization procedures in a MagicMirror² environment."
categories: ["Linux System Admin"]
tags: ["magicmirror2", "pm2", "systemd", "xrandr", "xinput"]
author: "K-Life Hack"
---

In the operation of embedded displays and smart mirror platforms, automatic process recovery at OS boot and synchronous control of screen display are critical. If a front-end application launches before the network interface is enabled, asynchronous requests to external RSS feeds or APIs may fail, posing a risk of rendering errors. Furthermore, when installing an LCD panel in portrait orientation or inverted (upside down), changing only the display output (`xrandr`) leaves the input coordinate system of the touch panel (`xinput`) out of sync, causing the operation axes to invert.


This article outlines the design of a delayed start sequence combining PM2 and Systemd, display rotation settings, calibration of the touch Coordinate Transformation Matrix, and module code modification procedures.



## 1. Process Auto-Start and System Daemon Configuration

To ensure application process liveness checks and automatic recovery upon OS reboot, a management configuration using PM2 and Systemd is introduced.

### Global Installation and Initialization of PM2

Install PM2 to handle process management in the Node.js environment.



```bash
sudo npm install -g pm2
```

To register PM2 as an OS startup daemon, execute the following command and run the generated Systemd registration command in the terminal.



```bash
pm2 startup
```

### Creating a Delayed Launch Script (mm.sh)

To prevent the application from starting before a network connection is established, create an execution script with a buffer delay in the user's home directory.



```bash
cd ~
nano mm.sh
```

The internal implementation of the script is as follows. Inserting `sleep 10` waits for the acquisition of the Wi-Fi/Ethernet IP address to complete, while `DISPLAY=:0` explicitly binds the output target of the X11 session.



```bash
#!/bin/bash
sleep 10
cd ./MagicMirror
DISPLAY=:0 npm start
```

Grant execution permissions.



```bash
chmod +x mm.sh
```

### Saving Process State and Systemd Control

Persist the process state started with PM2.



```bash
pm2 save
```

Commands to enable or disable auto-start as a Systemd service are as follows.



```bash
# Enable startup
sudo systemctl enable magicmirror.service

# Disable startup
sudo systemctl disable magicmirror.service
```

## 2. Display Power Control and Static Syntax Analysis

In a continuously operating signage environment, it is necessary to prevent OS default screensavers and power-saving blackouts.



### Disabling Sleep Features

Install `xscreensaver` and change the screensaver and display blanking functions to "Disable Screen Saver" via the GUI settings screen or configuration file.



```bash
sudo apt install xscreensaver
```

### Syntax Check of Configuration File (config.js)

Syntax errors in `config/config.js` (unclosed brackets, missing or extra commas) cause runtime errors. Before deployment, pass the source code through a static analysis tool (such as JSHint) to verify syntax correctness.



## 3. Display and Touch Coordinate Synchronization via xrandr and xinput

When changing the physical display layout, the coordinate transformation matrix of the X11 display output (`xrandr`) and the touch input device (`xinput`) must be synchronized.



### Rotating Standard HDMI Output (xrandr)

Command parameters for rotation settings on the `HDMI-1` device.



```bash
# Normal display (landscape)
xrandr --output HDMI-1 --rotate normal

# Rotate 90 degrees left (portrait)
xrandr --output HDMI-1 --rotate left

# Rotate 90 degrees right (portrait)
xrandr --output HDMI-1 --rotate right

# Rotate 180 degrees (inverted)
xrandr --output HDMI-1 --rotate inverted
```

### Touch Panel Coordinate System Calibration (xinput)

When using a DSI-connected touch display (e.g., `FT5406 memory based driver`), the `Coordinate Transformation Matrix` (3x3 matrix) must be calculated and configured to match the screen rotation.



#### 1. Normal Orientation (normal)

```bash
xrandr --output DSI-1 --rotate normal
xinput --set-prop "FT5406 memory based driver" "Coordinate Transformation Matrix" 0 0 0 0 0 0 0 0 0
```

#### 2. 90-Degree Counterclockwise Rotation (left)

```bash
xrandr --output DSI-1 --rotate left
xinput --set-prop "FT5406 memory based driver" "Coordinate Transformation Matrix" 0 -1 1 1 0 0 0 0 1
```

#### 3. 90-Degree Clockwise Rotation (right)

```bash
xrandr --output DSI-1 --rotate right
xinput --set-prop "FT5406 memory based driver" "Coordinate Transformation Matrix" 0 1 0 -1 0 1 0 0 1
```

#### 4. 180-Degree Inverted Orientation (inverted)

```bash
xrandr --output DSI-1 --rotate inverted
xinput --set-prop "FT5406 memory based driver" "Coordinate Transformation Matrix" -1 0 1 0 -1 1 0 0 1
```

## 4. Source Code Modification of MMM-BackgroundSlideshow Module

This is a refactoring example to disable header text ("Picture Info") and image count information (e.g., "1 of 10") on the screen for the background slideshow display module `MMM-BackgroundSlideshow`.


Target file: `MMM-BackgroundSlideshow.js`



### Code Before Modification

```javascript
case 'imagecount':
    imageProps.push(`${this.imageIndex} of ${this.imageList.length}`);
    break;
default:
    Log.warn(prop + ' is not a valid value for imageInfo. Please check your configuration');
}
});

let innerHTML = '<header class="infoDivHeader">Picture Info</header>';
imageProps.forEach((val, idx) =&gt; {
    innerHTML += val + '<br/>';
});
```

### Code After Modification

Hiding the UI elements is achieved by commenting out the array push operations and replacing the initial `innerHTML` value with an empty string.



```javascript
case 'imagecount':
    // Disable array insertion to hide count information
    // imageProps.push(`${this.imageIndex} of ${this.imageList.length}`);
    break;
default:
    Log.warn(prop + ' is not a valid value for imageInfo. Please check your configuration');
}
});

// Completely remove header text
let innerHTML = '';
imageProps.forEach((val, idx) =&gt; {
    innerHTML += val + '<br/>';
});
```

## 5. Troubleshooting

### Startup Failure Due to Unbound Display (DISPLAY Environment Variable Issue)

💡 <b>Symptom</b>: `Error: Cannot open display: null` occurs during startup via Systemd or Cron, preventing the Electron window from opening.


🛠️ <b>Cause</b>: When executing processes from a non-interactive shell environment, the X11 display environment variable `$DISPLAY` is not defined.


⚠️ <b>Solution</b>: Explicitly declare `export DISPLAY=:0` inside the execution script such as `mm.sh` before running the commands.



### Touch Panel Axis Mismatch (xinput Matrix Mismatch)

💡 <b>Symptom</b>: The screen display switches to vertical orientation, but touching the top of the screen moves the cursor to the right side.


🛠️ <b>Cause</b>: Only graphic output rotation via `xrandr` was applied, and the transformation matrix on the input kernel driver side was not updated.


⚠️ <b>Solution</b>: Confirm the device identifier name with `xinput list`, and reapply the `Coordinate Transformation Matrix` parameter corresponding to the rotation angle.



## 6. System Verification Logs

An example terminal log verifying process running status, X11 display assignment status, and input device property consistency post-deployment.



```text
$ pm2 status
┌────┬─────────────────┬─────────────┬─────────┬─────────┬─────────┬────────┬─────┬───────────┬──────────┬──────────┐
│ id │ name            │ namespace   │ version │ mode    │ pid     │ uptime │ ↺   │ status    │ cpu      │ mem      │
├────┼─────────────────┼─────────────┼─────────┼─────────┼─────────┼────────┼─────┼───────────┼──────────┼──────────┤
│ 0  │ magicmirror     │ default     │ 2.25.0  │ fork    │ 2104    │ 12m    │ 0   │ online    │ 1.2%     │ 142.5MB  │
└────┴─────────────────┴─────────────┴─────────┴─────────┴─────────┴────────┴─────┴───────────┴──────────┴──────────┘

$ xrandr --query
Screen 0: minimum 320 x 200, current 1080 x 1920, maximum 7680 x 7680
DSI-1 connected primary 1080x1920+0+0 right (normal left inverted right x axis y axis) 154mm x 85mm
   1080x1920     60.00*+

$ xinput list-props "FT5406 memory based driver"
Device 'FT5406 memory based driver':
	Device Enabled (115):	1
	Coordinate Transformation Matrix (117):	0.000000, 1.000000, 0.000000, -1.000000, 0.000000, 1.000000, 0.000000, 0.000000, 1.000000
```

## 7. Lessons Learned

For stable operation of embedded signage environments, it is critical to comprehensively understand not only the software layer (PM2/Node.js) but also the interdependencies among the OS display subsystem (X11/xrandr) and input device drivers (xinput). In particular, considering race conditions during startup until the network and display server are fully initialized during the design phase significantly mitigates unnecessary reboot issues post-field deployment.

