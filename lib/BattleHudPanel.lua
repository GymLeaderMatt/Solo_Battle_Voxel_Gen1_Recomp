-- The battle HUD as its own furniture, rather than the ROM's.
--
-- The engine draws each side's status block as black glyphs and a 48x8 gauge
-- straight onto the field, and BattleHud filters those pixels: it recolours
-- the gauge, flips the ink and lays the whole band back down at the window's
-- edge. That works, and it is still what HUD STYLE: OG does. What it cannot
-- do is change the PROPORTIONS: the bar is 8 rows of a 32-row block because
-- the ROM put it there, and scaling the block scales the name and the level
-- with it. A bar that reads across a room needs to be most of its panel, and
-- no amount of scaling a Game Boy HUD produces that.
--
-- So PANEL draws its own: a black box with a white outline, the name at the
-- left, the level (or the status, which replaces it exactly as the ROM does)
-- at the right, and a bar that is over a third of the panel's height.
--
-- Three things are deliberately NOT reimplemented here, because the engine
-- already does them and doing them again would be doing them differently:
--
--   * the drain. `battler.shownHP` is the HP the bar displays, ticked by
--     BattleState:stepHPDrain at hardware timing -- including the detail that
--     the player's bar drains slower than the foe's because the original
--     spends a frame reprinting the number and the enemy HUD does not. Read
--     it and the bar drains exactly like vanilla, for free.
--   * the status reveal. `battler.shownStatus` lags `mon.status` on purpose,
--     so the label appears in step with the animation rather than the instant
--     the move resolves.
--   * the glyphs. Font owns the charmap, which matters for a nickname the
--     player typed with characters that are not ASCII.
--
-- What IS ours is the geometry, and it is sized against the overlay rather
-- than against the Game Boy: PANEL_W is solo_run_overlay's own COLW, in the
-- same design units off the same 1440 reference height, so the panel and the
-- overlay column below it are the same width at every resolution instead of
-- approximately the same width at one of them.

-- the mod namespace (see main.lua): V.require loads a sibling module
local V = ...

local BattleHudPanel = {}

-- ------- geometry
--
-- Design units against a 1440p reference, the same space solo_run_overlay
-- lays out in (its REF_H and COLW). Everything below is multiplied by
-- `H / REF_H` at draw time, so these numbers are the 1440p pixel sizes and
-- the panel tracks the overlay on any display.
--
-- HEIGHT-based, not width-based, and that is the point: the voxel HUD's own
-- older sizing is a fraction of window WIDTH (HUD_TARGET_REF_W), and on any
-- window that is not 16:9 a width rule and a height rule drift apart. Two
-- mods that are supposed to agree about a shared column cannot each pick a
-- different axis.
BattleHudPanel.REF_H = 1440

-- WIDTH is fixed to the overlay column and is the one number that must not
-- grow: horizontal space is what the screen is short of. HEIGHT is free, so
-- the panel buys its presence vertically -- taller box, taller glyphs, taller
-- bar -- rather than by spreading sideways into the arena.
BattleHudPanel.PANEL_W = 463     -- solo_run_overlay COLW; do not grow
BattleHudPanel.PANEL_H = 216

BattleHudPanel.EDGE = 10         -- from the window edge
BattleHudPanel.OUTLINE = 6       -- white border thickness
BattleHudPanel.RADIUS = 34       -- outer corner radius
BattleHudPanel.PAD = 12          -- inside the outline
BattleHudPanel.BAR_H = 64
BattleHudPanel.BAR_OUTLINE = 6
BattleHudPanel.BAR_RADIUS = 30
BattleHudPanel.COL_GAP = 6       -- name column to level/status column

-- The gap between the name row and the bar is the SAME as the padding above
-- the name and below the bar, so the three margins read as one rhythm rather
-- than as a box with its contents pushed to the ends. Nothing is centred in
-- leftover space -- see panelHeight: the box is as tall as its contents need
-- and no taller, which is also why the player's panel is shorter than the
-- foe's (no ball cluster to make room for).
BattleHudPanel.ROW_GAP = 12

-- The white edge on the coloured fill itself. Without it the fill's moving
-- end is a bare colour-to-track boundary while everything around it is
-- outlined, which reads as unfinished as soon as the bar starts draining.
BattleHudPanel.FILL_OUTLINE = 4

BattleHudPanel.BALL_D = 26       -- one ball, corner to corner
BattleHudPanel.BALL_GAP = 4

