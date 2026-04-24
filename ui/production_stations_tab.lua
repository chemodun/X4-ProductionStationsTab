-- Production Stations Tab
-- Adds a "Production Stations" tab to the Property Owned menu (left-panel map menu).
-- Shows all player-owned stations that have at least one already-built production or
-- processing module. Stations with production issues are highlighted.
--
-- Compatible with X4 8.00 and 9.00, accounting for the RowGroup API added in 9.00.

local ffi = require("ffi")
local C   = ffi.C

ffi.cdef [[
  typedef uint64_t UniverseID;

  bool IsRealComponentClass(UniverseID componentid, const char* classname);
  bool IsComponentWrecked(UniverseID componentid);

  double   GetContainerWareConsumption(UniverseID containerid, const char* wareid, bool ignorestate);
  double   GetContainerWareProduction(UniverseID containerid, const char* wareid, bool ignorestate);
  uint32_t GetAllFactionStations(UniverseID* result, uint32_t resultlen, const char* factionid);
  uint32_t GetNumAllFactionStations(const char* factionid);
  uint32_t GetNumStationModules(UniverseID stationid, bool includeconstructions, bool includewrecks);
  uint32_t GetStationModules(UniverseID* result, uint32_t resultlen, UniverseID stationid, bool includeconstructions, bool includewrecks);

  typedef struct {
    int major;
    int minor;
  } GameVersion;
  GameVersion  GetGameVersion();
]]

-- *** constants ***

local PAGE_ID = 1972092418

local MODE         = "productionStations"
local TAB_ICON     = "stationbuildst_production"
local SPO_CATEGORY = "chem_station_prod_overview"

-- *** module table ***

local pst = {
  menuMap              = nil,
  menuMapConfig        = {},
  prodOverviewExpanded = {},
  isV9                 = C.GetGameVersion().major >= 9,
  mapFontSize          = Helper.standardFontSize,
  hasSPO               = nil,   -- nil = not yet checked; true/false cached after first displayTabData
  -- Error-highlighting options (read from MD blackboard, same keys as SPO)
  ignoreNoResources    = false, -- when true, noRes modules are not highlighted as issues
  ignoreWaitStore      = false, -- when true, waitStore modules are not highlighted as issues
  playerId             = nil,   -- set in pst.Init(); used to read MD blackboard config
  -- Data cache for throttled refresh (same pattern as SPO)
  dataRefreshInterval  = 3,    -- recompute every N render calls; configured via MD options slider
  dataCache            = {},   -- key: station-id string → { stationData, turnCounter }
}

-- *** debug helpers ***

local debugLevel = "none"  -- "none" | "debug" | "trace"

--- Read error-ignore config from the MD-side player.entity.$productionStationsTab blackboard.
--- Called on init and whenever any options menu control changes (PST.ConfigChanged event).
local function pstOnConfigChanged()
  if pst.playerId == nil then return end
  local cfg = GetNPCBlackboard(pst.playerId, "$productionStationsTab")
  if cfg then
    if cfg.dataRefreshInterval then
      pst.dataRefreshInterval = math.max(1, math.min(10, tonumber(cfg.dataRefreshInterval) or 3))
    end
    pst.ignoreNoResources = cfg.ignoreNoResources == 1
    pst.ignoreWaitStore   = cfg.ignoreWaitStore   == 1
    pst.dataCache = {} -- invalidate cache so next render reflects new settings
  end
end

local function debug(msg)
  if debugLevel ~= "none" then
    if type(DebugError) == "function" then
      DebugError("ProductionStationsTab: " .. msg)
    end
  end
end

local function trace(msg)
  if debugLevel == "trace" then
    debug(msg)
  end
end

-- *** production module detection ***

--- Returns true if the station has at least one already-built production or
--- processing module (not under construction, not wrecked).
-- *** storage issue detection ***

