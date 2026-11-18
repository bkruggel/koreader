--[[
    Headless benchmark driver for the async MuPDF rendering work.

    Inert unless the KOREADER_BENCHMARK environment variable is set, e.g.:

        KOREADER_BENCHMARK="pattern=steady,pages=10,interval=3.0" ./kodev run doc.pdf

    Config keys:
        pattern     steady | collision | reversal | mutation   (default steady)
                    mutation: every 3rd turn toggles the zoom mode and every
                    4th turn rotates the screen, invalidating in-flight jobs
                    on purpose (stress: obsolete-job aborts + cache churn)
        pages       number of page turns            (default 10)
        interval    seconds between turns           (default 3.0; collision ~0.5)
        settle      seconds to wait after load      (default 3.0)
        start_page  page to jump to before starting (default 2)
        zoommode    "page" (default) | "pagewidth"  (pagewidth + a window whose
                    aspect differs from the page's is what makes the full-page
                    tile exceed the cache budget while the viewport tile fits)
        gamma       gamma correction applied via GammaUpdate (default 1.0;
                    != 1 exercises the worker-side fz_gamma_pixmap step)
        saturation  saturation applied via SaturationUpdate (default 1.0;
                    != 1 exercises the worker's post-processing step)
        respectdoc  1 = do NOT force SetZoomMode/SetScrollMode: honor the
                    document sidecar's saved zoom mode & page mode (used to
                    replicate real user configurations, e.g. content+auto)
        croptaps    semicolon-separated list of Page Crop panel segments to tap after the
                    settle phase, exactly like the bottom config panel does
                    (ConfigChange + PageCrop events), e.g. "auto;none"
                    replays "turn crop on and off"
        pages_before_taps  page turns to run before croptaps (default 3)
        shot        1 = write a PNG of the screen after every turn/tap
                    (shotdir defaults to $KO_HOME/screenshots)
        shotdir     explicit directory for PNGs
        panflow     1 = drive interactions through GotoViewRel (the touch
                    path: pans within the page, wraps at the edge) instead
                    of GotoPageRel — exercises the pan → opportunistic-hint
                    cycle on zoomed/cropped pages
--]]
--]]

local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local PerfProfile = require("perfprofile")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local BenchmarkDriver = WidgetContainer:extend{
    name = "benchmarkdriver",
}