-- Names are cut to this many characters and every panel is sized for exactly
-- that many, so the glyphs are the same size on every panel AND as large as
-- the box can carry. Gen 1's cap is 10, and sizing for 10 left a third of the
-- panel empty on the short names that are far more common; 7 is the trade --
-- METAPOD fits whole, VICTREEBEL loses its tail. A nickname avoids the cut.
BattleHudPanel.NAME_MAX = 7

-- Glyph scales are whole numbers in both axes or the strokes come out uneven,
-- which at this size is the difference between "pixel font" and "blurry". The
-- vertical scale runs one step ahead of the horizontal, which fills the row's
-- height without spending any of the width the panel cannot spare. Set to 0
-- for square glyphs at the ROM's own proportions.
BattleHudPanel.NAME_STRETCH = 1

-- How far the foe's panel is lifted off the Game Boy row it hangs from, so it
-- clears the overlay's own enemy column instead of resting on it.
BattleHudPanel.ENEMY_LIFT = 32

-- ------- colour
--
-- The bar's three shades are the constants BattleHud's own brightHpGauge
-- already uses for the filtered ROM gauge, so OG and PANEL cannot disagree
-- about what "half health" looks like.
BattleHudPanel.HP_GREEN = { 0.20, 0.92, 0.32 }
BattleHudPanel.HP_YELLOW = { 1.00, 0.82, 0.05 }
BattleHudPanel.HP_RED = { 1.00, 0.16, 0.10 }

-- The empty part of the bar. NOT the panel's black: a green stub floating in
-- an unbounded black box gives no reading of how much is missing, which is
-- most of what the bar is for once it is low.
BattleHudPanel.TRACK = { 0.22, 0.22, 0.22 }
BattleHudPanel.FILL = { 0, 0, 0 }
BattleHudPanel.OUTLINE_COLOR = { 1, 1, 1 }
BattleHudPanel.TEXT = { 1, 1, 1 }

-- Vanilla draws the status in the same ink as everything else. On a black
-- panel there is no reason not to colour it, and a glanceable status is worth
-- more in a solo run than fidelity to a monochrome constraint.
BattleHudPanel.STATUS_COLOR = {
  SLP = { 1.00, 0.37, 0.81 },
  PSN = { 0.63, 0.31, 0.94 },
  BRN = { 1.00, 0.27, 0.19 },
  FRZ = { 0.25, 0.78, 0.94 },
  PAR = { 1.00, 0.82, 0.05 },
}

BattleHudPanel.HP_HIGH = 0.5
BattleHudPanel.HP_LOW = 0.2

-- ------- turning the font's paper into ink
--
-- Font's pages are OPAQUE four-shade grayscale: Font.draw does not paint a
-- letter, it stamps a white tile with a black letter in it. Dropped straight
-- onto a black panel that is a white bar with black text -- the inverse of
-- what is wanted.
--
-- So the string is rendered once into its own small canvas at 1:1 Game Boy
-- pixels, and THAT is drawn scaled through a shader that keeps the dark
-- pixels, discards the paper and re-emits the ink in whatever colour the
-- caller asked for. Nothing translucent survives to the screen; the panel is
-- opaque throughout.
local INK = [[
  uniform vec3 tint;
  vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
    vec4 p = Texel(tex, tc);
    float luma = dot(p.rgb, vec3(0.299, 0.587, 0.114));
    float a = (p.a > 0.0 && luma <= 0.35) ? 1.0 : 0.0;
    return vec4(tint, a) * color;
  }
]]

local inkShader = nil    -- nil = untried, false = unavailable
local textCache = {}     -- string -> { canvas, w }
local textCount = 0
local ballArt = nil      -- nil = untried, false = none bundled

local function getInk()
  if inkShader == nil then
    local ok, sh = pcall(love.graphics.newShader, INK)
    inkShader = (ok and sh) or false
  end
  return inkShader or nil
end

local function fontModule()
  local ok, Font = pcall(require, "src.render.Font")
  return ok and Font or nil
end

