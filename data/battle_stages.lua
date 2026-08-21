-- Location routing for 3D-BTL: B.
--
-- Two things are chosen here, and only these two: which DISC the fight is
-- staged on, and what SKY stands behind it. A B rung draws no map, so this
-- table is the whole of what makes one place look different from another.
--
-- Values name a disc file and a sky ramp, never a live Map object. Keeping
-- it pure data makes coverage auditable and lets an imported ROM fail open
-- when it adds a map id this Kanto table does not know: an unrouted map
-- gets DEFAULT rather than an error, and an unrouted disc name falls back
-- to the generated platform in DiscStage.
--
-- ------- how a stage is picked
--
-- Four passes, first match wins:
--
--   1. species   -- a legendary on its own map
--   2. trainer   -- a gym leader, an Elite Four member, the rival
--   3. terrain   -- surfing or fishing, which overrides the map's ground
--   4. map       -- everything else
--
-- Bosses sit above maps rather than replacing them, so a gym's ordinary
-- trainers keep the gym's own floor and the LEADER stands on something
-- else. Walking in and then facing the leader is a visible change of
-- ground, which is the whole reason the boss pass exists.
--
-- ------- how a sky is picked
--
-- `sky = "cycle"` hands the whole thing to DayNight: the ramp is the hour's
-- own, so an outdoor fight at midnight is under a midnight sky and the same
-- fight at dawn is not. Everything else is a fixed ramp, top band first,
-- because a cave does not care what time it is.
--
-- Ramps are 0..255 and are read top-of-frame to bottom. Three stops is
-- usually enough; the band renderer interpolates and dithers between them
-- (see Sky.DITHER), which is what keeps a two-colour void from banding.

-- ------- the skies

local skies = {
  cave       = { { 26, 24, 38 }, { 38, 34, 54 }, { 18, 16, 26 } },
  cave_warm  = { { 44, 32, 28 }, { 58, 42, 34 }, { 26, 18, 16 } },
  cave_ice   = { { 40, 62, 88 }, { 58, 84, 112 }, { 24, 38, 56 } },
  indoor     = { { 46, 46, 54 }, { 58, 58, 68 }, { 30, 30, 36 } },
  indoor_war = { { 64, 52, 40 }, { 82, 66, 50 }, { 38, 30, 24 } },
  facility   = { { 40, 48, 62 }, { 54, 64, 82 }, { 24, 30, 40 } },
  ssanne     = { { 248, 248, 248 }, { 150, 205, 245 }, { 46, 116, 190 } },
  silph      = { { 38, 62, 124 }, { 72, 116, 196 }, { 16, 20, 42 } },
  hideout    = { { 28, 86, 96 }, { 40, 140, 110 }, { 14, 38, 44 } },
  oakslab    = { { 168, 146, 236 }, { 112, 150, 232 }, { 48, 46, 110 } },
  rocket     = { { 32, 30, 40 }, { 44, 40, 54 }, { 18, 16, 24 } },
  tower      = { { 196, 178, 232 }, { 132, 104, 186 }, { 56, 40, 88 } },
  mansion    = { { 52, 32, 40 }, { 104, 52, 58 }, { 20, 14, 18 } },
  powerplant = { { 44, 46, 40 }, { 68, 70, 52 }, { 24, 26, 22 } },
  gym_rock   = { { 72, 62, 52 }, { 96, 84, 70 }, { 40, 34, 28 } },
  gym_water  = { { 30, 48, 92 }, { 44, 68, 124 }, { 16, 26, 52 } },
  gym_elec   = { { 38, 42, 54 }, { 60, 66, 84 }, { 20, 22, 30 } },
  gym_grass  = { { 44, 74, 48 }, { 62, 100, 66 }, { 24, 42, 28 } },
  gym_poison = { { 52, 34, 72 }, { 72, 48, 100 }, { 28, 18, 40 } },
  gym_psy    = { { 66, 40, 92 }, { 92, 58, 126 }, { 34, 20, 48 } },
  gym_fire   = { { 84, 40, 28 }, { 116, 58, 36 }, { 44, 20, 14 } },
  gym_ground = { { 56, 48, 36 }, { 76, 66, 48 }, { 28, 24, 18 } },
  dojo       = { { 74, 58, 36 }, { 98, 78, 50 }, { 38, 30, 18 } },
  league     = { { 34, 30, 46 }, { 50, 44, 66 }, { 18, 16, 24 } },
  lorelei    = { { 96, 132, 168 }, { 132, 172, 208 }, { 52, 74, 100 } },
  bruno      = { { 72, 52, 40 }, { 98, 72, 54 }, { 36, 26, 20 } },
  agatha     = { { 36, 28, 52 }, { 52, 40, 74 }, { 16, 12, 26 } },
  lance      = { { 78, 30, 30 }, { 108, 44, 44 }, { 38, 14, 14 } },
  champion   = { { 40, 50, 92 }, { 60, 74, 132 }, { 20, 26, 48 } },
  void       = { { 12, 10, 20 }, { 22, 18, 34 }, { 6, 5, 10 } },
  mewtwo     = { { 30, 16, 48 }, { 52, 28, 82 }, { 12, 6, 20 } },
}

