# JMS_Discord_API

A Discord REST API wrapper for FiveM servers: read a player's roles, add or remove roles, set nicknames, look up names/avatars and guild info. Other resources call it through exports.

This is a maintained fork of [Badger_Discord_API](https://github.com/JaredScar/Badger_Discord_API) by Jared Scarito (MIT). See [What changed](#what-changed-from-badger_discord_api).

## Setup

1. **Create a bot** in the [Discord Developer Portal](https://discord.com/developers/applications) and copy its token.
2. **Invite it** to your server with the permissions you need: *Manage Roles*, *Manage Nicknames* (only if you use `SetNickname`), *Move Members* (only if you use `ChangeDiscordVoice`).
3. **Move the bot's role above** any role it is supposed to assign or remove. Discord will return 403 otherwise.
4. Drop this folder into `resources/`, then in `server.cfg`:

```cfg
set discord_bot_token "YOUR_BOT_TOKEN"   # use `set`, NOT `setr` (setr sends it to every client)
ensure JMS_Discord_API
```

5. Set `Guild_ID` in `config.lua`. Players must have the Discord desktop app running when they connect, or FiveM has no Discord identifier for them.

On start, the console says which guild it connected to, or exactly what is wrong (missing token, bad token, bad guild ID).

**Never commit your bot token.** It lives in `server.cfg` on purpose; `config.lua` has no token field.

## Using it from another resource

```lua
local roles = exports.JMS_Discord_API:GetDiscordRoles(source)  -- array of role ID strings, or false
exports.JMS_Discord_API:AddRole(source, 'Founder', 'Granted in city')
```

`exports.Badger_Discord_API:...` also works (`provide` in `fxmanifest.lua`), so scripts written for the original keep working. Full tour: [`docs/example.lua`](docs/example.lua).

### Conventions

- `user` is a player source **or** a Discord ID string.
- `guild` is optional: a name from `Config.Guilds`, a guild ID, or `nil` for `Config.Guild_ID`. An unknown guild name is refused instead of silently using the main guild.
- Discord and network failures never throw. They are printed to the console and the call returns `false` or `nil`.
- Role arguments accept an ID, a `Config.RoleList` key, or a role name.
- Functions documented as returning `ok, httpCode` return `ok` first. Whether the second value survives a call from another resource is untested, so rely on `ok` only. Use `GetDiscordRolesEx` when you need to know *why* a lookup failed; it returns a single table for that reason.

### Functions

| Function | Returns |
| --- | --- |
| `GetDiscordRoles(user, guild?)` | array of role ID strings, or `false` |
| `GetDiscordRolesEx(user, guild?)` | one table: `{ status = 'ok', roles = {...} }` or `{ status = 'no_discord' \| 'not_in_guild' \| 'api_error' \| 'config_error' }` |
| `GetGuildRoleList(guild?)` | `{ [roleName] = roleId }` or `nil` |
| `GetRoleIdFromRoleName(name, guild?)` | role ID number or `nil` |
| `FetchRoleID(role, guild?)` | role ID number or `nil` |
| `CheckEqual(role1, role2, guild?)` | `true` / `false` |
| `AddRole(user, role, reason?, guild?)` | `ok, httpCode` (touches only that role) |
| `RemoveRole(user, role, reason?, guild?)` | `ok, httpCode` (touches only that role) |
| `SetRoles(user, roleList, reason?, guild?)` | `ok, httpCode` (**replaces all** the member's roles) |
| `SetNickname(user, nickname, reason?, guild?)` | `ok, httpCode` (`nil`/`""` resets) |
| `ChangeDiscordVoice(user, channelId, reason?, guild?)` | `ok, httpCode` (member must already be in voice) |
| `GetDiscordName(user)` | `'name'` or `'name#1234'`, or `nil` |
| `GetDiscordAvatar(user)` | URL or `nil` |
| `GetDiscordNickname(user, guild?)` | nickname or `nil` |
| `GetGuildName` / `GetGuildDescription` / `GetGuildIcon` / `GetGuildSplash` `(guild?)` | string / URL, or `nil` |
| `GetGuildMemberCount` / `GetGuildOnlineMemberCount` `(guild?)` | number or `nil` |
| `ClearCache(user)` / `ResetCaches()` | nothing |

## What changed from Badger_Discord_API

**Removed:** the splash screen, the chat and console advertising, `client.lua`, the version checker, `GetDiscordEmail` and `IsDiscordEmailVerified`. Discord's docs tie `email` and `verified` to the OAuth2 `email` scope, which a bot token does not have for other users.

**Fixed:**
- `AddRole` could wipe every role a player had when the role lookup failed. It now uses Discord's add/remove-one-role endpoints and never rewrites the full list.
- `AddRole`/`RemoveRole` no longer corrupt the role cache, leave holes in role arrays, or send other guilds' roles to the main guild. All write functions take a `guild` argument.
- Error handling no longer crashes on status codes it did not know about (500, 503, no response), and the startup check no longer crashes on a bad token.
- `GetGuildSplash` returned the icon hash; both it and `GetGuildIcon` used the wrong guild ID in the URL and crashed on guilds without an icon.
- Requests now have a timeout, retry on Discord's 429 rate limit, use API v10, and URL-encode the audit-log reason.

**Changed:** the bot token comes from the `discord_bot_token` convar, caches hand out copies, exports are registered with `exports()`, and the resource uses Lua 5.4.

## Tests

```sh
pip install lupa
python3 tests/run_tests.py
```

Runs the whole resource against a mock FiveM and a mock Discord. No server or network needed. Each fixed bug above has a regression test.

## License

MIT. Original work copyright (c) 2020 Jared Scarito; modifications copyright (c) 2026 SunnieP. See [LICENSE](LICENSE).
