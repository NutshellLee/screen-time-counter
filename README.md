# Screen-On Time

**English** ｜ [简体中文](README.zh-CN.md)

A treadmill is compelling because it records numbers — work with no feedback is hard to stick with.

Windows will not tell you how long your screen was on today: Task Manager does not have that number, and neither do the Settings.
If you want to know how many hours you spent in front of the machine and how many breaks you took, you would have to use a stopwatch.
This little tool turns that into a single number in the tray.

![Details panel (today)](docs/screenshot-today.png)

**Illustration only: the numbers in the screenshot are sample data, not anyone's actual usage.**

**Who it's for**: anyone who wants to know how many hours they spent in front of the computer, without installing a monitoring suite.

**Why keep it in the tray**

- **Entirely local, no network**: every record stays on this machine.
- **Not a guess**: the time comes from the system's display power notifications — it starts when the screen turns on and stops when it turns off.
- **No leftovers**: no admin rights, no runtime, no system service; deleting one folder removes it completely.
- **Easy to read at a glance**: the tray shows today's office time, and the panel breaks it down by program with a 24-hour timeline.

Version 1.2 ｜ MIT license (see [LICENSE](LICENSE)) ｜ A personal tool; Windows 10/11; no promise it fits your setup

---

## What counts as "in use"

One sentence: **the screen is on, so it counts; the screen goes off, so it stops.**

It does not try to guess whether you are at the machine, and it does not watch the keyboard or mouse.
Every second the screen is on is counted, even if your hands are still, even if you are watching a video or staring at a wall.

A segment starts when the screen turns on (or the program starts) and ends when the screen turns off
(or the program exits, or the machine sleeps).

## What it looks like

- **Icon**: an orange circle showing today's office time as `hours:minutes`.
  ![Icon](docs/icon.png)
- **Hovering** shows today's office time, today's entertainment time, and yesterday's office time.
  ![Tray icon and hover tooltip](docs/tray-tooltip.png)

- **Right-click menu**:

| Item | What it does |
| --- | --- |
| Details | Pops up a panel from the bottom-right; clicking elsewhere dismisses it |
| Refresh now | Updates the number immediately (no popup) |
| Open folder | Opens the folder the tool lives in |
| Exit | Quits |

A left click on the tray icon toggles the details panel: click to open it, click again to close it.
You can also dismiss it by clicking outside the panel or hitting the × in its top-right corner.
The right-click menu offers the same actions.

### The details panel

It is meant to be read as a picture, not as text:

- Three tabs at the top switch between **Today / Yesterday / Last 7 days**; Today is the default.
- The big number in the middle is the total; the small line under it splits it into office and entertainment.
- Below that, a colour bar divides the same way: office is blue, entertainment is orange.
- Then **by program**: one row per program, bar length in proportion, time on the right, entertainment rows in orange and labelled.
- At the bottom, a **24-hour timeline** for the day: the blue blocks are the stretches where the screen was on, so you can see
  at a glance when you worked and where the gaps were.
  Hovering the timeline highlights the segment under the cursor and shows its exact start and end times.
- On the Last 7 days tab, the bottom becomes seven vertical bars, one per day. Hovering a bar highlights it and shows that day's date and length.

![Last 7 days](docs/screenshot-week.png)

The panel's height follows the number of programs: fewer programs, shorter panel.

## Installation

1. Put the whole `screen-time-counter` folder somewhere permanent. The path does not matter — spaces and non-ASCII characters are fine.
   **But it must be writable**: do not put it under `Program Files` or anywhere that needs administrator rights,
   because the tool writes its data and logs inside its own folder.
2. Double-click `start-screen-time`. The icon appearing in the tray means it is installed; give it a second or two.
3. Cannot find the icon: click the little up arrow (∧) at the bottom-right of the taskbar — it is usually in the hidden-icons panel.
   To keep it visible: Settings → Personalization → Taskbar → Other system tray icons, and turn it on.
   Note that it shows up there as "Windows PowerShell", not as this tool's name; recognise it by the orange circle.
4. **Turning on autostart is recommended** — for the reason in "Known limitations" below:
   right-click the launcher → Send to → Desktop (create shortcut); press Win + R, type `shell:startup`, press Enter,
   and paste the shortcut into that folder.

### Desktop icon

A shortcut to a script shows the generic Windows script icon by default, and all three tools look identical.
To make it match the tray dot: right-click the shortcut → Properties → Change Icon → pick `icon.ico` in this folder.

## Usage

- Leave it alone; it saves every 30 seconds.
- For details, right-click the icon and choose *Details*.
- Only one instance runs at a time: double-clicking again makes the extra one exit by itself.
- It uses roughly 100–150 MB of memory.

## Under the hood

- **Screen state is not guessed**: it subscribes to the system's display power notifications, so on and off each arrive as an event,
  and every one is written to the log verbatim.
- **Time is settled by a 30-second heartbeat**; two adjacent segments (within 60 seconds) are merged automatically.
- **Time while it was not running is backfilled from the system log**: boot, sleep and wake records; running counts, sleeping stops the clock.
- **State is written to a temp file and then swapped in**; if it cannot be read, the remains are kept, a line goes into the log,
  and the previous backup is restored. It sits at roughly 100–150 MB of memory.

## How it measures

Once it starts with Windows, it does three things:

1. It subscribes to the system's display power-state notifications. Turning the screen on or off delivers an event:
   this is exact, not a guess.
2. While the screen is on, it counts.
3. When the screen goes off (or you exit the program, or the machine is detected as suspended), the segment is closed and counted in full,
   with no deduction.