-- The rendered ink for `str`, cached.
--
-- Cached by string rather than rebuilt per frame because binding a canvas is
-- a pipeline break and a name changes about once a battle. The canvas holds
-- Game Boy pixels, so it is resolution-independent -- a window resize scales
-- the draw, it does not invalidate the cache.
local function textImage(str)
  if not str or str == "" then return nil end
  local hit = textCache[str]
  if hit then return hit end
  local Font = fontModule()
  if not Font then return nil end

  local w = Font.width(str)
  if not w or w <= 0 then return nil end
  local ok, canvas = pcall(love.graphics.newCanvas, w, 8)
  if not ok or not canvas then return nil end
  canvas:setFilter("nearest", "nearest")

  local g = love.graphics
  local prevCanvas = g.getCanvas()
  local prevBlend, prevAlpha = g.getBlendMode()
  local drew = pcall(function()
    g.setCanvas(canvas)
    g.clear(0, 0, 0, 0)
    g.setBlendMode("alpha")
    g.setColor(1, 1, 1, 1)
    Font.draw(str, 0, 0)
  end)
  if prevCanvas then g.setCanvas(prevCanvas) else g.setCanvas() end
  g.setBlendMode(prevBlend or "alpha", prevAlpha)
  g.setColor(1, 1, 1, 1)
  if not drew then return nil end

  -- A runaway cache would mean a mod feeding it unbounded strings; names,
  -- levels and five statuses do not, but the cap costs nothing.
  if textCount > 256 then textCache, textCount = {}, 0 end
  textCache[str] = { canvas = canvas, w = w }
  textCount = textCount + 1
  return textCache[str]
end

-- Draw `str` with its top-left at (x, y), magnified `sx` by `sy`, in `color`.
-- Returns the width drawn, so a caller can lay the next thing after it.
function BattleHudPanel.text(str, x, y, sx, sy, color)
  local img = textImage(str)
  if not img then return 0 end
  local sh = getInk()
  local g = love.graphics
  if sh then
    g.setShader(sh)
    pcall(sh.send, sh, "tint", { color[1], color[2], color[3] })
    -- the shader supplies the colour; the draw must not also multiply by it
    g.setColor(1, 1, 1, 1)
  else
    -- No shader: the font's paper comes with it, so the glyphs read as dark
    -- on light instead of light on dark. Legible, right size, wrong polarity
    -- -- and a driver that cannot compile a four-line shader is not a reason
    -- to draw no HUD at all.
    g.setColor(color[1], color[2], color[3], 1)
  end
  g.draw(img.canvas, x, y, 0, sx, sy or sx)
  g.setShader()
  g.setColor(1, 1, 1, 1)
  return img.w * sx
end

function BattleHudPanel.textWidth(str)
  local img = textImage(str)
  return img and img.w or 0
end

-- ------- the party balls
--
-- Drawn rather than blitted. The engine's own sheet is four 8x8 tiles of
-- FOUR-SHADE GRAY: on the Game Boy pipeline the zone pass colours them, but
-- this panel is composited into the world image downstream of that pass, so
-- the tiles arrive gray -- and a gray ball on a black box is the thing that
-- disappeared into the background in the first place.
--
-- A ball is a circle, a band and a button, so it costs a handful of draw
-- calls to make one that is actually red, scales to any size without going
-- mushy against the smooth chrome around it, and needs no art shipped.
-- Custom art overrides it if any is bundled -- see ballImages.
local BALL_RED = { 0.93, 0.11, 0.14 }
local BALL_WHITE = { 0.95, 0.95, 0.95 }
local BALL_DARK = { 0.05, 0.05, 0.05 }
local BALL_KO = { 0.32, 0.32, 0.32 }        -- fainted: no colour left in it
local BALL_KO_DIM = { 0.18, 0.18, 0.18 }
local BALL_STATUS = { 1.00, 0.82, 0.05 }    -- statused: the HUD's own amber

-- Optional bundled art, one PNG per state, at
-- assets/battle/hud/ball_{ok,status,ko}.png. Absent by default: the drawn
-- ball below is the shipped look. Through the mod's asset resolver, never a
-- bare relative path -- the mod is mounted, so "assets/..." on its own
-- resolves against the GAME's root and silently finds nothing.
local function ballImages()
  if ballArt ~= nil then return ballArt or nil end
  local out, found = {}, false
  for _, name in ipairs({ "ok", "status", "ko" }) do
    local ok, img = pcall(function()
      local path = V.mod.assets:path("assets/battle/hud/ball_"
                                     .. name .. ".png")
      local image = love.graphics.newImage(path)
      image:setFilter("nearest", "nearest")
      return image
    end)
    if ok and img then out[name], found = img, true end
  end
  ballArt = found and out or false
  return ballArt or nil
end

