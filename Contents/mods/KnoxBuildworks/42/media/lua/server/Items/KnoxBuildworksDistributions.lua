-- Loot for the magazines that unlock buildables and the building components
-- some recipes use.
require "Items/ProceduralDistributions"
local function add(poolName, item, weight)
    local pool = ProceduralDistributions.list[poolName]
    if not pool or not pool.items then return end
    for index = 1, #pool.items, 2 do if pool.items[index] == item then return end end
    pool.items[#pool.items + 1] = item
    pool.items[#pool.items + 1] = weight
end
local magazines = {
    "KnoxBuildworks.FineWoodWorking_Furniture_BedsCouchesArmchairs",
    "KnoxBuildworks.FineWoodWorking_Furniture_ChairsBenches",
    "KnoxBuildworks.FineWoodWorking_Furniture_Dressers",
    "KnoxBuildworks.FineWoodWorking_Furniture_Crates",
    "KnoxBuildworks.FineWoodWorking_Furniture_Counters",
    "KnoxBuildworks.FineWoodWorking_Furniture_DesksTables",
    "KnoxBuildworks.FineWoodWorking_DoorsWindows",
    "KnoxBuildworks.TheFamilyHandyman_StairsFences",
    "KnoxBuildworks.OldHouseJournal_WoodenFloors",
    "KnoxBuildworks.ArchitecturalDigest_RugsCarpets",
    "KnoxBuildworks.HomeMechanix_Bathroom",
    "KnoxBuildworks.ProjectsInMetal_Diverse",
    "KnoxBuildworks.PopularMechanics_Lighting",
    "KnoxBuildworks.PopularMechanics_HomeAppliances",
    "KnoxBuildworks.FlooringGuide_Ceramic",
    "KnoxBuildworks.FlooringGuide_Paved",
    "KnoxBuildworks.DecorationsGuide_RoadwayGarage",
 }
for index = 1, #magazines do
    add("BookstoreBooks", magazines[index], 0.6)
    add("LibraryBooks", magazines[index], 0.3)
    add("MagazineRackMixed", magazines[index], 0.2)
    add("MechanicShelfBooks", magazines[index], 0.3)
end
local components = {
    "KnoxBuildworks.RefrigerantBottle",
    "KnoxBuildworks.RefrigeratorCompressor",
    "KnoxBuildworks.PlasticSheet",
    "KnoxBuildworks.PlasticSheetSmall",
    "KnoxBuildworks.InsulationFoam",
    "KnoxBuildworks.SmallRubberTube",
    "KnoxBuildworks.ThinCopperPipe",
    "KnoxBuildworks.RubberSeal",
 }
for index = 1, #components do
    add("ToolStoreMisc", components[index], 1.0)
    add("ElectronicStoreMisc", components[index], 1.0)
    add("CrateTools", components[index], 0.5)
end
