-- Small isometric model of a planned roof, drawn with flat-shaded polygons.
-- Uses the same projection as the game (a level is three half-tiles tall),
-- so a layout reads the same in the helper as it will in the world.
local RoofModelView = {}

local DIRECTIONS = { W = { -1, 0 }, N = { 0, -1 }, E = { 1, 0 }, S = { 0, 1 } }
local ROOF = { 0.62, 0.40, 0.33 }
local WALL = { 0.78, 0.76, 0.70 }
local STOREY = { 0.50, 0.52, 0.55 }
local MISSING = { 0.85, 0.30, 0.22 }

local function key(x, y)
    return tostring(x) .. ":" .. tostring(y)
end

-- Lambert shade from a light high in the south-west, like the game's art.
local LX, LY, LZ = -0.30, 0.62, 0.72
local function shade(ax, ay, ah, bx, by, bh, cx, cy, ch)
    local ux, uy, uz = bx - ax, by - ay, bh - ah
    local vx, vy, vz = cx - ax, cy - ay, ch - ah
    local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    if nz < 0 then nx, ny, nz = -nx, -ny, -nz end
    local length = math.sqrt(nx * nx + ny * ny + nz * nz)
    if length == 0 then return 0.7 end
    local d = (nx * LX + ny * LY + nz * LZ) / length
    return 0.45 + 0.55 * math.max(0, d)
end

---Build the model once per layout.
---@param layout table  RoofPlanner layout (roof, region, info, labels)
---@param steps integer steps per storey of the roof set (3 or 6)
function RoofModelView.build(layout, steps)
    if not layout or not layout.roof then return nil end
    steps = steps or 3
    local roof, region, info = layout.roof, layout.region or layout.roof, layout.info or {}
    local labels = layout.labels or {}
    local rise = 3 / steps -- world height of one step, in tile half-widths
    local polys = {}
    local minX, minY, maxX, maxY
    local ox, oy = roof.minX, roof.minY
    local function project(x, y, h)
        local sx = (x - ox) - (y - oy)
        local sy = ((x - ox) + (y - oy)) / 2 - h * rise
        if not minX or sx < minX then minX = sx end
        if not maxX or sx > maxX then maxX = sx end
        if not minY or sy < minY then minY = sy end
        if not maxY or sy > maxY then maxY = sy end
        return sx, sy
    end
    local function add(order, points, color, light)
        polys[#polys + 1] = { order = order, p = points, r = color[1] * light, g = color[2] * light,
            b = color[3] * light }
    end
    -- The storey below: only its south and east walls face the camera.
    local below = -steps
    for i = 1, #region.list do
        local c = region.list[i]
        if not region.cells[key(c.x, c.y + 1)] then
            local ax, ay = project(c.x, c.y + 1, below)
            local bx, by = project(c.x + 1, c.y + 1, below)
            local cx, cy = project(c.x + 1, c.y + 1, 0)
            local dx, dy = project(c.x, c.y + 1, 0)
            add(c.x + c.y - 1000, { ax, ay, bx, by, cx, cy, dx, dy }, STOREY, 0.95)
        end
        if not region.cells[key(c.x + 1, c.y)] then
            local ax, ay = project(c.x + 1, c.y, below)
            local bx, by = project(c.x + 1, c.y + 1, below)
            local cx, cy = project(c.x + 1, c.y + 1, 0)
            local dx, dy = project(c.x + 1, c.y, 0)
            add(c.x + c.y - 1000, { ax, ay, bx, by, cx, cy, dx, dy }, STOREY, 0.72)
        end
    end
    for i = 1, #roof.list do
        local c = roof.list[i]
        local cell = info[key(c.x, c.y)]
        if cell and cell.nw then
            local nw, ne, se, sw = cell.nw, cell.ne, cell.se, cell.sw
            local color = ROOF
            if cell.missing then color = MISSING end
            if cell.kind == "flat" then color = { 0.58, 0.52, 0.44 } end
            local x, y = c.x, c.y
            local p1x, p1y = project(x, y, nw)
            local p2x, p2y = project(x + 1, y, ne)
            local p3x, p3y = project(x + 1, y + 1, se)
            local p4x, p4y = project(x, y + 1, sw)
            local order = x + y
            -- Split along the crease: the odd corner sits on the NW-SE diagonal
            -- for south-east or north-west corners, otherwise on NE-SW.
            local odd = (nw ~= ne and nw ~= sw) or (se ~= ne and se ~= sw)
            if odd then
                add(order, { p1x, p1y, p2x, p2y, p3x, p3y, p3x, p3y }, color,
                    shade(x, y, nw * rise, x + 1, y, ne * rise, x + 1, y + 1, se * rise))
                add(order, { p1x, p1y, p3x, p3y, p4x, p4y, p4x, p4y }, color,
                    shade(x, y, nw * rise, x + 1, y + 1, se * rise, x, y + 1, sw * rise))
            else
                add(order, { p2x, p2y, p3x, p3y, p4x, p4y, p4x, p4y }, color,
                    shade(x + 1, y, ne * rise, x + 1, y + 1, se * rise, x, y + 1, sw * rise))
                add(order, { p1x, p1y, p2x, p2y, p4x, p4y, p4x, p4y }, color,
                    shade(x, y, nw * rise, x + 1, y, ne * rise, x, y + 1, sw * rise))
            end
            -- Gable and tall walls on the visible (south and east) roof edges.
            for d, delta in pairs({ S = DIRECTIONS.S, E = DIRECTIONS.E }) do
                local label = labels[key(x, y) .. ":" .. d]
                if (label == "gable" or label == "wall") and not roof.cells[key(x + delta[1], y + delta[2])] then
                    local a1, a2, ha, hb
                    if d == "S" then a1, a2, ha, hb = { x, y + 1 }, { x + 1, y + 1 }, sw, se
                    else a1, a2, ha, hb = { x + 1, y }, { x + 1, y + 1 }, ne, se end
                    local q1x, q1y = project(a1[1], a1[2], 0)
                    local q2x, q2y = project(a2[1], a2[2], 0)
                    local q3x, q3y = project(a2[1], a2[2], hb)
                    local q4x, q4y = project(a1[1], a1[2], ha)
                    add(order + 0.5, { q1x, q1y, q2x, q2y, q3x, q3y, q4x, q4y }, WALL, d == "S" and 0.95 or 0.78)
                end
            end
        end
    end
    table.sort(polys, function(a, b) return a.order < b.order end)
    if not minX then return nil end
    return { polys = polys, minX = minX, minY = minY, w = math.max(0.001, maxX - minX), h = math.max(0.001, maxY - minY) }
