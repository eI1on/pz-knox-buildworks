"""Blueprint size limits and the chunked multiplayer transport.

* HARD_LIMIT caps every blueprint; the sandbox "Max pieces per blueprint"
  caps building by hand; "Allow importing blueprints over the limit" lets a
  bigger blueprint be brought in whole, keep its size and stay editable.
* Every MP command is written into a fixed 1,000,000-byte connection buffer
  (UdpConnection.startPacket), so whole blueprints travel as a head plus
  chunks. The wire-size test encodes each command the way
  TableNetworkUtils.save does.
"""
import struct
import unittest

from test_catalog_workspace import runtime
from test_planning_selection import load

CONNECTION_BUFFER = 1_000_000


def limits_runtime():
    """The planning-selection stubs, plus a Core with sandbox values, registered
    before Blueprints loads (unregistered requires return a fresh table)."""
    lua = runtime()
    lua.execute("""
        modules['KnoxBuildworks/Definitions/Resolver']={resolveStage=function(id)
            return {id=id,placement={kind='floor'}},{id='built'} end}
        modules['KnoxBuildworks/Geometry/Matrix']={getFaceCells=function() return {{dx=0,dy=0,blocks=true,kind='floor'}} end,
            getFaceSprite=function() return nil end}
        modules['KnoxBuildworks/Validation/Placement']={previousStageOf=function() end,
            optionalReplacementStageOf=function() end}
        modules['KnoxBuildworks/Definitions/StageConfig']={placement=function(d) return d.placement end,
            sprite=function() return {} end}
        modules['KnoxBuildworks/Planning/BlueprintFiles']={queueSave=function() end, loadAll=function() return {} end,
            remove=function() end, save=function() end}
        function isClient() return false end
        function isServer() return false end
        SANDBOX = {}
        modules['KnoxBuildworks/Core'] = { NETWORK_MODULE = 'KnoxBuildworks', Runtime = { loaded = true },
            sandboxValue = function(name, default)
                if SANDBOX[name] == nil then return default end
                return SANDBOX[name]
            end }
    """)
    shape = load(lua, "shared/KnoxBuildworks/Planning/RoomShape.lua", "RoomShape")
    lua.globals().modules["KnoxBuildworks/Planning/RoomShape"] = shape
    load(lua, "shared/KnoxBuildworks/Planning/Blueprints.lua", "bp")
    lua.execute("""
        bp.blueprintRadius = function() return 100000 end
        SENT = {}
        function sendServerCommand(target, module, command, args)
            SENT[#SENT + 1] = { to = target, command = command, args = args }
        end
        function sendClientCommand(player, module, command, args)
            SENT[#SENT + 1] = { command = command, args = args }
        end
        OWNER = { getUsername = function() return 'owner' end, getAccessLevel = function() return '' end }
        OTHER = { getUsername = function() return 'other' end, getAccessLevel = function() return '' end }
        function makePlacements(count, finished)
            local list = {}
            for i = 1, count do
                local p = { id = 'p' .. i, buildableId = 'kbw.vanillaexpanded.walls.white_clapboard.white_clapboard_wall',
                    stageId = 'built', x = 10000 + i, y = 20000, z = 0, direction = 1 }
                if finished then
                    p.finish = { label = 'Plaster then paint Light Brown', actionType = 'wallFinish', plaster = true,
                        paintType = 'PaintLightBrown', color = { r = 0.59, g = 0.44, b = 0.21 } }
                end
                list[i] = p
            end
            return list
        end
        function makeExport(count)
            local data = { name = 'big', relativeLevel = 0, exportSchema = 1, placements = {}, rooms = {} }
            for i = 1, count do
                data.placements[i] = { id = 'p' .. i, buildableId = 'floor', x = i, y = 0, z = 0, direction = 1 }
            end
            return data
        end
    """)
    return lua


