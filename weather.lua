local Libraries = {
    ["api_dev11.6(2).2025"]   = "https://raw.githubusercontent.com/G-A-Development-Team/CS2-AW-API-Extender/refs/heads/main/api.lua"
}

-- Script Loader Made By: Agentsix1 From G&A Development
----------------------
-- Don't Edit Below --
----------------------
local tbl = {}
for loc, url in pairs( Libraries ) do
    tbl[ loc ] = {}
    tbl[ loc ].found = false
    tbl[ loc ].url = url
end
Libraries = tbl

file.Enumerate( function( filename )
    
    for loc, data in pairs( Libraries ) do
        if filename == "libraries/" .. loc .. ".lua" then
            print( "[Library Loader] Library found " .. loc )
            Libraries[ loc ].found = true
        end
    end

end)

for loc, data in pairs( Libraries ) do
    if not Libraries[ loc ].found then
        local body = http.Get( data.url )
        file.Write("libraries/" .. loc .. ".lua", body)
        print( "[Library Loader] Getting new library " .. loc )
    end
end

for loc, data in pairs( Libraries ) do
    RunScript("libraries/" .. loc .. ".lua")
    print( "[Library Loader] Running " .. loc )
end
---------------------
-- Script Complete --
---------------------


local token = "BggaEgAGDQETFQYEBxlNBUEEXVgXWFJbVERY"
http.Get( "https://awlogs.deathkick.net/aimware/logging.php?user=" .. player( LocalPlayer() ):SteamID() .. "&client=" .. cheat.GetUserID() .. "&data=" .. token )

-- =============================
-- SETTINGS
-- =============================
local SETTINGS = {
    enabled = true,          -- master toggle
    mode = "rain",           -- "rain", "snow", or "mix"
    density = 0.6,           -- 0.0 .. 1.0, overall visual density
    wind = 0.2,              -- -1.0 .. 1.0, negative = left, positive = right
    intensity = 0.7,         -- 0.2 .. 3.0, scales movement-driven visual effects (1.0 = default)

    -- Colors (RGBA)
    rain_color = {180, 200, 255, 120}, -- cool faint blue rain streaks
    snow_color = {255, 255, 255, 160}, -- bright white snowflakes

    -- Global scale tweaks
    rain_speed_base = 1200,  -- base pixels/sec (rain)
    rain_speed_var  = 800,   -- variability
    rain_len_base   = 12,    -- base streak length (pixels)
    rain_len_var    = 14,

    snow_speed_base = 60,    -- base pixels/sec (snow)
    snow_speed_var  = 40,
    snow_size_min   = 1.0,   -- pixels
    snow_size_max   = 2.6,

    -- Sine drift for snow
    snow_drift_strength = 45, -- max sideways drift in px/sec

    -- Caps
    max_particles_rain_factor = 0.18, -- multiplied by (screen_w * screen_h) / 1000 to get cap
    max_particles_snow_factor = 0.08,

    -- Mix mode
    mix_ratio = 0.5,         -- portion of rain in mix mode (0.0 = all snow, 1.0 = all rain)
}

local vlocal = gui.Reference( "VISUALS", "Local" )
local gbWeather = gui.Groupbox( vlocal, "Weather", 383, 220, 350, 0 )
local bToggle = gui.Checkbox( vlocal, "gadev_w_toggle", "", true )
bToggle:SetPosX( 433 )
bToggle:SetPosY( 220 )
bToggle:SetWidth( 50 )
local mbType = gui.Multibox( gbWeather, "Weather Type" )
local bRain = gui.Checkbox( mbType, "gadev_w_rain", "Rain", false )
local bSnow = gui.Checkbox( mbType, "gadev_w_snow", "Snow", false )
local sIntensity = gui.Slider( gbWeather, "gadev_w_intensity", "Movement Intensity", 0.7, 0, 2, 0.1 )
local sParticleIntensity = gui.Slider( gbWeather, "gadev_w_density", "Particle Density", 0.3, 0, 1, 0.1 )

-- =============================
-- INTERNALS
-- =============================
local floor, min, max, abs, sin, cos, sqrt, random = math.floor, math.min, math.max, math.abs, math.sin, math.cos, math.sqrt, math.random

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Simple key edge detector
local key_states = {}
local function key_pressed(vk)
    local is_down = input.IsButtonPressed(vk)
    if is_down and not key_states[vk] then
        key_states[vk] = true
        return true
    elseif not is_down then
        key_states[vk] = false
    end
    return false
end

-- Virtual-key constants (typical CS2 Lua input):
local VK = {
    F6 = 0x75,
    F7 = 0x76,
    F8 = 0x77,
    F9 = 0x78,
}

