"""Built wall light switches and built glass panes behave like the engine's own.

* A wall-switch tile has no lightR, so IsoLightSwitch makes it a room switch,
  and setActive refuses to toggle one outside a map room. Knox-built switches
  outside map rooms are toggled by World/LightSwitches through setActive (the
  engine's own sync) and switch the fixtures in their enclosed area.
* windowN/windowW tiles are IsoWindow objects on the map; as IsoThumpable they
  were open frames anyone could climb through (the sliding-door side panel).
"""
import re
import unittest
from pathlib import Path

import kbw_runtime as k

from test_catalog_workspace import LUA, ROOT, runtime

TILES = k.kbw_paths.TILE_DEFINITIONS


def world(lua):
    lua.execute("""
        ISToggleLightAction = {complete=function(self) self.object.vanilla = true; return true end}
        modules['TimedActions/ISToggleLightAction'] = ISToggleLightAction
        squares = {}
        walls = {}
        function key(x,y) return x..','..y end
        function list(items)
            return {size=function() return #items end, get=function(_,i) return items[i+1] end}
        end
        function square(x,y,room)
            local s={x=x,y=y,objects={},room=room}
            s.getX=function() return x end; s.getY=function() return y end; s.getZ=function() return 0 end
            s.getRoom=function() return s.room end
            s.getObjects=function() return list(s.objects) end
            local function blocked(other) return walls[key(x,y)..'|'..key(other.x,other.y)]
                or walls[key(other.x,other.y)..'|'..key(x,y)] end
            s.isWallTo=function(_,o) return blocked(o) == true end
            s.isDoorTo=function() return false end
            s.isWindowTo=function() return false end
            squares[key(x,y)] = s
            return s
        end
        function getCell() return {getGridSquare=function(_,x,y) return squares[key(x,y)] end} end
        function instanceof(o, class) return o and o.class == class end
        function light(sq, props, opts)
            opts = opts or {}
            local o={class='IsoLightSwitch', on=opts.on ~= false, modifiable=opts.modifiable or false,
                battery=opts.battery or false, powered=opts.powered ~= false, sets=0, md=opts.md}
            o.getSquare=function() return sq end
            o.getSprite=function() return {getProperties=function() return {has=function(_,k) return props[k]==true end} end} end
            o.isActivated=function() return o.on end
            o.getCanBeModified=function() return o.modifiable end
            o.setCanBeModified=function(_,v) o.modifiable=v end
            o.getUseBattery=function() return o.battery end
            o.hasModData=function() return o.md ~= nil end
            o.getModData=function() return o.md end
            o.setActive=function(_,v)
                o.sets=o.sets+1
                -- IsoLightSwitch.setActive: a room switch without a room only
                -- moves when it is modifiable, and every light needs power.
                if sq.room == nil and not o.modifiable then return o.on end
                if o.powered then o.on=v end
                return o.on
            end
            sq.objects[#sq.objects+1]=o
            return o
        end
    """)
    lights = lua.execute((LUA / "shared/KnoxBuildworks/World/LightSwitches.lua").read_text(encoding="utf-8-sig"))
    lua.globals().lights = lights
    return lights