-- ------- the stages

local stages = {
  DEFAULT     = { disc = "grass",      sky = "cycle" },

  -- outdoors: the disc changes, the sky is always the hour's own
  grass       = { disc = "grass",      sky = "cycle" },
  forest      = { disc = "forest",     sky = "cycle" },
  rocky       = { disc = "rock",       sky = "cycle" },
  sandy       = { disc = "sand",       sky = "cycle" },
  town        = { disc = "tile_warm",  sky = "cycle" },
  surf        = { disc = "water",      sky = "cycle" },

  -- underground and indoors: a fixed ramp, because there is no sky to see
  cave        = { disc = "cave",       sky = skies.cave },
  cave_light  = { disc = "sand",       sky = skies.cave_warm },
  cave_ice    = { disc = "ice",        sky = skies.cave_ice },
  cave_surf   = { disc = "water",      sky = skies.cave },
  building    = { disc = "tile_warm",  sky = skies.indoor_war },
  ship        = { disc = "ssanne_deck", sky = skies.ssanne },
  facility    = { disc = "silph_check", sky = skies.silph },
  lab         = { disc = "oaks_lab",   sky = skies.oakslab },
  rocket      = { disc = "hideout_check", sky = skies.hideout },
  tower       = { disc = "tower_brick", sky = skies.tower },
  mansion     = { disc = "mansion_check", sky = skies.mansion },
  powerplant  = { disc = "metal",      sky = skies.powerplant },

  -- the gyms, for their ordinary trainers
  gym_rock    = { disc = "rock",       sky = skies.gym_rock },
  gym_water   = { disc = "gymwater",   sky = skies.gym_water },
  gym_elec    = { disc = "metal",      sky = skies.gym_elec },
  gym_grass   = { disc = "flowers",    sky = skies.gym_grass },
  gym_poison  = { disc = "toxic",      sky = skies.gym_poison },
  gym_psy     = { disc = "psychic",    sky = skies.gym_psy },
  gym_fire    = { disc = "volcanic",   sky = skies.gym_fire },
  gym_ground  = { disc = "tile_dark",  sky = skies.gym_ground },
  dojo        = { disc = "dojo",       sky = skies.dojo },

  -- the League
  league      = { disc = "league",     sky = skies.league },

  -- the title fights
  brock       = { disc = "leader_brock",    sky = skies.gym_rock },
  misty       = { disc = "leader_misty",    sky = skies.gym_water },
  surge       = { disc = "leader_surge",    sky = skies.gym_elec },
  erika       = { disc = "leader_erika",    sky = skies.gym_grass },
  koga        = { disc = "leader_koga",     sky = skies.gym_poison },
  sabrina     = { disc = "leader_sabrina",  sky = skies.gym_psy },
  blaine      = { disc = "leader_blaine",   sky = skies.gym_fire },
  giovanni    = { disc = "leader_giovanni", sky = skies.gym_ground },
  lorelei     = { disc = "ice",        sky = skies.lorelei },
  bruno       = { disc = "dojo",       sky = skies.bruno },
  agatha      = { disc = "ghost",      sky = skies.agatha },
  lance       = { disc = "dragon",     sky = skies.lance },
  champion    = { disc = "champion",   sky = skies.champion },
  rival       = { disc = "rival",      sky = "cycle" },
  rival_in    = { disc = "rival",      sky = skies.indoor },

  -- the legendaries
  zapdos      = { disc = "metal",      sky = skies.powerplant },
  articuno    = { disc = "ice",        sky = skies.cave_ice },
  moltres     = { disc = "volcanic",   sky = skies.league },
  mewtwo      = { disc = "space",      sky = skies.mewtwo },
  mew         = { disc = "space",      sky = skies.void },
}

-- ------- the maps

local maps = {}
local function assign(stage, ids)
  for _, id in ipairs(ids) do maps[id] = stage end
end

