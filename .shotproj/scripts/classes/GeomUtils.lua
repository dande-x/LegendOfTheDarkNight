-- ============================================================================
-- GeomUtils.lua — 武器 CustomGeometry 通用几何辅助函数
-- ============================================================================
local GeomUtils = {}

--- 添加一个四边形（两个三角形）
function GeomUtils.addQuad(geom, p1, p2, p3, p4, normal)
    geom:DefineVertex(p1) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(0,0))
    geom:DefineVertex(p2) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(1,0))
    geom:DefineVertex(p3) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(1,1))
    geom:DefineVertex(p1) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(0,0))
    geom:DefineVertex(p3) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(1,1))
    geom:DefineVertex(p4) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(0,1))
end

--- 添加一个长方体
function GeomUtils.addBox(geom, cx, cy, cz, hx, hy, hz)
    local x0, x1 = cx - hx, cx + hx
    local y0, y1 = cy - hy, cy + hy
    local z0, z1 = cz - hz, cz + hz
    GeomUtils.addQuad(geom, Vector3(x0,y0,z1), Vector3(x1,y0,z1), Vector3(x1,y1,z1), Vector3(x0,y1,z1), Vector3(0,0,1))
    GeomUtils.addQuad(geom, Vector3(x1,y0,z0), Vector3(x0,y0,z0), Vector3(x0,y1,z0), Vector3(x1,y1,z0), Vector3(0,0,-1))
    GeomUtils.addQuad(geom, Vector3(x0,y0,z0), Vector3(x0,y0,z1), Vector3(x0,y1,z1), Vector3(x0,y1,z0), Vector3(-1,0,0))
    GeomUtils.addQuad(geom, Vector3(x1,y0,z1), Vector3(x1,y0,z0), Vector3(x1,y1,z0), Vector3(x1,y1,z1), Vector3(1,0,0))
    GeomUtils.addQuad(geom, Vector3(x0,y1,z1), Vector3(x1,y1,z1), Vector3(x1,y1,z0), Vector3(x0,y1,z0), Vector3(0,1,0))
    GeomUtils.addQuad(geom, Vector3(x0,y0,z0), Vector3(x1,y0,z0), Vector3(x1,y0,z1), Vector3(x0,y0,z1), Vector3(0,-1,0))
end

--- 构建圆柱（近似N棱柱）
function GeomUtils.addCylinder(geom, cx, cy, cz, radius, height, segments)
    segments = segments or 8
    local halfH = height / 2
    for i = 0, segments - 1 do
        local a0 = (i / segments) * math.pi * 2
        local a1 = ((i + 1) / segments) * math.pi * 2
        local x0, z0 = cx + math.cos(a0) * radius, cz + math.sin(a0) * radius
        local x1, z1 = cx + math.cos(a1) * radius, cz + math.sin(a1) * radius
        local nx = math.cos((a0 + a1) / 2)
        local nz = math.sin((a0 + a1) / 2)
        GeomUtils.addQuad(geom,
            Vector3(x0, cy - halfH, z0), Vector3(x1, cy - halfH, z1),
            Vector3(x1, cy + halfH, z1), Vector3(x0, cy + halfH, z0),
            Vector3(nx, 0, nz)
        )
    end
end

--- 构建菱形/钻石形
function GeomUtils.addDiamond(geom, cx, cy, cz, radius, halfHeight, segments)
    segments = segments or 8
    for i = 0, segments - 1 do
        local a0 = (i / segments) * math.pi * 2
        local a1 = ((i + 1) / segments) * math.pi * 2
        local x0, z0 = cx + math.cos(a0) * radius, cz + math.sin(a0) * radius
        local x1, z1 = cx + math.cos(a1) * radius, cz + math.sin(a1) * radius
        -- 上锥
        geom:DefineVertex(Vector3(cx, cy + halfHeight, cz))
        geom:DefineNormal(Vector3(0, 1, 0))
        geom:DefineTexCoord(Vector2(0.5, 0))
        geom:DefineVertex(Vector3(x1, cy, z1))
        geom:DefineNormal(Vector3(x1 - cx, 0.5, z1 - cz):Normalized())
        geom:DefineTexCoord(Vector2(1, 1))
        geom:DefineVertex(Vector3(x0, cy, z0))
        geom:DefineNormal(Vector3(x0 - cx, 0.5, z0 - cz):Normalized())
        geom:DefineTexCoord(Vector2(0, 1))
        -- 下锥
        geom:DefineVertex(Vector3(cx, cy - halfHeight, cz))
        geom:DefineNormal(Vector3(0, -1, 0))
        geom:DefineTexCoord(Vector2(0.5, 1))
        geom:DefineVertex(Vector3(x0, cy, z0))
        geom:DefineNormal(Vector3(x0 - cx, -0.5, z0 - cz):Normalized())
        geom:DefineTexCoord(Vector2(0, 0))
        geom:DefineVertex(Vector3(x1, cy, z1))
        geom:DefineNormal(Vector3(x1 - cx, -0.5, z1 - cz):Normalized())
        geom:DefineTexCoord(Vector2(1, 0))
    end
