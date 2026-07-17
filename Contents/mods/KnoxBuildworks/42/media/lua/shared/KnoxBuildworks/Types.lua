---Static EmmyLua domain types for Knox Buildworks.
---This module is documentation-only; runtime modules use ordinary Lua tables.

---@alias KBW.Direction 1|2|3|4
---@alias KBW.DirectionName 'N'|'E'|'S'|'W'
---@alias KBW.InputRole 'material'|'tool'|'consumable'|'component'|'resource'
---@alias KBW.InputMode 'consume'|'keep'|'drain'|'destroy'
---@alias KBW.ResourceType 'Item'|'Fluid'|'Energy'
---@alias KBW.AccessLevel 'none'|'view'|'build'|'contribute'
---@alias KBW.AccessScope 'private'|'view'|'build'|'contribute'

---@class KBW.LocalizedOption
---@field id string
---@field translationKey? string
---@field labelKey? string
---@field displayName? string
---@field label? string
---@field name? string

---@class KBW.BuildInput
---@field id string
---@field role KBW.InputRole
---@field mode KBW.InputMode
---@field resourceType? KBW.ResourceType
---@field label? string
---@field labelKey? string
---@field icon? string
---@field items? string[]
---@field tags? string[]
---@field amount? number
---@field amountMax? number
---@field uses? number
---@field flags? string[]
---@field materialTags? string[]
---@field selectedFullType? string

---@class KBW.KnowledgeRequirement
---@field recipes? string[]
---@field sources? string[]
---@field needToBeLearned? boolean

---@class KBW.RequirementSet
---@field inputs? KBW.BuildInput[]
---@field materials? KBW.BuildInput[]|string
---@field tools? KBW.BuildInput[]
---@field skills? table<string, integer>
---@field knowledge? KBW.KnowledgeRequirement
---@field recipes? string[]
---@field debugOnly? boolean

---@class KBW.GeometryCell
---@field sprite? string
---@field empty? boolean
---@field blocks? boolean
---@field kind? string
---@field properties? table<string, unknown>
---@field dx? integer
---@field dy? integer
---@field dz? integer

---@class KBW.GeometryLayer
---@field rows (KBW.GeometryCell|string|boolean)[][]

---@class KBW.GeometryFace
---@field layers KBW.GeometryLayer[]

---@class KBW.Geometry
---@field faces? table<KBW.DirectionName, KBW.GeometryFace>

---@class KBW.EntityCompat
---@field module? string
---@field entity string

---@class KBW.EntitySpriteMetadata
---@field geometry? KBW.Geometry
---@field sprites? table<string, string>
---@field health? number
---@field skillBaseHealth? number
---@field bonusHealth? number
---@field previousStage? string|string[]
---@field isThumpable? boolean
---@field isProp? boolean
---@field canBePadlocked? boolean
---@field breakSound? string
---@field corner? string
---@field dontNeedFrame? boolean
---@field needWindowFrame? boolean
---@field needToBeAgainstWall? boolean
---@field isPole? boolean
---@field onCreate? string
---@field onIsValid? string
---@field timedActionOnIsValid? string
---@field lightRadius? integer
---@field lightsourceItem? string
---@field lightsourceTags? string[]
---@field lightsourceFuel? string
---@field debugItem? string
---@field lightOffsets? table<KBW.DirectionName, KBW.LightOffset>

---@class KBW.EntityRecipeMetadata
---@field requirements? KBW.RequirementSet
---@field time? number
---@field timedAction? string
---@field category? string
---@field tags? string[]
---@field canWalk? boolean
---@field icon? string
---@field tooltip? string
---@field needToBeLearn? boolean
---@field xpAward? table<string, number>
---@field onAddToMenu? string

---@class KBW.EntityMetadata: KBW.EntityCompat
---@field scriptName? string
---@field spriteConfig? KBW.EntitySpriteMetadata|table<string, unknown>
---@field craftRecipe? KBW.EntityRecipeMetadata|table<string, unknown>
---@field wallCoveringConfig? table<string, unknown>

