-- JMS_Discord_API
-- Discord REST wrapper for FiveM. Fork of Badger_Discord_API (MIT, Jared Scarito).
--
-- Use from other resources with:
--     exports.JMS_Discord_API:GetDiscordRoles(source)
--     exports.Badger_Discord_API:GetDiscordRoles(source)   -- also works, see `provide` in fxmanifest.lua
--
-- Anywhere a `user` is accepted you can pass a player source OR a raw Discord ID string.
-- Anywhere a `guild` is accepted you can pass a name from Config.Guilds, a guild ID, or nil for Config.Guild_ID.

local RESOURCE = GetCurrentResourceName()
local API_BASE = 'https://discord.com/api/v10/'
local TOKEN = GetConvar('discord_bot_token', '')

local MAX_ATTEMPTS = 3 -- total tries when Discord answers 429
local REQUEST_TIMEOUT_MS = 10000
local AVATAR_CACHE_MS = 10 * 60 * 1000
local SWEEP_INTERVAL_MS = 5 * 60 * 1000

-- ---------------------------------------------------------------------------
-- Logging / helpers
-- ---------------------------------------------------------------------------

local HTTP_STATUS = {
	[-1] = 'The bot token is not set. Add `set discord_bot_token "..."` to server.cfg.',
	[0] = 'No response from Discord (network error or timeout).',
	[400] = 'Bad request - Discord rejected the request (check the IDs involved).',
	[401] = 'Unauthorized - the bot token is invalid.',
	[403] = 'Forbidden - the bot lacks the permission, or the target member outranks the bot.',
	[404] = 'Not found - wrong guild/user/role ID, or that user is not in the guild.',
	[429] = 'Rate limited by Discord.',
	[500] = 'Discord server error.',
	[502] = 'Discord is unreachable (bad gateway).',
	[503] = 'Discord is unavailable.',
}

local function logError(fn, msg)
	print(('^1[%s]^7 %s: %s'):format(RESOURCE, fn, msg))
end

local function logInfo(msg)
	print(('^2[%s]^7 %s'):format(RESOURCE, msg))
end

local function logDebug(msg)
	if Config.DebugScript then
		print(('^5[%s]^7 %s'):format(RESOURCE, msg))
	end
end

local function safeDecode(str)
	if type(str) ~= 'string' or str == '' then return nil end
	local ok, data = pcall(json.decode, str)
	if ok then return data end
	return nil
end

local function describe(code, body)
	local text = HTTP_STATUS[code] or ('Unexpected HTTP status ' .. tostring(code) .. '.')
	local data = safeDecode(body)
	if type(data) == 'table' and data.message then
		text = text .. ' Discord says: ' .. tostring(data.message)
	end
	return text
end

local function isOk(res)
	return res ~= nil and type(res.code) == 'number' and res.code >= 200 and res.code < 300
end

local function urlEncode(str)
	return (tostring(str):gsub('[^%w%-_%.~]', function(c)
		return ('%%%02X'):format(c:byte())
	end))
end

local function headerValue(headers, name)
	if type(headers) ~= 'table' then return nil end
	name = name:lower()
	for k, v in pairs(headers) do
		if tostring(k):lower() == name then return v end
	end
	return nil
end

local function copyArray(t)
	local c = {}
	for i = 1, #t do c[i] = t[i] end
	return c
end

local function copyMap(t)
	local c = {}
	for k, v in pairs(t) do c[k] = v end
	return c
end

local function isSnowflake(value)
	local s = tostring(value)
	return s:match('^%d+$') ~= nil and #s >= 15
end

-- ---------------------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------------------

-- One HTTP round trip. Always resolves exactly once (a timeout resolves it with code 0).
local function rawRequest(method, endpoint, payload, reason)
	local p = promise.new()
	local settled = false
	local function settle(result)
		if settled then return end
		settled = true
		p:resolve(result)
	end

	local headers = {
		['Content-Type'] = 'application/json',
		['Authorization'] = 'Bot ' .. TOKEN,
	}
	if reason and reason ~= '' then
		headers['X-Audit-Log-Reason'] = urlEncode(reason)
	end

	SetTimeout(REQUEST_TIMEOUT_MS, function()
		settle({ code = 0, data = nil, headers = {} })
	end)

	PerformHttpRequest(API_BASE .. endpoint, function(code, data, resultHeaders)
		settle({ code = code, data = data, headers = resultHeaders or {} })
	end, method, payload, headers)

	return Citizen.Await(p)
