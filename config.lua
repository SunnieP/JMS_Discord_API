-- The bot token is NOT stored here. Put it in server.cfg (never commit it):
--     set discord_bot_token "YOUR_BOT_TOKEN"
-- Use `set`, not `setr` (setr would replicate the token to every client).

Config = {
	Guild_ID = '', -- ID of your Discord server (your primary server if Multiguild is on)

	Multiguild = false, -- true = GetDiscordRoles() with no guild argument also merges roles from every guild in Guilds
	Guilds = {
		-- ["main"] = "123456789012345678",
	},

	-- Optional friendly names for role IDs, usable anywhere a role is accepted:
	-- RoleList = { Founder = "123456789012345678" },
	RoleList = {},

	DebugScript = false, -- true = extra console output (errors are always printed)

	CacheDiscordRoles = true, -- false = ask Discord every time (you will hit rate limits fast)
	CacheDiscordRolesTime = 60, -- seconds a player's roles stay cached
	RoleListCacheTime = 300, -- seconds the guild role list (name -> id) stays cached
}
