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
BattleHudPanel.RADIUS = 30       -- outer corner radius

-- ONE gap, and it is every gap in the panel: the top of the black field to
-- the name, the name to the bar, the bar to the bottom of the black field,
-- and both sides.
--
-- Measured INSIDE the outline, and that is the whole point. Measuring from
-- the outer edge is arithmetically tidier and visibly wrong: the top and
-- bottom gaps each spend an OUTLINE of their length on white border, the
-- middle one spends none, so three equal numbers land on screen as 6px, 11px,
-- 6px. The outline is a hard edge, not space -- what the eye measures is the
-- black, so the black is what gets padded.
--
--     +==========================+  <- OUTLINE, the frame
--     |                          |     PAD
--     |  NAME              L:15  |     the name's ink
--     |                          |     PAD
--     |  [=========-----------]  |     BAR_H
--     |                          |     PAD
--     +==========================+
--
-- 11 rather than 12 because it keeps the panel at exactly the height the
-- outer-edge version had: the name comes down about a pixel and a half at a
-- 1080-ish window and the gap under it loses about three, which is the whole
-- correction, with no change to where either panel sits.
BattleHudPanel.PAD = 11

-- The bar is the panel's whole reason for existing, but it was reading as a
-- slab rather than as a gauge: 64 units tall with a 6-unit rim around the
-- track and another 4 around the fill meant a third of the bar was edge. 48
-- is the same bar a quarter thinner, and the two rims come down with it --
-- still enough to hold the fill off the track and the track off the black
-- field, without the outline being the loudest thing on the panel.
BattleHudPanel.BAR_H = 48
BattleHudPanel.BAR_OUTLINE = 4
BattleHudPanel.BAR_RADIUS = 24   -- exactly BAR_H/2: a true pill, no flat run

-- The MINIMUM clear air between the name and the level/status, not the actual
-- gap: the name is left-aligned and the label right-aligned, so whatever is
-- left over between them is the gap, and for a name of ordinary length that is
-- most of the panel. This number only binds in the one case where both are as
-- long as they can be, and it is what the glyph size is solved against.
BattleHudPanel.COL_GAP = 13

-- The label the NAME'S SIZE is solved against: "L:99", "SLP", "PSN" -- four
-- cells, which covers every status and every level up to 99.
--
-- Sizing against the five of "L:100" instead costs the name a whole glyph
-- step, which is a permanent price paid for levels 100 and up. The name is fit
-- to the label actually in hand at draw time (see draw), so a level-100 mon
-- with a maximum-length name loses its last CHARACTER for those few battles
-- rather than every name in the game losing a fifth of its size. Nothing
-- resizes and nothing overlaps either way.
BattleHudPanel.LABEL_FIT = 4

-- ------- where the glyphs actually are
--
-- The font's cell is 8 rows; the LETTERS are not. Gen 1's uppercase leaves
-- blank rows in the cell (the baseline is not the last row), and every gap
-- measured against the cell therefore comes out that much bigger than it
-- looks -- which is why the space under the name read as much larger than the
-- space above it even when the two numbers matched. Rows are measured from
-- the INK instead: fontInk() reads the font's real top and bottom row once,
-- and PAD is applied to those.
--
-- These are the fallback if the probe cannot be read back (a driver that
-- refuses canvas readback). The whole cell is never WRONG, only a little
-- loose under the name -- the old behaviour exactly.
BattleHudPanel.INK_TOP = 0
BattleHudPanel.INK_BOTTOM = 8

-- The white edge on the coloured fill itself. Without it the fill's moving
-- end is a bare colour-to-track boundary while everything around it is
-- outlined, which reads as unfinished as soon as the bar starts draining.
BattleHudPanel.FILL_OUTLINE = 3

-- ------- the party pill
--
-- The balls are NOT inside the panel any more. They used to stack over the
-- level in the right-hand column, which made the foe's box taller than the
-- player's by the height of a ball cluster -- the two sides never matched,
-- and the foe's name row carried a hole in it that the player's did not.
-- They get their own box above the foe's panel now (see drawBallBox), so both
-- panels are the same box at the same height and the party count is a
-- separate piece of furniture that appears only when there is a party.
-- The pill's outline matches the panel's, because two pieces of white-edged
-- furniture sitting one above the other at different stroke weights read as a
-- mistake. Its PADDING deliberately does not take the panel's PAD: that gap
-- is set by a row of type that needs air around it, and a capsule that is
-- nothing but balls wants to hug them.
BattleHudPanel.BALL_D = 28       -- one ball, corner to corner
BattleHudPanel.BALL_GAP = 8      -- between balls
BattleHudPanel.BALL_BOX_PAD = 7  -- inside the pill's outline
BattleHudPanel.BALL_BOX_OUTLINE = 6
BattleHudPanel.BALL_BOX_GAP = 4 -- pill's bottom edge to the panel's top edge