end

-- body: table (JSON-encoded for you), a pre-encoded JSON string, or nil.
-- Returns { code = <number>, data = <raw body string>, headers = <table> }.
local function DiscordRequest(method, endpoint, body, reason)
	if TOKEN == '' then
		return { code = -1, data = nil, headers = {} }
	end

	local payload = ''
	if type(body) == 'table' then
		payload = json.encode(body)
	elseif type(body) == 'string' then
		payload = body
	end

	local res
	local retriedTimeout = false
	for attempt = 1, MAX_ATTEMPTS do
		res = rawRequest(method, endpoint, payload, reason)
		-- A timeout on a read is safe to try once more (a blip should not reject a player). Writes are never repeated.
		if res.code == 0 and method == 'GET' and not retriedTimeout then
			retriedTimeout = true
			logDebug(('no response for GET %s, retrying once'):format(endpoint))
			res = rawRequest(method, endpoint, payload, reason)
		end
		if res.code ~= 429 or attempt == MAX_ATTEMPTS then break end

		local waitSeconds = tonumber(headerValue(res.headers, 'retry-after'))
		if not waitSeconds then
			local data = safeDecode(res.data)
			waitSeconds = type(data) == 'table' and tonumber(data.retry_after) or 1
		end
		waitSeconds = math.min(math.max(waitSeconds, 0.1), 10)
		logDebug(('429 on %s %s, retrying in %.1fs (attempt %d/%d)'):format(method, endpoint, waitSeconds, attempt, MAX_ATTEMPTS))
		Wait(math.floor(waitSeconds * 1000) + 50)
	end
	return res
end

-- ---------------------------------------------------------------------------
-- IDs
-- ---------------------------------------------------------------------------

-- `user` may be a player source or a Discord ID. Returns the Discord ID string or nil.
local function getDiscordId(user)
	if user == nil then return nil end
	if isSnowflake(user) then return tostring(user) end
	local identifier = GetPlayerIdentifierByType(tostring(user), 'discord')
	if identifier then
		return (identifier:gsub('^discord:', ''))
	end
	return nil
end

-- Returns a guild ID string, or nil if `guild` was given but is not recognised.
-- (The original silently fell back to the main guild, which risks writing to the wrong server.)
local function resolveGuildId(guild, fn)
	if guild ~= nil then
		local named = Config.Guilds and Config.Guilds[guild]
		if named then return tostring(named) end
		if isSnowflake(guild) then return tostring(guild) end
		logError(fn or 'resolveGuildId', ('unknown guild "%s" (not in Config.Guilds and not an ID)'):format(tostring(guild)))
		return nil
	end
	if Config.Guild_ID == nil or tostring(Config.Guild_ID) == '' then
		logError(fn or 'resolveGuildId', 'Config.Guild_ID is not set')
		return nil
	end
	return tostring(Config.Guild_ID)
end

-- ---------------------------------------------------------------------------
-- Caches (always hand out copies so callers cannot corrupt them)
-- ---------------------------------------------------------------------------

local roleCache = {} -- "guildId:discordId" -> { roles = {...}, expires = ms }
local roleListCache = {} -- guildId -> { list = {name -> id}, expires = ms }
local avatarCache = {} -- discordId -> { url = "...", expires = ms }

local function now()
	return GetGameTimer()
end

local function sweepCaches()
	local t = now()
	for k, e in pairs(roleCache) do if e.expires <= t then roleCache[k] = nil end end
	for k, e in pairs(roleListCache) do if e.expires <= t then roleListCache[k] = nil end end
	for k, e in pairs(avatarCache) do if e.expires <= t then avatarCache[k] = nil end end
	SetTimeout(SWEEP_INTERVAL_MS, sweepCaches)
end
SetTimeout(SWEEP_INTERVAL_MS, sweepCaches)

local function ResetCaches()
	roleCache = {}
	roleListCache = {}
	avatarCache = {}
end

