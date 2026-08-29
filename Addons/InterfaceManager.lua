local httpService = game:GetService("HttpService")

local InterfaceManager = {} do
	InterfaceManager.Folder = "FluentSettings"
    InterfaceManager.Settings = {
        Theme = "Darker",
        Acrylic = true,
        Transparency = true,
        -- Percent, 0 = Fluent's own default look (the look before this
        -- setting existed) - which is already partly translucent, not
        -- fully opaque.
        WindowTransparency = 0,
        MenuKeybind = "RightAlt",
        -- Interface language. Lives here rather than in its own file because
        -- InterfaceManager's folder is the shared "Skull Hub" one, so the
        -- choice applies to every game's hub instead of being re-picked per
        -- game. "en" is the source language and needs no catalog entries.
        Language = "en",
    }

    -- ── Localization ────────────────────────────────────────────────────
    --
    -- The translator itself lives in the library (Library.Localization); this
    -- addon owns the *picker* and the strings for its own section. Everything
    -- here is feature-detected against that namespace: an older build of
    -- Fluent fetched from GitHub has no Localization, and this file must
    -- still build its section on one - just without a Language dropdown.

    -- Catalogs for InterfaceManager's own section. `en` is registered too,
    -- explicitly, so a key that is missing from one of the other four falls
    -- back to real English instead of to a raw dotted key.
    local STRINGS = {
        en = {
            section = "Interface",
            theme = { title = "Theme", desc = "Changes the interface theme." },
            transparency = {
                title = "Window Transparency",
                desc = "Fades the window background further. 0% is the default look.",
            },
            keybind = { title = "Minimize Bind" },
            language = { title = "Language", desc = "Changes the language of the interface." },
        },
        vi = {
            section = "Giao diện",
            theme = { title = "Chủ đề", desc = "Đổi chủ đề của giao diện." },
            transparency = {
                title = "Độ trong suốt cửa sổ",
                desc = "Làm nền cửa sổ mờ thêm. 0% là giao diện mặc định.",
            },
            keybind = { title = "Phím thu nhỏ" },
            language = { title = "Ngôn ngữ", desc = "Đổi ngôn ngữ của giao diện." },
        },
        ru = {
            section = "Интерфейс",
            theme = { title = "Тема", desc = "Меняет тему интерфейса." },
            transparency = {
                title = "Прозрачность окна",
                desc = "Сильнее осветляет фон окна. 0% — вид по умолчанию.",
            },
            keybind = { title = "Клавиша сворачивания" },
            language = { title = "Язык", desc = "Меняет язык интерфейса." },
        },
        tr = {
            section = "Arayüz",
            theme = { title = "Tema", desc = "Arayüz temasını değiştirir." },
            transparency = {
                title = "Pencere Saydamlığı",
                desc = "Pencere arka planını daha da soluklaştırır. %0 varsayılan görünümdür.",
            },
            keybind = { title = "Küçültme Tuşu" },
            language = { title = "Dil", desc = "Arayüzün dilini değiştirir." },
        },
        id = {
            section = "Antarmuka",
            theme = { title = "Tema", desc = "Mengubah tema antarmuka." },
            transparency = {
                title = "Transparansi Jendela",
                desc = "Membuat latar jendela makin pudar. 0% adalah tampilan bawaan.",
            },
            keybind = { title = "Tombol Perkecil" },
            language = { title = "Bahasa", desc = "Mengubah bahasa antarmuka." },
        },
    }

    local StringsRegistered = false

    function InterfaceManager:GetLocalization()
        local Library = self.Library
        return Library and Library.Localization or nil
    end

    -- Registers this addon's strings exactly once. Add() is idempotent, but
    -- an addon re-registering on every SetFolder/BuildInterfaceSection call
    -- would also re-fire every locale subscriber for no reason.
    function InterfaceManager:RegisterStrings()
        if StringsRegistered then return end
        local L = self:GetLocalization()
        if not L then return end

        for code, messages in pairs(STRINGS) do
            L.Add(code, { interface = messages })
        end
        StringsRegistered = true
    end

    -- Text for a key that works whether or not the library can translate.
    -- Used for the two places a live tag cannot go (the section title, which
    -- Fluent captures at creation, and any plain-string fallback).
    function InterfaceManager:Translate(key, fallback)
        local L = self:GetLocalization()
        if not L then return fallback end
        self:RegisterStrings()
        return L.t(key)
    end

    -- A live tag when the library supports one, the plain English string when
    -- it does not. Every element config below goes through this, so this file
    -- has exactly one place that knows localization is optional.
    function InterfaceManager:Tag(key, fallback)
        local L = self:GetLocalization()
        if not L then return fallback end
        self:RegisterStrings()
        return L.tag(key)
    end

    -- Pushes Settings.Language into the library. Called as early as the folder
    -- is known (SetFolder) so the built-in strings are already in the right
    -- language by the time the user looks at them, and again from the
    -- dropdown callback.
    function InterfaceManager:ApplyLanguage(Code)
        local L = self:GetLocalization()
        if not L then return false end
        self:RegisterStrings()

        Code = Code or InterfaceManager.Settings.Language
        if not L.IsSupported(Code) then
            Code = L.Default
        end

        InterfaceManager.Settings.Language = Code
        return L.Set(Code)
    end

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

		-- Apply the saved language here rather than waiting for
		-- BuildInterfaceSection: the library's own chrome (search box, close
		-- prompt, sidebar tooltip) is already on screen by then, and every
		-- localized element built between these two points would otherwise be
		-- painted in English first and corrected a moment later.
		pcall(function()
			self:LoadSettings()
			self:ApplyLanguage(InterfaceManager.Settings.Language)
		end)
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
        local L = self:GetLocalization()

        InterfaceManager:LoadSettings()
        InterfaceManager:ApplyLanguage(Settings.Language)

		local section = tab:AddSection(self:Tag("interface.section", "Interface"))

		local InterfaceTheme = section:AddDropdown("InterfaceTheme", {
			Title = self:Tag("interface.theme.title", "Theme"),
			Description = self:Tag("interface.theme.desc", "Changes the interface theme."),
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

        -- Language picker. Only built when the library actually ships a
        -- translator - an older Fluent would otherwise get a dropdown that
        -- saves a preference nothing can act on.
        if L then
            -- Label/Value entries: the row shows the endonym, the config
            -- stores the stable code. A plain-string dropdown would save
            -- "Tiếng Việt" and then fail to restore it the moment the label
            -- text ever changed.
            local LanguageValues = {}
            for _, Code in ipairs(L.GetSupported()) do
                table.insert(LanguageValues, { Label = L.GetNativeName(Code), Value = Code })
            end

            local InterfaceLanguage = section:AddDropdown("InterfaceLanguage", {
                Title = self:Tag("interface.language.title", "Language"),
                Description = self:Tag("interface.language.desc", "Changes the language of the interface."),
                Values = LanguageValues,
                Default = Settings.Language,
                Callback = function(Value)
                    -- ApplyLanguage is what writes Settings.Language, so the
                    -- saved value can only ever be a code the library accepts.
                    InterfaceManager:ApplyLanguage(Value)
                    InterfaceManager:SaveSettings()
                end
            })

            InterfaceLanguage:SetValue(Settings.Language)
        end

		-- The slider fires its callback with Default as soon as it is built,
		-- which is what applies the saved value on load - no SetValue needed.
		section:AddSlider("WindowTransparency", {
			Title = self:Tag("interface.transparency.title", "Window Transparency"),
			Description = self:Tag(
				"interface.transparency.desc",
				"Fades the window background further. 0% is the default look."
			),
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

		local MenuKeybind = section:AddKeybind("MenuKeybind", {
			Title = self:Tag("interface.keybind.title", "Minimize Bind"),
			Default = Settings.MenuKeybind,
		})
		MenuKeybind:OnChanged(function()
			Settings.MenuKeybind = MenuKeybind.Value
            InterfaceManager:SaveSettings()
		end)
		Library.MinimizeKeybind = MenuKeybind
    end
end

return InterfaceManager
