-- Title-menu whole-game voxel cache generator.
--
-- This is intentionally a normal game state rather than a blocking utility:
-- ChunkMesher keeps its cooperative frame budget, the screen remains
-- responsive, B cancels safely, and completed BAVC files make the next run
-- resume instead of starting over.  Only one map is retained in runtime
-- memory; after its required variants land, GPU meshes and Structures analysis
-- are released while the persistent files remain.

local V = ...

local Font = require("src.render.Font")
local ChunkMesher = V.require("ChunkMesher")
local MeshDisk = V.require("VoxelMeshDisk")
local Precache = V.require("VoxelPrecache")
local StaticGeometry = V.require("StaticGeometry")

local Screen = {}
Screen.__index = Screen
Screen.isOpaque = true

local function sizeText(bytes)
  bytes = tonumber(bytes) or 0
  if bytes >= 1024 * 1024 * 1024 then
    return ("%.2f GiB"):format(bytes / (1024 * 1024 * 1024))
  end
  return ("%.1f MiB"):format(bytes / (1024 * 1024))
end

local function put(text, row, col)
  Font.draw(tostring(text or ""), (col or 1) * 8, row * 8)
end

local function countKinds(jobs)
  local full, body, maps = 0, 0, {}
  for _, job in ipairs(jobs) do
    maps[job.id] = true
    if job.bodyOnly then body = body + 1 else full = full + 1 end
  end
  local n = 0
  for _ in pairs(maps) do n = n + 1 end
  return n, full, body
end

function Screen.new(game)
  StaticGeometry.capture(game and game.data) -- lifecycle/test fallback
  local data = StaticGeometry.data() or (game and game.data)
  local jobs = Precache.allJobs(data)
  local maps, full, body = countKinds(jobs)
  local self = setmetatable({
    game = game,
    phase = MeshDisk.available() and "confirm" or "unavailable",
    jobs = jobs,
    index = 1,
    maps = maps,
    full = full,
    body = body,
    skipped = 0,
    built = 0,
    failed = 0,
    active = nil,
    loadedId = nil,
    loadedMap = nil,
    stats = MeshDisk.stats(),
    statClock = 0,
    titleUiBox = { 0, 0, 19, 17 },
  }, Screen)
  return self
end

function Screen:releaseLoaded(exceptId)
  if self.loadedId and self.loadedId ~= exceptId then
    ChunkMesher.evictRuntime(self.loadedId)
    self.loadedId, self.loadedMap = nil, nil
  end
end

function Screen:loadMap(id)
  if self.loadedId == id and self.loadedMap then return self.loadedMap end
  self:releaseLoaded(id)
  local ok, map = pcall(StaticGeometry.map, id)
  if not (ok and map) then return nil end
  self.loadedId, self.loadedMap = id, map
  return map
end

function Screen:finish(phase)
  if self.active then ChunkMesher.evictRuntime(self.active.id) end
  self.active = nil
  self:releaseLoaded(nil)
  self.stats = MeshDisk.stats()
  self.phase = phase
  -- Whole-world generation touches several route-sized FFI buffers. Runtime
  -- meshes are already released above; collect their Lua/cdata owners before
  -- returning to gameplay so the first warp does not inherit generator debris.
  collectgarbage("collect")
end

function Screen:startNext()
  -- Skip several already-valid records per frame without turning a large
  -- existing cache scan into a visible hundreds-of-frame countdown.
  for _ = 1, 8 do
    local job = self.jobs[self.index]
    if not job then
      self:finish(self.failed == 0 and "complete" or "incomplete")
      return
    end
    local map = self:loadMap(job.id)
    if not map then
      self.failed = self.failed + 1
      self.index = self.index + 1
    else
      local masks
      if not job.bodyOnly then
        masks = Precache.masksFor(StaticGeometry.data() or self.game.data,
                                  job.id)
      end
      if MeshDisk.complete(map, job.bodyOnly, masks) then
        self.skipped = self.skipped + 1
        self.index = self.index + 1
      else
        -- A title-menu run can begin after gameplay has already built this
        -- slot in RAM (especially after the disk directory was cleared). In
        -- that case request() quite correctly returns the resident mesh and
        -- queues nothing, but there is still no persistent file to resume
        -- next session. Drop only this map's runtime copy first so the request
        -- is guaranteed to pass through the disk load/save path.
        ChunkMesher.evictRuntime(job.id)
        ChunkMesher.request(map, job.bodyOnly, masks, false)
        self.active = { id = job.id, map = map, bodyOnly = job.bodyOnly,
                        masks = masks, kind = job.kind }
        return
      end
    end
  end
