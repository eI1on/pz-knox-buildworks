"""Knox-built window coverings use vanilla's native curtain object."""
import unittest

from test_catalog_workspace import LUA, runtime


class NativeCurtainTests(unittest.TestCase):
    def test_all_faces_and_closed_sprites_create_native_curtains(self):
        lua = runtime()
        lua.execute("""
            sprites={}
            local faces={W=4,E=5,N=6,S=7}
            for face,index in pairs(faces) do
                local name='fixtures_windows_curtains_01_'..index
                sprites[name]={name=name,face=face,getProperties=function(s) return {
                    has=function(_,key) return key=='MoveType' or key=='Facing' end,
                    get=function(_,key) return key=='MoveType' and 'WindowObject' or s.face end} end}
            end
            sprites['fixtures_windows_curtains_01_0']={face='W',getProperties=function(s) return {
                has=function(_,key) return key=='MoveType' or key=='Facing' or key=='IsClosedState' end,
                get=function(_,key) return key=='MoveType' and 'WindowObject' or s.face end} end}
            function getSprite(name) return sprites[name] end
            function getCell() return {} end
            GridSquareEdgeFacingDirection={NORTH_SOUTH=1,EAST_WEST=2}
            ISMoveableSpriteProps={new=function() return {
                getWallForFacing=function(_,square) return square.host end} end}
            IsoCurtain={new=function(_,square,name,north) return {
                class='IsoCurtain',name=name,north=north,
                ToggleDoorSilent=function(s) s.closed=true end} end}
            modules['KnoxBuildworks/World/Mannequins']={detect=function() return false end}
            function makeSquare()
                local square={list={}}
                square.host={class='IsoWindow'}
                square.list[1]=square.host
                square.getObjects=function(s) return {
                    size=function() return #s.list end,
                    get=function(_,index) return s.list[index+1] end} end
                square.getWindow=function(s) return s.host end
                square.AddSpecialObject=function(s,object,index)
                    table.insert(s.list,(index or #s.list)+1,object)
                end
                return square
            end
        """)
        types = lua.execute((LUA / "shared/KnoxBuildworks/World/NativeObjectTypes.lua").read_text(encoding="utf-8"))
        lua.globals().modules["KnoxBuildworks/World/NativeObjectTypes"] = types
        lua.globals().factory = lua.execute(
            (LUA / "server/KnoxBuildworks/BuildingObjects/NativeObjectFactory.lua").read_text(encoding="utf-8")
        )
        lua.execute("""
            local faces={W=4,E=5,N=6,S=7}
            for face,index in pairs(faces) do
                local name='fixtures_windows_curtains_01_'..index
                assert(factory.resolve(nil,name)=='curtain')
                local square=makeSquare()
                local object,state=factory.create('curtain',nil,square,name)
                assert(object.class=='IsoCurtain' and object.north==(face=='N' or face=='S'))
                factory.insert(object,state,square)
                assert(square.list[2]==object,face..' curtain must sit after its window')
            end
            local closed=factory.create('curtain',nil,makeSquare(),'fixtures_windows_curtains_01_0')
            assert(closed.name=='fixtures_windows_curtains_01_4' and closed.closed)
        """)


if __name__ == "__main__":
    unittest.main()
