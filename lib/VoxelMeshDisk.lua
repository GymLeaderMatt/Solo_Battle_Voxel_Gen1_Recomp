-- Persistent raw voxel-mesh streams.
--
-- LOVE Mesh objects are driver/session resources and cannot survive a restart.
-- The six-float vertex streams which create them can: cache those under the
-- save directory, then upload them cooperatively next session instead of
-- rerunning Structures and the terrain carve.
--
-- Every read fails open. Missing, truncated, corrupt, or fingerprint-mismatched
-- files are removed and the ordinary mesher rebuilds them. No user setting or
-- cache id is exposed; CACHE_REVISION is the format/geometry contract and must
-- be bumped whenever emitted vertices change in a way the fingerprint cannot
-- observe directly.

local V = ...

local Budget = V.require("BuildBudget")
local StaticGeometry = V.require("StaticGeometry")

local ffi = nil
do
  local ok, value = pcall(require, "ffi")
  if ok then ffi = value end
end

local Disk = {}
local ramFiles, sessionActive = {}, false
local ramDirty, ramRejected = {}, {}
local ramBytes = 0

-- Current engines sandbox both raw filesystem access and FFI. This module is
-- therefore a legacy acceleration path; ChunkMesher automatically uses its
-- supported table builder when this returns unavailable. Probe the old API
-- behind pcall because merely indexing love.filesystem now raises an error.
local legacyFilesystem
pcall(function() legacyFilesystem = love and love.filesystem end)

Disk.CACHE_REVISION = 2
-- Patch releases which do not change emitted vertices must keep the existing
-- world cache usable. This token matches the first static-mesh-cache-v2 build;
-- CACHE_REVISION, not the public mod version, owns geometry compatibility.
Disk.CACHE_FAMILY = "1.8.1"
Disk.DIRECTORY = "mod-derived/SOLO_BATTLE_VOXEL/static-mesh-cache-v2"

local MAGIC = "BAVC"
local FORMAT = 2
local RAW_CHUNK = 1024 * 1024

local function available()
  local fs = legacyFilesystem
  return ffi ~= nil and fs and fs.read and fs.write and fs.createDirectory
    and fs.newFile and fs.getDirectoryItems
    and love.data and love.data.newByteData
    and love.data.compress and love.data.decompress
    and love.graphics and love.graphics.newMesh
end

function Disk.available()
  return available()
end

local function u32(n)
  n = math.floor(tonumber(n) or 0) % 4294967296
  return string.char(n % 256, math.floor(n / 256) % 256,
                     math.floor(n / 65536) % 256,
                     math.floor(n / 16777216) % 256)
end

local function readU32(s, pos)
  if not s or pos + 3 > #s then return nil end
  return s:byte(pos) + s:byte(pos + 1) * 256
       + s:byte(pos + 2) * 65536 + s:byte(pos + 3) * 16777216
end

