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
	}

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

		local fullPath = self.Folder .. "/settings/" .. name .. ".json"
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
		
		local file = self.Folder .. "/settings/" .. name .. ".json"
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
			self.Folder .. "/settings"
		}

		for i = 1, #paths do
			local str = paths[i]
			if not isfolder(str) then
				makefolder(str)
			end
		end
	end

	function SaveManager:RefreshConfigList()
		local list = listfiles(self.Folder .. "/settings")

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

	function SaveManager:LoadAutoloadConfig()
		if isfile(self.Folder .. "/settings/autoload.txt") then
			local name = readfile(self.Folder .. "/settings/autoload.txt")

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
		local autoloadFile = self.Folder .. "/settings/autoload.txt"
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

				local fullPath = self.Folder .. "/settings/" .. self.CurrentConfig .. ".json"
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

		writefile(self.Folder .. "/settings/autoload.txt", self.CurrentConfig)

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

		local autoloadPath = self.Folder .. "/settings/autoload.txt"
		if isfile(autoloadPath) then
			local existing = readfile(autoloadPath)
			if existing and existing ~= "" then
				self.CurrentConfig = existing
			end
		end

		if not self.CurrentConfig then
			self.CurrentConfig = self.AutoSaveConfigName
		end

		local path = self.Folder .. "/settings/" .. self.CurrentConfig .. ".json"
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

		local AutoloadButton
		AutoloadButton = section:AddButton({
			Title = "Set As Autoload",
			Description = "Current autoload config: none",
			Callback = function()
				local name = SaveManager.Options.SaveManager_ConfigList.Value
				writefile(self.Folder .. "/settings/autoload.txt", name)
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

		if isfile(self.Folder .. "/settings/autoload.txt") then
			local name = readfile(self.Folder .. "/settings/autoload.txt")
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