local function drawBall(cx, cy, r, state)
  local g = love.graphics
  local art = ballImages()
  if art then
    local img = art[state] or art.ok
    if img then
      local iw, ih = img:getDimensions()
      g.setColor(1, 1, 1, 1)
      g.draw(img, cx - r, cy - r, 0, (r * 2) / iw, (r * 2) / ih)
      return
    end
  end

  local top, bottom, ink = BALL_RED, BALL_WHITE, BALL_DARK
  if state == "ko" then
    top, bottom = BALL_KO, BALL_KO_DIM
  elseif state == "status" then
    top = BALL_STATUS
  end

  g.setColor(bottom[1], bottom[2], bottom[3], 1)
  g.circle("fill", cx, cy, r)
  g.setColor(top[1], top[2], top[3], 1)
  g.arc("fill", cx, cy, r, math.pi, math.pi * 2)
  local band = math.max(1, r * 0.26)
  g.setColor(ink[1], ink[2], ink[3], 1)
  g.rectangle("fill", cx - r, cy - band / 2, r * 2, band)
  g.circle("fill", cx, cy, r * 0.34)
  g.setColor(bottom[1], bottom[2], bottom[3], 1)
  g.circle("fill", cx, cy, r * 0.19)
  g.setColor(ink[1], ink[2], ink[3], 1)
  g.setLineWidth(math.max(1, r * 0.16))
  g.circle("line", cx, cy, r)
  g.setLineWidth(1)
  g.setColor(1, 1, 1, 1)
end

-- Which state a slot is in, matching BattleState:drawBallRow's own reading.
local function ballState(mon)
  if not mon then return nil end            -- omitted, not drawn as empty
  if (mon.hp or 0) <= 0 then return "ko" end
  if mon.status then return "status" end
  return "ok"
end

-- The 2x3 cluster, right-aligned, filling from the right:
--
--     3 2 1
--     6 5 4
--
-- Right-aligned and right-filled so a short party keeps a clean edge against
-- the panel's side instead of trailing a ragged gap. A four-mon trainer puts
-- slot 4 directly under slot 1; a two-mon one gets a single flush pair.
-- Empty slots are omitted rather than drawn as an empty tile, so a rival with
-- two badges does not look like a party that failed to load.
function BattleHudPanel.drawBalls(party, right, top, d, gap)
  if not party then return 0, 0 end
  local r = d / 2
  local drawn = 0
  for slot = 1, 6 do
    local state = ballState(party[slot])
    if state then
      local col = (slot - 1) % 3            -- 0 = rightmost
      local row = math.floor((slot - 1) / 3)
      drawBall(right - r - col * (d + gap), top + r + row * (d + gap),
               r, state)
      drawn = math.max(drawn, slot)
    end
  end
  if drawn == 0 then return 0, 0 end
  local cols = math.min(3, drawn)
  local rows = drawn > 3 and 2 or 1
  return cols * d + (cols - 1) * gap, rows * d + (rows - 1) * gap
end

-- ------- the bar

local function hpColor(frac)
  if frac > BattleHudPanel.HP_HIGH then return BattleHudPanel.HP_GREEN end
  if frac > BattleHudPanel.HP_LOW then return BattleHudPanel.HP_YELLOW end
  return BattleHudPanel.HP_RED
end