--- Returns an issues table for a station, or nil if not a production station.
---
--- Modules are classified into three pipeline stages:
---   "resource"     — first-line: produces intermediates but consumes only pure resources
---   "intermediate" — middle stages: consumes at least one intermediate ware
---   "production"   — final stage: produces the station's externally-sold products
---
--- For each stage, two issue states are counted:
---   noResources  ("waitingforresources")
---   waitStorage  ("waitingforstorage" / "choosingitem")
---
--- The stage-counts drive hasIssue (any non-zero count = issue) and the
--- mouseover text on the station row.
local function getProductionStationData(component)
  local station64 = ConvertIDTo64Bit(component)

  -- *** Cache check — reuse expensive data for dataRefreshInterval turns ***
  local cacheKey = tostring(station64)
  local cached   = pst.dataCache[cacheKey]
  if cached and cached.turnCounter < pst.dataRefreshInterval then
    cached.turnCounter = cached.turnCounter + 1
    return cached.stationData
  end

  local n = tonumber(C.GetNumStationModules(station64, false, false))
  if n == 0 then return nil end
  local moduleBuf = ffi.new("UniverseID[?]", n)
  n = tonumber(C.GetStationModules(moduleBuf, n, station64, false, false))

  -- Station-level ware sets
  local products, pureresources, intermediatewares =
    GetComponentData(station64, "availableproducts", "pureresources", "intermediatewares")
  products          = products          or {}
  pureresources     = pureresources     or {}
  intermediatewares = intermediatewares or {}

  -- Must have products or intermediates to qualify as a production station
  if #products == 0 and #intermediatewares == 0 then
    trace("Station " .. tostring(component) .. " skipped (no products/intermediates)")
    return nil
  end

  local productSet, intermediateSet = {}, {}
  for _, w in ipairs(products)          do productSet[w]      = true end
  for _, w in ipairs(intermediatewares) do intermediateSet[w] = true end

  local hasAnyModule = false
  -- Track unique module *types* (identified by sorted output-ware key) per stage+state.
  -- Two modules that produce the same ware(s) are the same type.
  local types = {
    intermediate = { noResources = {}, waitStorage = {} },
    production   = { noResources = {}, waitStorage = {} },
  }
  -- Per-ware module counts, reused by collectProductionWares to avoid a second module scan.
  local moduleCounts = {}
  -- Input wares consumed by production modules (used to classify products vs intermediates).
  local resourceWares = {}

  for i = 0, n - 1 do
    local mod = ConvertStringTo64Bit(tostring(moduleBuf[i]))
    if IsValidComponent(mod) and not C.IsComponentWrecked(mod) then
      if C.IsRealComponentClass(mod, "production")
          or C.IsRealComponentClass(mod, "processingmodule") then
        hasAnyModule = true
        local proddata = GetProductionModuleData(mod)
        local state = proddata and proddata.state
        -- Accumulate per-ware module counts
        if proddata and proddata.products then
          for _, entry in ipairs(proddata.products) do
            local w = entry.ware
            if not moduleCounts[w] then
              moduleCounts[w] = { total = 0, noRes = 0, waitStore = 0 }
            end
            moduleCounts[w].total = moduleCounts[w].total + 1
            if state == "waitingforresources" then
              moduleCounts[w].noRes = moduleCounts[w].noRes + 1
            elseif state == "waitingforstorage" or state == "choosingitem" then
              moduleCounts[w].waitStore = moduleCounts[w].waitStore + 1
            end
          end
        end
        -- Accumulate resource (input) wares from static macro data (same source as SPO)
        -- so classification is state-independent (proddata.resources is empty when idle).
        local macro = GetComponentData(mod, "macro")
        if macro then
          local mData = GetLibraryEntry(GetMacroData(macro, "infolibrary"), macro)
          if mData and mData.products then
            for _, pEntry in ipairs(mData.products) do
              for _, res in ipairs(pEntry.resources or {}) do
                resourceWares[res.ware] = true
              end
            end
          end
        end
        if state and state ~= "empty" and state ~= "producing" then

          -- Classify module stage by what it produces
          local stage = "production"  -- default: treat as final stage
          local mprods = proddata.products  or {}

          local producesFinal = false
          for _, entry in ipairs(mprods) do
            if productSet[entry.ware] then
              producesFinal = true
              break
            end
          end

          if not producesFinal then
            stage = "intermediate"
          end

          -- Build a stable type key from sorted output wares
          local plist = {}
          for _, entry in ipairs(mprods) do plist[#plist + 1] = entry.ware end
          table.sort(plist)
          local typeKey = #plist > 0 and table.concat(plist, "|") or ("__mod_" .. tostring(mod))

          if state == "waitingforstorage" or state == "choosingitem" then
            types[stage].waitStorage[typeKey] = true
          elseif state == "waitingforresources" then
            types[stage].noResources[typeKey] = true
          end
        end
      end
    end
  end

  if not hasAnyModule then return nil end

  -- Convert type-sets to counts
  local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
  end

  local counts = {
    intermediate = { noResources = countKeys(types.intermediate.noResources), waitStorage = countKeys(types.intermediate.waitStorage) },
    production   = { noResources = countKeys(types.production.noResources),   waitStorage = countKeys(types.production.waitStorage)   },
  }

  local hasIssue = (
    counts.intermediate.noResources > 0 or
    counts.intermediate.waitStorage > 0 or
    counts.production.noResources   > 0 or
    counts.production.waitStorage   > 0
  )

  -- Mouseover text: grouped by section with a coloured header per section.
  -- State IDs: {1001,8431}=Modules without resources, {1001,8432}=Modules waiting for storage
  local warnColor  = Helper.convertColorToText(Color["text_warning"])
  local errColor   = Helper.convertColorToText(Color["text_error"])
  local resetColor = "\027X"
  local parts = {}
  local function addSection(titleId, noResCount, waitStoreCount)
    local lines = {}
    if noResCount > 0 then
      lines[#lines + 1] = "  " .. errColor .. ReadText(1001, 8431) .. " (" .. noResCount .. ")" .. resetColor
    end
    if waitStoreCount > 0 then
      lines[#lines + 1] = "  " .. errColor .. ReadText(1001, 8432) .. " (" .. waitStoreCount .. ")" .. resetColor
    end
    if #lines > 0 then
      parts[#parts + 1] = warnColor .. ReadText(1001, titleId) .. ":" .. resetColor
                       .. "\n" .. table.concat(lines, "\n")
    end
  end

  addSection(6100, counts.intermediate.noResources, counts.intermediate.waitStorage)
  addSection(1610, counts.production.noResources,   counts.production.waitStorage)

  local result = {
    hasIssue      = hasIssue,
    text          = table.concat(parts, "\n"),
    moduleCounts  = moduleCounts,
    resourceWares = resourceWares,
    counts        = counts,
  }
  pst.dataCache[cacheKey] = { stationData = result, turnCounter = 1 }
  return result
end

-- *** tab registration ***

function pst.setupTab()
  local menu = pst.menuMap
  if menu == nil then
    debug("menu map not initialised")
    return
  end
  local cfg = pst.menuMapConfig
  local categories = cfg and cfg.propertyCategories or nil
  if categories == nil then
    debug("propertyCategories not found in menu map config")
    return
  end

  -- Insert after "stations" tab (between stations and fleets).
  -- Fall back to inserting after the last non-custom_tab entry if "stations" is not found.
  local insertAfter = nil
  local fallbackIdx = nil
  for i, cat in ipairs(categories) do
    trace("Checking category: " .. tostring(cat.category))
    if cat.category == MODE then
      trace("Tab already registered")
      return
    end
    if cat.category == "stations" then
      insertAfter = i
    end
    if string.sub(cat.category, 1, 10) ~= "custom_tab" then
      fallbackIdx = i
    end
  end

  local idx = insertAfter or fallbackIdx
  if idx then
    local newTab = {
      category = MODE,
      name     = ReadText(PAGE_ID, 1),
      icon     = TAB_ICON,
    }
    table.insert(categories, idx + 1, newTab)
  end
end

-- *** data preparation callbacks ***

--- Fired by kuertee UI Extensions for every player object inside the
--- createPropertyOwned loop (already sorted by the vanilla sorter).
--- Appends one entry to productionStationData for each production station.
function pst.onEveryPlayerObject(infoTableData, entry, propertyMode)
  if propertyMode ~= MODE then return end
  if not Helper.isComponentClass(entry.realclassid, "station") then return end
  if infoTableData.productionStationData == nil then
    infoTableData.productionStationData = {}
  end
  local stationData = getProductionStationData(entry.id)
  if stationData ~= nil then
    stationData.id = entry.id
    table.insert(infoTableData.productionStationData, stationData)
  end
end

function pst.prepareTabData(infoTableData)
  if infoTableData == nil then
    debug("infoTableData is nil")
    return
  end

  -- Guard: not the right tab.
  if pst.menuMap.propertyMode ~= MODE then
    trace("Not in production stations tab, skipping data preparation")
    return
  end

  -- Guard: already prepared this frame.
  if infoTableData.productionStationData ~= nil then
    trace("productionStationData already prepared")
    return
  end

  infoTableData.productionStationData = {}

  local n = tonumber(C.GetNumAllFactionStations("player"))
  if n == 0 then
    trace("No player faction stations found")
    return
  end
  local buf = ffi.new("UniverseID[?]", n)
  n = tonumber(C.GetAllFactionStations(buf, n, "player"))

  local entries = {}
  for i = 0, n - 1 do
    local object = ConvertStringToLuaID(tostring(buf[i]))
    local object64 = ConvertIDTo64Bit(object)
    local name, hull, purpose, uirelation, sector, classid, realclassid, idcode, fleetname =
      GetComponentData(object, "name", "hullpercent", "primarypurpose", "uirelation", "sector", "classid", "realclassid", "idcode", "fleetname")
    if pst.menuMap.isObjectValid(object64, classid, realclassid) then
      table.insert(entries, { id = object, name = name, fleetname = fleetname, objectid = idcode,
                               classid = classid, realclassid = realclassid, hull = hull,
                               purpose = purpose, relation = uirelation, sector = sector })
    end
  end

  table.sort(entries, pst.menuMap.componentSorter(pst.menuMap.propertySorterType))

  for _, entry in ipairs(entries) do
    local stationData = getProductionStationData(entry.id)
    if stationData ~= nil then
      stationData.id = entry.id
      table.insert(infoTableData.productionStationData, stationData)
    end
  end

  trace("Prepared " .. tostring(#infoTableData.productionStationData) .. " production stations")
end

-- *** production overview helpers ***

local function fmt(n)
  return ConvertIntegerString(Helper.round(n), true, 0, true, false)
end

--- Compute the effective hasIssue flag and mouseover text from raw stage counts,
--- respecting pst.ignoreNoResources / pst.ignoreWaitStore at render time.
local function computeStationIssue(counts)
  local warnColor  = Helper.convertColorToText(Color["text_warning"])
  local errColor   = Helper.convertColorToText(Color["text_error"])
  local resetColor = "\027X"
  local hasIssue   = false
  local parts      = {}
  local function addSection(titleId, noResCount, waitStoreCount)
    local lines = {}
    if noResCount > 0 and not pst.ignoreNoResources then
      hasIssue = true
      lines[#lines + 1] = "  " .. errColor .. ReadText(1001, 8431) .. " (" .. noResCount .. ")" .. resetColor
    end
    if waitStoreCount > 0 and not pst.ignoreWaitStore then
      hasIssue = true
      lines[#lines + 1] = "  " .. errColor .. ReadText(1001, 8432) .. " (" .. waitStoreCount .. ")" .. resetColor
    end
    if #lines > 0 then
      parts[#parts + 1] = warnColor .. ReadText(1001, titleId) .. ":" .. resetColor
                       .. "\n" .. table.concat(lines, "\n")
    end
  end
  addSection(6100, counts.intermediate.noResources, counts.intermediate.waitStorage)
  addSection(1610, counts.production.noResources,   counts.production.waitStorage)
  return hasIssue, table.concat(parts, "\n")
end

local function formatProductionTotal(v)
  if Helper.round(v) == 0 then
    return fmt(v)
  elseif v > 0 then
    return ColorText["text_positive"] .. "+" .. fmt(v)
  else
    return ColorText["text_negative"] .. "-" .. fmt(math.abs(v))
  end
end

--- Collect live per-ware production/consumption using station-level ware lists.
--- Returns { products, intermediates, resources } where each is a sorted list of
--- { name, icon, prod, cons, total, moduleTotal, moduleActive } entries; or nil if no production wares found.
--- Classification mirrors SPO: produced wares that are also resource inputs become Intermediates;
--- produced wares that are not resource inputs become Products; input-only wares become Resources.
local function collectProductionWares(station64, moduleCounts, resourceWares)
  moduleCounts  = moduleCounts  or {}
  resourceWares = resourceWares or {}

  -- Fallback to engine lists when no module scan data is available.
  if next(moduleCounts) == nil then
    local productWares, pureresources, intermediateWares =
      GetComponentData(station64, "availableproducts", "pureresources", "intermediatewares")
    productWares      = productWares      or {}
    pureresources     = pureresources     or {}
    intermediateWares = intermediateWares or {}
    for _, w in ipairs(productWares)      do moduleCounts[w]  = { total = 0, noRes = 0, waitStore = 0 } end
    for _, w in ipairs(intermediateWares) do moduleCounts[w]  = { total = 0, noRes = 0, waitStore = 0 } end
    for _, w in ipairs(pureresources)     do resourceWares[w] = true end
    for _, w in ipairs(intermediateWares) do resourceWares[w] = true end
  end

  if next(moduleCounts) == nil and next(resourceWares) == nil then return nil end

  local function makeEntry(ware)
    local wareName, wareIcon = GetWareData(ware, "name", "icon")
    local prod    = math.max(0, C.GetContainerWareProduction(station64, ware, false))
    local prodMax = math.max(0, C.GetContainerWareProduction(station64, ware, true))
    local cons    = math.max(0, C.GetContainerWareConsumption(station64, ware, false))
    local mc      = moduleCounts[ware] or { total = 0, noRes = 0, waitStore = 0 }
    local mTotal  = mc.total
    local mActive = 0
    if mTotal > 0 and prodMax > 0 then
      mActive = math.min(mTotal, Helper.round(prod / prodMax * mTotal))
    end
    return {
      name         = wareName or ware,
      icon         = (wareIcon and wareIcon ~= "") and wareIcon or "solid",
      prod         = Helper.round(prod),
      cons         = Helper.round(cons),
      total        = Helper.round(prod - cons),
      moduleTotal  = mTotal,
      moduleActive = mActive,
      noRes        = mc.noRes,
      waitStore    = mc.waitStore,
    }
  end

  local products = {}
  local intermediates = {}
  local resources = {}

  for ware, _ in pairs(moduleCounts) do
    if resourceWares[ware] then
      table.insert(intermediates, makeEntry(ware))
    else
      table.insert(products, makeEntry(ware))
    end
  end
  table.sort(products,     function(a, b) return a.name < b.name end)
  table.sort(intermediates, function(a, b) return a.name < b.name end)

  for ware, _ in pairs(resourceWares) do
    if not moduleCounts[ware] then
      local cons = math.max(0, C.GetContainerWareConsumption(station64, ware, false))
      local rName, rIcon = GetWareData(ware, "name", "icon")
      table.insert(resources, {
        name         = rName or ware,
        icon         = (rIcon and rIcon ~= "") and rIcon or "solid",
        prod         = 0,
        cons         = Helper.round(cons),
        total        = -Helper.round(cons),
        moduleTotal  = 0,
        moduleActive = 0,
        noRes        = 0,
        waitStore    = 0,
      })
    end
  end
  table.sort(resources, function(a, b) return a.name < b.name end)

  if #products == 0 and #intermediates == 0 and #resources == 0 then return nil end
  return { products = products, intermediates = intermediates, resources = resources }
end

-- *** custom station row ***

--- Creates a compact three-line row for a production station.
---
--- Column layout (total = 5 + maxIcons):
---   col 1                    : +/- expand button (subordinates / modules)
---   col 2, span maxIcons-2    : name \n sector (issue details in mouseover)
---   col maxIcons,   span 2    : Station Configuration button (mapst_plotmanagement)
---   col maxIcons+2, span 2    : Logical Station Overview button (stationbuildst_lsov)
---   col maxIcons+4, span 2    : Transaction Log button (pi_transactionlog)
---
--- Expansion of subordinates, module lists, and docked ships is fully handled
--- here (mirrors vanilla createPropertyRow logic).
local function createStationRow(instance, ftable, tblOrGroup, stationId, stationData, hasSPO, numdisplayed)
  local menu    = pst.menuMap
  local maxIcons = menu.infoTableData[instance].maxIcons
  local key     = tostring(stationId)
  local comp64  = ConvertIDTo64Bit(stationId)

  local subordinates  = menu.infoTableData[instance].subordinates[key]   or {}
  local dockedShips   = menu.infoTableData[instance].dockedships[key]    or {}
  local constructions = menu.infoTableData[instance].constructions[key]  or {}

  -- Auto-expand commanders / construction contexts (mirrors vanilla)
  if not menu.isPropertyExtended(key) then
    if menu.isCommander(comp64, 0) or menu.isConstructionContext(comp64) then
      menu.extendedproperty[key] = true
    end
  end

  -- Are there real (non-fleet-unit) subordinates?
  local subordinateFound = false
  for _, sub in ipairs(subordinates) do
    if (sub.component and menu.infoTableData[instance].fleetUnitSubordinates[tostring(sub.component)] ~= true)
        or sub.fleetunit then
      subordinateFound = true
      break
    end
  end

  local isconstruction    = IsComponentConstruction(stationId)
  local isStationExpandable = not isconstruction
  if isconstruction then
    isStationExpandable = C.GetNumStationModules(comp64, true, false) > 0
  end
  local isExpandable = isStationExpandable
                    or (subordinates.hasRendered and subordinateFound)
                    or (#dockedShips > 0)
                    or (#constructions > 0)

  numdisplayed = numdisplayed + 1

  -- Name / colour / sector
  local name, color, bgColor, font, mouseover, factionColor =
    menu.getContainerNameAndColors(stationId, 0, true, false, true)
  local sectorId, locationText = GetComponentData(stationId, "sectorid", "sector")

  -- "covered" indicator (mirrors vanilla alertString)
  local isPlayerOwned = GetComponentData(stationId, "isplayerowned")

  local hasIssue, issueText = false, ""
  if stationData then
    if stationData.counts then
      hasIssue, issueText = computeStationIssue(stationData.counts)
    else
      hasIssue  = stationData.hasIssue or false
      issueText = stationData.text     or ""
    end
  end

  -- Issue text goes into the mouseover, appended after any vanilla mouseover text
  local issueMouseover = mouseover
  if issueText ~= "" then
    if issueMouseover ~= "" then
      issueMouseover = issueMouseover .. "\n\n"
    end
    issueMouseover = issueMouseover .. issueText
  end

  -- When station has issues: tint only the embedded icon in the name with warning colour
  local displayName = name
  if hasIssue then
    local warningColorText  = Helper.convertColorToText(Color["text_warning"])
    local originalColorText = Helper.convertColorToText(color)
    displayName = name:gsub("(\027%[[^%]]+%])", warningColorText .. "%1\027X" .. originalColorText, 1)
  end

  local displayText = Helper.convertColorToText(color) .. displayName .. "\027X"
                   .. "\n" .. (locationText or "")

  -- Main row
  local row = tblOrGroup:addRow({"property", stationId, nil, 0}, {
    bgColor       = bgColor,
    multiSelected = menu.isSelectedComponent(stationId),
  })
  if menu.isSelectedComponent(stationId) then
    menu.setrow = row.index
  end
  if IsSameComponent(stationId, menu.highlightedbordercomponent) then
    menu.sethighlightborderrow = row.index
  end

  -- Col 1: +/- expand button
  if isExpandable then
    row[1]:createButton({ scaling = false })
          :setText(menu.isPropertyExtended(key) and "-" or "+", { scaling = true, halign = "center" })
    row[1].handlers.onClick = function() return menu.buttonExtendProperty(key) end
  end

  -- Col 2: two-line text (name / sector), issue details in mouseover
  row[2]:setColSpan(maxIcons - 2):createText(displayText, { font = font, mouseOverText = issueMouseover })

  -- Sync expand-button height to text height
  local rowHeight = row[2]:getMinTextHeight(true)
  if row[1].type == "button" then
    row[1].properties.height = rowHeight
  end

  -- Col (maxicons), span 2: Station Configuration button
  local cfgCell = row[maxIcons]
  cfgCell:setColSpan(2)
  local cellWidth = cfgCell:getWidth()
  local iconSize  = math.min(cellWidth, rowHeight)
  local iconX     = (cellWidth  - iconSize) / 2
  local iconY     = (rowHeight  - iconSize) / 2
  cfgCell:createButton({ mouseOverText = ReadText(1001, 7902), scaling = false, active = isPlayerOwned })
         :setIcon("mapst_plotmanagement", { scaling = false, width = iconSize, height = iconSize, x = iconX, y = iconY })
  cfgCell.handlers.onClick = function()
    Helper.closeMenuAndOpenNewMenu(pst.menuMap, "StationConfigurationMenu", { 0, 0, comp64 })
    pst.menuMap.cleanup()
  end
  cfgCell.properties.height = rowHeight

  -- Col (maxicons+2), span 2: Logical Station Overview button
  local lsoCell = row[maxIcons + 2]
  lsoCell:setColSpan(2)
  lsoCell:createButton({ mouseOverText = ReadText(1001, 7903), scaling = false })
         :setIcon("stationbuildst_lsov", { scaling = false, width = iconSize, height = iconSize, x = iconX, y = iconY, color = hasIssue and Color["text_warning"] or nil })
  lsoCell.handlers.onClick = function()
    Helper.closeMenuAndOpenNewMenu(pst.menuMap, "StationOverviewMenu", { 0, 0, comp64 })
    pst.menuMap.cleanup()
  end
  lsoCell.properties.height = rowHeight

  -- Col (maxicons+4), span 2: Transaction Log button
  local txCell = row[maxIcons + 4]
  txCell:setColSpan(2)
  txCell:createButton({ mouseOverText = ReadText(1001, 7702), scaling = false, active = isPlayerOwned })
        :setIcon("pi_transactionlog", { scaling = false, width = iconSize, height = iconSize, x = iconX, y = iconY })
  txCell.handlers.onClick = function()
    Helper.closeMenuAndOpenNewMenu(pst.menuMap, "TransactionLogMenu", { 0, 0, comp64 })
    pst.menuMap.cleanup()
  end
  txCell.properties.height = rowHeight

  -- *** Expansion ***
  if menu.isPropertyExtended(key) then
    -- Production Overview sub-section (expandable, before module list)
    local poExpanded = pst.prodOverviewExpanded[key] or false
    local poRow = tblOrGroup:addRow(true, {})
    poRow[1]:createButton():setText(poExpanded and "-" or "+", { halign = "center" })
    poRow[1].handlers.onClick = function()
      pst.prodOverviewExpanded[key] = not (pst.prodOverviewExpanded[key] or false)
      menu.noupdate = true
      menu.refreshInfoFrame()
    end
    if hasSPO then
      poRow[2]:setColSpan(2 + maxIcons):createText(ReadText(PAGE_ID, 200))
      local poRowH   = poRow[2]:getMinTextHeight(true)
      local spoCell  = poRow[maxIcons + 4]
      spoCell:setColSpan(2)
      local spoCellW  = spoCell:getWidth()
      local spoIconSz = math.min(spoCellW, poRowH)
      local spoIconX  = (spoCellW  - spoIconSz) / 2
      local spoIconY  = (poRowH    - spoIconSz) / 2
      spoCell:createButton({ mouseOverText = ReadText(1972092416, 2), scaling = false })
             :setIcon(TAB_ICON, { scaling = false, width = spoIconSz, height = spoIconSz, x = spoIconX, y = spoIconY })
      spoCell.handlers.onClick = function()
        menu.infoSubmenuObject = comp64
        menu.infoMode["right"] = SPO_CATEGORY
        if menu.searchTableMode == "info" then
          menu.refreshInfoFrame2()
        else
          menu.buttonToggleRightBar("info")
        end
      end
      spoCell.properties.height = poRowH
    else
      poRow[2]:setColSpan(4 + maxIcons):createText(ReadText(PAGE_ID, 200))
    end

    if poExpanded then
      local wareData = collectProductionWares(comp64, stationData and stationData.moduleCounts, stationData and stationData.resourceWares)
      if wareData then
        -- Column headers: col 1-2 (span 2) = Ware, col 3 = Produced, col 4 = Consumed, col 5+ span = Total
        local chRow = tblOrGroup:addRow(true, Helper.headerRowProperties)
        chRow[1]:setColSpan(2):createText(ReadText(PAGE_ID, 110), Helper.headerRowCenteredProperties)
        chRow[3]:createText(ReadText(PAGE_ID, 112), Helper.headerRowCenteredProperties)
        chRow[4]:createText(ReadText(PAGE_ID, 113), Helper.headerRowCenteredProperties)
        chRow[5]:setColSpan(1 + maxIcons):createText(ReadText(PAGE_ID, 114), Helper.headerRowCenteredProperties)

        local function renderProdGroup(entries, label)
          if #entries == 0 then return end
          local gRow = tblOrGroup:addRow(true, Helper.headerRowProperties)
          gRow[1]:setColSpan(5 + maxIcons):createText(label, Helper.headerRowCenteredProperties)
          local wareIconSize = menu.getShipIconWidth()
          for _, entry in ipairs(entries) do
            local dr = tblOrGroup:addRow(true, { bgColor = Color["row_background_unselectable"] })
            local countStr = ""
            if entry.moduleTotal > 0 then
              if entry.moduleActive < entry.moduleTotal then
                countStr = tostring(entry.moduleActive) .. "/" .. tostring(entry.moduleTotal)
              else
                countStr = tostring(entry.moduleTotal)
              end
            end
            -- Build issue colour and mouseover for the ware cell
            local wareHasIssue = (entry.noRes > 0 and not pst.ignoreNoResources) or
                                  (entry.waitStore > 0 and not pst.ignoreWaitStore)
            local wareName = wareHasIssue
              and (Helper.convertColorToText(Color["text_warning"]) .. entry.name .. "\027X")
              or entry.name
            local wareMouseover = ""
            if wareHasIssue then
              local errColor   = Helper.convertColorToText(Color["text_error"])
              local resetColor = "\027X"
              local lines = {}
              if entry.noRes > 0 and not pst.ignoreNoResources then
                lines[#lines + 1] = errColor .. ReadText(1001, 8431) .. " (" .. entry.noRes .. ")" .. resetColor
              end
              if entry.waitStore > 0 and not pst.ignoreWaitStore then
                lines[#lines + 1] = errColor .. ReadText(1001, 8432) .. " (" .. entry.waitStore .. ")" .. resetColor
              end
              wareMouseover = table.concat(lines, "\n")
            end
            dr[1]:setColSpan(2):createIcon(entry.icon, { scaling = false, width = wareIconSize, height = wareIconSize, mouseOverText = wareMouseover })
                :setText(wareName, { halign = "left", x = wareIconSize + Helper.standardTextOffsetx, fontsize = pst.mapFontSize })
                :setText2(countStr, { halign = "right", fontsize = pst.mapFontSize })
            dr[3]:createText(entry.prod > 0 and fmt(entry.prod) or "--", { halign = "right" })
            dr[4]:createText(entry.cons > 0 and fmt(entry.cons) or "--", { halign = "right" })
            dr[5]:setColSpan(1 + maxIcons):createText(formatProductionTotal(entry.total), { halign = "right" })
          end
        end

        renderProdGroup(wareData.products,      ReadText(PAGE_ID, 120))
        renderProdGroup(wareData.intermediates, ReadText(PAGE_ID, 121))
        renderProdGroup(wareData.resources,     ReadText(PAGE_ID, 122))
      end
    end

    -- Module list (station builds / constructions)
    if isStationExpandable then
      if pst.isV9 then
        menu.createModuleSection(instance, ftable, tblOrGroup, stationId, 0)
      else
        menu.createModuleSection(instance, ftable, stationId, 0)
      end
    end

    -- Subordinate ships
    if subordinates.hasRendered and subordinateFound then
      if pst.isV9 then
        numdisplayed = menu.createSubordinateSection(
          instance, ftable, tblOrGroup, stationId,
          false, true, 0, sectorId,
          numdisplayed, menu.propertySorterType,
          true, false)
      else
        numdisplayed = menu.createSubordinateSection(
          instance, ftable, stationId,
          false, true, 0, sectorId,
          numdisplayed, menu.propertySorterType,
          true, false)
      end
    end

    -- Docked ships header + expansion
    if #dockedShips > 0 then
      local isDockedExt = menu.isDockedShipsExtended(key, true)
      if not isDockedExt and menu.isDockContext(comp64) then
        if menu.infoTableMode ~= "propertyowned" then
          menu.extendeddockedships[key] = true
          isDockedExt = true
        end
      end

      local dRow = tblOrGroup:addRow({"dockedships", stationId}, {})
      dRow[1]:createButton():setText(isDockedExt and "-" or "+", { halign = "center" })
      dRow[1].handlers.onClick = function() return menu.buttonExtendDockedShips(key, true) end
      dRow[2]:setColSpan(3):createText(ReadText(1001, 3265))

      -- Count player-owned docked ships
      local nPlayerDocked = 0
      for _, ds in ipairs(dockedShips) do
        if GetComponentData(ds.component, "isplayerowned") then
          nPlayerDocked = nPlayerDocked + 1
        end
      end
      if nPlayerDocked > 0 then
        dRow[5]:setColSpan(1 + maxIcons)
               :createText("\027[order_dockat] " .. nPlayerDocked,
                           { halign = "right", color = menu.holomapcolor.playercolor })
      end

      if isDockedExt then
        dockedShips = menu.sortComponentListHelper(dockedShips, menu.propertySorterType)
        for _, ds in ipairs(dockedShips) do
          if pst.isV9 then
            numdisplayed = menu.createPropertyRow(instance, ftable, tblOrGroup,
              ds.component, 2, sectorId, nil, true, numdisplayed, menu.propertySorterType)
          else
            numdisplayed = menu.createPropertyRow(instance, ftable,
              ds.component, 2, sectorId, nil, true, numdisplayed, menu.propertySorterType)
          end
        end
      end
    end
  end

  return numdisplayed
end

-- *** display callback ***

function pst.displayTabData(numDisplayed, instance, ftable, infoTableData)
  local menu = pst.menuMap
  if menu == nil then
    debug("menu map not initialised")
    return { numdisplayed = numDisplayed }
  end

  if menu.propertyMode ~= MODE then
    return { numdisplayed = numDisplayed }
  end

  -- Detect once whether the SPO info tab is registered; cache result in pst.hasSPO.
  if pst.hasSPO == nil then
    pst.hasSPO = false
    local cats = pst.menuMapConfig.infoCategories
    if cats then
      for _, cat in ipairs(cats) do
        if cat.category == SPO_CATEGORY then
          pst.hasSPO = true
          break
        end
      end
    end
  end

  local stationData = infoTableData.productionStationData or {}
  local maxIcons    = menu.infoTableData[instance].maxIcons or 5

  -- Section header row.
  local headerRow = ftable:addRow(false, Helper.headerRowProperties)
  headerRow[1]:setColSpan(5 + maxIcons)
              :createText(ReadText(PAGE_ID, 1), Helper.headerRowCenteredProperties)

  -- RowGroup (9.00+ only).
  local tblOrGroup = ftable
  if pst.isV9 then
    tblOrGroup = ftable:addRowGroup({})
  end

  local prevDisplayed = numDisplayed

  for _, entry in ipairs(stationData) do
    numDisplayed = createStationRow(instance, ftable, tblOrGroup, entry.id,
                                    entry, pst.hasSPO, numDisplayed)
  end

  -- Empty section placeholder.
  if numDisplayed == prevDisplayed then
    local emptyRow = tblOrGroup:addRow(MODE, { interactive = false })
    emptyRow[2]:setColSpan(4 + maxIcons):createText(ReadText(PAGE_ID, 1000))
  end

  return { numdisplayed = numDisplayed }
end

-- *** init ***

function pst.Init(menuMap)
  trace("pst.Init called")
  pst.menuMap      = menuMap
  pst.menuMapConfig = menuMap.uix_getConfig()
  pst.mapFontSize   = Helper.scaleFont(Helper.standardFont, pst.menuMapConfig.mapFontSize)

  -- Options: read initial config and register for live updates via MD event.
  pst.playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
  RegisterEvent("PST.ConfigChanged", pstOnConfigChanged)
  pstOnConfigChanged()

  menuMap.registerCallback("createPropertyOwned_on_every_playerobject", pst.onEveryPlayerObject)
  menuMap.registerCallback("createPropertyOwned_on_add_other_objects_infoTableData", pst.prepareTabData)
  menuMap.registerCallback("createPropertyOwned_on_createPropertySection_unassignedships", pst.displayTabData)

  pst.setupTab()
end

local function Init()
  debug("Initialising Production Stations Tab")

  local menuMap = Helper.getMenu("MapMenu")
  if menuMap == nil or type(menuMap.registerCallback) ~= "function" then
    debug("Failed to get MapMenu - kuertee UI Extensions not loaded?")
    return
  end

  pst.Init(menuMap)
end

Register_OnLoad_Init(Init)
