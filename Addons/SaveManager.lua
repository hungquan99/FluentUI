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

	-- ── Localization ────────────────────────────────────────────────────
	--
	-- The Configuration section sits directly beside InterfaceManager's on the
	-- same Settings tab, so it translates through the same library namespace -
	-- otherwise picking a language visibly translates one half of one tab.
	-- Feature-detected the same way: an older Fluent with no Localization
	-- still builds this section, in English.
	local STRINGS = {
		en = {
			section = "Configuration",
			name = "Config Name",
			list = "Config List",
			create = "Create Config",
			load = "Load Config",
			overwrite = "Overwrite Config",
			refresh = "Refresh List",
			export = {
				title = "Export Config",
				desc = "Copies the selected config to your clipboard as JSON. With nothing selected, copies your current settings instead.",
			},
			import = {
				title = "Import Config",
				desc = "Paste an exported config below and press this. It saves as a new config (named from Config Name) and loads it.",
				input = "Config JSON",
			},
			autoload = {
				title = "Set As Autoload",
				remove = "Remove Autoload",
				none = "Current autoload config: none",
				current = "Current autoload config: {name}",
			},
			autosave = {
				title = "Auto Save",
				desc = "Automatically saves the loaded config whenever a setting changes",
			},
			notify = {
				title = "Interface",
				content = "Config loader",
				empty = "Invalid config name (empty)",
				created = "Created config {name}",
				loaded = "Loaded config {name}",
				overwrote = "Overwrote config {name}",
				autoloaded = "Auto loaded config {name}",
				autoloadSet = "Set {name} to auto load",
				autoloadRemoved = "Autoload config has been removed",
				autoloadMissing = "No autoload config is set",
				saveFailed = "Failed to save config: {err}",
				loadFailed = "Failed to load config: {err}",
				autoloadFailed = "Failed to load autoload config: {err}",
				overwriteFailed = "Failed to overwrite config: {err}",
				exportFailed = "Failed to export config: {err}",
				importFailed = "Failed to import config: {err}",
				importedNotLoaded = "Imported {name} but failed to load it: {err}",
				imported = "Imported {count} settings as {name} and loaded it",
				noClipboard = "This executor has no clipboard function. Copy the file yourself from: {path}",
				clipboardFailed = "Copy to clipboard failed",
				noInputBox = "This build of the UI library has no input box on buttons - update it to import configs",
				copiedNamed = "Copied config {name} to clipboard ({count} characters)",
				copiedCurrent = "Copied your current settings to clipboard ({count} characters)",
			},
		},
		vi = {
			section = "Cấu hình",
			name = "Tên cấu hình",
			list = "Danh sách cấu hình",
			create = "Tạo cấu hình",
			load = "Tải cấu hình",
			overwrite = "Ghi đè cấu hình",
			refresh = "Làm mới danh sách",
			export = {
				title = "Xuất cấu hình",
				desc = "Sao chép cấu hình đã chọn vào clipboard dưới dạng JSON. Không chọn gì thì chép thiết lập hiện tại.",
			},
			import = {
				title = "Nhập cấu hình",
				desc = "Dán cấu hình đã xuất vào ô dưới rồi bấm nút này. Nó lưu thành cấu hình mới (lấy Tên cấu hình) rồi tải luôn.",
				input = "JSON cấu hình",
			},
			autoload = {
				title = "Đặt làm tự động tải",
				remove = "Bỏ tự động tải",
				none = "Cấu hình tự động tải hiện tại: không có",
				current = "Cấu hình tự động tải hiện tại: {name}",
			},
			autosave = {
				title = "Tự động lưu",
				desc = "Tự lưu cấu hình đang dùng mỗi khi có thiết lập thay đổi",
			},
			notify = {
				title = "Giao diện",
				content = "Trình quản lý cấu hình",
				empty = "Tên cấu hình không hợp lệ (bỏ trống)",
				created = "Đã tạo cấu hình {name}",
				loaded = "Đã tải cấu hình {name}",
				overwrote = "Đã ghi đè cấu hình {name}",
				autoloaded = "Đã tự động tải cấu hình {name}",
				autoloadSet = "Đã đặt {name} làm tự động tải",
				autoloadRemoved = "Đã bỏ cấu hình tự động tải",
				autoloadMissing = "Chưa đặt cấu hình tự động tải nào",
				saveFailed = "Lưu cấu hình thất bại: {err}",
				loadFailed = "Tải cấu hình thất bại: {err}",
				autoloadFailed = "Tải cấu hình tự động thất bại: {err}",
				overwriteFailed = "Ghi đè cấu hình thất bại: {err}",
				exportFailed = "Xuất cấu hình thất bại: {err}",
				importFailed = "Nhập cấu hình thất bại: {err}",
				importedNotLoaded = "Đã nhập {name} nhưng tải thất bại: {err}",
				imported = "Đã nhập {count} thiết lập thành {name} và tải xong",
				noClipboard = "Executor này không có hàm clipboard. Hãy tự chép tệp từ: {path}",
				clipboardFailed = "Chép vào clipboard thất bại",
				noInputBox = "Bản thư viện giao diện này chưa có ô nhập trên nút - hãy cập nhật để nhập cấu hình",
				copiedNamed = "Đã chép cấu hình {name} vào clipboard ({count} ký tự)",
				copiedCurrent = "Đã chép thiết lập hiện tại vào clipboard ({count} ký tự)",
			},
		},
		ru = {
			section = "Конфигурация",
			name = "Имя конфига",
			list = "Список конфигов",
			create = "Создать конфиг",
			load = "Загрузить конфиг",
			overwrite = "Перезаписать конфиг",
			refresh = "Обновить список",
			export = {
				title = "Экспорт конфига",
				desc = "Копирует выбранный конфиг в буфер обмена как JSON. Если ничего не выбрано — копирует текущие настройки.",
			},
			import = {
				title = "Импорт конфига",
				desc = "Вставьте экспортированный конфиг ниже и нажмите сюда. Он сохранится как новый конфиг (с именем из поля «Имя конфига») и загрузится.",
				input = "JSON конфига",
			},
			autoload = {
				title = "Сделать автозагрузкой",
				remove = "Убрать автозагрузку",
				none = "Текущий конфиг автозагрузки: нет",
				current = "Текущий конфиг автозагрузки: {name}",
			},
			autosave = {
				title = "Автосохранение",
				desc = "Автоматически сохраняет загруженный конфиг при любом изменении настройки",
			},
			notify = {
				title = "Интерфейс",
				content = "Загрузчик конфигов",
				empty = "Недопустимое имя конфига (пустое)",
				created = "Конфиг {name} создан",
				loaded = "Конфиг {name} загружен",
				overwrote = "Конфиг {name} перезаписан",
				autoloaded = "Конфиг {name} загружен автоматически",
				autoloadSet = "{name} назначен для автозагрузки",
				autoloadRemoved = "Конфиг автозагрузки удалён",
				autoloadMissing = "Конфиг автозагрузки не задан",
				saveFailed = "Не удалось сохранить конфиг: {err}",
				loadFailed = "Не удалось загрузить конфиг: {err}",
				autoloadFailed = "Не удалось загрузить конфиг автозагрузки: {err}",
				overwriteFailed = "Не удалось перезаписать конфиг: {err}",
				exportFailed = "Не удалось экспортировать конфиг: {err}",
				importFailed = "Не удалось импортировать конфиг: {err}",
				importedNotLoaded = "{name} импортирован, но загрузить не удалось: {err}",
				imported = "Импортировано настроек: {count}, сохранено как {name} и загружено",
				noClipboard = "У этого исполнителя нет функции буфера обмена. Скопируйте файл вручную из: {path}",
				clipboardFailed = "Не удалось скопировать в буфер обмена",
				noInputBox = "В этой сборке библиотеки нет поля ввода на кнопках — обновите её для импорта конфигов",
				copiedNamed = "Конфиг {name} скопирован в буфер обмена ({count} символов)",
				copiedCurrent = "Текущие настройки скопированы в буфер обмена ({count} символов)",
			},
		},
		tr = {
			section = "Yapılandırma",
			name = "Yapılandırma Adı",
			list = "Yapılandırma Listesi",
			create = "Yapılandırma Oluştur",
			load = "Yapılandırma Yükle",
			overwrite = "Yapılandırmanın Üzerine Yaz",
			refresh = "Listeyi Yenile",
			export = {
				title = "Yapılandırmayı Dışa Aktar",
				desc = "Seçili yapılandırmayı JSON olarak panoya kopyalar. Hiçbir şey seçili değilse mevcut ayarlarınızı kopyalar.",
			},
			import = {
				title = "Yapılandırmayı İçe Aktar",
				desc = "Dışa aktarılmış bir yapılandırmayı aşağıya yapıştırıp buna basın. Yeni yapılandırma olarak (Yapılandırma Adı ile) kaydedilir ve yüklenir.",
				input = "Yapılandırma JSON'u",
			},
			autoload = {
				title = "Otomatik Yükleme Yap",
				remove = "Otomatik Yüklemeyi Kaldır",
				none = "Geçerli otomatik yükleme yapılandırması: yok",
				current = "Geçerli otomatik yükleme yapılandırması: {name}",
			},
			autosave = {
				title = "Otomatik Kaydet",
				desc = "Bir ayar her değiştiğinde yüklü yapılandırmayı otomatik kaydeder",
			},
			notify = {
				title = "Arayüz",
				content = "Yapılandırma yükleyici",
				empty = "Geçersiz yapılandırma adı (boş)",
				created = "{name} yapılandırması oluşturuldu",
				loaded = "{name} yapılandırması yüklendi",
				overwrote = "{name} yapılandırmasının üzerine yazıldı",
				autoloaded = "{name} yapılandırması otomatik yüklendi",
				autoloadSet = "{name} otomatik yüklenecek şekilde ayarlandı",
				autoloadRemoved = "Otomatik yükleme yapılandırması kaldırıldı",
				autoloadMissing = "Ayarlanmış otomatik yükleme yapılandırması yok",
				saveFailed = "Yapılandırma kaydedilemedi: {err}",
				loadFailed = "Yapılandırma yüklenemedi: {err}",
				autoloadFailed = "Otomatik yükleme yapılandırması yüklenemedi: {err}",
				overwriteFailed = "Yapılandırmanın üzerine yazılamadı: {err}",
				exportFailed = "Yapılandırma dışa aktarılamadı: {err}",
				importFailed = "Yapılandırma içe aktarılamadı: {err}",
				importedNotLoaded = "{name} içe aktarıldı ama yüklenemedi: {err}",
				imported = "{count} ayar {name} olarak içe aktarıldı ve yüklendi",
				noClipboard = "Bu yürütücüde pano işlevi yok. Dosyayı şuradan kendiniz kopyalayın: {path}",
				clipboardFailed = "Panoya kopyalama başarısız",
				noInputBox = "Arayüz kitaplığının bu sürümünde düğmelerde giriş kutusu yok - yapılandırma içe aktarmak için güncelleyin",
				copiedNamed = "{name} yapılandırması panoya kopyalandı ({count} karakter)",
				copiedCurrent = "Mevcut ayarlarınız panoya kopyalandı ({count} karakter)",
			},
		},
		id = {
			section = "Konfigurasi",
			name = "Nama Konfigurasi",
			list = "Daftar Konfigurasi",
			create = "Buat Konfigurasi",
			load = "Muat Konfigurasi",
			overwrite = "Timpa Konfigurasi",
			refresh = "Segarkan Daftar",
			export = {
				title = "Ekspor Konfigurasi",
				desc = "Menyalin konfigurasi terpilih ke papan klip sebagai JSON. Jika tidak ada yang dipilih, menyalin pengaturan Anda saat ini.",
			},
			import = {
				title = "Impor Konfigurasi",
				desc = "Tempel konfigurasi hasil ekspor di bawah lalu tekan ini. Ia disimpan sebagai konfigurasi baru (memakai Nama Konfigurasi) dan dimuat.",
				input = "JSON Konfigurasi",
			},
			autoload = {
				title = "Jadikan Muat Otomatis",
				remove = "Hapus Muat Otomatis",
				none = "Konfigurasi muat otomatis saat ini: tidak ada",
				current = "Konfigurasi muat otomatis saat ini: {name}",
			},
			autosave = {
				title = "Simpan Otomatis",
				desc = "Otomatis menyimpan konfigurasi yang dimuat setiap kali ada pengaturan berubah",
			},
			notify = {
				title = "Antarmuka",
				content = "Pemuat konfigurasi",
				empty = "Nama konfigurasi tidak valid (kosong)",
				created = "Konfigurasi {name} dibuat",
				loaded = "Konfigurasi {name} dimuat",
				overwrote = "Konfigurasi {name} ditimpa",
				autoloaded = "Konfigurasi {name} dimuat otomatis",
				autoloadSet = "{name} disetel untuk dimuat otomatis",
				autoloadRemoved = "Konfigurasi muat otomatis telah dihapus",
				autoloadMissing = "Belum ada konfigurasi muat otomatis yang disetel",
				saveFailed = "Gagal menyimpan konfigurasi: {err}",
				loadFailed = "Gagal memuat konfigurasi: {err}",
				autoloadFailed = "Gagal memuat konfigurasi muat otomatis: {err}",
				overwriteFailed = "Gagal menimpa konfigurasi: {err}",
				exportFailed = "Gagal mengekspor konfigurasi: {err}",
				importFailed = "Gagal mengimpor konfigurasi: {err}",
				importedNotLoaded = "{name} diimpor tetapi gagal dimuat: {err}",
				imported = "Mengimpor {count} pengaturan sebagai {name} dan memuatnya",
				noClipboard = "Executor ini tidak punya fungsi papan klip. Salin sendiri berkasnya dari: {path}",
				clipboardFailed = "Gagal menyalin ke papan klip",
				noInputBox = "Versi pustaka antarmuka ini tidak punya kotak isian pada tombol - perbarui untuk mengimpor konfigurasi",
				copiedNamed = "Konfigurasi {name} disalin ke papan klip ({count} karakter)",
				copiedCurrent = "Pengaturan Anda saat ini disalin ke papan klip ({count} karakter)",
			},
		},
	}

	local StringsRegistered = false

	function SaveManager:GetLocalization()
		local Library = self.Library
		return Library and Library.Localization or nil
	end

	function SaveManager:RegisterStrings()
		if StringsRegistered then return end
		local L = self:GetLocalization()
		if not L then return end

		for code, messages in pairs(STRINGS) do
			L.Add(code, { config = messages })
		end
		StringsRegistered = true
	end

	-- Resolved now, in the active locale. Used for notification text and for
	-- descriptions that already carry runtime values (a config name), which a
	-- tag cannot express.
	function SaveManager:Translate(key, fallback, params)
		local L = self:GetLocalization()
		if not L then
			if params and type(fallback) == "string" then
				return (fallback:gsub("{([%w_]+)}", function(name)
					local value = params[name]
					if value == nil then return nil end
					return tostring(value)
				end))
			end
			return fallback
		end
		self:RegisterStrings()
		return L.t(key, params)
	end

	-- A live tag when the library supports one, plain English when it does not.
	function SaveManager:Tag(key, fallback)
		local L = self:GetLocalization()
		if not L then return fallback end
		self:RegisterStrings()
		return L.tag(key)
	end

	-- Every notification in this file has the same shell; only the SubContent
	-- differs. One helper keeps the Title/Content pair translated in one place
	-- instead of at seventeen call sites.
	function SaveManager:Notify(key, fallback, params, duration)
		return self.Library:Notify({
			Title = self:Translate("config.notify.title", "Interface"),
			Content = self:Translate("config.notify.content", "Config loader"),
			SubContent = self:Translate(key, fallback, params),
			Duration = duration or 7,
		})
	end

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
			-- InterfaceLanguage belongs here for the same reason as the theme:
			-- it is persisted by InterfaceManager into the SHARED interface
			-- folder, so letting a per-game config also save it gives two
			-- owners for one setting - and the config, loaded last, would
			-- quietly undo the language the user picked in another game.
			"InterfaceTheme", "InterfaceLanguage", "AcrylicToggle", "TransparentToggle", "WindowTransparency", "MenuKeybind"
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
				return self:Notify(
					"config.notify.autoloadFailed",
					"Failed to load autoload config: {err}",
					{ err = tostring(err) }
				)
			end

			self:Notify("config.notify.autoloaded", "Auto loaded config {name}", { name = string.format("%q", name) })
		end
	end

	function SaveManager:RemoveAutoloadConfig()
		local autoloadFile = self:GetSettingsFolder() .. "/autoload.txt"
		if isfile(autoloadFile) then
			writefile(autoloadFile, "") -- Clear the file
			self:Notify("config.notify.autoloadRemoved", "Autoload config has been removed")
			return true
		else
			self:Notify("config.notify.autoloadMissing", "No autoload config is set")
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

		self:SetAutoloadName(self.CurrentConfig)
	end

	-- The autoload button's description embeds a runtime value, so a plain
	-- localization tag cannot carry it: the name has to be substituted into
	-- whichever translated sentence is current. The name is therefore held as
	-- state and the description rendered from it - by SetAutoloadName when the
	-- name changes, and by the locale subscription when the sentence does.
	-- Every writer goes through here so the two can never disagree.
	function SaveManager:RenderAutoloadDesc()
		if not self.AutoloadButton then return end

		if self.AutoloadName and self.AutoloadName ~= "" then
			self.AutoloadButton:SetDesc(
				self:Translate("config.autoload.current", "Current autoload config: {name}", { name = self.AutoloadName })
			)
		else
			self.AutoloadButton:SetDesc(self:Translate("config.autoload.none", "Current autoload config: none"))
		end
	end

	function SaveManager:SetAutoloadName(name)
		self.AutoloadName = name
		self:RenderAutoloadDesc()
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

		self:RegisterStrings()

		local section = tab:AddSection(self:Tag("config.section", "Configuration"))

		section:AddInput("SaveManager_ConfigName", { Title = self:Tag("config.name", "Config Name") })
		section:AddDropdown("SaveManager_ConfigList", {
			Title = self:Tag("config.list", "Config List"),
			Values = self:RefreshConfigList(),
			AllowNull = true,
		})

		section:AddButton({
			Title = self:Tag("config.create", "Create Config"),
			Callback = function()
				local name = SaveManager.Options.SaveManager_ConfigName.Value

				if name:gsub(" ", "") == "" then
					return self:Notify("config.notify.empty", "Invalid config name (empty)")
				end

				local success, err = self:Save(name)
				if not success then
					return self:Notify(
						"config.notify.saveFailed",
						"Failed to save config: {err}",
						{ err = tostring(err) }
					)
				end

				self:Notify("config.notify.created", "Created config {name}", { name = string.format("%q", name) })

				SaveManager.Options.SaveManager_ConfigList:SetValues(self:RefreshConfigList())
				SaveManager.Options.SaveManager_ConfigList:SetValue(nil)
			end
		})

		section:AddButton({
			Title = self:Tag("config.load", "Load Config"),
			Callback = function()
				local name = SaveManager.Options.SaveManager_ConfigList.Value

				local success, err = self:Load(name)
				if not success then
					return self:Notify(
						"config.notify.loadFailed",
						"Failed to load config: {err}",
						{ err = tostring(err) }
					)
				end

				self:Notify("config.notify.loaded", "Loaded config {name}", { name = string.format("%q", name) })
			end
		})

		section:AddButton({
			Title = self:Tag("config.overwrite", "Overwrite Config"),
			Callback = function()
				local name = SaveManager.Options.SaveManager_ConfigList.Value

				local success, err = self:Save(name)
				if not success then
					return self:Notify(
						"config.notify.overwriteFailed",
						"Failed to overwrite config: {err}",
						{ err = tostring(err) }
					)
				end

				self:Notify("config.notify.overwrote", "Overwrote config {name}", { name = string.format("%q", name) })
			end
		})

		section:AddButton({
			Title = self:Tag("config.refresh", "Refresh List"),
			Callback = function()
				SaveManager.Options.SaveManager_ConfigList:SetValues(self:RefreshConfigList())
				SaveManager.Options.SaveManager_ConfigList:SetValue(nil)
			end
		})

		section:AddButton({
			Title = self:Tag("config.export.title", "Export Config"),
			Description = self:Tag(
				"config.export.desc",
				"Copies the selected config to your clipboard as JSON. With nothing selected, copies your current settings instead."
			),
			Callback = function()
				local name = SaveManager.Options.SaveManager_ConfigList
					and SaveManager.Options.SaveManager_ConfigList.Value

				local data, err = self:ExportString(name)
				if not data then
					return self:Notify(
						"config.notify.exportFailed",
						"Failed to export config: {err}",
						{ err = tostring(err) }
					)
				end

				-- Clipboard support varies by executor and a missing global is
				-- a hard crash, so it is resolved by name rather than called
				-- blind (same probe the rest of the hub uses).
				local clipboard = setclipboard or toclipboard or (syn and syn.write_clipboard)
				if type(clipboard) ~= "function" then
					return self:Notify(
						"config.notify.noClipboard",
						"This executor has no clipboard function. Copy the file yourself from: {path}",
						{ path = self:GetSettingsFolder() .. "/" },
						10
					)
				end

				if not pcall(clipboard, data) then
					return self:Notify("config.notify.clipboardFailed", "Copy to clipboard failed")
				end

				-- Two separate keys rather than one with a substituted noun
				-- phrase: languages that inflect the object of "copied" cannot
				-- be translated by gluing a fragment into a sentence.
				if name and name ~= "" then
					self:Notify(
						"config.notify.copiedNamed",
						"Copied config {name} to clipboard ({count} characters)",
						{ name = string.format("%q", name), count = #data }
					)
				else
					self:Notify(
						"config.notify.copiedCurrent",
						"Copied your current settings to clipboard ({count} characters)",
						{ count = #data }
					)
				end
			end
		})

		-- Declared first so the Callback below can read the input box that is
		-- part of this very button (it is only populated once AddButton
		-- returns, which is always before a click can happen).
		local ImportButton
		ImportButton = section:AddButton({
			Title = self:Tag("config.import.title", "Import Config"),
			Description = self:Tag(
				"config.import.desc",
				"Paste an exported config below and press this. It saves as a new config (named from Config Name) and loads it."
			),
			Input = {
				Title = self:Tag("config.import.input", "Config JSON"),
				-- Left untranslated on purpose: it is a JSON literal the user
				-- is meant to match, not prose.
				Placeholder = '{"objects":[ ... ]}',
				Size = "Large",
				Height = 90,
			},
			Callback = function()
				if not ImportButton or ImportButton.InputValue == nil then
					return self:Notify(
						"config.notify.noInputBox",
						"This build of the UI library has no input box on buttons - update it to import configs",
						nil,
						8
					)
				end

				local nameField = SaveManager.Options.SaveManager_ConfigName
				local wanted = nameField and nameField.Value or ""

				local final, countOrErr = self:ImportString(ImportButton.InputValue, wanted)
				if not final then
					return self:Notify(
						"config.notify.importFailed",
						"Failed to import config: {err}",
						{ err = tostring(countOrErr) }
					)
				end

				-- Refresh before selecting: a dropdown drops any value that is
				-- not in its current Values list, so the new name has to exist
				-- there before it can be selected.
				SaveManager.Options.SaveManager_ConfigList:SetValues(self:RefreshConfigList())
				SaveManager.Options.SaveManager_ConfigList:SetValue(final)

				local success, err = self:Load(final)
				if not success then
					return self:Notify(
						"config.notify.importedNotLoaded",
						"Imported {name} but failed to load it: {err}",
						{ name = string.format("%q", final), err = tostring(err) }
					)
				end

				ImportButton:SetInputValue("")

				self:Notify(
					"config.notify.imported",
					"Imported {count} settings as {name} and loaded it",
					{ count = countOrErr, name = string.format("%q", final) }
				)
			end
		})

		local AutoloadButton = section:AddButton({
			Title = self:Tag("config.autoload.title", "Set As Autoload"),
			Description = self:Translate("config.autoload.none", "Current autoload config: none"),
			Callback = function()
				local name = SaveManager.Options.SaveManager_ConfigList.Value
				writefile(self:GetSettingsFolder() .. "/autoload.txt", name)
				self:SetAutoloadName(name)
				self:Notify(
					"config.notify.autoloadSet",
					"Set {name} to auto load",
					{ name = string.format("%q", name) }
				)
			end
		})

		self.AutoloadButton = AutoloadButton

		-- Re-render on locale change, not just on state change: the sentence
		-- gets translated but the name inside it does not, so it has to be
		-- rebuilt rather than swapped.
		local L = self:GetLocalization()
		if L then
			L.OnChanged(function()
				self:RenderAutoloadDesc()
			end)
		end

		section:AddButton({
			Title = self:Tag("config.autoload.remove", "Remove Autoload"),
			Callback = function()
				local success = SaveManager:RemoveAutoloadConfig()
				if success then
					self:SetAutoloadName(nil)
				end
			end
		})

		local autoloadFile = self:GetSettingsFolder() .. "/autoload.txt"
		if isfile(autoloadFile) then
			self:SetAutoloadName(readfile(autoloadFile))
		else
			self:RenderAutoloadDesc()
		end

		section:AddToggle("SaveManager_AutoSave", {
			Title = self:Tag("config.autosave.title", "Auto Save"),
			Description = self:Tag(
				"config.autosave.desc",
				"Automatically saves the loaded config whenever a setting changes"
			),
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
