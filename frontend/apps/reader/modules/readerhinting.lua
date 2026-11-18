local EventListener = require("ui/widget/eventlistener")
local Geom = require("ui/geometry")
local PerfProfile = require("perfprofile")
local pdf = require("ffi/mupdf")

local DHINTCOUNT = G_defaults:readSetting("DHINTCOUNT")

local ReaderHinting = EventListener:extend{
    hinting_states = nil, -- array
}

function ReaderHinting:init()
    self.hinting_states = {}
end

function ReaderHinting:onHintPage(_, opportunistic)
    if not self.view.hinting then return true end
    -- A cycle that starts with the worker mid-job cannot produce dispatchable
    -- params: the bbox probes it needs would either defer (answering with the
    -- stored/full-page bbox → a zoom/rect pair the next paint can never
    -- request) or race the running job (openPage on the main thread while it
    -- rasterizes). Skip the whole cycle: the paint always resolves the
    -- in-flight job (coalesce or abort), so the post-paint cycle re-fires
    -- with the worker idle (round 3.8).
    if pdf.workerStatus() == pdf.WORKER_RUNNING then
        PerfProfile.log("HINT_CYCLE_SKIPPED_BUSY opportunistic=%s",
            tostring(opportunistic))
        return true
    end
    -- Ask the paging module what the next interaction in the active reading
    -- direction would display: a pan segment on the current page (including
    -- intra-column steps and same-page column wraps), or the entry edge of
    -- an adjacent page. Hinting exactly that view (instead of blindly
    -- hinting page+1 with the current viewport) matters under a constrained
    -- tile cache, where the hint is clipped to that rect: the clip must
    -- match the next paint's request for the excerpt to be cacheable at all.
    local predicted = self.ui.paging
        and self.ui.paging.getNextViewHint
        and self.ui.paging:getNextViewHint()
    if predicted and predicted.page >= 1
            and predicted.page <= self.document.info.number_of_pages then
        -- An intra-page pan predicts a view of the page being displayed:
        -- its params are the ones that view renders with, so reuse them
        -- instead of re-evaluating (which would redo the bbox probe and
        -- could diverge from predicted.rect if the worker turned busy in
        -- between) (round 3.8).
        local zoom, use_bbox
        if predicted.page == self.view.state.page and self.view.state.zoom then
            zoom = self.view.state.zoom
            use_bbox = self.view.use_bbox
        else
            -- Pure evaluation: getZoom would apply the *future* page's crop
            -- decision to the view (c.f., ReaderZooming:getZoomForPage).
            zoom, use_bbox = self.zoom:getZoomForPage(predicted.page)
        end
        -- Evaluate every slot BEFORE the first dispatch: once slot 1 is
        -- submitted the worker is busy, and any later evaluation would hit
        -- the deferred-probe path above. Evaluated up front (worker idle),
        -- the remaining slots park in _pending_hint with REAL params and
        -- dispatch the instant slot 1's job commits (round 3.8).
        local slots = {
            { pageno = predicted.page, rect = predicted.rect,
              zoom = zoom, use_bbox = use_bbox },
        }
        -- Any remaining hint slots (DHINTCOUNT > 1) target the following
        -- pages at their forward entry edge.
        for i = 2, DHINTCOUNT do
            local pageno = self.view.state.page + i
            if pageno <= self.document.info.number_of_pages then
                local z, ub = self.zoom:getZoomForPage(pageno)
                slots[#slots + 1] = {
                    pageno = pageno,
                    rect = self:getEntryEdgeRect(pageno, 1, z, ub),
                    zoom = z, use_bbox = ub,
                }
            end
        end
        self:_dispatchHintSlots(slots, opportunistic)
        return true
    end

    -- Prediction unavailable (scroll mode, free zoom): fall back to hinting
    -- the adjacent pages at the edge they are entered on. Note we
    -- deliberately do *not* forward the current viewport here: its offset
    -- belongs to the current page, while the target page is always entered
    -- at an edge (a carried-over y offset would poison the excerpt cache
    -- key on every page transition).
    local dir = (self.ui.paging and self.ui.paging.last_view_rel_diff) or 1
    local slots = {}
    for i = 1, DHINTCOUNT do
        local pageno = self.view.state.page + (dir > 0 and i or -i)
        if pageno >= 1 and pageno <= self.document.info.number_of_pages then
            local zoom, use_bbox = self.zoom:getZoomForPage(pageno)
            slots[#slots + 1] = {
                pageno = pageno,
                rect = self:getEntryEdgeRect(pageno, dir, zoom, use_bbox),
                zoom = zoom, use_bbox = use_bbox,
            }
        end
    end
    self:_dispatchHintSlots(slots, opportunistic)
    return true
end

--- Dispatch evaluated hint slots. Slot 1 may fall back to the synchronous
-- path (it is the prediction the next paint is most likely to request);
-- the remaining slots are dispatch_only: with the worker busy (slot 1's
-- job) they park instead of dropping to a synchronous render — that
-- fallback would enter renderPage → resolveInFlightHint with a different
-- target and KILL slot 1's in-flight job to render page+2 on the main
-- thread (round 3.8).
function ReaderHinting:_dispatchHintSlots(slots, opportunistic)
    for i, slot in ipairs(slots) do
        self.document:hintPage(
            slot.pageno,
            slot.zoom,
            self.view.state.rotation,
            self.view.state.gamma,
            self.view.state.saturation,
            slot.rect,
            (i > 1 or opportunistic) and true or nil,
            slot.use_bbox)
    end
end

--- Viewport-sized rect at the edge page `pageno` is entered on: its top for
-- forward turns, its bottom for backward ones. Matches the rect the first
-- paint after the turn will request (ReaderView:recalculate anchors the view
-- at the entry edge, clamped to the page). `zoom`/`use_bbox` may be passed
-- by a caller that already evaluated the page purely; otherwise they are
-- computed here (still without touching view state).
function ReaderHinting:getEntryEdgeRect(pageno, dir, zoom, use_bbox)
    if not zoom then
        zoom, use_bbox = self.zoom:getZoomForPage(pageno)
    end
    local page_area = self.view:getPageArea(pageno, zoom, self.view.state.rotation, use_bbox, true)
    local w = math.min(self.view.dimen.w, page_area.w)
    local h = self.view.dimen.h
    if self.view.footer_visible and self.view.footer
            and not self.view.footer.settings.reclaim_height then
        h = h - self.view.footer:getHeight()
    end
    h = math.min(h, page_area.h)
    local y = page_area.y
    if dir < 0 then
        y = page_area.y + page_area.h - h
    end
    return Geom:new{ x = page_area.x, y = y, w = w, h = h }
end

function ReaderHinting:onSetHinting(hinting)
    self.view.hinting = hinting
end

function ReaderHinting:onDisableHinting()
    table.insert(self.hinting_states, self.view.hinting)
    self.view.hinting = false
    return true
end

function ReaderHinting:onRestoreHinting()
    self.view.hinting = table.remove(self.hinting_states)
    return true
end

return ReaderHinting
