local httpService = game:GetService("HttpService")

local InterfaceManager = {} do
	InterfaceManager.Folder = "FluentSettings"
    InterfaceManager.Settings = {
        Theme = "Darker",
        Acrylic = true,
        Transparency = true,
        -- Percent, 0 = solid window (the look before this setting existed).
        WindowTransparency = 0,
        MenuKeybind = "RightAlt"
    }

    -- Library:SetWindowTransparency only does anything on a window created
    -- with Acrylic = true, and every script here creates its window with
    -- Acrylic = false - so going through the library alone would give a
    -- slider that visibly does nothing. Fade the window's own background
    -- layers instead; those exist either way.
    local TransparencyBaselines = setmetatable({}, { __mode = "k" })

    local function GetWindowLayers(Library)
        local paint = Library.Window and Library.Window.AcrylicPaint
        local frame = paint and paint.Frame
        if not frame or not frame.Parent then
            return nil
        end

        -- The root pane, the themed "Background" fill and the white gradient
        -- sheet are what make the window read as solid. The noise images and
        -- the border frame are left alone on purpose - their alpha is theme
        -- driven, and the border is what keeps the window's edge visible.
        local layers = { frame }
        for _, child in ipairs(frame:GetChildren()) do
            if child:IsA("Frame")
                and (child.Name == "Background" or child:FindFirstChildOfClass("UIGradient"))
            then
                table.insert(layers, child)
            end
        end

        return layers
    end

    function InterfaceManager:ApplyWindowTransparency(Value)
        local Library = self.Library
        if not Library or not Library.Window then
            return
        end

        Value = math.clamp(tonumber(Value) or 0, 0, 100)

        if Library.UseAcrylic and Library.SetWindowTransparency then
            -- Keep the library's own tuned curve (it also covers the Glass
            -- theme and any open notifications); it takes a 0-3 scale.
            Library:SetWindowTransparency(Value / 100 * 3)
            return
        end

        local layers = GetWindowLayers(Library)
        if not layers then
            return
        end

        local alpha = Value / 100
        for _, layer in ipairs(layers) do
            local base = TransparencyBaselines[layer]
            if base == nil then
                base = layer.BackgroundTransparency
                TransparencyBaselines[layer] = base
            end
            layer.BackgroundTransparency = base + (1 - base) * alpha
        end
    end

    function InterfaceManager:SetFolder(folder)
		self.Folder = folder;
		self:BuildFolderTree()
	end

    function InterfaceManager:SetLibrary(library)
		self.Library = library
	end

    function InterfaceManager:BuildFolderTree()
		local paths = {}

		local parts = self.Folder:split("/")
		for idx = 1, #parts do
			paths[#paths + 1] = table.concat(parts, "/", 1, idx)
		end

		table.insert(paths, self.Folder)
		table.insert(paths, self.Folder .. "/settings")

		for i = 1, #paths do
			local str = paths[i]
			if not isfolder(str) then
				makefolder(str)
			end
		end
	end

    function InterfaceManager:SaveSettings()
        writefile(self.Folder .. "/options.json", httpService:JSONEncode(InterfaceManager.Settings))
    end

    function InterfaceManager:LoadSettings()
        local path = self.Folder .. "/options.json"
        if isfile(path) then
            local data = readfile(path)
            local success, decoded = pcall(httpService.JSONDecode, httpService, data)

            if success then
                for i, v in next, decoded do
                    InterfaceManager.Settings[i] = v
                end
            end
        end
    end

    function InterfaceManager:BuildInterfaceSection(tab)
        assert(self.Library, "Must set InterfaceManager.Library")
		local Library = self.Library
        local Settings = InterfaceManager.Settings

        InterfaceManager:LoadSettings()

		local section = tab:AddSection("Interface")

		local InterfaceTheme = section:AddDropdown("InterfaceTheme", {
			Title = "Theme",
			Description = "Changes the interface theme.",
			Values = Library.Themes,
			Default = Settings.Theme,
			Callback = function(Value)
				Library:SetTheme(Value)
                Settings.Theme = Value
                -- SetTheme can re-write the window transparency itself (the
                -- Glass theme does), so the user's choice is re-asserted
                -- after it rather than being silently replaced.
                InterfaceManager:ApplyWindowTransparency(Settings.WindowTransparency or 0)
                InterfaceManager:SaveSettings()
			end
		})

        InterfaceTheme:SetValue(Settings.Theme)

		-- The slider fires its callback with Default as soon as it is built,
		-- which is what applies the saved value on load - no SetValue needed.
		section:AddSlider("WindowTransparency", {
			Title = "Window Transparency",
			Description = "Fades the window background. 0% keeps it solid.",
			Default = Settings.WindowTransparency or 0,
			Min = 0,
			Max = 100,
			Rounding = 0,
			Callback = function(Value)
				Settings.WindowTransparency = Value
				InterfaceManager:ApplyWindowTransparency(Value)
				InterfaceManager:SaveSettings()
			end
		})

		local MenuKeybind = section:AddKeybind("MenuKeybind", { Title = "Minimize Bind", Default = Settings.MenuKeybind })
		MenuKeybind:OnChanged(function()
			Settings.MenuKeybind = MenuKeybind.Value
            InterfaceManager:SaveSettings()
		end)
		Library.MinimizeKeybind = MenuKeybind
    end
end

return InterfaceManager