---@class KBW.FinishSurface
---@field canPlaster? boolean
---@field canPaint? boolean
---@field canWallpaper? boolean
---@field paintRequiresPlaster? boolean
---@field wallpaperRequiresPlaster? boolean

---@class KBW.FinishConfig
---@field enabled? boolean
---@field wallType? string
---@field paints? string[]|boolean
---@field wallpapers? string[]|boolean
---@field surface? KBW.FinishSurface
---@field mapping? table<string, unknown>

---@class KBW.PlacementConfig
---@field kind? 'object'|'wall'|'floor'|'stairs'|'overlay'|'wallCovering'
---@field requiresFloor? boolean
---@field maxDistance? number
---@field againstWall? boolean
---@field needToBeAgainstWall? boolean
---@field dontNeedFrame? boolean
---@field needWindowFrame? boolean
---@field isPole? boolean
---@field wallCoveringType? 'plaster'|'paint'|'paintThump'|'wallpaper'|'paintSign'
---@field sign? integer|string

---@class KBW.AnimVariable
---@field key string
---@field value string

---@class KBW.ConstructionConfig
---@field time? number
---@field timedAction? string
---@field sound? string
---@field completionSound? string
---@field actionAnim? string
---@field animVariable? KBW.AnimVariable
---@field canWalk? boolean
---@field category? string
---@field tags? string[]
---@field xp? table<string, number>

---@class KBW.ObjectConfig
---@field isThumpable? boolean
---@field isProp? boolean
---@field dismantable? boolean
---@field blockAllSquare? boolean
---@field canPassThrough? boolean
---@field hoppable? boolean
---@field canBarricade? boolean
---@field canBePadlocked? boolean
---@field thumpDamage? number
---@field breakSound? string
---@field cornerSprite? string
---@field buildLow? boolean
---@field drawFloorGrid? boolean

---@class KBW.CallbackConfig
---@field onAddToMenu? string
---@field onCreate? string
---@field onIsValid? string
---@field timedActionOnIsValid? string

---@class KBW.LightOffset
---@field x? number
---@field y? number
---@field z? number

---@class KBW.LightSourceConfig
---@field radius integer
---@field item? string
---@field tags? string[]
---@field fuel? string
---@field debugItem? string
---@field offsets? table<KBW.DirectionName, KBW.LightOffset>

---@class KBW.BuildStage
---@field id string
---@field level? integer
---@field translationKey? string
---@field labelKey? string
---@field displayName? string
---@field label? string
---@field previousStage? string|string[]
---@field icon? string
---@field iconName? string
---@field iconTexture? string
---@field iconItem? string
---@field iconSprite? string
---@field health? number
---@field skillBaseHealth? number
---@field bonusHealth? number
---@field xp? table<string, number>
---@field object? KBW.ObjectConfig
---@field callbacks? KBW.CallbackConfig
---@field lightSource? KBW.LightSourceConfig
---@field allowSpriteReuse? boolean Explicit opt-in for sprites intentionally shared by multiple definitions.
---@field finishes? KBW.FinishConfig
---@field finishOptions? KBW.WallFinish[]
---@field entityCompat? KBW.EntityCompat
---@field sprites? table<string, string>
---@field geometry? KBW.Geometry
---@field requirements? KBW.RequirementSet
---@field placement? KBW.PlacementConfig
---@field construction? KBW.ConstructionConfig

---@class KBW.BuildableGroup
---@field id string
---@field name? string
---@field translationKey? string
---@field level? integer

---@class KBW.BuildableDefinition
---@field id string
---@field extends? string
---@field translationKey? string
---@field displayName? string
---@field description? string
---@field descriptionKey? string
---@field tooltipKey? string
---@field icon? string
---@field iconName? string
---@field iconTexture? string
---@field iconItem? string
---@field iconSprite? string
---@field category string
---@field subcategory? string
---@field material? string
---@field tags? string[]
---@field materialTags? string[]
---@field styleTags? string[]
---@field aliases? string[]
---@field allowSpriteReuse? boolean Explicit opt-in for sprites intentionally shared by multiple definitions.
---@field group? KBW.BuildableGroup
---@field variants? KBW.LocalizedOption[]
---@field materialOptions? KBW.LocalizedOption[]
---@field tools? KBW.BuildInput[]
---@field placement? KBW.PlacementConfig
---@field construction? KBW.ConstructionConfig
---@field finishes? KBW.FinishConfig
---@field spritePattern? table<string, unknown>
---@field postBuildActions? table[]
---@field stages KBW.BuildStage[]
---@field source? string

