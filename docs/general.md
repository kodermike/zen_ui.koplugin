---
title: General
category: General
summary: Manage connectivity, power, language, time, maintenance, and updates.
settingsPath: Zen Settings > General
order: 70
---

## Overview

General contains device and system settings. Use it to manage wireless connections, lighting schedules, sleep, battery information, language and time, maintenance tools, and updates.

## Battery

Battery shows the current charge, estimated drain per hour overall and during awake and asleep periods, screen on and off time, estimated time remaining, and time since the last charge. It also lets you reset the battery log.

Capacity in mAh appears only when the device reports charge capacity. Battery health requires both full and design charge values, with empty thresholds included when available; percentage alone cannot provide either value. ZenOS samples every 30 minutes while awake and at power and sleep changes, keeping up to 512 samples from the last 30 days.

## Schedules and sleep

Schedules can change brightness, night mode, and warmth automatically. Brightness and warmth can follow either a clock schedule or KOReader's light and dark mode, with separate values for each state. Enabling one method turns off the other for that setting. Lighting automation disables KOReader's Auto warmth and night mode plugin to prevent conflicting changes. Warmth options appear only on supported devices.

Sleep provides KOReader sleep screen controls, sleep presets, automatic dimmer, and automatic suspend integrations when available.

## Setting reference

| Setting | Description |
| --- | --- |
| Wi-Fi | Turns wireless networking on or off and opens network controls. |
| Bluetooth | Turns Bluetooth on or off and opens Bluetooth controls on supported devices. |
| Schedules > Brightness | Sets automatic frontlight brightness by time or light and dark mode. |
| Schedules > Night mode schedule | Sets times for automatic night mode changes. |
| Schedules > Warmth | Sets automatic warmth by time or light and dark mode on supported devices. |
| Sleep | Opens available sleep screen and suspend settings. |
| Battery | Shows battery charge, capacity when reported, drain, usage time, and remaining-time estimates; offers a log reset. |
| Language | Selects the KOReader and ZenOS interface language. |
| Time and date | Opens KOReader's date and time settings. |
| Advanced | Opens maintenance, logging, gesture, plugin, and patch tools. See [Advanced](/zen-os/docs/advanced). |
| Updates | Checks for ZenOS and supported KOReader updates and controls update preferences. See [Updates](/zen-os/docs/updates). |
