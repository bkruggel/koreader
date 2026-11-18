--[[
Minimal [PERF_PROFILE] instrumentation helper.

Emits machine-parseable timing lines on stdout for the async rendering
benchmark harness (tools/parse_perf_log.py). Inert unless the
KOREADER_PERF environment variable is set to "1".
--]]

local ffi = require("ffi")
require("ffi/posix_h")

local C = ffi.C
local enabled = os.getenv("KOREADER_PERF") == "1"

local PerfProfile = {
    enabled = enabled,
}

-- Wall clock in milliseconds, consistent with the C-side instrumentation.
function PerfProfile.now()
    local tv = ffi.new("struct timeval")
    C.gettimeofday(tv, nil)
    return tonumber(tv.tv_sec) * 1000 + tonumber(tv.tv_usec) / 1000
end

function PerfProfile.log(fmt, ...)
    if not enabled then
        return
    end
    -- The metric tag stays first; every line carries a shared millisecond
    -- timestamp (appended last) so the parser can correlate markers
    -- (turn start -> first paint) without relying on log-level timestamps.
    -- NB: the timestamp can't simply follow `...` in the call (a non-final
    -- vararg expression is truncated to a single value); collect the args.
    local nargs = select("#", ...)
    local args = {...}
    args[nargs + 1] = PerfProfile.now()
    print(string.format("[PERF_PROFILE] " .. fmt .. " ts=%.3f", unpack(args, 1, nargs + 1)))
end

return PerfProfile
