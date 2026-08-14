local httpService = game:GetService("HttpService")

local SaveManager = {} do
	SaveManager.Folder = "FluentSettings"
	SaveManager.Ignore = {}
	SaveManager.Parser = {
		Toggle = {
			Save = function(idx, object)
				local data = { type = "Toggle", idx = idx, value = object.Value }
				-- object.Input only exists if Config.Input was passed to
				-- AddToggle (HookConnectedInput sets it). The actual text
				-- lives in object.InputValue, not object.Input.Value.
				if object.Input then
					data.input = object.InputValue
				end
				return data
			end,
			Load = function(idx, data)
				local option = SaveManager.Options[idx]
				if not option then return end

				option:SetValue(data.value)

				if data.input ~= nil and option.SetInputValue then
					option:SetInputValue(data.input)
				end
			end,
		},
		Button = {
			Save = function(idx, object)
				-- Buttons carry no state of their own. Only worth saving if
				-- Config.Input was attached (HookConnectedInput ran), which
				-- gives it .InputValue / :SetInputValue same as Toggle.
				if not object.Input then return nil end
				return { type = "Button", idx = idx, input = object.InputValue }
			end,
			Load = function(idx, data)
				local option = SaveManager.Options[idx]
				if option and option.SetInputValue and data.input ~= nil then
					option:SetInputValue(data.input)
				end
			end,
		},
		Slider = {
			Save = function(idx, object)
				return { type = "Slider", idx = idx, value = tostring(object.Value) }
			end,
			Load = function(idx, data)
				if SaveManager.Options[idx] then 
					SaveManager.Options[idx]:SetValue(data.value)
				end
			end,
		},
		Dropdown = {
			Save = function(idx, object)
				return { type = "Dropdown", idx = idx, value = object.Value, mutli = object.Multi }
			end,
			Load = function(idx, data)
				if SaveManager.Options[idx] then 
					SaveManager.Options[idx]:SetValue(data.value)
				end
			end,
		},
		-- Priority stores a { [entryName] = number } map, not a scalar. Element:SetValue merges it
		-- over the current entries (unknown names dropped, missing ones left at their default), so
		-- a config saved before an entry was added or removed still restores cleanly.
		Priority = {
			Save = function(idx, object)
				local value = {}
				for name, number in pairs(object.Value or {}) do
					value[tostring(name)] = number
				end
				return { type = "Priority", idx = idx, value = value }
			end,
			Load = function(idx, data)
				if SaveManager.Options[idx] and type(data.value) == "table" then
					SaveManager.Options[idx]:SetValue(data.value)
				end
			end,
		},
		Colorpicker = {
			Save = function(idx, object)
				return { type = "Colorpicker", idx = idx, value = object.Value:ToHex(), transparency = object.Transparency }
			end,
			Load = function(idx, data)
				if SaveManager.Options[idx] then 
					SaveManager.Options[idx]:SetValueRGB(Color3.fromHex(data.value), data.transparency)
				end
			end,
		},
		Keybind = {
			Save = function(idx, object)
				return { type = "Keybind", idx = idx, mode = object.Mode, key = object.Value }
			end,
			Load = function(idx, data)
				if SaveManager.Options[idx] then 
					SaveManager.Options[idx]:SetValue(data.key, data.mode)
				end
			end,
		},
		Input = {
			Save = function(idx, object)
				return { type = "Input", idx = idx, text = object.Value }
			end,
			Load = function(idx, data)
				if SaveManager.Options[idx] and type(data.text) == "string" then
					SaveManager.Options[idx]:SetValue(data.text)
				end
			end,
		},
		Section = {
			Save = function(idx, object)
				-- Sections only expose their collapsed state through
				-- :IsCollapsed() (no plain .Value field like other
				-- elements), so pull it through that instead. Guarded with
				-- pcall in case a caller's build of Fluentv2 predates
				-- Section:IsCollapsed/SetValue - saving just skips it then,
				-- same as any other element type it doesn't recognize.
				local ok, collapsed = pcall(function() return object:IsCollapsed() end)
				if not ok then return nil end
				return { type = "Section", idx = idx, value = collapsed }
			end,
			Load = function(idx, data)
				local option = SaveManager.Options[idx]
				if not option then return end

				if option.SetValue then
					option:SetValue(data.value)
				elseif option.SetCollapsed then
					-- Fallback for older Fluentv2 builds that have
					-- Section:SetCollapsed but not the SetValue wrapper.
					option:SetCollapsed(data.value, true)
				end
			end,
		},
	}

	-- When true, settings/autoload/autosave all live under a per-account
	-- subfolder (keyed by LocalPlayer.UserId) instead of directly under
	-- "<Folder>/settings", so each Roblox account on the same PC gets its
	-- own configs instead of overwriting a shared one. Off by default to
	-- keep existing scripts' behavior unchanged; opt in with SetPerAccount(true).
	SaveManager.PerAccount = false

	-- Auto Save state
	SaveManager.AutoSaveDelay = 1 -- seconds between autosave diff-checks
	SaveManager.AutoSaveConfigName = "autosave" -- bootstrap config used only if no config has ever been active
	SaveManager.CurrentConfig = nil -- name of the config autosave currently targets; follows Load/Save
	SaveManager._loading = false
	SaveManager._autoSaveLoopStarted = false
	SaveManager._lastAutoSaveSnapshot = nil

	function SaveManager:SetIgnoreIndexes(list)
		for _, key in next, list do
			self.Ignore[key] = true
		end
	end

	function SaveManager:SetFolder(folder)
		self.Folder = folder
		self:BuildFolderTree()
	end

	-- Opt-in: isolate settings/autoload/autosave per Roblox account
	-- (keyed by LocalPlayer.UserId) instead of sharing one config set
	-- across every account that runs the script on this PC.
	function SaveManager:SetPerAccount(enabled)
		self.PerAccount = enabled
		self:BuildFolderTree()
	end

	function SaveManager:GetSettingsFolder()
		if self.PerAccount then
			local player = game:GetService("Players").LocalPlayer
			local id = (player and tostring(player.UserId)) or "unknown"
			return self.Folder .. "/settings/" .. id
		end
		return self.Folder .. "/settings"
	end

	function SaveManager:Encode()
		local data = { objects = {} }

		for idx, option in next, SaveManager.Options do
			if not self.Parser[option.Type] then continue end
			if self.Ignore[idx] then continue end

			local entry = self.Parser[option.Type].Save(idx, option)
			if entry then
				table.insert(data.objects, entry)
			end
		end

		local success, encoded = pcall(httpService.JSONEncode, httpService, data)
		if not success then
			return false, "failed to encode data"
		end

		return true, encoded
	end

	function SaveManager:Save(name)
		if not name then
			return false, "no config file is selected"
		end

		local success, encoded = self:Encode()
		if not success then
			return false, encoded
		end

		local fullPath = self:GetSettingsFolder() .. "/" .. name .. ".json"
		writefile(fullPath, encoded)

		if self.CurrentConfig ~= name then
			self.CurrentConfig = name
			self:SyncAutoloadToCurrent()
		end

		return true
	end

	function SaveManager:Load(name)
		if not name then
			return false, "no config file is selected"
		end
		
		local file = self:GetSettingsFolder() .. "/" .. name .. ".json"
		if not isfile(file) then return false, "invalid file" end

		local success, decoded = pcall(httpService.JSONDecode, httpService, readfile(file))
		if not success then return false, "decode error" end

		-- suppress autosave while options are being mass-updated from the file
		self._loading = true

		for _, option in next, decoded.objects do
			if self.Parser[option.type] then
				task.spawn(function() self.Parser[option.type].Load(option.idx, option) end)
			end
		end

		task.defer(function()
			self._loading = false
		end)

		self.CurrentConfig = name
		self:SyncAutoloadToCurrent()

		return true
	end

	function SaveManager:IgnoreThemeSettings()
		self:SetIgnoreIndexes({ 
			"InterfaceTheme", "AcrylicToggle", "TransparentToggle", "MenuKeybind"
		})
	end

	function SaveManager:BuildFolderTree()
		local paths = {
			self.Folder,
			self.Folder .. "/settings",
		}

		if self.PerAccount then
			table.insert(paths, self:GetSettingsFolder())
		end

		for i = 1, #paths do
			local str = paths[i]
			if not isfolder(str) then
				makefolder(str)
			end
		end
	end

	function SaveManager:RefreshConfigList()
		local list = listfiles(self:GetSettingsFolder())

		local out = {}
		for i = 1, #list do
			local file = list[i]
			if file:sub(-5) == ".json" then
				local pos = file:find(".json", 1, true)
				local start = pos

				local char = file:sub(pos, pos)
				while char ~= "/" and char ~= "\\" and char ~= "" do
					pos = pos - 1
					char = file:sub(pos, pos)
				end

				if char == "/" or char == "\\" then
					local name = file:sub(pos + 1, start - 1)
					if name ~= "options" then
						table.insert(out, name)
					end
				end
			end
		end
		
		return out
	end

	function SaveManager:SetLibrary(library)
		self.Library = library
		self.Options = library.Options
	end

	-- === Import / Export ===
	--
	-- The exported payload is exactly what a config file on disk holds
	-- ({ objects = { ... } }), NOT a wrapper around it. That keeps the round
	-- trip honest in both directions: what Export copies can be dropped
	-- straight into the settings folder as a .json, and any config file
	-- already sitting in that folder can be pasted into Import.

	-- Strips what an executor's writefile will not take - control characters,
	-- the Windows-reserved set, and the path separators that would otherwise
	-- let an imported name write outside the settings folder entirely.
	function SaveManager:SanitizeName(name)
		name = tostring(name or "")
		name = name:gsub("%c", "")
		name = name:gsub('[<>:"/\\|%?%*]', "")
		name = name:gsub("^%s+", "")
		name = name:gsub("%s+$", "")
		return name:sub(1, 64)
	end

	-- `name` = a config in the settings folder, or nil/"" for "whatever is set
	-- on screen right now". Returns the JSON string, or false + a reason.
	function SaveManager:ExportString(name)
		if name and name ~= "" then
			local file = self:GetSettingsFolder() .. "/" .. name .. ".json"
			if not isfile(file) then
				return false, "config file not found"
			end

			local success, data = pcall(readfile, file)
			if not success or type(data) ~= "string" or data == "" then
				return false, "could not read config file"
			end

			return data
		end

		local success, encoded = self:Encode()
		if not success then
			return false, encoded
		end

		return encoded
	end

	-- Checks a pasted string is really a config and hands back a clean,
	-- re-encoded copy of it plus how many settings it carries (or false + a
	-- reason). Kept separate from ImportString so a caller can validate a paste
	-- without writing anything to disk.
	function SaveManager:ValidateImport(text)
		if type(text) ~= "string" then
			return false, "nothing to import"
		end

		text = text:gsub("^%s+", ""):gsub("%s+$", "")
		if text == "" then
			return false, "nothing to import"
		end

		local success, decoded = pcall(httpService.JSONDecode, httpService, text)
		if not success or type(decoded) ~= "table" then
			return false, "that is not valid config JSON"
		end

		-- Tolerate a payload that merely CONTAINS a config (someone pasting a
		-- wrapper object around it) as well as the config itself.
		if type(decoded.objects) ~= "table" and type(decoded.config) == "table" then
			decoded = decoded.config
		end

		if type(decoded.objects) ~= "table" then
			return false, "no settings found in that JSON"
		end

		-- Keep only entries that could actually be replayed. A config exported
		-- from a different script - or by a newer build with element types this
		-- one has never heard of - then imports cleanly minus the parts that do
		-- not apply, rather than failing outright or writing junk to disk. The
		-- Load path already skips unknown types, so anything kept here is at
		-- worst inert.
		local objects = {}
		for _, entry in ipairs(decoded.objects) do
			if type(entry) == "table" and type(entry.type) == "string" and entry.idx ~= nil then
				table.insert(objects, entry)
			end
		end

		if #objects == 0 then
			return false, "no usable settings found in that JSON"
		end

		local encodeOk, encoded = pcall(httpService.JSONEncode, httpService, { objects = objects })
		if not encodeOk then
			return false, "failed to re-encode the imported data"
		end

		return encoded, #objects
	end

	-- Writes an imported config to disk under `name` (falling back to
	-- "imported"), never overwriting an existing one - a clashing name gets a
	-- numeric suffix instead, so an import can't silently destroy a config the
	-- user spent time on. Returns the final name + the number of settings.
	function SaveManager:ImportString(text, name)
		local encoded, countOrErr = self:ValidateImport(text)
		if not encoded then
			return false, countOrErr
		end

		local base = self:SanitizeName(name)
		if base == "" then
			base = "imported"
		end

		local final, attempt = base, 1
		while attempt < 1000 and isfile(self:GetSettingsFolder() .. "/" .. final .. ".json") do
			attempt = attempt + 1
			final = string.format("%s (%d)", base, attempt)
		end

		writefile(self:GetSettingsFolder() .. "/" .. final .. ".json", encoded)

		return final, countOrErr
	end

	function SaveManager:LoadAutoloadConfig()
		local autoloadFile = self:GetSettingsFolder() .. "/autoload.txt"
		if isfile(autoloadFile) then
			local name = readfile(autoloadFile)

			local success, err = self:Load(name)
			if not success then
				return self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = "Failed to load autoload config: " .. err,
					Duration = 7
				})
			end

			self.Library:Notify({
				Title = "Interface",
				Content = "Config loader",
				SubContent = string.format("Auto loaded config %q", name),
				Duration = 7
			})
		end
	end

	function SaveManager:RemoveAutoloadConfig()
		local autoloadFile = self:GetSettingsFolder() .. "/autoload.txt"
		if isfile(autoloadFile) then
			writefile(autoloadFile, "") -- Clear the file
			self.Library:Notify({
				Title = "Interface",
				Content = "Config loader",
				SubContent = "Autoload config has been removed",
				Duration = 7
			})
			return true
		else
			self.Library:Notify({
				Title = "Interface",
				Content = "Config loader",
				SubContent = "No autoload config is set",
				Duration = 7
			})
			return false
		end
	end

	-- === Auto Save ===

	-- Polls option state and writes to the dedicated autosave config only when
	-- something actually changed. Deliberately does NOT hook option:OnChanged —
	-- on some option implementations that overwrites the option's real callback
	-- (single callback slot instead of a multi-listener signal), silently
	-- breaking whatever that toggle/slider/etc. was supposed to do. Polling
	-- never touches option callbacks at all, so it's safe regardless of how
	-- Fluentv2's internals wire OnChanged.
	function SaveManager:StartAutoSaveLoop()
		if self._autoSaveLoopStarted then return end
		self._autoSaveLoopStarted = true

		task.spawn(function()
			while task.wait(self.AutoSaveDelay) do
				if self._loading then continue end
				if not self.CurrentConfig then continue end

				local toggle = self.Options and self.Options.SaveManager_AutoSave
				if toggle and not toggle.Value then continue end

				local success, encoded = self:Encode()
				if not success then continue end

				if encoded == self._lastAutoSaveSnapshot then continue end
				self._lastAutoSaveSnapshot = encoded

				local fullPath = self:GetSettingsFolder() .. "/" .. self.CurrentConfig .. ".json"
				writefile(fullPath, encoded)
			end
		end)
	end

	-- Points autoload.txt at whichever config is currently active so next
	-- session restores it automatically, and keeps the "Set As Autoload"
	-- button description in sync. No-ops if Auto Save is toggled off.
	function SaveManager:SyncAutoloadToCurrent()
		local toggle = self.Options and self.Options.SaveManager_AutoSave
		if toggle and not toggle.Value then return end
		if not self.CurrentConfig then return end

		writefile(self:GetSettingsFolder() .. "/autoload.txt", self.CurrentConfig)

		if self.AutoloadButton then
			self.AutoloadButton:SetDesc("Current autoload config: " .. self.CurrentConfig)
		end
	end

	-- Figures out which config autosave should start targeting: whatever
	-- autoload.txt already points to (respecting a prior session / manual
	-- "Set As Autoload"), falling back to AutoSaveConfigName only on a true
	-- first run where nothing has ever been saved.
	function SaveManager:EnsureAutoSaveConfig()
		local toggle = self.Options and self.Options.SaveManager_AutoSave
		if toggle and not toggle.Value then return end

		local autoloadPath = self:GetSettingsFolder() .. "/autoload.txt"
		if isfile(autoloadPath) then
			local existing = readfile(autoloadPath)
			if existing and existing ~= "" then
				self.CurrentConfig = existing
			end
		end

		if not self.CurrentConfig then
			self.CurrentConfig = self.AutoSaveConfigName
		end

		local path = self:GetSettingsFolder() .. "/" .. self.CurrentConfig .. ".json"
		if not isfile(path) then
			self:Save(self.CurrentConfig)
		end

		self:SyncAutoloadToCurrent()
		self:StartAutoSaveLoop()
	end

	function SaveManager:BuildConfigSection(tab)
		assert(self.Library, "Must set SaveManager.Library")

		local section = tab:AddSection("Configuration")

		section:AddInput("SaveManager_ConfigName", { Title = "Config Name" })
		section:AddDropdown("SaveManager_ConfigList", { Title = "Config List", Values = self:RefreshConfigList(), AllowNull = true })

		section:AddButton({
			Title = "Create Config",
			Callback = function()
				local name = SaveManager.Options.SaveManager_ConfigName.Value

				if name:gsub(" ", "") == "" then 
					return self.Library:Notify({
						Title = "Interface",
						Content = "Config loader",
						SubContent = "Invalid config name (empty)",
						Duration = 7
					})
				end

				local success, err = self:Save(name)
				if not success then
					return self.Library:Notify({
						Title = "Interface",
						Content = "Config loader",
						SubContent = "Failed to save config: " .. err,
						Duration = 7
					})
				end

				self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = string.format("Created config %q", name),
					Duration = 7
				})

				SaveManager.Options.SaveManager_ConfigList:SetValues(self:RefreshConfigList())
				SaveManager.Options.SaveManager_ConfigList:SetValue(nil)
			end
		})

		section:AddButton({
			Title = "Load Config",
			Callback = function()
				local name = SaveManager.Options.SaveManager_ConfigList.Value

				local success, err = self:Load(name)
				if not success then
					return self.Library:Notify({
						Title = "Interface",
						Content = "Config loader",
						SubContent = "Failed to load config: " .. err,
						Duration = 7
					})
				end

				self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = string.format("Loaded config %q", name),
					Duration = 7
				})
			end
		})

		section:AddButton({
			Title = "Overwrite Config",
			Callback = function()
				local name = SaveManager.Options.SaveManager_ConfigList.Value

				local success, err = self:Save(name)
				if not success then
					return self.Library:Notify({
						Title = "Interface",
						Content = "Config loader",
						SubContent = "Failed to overwrite config: " .. err,
						Duration = 7
					})
				end

				self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = string.format("Overwrote config %q", name),
					Duration = 7
				})
			end
		})

		section:AddButton({
			Title = "Refresh List",
			Callback = function()
				SaveManager.Options.SaveManager_ConfigList:SetValues(self:RefreshConfigList())
				SaveManager.Options.SaveManager_ConfigList:SetValue(nil)
			end
		})

		section:AddButton({
			Title = "Export Config",
			Description = "Copies the selected config to your clipboard as JSON. With nothing selected, copies your current settings instead.",
			Callback = function()
				local name = SaveManager.Options.SaveManager_ConfigList
					and SaveManager.Options.SaveManager_ConfigList.Value

				local data, err = self:ExportString(name)
				if not data then
					return self.Library:Notify({
						Title = "Interface",
						Content = "Config loader",
						SubContent = "Failed to export config: " .. tostring(err),
						Duration = 7
					})
				end

				-- Clipboard support varies by executor and a missing global is
				-- a hard crash, so it is resolved by name rather than called
				-- blind (same probe the rest of the hub uses).
				local clipboard = setclipboard or toclipboard or (syn and syn.write_clipboard)
				if type(clipboard) ~= "function" then
					return self.Library:Notify({
						Title = "Interface",
						Content = "Config loader",
						SubContent = "This executor has no clipboard function. Copy the file yourself from: "
							.. self:GetSettingsFolder() .. "/",
						Duration = 10
					})
				end

				if not pcall(clipboard, data) then
					return self.Library:Notify({
						Title = "Interface",
						Content = "Config loader",
						SubContent = "Copy to clipboard failed",
						Duration = 7
					})
				end

				self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = string.format(
						"Copied %s to clipboard (%d characters)",
						(name and name ~= "") and string.format("config %q", name) or "your current settings",
						#data
					),
					Duration = 7
				})
			end
		})

		-- Declared first so the Callback below can read the input box that is
		-- part of this very button (it is only populated once AddButton
		-- returns, which is always before a click can happen).
		local ImportButton
		ImportButton = section:AddButton({
			Title = "Import Config",
			Description = "Paste an exported config below and press this. It saves as a new config (named from Config Name) and loads it.",
			Input = {
				Title = "Config JSON",
				Placeholder = '{"objects":[ ... ]}',
				Size = "Large",
				Height = 90,
			},
			Callback = function()
				if not ImportButton or ImportButton.InputValue == nil then
					return self.Library:Notify({
						Title = "Interface",
						Content = "Config loader",
						SubContent = "This build of the UI library has no input box on buttons - update it to import configs",
						Duration = 8
					})
				end

				local nameField = SaveManager.Options.SaveManager_ConfigName
				local wanted = nameField and nameField.Value or ""

				local final, countOrErr = self:ImportString(ImportButton.InputValue, wanted)
				if not final then
					return self.Library:Notify({
						Title = "Interface",
						Content = "Config loader",
						SubContent = "Failed to import config: " .. tostring(countOrErr),
						Duration = 7
					})
				end

				-- Refresh before selecting: a dropdown drops any value that is
				-- not in its current Values list, so the new name has to exist
				-- there before it can be selected.
				SaveManager.Options.SaveManager_ConfigList:SetValues(self:RefreshConfigList())
				SaveManager.Options.SaveManager_ConfigList:SetValue(final)

				local success, err = self:Load(final)
				if not success then
					return self.Library:Notify({
						Title = "Interface",
						Content = "Config loader",
						SubContent = string.format("Imported %q but failed to load it: %s", final, tostring(err)),
						Duration = 7
					})
				end

				ImportButton:SetInputValue("")

				self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = string.format("Imported %d settings as %q and loaded it", countOrErr, final),
					Duration = 7
				})
			end
		})

		local AutoloadButton
		AutoloadButton = section:AddButton({
			Title = "Set As Autoload",
			Description = "Current autoload config: none",
			Callback = function()
				local name = SaveManager.Options.SaveManager_ConfigList.Value
				writefile(self:GetSettingsFolder() .. "/autoload.txt", name)
				AutoloadButton:SetDesc("Current autoload config: " .. name)
				self.Library:Notify({
					Title = "Interface",
					Content = "Config loader",
					SubContent = string.format("Set %q to auto load", name),
					Duration = 7
				})
			end
		})

		self.AutoloadButton = AutoloadButton

		section:AddButton({
			Title = "Remove Autoload",
			Callback = function()
				local success = SaveManager:RemoveAutoloadConfig()
				if success then
					AutoloadButton:SetDesc("Current autoload config: none")
				end
			end
		})

		local autoloadFile = self:GetSettingsFolder() .. "/autoload.txt"
		if isfile(autoloadFile) then
			local name = readfile(autoloadFile)
			AutoloadButton:SetDesc("Current autoload config: " .. name)
		end

		section:AddToggle("SaveManager_AutoSave", {
			Title = "Auto Save",
			Description = "Automatically saves the loaded config whenever a setting changes",
			Default = true,
		})

		SaveManager:SetIgnoreIndexes({ "SaveManager_ConfigList", "SaveManager_ConfigName", "SaveManager_AutoSave" })

		-- figure out which config autosave should follow (existing autoload,
		-- or bootstrap a fresh one), then start the safe polling loop
		self:EnsureAutoSaveConfig()
	end

	SaveManager:BuildFolderTree()
end

return SaveManager