class LimitTests(unittest.TestCase):
    def test_building_limit_defaults_and_hard_cap(self):
        lua = limits_runtime()
        lua.execute("""
            assert(bp.HARD_LIMIT == 10000)
            assert(bp.maxPlacements() == 2500, bp.maxPlacements())
            SANDBOX['KnoxBuildworks.MaxPlacementsPerBlueprint'] = 50000
            assert(bp.maxPlacements() == 10000)
            SANDBOX['KnoxBuildworks.MaxPlacementsPerBlueprint'] = 300
            assert(bp.importLimit() == 10000)
            SANDBOX['KnoxBuildworks.AllowOversizedImports'] = false
            assert(bp.importLimit() == 300)
        """)

    def test_limit_for_a_blueprint(self):
        lua = limits_runtime()
        lua.execute("""
            SANDBOX['KnoxBuildworks.MaxPlacementsPerBlueprint'] = 10
            assert(bp.limitFor({}) == 10)
            assert(bp.limitFor({ importedSize = 5 }) == 10)
            assert(bp.limitFor({ importedSize = 30 }) == 30)
            assert(bp.limitFor({ importedSize = 50000 }) == 10000)
        """)

    def test_import_over_the_building_limit_stays_editable_but_cannot_grow(self):
        lua = limits_runtime()
        lua.execute("""
            SANDBOX['KnoxBuildworks.MaxPlacementsPerBlueprint'] = 10
            bp.canContribute = function() return true end
            local imported = bp.importExported(nil, makeExport(30))
            assert(imported and imported.importedSize == 30 and bp.limitFor(imported) == 30)
            bp.get = function() return imported end
            -- full: nothing more by hand
            local added, why = bp.addPlacement(nil, imported.id,
                { buildableId = 'floor', x = 500, y = 0, z = 0, direction = 1 })
            assert(added == nil and why == 'placement_limit', tostring(why))
            -- replace a piece: remove, then add back in
            assert(bp.removePlacement(nil, imported.id, imported.placements[1].id))
            added = bp.addPlacement(nil, imported.id, { buildableId = 'floor', x = 501, y = 0, z = 0, direction = 1 })
            assert(added and #imported.placements == 30)
            local small = bp.importExported(nil, makeExport(3))
            assert(small.importedSize == nil)
        """)

    def test_import_over_the_limit_is_refused_when_the_server_disallows_it(self):
        lua = limits_runtime()
        lua.execute("""
            SANDBOX['KnoxBuildworks.MaxPlacementsPerBlueprint'] = 10
            SANDBOX['KnoxBuildworks.AllowOversizedImports'] = false
            local result, reason = bp.importExported(nil, makeExport(11))
            assert(result == nil and reason == 'too_many_pieces:11', tostring(reason))
            local text = bp.importErrorText(reason)
            assert(string.find(text, 'BlueprintImportTooLarge', 1, true), text)
            SANDBOX['KnoxBuildworks.AllowOversizedImports'] = true
            result, reason = bp.importExported(nil, makeExport(10001))
            assert(result == nil and reason == 'too_many_pieces:10001', tostring(reason))
        """)

    def test_exports_carry_no_local_size_or_transfer_state(self):
        lua = limits_runtime()
        lua.execute("""
            local data = bp.exportTable({ name = 'x', level = 0, origin = { x = 0, y = 0, z = 0 },
                importedSize = 30, importPending = 5, importTotal = 9, placements = {} })
            assert(data.importedSize == nil and data.importPending == nil and data.importTotal == nil)
        """)