local function addList(parts, list)
  parts[#parts + 1] = tostring(#(list or {}))
  for _, value in ipairs(list or {}) do
    if type(value) == "table" then
      addList(parts, value)
    else
      parts[#parts + 1] = tostring(value)
    end
  end
end

-- Exact canonical input description rather than a short probabilistic hash.
-- Map block edits, tileset replacements, connection-mask changes and void-fill
-- changes therefore invalidate themselves without relying on a remembered
-- cleanup event. The revision covers algorithm/data rules not present here.
local function canonicalMasks(map, masks)
  local out, seen = {}, {}
  local def = map and map.def or {}
  -- ChunkMesher's FULL ring extends three 32px blocks. Neighbours outside
  -- that rectangle cannot remove a vertex; runtime survey zoom may discover
  -- more of them than the title generator, and they must not create a false
  -- persistent variant.
  local pad, w, h = 96, (def.width or 0) * 32, (def.height or 0) * 32
  for _, mask in ipairs(masks or {}) do
    local row = { mask[1], mask[2], mask[3], mask[4] }
    local relevant = row[3] > -pad and row[1] < w + pad
                     and row[4] > -pad and row[2] < h + pad
    local key = table.concat(row, ",")
    if relevant and not seen[key] then
      seen[key], out[#out + 1] = true, row
    end
  end
  table.sort(out, function(a, b)
    for i = 1, 4 do
      if a[i] ~= b[i] then return (a[i] or 0) < (b[i] or 0) end
    end
    return false
  end)
  return out
end

function Disk.staticEligible(map)
  return StaticGeometry.source(map) ~= nil
end

function Disk.fingerprint(map, slot, masks, kind)
  map = StaticGeometry.source(map) or map
  -- BODY emits only the map's playable rectangle. Connection masks suppress
  -- the border ring of FULL meshes and cannot alter BODY vertices, so letting
  -- survey/title-screen mask discovery enter this key creates false variants.
  if slot == "body" then masks = nil end
  local def, tileset = map.def or {}, map.tileset or {}
  local parts = {
    "rev", tostring(Disk.CACHE_REVISION),
    "mod", Disk.CACHE_FAMILY,
    "kind", tostring(kind), "slot", tostring(slot),
    "map", tostring(map.id), "tileset", tostring(def.tileset),
    "size", tostring(def.width), tostring(def.height),
    "border", tostring(def.borderBlock),
    "image", tostring(tileset.image),
    "imageSize", tostring(tileset.imageWidth), tostring(tileset.imageHeight),
    "row", tostring(tileset.tilesPerRow),
    "trueColor", tileset.trueColor and "1" or "0",
  }
  local okTR, TileRenderer = pcall(require, "src.render.TileRenderer")
  parts[#parts + 1] = "void"
  parts[#parts + 1] = tostring(okTR and TileRenderer.voidFill or "trees")
  parts[#parts + 1] = "blocks"
  addList(parts, def.blocks)
  parts[#parts + 1] = "tiles"
  addList(parts, tileset.blocks)
  parts[#parts + 1] = "masks"
  addList(parts, canonicalMasks(map, masks))
  return table.concat(parts, "|")
end

local function safeId(id)
  return tostring(id):gsub("[^%w_.-]", "_")
end

local function pathFor(map, slot, kind)
  local suffix = kind == "aux" and "aux" or (tostring(slot) .. ".terrain")
  return Disk.DIRECTORY .. "/" .. safeId(map.id) .. "." .. suffix .. ".bavc"
end

-- Forget a broken/session-stale container without touching persistent storage.
-- Gameplay is deliberately RAM-only; CACHE -> SAVE is the sole runtime path
-- which writes the canonical disk cache.
local function discard(path, rejected)
  local held = ramFiles[path]
  if held then ramBytes = math.max(0, ramBytes - #held) end
  ramFiles[path] = nil
  ramDirty[path] = nil
  if rejected then ramRejected[path] = true end
end

local function header(fp)
  return MAGIC .. u32(FORMAT) .. u32(#fp) .. fp
end

-- CONTINUE may preload the compressed BAVC containers. They remain compressed
-- here (~745 MiB for the current full world rather than ~2.7 GiB of vertices)
-- and are decoded into temporary ByteData only when a map is uploaded.
function Disk.ramPlan()
  if not available() then return {}, 0 end
  local names, bytes = {}, 0
  local ok, listed = pcall(legacyFilesystem.getDirectoryItems, Disk.DIRECTORY)
  if not ok then return names, bytes end
  for _, name in ipairs(listed or {}) do
    if name:sub(-5) == ".bavc" then
      local path = Disk.DIRECTORY .. "/" .. name
      local info = legacyFilesystem.getInfo(path)
      if info and info.type == "file" then
        names[#names + 1] = name
        bytes = bytes + (info.size or 0)
      end
    end
  end
  table.sort(names)
  return names, bytes
end

function Disk.beginSession()
  sessionActive = true
end

function Disk.beginPrecache()
  ramFiles, ramDirty, ramRejected = {}, {}, {}
  ramBytes = 0
  sessionActive = false
  collectgarbage("collect")
end

function Disk.loadIntoRam(name)
  if not sessionActive or type(name) ~= "string"
     or name:find("/", 1, true) or name:sub(-5) ~= ".bavc" then
    return false, 0
  end
  local path = Disk.DIRECTORY .. "/" .. name
  local prior = ramFiles[path]
  if prior then return true, #prior end
  local ok, blob = pcall(legacyFilesystem.read, path)
  if not ok or type(blob) ~= "string" then return false, 0 end
  ramFiles[path] = blob
  ramBytes = ramBytes + #blob
  return true, #blob
end

function Disk.ramReady(names)
  if not sessionActive then return false end
  for _, name in ipairs(names or {}) do
    if not ramFiles[Disk.DIRECTORY .. "/" .. name] then return false end
  end
  return true
end

function Disk.ramStats()
  local files, dirty, dirtyBytes = 0, 0, 0
  for _ in pairs(ramFiles) do files = files + 1 end
  for path in pairs(ramDirty) do
    dirty = dirty + 1
    dirtyBytes = dirtyBytes + #(ramFiles[path] or "")
  end
  return { enabled = sessionActive, files = files, bytes = ramBytes,
           dirty = dirty, dirtyBytes = dirtyBytes }
end

-- DROP abandons both the whole-world preload and any unsaved generated
-- containers. Already-uploaded current/neighbor meshes remain alive; future
-- requests repopulate this table lazily from disk or freshly generated data.
function Disk.dropRam()
  local stats = Disk.ramStats()
  ramFiles, ramDirty, ramRejected = {}, {}, {}
  ramBytes = 0
  sessionActive = true
  collectgarbage("collect")
  return stats
end

local FP_LABEL = {
  rev = true, mod = true, kind = true, slot = true, map = true,
  tileset = true, size = true, border = true, image = true,
  imageSize = true, row = true, trueColor = true, void = true,
  blocks = true, tiles = true, masks = true,
}

local function fingerprintDifference(actual, expected)
  local a, e = {}, {}
  for part in tostring(actual or ""):gmatch("[^|]+") do a[#a + 1] = part end
  for part in tostring(expected or ""):gmatch("[^|]+") do e[#e + 1] = part end
  local n = math.max(#a, #e)
  for i = 1, n do
    if a[i] ~= e[i] then
      local label = "fingerprint"
      for j = i, 1, -1 do
        if FP_LABEL[e[j]] then label = e[j] break end
      end
      return ("%s: stored=%s expected=%s"):format(
        label, tostring(a[i]), tostring(e[i]))
    end
  end
  return "fingerprint differs"
end

local function reportMismatch(map, path, actual, expected, detail)
  StaticGeometry.record(map and map.id, "cache.record", path,
    detail or fingerprintDifference(actual, expected))
end

local function parseHeader(blob, expected)
  if not blob or #blob < 12 or blob:sub(1, 4) ~= MAGIC then return nil, nil end
  local format = readU32(blob, 5)
  local n = readU32(blob, 9)
  if format ~= FORMAT or not n or 12 + n > #blob then return nil, nil end
  local first = 13
  local actual = blob:sub(first, first + n - 1)
  if actual ~= expected then return nil, actual end
  return first + n, actual
end

-- Cheap resume probe for the title-screen whole-game generator.  Reading and
-- decompressing a 20+ MiB route merely to learn that it is already cached
-- would make "resume" nearly as expensive as generating it, so inspect only
-- the fixed header and exact fingerprint.  The ordinary load path still fully
-- validates every stream before gameplay uses it.
local function headerMatches(path, expected, map)
  if not available() then return false end
  local fs = legacyFilesystem
  local info = fs.getInfo and fs.getInfo(path)
  if not (info and info.type == "file" and info.size >= 12) then return false end
  local ok, matches = pcall(function()
    local file = assert(fs.newFile(path, "r"))
    local fixed = file:read(12)
    if not fixed or #fixed ~= 12 or fixed:sub(1, 4) ~= MAGIC
       or readU32(fixed, 5) ~= FORMAT then
      file:close()
      reportMismatch(map, path, nil, expected, "invalid BAVC header/format")
      return false
    end
    local n = readU32(fixed, 9)
    if not n or 12 + n > info.size then
      file:close()
      reportMismatch(map, path, nil, expected, "invalid fingerprint length")
      return false
    end
    local fp = file:read(n)
    file:close()
    if fp ~= expected then reportMismatch(map, path, fp, expected) end
    return fp == expected
  end)
  return ok and matches or false
end

-- Whether one map/slot has both persistent products the renderer will ask
-- for: shared grass/flower/figure data and its terrain+water stream.
function Disk.complete(map, bodyOnly, masks)
  if not map or not Disk.staticEligible(map) then return false end
  local slot = bodyOnly and "body" or "full"
  return headerMatches(pathFor(map, "aux", "aux"),
                       Disk.fingerprint(map, "aux", nil, "aux"), map)
     and headerMatches(pathFor(map, slot, "terrain"),
                       Disk.fingerprint(map, slot, masks, "terrain"), map)
end

-- Small public report used by the generator screen and documentation checks.
-- It never loads cached payloads, only directory entries and file metadata.
function Disk.stats()
  local out = { bytes = 0, files = 0, maps = 0,
                aux = 0, full = 0, body = 0 }
  if not available() then return out end
  local ok, names = pcall(legacyFilesystem.getDirectoryItems, Disk.DIRECTORY)
  if not ok then return out end
  local maps = {}
  for _, name in ipairs(names or {}) do
    if name:sub(-5) == ".bavc" then
      local info = legacyFilesystem.getInfo(Disk.DIRECTORY .. "/" .. name)
      if info and info.type == "file" then
        out.files = out.files + 1
        out.bytes = out.bytes + (info.size or 0)
        local id = name:match("^(.-)%.aux%.bavc$")
                or name:match("^(.-)%.full%.terrain%.bavc$")
                or name:match("^(.-)%.body%.terrain%.bavc$")
        if id then maps[id] = true end
        if name:match("%.aux%.bavc$") then out.aux = out.aux + 1
        elseif name:match("%.full%.terrain%.bavc$") then
          out.full = out.full + 1
        elseif name:match("%.body%.terrain%.bavc$") then
          out.body = out.body + 1
        end
      end
    end
  end
  for _ in pairs(maps) do out.maps = out.maps + 1 end
  return out
end

local function streamRecord(blob, pos)
  local n = readU32(blob, pos)
  if not n then return nil end
  local chunks = readU32(blob, pos + 4)
  if not chunks or chunks > 65536 then return nil end
  pos = pos + 8
  local expected = n * 6 * 4
  if chunks ~= (expected > 0 and math.ceil(expected / RAW_CHUNK) or 0) then
    return nil
  end
  if expected == 0 then return { n = n }, pos end
  -- Allocate the final stable buffer once. The old loader decompressed into a
  -- table of Lua strings and table.concat made a second full-size copy; a
  -- Forest-sized mesh briefly occupied ~172 MiB before upload, and an FFI
  -- pointer into that Lua string was then carried across cooperative yields.
  local data = love.data.newByteData(expected)
  local dataPtr = ffi.cast("uint8_t*", data:getFFIPointer())
  local function fail()
    if data and data.release then pcall(data.release, data) end
    return nil
  end
  local total = 0
  for _ = 1, chunks do
    local rawBytes = readU32(blob, pos)
    local packedBytes = readU32(blob, pos + 4)
    if not rawBytes or rawBytes > RAW_CHUNK
       or total + rawBytes > expected
       or not packedBytes or packedBytes > #blob - pos - 7 then
      return fail()
    end
    local first = pos + 8
    local packed = blob:sub(first, first + packedBytes - 1)
    local ok, raw = pcall(love.data.decompress, "data", "lz4", packed)
    if not ok or not raw or type(raw.getSize) ~= "function"
       or raw:getSize() ~= rawBytes then
      if raw and raw.release then pcall(raw.release, raw) end
      return fail()
    end
    ffi.copy(dataPtr + total, raw:getFFIPointer(), rawBytes)
    if raw.release then pcall(raw.release, raw) end
    total = total + rawBytes
    pos = first + packedBytes
    Budget.check()
  end
  if total ~= expected or (expected == 0 and chunks ~= 0) then return fail() end
  return { n = n, data = data, ptr = dataPtr }, pos
end

local function readValidated(path, fp, map)
  if not available() then return nil end
  local blob = ramFiles[path]
  if not blob then
    if sessionActive and ramRejected[path] then return nil end
    local ok, loaded = pcall(legacyFilesystem.read, path)
    if not ok or not loaded then return nil end
    blob = loaded
    if sessionActive then
      ramFiles[path] = blob
      ramBytes = ramBytes + #blob
    end
  end
  local pos, actual = parseHeader(blob, fp)
  if not pos then
    reportMismatch(map, path, actual, fp,
                   actual and nil or "invalid BAVC header/format")
    discard(path, true)
    return nil
  end
  return blob, pos
end

function Disk.loadTerrain(map, slot, masks)
  if not Disk.staticEligible(map) then return nil end
  local path = pathFor(map, slot, "terrain")
  local fp = Disk.fingerprint(map, slot, masks, "terrain")
  local blob, pos = readValidated(path, fp, map)
  if not blob then return nil end
  local terrain, nextPos = streamRecord(blob, pos)
  local water, finalPos
  if nextPos then water, finalPos = streamRecord(blob, nextPos) end
  if not terrain or not water or finalPos ~= #blob + 1 then
    discard(path, true)
    return nil
  end
  return { terrain = terrain, water = water }
end

local function float4(blob, pos)
  if pos + 15 > #blob then return nil end
  local values = ffi.new("float[4]")
  ffi.copy(values, ffi.cast("const uint8_t*", blob) + pos - 1, 16)
  return { values[0], values[1], values[2], values[3] }, pos + 16
end

function Disk.loadAux(map)
  if not Disk.staticEligible(map) then return nil end
  local path = pathFor(map, "aux", "aux")
  local fp = Disk.fingerprint(map, "aux", nil, "aux")
  local blob, pos = readValidated(path, fp, map)
  if not blob then return nil end
  local grass, p2 = streamRecord(blob, pos)
  local flowers, p3
  if p2 then flowers, p3 = streamRecord(blob, p2) end
  local count = p3 and readU32(blob, p3) or nil
  if not grass or not flowers or not count or count > 1024 then
    discard(path, true); return nil
  end
  pos = p3 + 4
  local figures = {}
  for _ = 1, count do
    local stream, nextPos = streamRecord(blob, pos)
    local meta, finalPos
    if nextPos then meta, finalPos = float4(blob, nextPos) end
    if not stream or not meta then discard(path, true); return nil end
    stream.wx, stream.wz, stream.y, stream.w = meta[1], meta[2], meta[3], meta[4]
    figures[#figures + 1] = stream
    pos = finalPos
  end
  if pos ~= #blob + 1 then discard(path, true); return nil end
  return { grass = grass, flowers = flowers, figures = figures }
end

local function write(file, bytes)
  local ok, err = file:write(bytes)
  if not ok then error(err or "voxel cache write failed", 0) end
end

local function writeChunked(file, ptr, n)
  write(file, u32(n or 0))
  local bytes = (n or 0) * 6 * 4
  local chunks = bytes > 0 and math.ceil(bytes / RAW_CHUNK) or 0
  write(file, u32(chunks))
  if not ptr or not n or n == 0 then return true end
  local offset = 0
  while offset < bytes do
    local count = math.min(RAW_CHUNK, bytes - offset)
    local raw = ffi.string(ffi.cast("const uint8_t*", ptr) + offset, count)
    local packed = love.data.compress("string", "lz4", raw)
    write(file, u32(count))
    write(file, u32(#packed))
    write(file, packed)
    offset = offset + count
    Budget.check()
  end
  return true
end

local function writePersistent(path, blob)
  local ok, err = pcall(function()
    assert(legacyFilesystem.createDirectory(Disk.DIRECTORY))
    local file = assert(legacyFilesystem.newFile(path, "w"))
    local wrote, writeErr = pcall(write, file, blob)
    file:close()
    if not wrote then error(writeErr, 0) end
  end)
  return ok, ok and nil or tostring(err)
end

local function remember(path, blob, dirty)
  local prior = ramFiles[path]
  if prior then ramBytes = math.max(0, ramBytes - #prior) end
  ramFiles[path] = blob
  ramBytes = ramBytes + #blob
  ramDirty[path] = dirty and true or nil
  ramRejected[path] = nil
end

local function encoded(fp, writer)
  local parts = {}
  local sink = {}
  function sink:write(bytes)
    parts[#parts + 1] = bytes
    return true
  end
  write(sink, header(fp))
  writer(sink)
  return table.concat(parts)
end

local function writeFile(path, fp, writer)
  if not available() then return false end
  if sessionActive then
    local ok, blob = pcall(encoded, fp, writer)
    if not ok or type(blob) ~= "string" then return false end
    remember(path, blob, true)
    return true
  end
  -- The title-screen whole-world generator streams directly to disk, avoiding
  -- an additional full-container Lua string beside its large raw mesh.
  local ok = pcall(function()
    assert(legacyFilesystem.createDirectory(Disk.DIRECTORY))
    local file = assert(legacyFilesystem.newFile(path, "w"))
    local wrote, err = pcall(function()
      write(file, header(fp))
      writer(file)
    end)
    file:close()
    if not wrote then error(err, 0) end
  end)
  return ok
end

-- Explicit pause-menu commit. Successful files become clean RAM entries;
-- failures remain dirty so granting storage permission and selecting SAVE
-- again retries exactly the unsaved set.
function Disk.saveRamToDisk()
  if not available() then return false, 0, 0, { "cache API unavailable" } end
  local paths = {}
  for path in pairs(ramDirty) do paths[#paths + 1] = path end
  table.sort(paths)
  local saved, failures, errors = 0, 0, {}
  for _, path in ipairs(paths) do
    local blob = ramFiles[path]
    local ok, err
    if blob then
      ok, err = writePersistent(path, blob)
    else
      ok, err = false, "missing RAM data"
    end
    if ok then
      ramDirty[path] = nil
      saved = saved + 1
    else
      failures = failures + 1
      errors[#errors + 1] = path .. ": " .. tostring(err or "missing RAM data")
    end
    Budget.check()
  end
  return failures == 0, saved, failures, errors
end

function Disk.saveTerrain(map, slot, masks, terrain, water)
  if not Disk.staticEligible(map) then return false end
  local path = pathFor(map, slot, "terrain")
  local fp = Disk.fingerprint(map, slot, masks, "terrain")
  return writeFile(path, fp, function(file)
    writeChunked(file, terrain and terrain.ptr, terrain and terrain.n or 0)
    writeChunked(file, water and water.ptr, water and water.n or 0)
  end)
end

local function f32x4(a, b, c, d)
  local values = ffi.new("float[4]", { a or 0, b or 0, c or 0, d or 0 })
  return ffi.string(values, 16)
end

function Disk.saveAux(map, aux)
  if not Disk.staticEligible(map) then return false end
  local path = pathFor(map, "aux", "aux")
  local fp = Disk.fingerprint(map, "aux", nil, "aux")
  return writeFile(path, fp, function(file)
    writeChunked(file, aux.grass and aux.grass.ptr, aux.grass and aux.grass.n or 0)
    writeChunked(file, aux.flowers and aux.flowers.ptr,
                 aux.flowers and aux.flowers.n or 0)
    write(file, u32(#(aux.figures or {})))
    for _, figure in ipairs(aux.figures or {}) do
      writeChunked(file, figure.ptr, figure.n)
      write(file, f32x4(figure.wx, figure.wz, figure.y, figure.w))
      Budget.check()
    end
  end)
end

return Disk
