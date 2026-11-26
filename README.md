# PC Debloater

A free, open-source app that cleans up Windows 10 and 11. Pick what you want gone, keep the rest, and get a log of everything it did.

- 🧹 **Debloat:** junk apps, trial programs, OneDrive, Edge (optional) and startup apps
- 🔒 **Privacy:** turns off tracking, ads, Copilot, Recall and Bing in search
- 🎮 **FPS Booster:** finds your games and gives them your best GPU and more CPU priority
- 📶 **Wi-Fi & Ethernet:** fixes lag spikes, faster DNS, lower ping
- 🖥️ **My PC and Drivers:** shows your hardware and helps you update drivers safely
- ↩️ **Reinstall / Undo:** brings almost everything back if you change your mind

> **Screenshots:** _add a few screenshots of the app here before you release it._

---

## How to use it

1. **Download** the latest `PC-Debloater.zip` from the [Releases](../../releases) page.
2. **Right-click the zip → Extract All.** Don't run it from inside the zip.
3. Open the folder and **double-click `Run PC Debloater.bat`**.
4. Click **Yes** when Windows asks for admin permission. The app needs it to remove apps and change settings.
5. Tick what you want gone, or press a **Quick pick** (Gamer / Max privacy / Light clean).
6. Not sure? Press **Preview (changes nothing)** to see exactly what will happen.
7. Press **Debloat**. You'll get a log on your Desktop and it'll ask if you want to restart.

### "Windows protected your PC" / antivirus warning
Windows shows this for most free tools that aren't paid-signed. Click **More info → Run anyway**.
The code is right here, so you can read every line. If your antivirus flags it, that's because the app changes the registry and removes apps, which is exactly what debloaters do.

---

## What the colors mean

| Tag | Meaning |
|---|---|
| 🟢 **SAFE** | Junk almost nobody needs. Ticked by default. |
| 🔵 **YOUR CALL** | Harmless to remove, but you might use it. |
| 🟠 **CAREFUL** | Can break stuff (for example, the Xbox app is needed for Minecraft and Game Pass). |
| 🔴 **DELETED** | You already removed this. Use Reinstall / Undo to bring it back. |
| 🟩 **TWEAKED** | You already changed this setting. |

---

## Safety

- **One backup, once.** The first time you debloat, it makes ONE restore point called "Before PC Debloater (original)". That's your PC exactly how it was before. After that it reuses that one instead of making new ones.
- **Reinstall / Undo** can bring back:
  - Store apps (reinstalled, or their Store page opens so you can click Get)
  - OneDrive and Edge (reinstalled automatically)
  - other programs (their official website opens)
  - startup apps and every setting it changed
- **Can't be undone:** cleaned temp files, the emptied Recycle Bin, and Windows Update leftovers. Those are deleted.
- **Never touched:** Microsoft Store, Calculator, normal Paint, Notepad, Terminal, Windows Security, Xbox sign-in parts and the Edge WebView2 runtime (lots of apps need it).
- **It checks before it starts** and warns you about:
  - work/school PCs
  - Windows Server
  - old Windows versions
  - low disk space
  - a pending Windows Update restart
- **Driver updates ask you twice** before installing anything.

### Undo everything at once
Start → type **"Create a restore point"** → **System Restore** → pick **"Before PC Debloater (original)"**.

---

## Privacy

PC Debloater **does not collect, track or send any data**. It only goes online to:
- check Windows Update for driver updates (Microsoft's own Windows Update)
- open official pages (NVIDIA, AMD, Intel, Microsoft Store...) when **you** click a button

---

## Where it saves stuff

| What | Where |
|---|---|
| Debloat / undo / driver logs | Your Desktop (plus a copy in `C:\ProgramData\PC Debloater\logs`) |
| Undo history | `C:\ProgramData\PC Debloater\history.json` |
| Error reports | Your Desktop (`PC-Debloater-ERROR_....txt`) |

### Removing PC Debloater itself
1. If you turned on "Warn me when Windows puts junk back", turn it off first with **Reinstall / Undo**.
2. Delete the app folder and `C:\ProgramData\PC Debloater`.

---

## FAQ

**Will it break Minecraft / Fortnite / my games?**
No. The Xbox stuff Minecraft needs is marked CAREFUL and isn't ticked. The FPS Booster only changes GPU and priority settings, and you can undo those.

**Something got removed that I wanted!**
Open the app → **Reinstall / Undo** → tick it → **Bring back selected**.

**Windows put an app back after an update.**
That happens with big Windows updates. Open the app again. It shows a yellow warning and lets you remove it again. You can also turn on "Warn me when Windows puts junk back" in Windows Tweaks.

**Edge didn't uninstall.**
Microsoft blocks it on some PCs. Nothing breaks. Use "Debloat Microsoft Edge" in Privacy & Ads instead.

**The app froze / crashed.**
An error report is saved to your Desktop. Please [open an issue](../../issues) and attach it.

---

## Reporting bugs
[Open an issue](../../issues) and include:
- your Windows version (Start → type `winver`)
- the error report from your Desktop, or the Debloat log
- what you clicked before it broke

---

## Legal

- Released under the [MIT License](LICENSE). Free to use, no warranty, **use at your own risk**.
- PC Debloater is **not made by or affiliated with** Microsoft, NVIDIA, AMD, Intel, Valve, Epic Games, Mojang or any other company or product it mentions. All product names and trademarks belong to their owners.
- The app shows icons that come from programs already installed on your own PC. It doesn't include any company logos.
