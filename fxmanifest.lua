fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'JMS_Discord_API'
author 'SunnieP (fork of Badger_Discord_API by Jared Scarito)'
description 'Discord REST API wrapper for FiveM: roles, nicknames, member and guild lookups'
version '2.0.0'
repository 'https://github.com/SunnieP/JMS_Discord_API'

-- Lets scripts that call exports.Badger_Discord_API:<fn>() keep working
-- while this resource lives in a folder with a different name.
provide 'Badger_Discord_API'

-- Server only. Exports are registered with exports() inside server.lua.
server_scripts {
	'config.lua',
	'server.lua',
}
