#!/usr/bin/env python3
"""
Regression tests for JMS_Discord_API, run against a mock FiveM + Discord.

    pip install lupa
    python3 tests/run_tests.py

No network, no FiveM, no Discord. Discord is faked per test via env.route(...).
"""
import json
import os
import sys
import traceback

import lupa
from lupa import LuaRuntime

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

GUILD = "100000000000000001"
GUILD2 = "100000000000000002"
USER = "200000000000000001"
ROLE_A = "300000000000000001"
ROLE_B = "300000000000000002"
ROLE_C = "300000000000000003"
ROLE_NEW = "300000000000000009"


def to_py(v):
    if lupa.lua_type(v) == "table":
        keys = list(v.keys())
        if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
            return [to_py(v[i]) for i in range(1, len(keys) + 1)]
        if not keys:
            return []
        return {str(k): to_py(v[k]) for k in keys}
    return v


class Env:
    """A fresh Lua VM with FiveM natives mocked, config.lua + server.lua loaded."""

    def __init__(self, token="TESTTOKEN", config_lua="", players=None):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.routes = {}      # (METHOD, endpoint) -> response or list of responses
        self.sent = []        # every HTTP request made
        self.printed = []
        self.clock = 0
        self.waits = []
        self.players = players if players is not None else {"1": USER}
        self.token = token
        self.threads = []
        self.timeouts = []

        g = self.lua.globals()
        g.py_http = self._http
        g.py_print = lambda s: self.printed.append(s)
        g.py_now = lambda: self.clock
        g.py_ident = lambda src, kind: f"discord:{self.players[src]}" if (kind == "discord" and src in self.players) else None
        g.py_convar = lambda name, default: self.token if name == "discord_bot_token" else default
        g.py_json_dec = self._json_dec
        g.py_json_enc = self._json_enc
        g.py_wait = lambda ms: self.waits.append(ms)
        g.py_settimeout = lambda ms, cb: self.timeouts.append((ms, cb))
        g.py_thread = lambda fn: self.threads.append(fn)
        g.py_fire_timeouts = self._fire_timeouts

        self.lua.execute(PRELUDE)
        self.lua.execute(open(os.path.join(REPO, "config.lua")).read())
        self.lua.execute('Config.Guild_ID = "%s"' % GUILD)
        if config_lua:
            self.lua.execute(config_lua)
        self.lua.execute(open(os.path.join(REPO, "server.lua")).read())
        self.exports = self.lua.eval("__exports")

    # --- mock plumbing -----------------------------------------------------
    def _json_dec(self, s):
        try:
            return self._to_lua(json.loads(s))
        except Exception:
            return None

    def _json_enc(self, t):
        return json.dumps(to_py(t))

    def _to_lua(self, o):
        if isinstance(o, dict):
            return self.lua.table_from({k: self._to_lua(v) for k, v in o.items()})
        if isinstance(o, list):
            return self.lua.table_from([self._to_lua(v) for v in o])
        return o

    def route(self, method, endpoint, code=200, data=None, headers=None):
        resp = {"code": code, "data": data, "headers": headers or {}}
        self.routes.setdefault((method, endpoint), []).append(resp)

    def never_respond(self, method, endpoint):
        self.routes.setdefault((method, endpoint), []).append(None)

    def _http(self, url, method, body, headers):
        endpoint = url.replace("https://discord.com/api/v10/", "", 1)
        hdrs = {str(k): v for k, v in headers.items()} if headers else {}
        try:
            parsed = json.loads(body) if body else None
        except Exception:
            parsed = body
        self.sent.append({"url": url, "method": method, "endpoint": endpoint, "body": parsed, "headers": hdrs})
        queue = self.routes.get((method, endpoint))
        if queue is None:
            return 404, json.dumps({"message": "Unknown route in test"}), self._to_lua({})
        resp = queue[0] if len(queue) == 1 else queue.pop(0)
        if resp is None:
            return None
        data = json.dumps(resp["data"]) if isinstance(resp["data"], (dict, list)) else resp["data"]
        return resp["code"], data, self._to_lua(resp["headers"])

    def _fire_timeouts(self):
        pending, self.timeouts = self.timeouts, []
        for _ms, cb in pending:
            cb()

    def run_threads(self):
        threads, self.threads = self.threads, []
        for t in threads:
            t()

    # --- helpers for tests -------------------------------------------------
    def call(self, name, *args):
        res = self.exports[name](*[self._to_lua(a) for a in args])
        if isinstance(res, tuple):
            return tuple(to_py(r) for r in res)
        return to_py(res)

    def ok(self, name, *args):
        """First return value (the success flag) of a write call."""
        res = self.call(name, *args)
        return res[0] if isinstance(res, tuple) else res

    def requests(self, method=None):
        return [r for r in self.sent if method is None or r["method"] == method]

    def output(self):
        return "\n".join(self.printed)