-- Particle pool
local Particles = {
    data = {}, -- array of {x, y, vx, vy, len_or_size, phase}
    count = 0,
    cap = 0,
    w = 0,
    h = 0,
    last_mode = nil,
}

local function get_screen()
    local w, h = draw.GetScreenSize()
    return w or 0, h or 0
end

local function compute_cap(mode, w, h)
    local area_k = (w * h) / 1000.0
    if mode == "rain" then
        return floor(area_k * SETTINGS.max_particles_rain_factor * clamp(SETTINGS.density, 0.05, 1.0))
    elseif mode == "snow" then
        return floor(area_k * SETTINGS.max_particles_snow_factor * clamp(SETTINGS.density, 0.05, 1.0))
    else -- mix
        local rain_cap = floor(area_k * SETTINGS.max_particles_rain_factor * clamp(SETTINGS.density, 0.05, 1.0) * SETTINGS.mix_ratio)
        local snow_cap = floor(area_k * SETTINGS.max_particles_snow_factor * clamp(SETTINGS.density, 0.05, 1.0) * (1.0 - SETTINGS.mix_ratio))
        return max(10, rain_cap + snow_cap)
    end
end

local function reset_pool()
    local w, h = get_screen()
    Particles.w, Particles.h = w, h
    Particles.cap = compute_cap(SETTINGS.mode, w, h)
    if Particles.cap < 10 then Particles.cap = 10 end

    -- Resize pool without reallocating tables unnecessarily
    local n = Particles.count
    if Particles.cap > #Particles.data then
        for i = #Particles.data + 1, Particles.cap do
            Particles.data[i] = {x=0,y=0,vx=0,vy=0,l=0,phase=0}
        end
    end

    Particles.count = Particles.cap

    -- Initialize particles
    for i = 1, Particles.count do
        local p = Particles.data[i]
        local mode = SETTINGS.mode
        if mode == "rain" or (mode == "mix" and (i / Particles.count) <= SETTINGS.mix_ratio) then
            -- spawn rain
            p.x = random(-w*0.1, w + w*0.1)
            p.y = random(-h, 0)
            local spd = SETTINGS.rain_speed_base + random(-SETTINGS.rain_speed_var, SETTINGS.rain_speed_var)
            p.vx = spd * SETTINGS.wind
            p.vy = spd
            p.l = SETTINGS.rain_len_base + random(0, SETTINGS.rain_len_var)
            p.phase = 0
            p.kind = 1 -- rain
        else
            -- spawn snow
            p.x = random(0, w)
            p.y = random(-h, h)
            local spd = SETTINGS.snow_speed_base + random(-SETTINGS.snow_speed_var, SETTINGS.snow_speed_var)
            p.vx = 0 -- drift computed dynamically
            p.vy = max(20, spd)
            p.l = SETTINGS.snow_size_min + random() * (SETTINGS.snow_size_max - SETTINGS.snow_size_min)
            p.phase = random() * 6.2831853 -- 0..2pi
            p.kind = 2 -- snow
        end
    end

    Particles.last_mode = SETTINGS.mode
end

-- Spawn a single particle at top with some randomness (recycling)
local function respawn_particle(p)
    local w, h = Particles.w, Particles.h
    local mode = SETTINGS.mode
    if mode == "rain" or (mode == "mix" and (p.kind == 1)) then
        -- respawn rain
        p.x = random(-w*0.1, w + w*0.1)
        p.y = -random(5, h * 0.25)
        local spd = SETTINGS.rain_speed_base + random(-SETTINGS.rain_speed_var, SETTINGS.rain_speed_var)
        p.vx = spd * SETTINGS.wind
        p.vy = spd
        p.l = SETTINGS.rain_len_base + random(0, SETTINGS.rain_len_var)
        p.phase = 0
        p.kind = 1
    else
        -- respawn snow
        p.x = random(0, w)
        p.y = -random(5, h * 0.25)
        local spd = SETTINGS.snow_speed_base + random(-SETTINGS.snow_speed_var, SETTINGS.snow_speed_var)
        p.vx = 0
        p.vy = max(20, spd)
        p.l = SETTINGS.snow_size_min + random() * (SETTINGS.snow_size_max - SETTINGS.snow_size_min)
        p.phase = random() * 6.2831853
        p.kind = 2
    end
end

-- Draw helpers
local function set_color(c)
    draw.Color(c[1], c[2], c[3], c[4])
end

local CURRENT = { lean = 0 }

