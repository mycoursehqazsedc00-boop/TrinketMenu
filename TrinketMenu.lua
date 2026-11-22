
--[[ TrinketMenu 3.5 ]]--
TrinketMenu = {}

-- Feature detection for Nampower/SuperWoW/UnitXP/ClassicAPI/VanillaHelpers
-- Runs at file load and refreshes on PLAYER_LOGIN to catch late-initializing DLLs.
function TrinketMenu.DetectMods()
	TrinketMenu.hasNampower = GetTrinketCooldown ~= nil
	TrinketMenu.hasGetTrinkets = GetTrinkets ~= nil
	TrinketMenu.hasGetItemIdCooldown = GetItemIdCooldown ~= nil
	TrinketMenu.hasNampowerVersion = GetNampowerVersion ~= nil
	TrinketMenu.hasSuperWoW = SUPERWOW_VERSION ~= nil
	TrinketMenu.hasUnitXP = pcall(UnitXP, "nop", "nop")
	-- ClassicAPI's own docs specify CLASSIC_API_VERSION as the canonical way to
	-- detect the DLL - probing individual C_* tables can miss it if a given
	-- build doesn't expose every sub-table, so we check both and report them
	-- separately (see /trinket compat).
	TrinketMenu.hasClassicAPI = (CLASSIC_API_VERSION ~= nil)
	-- NOTE: GetContainerNumSlots stays a plain global in ClassicAPI (it is not
	-- moved onto C_Container), so we only need to confirm GetContainerItemInfo
	-- exists on C_Container itself - requiring C_Container.GetContainerNumSlots
	-- here was the bug that made this read "not detected" even when ClassicAPI
	-- was loaded.
	TrinketMenu.hasClassicBag = (type(C_Container) == "table"
		and type(C_Container.GetContainerItemInfo) == "function")
	TrinketMenu.hasClassicTimer = (type(C_Timer) == "table" and type(C_Timer.After) == "function")
	-- ClassicAPI's GetItemCooldown(itemID)/C_Container.GetItemCooldown(itemID) is
	-- a direct-by-ID cooldown lookup (start,duration,enable) - the same shape
	-- GetContainerItemCooldown/GetInventoryItemCooldown already return, just
	-- addressed by item ID instead of bag/slot. This is what lets us track a
	-- trinket's cooldown without Nampower even if the trinket moves bags/slots.
	TrinketMenu.hasClassicItemCooldown = (type(C_Container) == "table" and type(C_Container.GetItemCooldown) == "function")
		or type(GetItemCooldown) == "function"
	-- VanillaHelpers is a display/model/file-IO DLL (minimap blips, character-skin
	-- morphing, WriteFile/ReadFile). It exposes no item, bag, cooldown or spell
	-- API, so there is nothing here for a trinket-swap addon to hook. Detected
	-- only so /trinket compat can report it accurately instead of pretending an
	-- integration exists.
	TrinketMenu.hasVanillaHelpers = (WriteFile ~= nil and ReadFile ~= nil)
end
TrinketMenu.DetectMods()

TrinketMenu.trace = false
function TrinketMenu.Trace(msg)
	if TrinketMenu.trace then
		DEFAULT_CHAT_FRAME:AddMessage("|cFF44AAFF[TrinketMenu Trace]|r "..tostring(msg))
	end
end

function TrinketMenu.LoadDefaults()

	TrinketMenuOptions = TrinketMenuOptions or {
		IconPos = -100,				-- angle of initial minimap icon position
		ShowIcon = "ON",			-- whether to show the minimap button
		SquareMinimap = "OFF",		-- whether the minimap is square instead of circular
		CooldownCount = "OFF",		-- whether to display numerical cooldown counters
		LargeCooldown = "ON",		-- whether cooldown numbers are large or small
		TooltipFollow = "OFF",		-- whether tooltips follow the mouse
		KeepOpen = "OFF",			-- whether menu hides after use
		KeepDocked = "ON",			-- whether to keep menu docked at all times
		Notify = "OFF",				-- whether a message appears when a trinket is ready
		DisableToggle="OFF",		-- whether minimap button toggles trinkets
		NotifyUsedOnly="OFF",		-- whether notify happens only on trinkets used
		NotifyChatAlso="OFF",		-- whether to send notify to chat also
		Locked = "OFF",				-- whether windows can be moved/scaled/rotated
		ShowTooltips = "ON",		-- whether to display tooltips at all
		NotifyThirty = "OFF",		-- whether to notify cooldowns at 30 seconds instead of 0
		MenuOnShift = "OFF",		-- whether menu requires Shift to display
		TinyTooltips = "OFF",		-- whether tooltips display only name and cooldown
		SetColumns = "OFF",			-- whether number of columns in menu is chosen automatically
		Columns = 4,				-- if SetColumns "ON", number of columns before menu wraps
		ShowHotKeys = "OFF",		-- whether hotkeys show on trinkets
		StopOnSwap = "OFF"			-- whether to stop auto queue on all manual swaps
	}

	TrinketMenuPerOptions = TrinketMenuPerOptions or {
		MainDock = "BOTTOMRIGHT",	-- corner of main window docked to
		MenuDock = "BOTTOMLEFT",	-- corner menu window is docked from
		MainOrient = "HORIZONTAL",	-- direction of main window
		MenuOrient = "VERTICAL",	-- direction of menu window
		XPos = 400,					-- left edge of main window
		YPos = 400,					-- top edge of main window
		MainScale = 1,				-- scaling of main window
		MenuScale = 1,				-- scaling of menu window
		Visible="ON",				-- whether to display the trinkets
		FirstUse = true,			-- whether this is the first time this user has used the mod
		ItemsUsed = {},				-- table of trinkets used and their cooldown status
	}
end

--[[ Misc Variables ]]--

TrinketMenu_Version = 3.5
BINDING_HEADER_TRINKETMENU = "TrinketMenu"

