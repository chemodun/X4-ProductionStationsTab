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

local MODE    = "productionStations"
local TAB_ICON = "stationbuildst_production"

-- *** module table ***

local pst = {
  menuMap              = nil,
  menuMapConfig        = {},
  prodOverviewExpanded = {},
  isV9                 = C.GetGameVersion().major >= 9,
  mapFontSize          = Helper.standardFontSize,
}

-- *** debug helpers ***

local debugLevel = "none"  -- "none" | "debug" | "trace"

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

  return {
    hasIssue     = hasIssue,
    text         = table.concat(parts, "\n"),
    moduleCounts = moduleCounts,
  }
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

-- *** data preparation callback ***

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
local function collectProductionWares(station64, moduleCounts)
  local productWares, pureresources, intermediateWares =
    GetComponentData(station64, "availableproducts", "pureresources", "intermediatewares")
  productWares      = productWares      or {}
  pureresources     = pureresources     or {}
  intermediateWares = intermediateWares or {}

  if #productWares == 0 and #intermediateWares == 0 then return nil end

  moduleCounts = moduleCounts or {}

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
  for _, w in ipairs(productWares) do
    table.insert(products, makeEntry(w))
  end
  table.sort(products, function(a, b) return a.name < b.name end)

  local intermediates = {}
  for _, w in ipairs(intermediateWares) do
    table.insert(intermediates, makeEntry(w))
  end
  table.sort(intermediates, function(a, b) return a.name < b.name end)

  local resources = {}
  for _, w in ipairs(pureresources) do
    local consMax = math.max(0, C.GetContainerWareConsumption(station64, w, true))
    if Helper.round(consMax) > 0 then
      local cons = math.max(0, C.GetContainerWareConsumption(station64, w, false))
      local rName, rIcon = GetWareData(w, "name", "icon")
      table.insert(resources, {
        name         = rName or w,
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
local function createStationRow(instance, ftable, tblOrGroup, component, issues, numdisplayed)
  local menu    = pst.menuMap
  local maxicons = menu.infoTableData[instance].maxIcons
  local key     = tostring(component)
  local comp64  = ConvertIDTo64Bit(component)

  local subordinates  = menu.infoTableData[instance].subordinates[key]   or {}
  local dockedships   = menu.infoTableData[instance].dockedships[key]    or {}
  local constructions = menu.infoTableData[instance].constructions[key]  or {}

  -- Auto-expand commanders / construction contexts (mirrors vanilla)
  if not menu.isPropertyExtended(key) then
    if menu.isCommander(comp64, 0) or menu.isConstructionContext(comp64) then
      menu.extendedproperty[key] = true
    end
  end

  -- Are there real (non-fleet-unit) subordinates?
  local subordinatefound = false
  for _, sub in ipairs(subordinates) do
    if (sub.component and menu.infoTableData[instance].fleetUnitSubordinates[tostring(sub.component)] ~= true)
        or sub.fleetunit then
      subordinatefound = true
      break
    end
  end

  local isconstruction    = IsComponentConstruction(component)
  local isstationexpandable = not isconstruction
  if isconstruction then
    isstationexpandable = C.GetNumStationModules(comp64, true, false) > 0
  end
  local isexpandable = isstationexpandable
                    or (subordinates.hasRendered and subordinatefound)
                    or (#dockedships > 0)
                    or (#constructions > 0)

  numdisplayed = numdisplayed + 1

  -- Name / colour / sector
  local name, color, bgcolor, font, mouseover, factioncolor =
    menu.getContainerNameAndColors(component, 0, true, false, true)
  local sectorid, locationtext = GetComponentData(component, "sectorid", "sector")

  -- "covered" indicator (mirrors vanilla alertString)
  local isplayerowned = GetComponentData(component, "isplayerowned")

  local hasIssue = issues and issues.hasIssue

  -- Issue text goes into the mouseover, appended after any vanilla mouseover text
  local issueMouseover = mouseover
  if issues.text and issues.text ~= "" then
    if issueMouseover ~= "" then
      issueMouseover = issueMouseover .. "\n\n"
    end
    issueMouseover = issueMouseover .. issues.text
  end

  -- When station has issues: tint only the embedded icon in the name with warning colour
  local displayName = name
  if hasIssue then
    local warningColorText  = Helper.convertColorToText(Color["text_warning"])
    local originalColorText = Helper.convertColorToText(color)
    displayName = name:gsub("(\027%[[^%]]+%])", warningColorText .. "%1\027X" .. originalColorText, 1)
  end

  local displayText = Helper.convertColorToText(color) .. displayName .. "\027X"
                   .. "\n" .. (locationtext or "")

  -- Main row
  local row = tblOrGroup:addRow({"property", component, nil, 0}, {
    bgColor       = bgcolor,
    multiSelected = menu.isSelectedComponent(component),
  })
  if menu.isSelectedComponent(component) then
    menu.setrow = row.index
  end
  if IsSameComponent(component, menu.highlightedbordercomponent) then
    menu.sethighlightborderrow = row.index
  end

  -- Col 1: +/- expand button
  if isexpandable then
    row[1]:createButton({ scaling = false })
          :setText(menu.isPropertyExtended(key) and "-" or "+", { scaling = true, halign = "center" })
    row[1].handlers.onClick = function() return menu.buttonExtendProperty(key) end
  end

  -- Col 2: two-line text (name / sector), issue details in mouseover
  row[2]:setColSpan(maxicons - 2):createText(displayText, { font = font, mouseOverText = issueMouseover })

  -- Sync expand-button height to text height
  local rowHeight = row[2]:getMinTextHeight(true)
  if row[1].type == "button" then
    row[1].properties.height = rowHeight
  end

  -- Col (maxicons), span 2: Station Configuration button
  local cfgCell = row[maxicons]
  cfgCell:setColSpan(2)
  local cellWidth = cfgCell:getWidth()
  local iconSize  = math.min(cellWidth, rowHeight)
  local iconX     = (cellWidth  - iconSize) / 2
  local iconY     = (rowHeight  - iconSize) / 2
  cfgCell:createButton({ mouseOverText = ReadText(1001, 7902), scaling = false, active = isplayerowned })
         :setIcon("mapst_plotmanagement", { scaling = false, width = iconSize, height = iconSize, x = iconX, y = iconY })
  cfgCell.handlers.onClick = function()
    Helper.closeMenuAndOpenNewMenu(pst.menuMap, "StationConfigurationMenu", { 0, 0, comp64 })
    pst.menuMap.cleanup()
  end
  cfgCell.properties.height = rowHeight

  -- Col (maxicons+2), span 2: Logical Station Overview button
  local lsoCell = row[maxicons + 2]
  lsoCell:setColSpan(2)
  lsoCell:createButton({ mouseOverText = ReadText(1001, 7903), scaling = false })
         :setIcon("stationbuildst_lsov", { scaling = false, width = iconSize, height = iconSize, x = iconX, y = iconY, color = hasIssue and Color["text_warning"] or nil })
  lsoCell.handlers.onClick = function()
    Helper.closeMenuAndOpenNewMenu(pst.menuMap, "StationOverviewMenu", { 0, 0, comp64 })
    pst.menuMap.cleanup()
  end
  lsoCell.properties.height = rowHeight

  -- Col (maxicons+4), span 2: Transaction Log button
  local txCell = row[maxicons + 4]
  txCell:setColSpan(2)
  txCell:createButton({ mouseOverText = ReadText(1001, 7702), scaling = false, active = isplayerowned })
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
    poRow[2]:setColSpan(4 + maxicons):createText(ReadText(PAGE_ID, 200))

    if poExpanded then
      local wareData = collectProductionWares(comp64, issues and issues.moduleCounts)
      if wareData then
        -- Column headers: col 1-2 (span 2) = Ware, col 3 = Produced, col 4 = Consumed, col 5+ span = Total
        local chRow = tblOrGroup:addRow(true, Helper.headerRowProperties)
        chRow[1]:setColSpan(2):createText(ReadText(PAGE_ID, 110), Helper.headerRowCenteredProperties)
        chRow[3]:createText(ReadText(PAGE_ID, 112), Helper.headerRowCenteredProperties)
        chRow[4]:createText(ReadText(PAGE_ID, 113), Helper.headerRowCenteredProperties)
        chRow[5]:setColSpan(1 + maxicons):createText(ReadText(PAGE_ID, 114), Helper.headerRowCenteredProperties)

        local function renderProdGroup(entries, label)
          if #entries == 0 then return end
          local gRow = tblOrGroup:addRow(true, Helper.headerRowProperties)
          gRow[1]:setColSpan(5 + maxicons):createText(label, Helper.headerRowCenteredProperties)
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
            local wareHasIssue = entry.noRes > 0 or entry.waitStore > 0
            local wareName = wareHasIssue
              and (Helper.convertColorToText(Color["text_warning"]) .. entry.name .. "\027X")
              or entry.name
            local wareMouseover = ""
            if wareHasIssue then
              local errColor   = Helper.convertColorToText(Color["text_error"])
              local resetColor = "\027X"
              local lines = {}
              if entry.noRes > 0 then
                lines[#lines + 1] = errColor .. ReadText(1001, 8431) .. " (" .. entry.noRes .. ")" .. resetColor
              end
              if entry.waitStore > 0 then
                lines[#lines + 1] = errColor .. ReadText(1001, 8432) .. " (" .. entry.waitStore .. ")" .. resetColor
              end
              wareMouseover = table.concat(lines, "\n")
            end
            dr[1]:setColSpan(2):createIcon(entry.icon, { scaling = false, width = wareIconSize, height = wareIconSize, mouseOverText = wareMouseover })
                :setText(wareName, { halign = "left", x = wareIconSize + Helper.standardTextOffsetx, fontsize = pst.mapFontSize })
                :setText2(countStr, { halign = "right", fontsize = pst.mapFontSize })
            dr[3]:createText(entry.prod > 0 and fmt(entry.prod) or "--", { halign = "right" })
            dr[4]:createText(entry.cons > 0 and fmt(entry.cons) or "--", { halign = "right" })
            dr[5]:setColSpan(1 + maxicons):createText(formatProductionTotal(entry.total), { halign = "right" })
          end
        end

        renderProdGroup(wareData.products,      ReadText(PAGE_ID, 120))
        renderProdGroup(wareData.intermediates, ReadText(PAGE_ID, 121))
        renderProdGroup(wareData.resources,     ReadText(PAGE_ID, 122))
      end
    end

    -- Module list (station builds / constructions)
    if isstationexpandable then
      if pst.isV9 then
        menu.createModuleSection(instance, ftable, tblOrGroup, component, 0)
      else
        menu.createModuleSection(instance, ftable, component, 0)
      end
    end

    -- Subordinate ships
    if subordinates.hasRendered and subordinatefound then
      if pst.isV9 then
        numdisplayed = menu.createSubordinateSection(
          instance, ftable, tblOrGroup, component,
          false, true, 0, sectorid,
          numdisplayed, menu.propertySorterType,
          true, false)
      else
        numdisplayed = menu.createSubordinateSection(
          instance, ftable, component,
          false, true, 0, sectorid,
          numdisplayed, menu.propertySorterType,
          true, false)
      end
    end

    -- Docked ships header + expansion
    if #dockedships > 0 then
      local isdockedext = menu.isDockedShipsExtended(key, true)
      if not isdockedext and menu.isDockContext(comp64) then
        if menu.infoTableMode ~= "propertyowned" then
          menu.extendeddockedships[key] = true
          isdockedext = true
        end
      end

      local drow = tblOrGroup:addRow({"dockedships", component}, {})
      drow[1]:createButton():setText(isdockedext and "-" or "+", { halign = "center" })
      drow[1].handlers.onClick = function() return menu.buttonExtendDockedShips(key, true) end
      drow[2]:setColSpan(3):createText(ReadText(1001, 3265))

      -- Count player-owned docked ships
      local nplayerdocked = 0
      for _, ds in ipairs(dockedships) do
        if GetComponentData(ds.component, "isplayerowned") then
          nplayerdocked = nplayerdocked + 1
        end
      end
      if nplayerdocked > 0 then
        drow[5]:setColSpan(1 + maxicons)
               :createText("\027[order_dockat] " .. nplayerdocked,
                           { halign = "right", color = menu.holomapcolor.playercolor })
      end

      if isdockedext then
        dockedships = menu.sortComponentListHelper(dockedships, menu.propertySorterType)
        for _, ds in ipairs(dockedships) do
          if pst.isV9 then
            numdisplayed = menu.createPropertyRow(instance, ftable, tblOrGroup,
              ds.component, 2, sectorid, nil, true, numdisplayed, menu.propertySorterType)
          else
            numdisplayed = menu.createPropertyRow(instance, ftable,
              ds.component, 2, sectorid, nil, true, numdisplayed, menu.propertySorterType)
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
                                    entry, numDisplayed)
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

  menuMap.registerCallback(
    "createPropertyOwned_on_add_other_objects_infoTableData",
    pst.prepareTabData)
  menuMap.registerCallback(
    "createPropertyOwned_on_createPropertySection_unassignedships",
    pst.displayTabData)

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