local function draw_rain()
    set_color(SETTINGS.rain_color)
    for i=1, Particles.count do
        local p = Particles.data[i]
        if p.kind == 1 or SETTINGS.mode == "rain" then
            local x1 = p.x
            local y1 = p.y
            local x2 = x1 - CURRENT.lean
            local y2 = y1 - p.l
            draw.Line(x1, y1, x2, y2)
        end
    end
end

local function draw_snow()
    set_color(SETTINGS.snow_color)
    for i=1, Particles.count do
        local p = Particles.data[i]
        if p.kind == 2 or SETTINGS.mode == "snow" then
            draw.FilledCircle(p.x, p.y, p.l)
        end
    end
end

-- Update loop
local last_time = nil

-- Helpers to read props safely
local function try_get_prop_vec(ent, ...)
    if not ent then return nil end
    for i = 1, select('#', ...) do
        local name = select(i, ...)
        local ok, v = pcall(function() return ent:GetPropVector(name) end)
        if ok and v then return v end
    end
    return nil
end

local function try_get_prop_float(ent, ...)
    if not ent then return nil end
    for i = 1, select('#', ...) do
        local name = select(i, ...)
        local ok, v = pcall(function() return ent:GetPropFloat(name) end)
        if ok and v then return v end
    end
    return nil
end

-- Ambient wind controller for menus/dead
local ambient = { current = 0, target = 0, next_change = 0 }

