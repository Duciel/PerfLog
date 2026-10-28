--[[
  !!PerfLog - performance diagnostics for WoW 1.12 (Lua 5.0)

  The addon loads first (the "!!" prefix) so that it can:
    * attribute every frame to the addon that created it;
    * wrap the OnEvent / OnUpdate / OnShow / OnHide scripts of every frame
      to measure the CPU time and Lua memory allocated by each handler;
    * track FPS, frame times, hitches, garbage collection, latency...

  Everything is written to  <WoW>\CustomData\PerfLog_<Character>_<Realm>_<date>_<client>.log
  through WriteCustomFile (nampower). Without nampower it falls back to the
  SavedVariables (WTF\Account\<account>\SavedVariables\!!PerfLog.lua).

  Open the file with Viewer\PerfLogViewer.html (drag and drop).

  Format: one record per line, tab-separated fields.
    S  key value                      session header
    A  addon enabled loaded           addon list
    C  cvar value                     graphics / nampower cvars
    R  id owner script name source    declaration of a profiled handler
    T  t dur frames maxMs n33 n50 n100 lat memKB thrKB allocKB gc freedKB luaMs selfMs combat loading group children bgSec
    H  t frameMs luaMs allocKB gc freedKB spikes events combat
    P  t window id key calls ms maxMs allocKB gc
    E  t window event fires dispatches
    M  t type text                    markers (combat, zone, loading screens, background, /perflog mark)
    F  t ms bytes                     cost of one disk write

  Background window: when WoW is not the active window it throttles itself to
  a fixed low frame rate (about 4 FPS here, i.e. ~260 ms frames). Those frames
  are not hitches. A run of bgRun frames that are all >= bgMinMs, within bgTol
  of each other and with almost no Lua time is treated as "background": the
  hitches of the run are dropped, a bg_start / bg_end marker is written, and
  the T line gets the number of seconds spent in background (bgSec).
]]

local ADDON_NAME = "!!PerfLog"
local VERSION = "1.3.0"

local GetTime, gcinfo, pairs, type, tostring, pcall = GetTime, gcinfo, pairs, type, tostring, pcall
local format, gsub, sfind = string.format, string.gsub, string.find
local tconcat, tsort, floor = table.concat, table.sort, math.floor

------------------------------------------------------------------------
-- Configuration
------------------------------------------------------------------------
local DEFAULTS = {
  enabled   = true,   -- write the log
  profile   = true,   -- profile handlers
  hitchMs   = 60,     -- a frame longer than this = hitch
  spikeMs   = 1,      -- handler calls >= this are kept to explain a hitch
  window    = 30,     -- seconds between two profile dumps
  tick      = 1,      -- seconds between two T lines
  flush     = 10,     -- seconds between two disk writes
  scanBatch = 100,    -- max frames inspected per rendered frame
  scanBudgetMs = 1,   -- max scanner time per rendered frame (ms)
  rescan    = 20,     -- seconds between two full scanner passes
  bgMinMs   = 150,    -- background: frames at least this long...
  bgRun     = 3,      -- ...this many in a row...
  bgTol     = 0.15,   -- ...each within 15% of the previous one
}
local cfg = {}
for k, v in pairs(DEFAULTS) do cfg[k] = v end

local PROF = true           -- profiling active (read from the config at ADDON_LOADED)
local SCRIPTS = { "OnEvent", "OnUpdate", "OnShow", "OnHide" }
local NSCRIPTS = 4
local PROFILED = { OnEvent = true, OnUpdate = true, OnShow = true, OnHide = true }

