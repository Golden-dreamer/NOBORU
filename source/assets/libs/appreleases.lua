AppReleases = {}

local decode = loadlib("releasejson")
local repository = "Golden-dreamer/NOBORU"
local api = "https://api.github.com/repos/" .. repository .. "/releases"
local downloads = "https://github.com/" .. repository .. "/releases/download/"
local pageSize = 20

local function devPublication(release)
	local published = release.published_at
	if release.draft == false and release.prerelease == true and type(published) == "string"
		and published:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") then return published end
end

local function candidate(release, channel)
	if type(release) ~= "table" or release.draft ~= false or type(release.tag_name) ~= "string" then return end
	local tag = release.tag_name
	local published = release.published_at
	if channel == "Dev" then
		published = devPublication(release)
		if not published or not tag:match("^dev%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d%d%d%d%d%d$") then return end
	elseif release.prerelease ~= false or not tag:match("^%d+%.%d+$") then
		return
	end
	if type(release.assets) ~= "table" then return end
	local name = "Noboru-" .. channel .. "-" .. tag .. ".vpk"
	for _, asset in ipairs(release.assets) do
		if type(asset) == "table" and (asset.name == name or (channel == "Stable" and asset.name == "Noboru.vpk"))
			and asset.state == "uploaded" and asset.browser_download_url == downloads .. tag .. "/" .. asset.name
			and type(asset.size) == "number" and asset.size >= 1000 then
			local notes = type(release.body) == "string" and release.body:gsub("\r", "") or nil
			if notes and (#notes > 700 or notes == "" or select(2, notes:gsub("\n", "")) > 8) then notes = nil end
			return {tag = tag, published = published, url = asset.browser_download_url, size = asset.size, notes = notes}
		end
	end
end

function AppReleases.check(channel, installed, isCurrent, complete)
	local best, installedPublished
	local function request(page)
		local response = {}
		local link = channel == "Stable" and (api .. "/latest") or (api .. "?per_page=" .. pageSize .. "&page=" .. page)
		Threads.insertTask(response, {
			Type = "StringRequest", Link = link, Table = response, Index = "body",
			Header1 = "Accept: application/vnd.github+json",
			OnError = function() if isCurrent() then complete(nil, true) end end,
			OnComplete = function()
				if not isCurrent() or response.body == nil then return end
				local ok, data = pcall(decode, response.body)
				if not ok or type(data) ~= "table" then complete(nil, true); return end
				if channel == "Stable" then
					complete(candidate(data, channel), type(data.tag_name) ~= "string")
					return
				end
				if not response.body:match("^%s*%[") then complete(nil, true); return end
				for _, release in ipairs(data) do
					if installed and type(release) == "table" and release.tag_name == installed then
						installedPublished = devPublication(release) or installedPublished
					end
					local item = candidate(release, channel)
					if item and (not best or item.published > best.published
						or (item.published == best.published and item.tag > best.tag)) then best = item end
				end
				if #data == pageSize then request(page + 1); return end
				local newer = best and best.tag ~= installed and (not installedPublished
					or best.published > installedPublished
					or (best.published == installedPublished and best.tag > installed))
				complete(best, false, newer)
			end
		})
	end
	request(1)
end
