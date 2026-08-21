-- Which stage a B-rung fight is on: one disc, one sky.
--
-- All the judgement lives in data/battle_stages.lua. This file is only the
-- lookup, and it is deliberately dull -- four passes, first match wins, no
-- inference. A map the table does not know gets DEFAULT rather than an
-- error, so an imported ROM that adds locations still fights on something.
--
-- ------- the four passes
--
--   1. species   a legendary standing on its own map
--   2. trainer   a Gym Leader, an Elite Four member, the rival
--   3. terrain   surfing or fishing, which replaces the ground but not the sky
--   4. map       everywhere else
--
-- Bosses sit ABOVE maps rather than replacing them, which is the whole point
-- of having a trainer pass at all: a gym's ordinary trainers keep the gym's
-- own floor and the leader stands on something else, so walking in and then
-- facing the leader is a visible change of ground.

local V = ...

local BattleStages = {}

local DATA = V.data("battle_stages")

local function stage(name)
  return DATA.stages[name] or DATA.stages.DEFAULT
end

-- The trainer class of the opponent, as the engine spells it ("OPP_BROCK"),
-- or nil for a wild encounter. `oppClass` is the same field BattleArt reads
-- for trainer portraits, so the two can never disagree about who this is.
-- Read defensively: a field that moves should cost a boss disc, not the
-- battle.
local function trainerClass(battle)
  if type(battle) ~= "table" then return nil end
  local v = battle.oppClass
  return type(v) == "string" and v or nil
end

local function speciesName(battle)
  if type(battle) ~= "table" then return nil end
  local mon = battle.enemy or battle.enemyMon
  local v = type(mon) == "table" and (mon.species or mon.name) or nil
  return type(v) == "string" and v or nil
end

-- ------- the passes

local function bySpecies(mapId, battle)
  local name = speciesName(battle)
  local hit = name and DATA.species[name]
  -- species AND map, so an ordinary party member never turns a route battle
  -- into a legendary encounter
  if hit and hit.map == mapId then return hit.stage end
  return nil
end

local function byTrainer(mapId, battle)
  local class = trainerClass(battle)
  if not class then return nil end
  if DATA.rivals[class] then
    return DATA.rivalIndoor[mapId] and "rival_in" or "rival"
  end
  local hit = DATA.trainers[class]
  if not hit then return nil end
  -- an entry is either { map =, stage = } or a map-keyed table for a trainer
  -- fought in more than one place
  if hit.stage then
    if hit.map == nil or hit.map == mapId then return hit.stage end
    return nil
  end
  return hit[mapId]
end

local function byTerrain(mapId, battle)
  if type(battle) ~= "table" then return nil end
  -- the mod stamps encounter provenance onto the battle while the
  -- overworld still owns it (see OverworldBattle); these are those fields
  local surf, fish = battle.soloBattleSurfing, battle.soloBattleFishing
  if not (surf or fish) then return nil end
  local set = fish and DATA.fishStage or DATA.surfStage
  return set[mapId] or set.DEFAULT
end

-- ------- the answer

-- The stage for this fight: { disc = <name>, sky = <ramp or "cycle"> }.
function BattleStages.forBattle(map, battle)
  local mapId = type(map) == "table" and (map.id or (map.def and map.def.id))
  if type(mapId) ~= "string" then mapId = nil end
  local name = (mapId and bySpecies(mapId, battle))
            or (mapId and byTrainer(mapId, battle))
            or (mapId and byTerrain(mapId, battle))
            or (mapId and DATA.maps[mapId])
            or "DEFAULT"
  return stage(name), name
end

-- The sky a stage stands under, as Sky.dress leaves it: a flat fill with a
-- `bands` array hung off it, which is exactly what the band pass already
-- knows how to render. "cycle" means hand it back to the hour instead.
-- Converted band lists, memoised by the ramp they came from.
--
-- Sky's rampFor caches the band TEXTURE by table IDENTITY, so handing it a
-- freshly built list every frame rebuilds one and leaks the old -- a GPU
-- texture per frame. One table per stage, reused forever, is what that cache
-- is expecting.
local bandCache = {}

local function bandsFor(ramp)
  local hit = bandCache[ramp]
  if hit then return hit end
  local bands = {}
  for i, c in ipairs(ramp) do
    bands[i] = { c[1] / 255, c[2] / 255, c[3] / 255 }
  end
  bandCache[ramp] = bands
  return bands
end

function BattleStages.dress(entry, fill)
  if not (entry and fill) then return fill end
  if entry.sky == nil or entry.sky == "cycle" then return nil end
  local bands = bandsFor(entry.sky)
  -- The clear behind the bands. Sky.dress uses the LAST band -- the haze the
  -- world sits in below the horizon -- but a disc rung paints the whole frame
  -- (fullBands), so the clear is only a guard for when the band pass declines
  -- outright. The middle stop is the safe value there; the darkest one reads
  -- as a black screen, which is exactly how this failed the first time.
  local guard = bands[math.max(1, math.ceil(#bands / 2))]
  fill[1], fill[2], fill[3] = guard[1], guard[2], guard[3]
  fill.bands = bands
  fill.fullBands = true
  return fill
end

return BattleStages