Two adjacent segments (within 60 seconds of each other) are merged, so one restart does not create an extra meaningless segment.

## By program

The panel lists how long each program was used, longest first. It asks "which window is in front?" every 30 seconds and closes
the previous segment when that changes. So it records **the window you were looking at**: if a video plays in the background while you
work in another window, that time goes to the foreground window.

## Office vs. entertainment

**It splits by program name only, never by content.**

- Entertainment programs are listed in `categories.json` (Steam and its helper processes by default). Their time is subtracted from
  "office time" but still shown separately.
- Anything not on the list counts as office. **Browsers count as office as a whole**, because the same browser is used for
  technical videos and for making things.
- So watching entertainment videos in Chrome counts as office. That trade-off was decided up front; it is not a bug.

Why not judge content: both obvious routes were tried and both fail. Judging entertainment by keywords is hopeless because entertainment
is endless; whitelisting work by keywords fails because technical videos span dozens of channels with wildly different titles.
Doing it properly needs a model, which means going online or installing one locally, and it would mean sending your titles out.

To change the list: copy `categories.example.json` to `categories.json` and add process names to the "娱乐" (entertainment) section.
Process names are visible in Task Manager's *Details* tab — the name without `.exe`.
Restart the tool for the change to apply. `categories.json` is your own copy and is not committed; if the file is missing,
the built-in default list is used.

## Backfilling older data

Time while the tool was not running cannot be recorded, but it can be estimated from the system log. Exit the tray first, then run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File screen-time.ps1 -Backfill
```

It backfills the last 7 days by default; `-BackfillDays 30` widens the range. It works by reading boot, shutdown, sleep and wake
records from the system log and counting "the machine was running" as in-use — only sleep stops the clock.

- Where an exact signal exists (the tool was running), the exact rule is used: only a lit screen counts.
- Where it does not, the degraded rule is used: the machine running counts. Both are treated the same way, with no marker in the UI.
- The **per-program breakdown cannot be filled in** — the system log has no record of which window was in front; that part only accumulates from now on.
- Time when the machine was off is not counted (a boot record means it was off before that).
- The backfill must be done with the tray exited, otherwise the tray overwrites it with its own data every 30 seconds.

## Known limitations

- **It has to stay running.** Time while it is not running cannot be recorded and cannot be recovered later — Windows itself does not
  log screen on/off. That is why autostart is recommended.
- Days before you installed it have no data. To approximate old dates you can only read the system log and reason from boot and sleep times;
  the error is the few minutes between the screen going off and the machine sleeping.
- It only records "the screen was on", with no idea what you were doing. Watching videos, writing code, staring into space: all the same.
- If you switch the monitor off with its own power button, the system does not know, and that time is still counted.
- Locking the screen (Win+L) leaves the display on, so it counts too.

## Troubleshooting

**The icon is gone**
Click the ∧ arrow on the taskbar to check the hidden panel; then check Settings → Personalization → Taskbar → Other system tray icons.

**The numbers never move**
Check whether the current segment in the panel still says "counting". A number is only settled when the screen goes off or when you exit.
If you keep sitting there working, it is one long segment and looks frozen.

**The icon stopped appearing at logon although it used to work**
Most likely the folder was moved and the autostart shortcut broke. Delete it and recreate it.

**Double-clicking the launcher does nothing**
Unblock the files first (right-click → Properties → tick *Unblock* if present), then check whether antivirus blocked the `.vbs`.
Run it by hand to see any red text:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\tools\screen-time-counter\screen-time.ps1" -Once
```

## Reading the log

`screen-time.log` sits in the tool folder. It records the tray starting, every display on/off notification received, and every segment closed.
If the screen goes off and no "segment recorded" line appears, keep the log so it can be looked at.

## Uninstalling completely

1. Right-click the tray icon → Exit. Do not skip this.
2. Delete the whole `screen-time-counter` folder. Your usage record `state.json` is inside it and goes with it.
3. Delete the Startup shortcut if you created one (Win + R, type `shell:startup`, press Enter).

Nothing else on the system was changed: no registry entries, no services, no installer.

## The other two tools in this set

- [Video Tab Counter](https://github.com/NutshellLee/video-tab-counter) — how many videos you finished today and how long they were
- [LLM Token Counter (DSH)](https://github.com/NutshellLee/dsh-token-counter) — how many tokens this machine's DSH used today

## Version history

- **1.2** (2026-10-14) — a segment that crosses midnight is now split by day. It used to be filed entirely under the day it started, so using the machine from the evening into the small hours made the new day show almost nothing; app time is split the same way.
- **1.1** (2026-10-12) — the tray click is now a toggle: click to open, click again to close. The tool can also be asked to exit cleanly from outside, so restarts and updates no longer need a forced kill.
- **1.0** (2026-10-12) — first release: the tray icon shows today's office time; the details panel switches between today / yesterday / the last 7 days, with a 24-hour timeline for today and yesterday and a per-program breakdown.

## What each file is

| File | What it is |
| --- | --- |
| `screen-time.ps1` | The main program |
| `start-screen-time.vbs` | Launcher — double-click this one |
| `categories.example.json` | Example category list; copy it to `categories.json` and edit that (your copy is not committed) |
| `icon.ico` | The icon used for the desktop shortcut |
| `README.md` / `README.zh-CN.md` | This document, in English and Chinese |
| `AGENTS.md` | Notes for AI or developers changing the code; safe to ignore as a user |
| `LICENSE` | License |
| `state.json` / `screen-time.log` | Created at runtime; safe to delete |

To change the code, read [AGENTS.md](AGENTS.md).