end

-- Clip a polygon (flat x,y list) against y >= limit (keepAbove=false) or
-- y <= limit (keepAbove=true). Sutherland-Hodgman on one edge.
local function clipY(points, limit, keepBelowLimit)
    local out = {}
    local n = #points / 2
    if n == 0 then return out end
    local function inside(py)
        if keepBelowLimit then return py <= limit end
        return py >= limit
    end
    local px, py = points[n * 2 - 1], points[n * 2]
    local pin = inside(py)
    for i = 1, n do
        local cx, cy = points[i * 2 - 1], points[i * 2]
        local cin = inside(cy)
        if cin ~= pin then
            local t = (limit - py) / (cy - py)
            out[#out + 1] = px + (cx - px) * t
            out[#out + 1] = limit
        end
        if cin then
            out[#out + 1] = cx
            out[#out + 1] = cy
        end
        px, py, pin = cx, cy, cin
    end
    return out
end

---Draw a built model scaled into a box of the panel. clipTop/clipBottom
---(element-relative) cut the polygons so a scrolled row never paints over
---the list's edges; drawPolygon is not reliably masked by the stencil.
function RoofModelView.draw(panel, model, x, y, w, h, alpha, tint, clipTop, clipBottom)
    if not model then return end
    alpha = alpha or 1
    local scale = math.min(w / model.w, h / model.h)
    local left = x + (w - model.w * scale) / 2 - model.minX * scale
    local top = y + (h - model.h * scale) / 2 - model.minY * scale
    local tr, tg, tb = 1, 1, 1
    if tint then tr, tg, tb = tint.r or 1, tint.g or 1, tint.b or 1 end
    local clipping = (clipTop and y < clipTop) or (clipBottom and y + h > clipBottom)
    if clipTop and clipBottom and (y + h <= clipTop or y >= clipBottom) then return end
    for i = 1, #model.polys do
        local poly = model.polys[i]
        local p = poly.p
        local r, g, b = poly.r * tr, poly.g * tg, poly.b * tb
        if not clipping then
            -- drawPolygon takes element-relative points (the four-point
            -- drawTextureAllPoint expects absolute screen coordinates).
            panel:drawPolygon(nil,
                left + p[1] * scale, top + p[2] * scale, left + p[3] * scale, top + p[4] * scale,
                left + p[5] * scale, top + p[6] * scale, left + p[7] * scale, top + p[8] * scale,
                r, g, b, alpha)
        else
            local pts = {}
            for k = 1, 4 do
                pts[#pts + 1] = left + p[k * 2 - 1] * scale
                pts[#pts + 1] = top + p[k * 2] * scale
            end
            if clipTop then pts = clipY(pts, clipTop, false) end
            if clipBottom and #pts >= 6 then pts = clipY(pts, clipBottom, true) end
            local n = #pts / 2
            -- Fan the clipped polygon into quads (drawPolygon draws four points).
            local k = 2
            while k < n do
                local k2, k3 = math.min(k + 1, n), math.min(k + 2, n)
                panel:drawPolygon(nil, pts[1], pts[2], pts[k * 2 - 1], pts[k * 2],
                    pts[k2 * 2 - 1], pts[k2 * 2], pts[k3 * 2 - 1], pts[k3 * 2], r, g, b, alpha)
                k = k + 2
            end
        end
    end
end

return RoofModelView