local function Print(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99PerfLog|r " .. tostring(msg))
  end
end

local function San(s)
  s = tostring(s or "?")
  s = gsub(s, "[\t\r\n]", " ")
  return s
end

------------------------------------------------------------------------
-- High resolution clock
------------------------------------------------------------------------
local clock, CLOCK_NAME
if type(debugprofilestop) == "function" then
  if type(debugprofilestart) == "function" then debugprofilestart() end
  clock = debugprofilestop
  CLOCK_NAME = "debugprofilestop"
else
  clock = function() return GetTime() * 1000 end
  CLOCK_NAME = "GetTime"
end

local function MeasureClockResolution()
  local best
  local changes = 0
  local a = clock()
  for i = 1, 300000 do
    local b = clock()
    if b ~= a then
      local d = b - a
      if d > 0 and (not best or d < best) then best = d end
      a = b
      changes = changes + 1
      if changes >= 30 then break end
    end
  end
  return best or -1
end

local T0 = GetTime()
local function Now() return GetTime() - T0 end
-- client id: GetTime() = uptime of this WoW process, differs between clients
local CLIENT_ID = format("%04d", math.mod(floor(GetTime() * 1000), 10000))

------------------------------------------------------------------------
-- Output (buffer + file)
------------------------------------------------------------------------
local buf, nbuf = {}, 0
local fileName
local writeMode            -- "file", "sv" or nil (not decided yet)
local bytesWritten, linesWritten, flushCount = 0, 0, 0
local lastFlushMs = 0
local SV_MAX_BYTES = 6 * 1024 * 1024

local function W(line)
  nbuf = nbuf + 1
  buf[nbuf] = line
end

local function SVAppend(text)
  PerfLogDB = PerfLogDB or {}
  if PerfLogDB.session ~= fileName then
    PerfLogDB.session = fileName
    PerfLogDB.chunks = {}
    PerfLogDB.bytes = 0
  end
  local chunks = PerfLogDB.chunks
  table.insert(chunks, text)
  PerfLogDB.bytes = (PerfLogDB.bytes or 0) + string.len(text)
  -- keep the beginning (header) and drop the oldest chunks after it
  while PerfLogDB.bytes > SV_MAX_BYTES and table.getn(chunks) > 2 do
    local removed = table.remove(chunks, 2)
    PerfLogDB.bytes = PerfLogDB.bytes - string.len(removed)
  end
end

local function Flush()
  if nbuf == 0 or not writeMode or not fileName then return end
  if not cfg.enabled then
    for i = 1, nbuf do buf[i] = nil end
    nbuf = 0
    return
  end
  local text = tconcat(buf, "\n", 1, nbuf) .. "\n"
  local n = nbuf
  for i = 1, nbuf do buf[i] = nil end
  nbuf = 0
  local t0 = clock()
  if writeMode == "file" then
    local ok, err = pcall(WriteCustomFile, fileName, text, "a")
    if not ok then
      Print("WriteCustomFile failed (" .. tostring(err) .. "), falling back to SavedVariables.")
      writeMode = "sv"
      SVAppend(text)
    end
  else
    SVAppend(text)
  end
  lastFlushMs = clock() - t0
  bytesWritten = bytesWritten + string.len(text)
  linesWritten = linesWritten + n
  flushCount = flushCount + 1
  W(format("F\t%.3f\t%.2f\t%d", Now(), lastFlushMs, string.len(text)))
end

------------------------------------------------------------------------
-- Attributing frames to addons
------------------------------------------------------------------------
local WEAK = { __mode = "k" }
local frameOwner = setmetatable({}, WEAK)   -- frame -> addon
local ownerSrc   = setmetatable({}, WEAK)   -- frame -> "stack" | "load"
local OURS       = setmetatable({}, WEAK)   -- our own frames (not profiled)

local addonNames  -- addon folder names (fallback when Lua truncates the path with "...")

local function StackOwner()
  if type(debugstack) ~= "function" then return nil end
  local ok, st = pcall(debugstack)
  if not ok or type(st) ~= "string" then return nil end
  for a in string.gfind(st, "[Aa][Dd][Dd][Oo][Nn][Ss][\\/]([^\\/:\n]+)[\\/]") do
    if a ~= ADDON_NAME then return a end
  end
  -- long paths are truncated by Lua ("...odules\nameplates.lua"): look for
  -- a known addon folder name surrounded by path separators
  if sfind(st, "%.%.%.") and GetNumAddOns then
    if not addonNames then
      addonNames = {}
      for i = 1, GetNumAddOns() do
        local name = GetAddOnInfo(i)
        if name and name ~= ADDON_NAME then table.insert(addonNames, name) end
      end
    end
    for line in string.gfind(st, "[^\n]+") do
      if not sfind(line, ADDON_NAME, 1, true) then
        for i = 1, table.getn(addonNames) do
          local nm = addonNames[i]
          if sfind(line, "\\" .. nm .. "\\", 1, true) or sfind(line, "/" .. nm .. "/", 1, true) then
            return nm
          end
        end
      end
    end
  end
  if sfind(st, "FrameXML") then return "FrameXML" end
  return nil
end

local function SafeCall(obj, method)
  local f = obj and obj[method]
  if type(f) ~= "function" then return nil end
  local ok, r = pcall(f, obj)
  if ok then return r end
  return nil
end

local function OwnerOf(f)
  local o = frameOwner[f]
  if o then return o, ownerSrc[f] or "load" end
  local p = f
  for i = 1, 8 do
    p = SafeCall(p, "GetParent")
    if not p then break end
    o = frameOwner[p]
    if o then return o, "parent" end
  end
  return "?", "none"
end

local function FrameLabel(f)
  local n = SafeCall(f, "GetName")
  if n then return n end
  local t = SafeCall(f, "GetObjectType") or "Frame"
  local p = SafeCall(f, "GetParent")
  local pn = p and SafeCall(p, "GetName")
  if pn then return "<" .. t .. ">@" .. pn end
  return "<" .. t .. ">"
end

-- Tag every frame that has no owner yet as belonging to `owner`
local function TagUntagged(owner)
  local n = 0
  local f = EnumerateFrames()
  while f do
    if not frameOwner[f] then
      frameOwner[f] = owner
      ownerSrc[f] = "load"
      n = n + 1
    end
    f = EnumerateFrames(f)
  end
  return n
end

------------------------------------------------------------------------
-- Handler profiling
------------------------------------------------------------------------
local infos = {}                                   -- id -> info
local nextId = 0
local slots = setmetatable({}, WEAK)               -- frame -> { script -> info }
local wrapInfo = setmetatable({}, { __mode = "k" })-- wrapper -> info

-- state shared by all wrappers
local depth = 0
local childT, childM, evAt = {}, {}, {}
local fLua = 0                          -- Lua ms (handlers) since the last frame
local frameNo = 0
local SPIKE_MAX = 64
local spikeN = 0
local spikeInfo, spikeKey, spikeMs = {}, {}, {}
local evStamp, evFrameCount = {}, {}    -- event -> frameNo / dispatches in that frame
local evDispatch = {}                   -- event -> dispatches (window)
local evFires = {}                      -- event -> occurrences (window, via RegisterAllEvents)
local spikeThreshold = DEFAULTS.spikeMs

local function MakeWrapper(info)
  local isEvent = (info.script == "OnEvent")
  local script = info.script
  local stats = info.stats
  return function(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12)
    local orig = info.orig
    if not orig then return end
    if not PROF then
      return orig(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12)
    end
    local key = script
    local d = depth + 1
    if isEvent then
      key = event or a2 or "?"
      -- a chain of hooks (HookScript) counts as a single dispatch
      if d == 1 or evAt[d - 1] ~= key then
        evDispatch[key] = (evDispatch[key] or 0) + 1
        if evStamp[key] ~= frameNo then
          evStamp[key] = frameNo
          evFrameCount[key] = 1
        else
          evFrameCount[key] = evFrameCount[key] + 1
        end
      end
    end
    evAt[d] = key
    depth = d
    childT[d] = 0
    childM[d] = 0
    local m0 = gcinfo()
    local t0 = clock()
    orig(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12)
    local dt = clock() - t0
    local dm = gcinfo() - m0
    depth = d - 1
    if dt < 0 then dt = 0 end
    local gc = dm < 0
    local ex = dt - (childT[d] or 0)
    if ex < 0 then ex = 0 end
    local exm = dm - (childM[d] or 0)
    if d > 1 then
      childT[d - 1] = (childT[d - 1] or 0) + dt
      if not gc then childM[d - 1] = (childM[d - 1] or 0) + dm end
    else
      fLua = fLua + dt
    end
    local s = stats[key]
    if not s then
      -- window: 1 calls, 2 ms, 3 max, 4 KB, 5 gc; cumulative: 6..10
      s = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
      stats[key] = s
    end
    s[1] = s[1] + 1
    s[2] = s[2] + ex
    if ex > s[3] then s[3] = ex end
    if gc then s[5] = s[5] + 1 elseif exm > 0 then s[4] = s[4] + exm end
    if ex >= spikeThreshold and spikeN < SPIKE_MAX then
      spikeN = spikeN + 1
      spikeInfo[spikeN] = info
      spikeKey[spikeN] = key
      spikeMs[spikeN] = ex
    end
  end
end

local function EmitInfo(info)
  W(format("R\t%d\t%s\t%s\t%s\t%s", info.id, San(info.owner), info.script, San(info.name), info.src))
end

local function NewInfo(frame, script, owner, src)
  nextId = nextId + 1
  local info = { id = nextId, script = script, owner = owner, src = src,
                 name = FrameLabel(frame), stats = {}, frame = frame }
  info.wrapper = MakeWrapper(info)
  wrapInfo[info.wrapper] = info
  infos[nextId] = info
  local s = slots[frame]
  if not s then s = {}; slots[frame] = s end
  s[script] = info
  EmitInfo(info)
  return info
end

------------------------------------------------------------------------
-- Hooking SetScript / GetScript (per widget type)
------------------------------------------------------------------------
local hookedMT = {}
local origSet, origGet = {}, {}
local validScripts = {}
local hookedTypes = 0

local function MethodTable(f)
  local mt = getmetatable(f)
  if type(mt) ~= "table" then return nil end
  local idx = mt.__index
  if type(idx) == "table" then return idx end
  return nil
end

local function HookMethodTable(idx)
  if hookedMT[idx] then return end
  hookedMT[idx] = true
  local oSet, oGet = idx.SetScript, idx.GetScript
  if type(oSet) ~= "function" or type(oGet) ~= "function" then return end
  origSet[idx] = oSet
  origGet[idx] = oGet
  hookedTypes = hookedTypes + 1

  idx.SetScript = function(self, sc, func)
    if not PROFILED[sc] or OURS[self] then
      return oSet(self, sc, func)
    end
    if type(func) ~= "function" or wrapInfo[func] then
      if func == nil then
        local s = slots[self]
        local info = s and s[sc]
        if info then info.orig = nil end
      end
      return oSet(self, sc, func)
    end
    local s = slots[self]
    local info = s and s[sc]
    if not info then
      local o, src = StackOwner(), "stack"
      if not o then o, src = OwnerOf(self) end
      info = NewInfo(self, sc, o, src)
    elseif info.src ~= "stack" and not info.reowned then
      -- an addon replaces a handler set by XML: re-attribute it once
      info.reowned = true
      local o = StackOwner()
      if o then
        info.src = "stack"
        if o ~= info.owner then
          info.owner = o
          EmitInfo(info)
        end
      end
    end
    info.orig = func
    return oSet(self, sc, info.wrapper)
  end

  idx.GetScript = function(self, sc)
    local f = oGet(self, sc)
    if f then
      local info = wrapInfo[f]
      if info then return info.orig end
    end
    return f
  end
end

local function HookAllExistingTypes()
  local f = EnumerateFrames()
  while f do
    local idx = MethodTable(f)
    if idx and not hookedMT[idx] then HookMethodTable(idx) end
    f = EnumerateFrames(f)
  end
end

local function ValidScriptsFor(idx, f, oGet)
  local v = idx and validScripts[idx]
  if v then return v end
  v = {}
  for i = 1, NSCRIPTS do
    local sc = SCRIPTS[i]
    v[sc] = pcall(oGet, f, sc) and true or false
  end
  if idx then validScripts[idx] = v end
  return v
end

-- Wrap the scripts of a frame that do not go through us yet
local function ScanFrame(f)
  if OURS[f] then return end
  local idx = MethodTable(f)
  if idx and not hookedMT[idx] then HookMethodTable(idx) end
  local oGet = (idx and origGet[idx]) or f.GetScript
  local oSet = (idx and origSet[idx]) or f.SetScript
  if type(oGet) ~= "function" or type(oSet) ~= "function" then return end
  local valid = ValidScriptsFor(idx, f, oGet)
  for i = 1, NSCRIPTS do
    local sc = SCRIPTS[i]
    if valid[sc] then
      local cur = oGet(f, sc)
      if cur and not wrapInfo[cur] then
        -- always a NEW info here: `cur` may be a chain (HookScript) that
        -- already calls our previous wrapper -> otherwise infinite recursion.
        local o, src
        local s = slots[f]
        local prev = s and s[sc]
        if prev then o, src = prev.owner, prev.src else o, src = OwnerOf(f) end
        local info = NewInfo(f, sc, o, src)
        info.orig = cur
        oSet(f, sc, info.wrapper)
      end
    end
  end
end

local scanCursor, scanRunning, scanNextAt = nil, false, 0
local scanCycleFrames, lastScanFrames = 0, 0

local function ScanStep(n)
  local f = scanCursor
  if not scanRunning then return end
  local t0 = clock()
  local budget = cfg.scanBudgetMs
  for i = 1, n do
    if clock() - t0 > budget then break end
    f = EnumerateFrames(f)
    if not f then
      scanRunning = false
      scanCursor = nil
      lastScanFrames = scanCycleFrames
      scanNextAt = GetTime() + cfg.rescan
      return
    end
    scanCycleFrames = scanCycleFrames + 1
    ScanFrame(f)
  end
  scanCursor = f
end

local function StartScan()
  scanRunning = true
  scanCursor = nil
  scanCycleFrames = 0
end

local function FullScanNow()
  local f = EnumerateFrames()
  local n = 0
  while f do
    ScanFrame(f)
    n = n + 1
    f = EnumerateFrames(f)
  end
  lastScanFrames = n
  return n
end

------------------------------------------------------------------------
-- Periodic dumps
------------------------------------------------------------------------
local lastWindowAt = 0

local function DumpProfile()
  local t = Now()
  local win = t - lastWindowAt
  lastWindowAt = t
  for id, info in pairs(infos) do
    for key, s in pairs(info.stats) do
      if s[1] > 0 then
        W(format("P\t%.3f\t%.1f\t%d\t%s\t%d\t%.3f\t%.3f\t%d\t%d", t, win, id, key, s[1], s[2], s[3], s[4], s[5]))
        s[6] = s[6] + s[1]; s[7] = s[7] + s[2]
        if s[3] > s[8] then s[8] = s[3] end
        s[9] = s[9] + s[4]; s[10] = s[10] + s[5]
        s[1] = 0; s[2] = 0; s[3] = 0; s[4] = 0; s[5] = 0
      end
    end
  end
  for ev, n in pairs(evDispatch) do
    local fires = evFires[ev] or 0
    if n > 0 or fires > 0 then
      W(format("E\t%.3f\t%.1f\t%s\t%d\t%d", t, win, ev, fires, n))
    end
    evDispatch[ev] = 0
  end
  for ev, n in pairs(evFires) do
    if n > 0 and not evDispatch[ev] then
      W(format("E\t%.3f\t%.1f\t%s\t%d\t%d", t, win, ev, n, 0))
    end
    evFires[ev] = 0
  end
end

------------------------------------------------------------------------
-- Session info
------------------------------------------------------------------------
local function S(k, v) W("S\t" .. k .. "\t" .. San(v)) end

local CVARS = {
  "gxApi", "gxResolution", "gxRefresh", "gxColorBits", "gxDepthBits", "gxMultisample",
  "gxMultisampleQuality", "gxVSync", "gxTripleBuffer", "gxWindow", "gxMaximize", "gxCursor",
  "maxfps", "maxfpsbk", "farclip", "horizonfarclip", "farclipoverride",
  "groundEffectDensity", "groundEffectDist", "smallCull", "detailDoodadAlpha", "doodadAnim",
  "texLodBias", "spellEffectLevel", "weatherDensity", "unitDrawDist", "shadowLevel",
  "M2UsePixelShaders", "M2UseZFill", "M2UseClipPlanes", "M2UseThreads", "M2BatchDoodads",
  "M2Faster", "pixelShaders", "fullAlpha", "frillDensity", "lod", "SkyCloudLOD", "waterLOD",
  "mapShadows", "showfootprints", "particleDensity", "anisotropic", "trilinear",
  "textureCacheSize", "nameplateDistance", "UnitNameRenderMode", "showShadow",
  "NP_EnableUnitEventsGuid", "NP_EnableUnitEventsGuidFiltering", "NP_EnableUnitEventsRaid",
  "NP_EnableUnitEventsParty", "NP_EnableUnitEventsPet", "NP_EnableUnitEventsMouseover",
  "NP_NameplateDistance", "NP_EnableAuraCastEvents", "NP_EnableAutoAttackEvents",
  "NP_EnableSpellStartEvents", "NP_EnableSpellGoEvents", "NP_EnableSpellHealEvents",
  "NP_EnableSpellEnergizeEvents", "NP_EnableEnhancedTooltips",
}

local function WriteSessionInfo()
  S("addonVersion", VERSION)
  S("date", date("%Y-%m-%d %H:%M:%S"))
  S("gettime0", format("%.3f", T0))
  local v, b, d = GetBuildInfo()
  S("build", tostring(v) .. " " .. tostring(b) .. " " .. tostring(d))
  S("realm", GetRealmName and GetRealmName() or "?")
  S("char", UnitName and UnitName("player") or "?")
  S("clientId", CLIENT_ID)
  S("clock", CLOCK_NAME)
  S("clockResMs", format("%.4f", MeasureClockResolution()))
  S("writeMode", writeMode)
  S("debugstack", type(debugstack) == "function" and "yes" or "no")
  S("hookedWidgetTypes", hookedTypes)
  do
    local mt = getmetatable(UIParent)
    local idx = type(mt) == "table" and mt.__index
    S("frameMeta", type(mt) .. "/" .. type(idx) .. "/" .. type(type(idx) == "table" and rawget(idx, "SetScript")))
  end
  S("superwow", SUPERWOW_VERSION or "absent")
  if type(GetNampowerVersion) == "function" then
    local ok, a, b2, c = pcall(GetNampowerVersion)
    S("nampower", ok and (tostring(a) .. "." .. tostring(b2) .. "." .. tostring(c)) or "?")
  else
    S("nampower", "absent")
  end
  S("classicapi", CLASSIC_API_VERSION or (C_AddOns and "present") or "absent")
  if type(GetWeirdUtilsVersion) == "function" then
    local ok, t = pcall(GetWeirdUtilsVersion)
    local parts = {}
    if ok and type(t) == "table" then
      for k2, v2 in pairs(t) do table.insert(parts, tostring(k2) .. "=" .. tostring(v2)) end
    end
    S("weirdutils", tconcat(parts, ","))
  else
    S("weirdutils", "absent")
  end
  S("unitxp", type(UnitXP) == "function" and "present" or "absent")
  S("hitchMs", cfg.hitchMs)
  S("window", cfg.window)
  S("bgDetect", format("%d frames >= %d ms within %d%%", cfg.bgRun, cfg.bgMinMs, cfg.bgTol * 100))
  S("profile", PROF and 1 or 0)
  -- addons
  local n = GetNumAddOns()
  for i = 1, n do
    local name, title, notes, enabled, loadable, reason = GetAddOnInfo(i)
    local loaded = IsAddOnLoaded(i)
    W(format("A\t%s\t%d\t%d", San(name), enabled and 1 or 0, loaded and 1 or 0))
  end
  -- cvars
  for i = 1, table.getn(CVARS) do
    local ok, val = pcall(GetCVar, CVARS[i])
    if ok and val ~= nil then W("C\t" .. CVARS[i] .. "\t" .. San(val)) end
  end
end

local function Mark(kind, text)
  W(format("M\t%.3f\t%s\t%s", Now(), kind, San(text or "")))
end

------------------------------------------------------------------------
-- Driver frame
------------------------------------------------------------------------
local driver = CreateFrame("Frame", "PerfLogDriverFrame")
OURS[driver] = true

local lastMem = gcinfo()
-- counters of the current second (in a table: Lua 5.0 has a 32 upvalue limit)
local tk = { acc = 0, frames = 0, max = 0, n33 = 0, n50 = 0, n100 = 0,
             alloc = 0, gc = 0, freed = 0, lua = 0, self = 0, bg = 0 }
-- background (throttled window) detection
--   on: in background; run/runMs/ref: current run of long regular frames;
--   pend: hitch lines of the current run, written only if the run is not background
local bgs = { on = false, run = 0, runMs = 0, ref = 0, pend = {}, npend = 0,
              since = 0, frames = 0, periods = 0, skipped = 0, total = 0 }
-- general state
local st = { nextFlushAt = 0, nextWindowAt = 0, loading = true, loadingUntil = 0,
             loadStart = GetTime(), inCombat = false, groupSize = 1, hitchCount = 0,
             childrenOK = WorldFrame and type(WorldFrame.GetNumChildren) == "function" }

local function SpikeString()
  if spikeN == 0 then return "-" end
  -- selection sort of the 5 biggest
  local out = {}
  local used = {}
  for k = 1, 5 do
    local best, bi = -1, nil
    for i = 1, spikeN do
      if not used[i] and spikeMs[i] > best then best = spikeMs[i]; bi = i end
    end
    if not bi then break end
    used[bi] = true
    table.insert(out, format("%d|%s|%.1f", spikeInfo[bi].id, spikeKey[bi], spikeMs[bi]))
  end
  return tconcat(out, ";")
end

local function EventString()
  local list = {}
  for ev, stamp in pairs(evStamp) do
    if stamp == frameNo then table.insert(list, ev) end
  end
  if table.getn(list) == 0 then return "-" end
  tsort(list, function(a, b) return evFrameCount[a] > evFrameCount[b] end)
  local out = {}
  for i = 1, math.min(6, table.getn(list)) do
    table.insert(out, list[i] .. "|" .. evFrameCount[list[i]])
  end
  return tconcat(out, ";")
end

local function GroupSize()
  local r = GetNumRaidMembers and GetNumRaidMembers() or 0
  if r > 0 then return r end
  local p = GetNumPartyMembers and GetNumPartyMembers() or 0
  return p + 1
end

local function EmitTick(now, mem, thr)
  local _, _, lat = GetNetStats()
  local children = 0
  if st.childrenOK then children = WorldFrame:GetNumChildren() or 0 end
  W(format("T\t%.3f\t%.3f\t%d\t%.1f\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%.2f\t%.2f\t%d\t%d\t%d\t%d\t%.3f",
    now - T0, tk.acc, tk.frames, tk.max, tk.n33, tk.n50, tk.n100, lat or 0, mem, thr or 0,
    tk.alloc, tk.gc, tk.freed, tk.lua, tk.self, st.inCombat and 1 or 0, st.loading and 1 or 0,
    st.groupSize, children, tk.bg))
  tk.acc, tk.frames, tk.max, tk.n33, tk.n50, tk.n100 = 0, 0, 0, 0, 0, 0
  tk.alloc, tk.gc, tk.freed, tk.lua, tk.self, tk.bg = 0, 0, 0, 0, 0, 0
end

-- pending hitches of a run that turned out NOT to be background: write them
local function BgFlushPending()
  for i = 1, bgs.npend do
    W(bgs.pend[i])
    bgs.pend[i] = nil
    st.hitchCount = st.hitchCount + 1
  end
  bgs.npend = 0
end

-- pending hitches of a run that IS background: drop them
local function BgDropPending()
  for i = 1, bgs.npend do bgs.pend[i] = nil end
  bgs.skipped = bgs.skipped + bgs.npend
  bgs.npend = 0
end

-- Called once per frame before the hitch test; returns true while in background
local function BgUpdate(ms, el, now)
  if bgs.on then
    if ms < cfg.bgMinMs then
      bgs.on = false
      bgs.run, bgs.runMs = 0, 0
      Mark("bg_end", format("%.1fs, %d frames", now - bgs.since, bgs.frames))
      return false
    end
    bgs.frames = bgs.frames + 1
    tk.bg = tk.bg + el
    bgs.total = bgs.total + el
    return true
  end
  local long = ms >= cfg.bgMinMs and fLua < ms * 0.25
  if long and bgs.run > 0 and math.abs(ms - bgs.ref) <= bgs.ref * cfg.bgTol then
    bgs.run = bgs.run + 1
    bgs.runMs = bgs.runMs + ms
  else
    -- the previous run is over and was not background: its hitches were real
    BgFlushPending()
    if long then bgs.run, bgs.runMs = 1, ms else bgs.run, bgs.runMs = 0, 0 end
  end
  bgs.ref = ms
  if bgs.run >= cfg.bgRun then
    bgs.on = true
    bgs.periods = bgs.periods + 1
    bgs.frames = bgs.run
    bgs.since = now - bgs.runMs / 1000
    tk.bg = tk.bg + bgs.runMs / 1000
    bgs.total = bgs.total + bgs.runMs / 1000
    BgDropPending()
    Mark("bg_start", format("%.0f ms frames", ms))
    return true
  end
  return false
end

local function Periodic(now)
  -- incremental scanner
  if scanRunning then
    ScanStep(cfg.scanBatch)
  elseif now >= scanNextAt and scanNextAt > 0 then
    StartScan()
  end
  if now >= st.nextWindowAt then
    st.nextWindowAt = now + cfg.window
    DumpProfile()
  end
  if now >= st.nextFlushAt or nbuf > 3000 then
    st.nextFlushAt = now + cfg.flush
    Flush()
  end
end

local function OnUpdate()
  local c0 = clock()
  local el = arg1 or 0
  local ms = el * 1000
  local now = GetTime()
  depth = 0

  local mem, thr = gcinfo()
  local dmem = mem - lastMem
  local gc, freed = 0, 0
  if dmem < 0 then
    gc = 1; freed = -dmem
    tk.gc = tk.gc + 1; tk.freed = tk.freed + freed
  else
    tk.alloc = tk.alloc + dmem
  end

  if st.loading and st.loadingUntil > 0 and now >= st.loadingUntil then
    st.loading = false
  end

  -- window in background (throttled frame rate): not a slow frame
  local bg = BgUpdate(ms, el, now)

  -- slow frame?
  if not bg then
    if ms >= 33 then tk.n33 = tk.n33 + 1 end
    if ms >= 50 then tk.n50 = tk.n50 + 1 end
    if ms >= 100 then tk.n100 = tk.n100 + 1 end
    if ms > tk.max then tk.max = ms end
    if ms >= cfg.hitchMs and not st.loading then
      local line = format("H\t%.3f\t%.1f\t%.2f\t%d\t%d\t%d\t%s\t%s\t%d",
        now - T0, ms, fLua, gc == 1 and 0 or dmem, gc, freed, SpikeString(), EventString(),
        st.inCombat and 1 or 0)
      if bgs.run > 0 then
        -- part of a run of long regular frames: wait to know if it is background
        bgs.npend = bgs.npend + 1
        bgs.pend[bgs.npend] = line
      else
        st.hitchCount = st.hitchCount + 1
        W(line)
      end
    end
  end
  tk.lua = tk.lua + fLua
  fLua = 0
  spikeN = 0
  frameNo = frameNo + 1

  tk.acc = tk.acc + el
  tk.frames = tk.frames + 1
  if tk.acc >= cfg.tick then EmitTick(now, mem, thr) end

  Periodic(now)

  -- our own cost (includes disk writes)
  tk.self = tk.self + (clock() - c0)
  -- re-sync memory after our own work so that our allocations are not
  -- counted as allocations of the game
  lastMem = gcinfo()
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local allEvents = pcall(driver.RegisterAllEvents, driver)
local MY_EVENTS = {
  "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_LOGOUT", "PLAYER_ENTERING_WORLD",
  "PLAYER_LEAVING_WORLD", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
  "ZONE_CHANGED_NEW_AREA", "RAID_ROSTER_UPDATE", "PARTY_MEMBERS_CHANGED",
}
if not allEvents then
  for i = 1, table.getn(MY_EVENTS) do driver:RegisterEvent(MY_EVENTS[i]) end
end

local loadTagged = {}

-- File name unique per client: character + realm + date + process id
-- (GetTime = uptime of each client, differs between two clients)
local function FileSafe(s)
  s = gsub(tostring(s or ""), "[^%w%-]", "")
  if s == "" then s = "X" end
  return s
end
local function MakeFileName()
  local char = UnitName and UnitName("player") or "?"
  local realm = GetRealmName and GetRealmName() or "?"
  return "PerfLog_" .. FileSafe(char) .. "_" .. FileSafe(realm) .. "_" ..
    date("%Y%m%d_%H%M%S") .. "_" .. CLIENT_ID .. ".log"
end

-- handlers set during an addon's XML OnLoad (owner unknown until its ADDON_LOADED)
local function ReassignUnknownOwners()
  for id, info in pairs(infos) do
    if info.owner == "?" and info.frame then
      local o, src = OwnerOf(info.frame)
      if o ~= "?" then
        info.owner = o
        info.src = src
        EmitInfo(info)
      end
    end
  end
end

local function OnLogin()
    st.groupSize = GroupSize()
    fileName = MakeFileName()
    WriteSessionInfo()
    local t0 = clock()
    local n = FullScanNow()
    S("initialScanFrames", n)
    S("initialScanMs", format("%.1f", clock() - t0))
    S("handlersWrapped", nextId)
    scanNextAt = GetTime() + cfg.rescan
    Mark("login", "")
    Flush()
    if cfg.enabled then
      Print("logging to CustomData\\" .. tostring(fileName) ..
        (writeMode == "sv" and " (SavedVariables: WriteCustomFile not available)" or "") ..
        ". |cffaaaaaa/perflog for help|r")
    end
end

local function OnEvent()
  local ev = event
  if allEvents then evFires[ev] = (evFires[ev] or 0) + 1 end

  if ev == "ADDON_LOADED" then
    local name = arg1
    if name == ADDON_NAME then
      if type(PerfLogConfig) ~= "table" then PerfLogConfig = {} end
      if PerfLogConfig.cfgVersion ~= 2 then
        -- v1.0: scanner too aggressive (caused hitches) -> new values
        PerfLogConfig.scanBatch = nil
        PerfLogConfig.rescan = nil
        PerfLogConfig.cfgVersion = 2
      end
      for k, v in pairs(DEFAULTS) do
        if PerfLogConfig[k] == nil then PerfLogConfig[k] = v end
        cfg[k] = PerfLogConfig[k]
      end
      PROF = cfg.profile and true or false
      spikeThreshold = cfg.spikeMs
      if type(WriteCustomFile) == "function" then
        writeMode = "file"
      else
        writeMode = "sv"
        PerfLogDB = {}
      end
    else
      local n = TagUntagged(name)
      loadTagged[name] = n
      ReassignUnknownOwners()
      W(format("M\t%.3f\taddon_loaded\t%s (%d frames)", Now(), San(name), n))
    end

  elseif ev == "PLAYER_LOGIN" then
    OnLogin()

  elseif ev == "PLAYER_ENTERING_WORLD" then
    local dur = GetTime() - st.loadStart
    Mark("loading_end", format("%.1fs%s", dur, arg2 and " (reload)" or ""))
    st.loading = true
    st.loadingUntil = GetTime() + 3
    st.inCombat = UnitAffectingCombat and UnitAffectingCombat("player") and true or false
    Mark("zone", GetRealZoneText and GetRealZoneText() or "?")

  elseif ev == "PLAYER_LEAVING_WORLD" then
    st.loading = true
    st.loadingUntil = 0
    st.loadStart = GetTime()
    Mark("loading_start", "")
    Flush()

  elseif ev == "PLAYER_REGEN_DISABLED" then
    st.inCombat = true
    Mark("combat_start", UnitName and UnitName("target") or "")

  elseif ev == "PLAYER_REGEN_ENABLED" then
    st.inCombat = false
    Mark("combat_end", "")

  elseif ev == "ZONE_CHANGED_NEW_AREA" then
    Mark("zone", GetRealZoneText and GetRealZoneText() or "?")

  elseif ev == "RAID_ROSTER_UPDATE" or ev == "PARTY_MEMBERS_CHANGED" then
    local g = GroupSize()
    if g ~= st.groupSize then
      st.groupSize = g
      Mark("group", tostring(g))
    end

  elseif ev == "PLAYER_LOGOUT" then
    BgFlushPending()
    Mark("logout", "")
    DumpProfile()
    Flush()
  end
end

driver:SetScript("OnEvent", OnEvent)
driver:SetScript("OnUpdate", OnUpdate)

------------------------------------------------------------------------
-- Installing hooks (when this file loads, before other addons)
------------------------------------------------------------------------
do
  local n = TagUntagged("FrameXML")
  W(format("M\t%.3f\taddon_loaded\tFrameXML (%d frames)", Now(), n))
  HookAllExistingTypes()
  -- make sure common widget types are hooked even without an existing instance
  local probe = { "Frame", "Button", "CheckButton", "StatusBar", "Slider", "ScrollFrame", "Model" }
  for i = 1, table.getn(probe) do
    local ok, f = pcall(CreateFrame, probe[i])
    if ok and f then
      OURS[f] = true
      local idx = MethodTable(f)
      if idx then HookMethodTable(idx) end
      if f.Hide then f:Hide() end
    end
  end

  -- attribute frames created through CreateFrame
  local oCreateFrame = CreateFrame
  CreateFrame = function(ftype, name, parent, inherits)
    local f = oCreateFrame(ftype, name, parent, inherits)
    if f and not frameOwner[f] then
      local o = StackOwner()
      if o then
        frameOwner[f] = o
        ownerSrc[f] = "stack"
      end
      local idx = MethodTable(f)
      if idx and not hookedMT[idx] then HookMethodTable(idx) end
    end
    return f
  end
end

------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------
local function TopReport(nOwners, nHandlers)
  local byOwner, ownerMem, rows = {}, {}, {}
  local total = 0
  for id, info in pairs(infos) do
    for key, s in pairs(info.stats) do
      local ms = s[2] + s[7]
      local kb = s[4] + s[9]
      if ms > 0 or kb > 0 then
        byOwner[info.owner] = (byOwner[info.owner] or 0) + ms
        ownerMem[info.owner] = (ownerMem[info.owner] or 0) + kb
        total = total + ms
        table.insert(rows, { ms = ms, kb = kb, n = s[1] + s[6], label = info.owner .. " " .. info.name .. ":" .. key })
      end
    end
  end
  local owners = {}
  for o, ms in pairs(byOwner) do table.insert(owners, { o = o, ms = ms, kb = ownerMem[o] }) end
  tsort(owners, function(a, b) return a.ms > b.ms end)
  tsort(rows, function(a, b) return a.ms > b.ms end)
  local up = Now()
  Print(format("Top addons (cumulative Lua CPU over %.0fs, total %.0f ms = %.1f%%):", up, total, up > 0 and total / (up * 10) or 0))
  for i = 1, math.min(nOwners, table.getn(owners)) do
    local o = owners[i]
    Print(format("  %d. %s: %.0f ms (%.2f ms/s), %.0f KB allocated", i, o.o, o.ms, o.ms / math.max(up, 1), o.kb or 0))
  end
  Print("Top handlers:")
  for i = 1, math.min(nHandlers, table.getn(rows)) do
    local r = rows[i]
    Print(format("  %d. %s: %.0f ms / %d calls, %.0f KB", i, r.label, r.ms, r.n, r.kb))
  end
end

local function SaveCfg()
  if type(PerfLogConfig) == "table" then
    for k in pairs(DEFAULTS) do PerfLogConfig[k] = cfg[k] end
  end
end

SLASH_PERFLOG1 = "/perflog"
SLASH_PERFLOG2 = "/plog"
SlashCmdList["PERFLOG"] = function(msg)
  msg = msg or ""
  local _, _, cmd, rest = sfind(msg, "^%s*(%S*)%s*(.-)%s*$")
  cmd = string.lower(cmd or "")
  if cmd == "mark" or cmd == "m" then
    Mark("user", rest)
    Print("marker added: " .. rest)
  elseif cmd == "top" then
    TopReport(10, 10)
  elseif cmd == "flush" then
    DumpProfile()
    Flush()
    Print("log written.")
  elseif cmd == "on" or cmd == "off" then
    cfg.enabled = (cmd == "on")
    SaveCfg()
    Mark("logging", cmd)
    Print("logging: " .. cmd)
  elseif cmd == "profile" then
    if rest == "on" then PROF = true elseif rest == "off" then PROF = false else PROF = not PROF end
    cfg.profile = PROF
    SaveCfg()
    Mark("profile", PROF and "on" or "off")
    Print("handler profiling: " .. (PROF and "on" or "off"))
  elseif cmd == "hitch" and tonumber(rest) then
    cfg.hitchMs = tonumber(rest); SaveCfg()
    Print("hitch threshold: " .. cfg.hitchMs .. " ms")
  elseif cmd == "window" and tonumber(rest) then
    cfg.window = math.max(5, tonumber(rest)); SaveCfg()
    Print("profile window: " .. cfg.window .. " s")
  elseif cmd == "gc" then
    local before = gcinfo()
    local t0 = clock()
    collectgarbage()
    local dt = clock() - t0
    local after = gcinfo()
    Mark("user_gc", format("%d->%d KB in %.1f ms", before, after, dt))
    Print(format("forced GC: %d KB -> %d KB in %.1f ms", before, after, dt))
  elseif cmd == "status" or cmd == "" then
    local mem, thr = gcinfo()
    Print(format("v%s  file: %s (%s)", VERSION, tostring(fileName), tostring(writeMode)))
    Print(format("  log %s, profiling %s, %d handlers profiled, %d widget types hooked, clock %s",
      cfg.enabled and "on" or "off", PROF and "on" or "off", nextId, hookedTypes, CLOCK_NAME))
    Print(format("  %d lines / %.0f KB written, %d hitches, Lua memory %.1f MB (GC at %.1f MB)",
      linesWritten, bytesWritten / 1024, st.hitchCount, mem / 1024, (thr or 0) / 1024))
    Print(format("  window in background: %d time(s), %.0fs in total, %d throttled frames not counted as hitches%s",
      bgs.periods, bgs.total, bgs.skipped, bgs.on and " (in background now)" or ""))
    Print("|cffaaaaaaCommands: /perflog mark <text> | top | flush | on | off | profile [on|off] | hitch <ms> | window <s> | gc|r")
  else
    Print("unknown command. /perflog for help.")
  end
end