-- Gen 1's own cap, so nothing is ever cut: VICTREEBEL fits whole. The glyphs
-- are sized for exactly this many characters and stay that size on every
-- panel, however short the name -- what a short name buys is a wider gap
-- before the level, not bigger letters, because letters that changed size
-- between one mon and the next would be the most distracting thing on screen.
--
-- Ten only fits because the level column is sized for four cells rather than
-- five (see LABEL_FIT); a longer nickname, or the one level-100 case, is cut
-- at draw time, never squeezed.
BattleHudPanel.NAME_MAX = 10

-- The level/status label's glyph scale as a fraction of the name's. A RATIO
-- rather than a size of its own, because the one thing that has to hold at
-- every resolution is that the level is SMALLER than the name: it is the
-- secondary field, and sizing the two independently off the panel width let a
-- narrow window round them to the same whole scale and make them peers.
-- layout() also floors it a whole step below the name, so they cannot tie.
BattleHudPanel.LEVEL_RATIO = 0.65

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

-- ------- the font's real top and bottom row
--
-- Measured, not assumed. The layout needs to know where the LETTERS are
-- inside the 8-row cell, and the only authority on that is the font itself --
-- a mod that swaps the font, or a future engine that ships a taller one,
-- should retune the panel without anyone editing a constant.
--
-- Read once from a probe string of the glyphs the panel actually draws, off
-- the same canvas the panel already renders text through, using the same ink
-- test as the shader. One readback of an 8-row image, at the first panel of
-- the session, and cached for the process.
local INK_PROBE = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:"
local fontInkRows = nil    -- nil = untried, false = unreadable

local function fontInk()
  if fontInkRows ~= nil then return fontInkRows or nil end
  fontInkRows = false
  local img = textImage(INK_PROBE)
  if img and img.canvas then
    local ok, data = pcall(function() return img.canvas:newImageData() end)
    if ok and data then
      local iw, ih = data:getWidth(), data:getHeight()
      local top, bottom
      for y = 0, ih - 1 do
        local inked = false
        for x = 0, iw - 1 do
          local r, g, b, a = data:getPixel(x, y)
          -- LOVE 0.10 hands back 0..255, 11+ hands back 0..1
          if a > 1 then r, g, b, a = r / 255, g / 255, b / 255, a / 255 end
          if a > 0 and (0.299 * r + 0.587 * g + 0.114 * b) <= 0.35 then
            inked = true
            break
          end
        end
        if inked then
          if not top then top = y end
          bottom = y + 1
        end
      end
      if top and bottom and bottom > top then
        fontInkRows = { top = top, bottom = bottom }
      end
    end
  end
  -- the probe is not a string any panel draws; do not leave it in the cache
  if textCache[INK_PROBE] then
    textCache[INK_PROBE] = nil
    textCount = math.max(0, textCount - 1)
  end
  return fontInkRows or nil
end

-- The font's ink rows, as { first, one-past-last } within the 8-row cell.
function BattleHudPanel.inkExtent()
  local ink = fontInk()
  if ink then return ink.top, ink.bottom end
  return BattleHudPanel.INK_TOP, BattleHudPanel.INK_BOTTOM
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

