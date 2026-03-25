pico-8 cartridge // http://www.pico-8.com
version 43
__lua__
-- twang: archer side-scroller
-- pico-8 port

-- ===== constants =====
-- physics (per-frame at 30fps)
local grav    = 0.28
local jforc   = -3.2   -- jump velocity (about half original height)
local pspd    = 1.5    -- max walk speed
local paccel  = 0.30   -- acceleration
local pdecel  = 0.24   -- deceleration
local air     = 0.6    -- air control multiplier
local coy_t   = 8      -- coyote grace frames
local jbuf_t  = 8      -- jump buffer frames
-- player dimensions (small green box)
local pw      = 4
local ph      = 6
-- tile size
local TW      = 8
-- spawn point
local spx     = 4
local spy     = 82
-- world
local ww      = 160    -- world width  (20 tiles)
local wh      = 96     -- world height (12 tiles)
local kill_y  = 96     -- fall below = respawn
-- jump system (multi-phase variable height, ref: 512px under)
local j_frames_max = 6   -- max frames of sustained upward acceleration
local j_iacc  = 1.8      -- initial jump step (move_towards, first frame)
local j_acc   = 0.9      -- sustained jump step per frame while held
-- arrow mode
local max_arr = 3      -- max live arrows

-- single arrow type (standard)
-- spd=px/frame, grv=gravity added per frame, col=pico-8 color (10=yellow)
local arrow_cfg = {spd=5.5, grv=0.09, col=10}
-- three power levels: low / medium / high (index 1/2/3)
local arrow_spds = {3.0, 4.5, 6.0}

-- slow-motion: physics runs 1-in-SLOW_N frames while aiming
-- 1/12 = about 8% speed (much slower than before)
local SLOW_N   = 12
local slow_cnt = 0

-- enemy constants
local MELEE_SPD   = 0.6   -- patrol speed px/frame
local ARCHER_SPD  = 0.4
local DETECT_DIST = 80    -- px: archer starts shooting
local SHOOT_CD    = 90    -- frames between archer shots
local BLOOD_N     = 10    -- particles per kill
local TILE_MELEE  = 50    -- map spawn tile for melee enemy
local TILE_ARCHER = 51    -- map spawn tile for archer enemy
local E_SPR_M     = 105   -- melee sprite
local E_SPR_A     = 90    -- archer sprite

-- ===== game state =====
local arrows = {}
local p      = {}
local cam    = {x=0, y=0}
local enemies  = {}
local e_arrows = {}
local particles = {}

-- ===== arrow type menu =====
arrow_types    = {"normal"}
sel_arrow_type = 1