end

--- 构建锥台（上下半径不同的圆柱），用于杖身渐变
function GeomUtils.addTapered(geom, cx, cy, cz, radiusBot, radiusTop, height, segments)
    segments = segments or 12
    local halfH = height / 2
    for i = 0, segments - 1 do
        local a0 = (i / segments) * math.pi * 2
        local a1 = ((i + 1) / segments) * math.pi * 2
        local cos0, sin0 = math.cos(a0), math.sin(a0)
        local cos1, sin1 = math.cos(a1), math.sin(a1)
        -- bottom ring
        local bx0, bz0 = cx + cos0 * radiusBot, cz + sin0 * radiusBot
        local bx1, bz1 = cx + cos1 * radiusBot, cz + sin1 * radiusBot
        -- top ring
        local tx0, tz0 = cx + cos0 * radiusTop, cz + sin0 * radiusTop
        local tx1, tz1 = cx + cos1 * radiusTop, cz + sin1 * radiusTop
        -- normal (approximate)
        local nx = math.cos((a0 + a1) / 2)
        local nz = math.sin((a0 + a1) / 2)
        local ny = (radiusBot - radiusTop) / height
        local nLen = math.sqrt(nx*nx + ny*ny + nz*nz)
        nx, ny, nz = nx/nLen, ny/nLen, nz/nLen
        GeomUtils.addQuad(geom,
            Vector3(bx0, cy - halfH, bz0), Vector3(bx1, cy - halfH, bz1),
            Vector3(tx1, cy + halfH, tz1), Vector3(tx0, cy + halfH, tz0),
            Vector3(nx, ny, nz)
        )
    end
end

--- 构建 UV 球体
function GeomUtils.addSphere(geom, cx, cy, cz, radius, rings, sectors)
    rings = rings or 8
    sectors = sectors or 12
    for r = 0, rings - 1 do
        local phi0 = (r / rings) * math.pi
        local phi1 = ((r + 1) / rings) * math.pi
        local y0 = cy + math.cos(phi0) * radius
        local y1 = cy + math.cos(phi1) * radius
        local r0 = math.sin(phi0) * radius
        local r1 = math.sin(phi1) * radius
        for s = 0, sectors - 1 do
            local theta0 = (s / sectors) * math.pi * 2
            local theta1 = ((s + 1) / sectors) * math.pi * 2
            local cos0, sin0 = math.cos(theta0), math.sin(theta0)
            local cos1, sin1 = math.cos(theta1), math.sin(theta1)
            local p1 = Vector3(cx + cos0 * r0, y0, cz + sin0 * r0)
            local p2 = Vector3(cx + cos1 * r0, y0, cz + sin1 * r0)
            local p3 = Vector3(cx + cos1 * r1, y1, cz + sin1 * r1)
            local p4 = Vector3(cx + cos0 * r1, y1, cz + sin0 * r1)
            local n = Vector3(
                math.cos((theta0+theta1)/2) * math.sin((phi0+phi1)/2),
                math.cos((phi0+phi1)/2),
                math.sin((theta0+theta1)/2) * math.sin((phi0+phi1)/2)
            ):Normalized()
            GeomUtils.addQuad(geom, p1, p2, p3, p4, n)
        end
    end
end

return GeomUtils
