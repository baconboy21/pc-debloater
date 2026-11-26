# Testing checklist (do this BEFORE you release)

Test in a **virtual machine**, not your real PC. VirtualBox (free) or Hyper-V (built into Windows Pro) both work.
Take a VM **snapshot** before each test so you can jump back to a clean Windows in seconds.

Set up these VMs if you can:
- [ ] Windows 11 (newest version), fresh install
- [ ] Windows 10 22H2, fresh install
- [ ] One "messy" one with Steam, Epic, Minecraft, Discord, Spotify, Chrome and some trial junk installed

## 1. Starting the app
- [ ] Double-clicking the .bat **inside the zip** shows the "extract it first" message
- [ ] After extracting, the .bat asks for admin → click **No** → you see the friendly "needs admin" message
- [ ] Click **Yes** → the welcome screen shows (first time only) → Continue stays disabled until you tick the box
- [ ] Second launch: no welcome screen
- [ ] Loading screen shows, then the main window. **No black console window** behind it.
- [ ] Window fits on a small 1366x768 screen

## 2. Every tab
- [ ] Apps: icons show, only installed apps are listed, startup apps show up
- [ ] Privacy, FPS Booster, Wi-Fi & Ethernet, Windows Tweaks: rows show in the right tab
- [ ] FPS Booster finds the games you installed
- [ ] My PC and Drivers: CPU / GPU / RAM are right, the driver check finishes, the brand buttons open the right page or app
- [ ] Search box filters rows and jumps to the right tab
- [ ] Quick picks tick the right stuff (Gamer on a laptop skips the power plan)

## 3. Debloat
- [ ] **Preview** lists everything and changes nothing
- [ ] Debloat with **Recommended** → restore point gets made → progress bar moves → **window never says "Not Responding"**
- [ ] Try to close the window while it's working → it says "Still working"
- [ ] Log opens on the Desktop and makes sense
- [ ] After restart: Start menu, search, taskbar, Settings, Store, Wi-Fi, sound and printing all still work
- [ ] Minecraft (Java + Bedrock), Fortnite, Steam games, Discord and Spotify still launch
- [ ] Reopen the app → red DELETED / green TWEAKED tags show

## 4. The careful stuff (one at a time, snapshot before each)
- [ ] Edge removal (with Chrome installed) → Edge gone, other apps still work
- [ ] OneDrive removal
- [ ] Remove old unused features + deep clean (slow - window must stay responsive)
- [ ] Each Wi-Fi / Ethernet tweak → internet still works

## 5. Undo
- [ ] Reinstall / Undo lists everything you did
- [ ] Bring back an app, OneDrive, Edge, a startup app and a few settings → they come back
- [ ] Reopen the app → the tags for undone stuff are gone

## 6. Errors
- [ ] Turn off the VM's internet → driver check shows a friendly message (no crash)
- [ ] If anything ever crashes → an error report appears on the Desktop

## 7. Before you publish
- [x] Put your GitHub link in `$ProjectUrl` at the top of `PC-Debloater.ps1`
- [x] Put your name in `LICENSE`
- [ ] Add screenshots to `README.md`
- [ ] Bump `$AppVersion` and update `CHANGELOG.md` for every new release
