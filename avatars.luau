--!strict
-- GitHub avatars for commit authors, by email, fetched once per daemon and shared by every
-- block. A GitHub noreply address names its account; any other address goes through
-- GitHub's email lookup, which answers an address no account has with a placeholder image.
-- That placeholder (and any failure to find an image) means no avatar: the caller keeps
-- its initials.

local M = {}

export type Image = { bytes: string, mime: string }

-- Per lowercased email: the avatar, or false when GitHub has none. Network failures are
-- not cached, so a later refresh tries again.
local cache: { [string]: Image | false } = {}
local waiting: { [string]: { (Image) -> () } } = {}

-- GitHub's image for an email no account has, fetched once to compare lookups against.
local placeholder: string? = nil
local placeholder_waiting: { () -> () }? = nil

local SIZE = "64"

local function encode(s: string): string
	return (string.gsub(s, "[^%w%-%._~]", function(c: string): string
		return string.format("%%%02X", string.byte(c))
	end))
end

-- The avatar's URL, and whether GitHub answers it with its placeholder when no account
-- matches.
local function url(email: string): (string?, boolean)
	local id = string.match(email, "^(%d+)%+[^@]+@users%.noreply%.github%.com$")
	if id then
		return "https://avatars.githubusercontent.com/u/" .. id .. "?s=" .. SIZE, false
	end
	local login = string.match(email, "^([^@+]+)@users%.noreply%.github%.com$")
	if login then
		return "https://github.com/" .. encode(login) .. ".png?size=" .. SIZE, false
	end
	if string.find(email, "^[^@%s]+@[^@%s]+$") then
		return "https://avatars.githubusercontent.com/u/e?email=" .. encode(email) .. "&s=" .. SIZE, true
	end
	return nil, false
end

-- Fetches an image: the image, or nil with whether the answer is final (no image there)
-- rather than a network failure.
local function get(u: string, done: (Image?, boolean) -> ())
	tern.fetch(u, { timeout_ms = 15000 }, function(r: FetchResult)
		if r.error then
			done(nil, false)
			return
		end
		local mime = string.match(r.headers["content-type"] or "", "^%s*([^;%s]+)") or ""
		if r.status ~= 200 or string.sub(mime, 1, 6) ~= "image/" then
			done(nil, true)
			return
		end
		done({ bytes = r.body, mime = mime }, true)
	end)
end

local function with_placeholder(ready: () -> ())
	if placeholder then
		ready()
		return
	end
	local list = placeholder_waiting
	if list then
		table.insert(list, ready)
		return
	end
	placeholder_waiting = { ready }
	local u = url("no-account@tern-jj.invalid")
	get(u :: string, function(image: Image?)
		local all = placeholder_waiting or {}
		placeholder_waiting = nil
		if not image then
			-- Without it a lookup can't be told from the placeholder: show no lookups.
			for _, f in all do
				f()
			end
			return
		end
		placeholder = image.bytes
		for _, f in all do
			f()
		end
	end)
end

-- Calls `found` with `email`'s GitHub avatar, at once when it is cached, else when it
-- arrives; never when GitHub has none.
function M.load(email: string, found: (Image) -> ())
	local key = string.lower(email)
	local hit = cache[key]
	if hit then
		found(hit)
		return
	elseif hit == false then
		return
	end
	local list = waiting[key]
	if list then
		table.insert(list, found)
		return
	end
	local u, lookup = url(key)
	if not u then
		cache[key] = false
		return
	end
	waiting[key] = { found }
	local function finish(image: Image?, final: boolean)
		local all = waiting[key] or {}
		waiting[key] = nil
		if image then
			cache[key] = image
			for _, f in all do
				f(image)
			end
		elseif final then
			cache[key] = false
		end
	end
	get(u, function(image: Image?, final: boolean)
		if image and lookup then
			with_placeholder(function()
				local known = placeholder
				if known == nil then
					finish(nil, false)
				else
					finish(if image.bytes == known then nil else image, true)
				end
			end)
		else
			finish(image, final)
		end
	end)
end

return M