PRELUDE = r"""
__exports = {}
exports = setmetatable({}, { __call = function(_, name, fn) __exports[name] = fn end })

local function tostr(...) local t = {} for i = 1, select('#', ...) do t[#t+1] = tostring((select(i, ...))) end return table.concat(t, ' ') end
print = function(...) py_print(tostr(...)) end

json = { encode = function(t) return py_json_enc(t) end, decode = function(s) return py_json_dec(s) end }

GetConvar = function(name, default) return py_convar(name, default) end
GetGameTimer = function() return py_now() end
GetPlayerIdentifierByType = function(src, kind) return py_ident(src, kind) end
GetCurrentResourceName = function() return "JMS_Discord_API" end
CreateThread = function(fn) py_thread(fn) end
Wait = function(ms) py_wait(ms) end
SetTimeout = function(ms, cb) py_settimeout(ms, cb) end

-- Minimal promise: Await on an unresolved promise simulates time passing (fires pending timeouts).
promise = { new = function()
  local p = { done = false }
  function p:resolve(v) if not self.done then self.done = true; self.v = v end end
  return p
end }
Citizen = { Await = function(p)
  if not p.done then py_fire_timeouts() end
  return p.v
end }

PerformHttpRequest = function(url, cb, method, body, headers)
  local code, data, h = py_http(url, method, body, headers)
  if code ~= nil then cb(code, data, h) end
end
"""

# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------

RESULTS = []


def test(fn):
    try:
        fn()
        RESULTS.append((fn.__name__, True, ""))
    except AssertionError as e:
        RESULTS.append((fn.__name__, False, str(e) or "assertion failed"))
    except Exception:
        RESULTS.append((fn.__name__, False, traceback.format_exc(limit=3)))
    return fn


member_ep = f"guilds/{GUILD}/members/{USER}"


@test
def adds_role_with_put_and_never_reads_first():
    """Bug 1: the old AddRole read all roles, then PATCHed the whole list back."""
    e = Env()
    e.route("PUT", f"{member_ep}/roles/{ROLE_NEW}", 204)
    ok, code = e.call("AddRole", 1, ROLE_NEW, "promoted")
    assert ok is True and code == 204, (ok, code)
    assert [r["method"] for r in e.sent] == ["PUT"], e.sent
    assert e.sent[0]["url"].startswith("https://discord.com/api/v10/"), "must pin API v10"


@test
def failed_add_role_does_not_wipe_roles():
    """Bug 1 (critical): a failed lookup used to PATCH roles=[new role] and wipe everything."""
    e = Env()
    e.route("PUT", f"{member_ep}/roles/{ROLE_NEW}", 429, {"message": "slow down", "retry_after": 0.1})
    ok = e.ok("AddRole", 1, ROLE_NEW)
    assert ok is False
    assert not e.requests("PATCH"), "must never PATCH the member's role list on a failed add"


@test
def remove_role_uses_delete():
    """Bug 4: RemoveRole used to leave nil holes in the roles array."""
    e = Env()
    e.route("DELETE", f"{member_ep}/roles/{ROLE_B}", 204)
    assert e.ok("RemoveRole", 1, ROLE_B) is True
    assert [r["method"] for r in e.sent] == ["DELETE"]


@test
def role_cache_returns_copies_and_hits_cache():
    """Bug 3: callers got the live cache table, so mutating it corrupted everyone's view."""
    e = Env()
    e.route("GET", member_ep, 200, {"roles": [ROLE_A, ROLE_B]})
    e.call("GetDiscordRoles", 1)  # warm the cache (a miss returns a fresh copy, so it proves nothing)
    # Mutate a cache HIT inside Lua (converting to a Python list would hide aliasing).
    e.lua.execute('local r = __exports.GetDiscordRoles(1); r[#r + 1] = "INJECTED"')
    second = e.call("GetDiscordRoles", 1)
    assert second == [ROLE_A, ROLE_B], second
    assert len(e.requests("GET")) == 1, "second call should come from cache"