class TransportTests(unittest.TestCase):
    def test_server_create_assembles_chunks_from_the_owner_only(self):
        lua = limits_runtime()
        lua.execute("""
            SANDBOX['KnoxBuildworks.MaxPlacementsPerBlueprint'] = 10
            local all = makePlacements(1000)
            local head = bp.transferHead({ id = 'big', name = 'big', placements = all })
            head.importTotal = 1000
            local created, applied = bp.applyServerCommand(OWNER, 'BPCreate', { blueprint = head })
            assert(applied and #created.placements == 400 and created.importPending == 600)
            assert(created.importedSize == 1000)
            local chunks = {}
            bp.eachTransferChunk(all, function(part) chunks[#chunks + 1] = part end)
            assert(#chunks == 2 and #chunks[1] == 400 and #chunks[2] == 200)
            bp.get = function() return created end
            bp.isOwner = function(player) return player == OWNER end
            local _, ok = bp.applyServerCommand(OTHER, 'BPImportChunk', { id = 'big', placements = chunks[1] })
            assert(not ok, 'a non-owner appended')
            _, ok = bp.applyServerCommand(OWNER, 'BPImportChunk', { id = 'big', placements = chunks[1] })
            assert(ok and created.importPending == 200)
            _, ok = bp.applyServerCommand(OWNER, 'BPImportChunk', { id = 'big', placements = makePlacements(201) })
            assert(not ok, 'more than declared')
            _, ok = bp.applyServerCommand(OWNER, 'BPImportChunk', { id = 'big', placements = chunks[2] })
            assert(ok and #created.placements == 1000 and created.importPending == nil)
            _, ok = bp.applyServerCommand(OWNER, 'BPImportChunk', { id = 'big', placements = chunks[2] })
            assert(not ok, 'chunks after the declared total')
        """)

    def test_server_create_refuses_more_than_the_import_limit(self):
        lua = limits_runtime()
        lua.execute("""
            local head = { id = 'huge', placements = makePlacements(10), importTotal = 10001 }
            local _, applied = bp.applyServerCommand(OWNER, 'BPCreate', { blueprint = head })
            assert(not applied)
            local claim = { id = 'claim', placements = {}, importedSize = 99999 }
            local created
            created, applied = bp.applyServerCommand(OWNER, 'BPCreate', { blueprint = claim })
            assert(applied and created.importedSize == 10000 and created.importPending == nil)
        """)

    def test_sync_streams_and_the_client_reassembles(self):
        lua = limits_runtime()
        lua.execute("""
            local blueprint = { id = 'big', name = 'big', placements = makePlacements(1000) }
            SENT = {}
            bp.serverSyncTo(OTHER, blueprint)
            assert(#SENT == 3 and SENT[1].command == 'BPSync' and SENT[2].command == 'BPSyncChunk')
            assert(#blueprint.placements == 1000, 'transport touched the stored blueprint')
            function isClient() return true end
            bp.applySync({ big = SENT[1].args.item }, true)
            for i = 2, #SENT do bp.applySyncChunk(SENT[i].args.id, SENT[i].args.placements) end
            local got = bp.sharedItems().big
            assert(#got.placements == 1000)
            for i = 1, 1000 do assert(got.placements[i].id == 'p' .. i) end
        """)

    def test_login_sync_never_puts_two_blueprints_in_one_command(self):
        lua = limits_runtime()
        lua.execute("""
            function isServer() return true end
            bp.shouldSync = function() return true end
            local store = bp.sharedItems()
            store.a = { id = 'a', placements = makePlacements(10) }
            store.b = { id = 'b', placements = makePlacements(900) }
            SENT = {}
            bp.serverSyncAll(OTHER)
            assert(SENT[1].command == 'BPSyncAll' and next(SENT[1].args.items) == nil)
            local syncs = 0
            for i = 2, #SENT do
                assert(SENT[i].command == 'BPSync' or SENT[i].command == 'BPSyncChunk')
                if SENT[i].command == 'BPSync' then syncs = syncs + 1 end
            end
            assert(syncs == 2 and #SENT == 1 + 1 + 1 + 2)
        """)

    def test_client_import_sends_a_head_and_chunks(self):
        lua = limits_runtime()
        lua.execute("""
            function isClient() return true end
            SENT = {}
            local imported = bp.importExported(nil, makeExport(900))
            assert(imported and #imported.placements == 900)
            assert(SENT[1].command == 'BPCreate' and SENT[1].args.blueprint.importTotal == 900)
            assert(#SENT[1].args.blueprint.placements == 400 and imported.importTotal == nil)
            assert(SENT[2].command == 'BPImportChunk' and #SENT[3].args.placements == 100 and #SENT == 3)
        """)

    def test_every_command_fits_the_connection_buffer_at_the_hard_limit(self):
        lua = limits_runtime()
        lua.execute("""
            SENT = {}
            local blueprint = { id = 'max', name = 'max', placements = makePlacements(10000, true),
                rooms = {}, access = { scope = 'private', players = {}, factions = {} }, owner = 'owner' }
            bp.serverSyncTo(OTHER, blueprint)
            function isClient() return true end
            bp.sendCreate(OWNER, blueprint)
        """)
        sent = lua.globals().SENT
        sizes = [encoded(sent[i].args) for i in range(1, len(sent) + 1)]
        self.assertEqual(len(sizes), 2 * 25)
        self.assertLess(max(sizes), CONNECTION_BUFFER // 4, f"largest command {max(sizes)} bytes")
        # Without chunking the same blueprint would not fit.
        whole = lua.eval("{ item = { placements = makePlacements(10000, true) } }")
        self.assertGreater(encoded(whole), CONNECTION_BUFFER)


def encoded(table):
    """Bytes TableNetworkUtils.save writes: int count, then per entry a type
    byte and a UTF string (2-byte length) or 8-byte double for the key and
    the value; nested tables recurse."""
    def utf(value):
        return 1 + 2 + len(str(value).encode("utf-8"))

    def value_size(value):
        if hasattr(value, "items") and not isinstance(value, (str, bytes)):
            return 1 + table_size(value)
        if isinstance(value, bool):
            return 2
        if isinstance(value, (int, float)):
            return 1 + len(struct.pack(">d", float(value)))
        return utf(value)

    def table_size(t):
        total = 4
        for key, value in t.items():
            total += utf(key) if isinstance(key, str) else 9
            total += value_size(value)
        return total

    return table_size(table)


if __name__ == "__main__":
    unittest.main()