function BenchmarkDriver:onReaderReady()
    local cfg_env = os.getenv("KOREADER_BENCHMARK")
    if not cfg_env or cfg_env == "" then
        return
    end

    local cfg = {}
    for k, v in cfg_env:gmatch("([%w_]+)=([^,]*)") do
        cfg[k] = v
    end
    cfg.pattern = cfg.pattern or "steady"
    cfg.pages = tonumber(cfg.pages) or 10
    cfg.interval = tonumber(cfg.interval) or 3.0
    cfg.settle = tonumber(cfg.settle) or 3.0
    cfg.start_page = tonumber(cfg.start_page) or 2
    cfg.zoommode = cfg.zoommode or "page"
    cfg.gamma = tonumber(cfg.gamma) or 1.0
    cfg.saturation = tonumber(cfg.saturation) or 1.0
    -- colflow=0 keeps the default horizontal (line) reading direction while
    -- zoommode=columns zooms to 2x: exercises the 2D x-wrap/y-pan machine
    -- without the axis inversion (row-wise reading of a zoomed page).
    cfg.colflow = tonumber(cfg.colflow) or 1
    cfg.respectdoc = tonumber(cfg.respectdoc) or 0
    cfg.pages_before_taps = tonumber(cfg.pages_before_taps) or 3
    cfg.shot = tonumber(cfg.shot) or 0
    cfg.shotdir = cfg.shotdir or (os.getenv("KO_HOME") or "/tmp") .. "/screenshots"
    self._cfg = cfg

    if cfg.respectdoc == 1 then
        -- Replica mode: the sidecar's saved zoom/page mode is the experiment.
        -- Only force single-page mode if the doc loaded into scroll mode.
        if self.ui.view.page_scroll then
            self.ui:handleEvent(Event:new("SetScrollMode", false))
        end
        PerfProfile.log("DRIVER_RESPECTDOC zoom_mode=%s trim=%s page_scroll=%s",
            tostring(self.ui.zooming.zoom_mode),
            tostring(self.ui.document.configurable.trim_page),
            tostring(self.ui.view.page_scroll))
    else
        -- Force single-page mode; zoom mode defaults to whole-page so turns
        -- flip pages instead of panning through zoomed segments. "pagewidth"
        -- is for the constrained-cache scenario (viewport tile != full-page).
        self.ui:handleEvent(Event:new("SetScrollMode", false))
        self.ui:handleEvent(Event:new("SetZoomMode", cfg.zoommode))
    end
    if cfg.zoommode == "columns" then
        -- 2-column navigation, the on-device setup for paged academic PDFs:
        -- zoom factor 2 so the viewport spans one column (the x axis wraps
        -- between columns before the y axis wraps across pages), and —
        -- unless colflow=0 — the vertical reading direction so taps pan
        -- *down* a column and the wrap moves to the top of the next column
        -- (the left-to-right, top-to-bottom, vertical entry of
        -- zoom_direction_settings).
        self.ui:handleEvent(Event:new("SetZoomPan", {kopt_zoom_factor = 2}))
        if cfg.colflow == 1 then
            self.ui.zooming.zoom_direction_vertical = true
            self.ui.zooming.zoom_bottom_to_top = nil
        end
    end
    -- Non-default gamma/saturation ride along every render/hint request
    -- (view.state.gamma/saturation), exercising the worker's post-processing.
    if cfg.gamma ~= 1.0 then
        self.ui:handleEvent(Event:new("GammaUpdate", cfg.gamma))
    end
    if cfg.saturation ~= 1.0 then
        self.ui:handleEvent(Event:new("SaturationUpdate", cfg.saturation))
    end

    -- Jump to a deterministic start page so every run sees identical state.
    self.ui:handleEvent(Event:new("GotoPage", cfg.start_page))

    UIManager:scheduleIn(cfg.settle, function()
        self:run()
    end)
end

function BenchmarkDriver:_shot(tag)
    local cfg = self._cfg
    if cfg.shot ~= 1 then
        return
    end
    local Screen = require("device").screen
    local path = string.format("%s/%03d_%s.png", cfg.shotdir, self._shot_seq, tag)
    self._shot_seq = self._shot_seq + 1
    local ok = Screen:shot(path)
    PerfProfile.log("SHOT ok=%s path=%s", tostring(ok), path)
end

