-- assets_transforms.lua (Solo Battle Voxel)
--
-- gen1recomp's own importer keys Pokemon battle pics with a border-only
-- flood fill (src/import/ImageWriter.lua, matteColor0): it floods the
-- matte colour in from the canvas edge, so a white pocket sealed off from
-- the border by outline alone (the gap between a Pokemon's front legs, the
-- underside of a tail, between Victreebel's body and its vine-arm) never
-- gets keyed and stays opaque white.
--
-- This recipe re-derives every Pokemon front/back picture gen1recomp has
-- already decoded from YOUR OWN ROM (assets/generated/battle/front|back/),
-- tunnelling the flood through outline (pure black) pixels too -- without
-- erasing the outline itself -- so it can reach those sealed-off pockets.
-- SPRITE_OUTLINE below also grows the cleaned silhouette by one pixel and
-- fills the new ring white (the Emerald Seaglass look).
--
-- Why a recipe and not a patched engine file: this runs through
-- gen1recomp's own sanctioned asset-transform hook (17-total-conversions.md
-- "assets_transforms"), so it ships no Pokemon pixels of its own -- only
-- this code, which reads and rewrites YOUR locally-imported cache. It
-- writes to save/mod-derived/SOLO_BATTLE_VOXEL/, which src/render/Assets.lua
-- reads in preference to assets/generated/ everywhere that picture is
-- shown (battle, Pokedex, party, status screen), without touching a single
-- gen1recomp file -- so a gen1recomp update can't clobber it, and it
-- doesn't need you to find or patch anything inside the engine, or ever
-- re-import your ROM by hand. It re-runs itself automatically (via
-- AssetTransform's stamp) whenever this file changes or the ROM cache is
-- re-imported.
--
-- The species list and its front/back filenames below are pulled straight
-- from gen1recomp's own bundled tools/rom_manifest.json (pokemonAssets),
-- confirmed identical across the Red, Blue and Yellow manifests -- not
-- guessed from a third-party source. back is front .. "b" for all 151, so
-- only front is listed.

local SPRITE_OUTLINE = true  -- false = fix the enclosed-gap bug only

-- National Dex 1-151, gen1recomp's own "front" slug for each.
local SPECIES = {
  "bulbasaur","ivysaur","venusaur","charmander","charmeleon","charizard",
  "squirtle","wartortle","blastoise","caterpie","metapod","butterfree",
  "weedle","kakuna","beedrill","pidgey","pidgeotto","pidgeot",
  "rattata","raticate","spearow","fearow","ekans","arbok",
  "pikachu","raichu","sandshrew","sandslash","nidoranf","nidorina",
  "nidoqueen","nidoranm","nidorino","nidoking","clefairy","clefable",
  "vulpix","ninetales","jigglypuff","wigglytuff","zubat","golbat",
  "oddish","gloom","vileplume","paras","parasect","venonat",
  "venomoth","diglett","dugtrio","meowth","persian","psyduck",
  "golduck","mankey","primeape","growlithe","arcanine","poliwag",
  "poliwhirl","poliwrath","abra","kadabra","alakazam","machop",
  "machoke","machamp","bellsprout","weepinbell","victreebel","tentacool",
  "tentacruel","geodude","graveler","golem","ponyta","rapidash",
  "slowpoke","slowbro","magnemite","magneton","farfetchd","doduo",
  "dodrio","seel","dewgong","grimer","muk","shellder",
  "cloyster","gastly","haunter","gengar","onix","drowzee",
  "hypno","krabby","kingler","voltorb","electrode","exeggcute",
  "exeggutor","cubone","marowak","hitmonlee","hitmonchan","lickitung",
  "koffing","weezing","rhyhorn","rhydon","chansey","tangela",
  "kangaskhan","horsea","seadra","goldeen","seaking","staryu",
  "starmie","mr.mime","scyther","jynx","electabuzz","magmar",
  "pinsir","tauros","magikarp","gyarados","lapras","ditto",
  "eevee","vaporeon","jolteon","flareon","porygon","omanyte",
  "omastar","kabuto","kabutops","aerodactyl","snorlax","articuno",
  "zapdos","moltres","dratini","dragonair","dragonite","mewtwo",
  "mew",
}

-- Non-species battle pics the importer writes the same way (RomExtractor:
-- extractPokemon's trailing loops). Fossils and the Silph ghost are front-
-- only, written under battle/front/; the three player intro portraits are
-- flat, written directly under battle/.
local FRONT_ONLY = { "fossilaerodactyl", "fossilkabutops", "ghost" }
local FLAT = { "redb", "oldmanb", "profoakb" }

local function isWhite(r, g, b, a)
  return r > 0.999 and g > 0.999 and b > 0.999 and a > 0.999
end
local function isInk(r, g, b, a)
  return r < 0.001 and g < 0.001 and b < 0.001 and a > 0.999
end

local function tunnelFix(data, w, h)
  local seen, stack, top = {}, {}, 0
  local function push(x, y)
    if x < 0 or y < 0 or x >= w or y >= h then return end
    local i = y * w + x
    if seen[i] then return end
    local r, g, b, a = data:getPixel(x, y)
    if a <= 0.001 or isWhite(r, g, b, a) or isInk(r, g, b, a) then
      seen[i], top = true, top + 1
      stack[top] = i
    end
  end
  -- Seed from every pixel the importer's own border-only pass already
  -- keyed, anywhere in the image -- not just the border, since the pockets
  -- this exists to fix are by definition not border-connected -- plus the
  -- border itself, as a fallback for a picture that arrives still opaque.
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local _, _, _, a = data:getPixel(x, y)
      if a <= 0.001 then push(x, y) end
    end
  end
  for x = 0, w - 1 do push(x, 0); push(x, h - 1) end
  for y = 0, h - 1 do push(0, y); push(w - 1, y) end
  while top > 0 do
    local i = stack[top]; stack[top], top = nil, top - 1
    local x, y = i % w, math.floor(i / w)
    local r, g, b, a = data:getPixel(x, y)
    -- Ink pixels stay opaque; they're visited only so the flood can
    -- tunnel along the outline to reach a sealed-off matte pocket.
    if isWhite(r, g, b, a) then
      data:setPixel(x, y, r, g, b, 0)
    end
    push(x - 1, y); push(x + 1, y); push(x, y - 1); push(x, y + 1)
  end
end

local function addOutline(data, w, h)
  local additions
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local _, _, _, a = data:getPixel(x, y)
      if a <= 0.001 then
        local hit = false
        for dy = -1, 1 do
          for dx = -1, 1 do
            if not (dx == 0 and dy == 0) then
              local nx, ny = x + dx, y + dy
              if nx >= 0 and ny >= 0 and nx < w and ny < h then
                local _, _, _, na = data:getPixel(nx, ny)
                if na > 0.001 then hit = true break end
              end
            end
          end
          if hit then break end
        end
        if hit then
          additions = additions or {}
          additions[#additions + 1] = { x, y }
        end
      end
    end
  end
  if not additions then return end
  for _, p in ipairs(additions) do
    data:setPixel(p[1], p[2], 1, 1, 1, 1)
  end
end

local function fixOne(ctx, rel)
  if not ctx.exists(rel) then return false end
  local data = ctx.readImage(rel)
  local w, h = data:getDimensions()
  tunnelFix(data, w, h)
  if SPRITE_OUTLINE then addOutline(data, w, h) end
  ctx.writeImage(data, rel)
  return true
end

return function(ctx)
  for _, species in ipairs(SPECIES) do
    fixOne(ctx, "battle/front/" .. species .. ".png")
    fixOne(ctx, "battle/back/" .. species .. "b.png")
  end
  for _, name in ipairs(FRONT_ONLY) do
    fixOne(ctx, "battle/front/" .. name .. ".png")
  end
  for _, name in ipairs(FLAT) do
    fixOne(ctx, "battle/" .. name .. ".png")
  end
end