@test
def rejected_add_does_not_poison_cache():
    """Bug 3: AddRole used to append to the cached list even when Discord said 403."""
    e = Env()
    e.route("GET", member_ep, 200, {"roles": [ROLE_A]})
    e.route("PUT", f"{member_ep}/roles/{ROLE_NEW}", 403, {"message": "Missing Permissions"})
    e.call("GetDiscordRoles", 1)
    assert e.ok("AddRole", 1, ROLE_NEW) is False
    assert e.call("GetDiscordRoles", 1) == [ROLE_A]


@test
def successful_write_invalidates_cache():
    e = Env()
    e.route("GET", member_ep, 200, {"roles": [ROLE_A]})
    e.route("GET", member_ep, 200, {"roles": [ROLE_A, ROLE_NEW]})
    e.route("PUT", f"{member_ep}/roles/{ROLE_NEW}", 204)
    assert e.call("GetDiscordRoles", 1) == [ROLE_A]
    e.call("AddRole", 1, ROLE_NEW)
    assert e.call("GetDiscordRoles", 1) == [ROLE_A, ROLE_NEW], "cache must be refreshed after a write"


@test
def failed_lookup_returns_false_not_crash():
    e = Env()
    e.route("GET", member_ep, 500, None)
    assert e.call("GetDiscordRoles", 1) is False


@test
def unknown_status_codes_do_not_crash():
    """Bug 6: error_codes_defined had no entry for 500/503/0, so logging itself crashed."""
    for code in (500, 503, 0, 418):
        e = Env()
        e.route("GET", f"users/{USER}", code, None)
        assert e.call("GetDiscordName", 1) is None
        assert "GetDiscordName" in e.output()


@test
def no_response_times_out_instead_of_hanging():
    """Bug 9: the old busy-wait loop had no timeout."""
    e = Env()
    e.never_respond("GET", f"users/{USER}")
    assert e.call("GetDiscordName", 1) is None
    assert "No response from Discord" in e.output()


@test
def retries_429_then_succeeds():
    """Bug 9: no 429 handling."""
    e = Env()
    e.route("GET", f"users/{USER}", 429, {"message": "limited", "retry_after": 0.2}, {"Retry-After": "0.2"})
    e.route("GET", f"users/{USER}", 200, {"username": "juice", "discriminator": "0"})
    assert e.call("GetDiscordName", 1) == "juice"
    assert len(e.requests("GET")) == 2 and len(e.waits) == 1


@test
def gives_up_after_max_attempts():
    e = Env()
    e.route("GET", f"users/{USER}", 429, {"retry_after": 0.1})
    assert e.call("GetDiscordName", 1) is None
    assert len(e.requests("GET")) == 3


@test
def missing_token_is_a_clear_error_not_a_crash():
    e = Env(token="")
    assert e.call("GetDiscordName", 1) is None
    assert not e.sent, "must not send requests without a token"
    assert "discord_bot_token" in e.output()
    e.run_threads()
    assert "discord_bot_token" in e.output()


@test
def sends_bot_auth_and_url_encoded_reason():
    e = Env()
    e.route("PUT", f"{member_ep}/roles/{ROLE_A}", 204)
    e.call("AddRole", 1, ROLE_A, "Promoted by Sunnie ✨")
    h = e.sent[0]["headers"]
    assert h["Authorization"] == "Bot TESTTOKEN", h
    assert h["X-Audit-Log-Reason"] == "Promoted%20by%20Sunnie%20%E2%9C%A8", h["X-Audit-Log-Reason"]


@test
def set_roles_sends_strings_and_replaces():
    e = Env()
    e.route("PATCH", member_ep, 200, {})
    assert e.ok("SetRoles", 1, [ROLE_A, ROLE_C], "sync") is True
    assert e.sent[0]["body"] == {"roles": [ROLE_A, ROLE_C]}, e.sent[0]["body"]


@test
def set_nickname_and_reset():
    e = Env()
    e.route("PATCH", member_ep, 200, {})
    e.call("SetNickname", 1, "Juice", "rename")
    e.call("SetNickname", 1, None, "reset")
    assert e.sent[0]["body"] == {"nick": "Juice"} and e.sent[1]["body"] == {"nick": ""}


@test
def voice_move_sends_channel_as_string():
    e = Env()
    e.route("PATCH", member_ep, 200, {})
    e.call("ChangeDiscordVoice", 1, "400000000000000001", "move")
    assert e.sent[0]["body"] == {"channel_id": "400000000000000001"}