--- Dump the live view state (what the user's screen should be showing).
function BenchmarkDriver:_geomDump(tag)
    local v = self.ui.view
    local z = self.ui.zooming
    local pa, va = v.page_area, v.visible_area
    if pa and va then
        PerfProfile.log("GEOM %s page=%d trim=%s mode=%s zoom=%.3f use_bbox=%s dimen=%dx%d page_area=%.0fx%.0f+%d+%d visible=%.0fx%.0f+%d+%d",
            tag, v.state.page or -1,
            tostring(self.ui.document.configurable.trim_page),
            tostring(z.zoom_mode), v.state.zoom or 0,
            tostring(v.use_bbox),
            v.dimen.w, v.dimen.h,
            pa.w, pa.h, pa.x, pa.y,
            va.w, va.h, va.x, va.y)
    end
end

--- Fire one Page Crop panel tap exactly like the bottom config panel does:
-- ConfigChange writes the configurable, then the option's PageCrop event.
function BenchmarkDriver:_cropTap(segment)
    local values = {3, 1, 2, 0}          -- none, auto, semi-auto, manual
    local args = {"none", "auto", "semi-auto", "manual"}
    local pos
    for i, name in ipairs(args) do
        if name == segment then
            pos = i
            break
        end
    end
    if not pos then
        PerfProfile.log("CROPTAP unknown segment=%s", tostring(segment))
        return
    end
    PerfProfile.log("CROPTAP segment=%s old_trim=%s new_trim=%s",
        segment, tostring(self.ui.document.configurable.trim_page), tostring(values[pos]))
    self.ui:handleEvent(Event:new("ConfigChange", "trim_page", values[pos]))
    self.ui:handleEvent(Event:new("PageCrop", args[pos]))
    UIManager:nextTick(function()
        self:_geomDump("post_tap_" .. segment)
        self:_shot("post_tap_" .. segment)
    end)
end

function BenchmarkDriver:run()
    local cfg = self._cfg

    PerfProfile.log("DRIVER_START pattern=%s pages=%d interval=%.3f",
        cfg.pattern, cfg.pages, cfg.interval)
    logger.info("benchmark driver: starting", cfg.pattern, cfg.pages, cfg.interval)

    self._seq = 0
    self._shot_seq = 0
    local function step()
        self._seq = self._seq + 1
        if self._seq > cfg.pages then
            PerfProfile.log("DRIVER_END")
            UIManager:nextTick(function()
                UIManager:quit()
            end)
            return
        end

        -- Replay the user's crop panel taps after pages_before_taps turns.
        if cfg.croptaps and self._seq == cfg.pages_before_taps + 1 then
            local taps = {}
            for seg in cfg.croptaps:gmatch("[^;]+") do
                table.insert(taps, seg)
            end
            local function fireTaps(idx)
                if idx > #taps then
                    UIManager:scheduleIn(cfg.interval, step)
                    return
                end
                self:_cropTap(taps[idx])
                UIManager:scheduleIn(2.0, function()
                    fireTaps(idx + 1)
                end)
            end
            fireTaps(1)
            return
        end

        local dir = 1
        if cfg.pattern == "reversal" and self._seq % 2 == 0 then
            dir = -1
        end

        if cfg.pattern == "mutation" then
            -- Mutate the viewport *right before* a turn, so the pending hint
            -- for the previous state is in flight and becomes obsolete.
            if self._seq % 3 == 0 then
                self._zoom_wide = not self._zoom_wide
                PerfProfile.log("MUTATE zoom=%s", self._zoom_wide and "pagewidth" or "page")
                self.ui:handleEvent(Event:new("SetZoomMode", self._zoom_wide and "pagewidth" or "page"))
            end
            if self._seq % 4 == 0 then
                self._rot_landscape = not self._rot_landscape
                PerfProfile.log("MUTATE rotation=%d", self._rot_landscape and 1 or 0)
                self.ui:handleEvent(Event:new("SetRotationMode", self._rot_landscape and 1 or 0))
            end
        end

        PerfProfile.log("TURN_START seq=%d dir=%d", self._seq, dir)
        if cfg.panflow == 1 then
            -- The touch path (onGotoViewRel): pans within the page when the
            -- cropped page area exceeds the viewport, wraps to the next
            -- page at the edge. This is what exercises the pan →
            -- opportunistic-hint cycle that a whole-page-fit turn sequence
            -- never reaches.
            self.ui:handleEvent(Event:new("GotoViewRel", dir))
        elseif cfg.zoommode == "columns" and cfg.respectdoc ~= 1 then
            -- Column navigation follows the tap path (onGotoViewRel): each
            -- step pans within the column, wraps to the next column at the
            -- bottom, or turns the page after the last column.
            self.ui:handleEvent(Event:new("GotoViewRel", 1))
        else
            self.ui:handleEvent(Event:new("GotoPageRel", dir))
        end

        -- After the paint settles, capture what the screen actually holds.
        UIManager:scheduleIn(1.0, function()
            self:_geomDump("post_turn_" .. self._seq)
            self:_shot("turn" .. self._seq)
            UIManager:scheduleIn(math.max(cfg.interval - 1.0, 0.5), step)
        end)
    end

    step()
end

return BenchmarkDriver