TrinketMenu.MaxTrinkets = 30 -- add more to TrinketMenu_MenuFrame if this changes
TrinketMenu.BaggedTrinkets = {} -- indexed by number, 1-30 of trinkets in the menu
TrinketMenu.NumberOfTrinkets = 0 -- number of trinkets in the menu
TrinketMenu.CombatQueue = {} -- [0] or [1] = name of trinket queued for slot 0 or 1
TrinketMenu.Corners = { "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }
TrinketMenu.WatchItem = {} -- table of items being watched for cooldowns

-- Pre-cached frame references (populated in CacheFrameRefs)
TrinketMenu.MenuFrames = {}      -- [i] = TrinketMenu_Menu<i>
TrinketMenu.MenuIconFrames = {}  -- [i] = TrinketMenu_Menu<i>Icon
TrinketMenu.MenuCDFrames = {}    -- [i] = TrinketMenu_Menu<i>Cooldown
TrinketMenu.MenuTimeFrames = {}  -- [i] = TrinketMenu_Menu<i>Time
TrinketMenu.QueueIcons = {}      -- [0] = TrinketMenu_Trinket0Queue, [1] = ..1Queue

-- Cached equipped trinket names and IDs (updated on UNIT_INVENTORY_CHANGED)
TrinketMenu.EquippedTrinketName = {} -- [13] and [14]
TrinketMenu.EquippedTrinketID = {} -- [13] and [14] = itemId string

--[[ Local functions ]]--

-- dock-dependant offset and directions: MainDock..MenuDock
-- x/yoff   = offset MenuFrame is positioned to MainFrame
-- x/ydir   = direction trinkets are added to menu
-- x/ystart = starting offset when building a menu, relativePoint MenuDock
TrinketMenu.DockStats = { ["TOPRIGHTTOPLEFT"] =		 { xoff=-4, yoff=0,  xdir=1,  ydir=-1, xstart=8,   ystart=-8 },
					 ["BOTTOMRIGHTBOTTOMLEFT"] = { xoff=-4, yoff=0,  xdir=1,  ydir=1,  xstart=8,   ystart=44 },
					 ["TOPLEFTTOPRIGHT"] =		 { xoff=4,  yoff=0,  xdir=-1, ydir=-1, xstart=-44, ystart=-8 },
					 ["BOTTOMLEFTBOTTOMRIGHT"] = { xoff=4,  yoff=0,  xdir=-1, ydir=1,  xstart=-44, ystart=44 },
					 ["TOPRIGHTBOTTOMRIGHT"] =   { xoff=0,  yoff=-4, xdir=-1, ydir=1,  xstart=-44,  ystart=44 },
					 ["BOTTOMRIGHTTOPRIGHT"] =   { xoff=0,  yoff=4,	 xdir=-1, ydir=-1, xstart=-44,  ystart=-8 },
					 ["TOPLEFTBOTTOMLEFT"] =	 { xoff=0,  yoff=-4, xdir=1,  ydir=1,  xstart=8,   ystart=44 },
					 ["BOTTOMLEFTTOPLEFT"] =	 { xoff=0,  yoff=4,  xdir=1,  ydir=-1, xstart=8,   ystart=-8 } }

-- returns offset and direction depending on current docking. ie: TrinketMenu.DockInfo("xoff")
function TrinketMenu.DockInfo(arg1)
	local anchor = TrinketMenuPerOptions.MainDock..TrinketMenuPerOptions.MenuDock
	if TrinketMenu.DockStats[anchor] and arg1 and TrinketMenu.DockStats[anchor][arg1] then
		return TrinketMenu.DockStats[anchor][arg1]
	else
		return 0
	end
end

-- hide the docking markers
function TrinketMenu.ClearDocking()
	for i=1,4 do
		_G["TrinketMenu_MainDock_"..TrinketMenu.Corners[i]]:Hide()
		_G["TrinketMenu_MenuDock_"..TrinketMenu.Corners[i]]:Hide()
	end
end

-- returns true if the two values are close to each other
function TrinketMenu.Near(arg1,arg2)
	return (math.max(arg1,arg2)-math.min(arg1,arg2))<15
end

-- moves the MenuFrame to the dock position against MainFrame
function TrinketMenu.DockWindows()
	TrinketMenu.ClearDocking()
	if TrinketMenuOptions.KeepDocked=="ON" then
		TrinketMenu_MenuFrame:ClearAllPoints()
		if TrinketMenuOptions.Locked=="OFF" then
			TrinketMenu_MenuFrame:SetPoint(TrinketMenuPerOptions.MenuDock,"TrinketMenu_MainFrame",TrinketMenuPerOptions.MainDock,TrinketMenu.DockInfo("xoff"),TrinketMenu.DockInfo("yoff"))
		else
			TrinketMenu_MenuFrame:SetPoint(TrinketMenuPerOptions.MenuDock,"TrinketMenu_MainFrame",TrinketMenuPerOptions.MainDock,TrinketMenu.DockInfo("xoff")*3,TrinketMenu.DockInfo("yoff")*3)
		end
	end
	if TrinketMenu_MenuFrame:IsVisible() then
		TrinketMenu.BuildMenu()
	end
end

-- displays windows vertically or horizontally
function TrinketMenu.OrientWindows()
	if TrinketMenuPerOptions.MainOrient=="HORIZONTAL" then
		TrinketMenu_MainFrame:SetWidth(92)
		TrinketMenu_MainFrame:SetHeight(52)
	else
		TrinketMenu_MainFrame:SetWidth(52)
		TrinketMenu_MainFrame:SetHeight(92)
	end
end

-- scan bags for trinkets and cache results (only when dirty)
function TrinketMenu.ScanBaggedTrinkets()
	local idx = 1
	if TrinketMenu.hasGetTrinkets then
		-- Nampower fast path: single C call returns all trinkets (skips non-trinket slots)
		-- We still use GetContainerItemInfo for textures because GetTrinkets may return
		-- numeric fileDataIDs that vanilla SetTexture doesn't accept
		local trinkets = GetTrinkets()
		for i=1,table.getn(trinkets) do
			if idx > TrinketMenu.MaxTrinkets then break end
			local t = trinkets[i]
			if t.bagIndex ~= nil then -- bagged only (nil = equipped)
				if not TrinketMenu.BaggedTrinkets[idx] then
					TrinketMenu.BaggedTrinkets[idx] = {}
				end
				TrinketMenu.BaggedTrinkets[idx].bag = t.bagIndex
				TrinketMenu.BaggedTrinkets[idx].slot = t.slotIndex
				TrinketMenu.BaggedTrinkets[idx].name = t.trinketName
				TrinketMenu.BaggedTrinkets[idx].texture = GetContainerItemInfo(t.bagIndex, t.slotIndex) or t.texture
				TrinketMenu.BaggedTrinkets[idx].id = t.itemId
				idx = idx + 1
			end
		end
	elseif TrinketMenu.hasClassicBag then
		-- ClassicAPI fast(er) path: some servers ship ClassicAPI's C_Container
		-- backport without Nampower. GetContainerItemInfo's table already
		-- gives us itemID/itemName/hyperlink/iconFileID directly (confirmed
		-- against ClassicAPI's own reference), so no regex parsing needed -
		-- we still confirm INVTYPE_TRINKET via GetItemInfo per item since
		-- ContainerItemInfo doesn't carry an equip-slot field.
		local info,equipSlot,itemTexture,itemName
		for i=0,4 do
			if idx > TrinketMenu.MaxTrinkets then break end
			for j=1,GetContainerNumSlots(i) do
				if idx > TrinketMenu.MaxTrinkets then break end
				info = C_Container.GetContainerItemInfo(i,j)
				if info and info.itemID then
					_,_,_,_,_,_,_,equipSlot,itemTexture = GetItemInfo(info.itemID)
					if equipSlot=="INVTYPE_TRINKET" then
						if not TrinketMenu.BaggedTrinkets[idx] then
							TrinketMenu.BaggedTrinkets[idx] = {}
						end
						-- itemName is cache-derived and can briefly be nil right
						-- after a bag update; hyperlink is a live per-instance
						-- field per ClassicAPI's docs, so pull the name from the
						-- link text the same way the other two scan tiers do.
						itemName = info.itemName
						if not itemName and info.hyperlink then
							_,_,itemName = string.find(info.hyperlink,"%[(.+)%]")
						end
						TrinketMenu.BaggedTrinkets[idx].bag = i
						TrinketMenu.BaggedTrinkets[idx].slot = j
						TrinketMenu.BaggedTrinkets[idx].name = itemName
						TrinketMenu.BaggedTrinkets[idx].texture = info.iconFileID or itemTexture
						TrinketMenu.BaggedTrinkets[idx].id = info.itemID
						idx = idx + 1
					end
				end
			end
		end
	else
		-- Vanilla fallback: scan all bag slots
		local itemLink,itemID,itemName,equipSlot,itemTexture
		for i=0,4 do
			if idx > TrinketMenu.MaxTrinkets then break end
			for j=1,GetContainerNumSlots(i) do
				if idx > TrinketMenu.MaxTrinkets then break end
				itemLink = GetContainerItemLink(i,j)
				if itemLink then
					_,_,itemID,itemName = string.find(itemLink,"item:(%d+).+%[(.+)%]")
					_,_,_,_,_,_,_,equipSlot,itemTexture = GetItemInfo(itemID or "")
					if equipSlot=="INVTYPE_TRINKET" then
						if not TrinketMenu.BaggedTrinkets[idx] then
							TrinketMenu.BaggedTrinkets[idx] = {}
						end
						TrinketMenu.BaggedTrinkets[idx].bag = i
						TrinketMenu.BaggedTrinkets[idx].slot = j
						TrinketMenu.BaggedTrinkets[idx].name = itemName
						TrinketMenu.BaggedTrinkets[idx].texture = itemTexture
						TrinketMenu.BaggedTrinkets[idx].id = itemID
						idx = idx + 1
					end
				end
			end
		end
	end
	TrinketMenu.NumberOfTrinkets = math.min(idx-1,TrinketMenu.MaxTrinkets)
	TrinketMenu.BagsDirty = false

	-- Tag trinkets that share a name with another bagged copy. Priority/Delay/
	-- Pause settings and the watch table are keyed by name, so two physical
	-- copies of the same trinket share one entry - this just makes that
	-- visible in the tooltip instead of silently surprising the player.
	local nameCount = {}
	for i=1,TrinketMenu.NumberOfTrinkets do
		local n = TrinketMenu.BaggedTrinkets[i].name
		if n then nameCount[n] = (nameCount[n] or 0) + 1 end
	end
	for i=1,TrinketMenu.NumberOfTrinkets do
		local n = TrinketMenu.BaggedTrinkets[i].name
		TrinketMenu.BaggedTrinkets[i].dupeCount = n and nameCount[n] or 1
	end
end

-- build and display MenuFrame
function TrinketMenu.BuildMenu()

	if not IsShiftKeyDown() and TrinketMenuOptions.MenuOnShift=="ON" then
		return
	end

	-- only rescan bags if contents changed
	if TrinketMenu.BagsDirty ~= false then
		TrinketMenu.ScanBaggedTrinkets()
	end

	if TrinketMenu.NumberOfTrinkets<1 then
		-- user has no bagged trinkets :(
		TrinketMenu_MenuFrame:Hide()
	else
		-- cache dock stats for this layout pass
		local dock = TrinketMenu.DockStats[TrinketMenuPerOptions.MainDock..TrinketMenuPerOptions.MenuDock] or {}
		local dxdir = dock.xdir or 0
		local dydir = dock.ydir or 0
		local dxstart = dock.xstart or 0
		local dystart = dock.ystart or 0

		-- display trinkets outward from docking point
		local col,row,xpos,ypos = 0,0,dxstart,dystart
		local max_cols = 1

		if TrinketMenu.NumberOfTrinkets>24 then
			max_cols = 5
		elseif TrinketMenu.NumberOfTrinkets>18 then
			max_cols = 4
		elseif TrinketMenu.NumberOfTrinkets>12 then
			max_cols = 3
		elseif TrinketMenu.NumberOfTrinkets>4 then
			max_cols = 2
		end
		if TrinketMenuOptions.SetColumns=="ON" and TrinketMenuOptions.Columns then
			max_cols = TrinketMenuOptions.Columns
		end

		for i=1,TrinketMenu.NumberOfTrinkets do
			local item = TrinketMenu.MenuFrames[i]
			TrinketMenu.MenuIconFrames[i]:SetTexture(TrinketMenu.BaggedTrinkets[i].texture)
			item:SetPoint("TOPLEFT","TrinketMenu_MenuFrame",TrinketMenuPerOptions.MenuDock,xpos,ypos)

			if TrinketMenuPerOptions.MenuOrient=="VERTICAL" then
				xpos = xpos + dxdir*40
				col = col + 1
				if col==max_cols then
					xpos = dxstart
					col = 0
					ypos = ypos + dydir*40
					row = row + 1
				end
				item:Show()
			else
				ypos = ypos + dydir*40
				col = col + 1
				if col==max_cols then
					ypos = dystart
					col = 0
					xpos = xpos + dxdir*40
					row = row + 1
				end
				item:Show()
			end
		end
		for i=(TrinketMenu.NumberOfTrinkets+1),TrinketMenu.MaxTrinkets do
			TrinketMenu.MenuFrames[i]:Hide()
		end
		if col==0 then
			row = row-1
		end

		if TrinketMenuPerOptions.MenuOrient=="VERTICAL" then
			TrinketMenu_MenuFrame:SetWidth(12+(max_cols*40))
			TrinketMenu_MenuFrame:SetHeight(12+((row+1)*40))
		else
			TrinketMenu_MenuFrame:SetWidth(12+((row+1)*40))
			TrinketMenu_MenuFrame:SetHeight(12+(max_cols*40))
		end
		TrinketMenu.UpdateMenuCooldowns()
		TrinketMenu_MenuFrame:Show()
		TrinketMenu.StartTimer("MenuMouseover")
	end

end

function TrinketMenu.CacheFrameRefs()
	for i=1,TrinketMenu.MaxTrinkets do
		TrinketMenu.MenuFrames[i] = _G["TrinketMenu_Menu"..i]
		TrinketMenu.MenuIconFrames[i] = _G["TrinketMenu_Menu"..i.."Icon"]
		TrinketMenu.MenuCDFrames[i] = _G["TrinketMenu_Menu"..i.."Cooldown"]
		TrinketMenu.MenuTimeFrames[i] = _G["TrinketMenu_Menu"..i.."Time"]
	end
	TrinketMenu.QueueIcons[0] = _G["TrinketMenu_Trinket0Queue"]
	TrinketMenu.QueueIcons[1] = _G["TrinketMenu_Trinket1Queue"]
end

function TrinketMenu.UpdateEquippedNames()
	for i=13,14 do
		local _,name = TrinketMenu.ItemInfo(i)
		TrinketMenu.EquippedTrinketName[i] = name
		local link = GetInventoryItemLink("player",i)
		if link then
			local _,_,id = string.find(link,"item:(%d+)")
			TrinketMenu.EquippedTrinketID[i] = id
		else
			TrinketMenu.EquippedTrinketID[i] = nil
		end
	end
end

function TrinketMenu.Initialize()

	local options = TrinketMenuOptions
	options.KeepDocked = options.KeepDocked or "ON" -- new option for 2.1
	options.Notify = options.Notify or "OFF" -- 2.1
	options.DisableToggle = options.DisableToggle or "OFF" -- new option for 2.2
	options.NotifyUsedOnly = options.NotifyUsedOnly or "OFF" -- 2.2
	options.NotifyChatAlso = options.NotifyChatAlso or "OFF" -- 2.2
	options.ShowTooltips = options.ShowTooltips or "ON" -- 2.3
	options.NotifyThirty = options.NotifyThirty or "OFF" -- 2.5
	options.SquareMinimap = options.SquareMinimap or "OFF" -- 2.6
	options.MenuOnShift = options.MenuOnShift or "OFF" -- 2.6
	options.TinyTooltips = options.TinyTooltips or "OFF" -- 3.0
	options.SetColumns = options.SetColumns or "OFF" -- 3.0
	options.Columns = options.Columns or 4 -- 3.0
	options.LargeCooldown = options.LargeCooldown or "OFF" -- 3.0
	options.ShowHotKeys = options.ShowHotKeys or "OFF" -- 3.0
	TrinketMenuPerOptions.ItemsUsed = TrinketMenuPerOptions.ItemsUsed or {} -- 3.0
	options.StopOnSwap = options.StopOnSwap or "OFF" -- 3.2
	options.HideOnLoad = options.HideOnLoad or "OFF" -- 3.4

	if TrinketMenuPerOptions.XPos and TrinketMenuPerOptions.YPos then
		TrinketMenu_MainFrame:SetPoint("TOPLEFT","UIParent","BOTTOMLEFT",TrinketMenuPerOptions.XPos,TrinketMenuPerOptions.YPos)
	end
	if TrinketMenuPerOptions.MainScale then
		TrinketMenu_MainFrame:SetScale(TrinketMenuPerOptions.MainScale)
	end
	if TrinketMenuPerOptions.MenuScale then
		TrinketMenu_MenuFrame:SetScale(TrinketMenuPerOptions.MenuScale)
	end

	TrinketMenu.CacheFrameRefs()

	TrinketMenu.InitTimers()
	TrinketMenu.CreateTimer("UpdateWornTrinkets",TrinketMenu.UpdateWornTrinkets,.75)
	TrinketMenu.CreateTimer("DockingMenu",TrinketMenu.DockingMenu,.2,1)
	TrinketMenu.CreateTimer("MenuMouseover",TrinketMenu.MenuMouseover,.25,1)
	TrinketMenu.CreateTimer("Scaling",TrinketMenu.Scaling,.1,1)
	TrinketMenu.CreateTimer("TooltipUpdate",TrinketMenu.TooltipUpdate,1,1)
	TrinketMenu.CreateTimer("CooldownUpdate",TrinketMenu.CooldownUpdate,1,1)

	TrinketMenu.oldUseInventoryItem = UseInventoryItem
	UseInventoryItem = TrinketMenu.newUseInventoryItem
	TrinketMenu.oldUseAction = UseAction
	UseAction = TrinketMenu.newUseAction

	TrinketMenu.InitOptions()

	TrinketMenu.UpdateWornTrinkets()
	TrinketMenu.DockWindows()
	TrinketMenu.OrientWindows()
	TrinketMenu.StartTimer("CooldownUpdate")

	if TrinketMenuPerOptions.Visible=="ON" and (GetInventoryItemLink("player",13) or GetInventoryItemLink("player",14)) then
		TrinketMenu_MainFrame:Show()
	end
end

-- returns true if the player is really dead or ghost, not merely FD
function TrinketMenu.IsPlayerReallyDead()
	if not UnitIsDeadOrGhost("player") then
		return nil
	end
	for i=1,24 do
		if UnitBuff("player",i)=="Interface\\Icons\\Ability_Rogue_FeignDeath" then
			return nil
		end
	end
	return true
end

function TrinketMenu.ItemInfo(slot)
	local link = GetInventoryItemLink("player",slot)
	local name,equipLoc,texture
	if link then
		local _,_,id = string.find(link,"item:(%d+)")
		name,_,_,_,_,_,_,equipLoc,texture = GetItemInfo(id)
	else
		_,texture = GetInventorySlotInfo("Trinket"..(slot-13).."Slot")
	end
	return texture,name,equipLoc
end

function TrinketMenu.FindItem(name,includeInventory)
	if includeInventory then
		for i=13,14 do
			if string.find(GetInventoryItemLink("player",i) or "",name,1,1) then
				return i
			end
		end
	end
	for i=0,4 do
		for j=1,GetContainerNumSlots(i) do
			if string.find(GetContainerItemLink(i,j) or "",name,1,1) then
				return nil,i,j
			end
		end
	end
end

--[[ Frame Scripts ]]--

function TrinketMenu.OnLoad()

	SlashCmdList["TrinketMenuCOMMAND"] = TrinketMenu.SlashHandler
	SLASH_TrinketMenuCOMMAND1 = "/trinketmenu";
	SLASH_TrinketMenuCOMMAND2 = "/trinket";
	
	this:RegisterEvent("PLAYER_LOGIN")
end

function TrinketMenu.OnEvent()

	if event=="BAG_UPDATE" then
		TrinketMenu.BagsDirty = true
		if arg1 and arg1>=0 and arg1<=4 then
			if TrinketMenu.BagsNeedUpdating then
				TrinketMenu.BagsNeedUpdating[arg1] = 1
			end
		end
		if TrinketMenu.TimerPool and TrinketMenu.TimerPool["UpdateBaggedTrinkets"] then
			TrinketMenu.StartTimer("UpdateBaggedTrinkets")
		end
	elseif event=="UNIT_INVENTORY_CHANGED" and arg1=="player" then
		TrinketMenu.UpdateWornTrinkets()
	elseif event=="ACTIONBAR_UPDATE_COOLDOWN" then
		TrinketMenu.UpdateWornCooldowns(1)
	elseif (event=="PLAYER_REGEN_ENABLED" or event=="PLAYER_UNGHOST" or event=="PLAYER_ALIVE") and not TrinketMenu.IsPlayerReallyDead() then
		-- trinkets can now be swapped after combat/death
		if TrinketMenu.CombatQueue[0] or TrinketMenu.CombatQueue[1] then
			TrinketMenu.Trace("Combat/death ended, processing combat queue")
			TrinketMenu.EquipTrinketByName(TrinketMenu.CombatQueue[0],13)
			TrinketMenu.EquipTrinketByName(TrinketMenu.CombatQueue[1],14)
			TrinketMenu.CombatQueue[0] = nil
			TrinketMenu.CombatQueue[1] = nil
			TrinketMenu.UpdateCombatQueue()
		end
	elseif event=="UPDATE_BINDINGS" then
		TrinketMenu.ReflectKeyBindings()
	elseif event=="SPELL_CAST_EVENT" then
		-- Nampower: arg1=success, arg5=itemId
		if arg1==1 and arg5 and arg5~=0 then
			local itemIdStr = tostring(arg5)
			if itemIdStr == TrinketMenu.EquippedTrinketID[13] then
				TrinketMenu.Trace("SPELL_CAST_EVENT matched slot 13 itemId="..itemIdStr)
				TrinketMenu.ReflectTrinketUse(13)
			elseif itemIdStr == TrinketMenu.EquippedTrinketID[14] then
				TrinketMenu.Trace("SPELL_CAST_EVENT matched slot 14 itemId="..itemIdStr)
				TrinketMenu.ReflectTrinketUse(14)
			end
		end
	elseif event=="PLAYER_LOGIN" then
		TrinketMenu.DetectMods()
		TrinketMenu.LoadDefaults()
		TrinketMenu.Initialize()
	this:RegisterEvent("PLAYER_REGEN_ENABLED")
	this:RegisterEvent("PLAYER_UNGHOST")
	this:RegisterEvent("PLAYER_ALIVE")
	this:RegisterEvent("UNIT_INVENTORY_CHANGED")
	this:RegisterEvent("UPDATE_BINDINGS")
	this:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
	if TrinketMenu.hasNampower then
		this:RegisterEvent("SPELL_CAST_EVENT")
	end
	end
end

function TrinketMenu.UpdateWornTrinkets()
	local tex0 = TrinketMenu.ItemInfo(13)
	local tex1 = TrinketMenu.ItemInfo(14)
	TrinketMenu_Trinket0Icon:SetTexture(tex0)
	TrinketMenu_Trinket1Icon:SetTexture(tex1)
	TrinketMenu_Trinket0Icon:SetDesaturated(nil)
	TrinketMenu_Trinket0:SetChecked(0)
	TrinketMenu_Trinket1Icon:SetDesaturated(nil)
	TrinketMenu_Trinket1:SetChecked(0)
	TrinketMenu.UpdateWornCooldowns()
	TrinketMenu.UpdateEquippedNames()
	local name
	for i=13,14 do
		_,_,name = string.find(GetInventoryItemLink("player",i) or "","%[(.+)%]")
		if name then
			TrinketMenu.AddWatchItem(name,i,nil,nil,TrinketMenu.EquippedTrinketID[i])
		end
	end
	TrinketMenu.BagsDirty = true -- inventory changed, menu needs rescan
	if TrinketMenu_MenuFrame:IsVisible() then
		TrinketMenu.BuildMenu()
	end
end

function TrinketMenu.SlashHandler(msg)

	local _,_,which,profile = string.find(msg,"load (.+) (.+)")

	if profile and TrinketMenu.SetQueue then
		which = string.lower(which)
		if which=="top" or which=="0" then
			which = 0
		elseif which=="bottom" or which=="1" then
			which = 1
		elseif which=="merged" or which=="2" then
			which = 2
		end
		if type(which)=="number" then
			local profileIdx = TrinketMenu.GetProfileID(profile)
			if profileIdx then
				TrinketMenu.LoadProfile(which, profileIdx)
			elseif which == 2 then
				DEFAULT_CHAT_FRAME:AddMessage("|cFFBBBBBBTrinketMenu:|cFFFFFFFF Profile \""..profile.."\" not found.")
			else
				TrinketMenu.SetQueue(which,"SORT",profile)
			end
			return
		end
	end

	msg = string.lower(msg)

	if not msg or msg=="" then
		TrinketMenu.ToggleFrame(TrinketMenu_MainFrame)
	elseif string.find(msg,"^opt") or string.find(msg,"^config") then
		TrinketMenu.ToggleFrame(TrinketMenu_OptFrame)
	elseif msg=="lock" then
		TrinketMenuOptions.Locked="ON"
		TrinketMenu.DockWindows()
		TrinketMenu.ReflectLock()
	elseif msg=="unlock" then
		TrinketMenuOptions.Locked="OFF"
		TrinketMenu.DockWindows()
		TrinketMenu.ReflectLock()
	elseif msg=="reset" then
		TrinketMenu.ResetSettings()
	elseif string.find(msg,"scale") then
		local _,_,menuscale = string.find(msg,"scale menu (.+)")
		if tonumber(menuscale) then
			TrinketMenu.FrameToScale = TrinketMenu_MenuFrame
			TrinketMenu.ScaleFrame(menuscale)
		end
		local _,_,mainscale = string.find(msg,"scale main (.+)")
		if tonumber(mainscale) then
			TrinketMenu.FrameToScale = TrinketMenu_MainFrame
			TrinketMenu.ScaleFrame(mainscale)
		end
		if not tonumber(menuscale) and not tonumber(mainscale) then
			DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00TrinketMenu scale:")
			DEFAULT_CHAT_FRAME:AddMessage("/trinket scale main (number) : set exact main scale")
			DEFAULT_CHAT_FRAME:AddMessage("/trinket scale menu (number) : set exact menu scale")
			DEFAULT_CHAT_FRAME:AddMessage("ie, /trinket scale menu 0.85")
			DEFAULT_CHAT_FRAME:AddMessage("Note: You can drag the lower-right corner of either window to scale.  This slash command is for those who want to set an exact scale.")
		end
		TrinketMenu.FrameToScale = nil
		TrinketMenuPerOptions.MainScale = TrinketMenu_MainFrame:GetScale()
		TrinketMenuPerOptions.MenuScale = TrinketMenu_MenuFrame:GetScale()
	elseif string.find(msg,"load") then
		DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00TrinketMenu load:")
		DEFAULT_CHAT_FRAME:AddMessage("/trinket load (top|bottom|merged) profilename\nie: /trinket load bottom PvP")
	elseif msg=="compat" then
		TrinketMenu.PrintCompat()
	elseif string.find(msg,"^dock") then
		local _,_,dir = string.find(msg,"^dock%s+(%S+)")
		if dir=="top" then
			TrinketMenuPerOptions.MainDock, TrinketMenuPerOptions.MenuDock = "TOPLEFT", "BOTTOMLEFT"
		elseif dir=="bottom" then
			TrinketMenuPerOptions.MainDock, TrinketMenuPerOptions.MenuDock = "BOTTOMLEFT", "TOPLEFT"
		elseif dir=="left" then
			TrinketMenuPerOptions.MainDock, TrinketMenuPerOptions.MenuDock = "TOPLEFT", "TOPRIGHT"
		elseif dir=="right" then
			TrinketMenuPerOptions.MainDock, TrinketMenuPerOptions.MenuDock = "TOPRIGHT", "TOPLEFT"
		else
			DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00TrinketMenu dock:")
			DEFAULT_CHAT_FRAME:AddMessage("/trinket dock top|bottom|left|right")
			return
		end
		TrinketMenuOptions.KeepDocked = "ON"
		TrinketMenu.DockWindows()
		DEFAULT_CHAT_FRAME:AddMessage("|cFFBBBBBBTrinketMenu:|cFFFFFFFF Menu docked: "..dir)
	elseif msg=="trace" then
		TrinketMenu.trace = not TrinketMenu.trace
		DEFAULT_CHAT_FRAME:AddMessage("|cFFBBBBBBTrinketMenu:|cFFFFFFFF Debug trace "..(TrinketMenu.trace and "|cFF00FF00ON" or "|cFFFF0000OFF"))
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00TrinketMenu useage:")
		DEFAULT_CHAT_FRAME:AddMessage("/trinket or /trinketmenu : toggle the window")
		DEFAULT_CHAT_FRAME:AddMessage("/trinket reset : reset all settings")
		DEFAULT_CHAT_FRAME:AddMessage("/trinket opt : summon options window")
		DEFAULT_CHAT_FRAME:AddMessage("/trinket lock|unlock : toggles window lock")
		DEFAULT_CHAT_FRAME:AddMessage("/trinket dock top|bottom|left|right : dock swap menu")
		DEFAULT_CHAT_FRAME:AddMessage("/trinket scale main|menu (number) : sets an exact scale")
		DEFAULT_CHAT_FRAME:AddMessage("/trinket load top|bottom|merged profilename : loads a profile")
		DEFAULT_CHAT_FRAME:AddMessage("/trinket compat : show detected DLL/addon integrations")
		DEFAULT_CHAT_FRAME:AddMessage("/trinket trace : toggle debug trace output")
	end
end

-- reports which of Nampower/SuperWoW/UnitXP SP3/ClassicAPI/VanillaHelpers
-- were detected, and what TrinketMenu actually does with each one
function TrinketMenu.PrintCompat()
	local on,off = "|cFF00FF00detected","|cFFFF0000not detected"
	DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00TrinketMenu compatibility:")
	local nampowerVer = ""
	if TrinketMenu.hasNampowerVersion then
		local okv,major,minor,patch = pcall(GetNampowerVersion)
		if okv and major then
			nampowerVer = " (v"..major.."."..minor.."."..patch..")"
		end
	end
	DEFAULT_CHAT_FRAME:AddMessage("Nampower: "..(TrinketMenu.hasNampower and on or off)..nampowerVer..
		(TrinketMenu.hasNampower and "|cFFFFFFFF - driving worn/bagged cooldowns and trinket-use detection" or ""))
	DEFAULT_CHAT_FRAME:AddMessage("ClassicAPI: "..(TrinketMenu.hasClassicAPI and (on.."|cFFFFFFFF (v"..tostring(CLASSIC_API_VERSION)..")") or off))
	DEFAULT_CHAT_FRAME:AddMessage("  C_Container bag API: "..(TrinketMenu.hasClassicBag and on or off)..
		(TrinketMenu.hasClassicBag and "|cFFFFFFFF - used as bag-scan fallback when Nampower's GetTrinkets is absent" or
			(TrinketMenu.hasClassicAPI and "|cFFFFFFFF - ClassicAPI is loaded but C_Container wasn't found on this build/version" or "")))
	DEFAULT_CHAT_FRAME:AddMessage("  C_Timer: "..(TrinketMenu.hasClassicTimer and on or off))
	DEFAULT_CHAT_FRAME:AddMessage("  Item-ID cooldown lookup: "..(TrinketMenu.hasClassicItemCooldown and on or off)..
		(TrinketMenu.hasClassicItemCooldown and "|cFFFFFFFF - tracks used trinkets by item ID without Nampower, same as Nampower's advantage" or ""))
	if TrinketMenu.hasClassicAPI and not TrinketMenu.hasClassicBag then
		if type(C_Container) ~= "table" then
			DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFAA00C_Container global doesn't exist at all on this build.")
		else
			DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFAA00C_Container exists - listing its functions so we can find the real names:")
			local list = ""
			for k,v in C_Container do
				if type(v)=="function" then
					list = list..k..", "
				end
			end
			DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFAA00"..(list~="" and list or "(no functions found in the table)"))
		end
	end
	DEFAULT_CHAT_FRAME:AddMessage("UnitXP SP3: "..(TrinketMenu.hasUnitXP and on or off)..
		(TrinketMenu.hasUnitXP and "|cFFFFFFFF - taskbar/sound alert on trinket-ready while alt-tabbed" or ""))
	DEFAULT_CHAT_FRAME:AddMessage("SuperWoW: "..(TrinketMenu.hasSuperWoW and on or off)..
		"|cFFFFFFFF - detected for other addons' benefit; TrinketMenu already addresses items by exact bag/slot or item ID, so it has nothing extra to use here")
	DEFAULT_CHAT_FRAME:AddMessage("VanillaHelpers: "..(TrinketMenu.hasVanillaHelpers and on or off)..
		"|cFFFFFFFF - display/model/file-IO only, no item or cooldown API for TrinketMenu to use")
end

function TrinketMenu.ResetSettings()
	StaticPopupDialogs["TRINKETMENURESET"] = {
		text = "Are you sure you want to reset TrinketMenu to default state and reload the UI?",
		button1 = "Yes", button2 = "No", showAlert=1, timeout = 0, whileDead = 1,
		OnAccept = function() TrinketMenuOptions=nil TrinketMenuPerOptions=nil TrinketMenuQueue=nil ReloadUI() end,
	}
	StaticPopup_Show("TRINKETMENURESET")
end

--[[ Window Movement ]]--

function TrinketMenu.MainFrame_OnMouseUp()
	if arg1=="LeftButton" then
		this:StopMovingOrSizing()
		TrinketMenuPerOptions.XPos = TrinketMenu_MainFrame:GetLeft()
		TrinketMenuPerOptions.YPos = TrinketMenu_MainFrame:GetTop()
	elseif TrinketMenuOptions.Locked=="OFF" then
		if TrinketMenuPerOptions.MainOrient=="VERTICAL" then
			TrinketMenuPerOptions.MainOrient = "HORIZONTAL"
		else
			TrinketMenuPerOptions.MainOrient = "VERTICAL"
		end
		TrinketMenu.OrientWindows()
	end

end

function TrinketMenu.MainFrame_OnMouseDown(arg1)
	if arg1=="LeftButton" and TrinketMenuOptions.Locked=="OFF" then
		this:StartMoving()
	end
end

--[[ Timers ]]

function TrinketMenu.InitTimers()
	TrinketMenu.TimerPool = {}
	TrinketMenu.Timers = {}
	TrinketMenu.ActiveTimers = {} -- hash lookup: ActiveTimers[name] = true
end

function TrinketMenu.CreateTimer(name,func,delay,rep)
	TrinketMenu.TimerPool[name] = { func=func,delay=delay,rep=rep,elapsed=delay }
end

function TrinketMenu.IsTimerActive(name)
	return TrinketMenu.ActiveTimers[name]
end

function TrinketMenu.StartTimer(name,delay)
	TrinketMenu.TimerPool[name].elapsed = delay or TrinketMenu.TimerPool[name].delay
	if not TrinketMenu.ActiveTimers[name] then
		table.insert(TrinketMenu.Timers,name)
		TrinketMenu.ActiveTimers[name] = true
		TrinketMenu_TimersFrame:Show()
	end
end

function TrinketMenu.StopTimer(name)
	if TrinketMenu.ActiveTimers[name] then
		TrinketMenu.ActiveTimers[name] = nil
		-- find and remove from ordered list
		for i=table.getn(TrinketMenu.Timers),1,-1 do
			if TrinketMenu.Timers[i]==name then
				table.remove(TrinketMenu.Timers,i)
				break
			end
		end
		if table.getn(TrinketMenu.Timers)<1 then
			TrinketMenu_TimersFrame:Hide()
		end
	end
end

function TrinketMenu.TimersFrame_OnUpdate()
	local timerPool
	local toStop -- deferred removal list
	for i=1,table.getn(TrinketMenu.Timers) do
		local name = TrinketMenu.Timers[i]
		if TrinketMenu.ActiveTimers[name] then
			timerPool = TrinketMenu.TimerPool[name]
			timerPool.elapsed = timerPool.elapsed - arg1
			if timerPool.elapsed < 0 then
				timerPool.func()
				if timerPool.rep then
					timerPool.elapsed = timerPool.delay
				else
					if not toStop then toStop = {} end
					table.insert(toStop, name)
				end
			end
		end
	end
	if toStop then
		for i=1,table.getn(toStop) do
			TrinketMenu.StopTimer(toStop[i])
		end
	end
end

function TrinketMenu.TimerDebug()
	local on = "|cFF00FF00On"
	local off = "|cFFFF0000Off"
	DEFAULT_CHAT_FRAME:AddMessage("|cFF44AAFFTrinketMenu_TimersFrame is "..(TrinketMenu_TimersFrame:IsVisible() and on or off))
	for i in TrinketMenu.TimerPool do
		DEFAULT_CHAT_FRAME:AddMessage(i.." is "..(TrinketMenu.IsTimerActive(i) and on or off))
	end
end

--[[ OnClicks ]]

function TrinketMenu.MainTrinket_OnClick()
	if IsShiftKeyDown() and ChatFrameEditBox:IsVisible() then
		this:SetChecked(0)
		ChatFrameEditBox:Insert(GetInventoryItemLink("player",this:GetID()))
	elseif IsAltKeyDown() and TrinketMenu.QueueInit then
		this:SetChecked(0)
		local which = this:GetID()-13
		if TrinketMenuQueue.Enabled[which] then
			TrinketMenu.CombatQueue[this:GetID()-13]=nil
			TrinketMenuQueue.Enabled[which] = nil
		else
			TrinketMenuQueue.Enabled[which] = 1
		end
--		TrinketMenuQueue.Enabled[which] = not TrinketMenuQueue.Enabled[which]
		TrinketMenu.ReflectQueueEnabled()
		TrinketMenu.UpdateCombatQueue()
		-- toggle queue
	else
		UseInventoryItem(this:GetID())
	end
end

function TrinketMenu.MenuTrinket_OnClick()
	this:SetChecked(0)
	if IsShiftKeyDown() and ChatFrameEditBox:IsVisible() then
		ChatFrameEditBox:Insert(GetContainerItemLink(TrinketMenu.BaggedTrinkets[this:GetID()].bag,TrinketMenu.BaggedTrinkets[this:GetID()].slot))
	else
		local slot = (arg1=="LeftButton") and 13 or 14
		if TrinketMenu.QueueInit then
			local _,_,canCooldown = GetContainerItemCooldown(TrinketMenu.BaggedTrinkets[this:GetID()].bag,TrinketMenu.BaggedTrinkets[this:GetID()].slot)
			if canCooldown==0 or TrinketMenuOptions.StopOnSwap=="ON" then -- if incoming trinket can't go on cooldown
				TrinketMenuQueue.Enabled[slot-13]=nil -- turn off autoqueue
				TrinketMenu.ReflectQueueEnabled()
			end
		end
		TrinketMenu.EquipTrinketByName(TrinketMenu.BaggedTrinkets[this:GetID()].name,slot)
		if not IsShiftKeyDown() and TrinketMenuOptions.KeepOpen=="OFF" then
			TrinketMenu_MenuFrame:Hide()
		end
	end
end

--[[ Docking ]]

function TrinketMenu.MenuFrame_OnMouseDown()
	if arg1=="LeftButton" and TrinketMenuOptions.Locked=="OFF" then
		TrinketMenu_MenuFrame:StartMoving()

		if TrinketMenuOptions.KeepDocked=="ON" then
			TrinketMenu.StartTimer("DockingMenu")
		end
	end
end

function TrinketMenu.MenuFrame_OnMouseUp()
	if arg1=="LeftButton" then
		TrinketMenu.StopTimer("DockingMenu")
		TrinketMenu_MenuFrame:StopMovingOrSizing()
		if TrinketMenuOptions.KeepDocked=="ON" then
			TrinketMenu.DockWindows()
		end
	elseif TrinketMenuOptions.Locked=="OFF" then
		if TrinketMenuPerOptions.MenuOrient=="VERTICAL" then
			TrinketMenuPerOptions.MenuOrient="HORIZONTAL"
		else
			TrinketMenuPerOptions.MenuOrient="VERTICAL"
		end
		TrinketMenu.BuildMenu()
	end
end

function TrinketMenu.DockingMenu()

	local main = TrinketMenu_MainFrame
	local menu = TrinketMenu_MenuFrame
	local mainscale = TrinketMenu_MainFrame:GetScale()
	local menuscale = TrinketMenu_MenuFrame:GetScale()
	local near = TrinketMenu.Near

	if near(main:GetRight()*mainscale,menu:GetLeft()*menuscale) then
		if near(main:GetTop()*mainscale,menu:GetTop()*menuscale) then
			TrinketMenuPerOptions.MainDock = "TOPRIGHT"
			TrinketMenuPerOptions.MenuDock = "TOPLEFT"
		elseif near(main:GetBottom()*mainscale,menu:GetBottom()*menuscale) then
			TrinketMenuPerOptions.MainDock = "BOTTOMRIGHT"
			TrinketMenuPerOptions.MenuDock = "BOTTOMLEFT"
		end
	elseif near(main:GetLeft()*mainscale,menu:GetRight()*menuscale) then
		if near(main:GetTop()*mainscale,menu:GetTop()*menuscale) then
			TrinketMenuPerOptions.MainDock = "TOPLEFT"
			TrinketMenuPerOptions.MenuDock = "TOPRIGHT"
		elseif near(main:GetBottom()*mainscale,menu:GetBottom()*menuscale) then
			TrinketMenuPerOptions.MainDock = "BOTTOMLEFT"
			TrinketMenuPerOptions.MenuDock = "BOTTOMRIGHT"
		end
	elseif near(main:GetRight()*mainscale,menu:GetRight()*menuscale) then
		if near(main:GetTop()*mainscale,menu:GetBottom()*menuscale) then
			TrinketMenuPerOptions.MainDock = "TOPRIGHT"
			TrinketMenuPerOptions.MenuDock = "BOTTOMRIGHT"
		elseif near(main:GetBottom()*mainscale,menu:GetTop()*menuscale) then
			TrinketMenuPerOptions.MainDock = "BOTTOMRIGHT"
			TrinketMenuPerOptions.MenuDock = "TOPRIGHT"
		end
	elseif near(main:GetLeft()*mainscale,menu:GetLeft()*menuscale) then
		if near(main:GetTop()*mainscale,menu:GetBottom()*menuscale) then
			TrinketMenuPerOptions.MainDock = "TOPLEFT"
			TrinketMenuPerOptions.MenuDock = "BOTTOMLEFT"
		elseif near(main:GetBottom()*mainscale,menu:GetTop()*menuscale) then
			TrinketMenuPerOptions.MainDock = "BOTTOMLEFT"
			TrinketMenuPerOptions.MenuDock = "TOPLEFT"
		end
	end
	TrinketMenu.ClearDocking()
	_G["TrinketMenu_MainDock_"..TrinketMenuPerOptions.MainDock]:Show()
	_G["TrinketMenu_MenuDock_"..TrinketMenuPerOptions.MenuDock]:Show()
end

function TrinketMenu.MenuMouseover()
	if (not MouseIsOver(TrinketMenu_MainFrame)) and (not MouseIsOver(TrinketMenu_MenuFrame)) and not IsShiftKeyDown() and (TrinketMenuOptions.KeepOpen=="OFF") and not TrinketMenu.IsTimerActive("Scaling") then
		TrinketMenu.StopTimer("MenuMouseover")
		TrinketMenu_MenuFrame:Hide()
	end
end

--[[ Scaling ]]

function TrinketMenu.StartScaling()
	if arg1=="LeftButton" and TrinketMenuOptions.Locked=="OFF" then
		this:LockHighlight()
		TrinketMenu.FrameToScale = this:GetParent()
		TrinketMenu.ScalingWidth = this:GetParent():GetWidth()
		TrinketMenu.StartTimer("Scaling")
	end
end

function TrinketMenu.StopScaling()
	if arg1=="LeftButton" then
		TrinketMenu.StopTimer("Scaling")
		TrinketMenu.FrameToScale = nil
		this:UnlockHighlight()
		if this:GetParent():GetName() == "TrinketMenu_MainFrame" then
			TrinketMenuPerOptions.MainScale = TrinketMenu_MainFrame:GetScale()
		else
			TrinketMenuPerOptions.MenuScale = TrinketMenu_MenuFrame:GetScale()
		end
	end
end

function TrinketMenu.ScaleFrame(scale)
	local frame = TrinketMenu.FrameToScale
	local oldscale = frame:GetScale() or 1
	local framex = (frame:GetLeft() or TrinketMenuPerOptions.XPos)* oldscale
	local framey = (frame:GetTop() or TrinketMenuPerOptions.YPos)* oldscale

	frame:SetScale(scale)
	if frame:GetName() == "TrinketMenu_MainFrame" then
		TrinketMenu_MainFrame:SetPoint("TOPLEFT","UIParent","BOTTOMLEFT",framex/scale,framey/scale)
		TrinketMenuPerOptions.XPos = TrinketMenu_MainFrame:GetLeft()
		TrinketMenuPerOptions.YPos = TrinketMenu_MainFrame:GetTop()
	elseif TrinketMenuOptions.KeepDocked=="OFF" then
		TrinketMenu_MenuFrame:ClearAllPoints()
		TrinketMenu_MenuFrame:SetPoint("TOPLEFT","UIParent","BOTTOMLEFT",framex/scale,framey/scale)
	end
end

function TrinketMenu.Scaling()
	local frame = TrinketMenu.FrameToScale
	local oldscale = frame:GetEffectiveScale()
	local framex, framey, cursorx, cursory = frame:GetLeft()*oldscale, frame:GetTop()*oldscale, GetCursorPosition()
	if (cursorx-framex)>32 then
		local newscale = (cursorx-framex)/TrinketMenu.ScalingWidth
		TrinketMenu.ScaleFrame(newscale)
	end
end

--[[ Cooldowns ]]

function TrinketMenu.UpdateWornCooldowns(maybeGlobal)
	local start,duration,enable = GetInventoryItemCooldown("player",13)
	CooldownFrame_SetTimer(TrinketMenu_Trinket0Cooldown,start,duration,enable)
	start,duration,enable = GetInventoryItemCooldown("player",14)
	CooldownFrame_SetTimer(TrinketMenu_Trinket1Cooldown,start,duration,enable)
	if not maybeGlobal then
		TrinketMenu.WriteWornCooldowns()
	end
end

function TrinketMenu.UpdateMenuCooldowns()
	local start,duration,enable
	for i=1,TrinketMenu.NumberOfTrinkets do
		start,duration,enable = GetContainerItemCooldown(TrinketMenu.BaggedTrinkets[i].bag,TrinketMenu.BaggedTrinkets[i].slot)
		CooldownFrame_SetTimer(TrinketMenu.MenuCDFrames[i],start,duration,enable)
	end
	TrinketMenu.WriteMenuCooldowns()
end

--[[ Item use ]]

function TrinketMenu.ReflectTrinketUse(slot)
	_G["TrinketMenu_Trinket"..(slot-13)]:SetChecked(1)
	TrinketMenu.StartTimer("UpdateWornTrinkets")
	local _,_,id,trinket = string.find(GetInventoryItemLink("player",slot) or "","item:(%d+).+%[(.+)%]")
	if trinket then
		TrinketMenuPerOptions.ItemsUsed[trinket] = 0 -- 0 is an indeterminate state, cooldown will figure if it's worth watching
		TrinketMenu.AddWatchItem(trinket,nil,nil,nil,id)
	end
end

function TrinketMenu.newUseInventoryItem(slot)
	if (slot==13 or slot==14) and not MerchantFrame:IsVisible() then
		TrinketMenu.ReflectTrinketUse(slot)
	end
	TrinketMenu.oldUseInventoryItem(slot)
end

function TrinketMenu.newUseAction(slot,cursor,self)
	-- When Nampower is available, SPELL_CAST_EVENT handles trinket use detection
	-- Skip the expensive tooltip scan entirely
	if not TrinketMenu.hasNampower and IsEquippedAction(slot) then
		local trinket0 = TrinketMenu.EquippedTrinketName[13]
		local trinket1 = TrinketMenu.EquippedTrinketName[14]
		if trinket0 or trinket1 then
			TrinketMenu_TooltipScan:SetOwner(UIParent, "ANCHOR_NONE")
			TrinketMenu_TooltipScan:SetAction(slot)
			local tipText = TrinketMenu_TooltipScanTextLeft1 and TrinketMenu_TooltipScanTextLeft1:GetText()
			if tipText and tipText==trinket0 then
				TrinketMenu.ReflectTrinketUse(13)
			elseif tipText and tipText==trinket1 then
				TrinketMenu.ReflectTrinketUse(14)
			end
		end
	end
	TrinketMenu.oldUseAction(slot,cursor,self)
end

--[[ Tooltips ]]

function TrinketMenu.WornTrinketTooltip()
	local id = this:GetID()
	if TrinketMenu.IsTimerActive("Scaling") or TrinketMenuOptions.ShowTooltips=="OFF" then
		return
	end
	TrinketMenu.TooltipOwner = this
	TrinketMenu.TooltipType = "INVENTORY"
	TrinketMenu.TooltipSlot = id
	TrinketMenu.TooltipBag = TrinketMenu.CombatQueue[id-13]
	TrinketMenu.StartTimer("TooltipUpdate",0)
end

function TrinketMenu.MenuTrinketTooltip()
	local id = this:GetID()
	if TrinketMenu.IsTimerActive("Scaling") or TrinketMenuOptions.ShowTooltips=="OFF" then
		return
	end
	TrinketMenu.TooltipOwner = this
	TrinketMenu.TooltipType = "BAG"
	TrinketMenu.TooltipBag = TrinketMenu.BaggedTrinkets[id].bag
	TrinketMenu.TooltipSlot = TrinketMenu.BaggedTrinkets[id].slot
	TrinketMenu.TooltipDupeCount = TrinketMenu.BaggedTrinkets[id].dupeCount
	TrinketMenu.StartTimer("TooltipUpdate",0)
end

function TrinketMenu.ClearTooltip()
	GameTooltip:Hide()
	TrinketMenu.StopTimer("TooltipUpdate")
	TrinketMenu.TooltipType = nil
	TrinketMenu.TooltipDupeCount = nil
end

function TrinketMenu.AnchorTooltip(owner)
	owner = owner or this
	if TrinketMenuOptions.TooltipFollow=="ON" then
		if owner.GetLeft and owner:GetLeft() and owner:GetLeft()<400 then
			GameTooltip:SetOwner(owner,"ANCHOR_RIGHT")
		else
			GameTooltip:SetOwner(owner,"ANCHOR_LEFT")
		end
	else
		GameTooltip_SetDefaultAnchor(GameTooltip,owner)
	end
end

-- updates the tooltip created in the functions above
function TrinketMenu.TooltipUpdate()
	if TrinketMenu.TooltipType then
		local cooldown
		TrinketMenu.AnchorTooltip(TrinketMenu.TooltipOwner)
		if TrinketMenu.TooltipType=="BAG" then
			GameTooltip:SetBagItem(TrinketMenu.TooltipBag,TrinketMenu.TooltipSlot)
			cooldown = GetContainerItemCooldown(TrinketMenu.TooltipBag,TrinketMenu.TooltipSlot)
		else
			GameTooltip:SetInventoryItem("player",TrinketMenu.TooltipSlot)
			cooldown = GetInventoryItemCooldown("player",TrinketMenu.TooltipSlot)
		end
		TrinketMenu.ShrinkTooltip(TrinketMenu.TooltipOwner) -- if TinyTooltips on, shrink it
		if TrinketMenu.TooltipType=="INVENTORY" and TrinketMenu.TooltipBag then
			GameTooltip:AddLine("Queued: "..TrinketMenu.TooltipBag)
		end
		if TrinketMenu.TooltipType=="BAG" and TrinketMenu.TooltipDupeCount and TrinketMenu.TooltipDupeCount>1 then
			GameTooltip:AddLine("You have "..TrinketMenu.TooltipDupeCount.." copies - Priority/Delay apply to all of them",.6,.6,.6)
		end
		GameTooltip:Show()
		if cooldown==0 then
			-- stop updates if this trinket has no cooldown
			TrinketMenu.TooltipType = nil
			TrinketMenu.StopTimer("TooltipUpdate")
		end
	end

end

-- normal tooltip for options
function TrinketMenu.OnTooltip(line1,line2)
	if TrinketMenuOptions.ShowTooltips=="ON" then
		TrinketMenu.AnchorTooltip()
		if line1 then
			GameTooltip:AddLine(line1)
			GameTooltip:AddLine(line2,.8,.8,.8,1)
			GameTooltip:Show()
		else
			local name = this:GetName() or ""
			for i=1,table.getn(TrinketMenu.CheckOptInfo) do
				if name=="TrinketMenu_Opt"..TrinketMenu.CheckOptInfo[i][1] and TrinketMenu.CheckOptInfo[i][3] then
					TrinketMenu.OnTooltip(TrinketMenu.CheckOptInfo[i][3],TrinketMenu.CheckOptInfo[i][4])
				end
			end
			for i=1,table.getn(TrinketMenu.TooltipInfo) do
				if TrinketMenu.TooltipInfo[i][1]==name and TrinketMenu.TooltipInfo[i][2] then
					TrinketMenu.OnTooltip(TrinketMenu.TooltipInfo[i][2],TrinketMenu.TooltipInfo[i][3])
				end
			end
		end
	end
end

-- strip format reordering in global strings
TrinketMenu.ITEM_SPELL_CHARGES = string.gsub(ITEM_SPELL_CHARGES,"%%%d%$d","%%d")
TrinketMenu.ITEM_SPELL_CHARGES_P1 = string.gsub(ITEM_SPELL_CHARGES_P1,"%%%d%$d","%%d")

function TrinketMenu.ShrinkTooltip(owner)
	if TrinketMenuOptions.TinyTooltips=="ON" then
		local r,g,b = GameTooltipTextLeft1:GetTextColor()
		local name = GameTooltipTextLeft1:GetText()
		local line,cooldown,charge
		for i=2,12 do
			line = _G["GameTooltipTextLeft"..i]
			if line:IsVisible() then
				line = line:GetText() or ""
				if string.find(line,COOLDOWN_REMAINING) then
					cooldown = line
				end
				if string.find(line,TrinketMenu.ITEM_SPELL_CHARGES_P1) or string.find(line,TrinketMenu.ITEM_SPELL_CHARGES) then
					charge = line
				end
			end
		end
		TrinketMenu.AnchorTooltip(owner or this)
		GameTooltip:AddLine(name,r,g,b)
		GameTooltip:AddLine(charge,1,1,1)
		GameTooltip:AddLine(cooldown,1,1,1)
	end
end

--[[ Combat Queue ]]

function TrinketMenu.EquipTrinketByName(name,slot)
	if not name then return end
	if UnitAffectingCombat("player") or TrinketMenu.IsPlayerReallyDead() then
		-- queue trinket
		local queue = TrinketMenu.CombatQueue
		local which = slot-13 -- 0 or 1
		if queue[which]==name then
			queue[which] = nil
		elseif queue[1-which]==name then
			queue[1-which] = nil
			queue[which] = name
		else
			queue[which] = name
		end
	elseif not CursorHasItem() and not SpellIsTargeting() then
		local _,b,s = TrinketMenu.FindItem(name)
		if b then
			local _,_,isLocked = GetContainerItemInfo(b,s)
			if not isLocked and not IsInventoryItemLocked(slot) then
				-- neither container item nor inventory item locked, perform swap
				PickupContainerItem(b,s)
				PickupInventoryItem(slot)
				_G["TrinketMenu_Trinket"..(slot-13).."Icon"]:SetDesaturated(1)
				TrinketMenu.StartTimer("UpdateWornTrinkets") -- in case it's not equipped (stunned, etc)
			end
		end
	end
	TrinketMenu.UpdateCombatQueue()
end	

function TrinketMenu.UpdateCombatQueue()
	local bag,slot
	for which=0,1 do
		local trinket = TrinketMenu.CombatQueue[which]
		local icon = TrinketMenu.QueueIcons[which]
		icon:Hide()
		if trinket then
			_,bag,slot = TrinketMenu.FindItem(trinket)
			if bag then
				local tex = GetContainerItemInfo(bag,slot)
				icon:SetTexture(tex)
				icon:Show()
			end
		elseif TrinketMenu.QueueInit and TrinketMenuQueue and TrinketMenuQueue.Enabled[which] then
			icon:SetTexture("Interface\\AddOns\\TrinketMenu\\TrinketMenu-Gear")
			icon:Show()
		end
	end
end

--[[ Notify ]]

function TrinketMenu.Notify(msg)
	PlaySound("GnomeExploration")
	if SCT_Display then -- send via SCT if it exists
		SCT_Display(msg,{r=.2,g=.7,b=.9})
	elseif SHOW_COMBAT_TEXT=="1" then
		CombatText_AddMessage(msg, CombatText_StandardScroll, .2, .7, .9) -- or default UI's SCT
	else
		-- send vis UIErrorsFrame if neither SCT exists
		UIErrorsFrame:AddMessage(msg,.2,.7,.9,1,UIERRORS_HOLD_TIME)
	end
	if TrinketMenuOptions.NotifyChatAlso=="ON" then
		DEFAULT_CHAT_FRAME:AddMessage("|cff33b2e5"..msg)
	end
	if TrinketMenu.hasUnitXP then
		-- UnitXP SP3's "notify" calls only do anything while the game window
		-- is in the background, so it's safe to always fire alongside the
		-- normal in-game notice above.
		pcall(UnitXP,"notify","taskbarIcon")
		pcall(UnitXP,"notify","systemSound")
	end
end

-- adds location of the name to a watch table for fast lookups
-- pass inv bag slot to override the search, id to cache item ID for Nampower
function TrinketMenu.AddWatchItem(name,inv,bag,slot,id)
	TrinketMenu.WatchItem[name] = TrinketMenu.WatchItem[name] or {}
	if id then
		TrinketMenu.WatchItem[name].id = id
	end
	if not inv and not bag then
		inv = TrinketMenu.WatchItem[name].inv
		bag = TrinketMenu.WatchItem[name].bag
		slot = TrinketMenu.WatchItem[name].slot
		if not string.find((inv and (GetInventoryItemLink("player",inv) or "")) or (bag and (GetContainerItemLink(bag,slot) or "")) or "",name,1,1) then
			inv,bag,slot = TrinketMenu.FindItem(name,1)
		end
	end
	TrinketMenu.WatchItem[name].inv = inv
	TrinketMenu.WatchItem[name].bag = bag
	TrinketMenu.WatchItem[name].slot = slot
end

-- ClassicAPI itemID-based cooldown lookup. Returns (start,duration) in the
-- same shape GetContainerItemCooldown/GetInventoryItemCooldown use, or nil
-- if ClassicAPI's cooldown call isn't available.
function TrinketMenu.ClassicItemCooldown(itemID)
	if not TrinketMenu.hasClassicItemCooldown or not itemID then return nil end
	local start,duration
	if type(C_Container) == "table" and type(C_Container.GetItemCooldown) == "function" then
		start,duration = C_Container.GetItemCooldown(tonumber(itemID))
	else
		start,duration = GetItemCooldown(tonumber(itemID))
	end
	return start,duration
end

function TrinketMenu.CooldownUpdate()
	local inv,bag,slot,start,duration,name,remain
	local watch = TrinketMenu.WatchItem
	local hasIdCD = TrinketMenu.hasGetItemIdCooldown
	for i in TrinketMenuPerOptions.ItemsUsed do
		start,remain = nil,nil
		if not watch[i] then TrinketMenu.AddWatchItem(i) end -- if not on watch table, add it

		if hasIdCD and watch[i] and watch[i].id then
			-- Nampower fast path: use item ID directly, skip bag/slot tracking
			local cd = GetItemIdCooldown(tonumber(watch[i].id))
			if type(cd) == "table" then
				if cd.isOnCooldown == 1 then
					start = 1
					remain = cd.cooldownRemainingMs / 1000
				else
					start = 0
				end
			else
				TrinketMenuPerOptions.ItemsUsed[i] = nil
			end
		elseif TrinketMenu.hasClassicItemCooldown and watch[i] and watch[i].id then
			-- ClassicAPI fast path: itemID-based cooldown, same advantage as
			-- Nampower (no bag/slot re-tracking needed) via GetItemCooldown
			local cdStart,cdDuration = TrinketMenu.ClassicItemCooldown(watch[i].id)
			if cdStart and cdStart>0 then
				start,duration = cdStart,cdDuration
			elseif cdStart==0 then
				start = 0
			else
				TrinketMenuPerOptions.ItemsUsed[i] = nil
			end
		else
			-- Vanilla fallback: track bag/slot positions
			name = nil
			inv,bag,slot = watch[i].inv,watch[i].bag,watch[i].slot
			if inv then -- if it was last seen in an inv slot, get name in that slot
				_,_,name = string.find(GetInventoryItemLink("player",inv) or "","%[(.+)%]")
			end
			if bag then -- if it was last seen in a container slot, get name in that slot
				_,_,name = string.find(GetContainerItemLink(bag,slot) or "","%[(.+)%]")
			end
			if name~=i then -- item has moved
				inv,bag,slot = TrinketMenu.FindItem(i,1)
				watch[i].inv,watch[i].bag,watch[i].slot = inv,bag,slot
			end
			if inv then
				start,duration = GetInventoryItemCooldown("player",inv)
			elseif bag then
				start,duration = GetContainerItemCooldown(bag,slot)
			else
				TrinketMenuPerOptions.ItemsUsed[i] = nil
			end
		end

		if start and TrinketMenuPerOptions.ItemsUsed[i]<3 then
			TrinketMenuPerOptions.ItemsUsed[i] = TrinketMenuPerOptions.ItemsUsed[i] + 1 -- count for 3 seconds before seeing if this is a real cooldown
		elseif start then
			if start>0 then
				remain = remain or duration - (GetTime()-start)
				if TrinketMenuPerOptions.ItemsUsed[i]<5 then
					if remain>29 then
						TrinketMenuPerOptions.ItemsUsed[i] = 30 -- first actual cooldown greater than 30 seconds, tag it for 30+0 notify
					elseif remain>5 then
						TrinketMenuPerOptions.ItemsUsed[i] = 5 -- first actual cooldown less than 30 but greater than 5, tag for 0 notify
					end
				end
			end
			if TrinketMenuPerOptions.ItemsUsed[i]==30 and start>0 and remain<30 then
				if TrinketMenuOptions.NotifyThirty=="ON" then
					TrinketMenu.Notify(i.." ready soon!")
				end
				TrinketMenuPerOptions.ItemsUsed[i]=5 -- tag for just 0 notify now
			elseif TrinketMenuPerOptions.ItemsUsed[i]==5 and start==0 then
				if TrinketMenuOptions.Notify=="ON" then
					TrinketMenu.Notify(i.." ready!")
				end
			end
			if start==0 then
				TrinketMenuPerOptions.ItemsUsed[i] = nil
			end
		end
	end

	-- update cooldown numbers
	if TrinketMenuOptions.CooldownCount=="ON" then
		if TrinketMenu_MainFrame:IsVisible() then
			TrinketMenu.WriteWornCooldowns()
		end
		if TrinketMenu_MenuFrame:IsVisible() then
			TrinketMenu.WriteMenuCooldowns()
		end
	end

	if TrinketMenu.PeriodicQueueCheck then
		TrinketMenu.PeriodicQueueCheck()
	end
end

function TrinketMenu.WriteWornCooldowns()
	if TrinketMenu.hasNampower then
		local now = GetTime()
		for i=0,1 do
			local cd = GetTrinketCooldown(i+1)
			if type(cd) == "table" and cd.isOnCooldown == 1 then
				TrinketMenu.WriteCooldown(_G["TrinketMenu_Trinket"..i.."Time"], now, cd.cooldownRemainingMs / 1000)
			else
				TrinketMenu.WriteCooldown(_G["TrinketMenu_Trinket"..i.."Time"], 0, 0)
			end
		end
	else
		local start, duration
		start, duration = GetInventoryItemCooldown("player",13)
		TrinketMenu.WriteCooldown(TrinketMenu_Trinket0Time,start,duration)
		start, duration = GetInventoryItemCooldown("player",14)
		TrinketMenu.WriteCooldown(TrinketMenu_Trinket1Time,start,duration)
	end
end

function TrinketMenu.WriteMenuCooldowns()
	local start, duration
	if TrinketMenu.hasGetItemIdCooldown then
		local now = GetTime()
		for i=1,TrinketMenu.NumberOfTrinkets do
			local id = TrinketMenu.BaggedTrinkets[i].id
			if id then
				local cd = GetItemIdCooldown(tonumber(id))
				if type(cd) == "table" and cd.isOnCooldown == 1 then
					TrinketMenu.WriteCooldown(TrinketMenu.MenuTimeFrames[i], now, cd.cooldownRemainingMs / 1000)
				else
					TrinketMenu.WriteCooldown(TrinketMenu.MenuTimeFrames[i], 0, 0)
				end
			else
				start, duration = GetContainerItemCooldown(TrinketMenu.BaggedTrinkets[i].bag, TrinketMenu.BaggedTrinkets[i].slot)
				TrinketMenu.WriteCooldown(TrinketMenu.MenuTimeFrames[i], start, duration)
			end
		end
	elseif TrinketMenu.hasClassicItemCooldown then
		-- ClassicAPI fast path: same itemID-based lookup, no Nampower needed
		for i=1,TrinketMenu.NumberOfTrinkets do
			start,duration = nil,nil
			local id = TrinketMenu.BaggedTrinkets[i].id
			if id then
				start,duration = TrinketMenu.ClassicItemCooldown(id)
			end
			if not start then
				start, duration = GetContainerItemCooldown(TrinketMenu.BaggedTrinkets[i].bag, TrinketMenu.BaggedTrinkets[i].slot)
			end
			TrinketMenu.WriteCooldown(TrinketMenu.MenuTimeFrames[i], start, duration)
		end
	else
		for i=1,TrinketMenu.NumberOfTrinkets do
			start, duration = GetContainerItemCooldown(TrinketMenu.BaggedTrinkets[i].bag,TrinketMenu.BaggedTrinkets[i].slot)
			TrinketMenu.WriteCooldown(TrinketMenu.MenuTimeFrames[i],start,duration)
		end
	end
end

function TrinketMenu.WriteCooldown(where,start,duration)
	local cooldown = duration - (GetTime()-start)
	if start==0 or TrinketMenuOptions.CooldownCount=="OFF" then
		if where.lastCDText then
			where:SetText("")
			where.lastCDText = nil
		end
	elseif cooldown<3 and not where.lastCDText then
		-- this is a global cooldown. don't display it. not accurate but at least not annoying
	else
		local text
		if cooldown<60 then
			text = math.floor(cooldown+.5).." s"
		elseif cooldown<3600 then
			text = math.ceil(cooldown/60).." m"
		else
			text = math.ceil(cooldown/3600).." h"
		end
		if text ~= where.lastCDText then
			where:SetText(text)
			where.lastCDText = text
		end
	end
end

function TrinketMenu.OnShow()
	TrinketMenuPerOptions.Visible = "ON"
	if TrinketMenuOptions.KeepOpen=="ON" then
		TrinketMenu.BuildMenu()
	end
end

function TrinketMenu.OnHide()
	TrinketMenuPerOptions.Visible = "OFF"
	TrinketMenu_MenuFrame:Hide()
end

--[[ Key bindings ]]

function TrinketMenu.ReflectKeyBindings()
	if TrinketMenuOptions.ShowHotKeys=="ON" then
		TrinketMenu_Trinket0HotKey:SetText(GetBindingText(GetBindingKey("Use Top Trinket"),"KEY_",1))
		TrinketMenu_Trinket1HotKey:SetText(GetBindingText(GetBindingKey("Use Bottom Trinket"),"KEY_",1))
	else
		TrinketMenu_Trinket0HotKey:SetText("")
		TrinketMenu_Trinket1HotKey:SetText("")
	end
end
