local catalogs = {
	English = loadlib("locales/English"),
	Russian = loadlib("locales/Russian")
}

I18n = {}

function I18n.text(key, ...)
	local locale = Settings.Language
	if locale == "Default" then
		for name in pairs(catalogs) do
			if Language[name] == Language.Default then
				locale = name
				break
			end
		end
	end
	local catalog = catalogs[locale] or catalogs.English
	local text = assert(catalog[key] or catalogs.English[key], "Missing translation: " .. key)
	if select("#", ...) > 0 then return string.format(text, ...) end
	return text
end