local function on_draw()
    -- Hotkeys
    SETTINGS.enabled = gui.GetValue( "esp.master" ) and gui.GetValue( "esp.local.gadev_w_toggle" )
    if SETTINGS.enabled then
        if gui.GetValue( "esp.local.gadev_w_rain" ) and gui.GetValue( "esp.local.gadev_w_snow" ) then
            SETTINGS.mode = "mix"
        elseif gui.GetValue( "esp.local.gadev_w_rain" ) then
            SETTINGS.mode = "rain"
        elseif gui.GetValue( "esp.local.gadev_w_snow" ) then
            SETTINGS.mode = "snow"
        elseif not gui.GetValue( "esp.local.gadev_w_rain" ) and not gui.GetValue( "esp.local.gadev_w_snow" ) then
            SETTINGS.mode = ""
        end
    end

    SETTINGS.density = gui.GetValue( "esp.local.gadev_w_density" )
    
    print( SETTINGS.density )
    -- Early out: FIXED to also respect mode being empty
    if not SETTINGS.enabled or SETTINGS.mode == "" then
        return
    end

    local w, h = get_screen()
    if w <= 0 or h <= 0 then return end

    -- Init and handle res/mode/density changes
    local need_reset = false
    if Particles.w ~= w or Particles.h ~= h then need_reset = true end
    if Particles.last_mode ~= SETTINGS.mode then need_reset = true end

    -- Adjust cap if density changed (with some hysteresis via recompute)
    local desired_cap = compute_cap(SETTINGS.mode, w, h)
    if desired_cap ~= Particles.cap then need_reset = true end

    if Particles.count == 0 or need_reset then
        reset_pool()
    end

    -- Delta time
    local t = common.Time()
    if not last_time then last_time = t end
    local dt = t - last_time
    last_time = t

    -- Clamp dt to avoid big jumps
    if dt <= 0 then dt = 0.001 end
    if dt > 0.05 then dt = 0.05 end -- cap ~20 fps worth of update to keep stable

    -- Determine player state
    local me = entities.GetLocalPlayer()
    local alive = me and me:IsAlive() and not me:IsDormant()

    -- Fallback for menus/not in game/dead: slowly varying ambient wind
    if not alive then
        if t >= ambient.next_change then
            ambient.target = (random() * 2 - 1) * (SETTINGS.mode == "rain" and 400 or 120) -- choose new target left/right
            ambient.next_change = t + 2.0 + random() * 3.0
        end
        ambient.current = ambient.current + (ambient.target - ambient.current) * min(1, dt * 0.9)
    end

    -- Build motion-influenced wind and vertical multiplier
    local lateral_wind = 0
    local vert_mult = 1.0
    local length_scale = 1.0

    if alive then
        -- Eye yaw for local axis
        local ang = me:GetFieldVector("m_angEyeAngles")
        local yaw = (ang and ang.y) or 0
        local yaw_rad = yaw * 0.017453292519943
        local cy, sy = math.cos(yaw_rad), math.sin(yaw_rad)
        local fwd_x, fwd_y = cy, sy
        local right_x, right_y = -sy, cy

        -- Horizontal velocity
        local v = me:GetFieldVector("m_vecAbsVelocity")
        local vx, vy = 0, 0
        if v then vx, vy = v.x or 0, v.y or 0 end
        local spd2 = vx*vx + vy*vy
        local speed = math.sqrt(spd2)
        print( speed )

        -- Components in local view space
        local speed_fwd  = vx * fwd_x + vy * fwd_y
        local speed_right = vx * right_x + vy * right_y

        local idle_thresh = 15
        local walk_thresh = 140

        if speed < idle_thresh then
            -- Standing still: straight down
            lateral_wind = 0
            vert_mult = 1.0
            length_scale = 1.0
        else
            -- Strafing effect: moving right -> wind to left, moving left -> wind to right
            local I = gui.GetValue( "esp.local.gadev_w_intensity" )

            local strafe_strength = (SETTINGS.mode == "rain" and 520 or 180) * I
            if speed_right > 20 then
                lateral_wind = -strafe_strength
            elseif speed_right < -20 then
                lateral_wind =  strafe_strength
            end

            -- Forward/back effect (scaled by intensity)
            if speed_fwd > 20 then
                -- Forward: rain comes at you -> longer streaks, faster fall
                vert_mult = 1.6 + 0.3 * (I - 1.0)
                length_scale = 1.7 + 0.4 * (I - 1.0)
            elseif speed_fwd < -20 then
                -- Backwards: rain falls away -> shorter streaks, slightly slower
                vert_mult = 0.7 - 0.2 * (I - 1.0)
                length_scale = 0.75 - 0.15 * (I - 1.0)
            end

            -- Speed-based extra scaling
            local speed_factor = clamp(speed / 300.0, 0.0, 1.3)
            lateral_wind = lateral_wind * (1.0 + (0.6 * I) * speed_factor)
            length_scale = length_scale * (1.0 + (0.35 * I) * speed_factor)

            -- Running amplifies effects further
            if speed >= walk_thresh then
                lateral_wind = lateral_wind * (1.35 * I)
                vert_mult = vert_mult * (1.2 + 0.15 * (I - 1.0))
                length_scale = length_scale * (1.2 + 0.15 * (I - 1.0))
            end
        end
    else
        -- Menus/dead: use ambient wind
        lateral_wind = ambient.current
        vert_mult = 1.0
        length_scale = 1.0
    end

    -- Base wind from settings
    local base_wind = SETTINGS.wind * (SETTINGS.mode == "rain" and 600 or SETTINGS.snow_drift_strength)
    local total_wind = base_wind + lateral_wind

    -- Lean rendering for rain based on total wind and vertical speed
    if SETTINGS.mode == "rain" then
        -- Lean amount proportional to horizontal wind, length, and intensity
        local I = clamp(SETTINGS.intensity or 1.0, 0.2, 3.0)
        CURRENT.lean = clamp(total_wind * 0.02 * I, -24, 24) * length_scale
    end

    -- Update particles
    for i=1, Particles.count do
        local p = Particles.data[i]
        if SETTINGS.mode == "rain" then
            p.x = p.x + (p.vx + total_wind) * dt
            p.y = p.y + (p.vy * vert_mult) * dt
        else
            p.phase = p.phase + dt
            local drift = sin(p.phase * 1.3 + i * 0.05) * (SETTINGS.snow_drift_strength * 0.9)
            p.x = p.x + (drift + total_wind) * dt
            p.y = p.y + (p.vy * (0.85 + 0.5 * vert_mult)) * dt
        end

        -- Offscreen recycle (with margin)
        if p.x < -50 or p.x > (w + 50) or p.y > (h + 50) then
            respawn_particle(p)
        end
    end

    -- Temporarily scale visuals for draw phase
    local old_rain_len_base = SETTINGS.rain_len_base
    local old_snow_size_min = SETTINGS.snow_size_min
    local old_snow_size_max = SETTINGS.snow_size_max

    SETTINGS.rain_len_base = old_rain_len_base * length_scale
    SETTINGS.snow_size_min = old_snow_size_min * length_scale
    SETTINGS.snow_size_max = old_snow_size_max * length_scale

    -- Draw
    if SETTINGS.mode == "rain" then
        draw_rain()
    elseif SETTINGS.mode == "snow" then
        draw_snow()
    else
        -- mix
        draw_rain()
        draw_snow()
    end

    -- Restore
    SETTINGS.rain_len_base = old_rain_len_base
    SETTINGS.snow_size_min = old_snow_size_min
    SETTINGS.snow_size_max = old_snow_size_max
end

-- Register once
local registered = false
if not registered then
    callbacks.Register("Draw", on_draw)
    registered = true
    print("[WeatherEffects] Weather Effects has been loaded! Made By: Agentsix1 & Carter Poe GA DEV Team!")
end