-- Towns and cities. Paved ground rather than grass: a Gen 1 city battle
-- happens on the road.
assign("town", {
  "PALLET_TOWN", "VIRIDIAN_CITY", "PEWTER_CITY", "CERULEAN_CITY",
  "LAVENDER_TOWN", "CELADON_CITY", "FUCHSIA_CITY", "SAFFRON_CITY",
  "VERMILION_CITY", "CINNABAR_ISLAND", "VERMILION_DOCK",
})
maps.INDIGO_PLATEAU = "league"

-- Routes, grouped by what is actually underfoot rather than by number.
assign("grass", {
  "ROUTE_1", "ROUTE_2", "ROUTE_5", "ROUTE_6", "ROUTE_7", "ROUTE_8",
  "ROUTE_11", "ROUTE_12", "ROUTE_13", "ROUTE_14", "ROUTE_15", "ROUTE_16",
  "ROUTE_22", "ROUTE_24", "ROUTE_25",
})
assign("rocky", { "ROUTE_3", "ROUTE_4", "ROUTE_9", "ROUTE_10", "ROUTE_23" })
assign("sandy", { "ROUTE_17", "ROUTE_18", "ROUTE_19", "ROUTE_20", "ROUTE_21" })
assign("grass", {
  "SAFARI_ZONE_CENTER", "SAFARI_ZONE_EAST", "SAFARI_ZONE_NORTH",
  "SAFARI_ZONE_WEST",
})
maps.VIRIDIAN_FOREST = "forest"

-- Caves and tunnels. Mt Moon and the Rock Tunnel are lit stone; the
-- Diglett/Underground warrens and Cerulean Cave are not.
assign("cave_light", {
  "MT_MOON_1F", "MT_MOON_B1F", "MT_MOON_B2F",
  "ROCK_TUNNEL_1F", "ROCK_TUNNEL_B1F",
})
assign("cave", {
  "DIGLETTS_CAVE", "DIGLETTS_CAVE_ROUTE_2", "DIGLETTS_CAVE_ROUTE_11",
  "UNDERGROUND_PATH_NORTH_SOUTH", "UNDERGROUND_PATH_WEST_EAST",
  "UNDERGROUND_PATH_ROUTE_5", "UNDERGROUND_PATH_ROUTE_6",
  "UNDERGROUND_PATH_ROUTE_6_COPY", "UNDERGROUND_PATH_ROUTE_7",
  "UNDERGROUND_PATH_ROUTE_7_COPY", "UNDERGROUND_PATH_ROUTE_8",
  "CERULEAN_CAVE_1F", "CERULEAN_CAVE_2F", "CERULEAN_CAVE_B1F",
})
assign("cave_ice", {
  "SEAFOAM_ISLANDS_1F", "SEAFOAM_ISLANDS_B1F", "SEAFOAM_ISLANDS_B2F",
  "SEAFOAM_ISLANDS_B3F", "SEAFOAM_ISLANDS_B4F",
})
assign("league", {
  "VICTORY_ROAD_1F", "VICTORY_ROAD_2F", "VICTORY_ROAD_3F",
})

-- The gyms, for the trainers who are not the leader.
maps.PEWTER_GYM = "gym_rock"
maps.CERULEAN_GYM = "gym_water"
maps.VERMILION_GYM = "gym_elec"
maps.CELADON_GYM = "gym_grass"
maps.FUCHSIA_GYM = "gym_poison"
maps.SAFFRON_GYM = "gym_psy"
maps.CINNABAR_GYM = "gym_fire"
maps.VIRIDIAN_GYM = "gym_ground"
maps.FIGHTING_DOJO = "dojo"

-- Story facilities.
maps.OAKS_LAB = "lab"
maps.POWER_PLANT = "powerplant"
assign("mansion", {
  "POKEMON_MANSION_1F", "POKEMON_MANSION_2F",
  "POKEMON_MANSION_3F", "POKEMON_MANSION_B1F",
})
assign("tower", {
  "POKEMON_TOWER_1F", "POKEMON_TOWER_2F", "POKEMON_TOWER_3F",
  "POKEMON_TOWER_4F", "POKEMON_TOWER_5F", "POKEMON_TOWER_6F",
  "POKEMON_TOWER_7F",
})
assign("rocket", {
  "ROCKET_HIDEOUT_B1F", "ROCKET_HIDEOUT_B2F", "ROCKET_HIDEOUT_B3F",
  "ROCKET_HIDEOUT_B4F", "ROCKET_HIDEOUT_ELEVATOR",
})
assign("facility", {
  "SILPH_CO_1F", "SILPH_CO_2F", "SILPH_CO_3F", "SILPH_CO_4F",
  "SILPH_CO_5F", "SILPH_CO_6F", "SILPH_CO_7F", "SILPH_CO_8F",
  "SILPH_CO_9F", "SILPH_CO_10F", "SILPH_CO_11F", "SILPH_CO_ELEVATOR",
})
assign("ship", {
  "SS_ANNE_BOW", "SS_ANNE_1F", "SS_ANNE_2F", "SS_ANNE_3F", "SS_ANNE_B1F",
  "SS_ANNE_KITCHEN", "SS_ANNE_CAPTAINS_ROOM", "SS_ANNE_1F_ROOMS",
  "SS_ANNE_2F_ROOMS", "SS_ANNE_B1F_ROOMS",
})