class LightSwitchTests(unittest.TestCase):
    def test_detached_switch_toggles_and_switches_fixtures_inside_its_walls(self):
        lua = runtime()
        world(lua)
        lua.execute("""
            for x=0,5 do for y=0,3 do square(x,y,nil) end end
            -- A wall between x=2 and x=3 splits two rooms.
            for y=0,3 do walls[key(2,y)..'|'..key(3,y)]=true end
            local wall=light(squares[key(0,0)], {}, {md={KBW={}}})
            local lamp=light(squares[key(2,3)], {lightR=true}, {modifiable=true})
            local sign=light(squares[key(2,0)], {lightR=true})
            local battery=light(squares[key(1,1)], {lightR=true}, {battery=true})
            local street=light(squares[key(1,2)], {lightR=true, streetlight=true})
            local other=light(squares[key(4,1)], {lightR=true})
            assert(lights.isDetachedSwitch(wall))
            local action=setmetatable({object=wall},{__index=ISToggleLightAction})
            assert(ISToggleLightAction.complete(action)==true and not wall.vanilla)
            assert(wall.on==false and wall.modifiable==false, 'switch toggled, flag restored')
            assert(lamp.on==false and sign.on==false, 'fixtures in the same room follow the switch')
            assert(lamp.modifiable==true and sign.modifiable==false, 'modifiable flags restored')
            assert(battery.on and street.on and other.on, 'battery lamps, street lights and other rooms untouched')
            ISToggleLightAction.complete(action)
            assert(wall.on and lamp.on)
        """)

    def test_room_switches_lamps_and_vanilla_switches_keep_vanilla_behaviour(self):
        lua = runtime()
        world(lua)
        lua.execute("""
            local roomSquare=square(0,0,{id=1}); local open=square(1,0,nil)
            local inRoom=light(roomSquare, {}, {md={KBW={}}})
            local vanilla=light(open, {})
            local lamp=light(open, {lightR=true}, {md={KBW={}}})
            for _,o in pairs({inRoom, vanilla, lamp}) do
                assert(not lights.isDetachedSwitch(o))
                local action=setmetatable({object=o},{__index=ISToggleLightAction})
                ISToggleLightAction.complete(action); assert(o.vanilla)
            end
        """)

    def test_unpowered_switch_does_not_change_fixtures(self):
        lua = runtime()
        world(lua)
        lua.execute("""
            square(0,0,nil); square(1,0,nil)
            local wall=light(squares[key(0,0)], {}, {md={KBW={}}, powered=false})
            local lamp=light(squares[key(1,0)], {lightR=true})
            assert(lights.toggle(wall)==true and wall.on and lamp.on and lamp.sets==0)
        """)

    def test_factory_pushes_room_state_and_server_installs_the_hook(self):
        factory = (LUA / "server/KnoxBuildworks/BuildingObjects/NativeObjectFactory.lua").read_text(encoding="utf-8")
        switch = factory[factory.index('register("lightSwitch"'):factory.index('register("window"')]
        self.assertIn("object:switchLight(object:isActivated())", switch)
        self.assertNotIn("setPower", switch)
        server = (LUA / "server/KnoxBuildworks/Server.lua").read_text(encoding="utf-8")
        self.assertIn('require("KnoxBuildworks/World/LightSwitches")', server)


class GlassPaneTests(unittest.TestCase):
    def test_glass_panes_are_built_as_native_windows(self):
        build = (LUA / "server/KnoxBuildworks/BuildingObjects/KBWBuildingObject.lua").read_text(encoding="utf-8")
        self.assertIn('if not nativeObjectType and not spriteConfig.onCreate and isGlassPaneSprite(tile.sprite) then', build)
        self.assertIn('if nativeObjectType == "window" then part = self:connectWallParts(target, part, north) end', build)
        factory = (LUA / "server/KnoxBuildworks/BuildingObjects/NativeObjectFactory.lua").read_text(encoding="utf-8")
        window = factory[factory.index('register("window"'):]
        self.assertIn("IsoWindow.new(getCell(), square, sprite, properties:has(IsoFlagType.windowN))", window)
        self.assertIn("object:setIsLocked(false)", window)

    @unittest.skipUnless(TILES is not None, "needs the game's newtiledefinitions.tiles.txt")
    def test_sliding_door_side_panels_are_locked_glass(self):
        text = TILES.read_text(encoding="utf-8", errors="replace")
        for sprite in ("fixtures_doors_01_106", "fixtures_doors_01_107", "fixtures_doors_01_114", "fixtures_doors_01_115"):
            body = re.search(r"// %s\s+tile\s*\{(.*?)\n    \}" % sprite, text, re.S).group(1)
            self.assertRegex(body, r"\bwindow[NW] =", sprite)
            self.assertIn("WindowLocked", body, sprite)


if __name__ == "__main__":
    unittest.main()