-- The bar, with the outline that makes it read as a gauge rather than as a
-- coloured smear on a dark field, and the one clamp the shape needs.
--
-- A rounded fill narrower than the bar is tall stops being a bar: the two end
-- caps meet and it collapses into a lens, then a sliver, then nothing. Which
-- would mean 1 HP and 0 HP look the same, and they are the two states that
-- must never be confused.
--
-- Vanilla has the same problem and solves it the same way -- GetHPBarLength,
-- via Timing.hpBarPixels, clamps to a minimum of one pixel whenever hp > 0.
-- The bottom few percent of the bar stop being linear; that is the correct
-- trade.
function BattleHudPanel.drawBar(x, y, w, h, frac, outline, radius, fillOutline)
  local g = love.graphics
  local oc = BattleHudPanel.OUTLINE_COLOR
  g.setColor(oc[1], oc[2], oc[3], 1)
  g.rectangle("fill", x, y, w, h, radius, radius)

  local ix, iy = x + outline, y + outline
  local iw, ih = w - outline * 2, h - outline * 2
  if iw <= 0 or ih <= 0 then g.setColor(1, 1, 1, 1) return end
  local ir = math.max(0, radius - outline)

  local t = BattleHudPanel.TRACK
  g.setColor(t[1], t[2], t[3], 1)
  g.rectangle("fill", ix, iy, iw, ih, ir, ir)
  if not (frac and frac > 0) then g.setColor(1, 1, 1, 1) return end

  local fw = iw * math.min(1, frac)
  if fw < ih then fw = ih end               -- never thinner than a round cap

  -- the fill gets the same treatment as the box: a white shape with the
  -- colour inset into it, rather than a coloured shape with a stroke drawn
  -- over its edge -- a stroke would straddle the boundary and leave a half
  -- pixel of track colour showing through on the inside of the curve
  local fo = math.min(fillOutline or 0, ih / 2 - 1)
  if fo > 0 then
    g.setColor(oc[1], oc[2], oc[3], 1)
    g.rectangle("fill", ix, iy, fw, ih, ir, ir)
  end
  local cxx, cyy = ix + fo, iy + fo
  local cww, chh = fw - fo * 2, ih - fo * 2
  if cww > 0 and chh > 0 then
    local c = hpColor(frac)
    g.setColor(c[1], c[2], c[3], 1)
    g.rectangle("fill", cxx, cyy, cww, chh,
                math.max(0, ir - fo), math.max(0, ir - fo))
  end
  g.setColor(1, 1, 1, 1)
end

-- ------- how tall the box has to be
--
-- Derived, not declared. The name row is exactly as tall as the taller of the
-- two things in it -- the glyphs, or the ball cluster stacked over the
-- level/status label -- and the box is that plus one padding above, one gap,
-- the bar, and one padding below. Three equal margins, nothing floating in
-- slack, and the player's box comes out shorter than the foe's because it has
-- no cluster to carry.
function BattleHudPanel.layout(s, hasBalls)
  local P = BattleHudPanel
  local w = P.PANEL_W * s
  local outline, pad = P.OUTLINE * s, P.PAD * s
  local cw = w - (outline + pad) * 2
  local gap = P.COL_GAP * s
  local barH = P.BAR_H * s
  local rowGap = P.ROW_GAP * s
  local smallScale = math.max(1, math.floor(cw / 130))

  -- Reserve for the WIDEST label the column can ever hold ("L:100"), not for
  -- the one in hand: a panel that changed width between level 99 and 100, or
  -- between a level and a status, would visibly twitch.
  local labelReserve = 5 * 8 * smallScale
  local ballD, ballGap = P.BALL_D * s, P.BALL_GAP * s
  local clusterW = ballD * 3 + ballGap * 2
  local rightCol = math.max(labelReserve, hasBalls and clusterW or 0)
  local nameW = math.max(0, cw - rightCol - gap)

  local nameX = math.max(1, math.floor(nameW / (P.NAME_MAX * 8)))
  local nameY = nameX + (P.NAME_STRETCH or 0)
  local labelH = 8 * smallScale
  local stack = hasBalls
                and (ballD * 2 + ballGap + ballGap + labelH)
                or labelH
  local rowH = math.max(8 * nameY, stack)

  return {
    w = w, h = outline * 2 + pad * 2 + rowH + rowGap + barH,
    outline = outline, pad = pad, cw = cw, gap = gap,
    barH = barH, rowGap = rowGap, rowH = rowH,
    smallScale = smallScale, nameX = nameX, nameY = nameY,
    nameW = nameW, rightCol = rightCol,
    ballD = ballD, ballGap = ballGap,
  }
end

-- ------- the panel

-- What the bar should read, from the battler the engine is already animating.
local function fractionOf(battler)
  local mon = battler and battler.mon
  if not mon then return nil end
  local maxHP = mon.stats and mon.stats.hp
  if not maxHP or maxHP <= 0 then return nil end
  local shown = battler.shownHP or mon.hp or 0
  if shown < 0 then shown = 0 end
  return math.min(1, shown / maxHP)
end

-- The right-hand label: the status if there is one, the level if there is
-- not. Exactly the ROM's own swap (BattleState:statusLabel is documented as
-- "the HUD label drawn in place of the level for a statused mon"), so the
-- panel never has to find room for both.
local function rightLabel(battler)
  local status = battler and battler.shownStatus
  if status then
    return tostring(status), BattleHudPanel.STATUS_COLOR[status]
                             or BattleHudPanel.TEXT
  end
  local level = battler and battler.mon and battler.mon.level
  return "L:" .. tostring(level or "?"), BattleHudPanel.TEXT
end