@test
def guild_icon_and_splash_urls():
    """Bug 8: splash used the icon hash; both used the main guild ID regardless of the guild asked for."""
    e = Env(config_lua=f'Config.Guilds = {{ second = "{GUILD2}" }}')
    e.route("GET", f"guilds/{GUILD}", 200, {"icon": "a_iconhash", "splash": "splashhash", "name": "Main"})
    e.route("GET", f"guilds/{GUILD2}", 200, {"icon": "plainhash", "name": "Second"})
    assert e.call("GetGuildIcon") == f"https://cdn.discordapp.com/icons/{GUILD}/a_iconhash.gif"
    assert e.call("GetGuildSplash") == f"https://cdn.discordapp.com/splashes/{GUILD}/splashhash.png"
    assert e.call("GetGuildIcon", "second") == f"https://cdn.discordapp.com/icons/{GUILD2}/plainhash.png"
    assert e.call("GetGuildSplash", "second") is None, "no splash set on that guild"


@test
def guild_without_icon_returns_nil():
    """Bug 8: used to crash indexing a nil icon."""
    e = Env()
    e.route("GET", f"guilds/{GUILD}", 200, {"name": "Main"})
    assert e.call("GetGuildIcon") is None


@test
def guild_counts():
    e = Env()
    e.route("GET", f"guilds/{GUILD}?with_counts=true", 200, {"approximate_member_count": 120, "approximate_presence_count": 45})
    assert e.call("GetGuildMemberCount") == 120
    assert e.call("GetGuildOnlineMemberCount") == 45


@test
def unknown_guild_name_is_refused_not_redirected():
    """The old code silently used the main guild for an unknown name, so writes could hit the wrong server."""
    e = Env()
    assert e.ok("AddRole", 1, ROLE_A, "x", "typo-guild") is False
    assert e.call("GetDiscordRoles", 1, "typo-guild") is False
    assert not e.sent, "no request should be sent for an unknown guild"


@test
def writes_target_the_requested_guild_only():
    """Bug 2: all writes were hardcoded to Config.Guild_ID."""
    e = Env(config_lua=f'Config.Guilds = {{ second = "{GUILD2}" }}')
    e.route("PUT", f"guilds/{GUILD2}/members/{USER}/roles/{ROLE_A}", 204)
    assert e.ok("AddRole", 1, ROLE_A, "x", "second") is True
    assert e.sent[0]["endpoint"].startswith(f"guilds/{GUILD2}/")


@test
def multiguild_merges_and_dedupes_for_reads():
    e = Env(config_lua=f'Config.Multiguild = true; Config.Guilds = {{ main = "{GUILD}", second = "{GUILD2}" }}')
    e.route("GET", member_ep, 200, {"roles": [ROLE_A, ROLE_B]})
    e.route("GET", f"guilds/{GUILD2}/members/{USER}", 200, {"roles": [ROLE_B, ROLE_C]})
    assert e.call("GetDiscordRoles", 1) == [ROLE_A, ROLE_B, ROLE_C]
    assert e.call("GetDiscordRoles", 1, "second") == [ROLE_B, ROLE_C], "explicit guild returns just that guild"


@test
def multiguild_write_never_sends_other_guilds_roles():
    """Bug 2: AddRole used to PATCH the merged cross-guild role list to the main guild."""
    e = Env(config_lua=f'Config.Multiguild = true; Config.Guilds = {{ second = "{GUILD2}" }}')
    e.route("PUT", f"{member_ep}/roles/{ROLE_NEW}", 204)
    e.call("AddRole", 1, ROLE_NEW)
    assert [r["method"] for r in e.sent] == ["PUT"], e.sent


@test
def player_without_discord_is_handled():
    e = Env(players={})
    assert e.call("GetDiscordRoles", 1) is False
    assert e.ok("AddRole", 1, ROLE_A) is False
    assert e.call("GetDiscordName", 1) is None
    assert not e.sent


@test
def accepts_raw_discord_id_as_user():
    e = Env(players={})
    e.route("GET", member_ep, 200, {"roles": [ROLE_A]})
    assert e.call("GetDiscordRoles", USER) == [ROLE_A]


@test
def names_pomelo_and_legacy():
    e = Env()
    e.route("GET", f"users/{USER}", 200, {"username": "juice", "discriminator": "0"})
    assert e.call("GetDiscordName", 1) == "juice"
    e2 = Env()
    e2.route("GET", f"users/{USER}", 200, {"username": "juice", "discriminator": "1234"})
    assert e2.call("GetDiscordName", 1) == "juice#1234"