-- Drops cached roles for one user (all guilds). `user` = source or Discord ID.
local function ClearCache(user)
	local discordId = getDiscordId(user)
	if not discordId then return end
	local suffix = ':' .. discordId
	for key in pairs(roleCache) do
		if key:sub(-#suffix) == suffix then roleCache[key] = nil end
	end
end

-- ---------------------------------------------------------------------------
-- Roles (read)
-- ---------------------------------------------------------------------------

-- 'not_in_guild' = Discord says this user is not a member of the guild (expected for non-members).
-- 'api_error'    = anything else (rate limit, outage, bad token, wrong guild ID, ...).
local function classifyMemberFailure(res)
	if res.code == 404 then
		local data = safeDecode(res.data)
		-- 10007 = Unknown Member, 10013 = Unknown User
		if type(data) == 'table' and (data.code == 10007 or data.code == 10013) then
			return 'not_in_guild'
		end
	end
	return 'api_error'
end

-- Returns an array of role IDs (strings), or nil plus 'not_in_guild' / 'api_error'.
local function getUserRolesInGuild(discordId, guildId)
	local key = guildId .. ':' .. discordId
	if Config.CacheDiscordRoles then
		local entry = roleCache[key]
		if entry and entry.expires > now() then
			return copyArray(entry.roles)
		end
	end

	local res = DiscordRequest('GET', ('guilds/%s/members/%s'):format(guildId, discordId))
	if not isOk(res) then
		local reason = classifyMemberFailure(res)
		if reason == 'not_in_guild' then
			logDebug(('user %s is not a member of guild %s'):format(discordId, guildId))
		else
			logError('GetUserRolesInGuild', describe(res.code, res.data))
		end
		return nil, reason
	end

	local data = safeDecode(res.data)
	if type(data) ~= 'table' or type(data.roles) ~= 'table' then
		logError('GetUserRolesInGuild', 'unexpected response from Discord')
		return nil, 'api_error'
	end

	if Config.CacheDiscordRoles then
		roleCache[key] = {
			roles = copyArray(data.roles),
			expires = now() + (Config.CacheDiscordRolesTime or 60) * 1000,
		}
	end
	return copyArray(data.roles)
end

-- Core lookup. Returns an array of role ID strings, or nil plus a status:
--   'no_discord'   the player has no Discord identifier (Discord app not running)
--   'not_in_guild' Discord says they are not a member of the guild
--   'api_error'    Discord/network problem, bad token, rate limit
--   'config_error' unknown guild / Config.Guild_ID not set
-- With Config.Multiguild and no `guild`, roles from every guild in Config.Guilds are merged (deduplicated).
local function lookupDiscordRoles(user, guild)
	local discordId = getDiscordId(user)
	if not discordId then return nil, 'no_discord' end
	local guildId = resolveGuildId(guild, 'GetDiscordRoles')
	if not guildId then return nil, 'config_error' end

	local roles, reason = getUserRolesInGuild(discordId, guildId)
	if not roles then return nil, reason end

	if guild ~= nil or not Config.Multiguild then
		return roles
	end

	local seen = {}
	for _, r in ipairs(roles) do seen[r] = true end
	for _, otherId in pairs(Config.Guilds or {}) do
		otherId = tostring(otherId)
		if otherId ~= guildId and isSnowflake(otherId) then
			local extra = getUserRolesInGuild(discordId, otherId)
			if extra then
				for _, r in ipairs(extra) do
					if not seen[r] then
						seen[r] = true
						roles[#roles + 1] = r
					end
				end
			end
		end
	end
	return roles
end

-- Returns an array of role ID strings, or false if the lookup failed or the player has no Discord linked.
local function GetDiscordRoles(user, guild)
	local roles, status = lookupDiscordRoles(user, guild)
	if not roles then
		if status == 'no_discord' then
			logError('GetDiscordRoles', 'no Discord identifier for this player (is Discord running on their PC?)')
		end
		return false
	end
	return roles
end

-- Same lookup as GetDiscordRoles, but tells you WHY it failed. Always returns ONE table:
--   { status = 'ok', roles = { ... } }
--   { status = 'no_discord' | 'not_in_guild' | 'api_error' | 'config_error' }
-- Use this when you must tell "not in the Discord" apart from "Discord is having a bad day".
local function GetDiscordRolesEx(user, guild)
	local roles, status = lookupDiscordRoles(user, guild)
	if roles then return { status = 'ok', roles = roles } end
	return { status = status }
end

-- ---------------------------------------------------------------------------
-- Role names / IDs
-- ---------------------------------------------------------------------------

-- Returns { [roleName] = roleId(string) } or nil on failure.
local function GetGuildRoleList(guild)
	local guildId = resolveGuildId(guild, 'GetGuildRoleList')
	if not guildId then return nil end

	local entry = roleListCache[guildId]
	if entry and entry.expires > now() then
		return copyMap(entry.list)
	end

	local res = DiscordRequest('GET', 'guilds/' .. guildId .. '/roles')
	if not isOk(res) then
		logError('GetGuildRoleList', describe(res.code, res.data))
		return nil
	end
	local data = safeDecode(res.data)
	if type(data) ~= 'table' then
		logError('GetGuildRoleList', 'unexpected response from Discord')
		return nil
	end

	local list = {}
	for _, role in ipairs(data) do
		list[role.name] = tostring(role.id)
	end
	roleListCache[guildId] = { list = list, expires = now() + (Config.RoleListCacheTime or 300) * 1000 }
	return copyMap(list)
end

-- Returns the role ID as a number, or nil.
local function GetRoleIdFromRoleName(name, guild)
	local list = GetGuildRoleList(guild)
	if not list then return nil end
	return tonumber(list[name])
end

-- Accepts a role ID (number or numeric string), a name from Config.RoleList, or a role name in the guild.
-- Returns the role ID as a number, or nil.
local function FetchRoleID(role, guild)
	if type(role) == 'number' then return role end
	if type(role) ~= 'string' then return nil end
	if role:match('^%d+$') then return tonumber(role) end

	if Config.RoleList and Config.RoleList[role] then
		return tonumber(Config.RoleList[role])
	end

	local list = GetGuildRoleList(guild)
	if list and list[role] then return tonumber(list[role]) end

	-- Not in the requested guild: fall back to the main guild.
	if guild ~= nil then
		local main = GetGuildRoleList()
		if main and main[role] then return tonumber(main[role]) end
	end
	return nil
end

local function CheckEqual(role1, role2, guild)
	local a = FetchRoleID(role1, guild)
	local b = FetchRoleID(role2, guild)
	return a ~= nil and b ~= nil and a == b
end

-- Role string for REST paths/bodies. Snowflakes must stay strings or JSON can mangle them.
local function resolveRoleString(role, guild)
	if type(role) == 'string' and role:match('^%d+$') then return role end
	local id = FetchRoleID(role, guild)
	if id == nil then return nil end
	return tostring(math.tointeger(id) or id)
end

-- ---------------------------------------------------------------------------
-- Member writes
-- ---------------------------------------------------------------------------

local function memberCall(fn, user, guild, method, subpath, body, reason)
	local discordId = getDiscordId(user)
	if not discordId then
		logError(fn, 'no Discord identifier for this player (is Discord running on their PC?)')
		return false
	end
	local guildId = resolveGuildId(guild, fn)
	if not guildId then return false end

	local endpoint = ('guilds/%s/members/%s%s'):format(guildId, discordId, subpath or '')
	local res = DiscordRequest(method, endpoint, body, reason)
	if not isOk(res) then
		logError(fn, describe(res.code, res.data))
		return false, res.code
	end

	roleCache[guildId .. ':' .. discordId] = nil
	return true, res.code
end

-- Adds one role without touching the member's other roles. Returns true/false, httpCode.
local function AddRole(user, roleId, reason, guild)
	local role = resolveRoleString(roleId, guild)
	if not role then
		logError('AddRole', ('could not resolve role "%s"'):format(tostring(roleId)))
		return false
	end
	return memberCall('AddRole', user, guild, 'PUT', '/roles/' .. role, nil, reason)
end

-- Removes one role without touching the member's other roles. Returns true/false, httpCode.
local function RemoveRole(user, roleId, reason, guild)
	local role = resolveRoleString(roleId, guild)
	if not role then
		logError('RemoveRole', ('could not resolve role "%s"'):format(tostring(roleId)))
		return false
	end
	return memberCall('RemoveRole', user, guild, 'DELETE', '/roles/' .. role, nil, reason)
end

-- REPLACES all of the member's roles with roleList. Pass the complete list you want them to end up with.
local function SetRoles(user, roleList, reason, guild)
	if type(roleList) ~= 'table' then
		logError('SetRoles', 'roleList must be an array of role IDs')
		return false
	end
	local roles = {}
	for _, r in ipairs(roleList) do
		local role = resolveRoleString(r, guild)
		if not role then
			logError('SetRoles', ('could not resolve role "%s", nothing was changed'):format(tostring(r)))
			return false
		end
		roles[#roles + 1] = role
	end
	return memberCall('SetRoles', user, guild, 'PATCH', '', { roles = roles }, reason)
end

-- nickname nil or "" resets the nickname.
local function SetNickname(user, nickname, reason, guild)
	return memberCall('SetNickname', user, guild, 'PATCH', '', { nick = tostring(nickname or '') }, reason)
end

-- Moves a member who is ALREADY in a voice channel. Discord returns 400 otherwise.
local function ChangeDiscordVoice(user, voice, reason, guild)
	return memberCall('ChangeDiscordVoice', user, guild, 'PATCH', '', { channel_id = tostring(voice) }, reason)
end

-- ---------------------------------------------------------------------------
-- User / member lookups
-- ---------------------------------------------------------------------------

local function getUserObject(fn, user)
	local discordId = getDiscordId(user)
	if not discordId then
		logError(fn, 'no Discord identifier for this player (is Discord running on their PC?)')
		return nil
	end
	local res = DiscordRequest('GET', 'users/' .. discordId)
	if not isOk(res) then
		logError(fn, describe(res.code, res.data))
		return nil
	end
	local data = safeDecode(res.data)
	if type(data) ~= 'table' then
		logError(fn, 'unexpected response from Discord')
		return nil
	end
	return data, discordId
end

local function GetDiscordName(user)
	local data = getUserObject('GetDiscordName', user)
	if not data or not data.username then return nil end
	if data.discriminator == nil or data.discriminator == 0 or data.discriminator == '0' then
		return data.username -- new-style (pomelo) username, no #tag
	end
	return data.username .. '#' .. tostring(data.discriminator)
end

local function GetDiscordAvatar(user)
	local discordId = getDiscordId(user)
	if not discordId then
		logError('GetDiscordAvatar', 'no Discord identifier for this player (is Discord running on their PC?)')
		return nil
	end

	local entry = avatarCache[discordId]
	if entry and entry.expires > now() then return entry.url end

	local data = getUserObject('GetDiscordAvatar', discordId)
	if not data or not data.avatar then return nil end

	local ext = data.avatar:sub(1, 2) == 'a_' and 'gif' or 'png'
	local url = ('https://cdn.discordapp.com/avatars/%s/%s.%s'):format(discordId, data.avatar, ext)
	avatarCache[discordId] = { url = url, expires = now() + AVATAR_CACHE_MS }
	return url
end

local function GetDiscordNickname(user, guild)
	local discordId = getDiscordId(user)
	if not discordId then
		logError('GetDiscordNickname', 'no Discord identifier for this player (is Discord running on their PC?)')
		return nil
	end
	local guildId = resolveGuildId(guild, 'GetDiscordNickname')
	if not guildId then return nil end

	local res = DiscordRequest('GET', ('guilds/%s/members/%s'):format(guildId, discordId))
	if not isOk(res) then
		logError('GetDiscordNickname', describe(res.code, res.data))
		return nil
	end
	local data = safeDecode(res.data)
	if type(data) ~= 'table' then return nil end
	return data.nick
end

-- ---------------------------------------------------------------------------
-- Guild lookups
-- ---------------------------------------------------------------------------

local function getGuildObject(fn, guild, withCounts)
	local guildId = resolveGuildId(guild, fn)
	if not guildId then return nil end
	local res = DiscordRequest('GET', 'guilds/' .. guildId .. (withCounts and '?with_counts=true' or ''))
	if not isOk(res) then
		logError(fn, describe(res.code, res.data))
		return nil
	end
	local data = safeDecode(res.data)
	if type(data) ~= 'table' then
		logError(fn, 'unexpected response from Discord')
		return nil
	end
	return data, guildId
end

local function GetGuildIcon(guild)
	local data, guildId = getGuildObject('GetGuildIcon', guild)
	if not data or not data.icon then return nil end
	local ext = data.icon:sub(1, 2) == 'a_' and 'gif' or 'png'
	return ('https://cdn.discordapp.com/icons/%s/%s.%s'):format(guildId, data.icon, ext)
end

local function GetGuildSplash(guild)
	local data, guildId = getGuildObject('GetGuildSplash', guild)
	if not data or not data.splash then return nil end
	return ('https://cdn.discordapp.com/splashes/%s/%s.png'):format(guildId, data.splash)
end

local function GetGuildName(guild)
	local data = getGuildObject('GetGuildName', guild)
	return data and data.name or nil
end

local function GetGuildDescription(guild)
	local data = getGuildObject('GetGuildDescription', guild)
	return data and data.description or nil
end

local function GetGuildMemberCount(guild)
	local data = getGuildObject('GetGuildMemberCount', guild, true)
	return data and data.approximate_member_count or nil
end

local function GetGuildOnlineMemberCount(guild)
	local data = getGuildObject('GetGuildOnlineMemberCount', guild, true)
	return data and data.approximate_presence_count or nil
end

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------

local API = {
	GetDiscordRoles = GetDiscordRoles,
	GetDiscordRolesEx = GetDiscordRolesEx,
	GetRoleIdFromRoleName = GetRoleIdFromRoleName,
	GetDiscordAvatar = GetDiscordAvatar,
	GetDiscordName = GetDiscordName,
	GetDiscordNickname = GetDiscordNickname,
	GetGuildIcon = GetGuildIcon,
	GetGuildSplash = GetGuildSplash,
	GetGuildName = GetGuildName,
	GetGuildDescription = GetGuildDescription,
	GetGuildMemberCount = GetGuildMemberCount,
	GetGuildOnlineMemberCount = GetGuildOnlineMemberCount,
	GetGuildRoleList = GetGuildRoleList,
	ResetCaches = ResetCaches,
	ClearCache = ClearCache,
	CheckEqual = CheckEqual,
	FetchRoleID = FetchRoleID,
	SetNickname = SetNickname,
	SetRoles = SetRoles,
	AddRole = AddRole,
	RemoveRole = RemoveRole,
	ChangeDiscordVoice = ChangeDiscordVoice,
}

for name, fn in pairs(API) do
	exports(name, fn)
end

-- ---------------------------------------------------------------------------
-- Console diagnostic: jms_discord_test <discord user ID>
-- Runs the same member lookup the whitelist uses, outside any player connection, and reports the result and time taken.
-- ---------------------------------------------------------------------------

RegisterCommand('jms_discord_test', function(source, args)
	if source ~= 0 then return end -- server console only
	local discordId = args[1]
	if not discordId or not isSnowflake(discordId) then
		print('Usage: jms_discord_test <Discord user ID>')
		return
	end
	local guildId = Config.Guild_ID and tostring(Config.Guild_ID) or ''
	if guildId == '' then
		print('[JMS_Discord_API] Config.Guild_ID is not set')
		return
	end
	local started = GetGameTimer()
	local res = DiscordRequest('GET', ('guilds/%s/members/%s'):format(guildId, discordId))
	local ms = GetGameTimer() - started
	print(('[JMS_Discord_API] test lookup: %s after %d ms'):format(describe(res.code, res.data), ms))
	if isOk(res) then
		local data = safeDecode(res.data)
		local n = type(data) == 'table' and type(data.roles) == 'table' and #data.roles or 0
		print(('[JMS_Discord_API] test lookup OK: member has %d role(s)'):format(n))
	end
end, true)

-- ---------------------------------------------------------------------------
-- Startup check
-- ---------------------------------------------------------------------------

CreateThread(function()
	if TOKEN == '' then
		logError('startup', HTTP_STATUS[-1])
		return
	end

	local ids = {}
	if Config.Guild_ID ~= nil and tostring(Config.Guild_ID) ~= '' then
		ids[#ids + 1] = tostring(Config.Guild_ID)
	else
		logError('startup', 'Config.Guild_ID is not set')
	end
	if Config.Multiguild then
		for _, id in pairs(Config.Guilds or {}) do
			if isSnowflake(id) then ids[#ids + 1] = tostring(id) end
		end
	end

	for _, guildId in ipairs(ids) do
		local res = DiscordRequest('GET', 'guilds/' .. guildId)
		if isOk(res) then
			local data = safeDecode(res.data)
			logInfo(('Connected to guild "%s" (%s)'):format(data and data.name or '?', guildId))
		else
			logError('startup', ('guild %s: %s'):format(guildId, describe(res.code, res.data)))
		end
	end
end)
