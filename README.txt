!!PerfLog - performance diagnostics for WoW 1.12 (vanilla / Turtle WoW)
========================================================================

HOW TO USE
1. Play normally (raid, battleground, city...). The addon records everything by itself.
2. Drop a marker whenever you feel a slowdown:  /perflog mark lag on pull
3. After the session (no need to quit the game), open
   Interface\AddOns\!!PerfLog\Viewer\PerfLogViewer.html in your web browser
   and drop the file  <WoW folder>\CustomData\PerfLog_<Character>_<Realm>_<date>_<client>.log
   onto it. There is one file per client session (login or /reload); you can drop
   several files and switch between them with the list at the top right.

REQUIREMENTS
- nampower (WriteCustomFile) to write the log file continuously.
  Without nampower the log goes to the SavedVariables instead
  (WTF\Account\<account>\SavedVariables\!!PerfLog.lua, written on logout or /reload),
  and the viewer can read that file too.
- Optional: SuperWoW, ClassicAPI and WeirdUtils versions are recorded when present.

COMMANDS (/perflog or /plog)
  /perflog               status (file, memory, number of hitches)
  /perflog mark <text>   add a marker to the log
  /perflog top           live top 10 of the most expensive addons / handlers
  /perflog flush         write the log to disk now
  /perflog off | on      stop / resume logging
  /perflog profile off   turn per-addon profiling off (lighter; keeps FPS/GC/hitches)
  /perflog hitch 60      hitch threshold in ms (default 60)
  /perflog window 30     per-addon measurement interval in seconds (default 30)
  /perflog gc            force a garbage collection and measure how long it takes

WHAT IS MEASURED
- FPS, worst frame of each second, frames > 33/50/100 ms, latency, Lua memory, GC.
- Every hitch (frame longer than the threshold) with its likely cause: the guilty
  Lua handler, a garbage collection, or a non-Lua cause (rendering, disk, network).
- For each addon and each OnEvent/OnUpdate/OnShow/OnHide handler: exclusive CPU
  time, number of calls, Lua memory allocated, garbage collections triggered.
- How often each event fires and how many handlers it wakes up.
- Markers: combat, zone changes, loading screens, group size.
- Header: loaded addons, graphics and nampower CVars, mod versions.

NOTES
- The log is appended to disk every 10 seconds with WriteCustomFile.
- Profiling adds a small overhead (shown in the viewer as "PerfLog overhead").
- Delete old logs from CustomData from time to time (roughly 5-15 MB per hour).
- To turn it off completely, untick "PerfLog" in the addon list.
