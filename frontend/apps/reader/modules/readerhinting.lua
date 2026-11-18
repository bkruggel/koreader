local EventListener = require("ui/widget/eventlistener")
local Geom = require("ui/geometry")

local DHINTCOUNT = G_defaults:readSetting("DHINTCOUNT")

local ReaderHinting = EventListener:extend{
    hinting_states = nil, -- array
}

function ReaderHinting:init()
    self.hinting_states = {}
end

function ReaderHinting:onHintPage(_, opportunistic)
    if not self.view.hinting then return true end
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
        -- Pure evaluation: getZoom would apply the *future* page's crop
        -- decision to the view (c.f., ReaderZooming:getZoomForPage).
        local zoom, use_bbox = self.zoom:getZoomForPage(predicted.page)
        self.document:hintPage(
            predicted.page,
            zoom,
            self.view.state.rotation,
            self.view.state.gamma,
            self.view.state.saturation,
            predicted.rect,
            opportunistic,
            use_bbox)
        -- Any remaining hint slots (DHINTCOUNT > 1) target the following
        -- pages at their forward entry edge.
        for i = 2, DHINTCOUNT do
            local pageno = self.view.state.page + i
            if pageno <= self.document.info.number_of_pages then
                local z, ub = self.zoom:getZoomForPage(pageno)
                self.document:hintPage(
                    pageno,
                    z,
                    self.view.state.rotation,
                    self.view.state.gamma,
                    self.view.state.saturation,
                    self:getEntryEdgeRect(pageno, 1, z, ub),
                    opportunistic,
                    ub)
            end
        end
        return true
    end

    -- Prediction unavailable (scroll mode, free zoom): fall back to hinting
    -- the adjacent pages at the edge they are entered on. Note we
    -- deliberately do *not* forward the current viewport here: its offset
    -- belongs to the current page, while the target page is always entered
    -- at an edge (a carried-over y offset would poison the excerpt cache
    -- key on every page transition).
    local dir = (self.ui.paging and self.ui.paging.last_view_rel_diff) or 1
    for i = 1, DHINTCOUNT do
        local pageno = self.view.state.page + (dir > 0 and i or -i)
        if pageno >= 1 and pageno <= self.document.info.number_of_pages then
            local zoom, use_bbox = self.zoom:getZoomForPage(pageno)
            self.document:hintPage(
                pageno,
                zoom,
                self.view.state.rotation,
                self.view.state.gamma,
                self.view.state.saturation,
                self:getEntryEdgeRect(pageno, dir, zoom, use_bbox),
                opportunistic,
                use_bbox)
        end
    end
    return true
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
    local page_area = self.view:getPageArea(pageno, zoom, self.view.state.rotation, use_bbox)
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
