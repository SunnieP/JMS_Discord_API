-- Example: how another resource uses JMS_Discord_API. This file is documentation, it is not loaded.
--
-- Call exports on the resource's folder name:
--     exports.JMS_Discord_API:<function>(...)
-- or on the legacy name, which works because fxmanifest.lua has `provide 'Badger_Discord_API'`:
--     exports.Badger_Discord_API:<function>(...)
--
-- `user`  = a player source (number) OR a Discord ID string.
-- `guild` = optional. A name from Config.Guilds, a guild ID, or nil for Config.Guild_ID.
--           Unknown names are refused (the call returns false) rather than silently using the main guild.
--
-- Discord/network failures are printed to the server console and the call returns false / nil. They do not throw.

RegisterCommand('discordtest', function(source)
	local api = exports.JMS_Discord_API

	-- Roles ------------------------------------------------------------------
	-- Returns an array of role ID strings, or false (no Discord linked / lookup failed).
	local roles = api:GetDiscordRoles(source)

	-- Same lookup, but says WHY it failed. One table back:
	--   { status = 'ok', roles = {...} }
	--   { status = 'no_discord' | 'not_in_guild' | 'api_error' | 'config_error' }
	local result = api:GetDiscordRolesEx(source)
	if result.status == 'not_in_guild' then print('not in our Discord') end
	if roles then
		for _, roleId in ipairs(roles) do print('has role', roleId) end
	end

	-- Role names -> IDs. Accepts an ID, a Config.RoleList key, or a role name in the guild.
	-- Returns a number or nil.
	local founderId = api:FetchRoleID('Founder')
	local sameRole = api:CheckEqual('Founder', 123456789012345678)

	-- Everything in the guild as { [roleName] = roleId }
	local roleList = api:GetGuildRoleList()

	-- Changing roles --------------------------------------------------------
	-- AddRole / RemoveRole touch ONE role and leave the rest alone. Each returns ok, httpCode.
	-- The role can be an ID or a name.
	-- Signature: (user, role, reason, guild)
	local ok = api:AddRole(source, 'Founder', 'Granted in city')
	api:RemoveRole(source, 'Founder', 'Revoked in city')

	-- SetRoles REPLACES all of the member's roles. Pass the complete list you want them to end up with.
	-- api:SetRoles(source, { '123456789012345678' }, 'Role sync')

	-- Nickname / voice ------------------------------------------------------
	api:SetNickname(source, 'Juice', 'Set in city')   -- nil or '' resets it
	api:SetNickname(source, nil, 'Reset')
	-- Only works if the member is already in a voice channel:
	-- api:ChangeDiscordVoice(source, '123456789012345678', 'Moved to staff VC')

	-- Lookups ---------------------------------------------------------------
	print(api:GetDiscordName(source))      -- 'juice' (new usernames) or 'juice#1234' (legacy)
	print(api:GetDiscordAvatar(source))    -- URL or nil
	print(api:GetDiscordNickname(source))  -- server nickname or nil
	print(api:GetGuildName(), api:GetGuildDescription())
	print(api:GetGuildIcon(), api:GetGuildSplash())  -- URL or nil (nil if the guild has none)
	print(api:GetGuildMemberCount(), api:GetGuildOnlineMemberCount())

	-- Caches ----------------------------------------------------------------
	-- Roles are cached (Config.CacheDiscordRolesTime). AddRole/RemoveRole/SetRoles refresh the cache
	-- for that member automatically. Force a re-read yourself with:
	api:ClearCache(source)   -- one player
	api:ResetCaches()        -- everything
end, true)