function update_arrow_menu()
  menuitem(1, "arrows: "..arrow_types[sel_arrow_type], function()
    sel_arrow_type = (sel_arrow_type % #arrow_types) + 1
    update_arrow_menu()  -- re-register with updated label
  end)
end

-- ===== init =====
function _init()
  respawn()
  arrows    = {}
  e_arrows  = {}
  particles = {}
  cam.x = 0
  cam.y = 0
  scan_enemies()
  update_arrow_menu()
end

-- ===== tile flag helpers =====
-- set flags in sprite editor (F2): flag 0=solid  flag 1=sticky  flag 2=slippery
function tile_solid(t)    return t~=0 and fget(t,0) end
function tile_sticky(t)   return t~=0 and fget(t,1) end
function tile_friction(t) return (t~=0 and fget(t,2)) and 0.1 or 1.0 end

-- is the pixel at world (x,y) inside a solid tile?
function solid_at(x,y)
  return tile_solid(mget(flr(x/TW), flr(y/TW)))
end

-- is the tile at (x,y) sticky (flag 1)? arrows bounce off these
function sticky_at(x,y)
  local t = mget(flr(x/TW), flr(y/TW))
  return t ~= 0 and fget(t, 1)
end

function respawn()
  p = {
    x=spx, y=spy,
    vx=0,  vy=0,
    w=pw,  h=ph,
    gr=false,    -- grounded flag
    facing=1,    -- 1=right, -1=left
    coy=0,       -- coyote frames remaining
    jbuf=0,      -- jump buffer frames remaining
    fr=1.0,      -- surface friction (set on land)
    -- multi-phase jump
    j_frames=0,  -- sustained jump frames remaining
    -- wall state
    wall_l=false, wall_r=false,
    -- arrow mode state
    aim_angle=0,     -- current aim direction (0-1 pico-8 fraction)
    aim_power=2,     -- 1=low 2=medium 3=high; resets to medium on aim entry
    was_aiming=false,-- true while btn(4) was held last frame
    aimed_down=false,-- true after firing downward until grounded or re-aiming
    -- landing state
    prev_gr=false,   -- grounded last frame (for transition detection)
    land_frames=0,   -- counts down after touching ground,
  }
end

-- move v toward target by at most step (ref: 512px under)
function mv_to(v, target, step)
  if v < target then return min(v + step, target)
  else               return max(v - step, target)
  end
end

-- ===== update =====
function _update()
  slow_cnt = slow_cnt + 1

  -- INPUT: always runs every frame for responsiveness --

  if btn(4) then
    -- ARROW MODE: held z slows time
    if not p.was_aiming then
      -- first frame of aim mode: initialize angle and reset power to medium
      p.aim_angle = p.facing > 0 and 0 or 0.5
      p.aim_power = 2
      p.was_aiming = true
      p.aimed_down = false
    end
    -- left/right rotates aim continuously
    if btn(0) then p.aim_angle = (p.aim_angle + 0.007) % 1 end
    if btn(1) then p.aim_angle = (p.aim_angle - 0.007) % 1 end
    -- up/down steps through power levels
    if btnp(2) then p.aim_power = min(3, p.aim_power + 1) end
    if btnp(3) then p.aim_power = max(1, p.aim_power - 1) end
  else
    if p.was_aiming then
      -- button released: fire at current angle and exit aim mode
      if sin(p.aim_angle) > 0.5 then p.aimed_down = true end
      do_fire_at(p.aim_angle)
      p.was_aiming = false
    end
    if btnp(5) then p.jbuf = jbuf_t end
  end
  if p.jbuf > 0 then p.jbuf = p.jbuf - 1 end

  -- PHYSICS: full rate normally, 1-in-SLOW_N frames while arrow mode held --
  local do_phys = not btn(4) or (slow_cnt % SLOW_N == 0)
  if do_phys then
    upd_player_phys()
    upd_arrows()
    upd_enemies()
    upd_e_arrows()
    upd_particles()
    upd_cam()
  end
end

-- Physics-only update (movement, gravity, integration, collision).
-- Called every frame normally; called 1-in-SLOW_N frames while in arrow mode.
function upd_player_phys()
  if not btn(4) then
    -- horizontal movement only when arrow mode is not held
    local ax = 0
    if btn(0) then ax = -1 end
    if btn(1) then ax =  1 end

    if ax ~= 0 then
      p.facing = ax
      local a = p.gr and paccel or (paccel * air)
      p.vx = p.vx + ax * a
    else
      local d = p.gr and (pdecel * p.fr) or (pdecel * 0.35)
      if p.vx > 0 then
        p.vx = max(0, p.vx - d)
      elseif p.vx < 0 then
        p.vx = min(0, p.vx + d)
      end
    end
    p.vx = mid(-pspd, p.vx, pspd)
  else
    -- aiming: decelerate to a stop (no input accepted)
    local d = p.gr and (pdecel * p.fr) or (pdecel * 0.35)
    if p.vx > 0 then
      p.vx = max(0, p.vx - d)
    elseif p.vx < 0 then
      p.vx = min(0, p.vx + d)
    end
  end

  -- normal jump (ground / coyote) — jbuf is only set outside aim mode
  if p.jbuf > 0 and p.coy > 0 then
    -- initial kick: move_towards vy toward jforc by j_iacc (first frame)
    p.vy      = mv_to(p.vy, jforc, j_iacc)
    p.coy     = 0
    p.jbuf    = 0
    p.j_frames = j_frames_max
  end

  -- sustained jump acceleration while button held and frames remain
  if p.j_frames > 0 then
    if btn(5) and p.vy < 0 then
      p.vy      = mv_to(p.vy, jforc, j_acc)
      p.j_frames = p.j_frames - 1
    else
      -- early release: halve upward speed (cuts height)
      if p.vy < 0 then p.vy = p.vy / 2 end
      p.j_frames = 0
    end
  end

  -- gravity
  p.vy = p.vy + grav
  -- cap fall speed to platform thickness so we can never tunnel through
  p.vy = min(p.vy, 3)

  -- X pass: integrate + horizontal collision
  p.x = p.x + p.vx
  resolve_x(p)

  -- wall detection via tile flags (airborne only)
  check_walls(p)

  -- Y pass: integrate + vertical collision
  p.gr = false
  p.fr = 1.0
  p.y = p.y + p.vy
  resolve_y(p)
  check_arrow_platforms()

  -- coyote time + landing flash
  if p.gr then
    p.coy = coy_t
    p.j_frames = 0    -- landing resets jump phase
    p.aimed_down = false
    if not p.prev_gr then p.land_frames = 6 end  -- just touched down
    if p.land_frames > 0 then p.land_frames = p.land_frames - 1 end
  else
    p.coy = max(0, p.coy - 1)
    p.land_frames = 0
  end
  p.prev_gr = p.gr

  -- kill zone
  if p.y > kill_y then player_die() end
end

function do_fire_at(angle)
  if #arrows >= max_arr then
    -- evict the oldest stuck arrow to make room
    for a in all(arrows) do
      if a.stuck then
        del(arrows, a)
        break
      end
    end
    if #arrows >= max_arr then return end  -- all arrows still flying
  end
  local dx = cos(angle)
  local dy = sin(angle)
  local spd = arrow_spds[p.aim_power]
  add(arrows, {
    x=p.x+pw/2, y=p.y+ph/2,
    vx=dx*spd, vy=dy*spd,
    active=true, stuck=false,
    bounced=false,
    sdx=dx, sdy=dy,  -- shaft direction (set properly on stick)
    spin=0,
    lt=300,   -- lifetime for flying; overwritten to large value on stick
  })
end

-- allow player to land on stuck arrows as small platforms
function check_arrow_platforms()
  if p.vy < 0 then return end  -- only when falling or standing
  for a in all(arrows) do
    if a.stuck and a.active then
      local ay = a.y
      local by = p.y + p.h
      -- y window: 5px tall so max vy (3px) can never skip over it
      if by >= ay - 1 and by <= ay + 4 then
        -- derive platform x-range from the wall face, not the embedded tip.
        -- arrows travel into solid tiles so a.x may be several pixels inside;
        -- using a.x directly puts the range fully inside the wall.
        local ax1, ax2
        if abs(a.sdx) >= abs(a.sdy) then
          -- arrow hit a vertical wall (mostly horizontal travel)
          if a.sdx > 0 then
            -- hit right wall: face is left edge of the tile
            local wx = flr(a.x/TW)*TW
            ax1 = wx - 7  ax2 = wx + 2
          else
            -- hit left wall: face is right edge of the tile
            local wx = (flr(a.x/TW)+1)*TW
            ax1 = wx - 2  ax2 = wx + 7
          end
        else
          -- arrow hit a floor/ceiling (mostly vertical travel)
          ax1 = a.x - 4  ax2 = a.x + 4
        end
        if p.x + p.w > ax1 and p.x < ax2 then
          p.y  = ay - p.h
          p.vy = 0
          p.gr = true
          p.coy = coy_t
        end
      end
    end
  end
end

-- ===== enemies =====
function player_die()
  respawn()
  arrows   = {}
  e_arrows = {}
end

function aabb(a, b)
  return a.x < b.x+b.w and a.x+a.w > b.x
     and a.y < b.y+b.h and a.y+a.h > b.y
end

function scan_enemies()
  enemies = {}
  for r = 0, 11 do
    for c = 0, 19 do
      local t = mget(c, r)
      if t == TILE_MELEE or t == TILE_ARCHER then
        add(enemies, {
          x=c*TW, y=r*TW,
          vx=0, vy=0,
          w=6, h=8,
          gr=false,
          facing=1,
          type=(t==TILE_MELEE) and "melee" or "archer",
          shoot_cd=SHOOT_CD,
        })
        mset(c, r, 0)
      end
    end
  end
end

function upd_enemy(e)
  -- gravity + Y collision
  e.vy = min(e.vy + grav, 3)
  e.gr = false
  e.y  = e.y + e.vy
  resolve_y(e)

  -- patrol when grounded
  if e.gr then
    local spd = (e.type=="melee") and MELEE_SPD or ARCHER_SPD
    local px  = e.facing>0 and (e.x+e.w) or (e.x-1)
    local wall_ahead  = solid_at(px, e.y+e.h/2)
    local ledge_ahead = not solid_at(px, e.y+e.h)
    if wall_ahead or ledge_ahead then e.facing = -e.facing end
    e.vx = spd * e.facing
  else
    e.vx = e.vx * 0.85
  end

  -- X collision
  e.x = e.x + e.vx
  resolve_x(e)

  -- world bounds
  if e.x < 0 then e.x=0 e.facing=1 end
  if e.x+e.w > ww then e.x=ww-e.w e.facing=-1 end

  -- melee: touch kills player
  if e.type=="melee" and aabb(e,p) then
    player_die()
    return
  end

  -- archer: shoot when close
  if e.type=="archer" then
    if e.shoot_cd > 0 then e.shoot_cd=e.shoot_cd-1 end
    if abs(p.x-e.x) < DETECT_DIST and e.shoot_cd==0 then
      local ex=e.x+e.w/2  local ey=e.y+e.h/2
      local tx=p.x+pw/2   local ty=p.y+ph/2
      local ddx=tx-ex      local ddy=ty-ey
      local len=sqrt(ddx*ddx+ddy*ddy)
      if len>0 then
        add(e_arrows,{
          x=ex, y=ey,
          vx=ddx/len*arrow_cfg.spd,
          vy=ddy/len*arrow_cfg.spd,
          active=true,
        })
      end
      e.shoot_cd=SHOOT_CD
    end
  end
end

function upd_enemies()
  for e in all(enemies) do upd_enemy(e) end
end

function upd_e_arrows()
  for a in all(e_arrows) do
    if not a.active then
      del(e_arrows, a)
    else
      a.vy = a.vy + arrow_cfg.grv
      local nx = a.x + a.vx
      local ny = a.y + a.vy
      if solid_at(nx,ny) then
        a.active = false
      else
        a.x = nx  a.y = ny
        -- player hit
        if nx>=p.x and nx<p.x+pw and ny>=p.y and ny<p.y+ph then
          player_die()
          a.active = false
        end
        if a.y>kill_y+10 or a.x<-10 or a.x>ww+10 then
          a.active=false
        end
      end
    end
  end
end

function spawn_blood(x, y, avx, avy)
  local len = sqrt(avx*avx+avy*avy)
  if len==0 then len=1 end
  local base = atan2(-avx/len, -avy/len)
  for i=1, BLOOD_N do
    local a   = base + rnd(0.25) - 0.125
    local spd = rnd(1.5) + 0.5
    add(particles,{
      x=x, y=y,
      vx=cos(a)*spd,
      vy=sin(a)*spd,
      life=flr(rnd(10))+10,
    })
  end
end

function upd_particles()
  for pt in all(particles) do
    pt.x = pt.x + pt.vx
    pt.y = pt.y + pt.vy
    pt.vy = pt.vy + 0.06
    pt.life = pt.life - 1
    if pt.life<=0 then del(particles, pt) end
  end
end

-- ===== arrow update =====
function upd_arrows()
  for a in all(arrows) do
    if not a.active then
      del(arrows, a)
    else
      upd_arrow(a)
    end
  end
end

function upd_arrow(a)
  a.lt = a.lt - 1
  if a.lt <= 0 then a.active = false return end

  if a.stuck then return end

  -- spin counter for bounced arrows
  if a.bounced then a.spin = a.spin + 0.06 end

  -- physics
  a.vy = a.vy + arrow_cfg.grv
  local nx = a.x + a.vx
  local ny = a.y + a.vy

  -- tile collision
  if solid_at(nx, ny) then
    -- check whether hit surface is sticky (yellow wall = bounce)
    local hx = solid_at(nx, a.y)
    local hy = solid_at(a.x, ny)
    local is_sticky = (hx and sticky_at(nx, a.y))
                   or (hy and sticky_at(a.x, ny))
                   or (not hx and not hy and sticky_at(nx, ny))

    if is_sticky then
      -- bounce: reflect velocity off the hit surface, bleed off speed
      if hx then a.vx = -a.vx * 0.65 end
      if hy then a.vy = -a.vy * 0.65 end
      if not hx and not hy then
        a.vx = -a.vx * 0.65  a.vy = -a.vy * 0.65
      end
      a.bounced = true
      a.lt = min(a.lt, 80)  -- bounced arrows expire quickly
    else
      -- stick: save shaft direction for drawing, then freeze
      local spd = sqrt(a.vx*a.vx + a.vy*a.vy)
      a.sdx = spd > 0 and (a.vx/spd) or a.sdx
      a.sdy = spd > 0 and (a.vy/spd) or a.sdy
      a.x = nx  a.y = ny
      a.stuck = true
      a.lt = 32000  -- effectively permanent until evicted
    end
    return
  end

  a.x = nx
  a.y = ny

  -- enemy hit check
  for e in all(enemies) do
    if nx >= e.x and nx < e.x+e.w and ny >= e.y and ny < e.y+e.h then
      spawn_blood(nx, ny, a.vx, a.vy)
      del(enemies, e)
      a.active = false
      return
    end
  end

  -- cull off-world
  if a.y > kill_y+10 or a.x < -10 or a.x > ww+10 then
    a.active = false
  end
end


-- ===== camera =====
function upd_cam()
  -- keep player centered horizontally; world fits in screen vertically
  local tx = p.x + pw/2 - 64
  tx = mid(0, tx, ww - 128)
  cam.x = cam.x + (tx - cam.x) * 0.15
  -- no vertical scroll: level fits within128px height
  cam.y = 0
end

-- ===== tile-based AABB collision =====
-- X pass: push obj out of solid tiles horizontally
function resolve_x(obj)
  if obj.vx > 0 then
    local rx = obj.x + obj.w - 1
    if solid_at(rx, obj.y) or solid_at(rx, obj.y+obj.h-1) then
      obj.x  = flr(rx/TW)*TW - obj.w
      obj.vx = 0
    end
  elseif obj.vx < 0 then
    if solid_at(obj.x, obj.y) or solid_at(obj.x, obj.y+obj.h-1) then
      obj.x  = (flr(obj.x/TW)+1)*TW
      obj.vx = 0
    end
  end
end

-- Y pass: push obj out of solid tiles vertically
function resolve_y(obj)
  if obj.vy >= 0 then
    local by = obj.y + obj.h
    if solid_at(obj.x, by) or solid_at(obj.x+obj.w-1, by) then
      local tc = mget(flr(obj.x/TW), flr(by/TW))
      obj.y  = flr(by/TW)*TW - obj.h
      obj.vy = 0
      obj.gr = true
      obj.fr = tile_friction(tc)
    end
  elseif obj.vy < 0 then
    if solid_at(obj.x, obj.y) or solid_at(obj.x+obj.w-1, obj.y) then
      obj.y  = (flr(obj.y/TW)+1)*TW
      obj.vy = 0
    end
  end
end

-- detect wall contact on left/right of obj (airborne only)
function check_walls(obj)
  obj.wall_l = false  obj.wall_r = false
  if obj.gr then return end
  local tr = flr(obj.y/TW)
  local br = flr((obj.y+obj.h-1)/TW)
  for r = tr, br do
    local tl = mget(flr((obj.x-1)/TW), r)
    if tile_solid(tl) then obj.wall_l = true end
    local tw = mget(flr((obj.x+obj.w)/TW), r)
    if tile_solid(tw) then obj.wall_r = true end
  end
end

-- ===== draw =====
function _draw()
  cls(1)              -- dark blue sky

  -- world-space draw (camera offset applied)
  camera(cam.x, cam.y)
  map(0, 0, 0, 0, 20, 12)  -- draw tilemap
  draw_particles()
  draw_enemies()
  draw_e_arrows()
  draw_arrows()
  draw_player()

  -- screen-space HUD
  camera()
  draw_hud()
end

-- run animation: cycle through 4 frames
-- sprites 176-179, advance every 6 physics frames
local run_frame = 0
local run_tick  = 0

function draw_player()
  -- choose sprite based on state
  local s
  if not p.gr then
    s = 161                          -- airborne jump sprite
  elseif p.vx ~= 0 and not btn(4) then
    -- running: advance frame counter on the ground (not while aiming)
    run_tick = run_tick + 1
    if run_tick >= 6 then
      run_tick  = 0
      run_frame = (run_frame + 1) % 4
    end
    s = 176 + run_frame              -- run cycle sprites 176-179
  else
    run_frame = 0  run_tick = 0      -- reset cycle when idle or aiming
    s = 160                          -- standing
  end

  -- landing flash overrides everything else
  if p.land_frames > 0 then s = 163
  -- down-aim pose while aiming downward, or after firing downward mid-air
  elseif btn(4) and sin(p.aim_angle) > 0.5 then s = 162
  elseif p.aimed_down and not p.gr then s = 162
  end

  -- draw 8x8 sprite centered on the 4x6 collision box
  -- when aiming, face the aim direction; otherwise face movement direction
  local draw_facing = p.facing
  if btn(4) then
    local ax = cos(p.aim_angle)
    if ax > 0 then draw_facing =  1
    elseif ax < 0 then draw_facing = -1
    end
  end
  local sx = p.x - 2               -- center 8px sprite over 4px box
  local sy = p.y - 2               -- align bottom of 8px sprite with feet
  spr(s, sx, sy, 1, 1, draw_facing < 0, false)

  -- trajectory overlay (arrow mode)
  if btn(4) then
    local cx = p.x + pw/2
    local cy = p.y + ph/2
    local ex = cx + cos(p.aim_angle) * 8
    local ey = cy + sin(p.aim_angle) * 8
    line(cx, cy, ex, ey, 10)
    draw_traj(cx, cy, p.aim_angle, arrow_spds[p.aim_power])
  end
end

function draw_traj(sx, sy, angle, spd)
  local tvx = cos(angle) * spd
  local tvy = sin(angle) * spd
  local tx, ty = sx, sy
  for i = 1, 20 do
    tvy = tvy + arrow_cfg.grv
    tx  = tx  + tvx
    ty  = ty  + tvy
    if i % 2 == 0 then
      pset(tx, ty, arrow_cfg.col)
    end
  end
end

function draw_arrows()
  for a in all(arrows) do
    if a.active then
      if a.stuck then
        -- shaft sticking out of wall: line from tip back along entry direction
        pset(a.x, a.y, 7)  -- bright tip
        line(a.x, a.y, a.x - a.sdx*4, a.y - a.sdy*4, arrow_cfg.col)
      elseif a.bounced then
        -- spinning tumble: rotate around arrow center using spin angle
        local cx = cos(a.spin) * 3
        local cy = sin(a.spin) * 3
        line(a.x+cx, a.y+cy, a.x-cx, a.y-cy, arrow_cfg.col)
        pset(a.x+cx, a.y+cy, 7)
      else
        -- flying: short line in direction of travel
        local len = sqrt(a.vx*a.vx + a.vy*a.vy)
        if len > 0 then
          local dnx = a.vx / len
          local dny = a.vy / len
          line(a.x, a.y, a.x-dnx*3, a.y-dny*3, arrow_cfg.col)
          pset(a.x, a.y, 7)
        end
      end
    end
  end
end

local pwr_labels = {"lo","md","hi"}
local pwr_cols   = {12, 10, 8}   -- blue / yellow / red

function draw_hud()
  if btn(4) then
    local lbl = pwr_labels[p.aim_power]
    local col = pwr_cols[p.aim_power]
    print("pwr:"..lbl, 98, 1, col)
    print("z:aim  lr:ang  ud:pwr", 0, 121, 6)
  else
    print("x:jump  z:bow", 0, 121, 6)
  end
end

function draw_enemies()
  for e in all(enemies) do
    local s = (e.type=="melee") and E_SPR_M or E_SPR_A
    spr(s, e.x, e.y, 1, 1, e.facing<0, false)
  end
end

function draw_e_arrows()
  for a in all(e_arrows) do
    if a.active then
      local len=sqrt(a.vx*a.vx+a.vy*a.vy)
      if len>0 then
        local dnx=a.vx/len  local dny=a.vy/len
        line(a.x,a.y,a.x-dnx*3,a.y-dny*3,8)
        pset(a.x,a.y,7)
      end
    end
  end
end

function draw_particles()
  for pt in all(particles) do
    pset(pt.x, pt.y, 8)
  end
end

-->8
-- no sprites needed: all drawing is procedural
__gfx__
0000000009990990555555555555555555555555555555550000000990000000000ee000555555555555555555555555555555550000000ee000000000000000
0000000099999999555555555555555555555dd555555555000000999900000000eeee00555d55d5555555555555555555555555000000eeee00000000000000
000000009999999955555555555dd5d5555d5dd55d5dd555000009999990000000eeee0055dd55555555555555555d555555555500000eeeeee0000000000000
000000000999999955555555555dd55555555555555dd5550000999dd99900000eeeeee05555d555555dd55dd555555dd55555550000eeeddeee000000000000
0000000099999999555555555555555dd55dd55dd5555555000999dddd9990000eeeeee055555dd5555dd5dddd5dd5dddd5d5555000eeeddddeee000d888888d
00000000099999995555555555d55dddddddddddddd55d5500999dd55dd999000eeeeee05dd55d55555555dddddddddddd55555500eeedd55ddeee00d888888d
00000000999999905555555555555dd9999999999dd555550999dd5555dd9990eeeeeeee5dd555555555dddeeeeeeeeeeddd55550eeedd5555ddeee0000dd000
0000000099999999555555555555dd999999999999dd5555999ddd5555ddd999eeeeeeee55555555555dddeeeeeeeeeeeeddd555eeeddd5555dddeee00555500
99999999555555555d55dd999999999999dd55d599dddd5555dddd99eeeeeeee55555555555dddeeeeeeeeeeeeddd555eedddd5555ddddeed888888d99999999
999999905555d55555555d999999999999d555559dd5555555555dd90eeeeeee55555d555555ddeeeeeeeeeeeedd5555edd5555555555dded888888d99999990
9999999955d5555555555d999999999999d55555dd555555555555ddeeeeeeee55555dd555d55deeeeeeeeeeeed55555dd555555555555dd000dd00099999999
999999995555555555d5dd999999999999dd5d55d55dd555555dd55deeeeeeee5555d5555555ddeeeeeeeeeeeedd5555d55dd555555dd55d0055550099999999
99999999555dd5555555dd999999999999dd5555555dd555555dd555eeeeeeee555d55555555ddeeeeeeeeeeeedd5555555dd555555dd555000dd00009999990
99999999555dd5d55dd55d999999999999d55dd55d555555555555d5eeeeeeee5dd5555555555deeeeeeeeeeeed55d555d555555555555d5005555000d0dd0d0
099999995d5555555dd55d999999999999d55dd55555555555555555eeeeeee055d555555555ddeeeeeeeeeeeedd55555555555555555555000dd000005dd500
99999999555555555555dd999999999999dd55555555555555555555eeeeeeee55555555555dddeeeeeeeeeeeeddd555555555555555555500555500000dd000
555555555555dd999999999999dd555555555555555555550eeeeee055555555555dddeeeeeeeeeeeeddd555555555555555555555000055000dd00009999990
5d5d5d5555555dd9999999999dd555555555555555555555050dd05055dddd555555dddeeeeeeeeeeddd555555555555555555555dd0000dd000ddd009999999
5555d55555d55dddddddddddddd55d555d555555555555d50d0dd0d05dddddd5555555dddddddddddd5555555d555555555555d5dddddddd000dd000995dd599
555d5d555555555dd55dd55dd5555555555dd555555dd555005dd0d05d5dd5d55555555dd555555dd55dd555d55dd555555dd55d00000000000dd00099d55d99
55555555555dd55555555555555dd555d55dd555555dd55d000dd0d05dddddd55555555555d5555555555555dd555555555555dd00000000000dd00099d55d99
5dd555d5555dd5d5555d5dd55d5dd555dd555555555555dd000dd0d05dddddd55555d5dddd5dd5dddd5dd555555dd555555dd5550dddddd0000dd00099d55d99
5dd5555555555555d5555dd5555555559dd5555555555dd9000dd0d055d55d555555555555555555555555555555555555555555dde00000000005dd00099d55
5555555555555555555555555555555599dddd5555dddd99000dd50055555555555555555555555555555555555555555555555555555555555555555555555e
9999999999999999999999990999ddd5555dd999000dd0000eeeeee00eeeeeeeeeeeeeeeeeeeeee0eeeddd5555dddeeecccccccc000dd00099d55d9909999999
9999999999999999999999990999dd5555dd999000dd500eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0eeedd5555ddeee0cccccccc000ddd0099d55d99999999990
995dddddddddddddddddd59900999dd55dd99900000dd000ee5dd5eeee5dddddddddddddddddd5ee00eeedd55ddeee00dddddddd000dd00099d55d9999dddddd
99d555555555555555555d99000999dddd999000000dd000eed55deeeed555555555555555555ddee000eeeddddeee0000dd0dd000ddd00099d55d9999ddd55d
99d555555555555555555d990000999dd9990000000dd000eed55deeeed555555555555555555ddee0000eeeddeee00000000000000dd00099d55d9999ddd555
995dddddddddddddddddd5990000099999900000000dd000eed55deeee5dddddddddddddddddd5ee00000eeeeee00000000000000dd00099d55d9999d5555500
999999999999999999999999000000999900000000ddd000eed55deeeeeeeeeeeeeeeeeeeeeeeeee000000eeee00000000000000000dd00099d55d9999d55555
0999999999999999999999900000000990000000000dd000eed55dee0eeeeeeeeeeeeeeeeeeeeee00000000ee000000000000000005dd50099d55d9999dd5555
99999990000000000000000000dddd00000dd000eed55dee0eeeeeeeeeeeeee000000000dd880088dd000000000000007777666699d55d9999dd55555555dd99
9999999900000000000009900dddddd0000dd000eed55deeeeeeeeeeeeeeeeee00000000dd588888dd000000000000006666dddd99d55d9999d5555555555d99
dddddd9900000000000099400dd00dd0000dd000eed55deeeeddddddddddddee0ee00000dd888888dd00000000d006006666dddd99d55d9999d5555555555d99
d55ddd9900000000000994990dd00dd0005dd500eed55deeeedd55dddd55ddee00ee0000dd588888dd00000000d006006666dddd99d55d9999ddd555555ddd99
555ddd9900000000099990900999999000dddd00eed55deeeed5555dd5555dee00ee0000dd888888dd00000006dd66d0dddd666699d55d9999ddd55dd55ddd99
55555d9900000990900900000994499000dddd00eed55deeeed5555555555dee00ee00eedd008800dd00000006dd66d0dddd6666995dd59999dddddddddddd99
55555d9999003300900900000994499000dddd00eed55deeeedd55555555ddee0ee0ee0dd000000dd00000066dd66dddddd66669999999999999999999999990
5555dd9909909900099000000999999005dddd50eed55deeeeddd555555dddee0ee0ee0dd000000dd00000066dd66dddddd66660999999009999999999999900
000000000000000000000000000ccc00eed55deeeeddd555555dddee000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000c0ccc00eed55deeeedd55555555ddee000000000000000000888800088008800880880008802200000000008888888000000000
0000000007770000007700000000ccc0eed55deeeed5555555555dee000000000094490008888880088888800880220008888880000000008888888000088000
00000000777707700077000000ccccc0eed55deeeed5555dd5555dee0ee00ee00049940008800880088888800888888008878870088088008888888008888000
0990099077777777000007000ccccc00eed55deeeedd55dddd55ddee0eeeeee00049940008800880087887800887887028888882088022008878878800888800
0999999077777777000700000ccc0000ee5dd5eeeeddddddddddddee00eeee00009449000dd00dd0088888800888888000222200088888808888888800088000
00999900077777700000000000ccc0c0eeeeeeeeeeeeeeeeeeeeeeee000dd000000000000dd00dd0202222022022220208000080088788708888888000000000
000dd000000000000000000000ccc0000eeeeee00eeeeeeeeeeeeee000edde000000000000000000008008000080080000000000288888820888888800000000
0000000000cccc0000000000000000007707707700000dddddd0000000000dddddd00000000000000000000000cccc0000000000111111000000000000000000
000000000cccccc0000c00000000000077077077000dddddddddd000000dddddddddd00000cccc0000cccc000cccccc000000000111111100100100000000000
00000000cccccccc000cc000000000000000000000ddddc55ddddd0000dddd5555dddd000cccccc00cccccc00cccccc000000000111111101011010001001000
00088000cccccccc00ccccc0000c0000770000770dddcccddcccddd00ddd55555555ddd00cccccc00cccccc00cc7cc7000cccc00118118110011110000011000
00088000cc7cc7cc0ccccc000000c000770000770ddccccddccccdd00dd5555555555dd00c7cc7c00cc7cc701cccccc10cccccc0111111110011110000011000
00000000cccccccc000cc0000000000000000000dddccccddccccdddddd5555555555ddd0cccccc00cccccc0001111000cccccc0111111110101101000100100
000000000cccccc00000c0000000000077077077ddcccccddcccccddddc5555555555cdd101111101101111010c0000c00cc7cc7011111111001001000000000
0000000000cccc0000000000000000007707077ddcccccddcccccddddc5555555555cdd00c00c0000c00c00000000001cccccc10000000000000000000000000
d777777d00d77d000100001000111100dd6ccc6666ccc6dddd655555555556dd00dddd00000dd00000dddd000dddddd00dd00dd00dddddd0000dd0000dddddd0
00000000000000000000000001111110dd6cc666666cc6dddd655555555556dd0dddddd000ddd0000dddddd00dddddd00dd00dd00dddddd000ddd0000dddddd0
01111110011111100111111001111110ddccc66dd66cccddddc5555555555cdd0dd00dd000ddd0000dd00dd00000ddd00dd00dd00dd000000ddd0000000000dd
11111111111111111111111101811810ddccc66dd66cccddddc5555555555cdd0dd00dd0000dd0000000ddd000dddd000dddddd00ddddd000ddddd000000ddd0
11111111111111111111111101111110ddccc666666cccddddc5555555555cdd0dd00dd0000dd000000ddd0000dddd000dddddd000ddddd00dddddd000ddd000
11811811118118111181181100111100dd6ccd6666dcc6dddd655555555556dd0dd00dd0000dd00000ddd0000000ddd000000dd00dd00dd00d0000dd00000000
11111111111111111111111100100100dd6cccd55dccc6dddd655555555556dd0dddddd000dddd000dddddd00dddddd000000dd00dddddd00dddddd0000dd000
01111110011111100111111010000001ddcccccddcccccddddc5555555555cdd00dddd0000dddd000dddddd00ddddd0000000dd00ddddd00500dddd00000dd00
00dddd0000dddd000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0dddddd00dddddd00dd00dd00dd00dd00880088008800dd00dd00dd000dddd00000dd00000ddd00000dddd0000d0dd0000dddd00000dd00000dddd0000dddd00
0dd00dd00dd00dd00dddddd00dd0ddd0888888888888dddddddddddd00d0dd0000ddd0000000dd00000d0dd0000d0dd0000dd000000dd00000000dd0000d0dd0
00dddd000dddddd000dddd00000ddd00888888888888dddddddddddd00d0dd00000dd000000ddd00000dd00000d0dd0000dddd0000dddd0005ddd0000dddd000
0dddddd0000ddd0000dddd0000ddd000088888800888ddd00dddddd000d0dd00000dd00000ddd0000000dd0000dddd000000dd0000dd0d0000dd00000d0dd000
0dd00dd00000ddd00dddddd00ddd0dd0008888000088dd0000dddd0000d0dd00000dd00000dd00000000dd000000dd000000dd0000dd0d00000dd00000d0dd00
0dddddd0000ddd000dd00dd00dd00dd0000880000008d000000dd00000dddd0000dddd0000dddd0000ddd0000000dd0000ddd00000dddd00000dd00000dddd00
00dddd00000dd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00dddd000000000000000000000990000009d000000dd00000000000000000000000000000000000000000000000000000000000000000000000000000000000
00d0dd0000d00d0000d0dd00099999900999ddd00dddddd000000000000000000000000000000000000000000000000000000000000000000000000000000000
00d0dd00000dd000000ddd00099999900999ddd00dddddd000000000000000000000000000000000000000000000000000000000000000000000000000000000
00dddd00000dd00000ddd000009999000099dd0000dddd0000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000dd0000d00d0000dd0d00099999900999ddd00dddddd000000000000000000000000000000000000000000000000000000000000000000000000000000000
000dd00000000000000000000990099009900dd00dd00dd000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000088088000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
08808800088022000808888800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
08802200088888000082888800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
08888880088788700828780008808800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
08878870288888820028882808802200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
08888880002222000028882808888880000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
20222202080000800008780008878870000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00800800000000000000000028888882000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
08808800000000000088800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
08802200088088000088200000888000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
08888880088022000888888000882000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
08878870088888800888878008888880000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
28888882088788700888882008888780000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00222200088888802022200008888880000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
08000080002228008000080000222000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
00000000000800000000000000800800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
__gff__
0001010101010101000103030300000001010101010100000103030303030000010101010100000103030303030000000101000000000303030300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
__map__
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000022220000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000006070000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000001b190000000014120000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000001b190000000014120000000000003300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000001b190000000014120000002222222200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000001b190000000014120000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000001b190000000014120000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
000000001b190000000014120000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000032000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
2222222222222222222222222222222222222222000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