---@class KBW.DefinitionBundle
---@field schemaVersion integer
---@field templates? table<string, table>
---@field materialGroups? table<string, table>
---@field buildables KBW.BuildableDefinition[]

---@class KBW.WallFinish
---@field id? string
---@field label? string
---@field actionType? string
---@field none? boolean
---@field plaster? boolean
---@field paintType? string
---@field wallpaperType? string
---@field sign? string

---@class KBW.RequirementAvailableItem
---@field fullType string
---@field count integer
---@field uses number
---@field available number
---@field item? InventoryItem
---@field items InventoryItem[]

---@class KBW.RequirementRow
---@field id? string
---@field kind 'input'|'skill'|'knowledge'|string
---@field role? string
---@field mode? KBW.InputMode
---@field resourceType? KBW.ResourceType
---@field label? string
---@field labelKey? string
---@field icon? string
---@field flags? string[]
---@field possibleItems? string[]
---@field possibleTags? string[]
---@field availableItems? KBW.RequirementAvailableItem[]
---@field needed number
---@field neededMax? number
---@field available number
---@field ok boolean
---@field item? InventoryItem
---@field selectedFullType? string
---@field name? string
---@field sources? string[]
---@field row? KBW.BuildInput

---@class KBW.RequirementStatus
---@field ok boolean
---@field reason? string
---@field materials table[]
---@field tools table[]
---@field skills KBW.RequirementRow[]
---@field recipes KBW.RequirementRow[]
---@field rows KBW.RequirementRow[]

---@class KBW.BlueprintAccess
---@field scope KBW.AccessScope
---@field players table<string, KBW.AccessLevel>
---@field factions table<string, KBW.AccessLevel>

---@class KBW.BlueprintRoom
---@field id string
---@field name? string
---@field type? string
---@field x number
---@field y number
---@field z number
---@field w number
---@field h number
---@field color? {r:number, g:number, b:number, a:number}

---@class KBW.GatherArea
---@field x1 integer
---@field y1 integer
---@field x2 integer
---@field y2 integer
---@field z integer

---@class KBW.BlueprintPlacement
---@field id string
---@field buildableId string
---@field stageId? string
---@field variantId? string
---@field materialId? string
---@field x integer
---@field y integer
---@field z integer
---@field direction KBW.Direction
---@field finish? KBW.WallFinish
---@field finishTarget? table<string, unknown>
---@field creator? string
---@field timestamp? number|string

---@class KBW.Blueprint
---@field id string
---@field name string
---@field level integer
---@field origin {x:number, y:number, z:number}
---@field anchored boolean
---@field anchor? {x:number, y:number}
---@field radius integer
---@field owner string
---@field access KBW.BlueprintAccess
---@field rooms KBW.BlueprintRoom[]
---@field placements KBW.BlueprintPlacement[]
---@field gatherArea? KBW.GatherArea
---@field updated number|string

---@class KBW.BlueprintTotalRow
---@field key string
---@field label? string
---@field labelKey? string
---@field amount? number
---@field needed? number
---@field selectedFullType? string
---@field row? KBW.BuildInput

---@class KBW.BlueprintTotals
---@field placements integer
---@field materials table<string, KBW.BlueprintTotalRow>
---@field tools table<string, KBW.BlueprintTotalRow>
---@field skills table<string, {name:string, needed:integer}>

---@class KBW.PlacementCell
---@field x integer
---@field y integer
---@field z integer
---@field sprite? string
---@field blocks? boolean

---@class KBW.ValidationResult
---@field ok boolean
---@field reason? string
---@field definition? KBW.BuildableDefinition
---@field stage? KBW.BuildStage
---@field status? KBW.RequirementStatus

return {}