-- The League rooms. Each Elite Four member owns their room outright: there
-- is no ordinary trainer in any of them, so the room IS the title fight and
-- no boss pass is needed to make it special.
maps.LORELEIS_ROOM = "lorelei"
maps.BRUNOS_ROOM = "bruno"
maps.AGATHAS_ROOM = "agatha"
maps.LANCES_ROOM = "lance"
maps.CHAMPIONS_ROOM = "champion"
maps.HALL_OF_FAME = "champion"

-- ------- the boss pass
--
-- Trainer class plus, where it matters, the map. Giovanni is fought three
-- times in three places and keeps his own disc at each; the map key exists
-- so a future content mod adding a fourth cannot silently inherit it.

local trainers = {
  OPP_BROCK    = { map = "PEWTER_GYM",    stage = "brock" },
  OPP_MISTY    = { map = "CERULEAN_GYM",  stage = "misty" },
  OPP_LT_SURGE = { map = "VERMILION_GYM", stage = "surge" },
  OPP_ERIKA    = { map = "CELADON_GYM",   stage = "erika" },
  OPP_KOGA     = { map = "FUCHSIA_GYM",   stage = "koga" },
  OPP_SABRINA  = { map = "SAFFRON_GYM",   stage = "sabrina" },
  OPP_BLAINE   = { map = "CINNABAR_GYM",  stage = "blaine" },
  OPP_GIOVANNI = {
    SILPH_CO_11F = "giovanni",
    ROCKET_HIDEOUT_B4F = "giovanni",
    VIRIDIAN_GYM = "giovanni",
  },
}

-- Every rival fight, indoors and out. RIVAL3 is the Champion class and is
-- deliberately absent: that one is the Champion's room and takes the
-- champion stage from the map pass above.
local rivals = {
  OPP_RIVAL1 = true,
  OPP_RIVAL2 = true,
}

-- Which rival fights are under a roof, so the sky does not try to run the
-- day cycle inside Oak's lab or the Silph office.
local rivalIndoor = {
  OAKS_LAB = true,
  SS_ANNE_2F = true,
  SILPH_CO_7F = true,
  POKEMON_TOWER_2F = true,
}

-- Species and map must both match, so an ordinary party member never turns
-- a route battle into a legendary encounter. Mew is carried for content
-- mods and has no canonical Gen 1 map.
local species = {
  ZAPDOS   = { map = "POWER_PLANT",         stage = "zapdos" },
  ARTICUNO = { map = "SEAFOAM_ISLANDS_B4F", stage = "articuno" },
  MOLTRES  = { map = "VICTORY_ROAD_2F",     stage = "moltres" },
  MEWTWO   = { map = "CERULEAN_CAVE_B1F",   stage = "mewtwo" },
}

-- ------- the terrain pass
--
-- Surfing and fishing replace the ground but not the sky: a fight on the
-- water off Route 20 is still under Route 20's hour, and one in Seafoam is
-- still in a cave.

local surfStage = {
  DEFAULT = "surf",
  SEAFOAM_ISLANDS_1F = "cave_surf", SEAFOAM_ISLANDS_B1F = "cave_surf",
  SEAFOAM_ISLANDS_B2F = "cave_surf", SEAFOAM_ISLANDS_B3F = "cave_surf",
  SEAFOAM_ISLANDS_B4F = "cave_surf",
  CERULEAN_CAVE_1F = "cave_surf", CERULEAN_CAVE_2F = "cave_surf",
  CERULEAN_CAVE_B1F = "cave_surf",
}

return {
  skies = skies,
  stages = stages,
  maps = maps,
  trainers = trainers,
  rivals = rivals,
  rivalIndoor = rivalIndoor,
  species = species,
  surfStage = surfStage,
  fishStage = surfStage,
}