-- How many slots the party actually occupies, and their states, in order.
--
-- Empty slots are omitted rather than drawn as an empty tile: the box is
-- sized to the party, so a rival with two mons gets a two-ball box, not a
-- six-ball box with four holes in it. The states are collected once because
-- both the measuring and the drawing need them and the party can change
-- between frames.
local function ballStates(party)
  local out = {}
  if not party then return out end
  for slot = 1, 6 do
    local state = ballState(party[slot])
    if state then out[#out + 1] = state end
  end
  return out
end

-- The party box's own size in window pixels, or nil when there is no party to
-- draw. Measured separately from the drawing so place() can hang the panel
-- and the box off the same baseline without drawing anything first.
function BattleHudPanel.ballBoxSize(party, s)
  local P = BattleHudPanel
  local n = #ballStates(party)
  if n == 0 then return nil end
  local d, gap = P.BALL_D * s, P.BALL_GAP * s
  local outline, pad = P.BALL_BOX_OUTLINE * s, P.BALL_BOX_PAD * s
  local inner = n * d + (n - 1) * gap
  return inner + (outline + pad) * 2, d + (outline + pad) * 2, n
end

-- The party box: one row of up to six balls in their own rounded box, drawn
-- with its RIGHT edge at `right` and its BOTTOM edge at `bottom`.
--
-- Anchored by its bottom-right rather than its top-left because that is the
-- corner that has to stay put: the box sits above the foe's panel and shares
-- its right edge, and it grows leftward and upward as the party fills. Fixing
-- the far corner instead would make the box appear to slide along the panel
-- every time a trainer had a different number of mons.
--
-- Same treatment as the panel and the bar -- a white shape with the black
-- field inset into it -- so the three pieces of furniture read as one set,
-- and fully rounded (radius = half the height) because at this size a box
-- that is mostly ball wants to be a capsule around them rather than a card.
function BattleHudPanel.drawBallBox(party, right, bottom, s)
  local P = BattleHudPanel
  local states = ballStates(party)
  local n = #states
  if n == 0 then return 0, 0 end

  local w, h = P.ballBoxSize(party, s)
  local x, y = right - w, bottom - h
  local outline = P.BALL_BOX_OUTLINE * s
  local radius = h / 2

  local g = love.graphics
  local oc = P.OUTLINE_COLOR
  g.setColor(oc[1], oc[2], oc[3], 1)
  g.rectangle("fill", x, y, w, h, radius, radius)
  local f = P.FILL
  g.setColor(f[1], f[2], f[3], 1)
  g.rectangle("fill", x + outline, y + outline,
              w - outline * 2, h - outline * 2,
              math.max(0, radius - outline), math.max(0, radius - outline))
  g.setColor(1, 1, 1, 1)

  -- Party order, slot 1 at the left, the way the party screen lists it.
  local d, gap = P.BALL_D * s, P.BALL_GAP * s
  local r = d / 2
  local cx = x + outline + P.BALL_BOX_PAD * s + r
  local cy = y + h / 2
  for i = 1, n do
    drawBall(cx + (i - 1) * (d + gap), cy, r, states[i])
  end
  return w, h
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
-- Derived, not declared, and from ONE number: three stacked gaps of black,
-- the name row and the bar, with the outline outside all of it.
--
--     OUTLINE         the frame, not space
--     PAD             black, to the top of the name's INK
--     rowH            the name's ink, nothing more
--     PAD             black, to the top of the bar
--     barH
--     PAD             black, to the frame
--     OUTLINE
--
-- Every gap of black the same size, and measured against the letters rather
-- than the cell they sit in. Nothing floats in slack and there is no second
-- spacing number to keep in sync with the first.
--
-- BOTH SIDES GET THE SAME NUMBER. There is no hasBalls case any more -- the
-- party moved into its own box above the foe's panel -- and that is the whole
-- point: two panels of the same height put the two HP bars on the same line,
-- which is what the eye is actually comparing during a battle. The argument
-- is still accepted and ignored so an older caller does not break.
function BattleHudPanel.layout(s)
  local P = BattleHudPanel
  local w = P.PANEL_W * s
  local outline = P.OUTLINE * s
  local pad = P.PAD * s
  local inset = outline + pad          -- outer edge to any content
  local cw = w - inset * 2
  local gap = P.COL_GAP * s
  local barH = P.BAR_H * s
  local rowGap = pad                   -- the name-to-bar gap IS the padding

  -- The two glyph scales are solved together, because each one's width comes
  -- out of the other's: the name gets what the label column does not reserve.
  --
  -- Pass one sizes the label off the panel width, as before, and the name off
  -- what is left. Pass two pins the label to LEVEL_RATIO of the name and a
  -- whole step below it, which is the rule that has to hold; since that can
  -- only make the label SMALLER, the name's share can only grow, so the name
  -- re-solves upward and the ratio still holds. No third pass can change it.
  local function solve(smallScale)
    -- Reserve for a FIXED number of cells, never for the label in hand: a
    -- panel whose glyphs changed size between level 99 and 100, or between a
    -- level and a status, would visibly twitch.
    local labelReserve = P.LABEL_FIT * 8 * smallScale
    local nameW = math.max(0, cw - labelReserve - gap)
    local nameX = math.max(1, math.floor(nameW / (P.NAME_MAX * 8)))
    return nameW, nameX, nameX + (P.NAME_STRETCH or 0), labelReserve
  end

  local smallScale = math.max(1, math.floor(cw / 130))
  local nameW, nameX, nameY, labelReserve = solve(smallScale)

  local wanted = math.max(1, math.floor(nameY * P.LEVEL_RATIO + 0.5))
  if wanted > nameY - 1 then wanted = nameY - 1 end
  if wanted < 1 then wanted = 1 end
  if wanted < smallScale then
    smallScale = wanted
    nameW, nameX, nameY, labelReserve = solve(smallScale)
  end

  -- The row is the NAME'S INK, not its cell. Taken from the font's extent
  -- rather than the string in hand so the box is the same height whatever is
  -- in it -- a name that happens to have no descender must not make a shorter
  -- panel than one that does.
  local inkTop, inkBottom = P.inkExtent()
  local rowH = (inkBottom - inkTop) * nameY

  -- Three equal gaps of black, with the frame outside them.
  return {
    w = w, h = outline * 2 + pad * 3 + rowH + barH,
    outline = outline, pad = pad, inset = inset, cw = cw, gap = gap,
    barH = barH, rowGap = rowGap, rowH = rowH,
    inkTop = inkTop, inkBottom = inkBottom,
    smallScale = smallScale, nameX = nameX, nameY = nameY,
    nameW = nameW, rightCol = labelReserve,
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

-- Draw one panel with its top-left at (x, y), for `battler`.
-- `party` puts the party box above it; pass nil for the player's side and for
-- a wild foe, which has no party to show.
function BattleHudPanel.draw(battler, party, x, y, s)
  if not battler then return end
  local g = love.graphics
  local P = BattleHudPanel
  local L = P.layout(s)
  local w, h = L.w, L.h
  local radius = P.RADIUS * s

  -- the party box, above the panel and sharing its right edge
  if party then
    P.drawBallBox(party, x + w, y - P.BALL_BOX_GAP * s, s)
  end

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

  local cx = x + L.inset
  local cy = y + L.inset
  local right = cx + L.cw

  -- The name row: name at the left, level-or-status flush right, and the two
  -- sitting on ONE BASELINE -- the bottom of the name's ink, which is also the
  -- line the bar hangs one PAD below.
  --
  -- Both used to be centred in the row independently, so the smaller label
  -- floated half a glyph off the name's feet and the pair read as two things
  -- at two heights rather than as one line of type. Aligning bottoms rather
  -- than centres is what makes a smaller label look deliberate instead of
  -- misplaced, and it holds at every scale because it is one subtraction
  -- rather than a rounded halving of a difference.
  --
  -- Both are placed by their INK. P.text takes the top-left of the CELL, and
  -- the cell has blank rows in it -- so the cell is pushed up by whatever the
  -- font leaves below its baseline, at each label's own scale. Aligning the
  -- cells instead would put the two baselines apart by the difference between
  -- those two scales, which is precisely the drift this is here to remove.
  local baseline = cy + L.rowH

  -- The label is measured FIRST, because the name is cut to what is actually
  -- left beside it rather than to a fixed count.
  --
  -- The glyphs were sized for LABEL_FIT cells (four: "L:99", "SLP"), which is
  -- what lets a ten-character name fit at full size. A five-cell label --
  -- "L:100", and nothing else -- takes one cell more than that was sized for,
  -- so the name gives up its last character for those battles. The
  -- alternative is sizing every panel in the game for a label almost no
  -- battle ever shows, and paying for it in glyph size the whole way.
  --
  -- Cut, never squeezed: the name's size is fixed by layout() and identical
  -- on every panel. Only how many characters survive changes.
  local label, labelColor = rightLabel(battler)
  local labelW = P.textWidth(label) * L.smallScale
  P.text(label, right - labelW, baseline - L.inkBottom * L.smallScale,
         L.smallScale, L.smallScale, labelColor)

  local name = battler.name or "?"
  local cell = 8 * L.nameX
  local fits = P.NAME_MAX
  if cell > 0 then
    fits = math.floor((L.cw - labelW - L.gap) / cell)
    if fits > P.NAME_MAX then fits = P.NAME_MAX end
    if fits < 1 then fits = 1 end
  end
  if #name > fits then name = name:sub(1, fits) end
  P.text(name, cx, baseline - L.inkBottom * L.nameY, L.nameX, L.nameY, P.TEXT)

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
function BattleHudPanel.place(shot, swapped, pin)
  local s = (shot.ph or 0) / BattleHudPanel.REF_H
  if s <= 0 then return nil end
  local P = BattleHudPanel
  -- One layout for both sides now: the party box is drawn ABOVE the foe's
  -- panel rather than inside it, so the two boxes are identical and their
  -- tops line up as well as their bottoms.
  local pl = P.layout(s)
  local en = pl
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