@test
def avatar_urls_and_cache():
    e = Env()
    e.route("GET", f"users/{USER}", 200, {"username": "j", "avatar": "a_gifhash"})
    url = e.call("GetDiscordAvatar", 1)
    assert url == f"https://cdn.discordapp.com/avatars/{USER}/a_gifhash.gif", url
    e.call("GetDiscordAvatar", 1)
    assert len(e.requests("GET")) == 1, "second call should be cached"
    e.clock += 11 * 60 * 1000
    e.call("GetDiscordAvatar", 1)
    assert len(e.requests("GET")) == 2, "cache should expire"


@test
def role_cache_expires():
    e = Env()
    e.route("GET", member_ep, 200, {"roles": [ROLE_A]})
    e.call("GetDiscordRoles", 1)
    e.clock += 61 * 1000
    e.call("GetDiscordRoles", 1)
    assert len(e.requests("GET")) == 2


@test
def role_names_resolve_and_compare():
    e = Env(config_lua='Config.RoleList = { FounderRef = "300000000000000001" }')
    e.route("GET", f"guilds/{GUILD}/roles", 200, [{"id": ROLE_A, "name": "Founder"}, {"id": ROLE_B, "name": "Staff"}])
    assert e.call("GetGuildRoleList") == {"Founder": ROLE_A, "Staff": ROLE_B}
    assert e.call("GetRoleIdFromRoleName", "Staff") == int(ROLE_B)
    assert e.call("GetRoleIdFromRoleName", "Nope") is None
    assert e.call("FetchRoleID", "FounderRef") == int(ROLE_A)
    assert e.call("CheckEqual", "FounderRef", "Founder") is True
    assert e.call("CheckEqual", "Founder", "Staff") is False
    assert e.call("CheckEqual", "Founder", "Missing") is False
    assert len(e.requests("GET")) == 1, "role list should be cached"


@test
def add_role_by_name():
    e = Env()
    e.route("GET", f"guilds/{GUILD}/roles", 200, [{"id": ROLE_A, "name": "Founder"}])
    e.route("PUT", f"{member_ep}/roles/{ROLE_A}", 204)
    assert e.ok("AddRole", 1, "Founder", "by name") is True


@test
def startup_check_reports_bad_token_without_crashing():
    """Bug 7: the old startup check crashed when Discord returned a JSON error body."""
    e = Env()
    e.route("GET", f"guilds/{GUILD}", 401, {"message": "401: Unauthorized", "code": 0})
    e.run_threads()
    out = e.output()
    assert "token is invalid" in out and "401: Unauthorized" in out, out


@test
def startup_check_reports_success():
    e = Env()
    e.route("GET", f"guilds/{GUILD}", 200, {"name": "Lover Lounge", "id": GUILD})
    e.run_threads()
    assert "Connected to guild" in e.output() and "Lover Lounge" in e.output()


@test
def reset_and_clear_cache():
    e = Env()
    e.route("GET", member_ep, 200, {"roles": [ROLE_A]})
    e.call("GetDiscordRoles", 1)
    e.call("ClearCache", 1)
    e.call("GetDiscordRoles", 1)
    assert len(e.requests("GET")) == 2
    e.call("ResetCaches")
    e.call("GetDiscordRoles", 1)
    assert len(e.requests("GET")) == 3


@test
def no_advertising_left():
    src = open(os.path.join(REPO, "server.lua")).read().lower() + open(os.path.join(REPO, "config.lua")).read().lower()
    for needle in ("zap-hosting", "thewolfbadger", "gyazo", "discord.gg/wjb5vfz", "presentcard"):
        assert needle not in src, f"found leftover: {needle}"


@test
def token_is_not_in_the_repo():
    cfg = open(os.path.join(REPO, "config.lua")).read()
    assert "Bot_Token" not in cfg, "token must come from the discord_bot_token convar"


if __name__ == "__main__":
    width = max(len(n) for n, _, _ in RESULTS)
    failed = 0
    for name, ok, detail in RESULTS:
        print(f"{'PASS' if ok else 'FAIL'}  {name.ljust(width)}" + ("" if ok else f"\n      {detail}"))
        failed += 0 if ok else 1
    print(f"\n{len(RESULTS) - failed}/{len(RESULTS)} passed")
    sys.exit(1 if failed else 0)
