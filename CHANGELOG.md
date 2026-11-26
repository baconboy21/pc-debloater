# Changelog

## v1.1.1
- Tabs stay in place now: a fixed 2 rows of 3, they no longer jump around when you click one.

## v1.1.0 - quality of life
- New "Select all (every tab)" and "Select none (every tab)" buttons (select all asks first if it would tick CAREFUL stuff)
- Tabs show how many you picked, like "Apps (3 of 15)"
- "My last picks" button re-ticks what you picked last time
- Rows light up when your mouse is over them
- Clear-search X button, Ctrl+F to search, Esc to clear, Ctrl+1 to Ctrl+6 to switch tabs
- Remembers the window size and position
- The window pops to the front and dings when a long job finishes

## v1.0.6
- Fixed for real: "Select all / none in this tab" was still changing every tab. It now checks which tab you are on by the tab's own name.
- Search tab counts use the same safer check.

## v1.0.5
- Quick pick buttons stay usable while the driver check runs.
- The app now tells you when buttons are paused because it is busy (instead of them just looking broken).

## v1.0.4
- "Select all" and "Select none" now only change the tab you are looking at (and only what your search shows), not every tab.

## v1.0.3
- Fixed: the app crashed with "Collection was of a fixed size" when you opened it again after debloating (reading the undo history).

## v1.0.2
- Backups: only ONE restore point is ever made, the first time ("Before PC Debloater (original)"). Every debloat and driver update after that reuses it. If Windows deletes it by itself, a new one is made so you are never left without a backup.

## v1.0.1
- Fixed: "Get newest ... driver (step by step)" and "Reinstall / Undo" windows crashed with a "PROPERTYELEMENT" error.

## v1.0.0 - first public release

**Debloat**
- Removes 100+ junk apps (only shows the ones actually on your PC), with real app icons
- Removes trial junk programs (McAfee, Norton, WildTangent, Office trial...), OneDrive and Microsoft Edge (optional, careful)
- Startup apps list - stop programs opening when your PC turns on
- Safe / Your call / Careful tags on everything

**Privacy & Ads**
- Telemetry, advertising ID, Start menu + lock screen ads, Bing in search, Copilot, Recall, Widgets, activity history, tracking tasks, Edge debloat and more

**FPS Booster**
- Finds your games (Steam, Epic, Riot, Minecraft Java + Bedrock, Roblox...) and gives them your best GPU + high CPU priority
- Game Mode, GPU scheduling, mouse acceleration off, Ultimate Performance power plan and more
- In-game settings tips for each game in your log

**Wi-Fi & Ethernet**
- Power saving off, 5 GHz, roaming, full speed, lower latency, faster DNS, lower ping

**Windows Tweaks**
- Useless services off, no surprise restarts, old risky features removed, taskbar cleanup, free up space

**My PC and Drivers**
- Shows your CPU, GPU and RAM
- Checks Windows Update for driver updates (asks you twice before installing)
- Step-by-step guides that open NVIDIA / AMD / Intel's official updater for you

**Safety**
- Welcome screen, safety checks (work/school PCs, Windows Server, old Windows, low disk space, pending restart)
- Restore point before every debloat
- Preview mode - see exactly what will happen without changing anything
- Reinstall / Undo - bring back apps, programs, startup apps and settings
- Red DELETED / green TWEAKED tags remember what you already did
- Warns you when Windows puts junk back
- Logs on your Desktop for everything, error reports if something breaks
- Window never freezes (slow stuff runs in the background)