-- Draw one panel at (x, y), `w` x `h` window pixels, for `battler`.
-- `party` draws the ball cluster; pass nil for the player's side.
function BattleHudPanel.draw(battler, party, x, y, s)
  if not battler then return end
  local g = love.graphics
  local P = BattleHudPanel
  local L = P.layout(s, party and true or false)
  local w, h = L.w, L.h
  local radius = P.RADIUS * s

  -- box: white outline, then the black field inset into it
  local oc = P.OUTLINE_COLOR
  g.setColor(oc[1], oc[2], oc[3], 1)
  g.rectangle("fill", x, y, w, h, radius, radius)
  local f = P.FILL
  g.setColor(f[1], f[2], f[3], 1)
  g.rectangle("fill", x + L.outline, y + L.outline,
              w - L.outline * 2, h - L.outline * 2,
              math.max(0, radius - L.outline), math.max(0, radius - L.outline))
  g.setColor(1, 1, 1, 1)

  local cx = x + L.outline + L.pad
  local cy = y + L.outline + L.pad
  local right = cx + L.cw

  -- name, cut to NAME_MAX and drawn at the size every panel uses
  local name = battler.name or "?"
  if #name > P.NAME_MAX then name = name:sub(1, P.NAME_MAX) end
  local nameH = 8 * L.nameY
  P.text(name, cx, cy + (L.rowH - nameH) / 2, L.nameX, L.nameY, P.TEXT)

  -- right column: balls above, level-or-status below, both flush right
  local ballH = 0
  if party then
    local _
    _, ballH = P.drawBalls(party, right, cy, L.ballD, L.ballGap)
  end
  local label, labelColor = rightLabel(battler)
  local labelW = P.textWidth(label) * L.smallScale
  local labelH = 8 * L.smallScale
  local labelY = ballH > 0 and (cy + ballH + L.ballGap)
                 or (cy + (L.rowH - labelH) / 2)
  labelY = math.min(labelY, cy + L.rowH - labelH)
  P.text(label, right - labelW, labelY, L.smallScale, L.smallScale, labelColor)

  P.drawBar(cx, cy + L.rowH + L.rowGap, L.cw, L.barH, fractionOf(battler),
            P.BAR_OUTLINE * s, P.BAR_RADIUS * s, P.FILL_OUTLINE * s)
end

-- ------- where the two panels go
--
-- The sides keep the arrangement the snapped HUD already uses (the foe on the
-- right, the player on the left, per HUD_SIDES_SWAPPED), because that is what
-- the overlay's own columns were laid out around.
--
-- Vertically BOTH panels hang UP from the text box's top edge -- the anchor
-- HUD_PIN names in Game Boy rows, resolved here through the letterbox so it
-- holds on any window, then lifted by ENEMY_LIFT so the panels clear the
-- overlay's own enemy column rather than resting on it. ONE baseline for the
-- pair is what keeps the two HP bars on the same line. HUD_PIN.playerTop is
-- the OG band's anchor and is deliberately not used here: it is tuned to the
-- band's geometry, not the panel's.
--
-- Both edges are measured to the OUTSIDE of the white outline, which is what
-- the eye lines up against: the outline is part of the panel, not something
-- drawn around it.
function BattleHudPanel.place(shot, swapped, pin, enemyHasBalls)
  local s = (shot.ph or 0) / BattleHudPanel.REF_H
  if s <= 0 then return nil end
  local P = BattleHudPanel
  local pl = P.layout(s, false)
  local en = P.layout(s, enemyHasBalls and true or false)
  local edge = P.EDGE * s
  local playerX = swapped and edge or (shot.pw - edge - pl.w)
  local enemyX = swapped and (shot.pw - edge - en.w) or edge
  -- Both panels hang UP from ONE shared baseline, so their bottom edges line
  -- up -- and with them the HP bars, which sit at the bottom of each box.
  -- The player used to hang DOWN from HUD_PIN.playerTop, a row tuned for the
  -- OG band's geometry rather than this panel's, which left it sitting high.
  local baseline = shot.ly + (pin and pin.enemyBottom or 96) * shot.scale
                   - P.ENEMY_LIFT * s
  local playerY = baseline - pl.h
  local enemyY = baseline - en.h
  return {
    player = { playerX, playerY },
    enemy = { enemyX, enemyY },
    scale = s,
  }
end

function BattleHudPanel.invalidate()
  textCache, textCount = {}, 0
  ballArt = nil
end

return BattleHudPanel