end

function Screen:update(dt)
  local input = self.game.input
  if self.phase == "confirm" then
    if input:wasPressed("a") or input:wasPressed("start") then
      self.phase = "running"
    elseif input:wasPressed("b") then
      self.game.stack:pop()
    end
    return
  end
  if self.phase ~= "running" then
    if input:wasPressed("a") or input:wasPressed("b")
       or input:wasPressed("start") then
      self.game.stack:pop()
    end
    return
  end

  if input:wasPressed("b") then self:finish("cancelled"); return end

  self.statClock = self.statClock + (dt or 0)
  if self.statClock >= 0.5 then
    self.stats, self.statClock = MeshDisk.stats(), 0
  end

  if self.active then
    ChunkMesher.pump(true)
    if ChunkMesher.jobPending(self.active.id, self.active.bodyOnly) then return end
    if MeshDisk.complete(self.active.map, self.active.bodyOnly,
                         self.active.masks) then
      self.built = self.built + 1
    else
      self.failed = self.failed + 1
    end
    self.active = nil
    self.index = self.index + 1
  end
  self:startNext()
end

function Screen:draw()
  love.graphics.clear(1, 1, 1, 1)
  love.graphics.setColor(1, 1, 1, 1)
  Font.drawBox(0, 0, 20, 18)
  love.graphics.setColor(0, 0, 0, 1)
  put("GENERATE PRECACHE", 1)

  if self.phase == "confirm" then
    put(("MAPS: %d"):format(self.maps), 3)
    put(("FULL: %d"):format(self.full), 4)
    put(("BODY: %d"):format(self.body), 5)
    put("TERRAIN + WATER", 7)
    put("GRASS + FLOWERS", 8)
    put("AUTHORED FIGURES", 9)
    put(("CURRENT: %s"):format(sizeText(self.stats.bytes)), 11)
    put("VALID FILES RESUME", 13)
    put("A:START  B:BACK", 15)
  elseif self.phase == "running" then
    local job = self.active or self.jobs[self.index]
    put(("JOB %d/%d"):format(math.min(self.index, #self.jobs), #self.jobs), 3)
    put(job and job.id:sub(1, 18) or "FINISHING", 5)
    put(job and (job.kind == "body" and "CONNECTED BODY" or "FULL MAP") or "", 6)
    put(("BUILT: %d"):format(self.built), 8)
    put(("EXISTING: %d"):format(self.skipped), 9)
    put(("FAILED: %d"):format(self.failed), 10)
    put(("FILES: %d"):format(self.stats.files), 12)
    put(("DISK: %s"):format(sizeText(self.stats.bytes)), 13)
    put("B:CANCEL", 15)
  elseif self.phase == "unavailable" then
    put("DISK CACHE IS NOT", 4)
    put("AVAILABLE ON THIS", 5)
    put("LOVE BUILD.", 6)
    put("A/B:BACK", 15)
  else
    local result = self.phase == "complete" and "COMPLETE"
                   or (self.phase == "incomplete" and "INCOMPLETE" or "CANCELLED")
    put(result, 3)
    put(("MAPS: %d"):format(self.stats.maps), 5)
    put(("FILES: %d"):format(self.stats.files), 6)
    put(("FULL: %d"):format(self.stats.full), 7)
    put(("BODY: %d"):format(self.stats.body), 8)
    put(("AUX: %d"):format(self.stats.aux), 9)
    put(("DISK: %s"):format(sizeText(self.stats.bytes)), 11)
    put(("FAILED: %d"):format(self.failed), 12)
    put("A/B:BACK", 15)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return Screen
