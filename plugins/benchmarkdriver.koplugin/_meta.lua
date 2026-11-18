local _ = require("gettext")
return {
    fullname = _("Benchmark driver"),
    description = _([[
Headless benchmark driver for profiling page turn performance.
Only active when the KOREADER_BENCHMARK environment variable is set.]]),
}
