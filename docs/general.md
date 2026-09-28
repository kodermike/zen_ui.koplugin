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

ZenOS records the battery percentage every 30 minutes while awake, and when the device sleeps, wakes, or changes charging state. It keeps the most recent 512 samples, with no calendar cutoff. Drain rates divide the total percentage points lost by the elapsed hours between samples: for example, a 5-point drop in 2 hours is 2.5% per hour. Overall, awake, and asleep rates use the same calculation on their respective intervals. Charging intervals and gaps while KOReader was closed are excluded from both drain rates and usage times; rising battery readings are excluded from drain rates. Screen on and off time total the remaining awake and asleep intervals, so they are approximations rather than direct screen measurements.

Estimated time remaining divides the current percentage by the overall drain rate; it is unavailable until there is usable discharge history. Time since last charge starts when charging stops. If ZenOS cannot establish that time, the value is unavailable. Reset battery log clears the samples and last-charge time.

Current, full, and design capacity in mAh appear only when the device reports charge values. ZenOS converts reported microamp-hours to mAh and subtracts the matching empty thresholds when available. Battery health is full capacity divided by design capacity, multiplied by 100; battery percentage alone cannot provide capacity or health.

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
