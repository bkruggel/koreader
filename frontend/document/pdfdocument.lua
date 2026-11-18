local Blitbuffer = require("ffi/blitbuffer")
local CacheItem = require("cacheitem")
local CanvasContext = require("document/canvascontext")
local DocCache = require("document/doccache")
local DocSettings = require("docsettings")
local Document = require("document/document")
local DrawContext = require("ffi/drawcontext")
local logger = require("logger")
local PerfProfile = require("perfprofile")
local TileCacheItem = require("document/tilecacheitem")
local UIManager = require("ui/uimanager")
local util = require("util")
local ffi = require("ffi")
local C = ffi.C
local pdf = nil

local PdfDocument = Document:extend{
    _document = false,
    is_pdf = true,
    dc_null = DrawContext.new(),
    koptinterface = nil,
    provider = "mupdf",
    provider_name = "MuPDF",
}

function PdfDocument:init()
    if not pdf then pdf = require("ffi/mupdf") end
    self.koptinterface = require("document/koptinterface")
    self.koptinterface:setDefaultConfigurable(self.configurable)
    -- Async rendering engine state (see hintPageAsync below)
    self._worker_broken = false
    self._worker_initialized = false
    -- 2-slot LRU of per-page display lists (see _getDisplayList): one zoomed
    -- page is hinted once per viewport slice (4-6 times in 2-column
    -- navigation), and rebuilding its display list every time re-parses the
    -- content stream (and re-loads embedded image objects) on the main
    -- thread — the source of the column-wrap stalls on image-heavy pages.
    self._display_list_slots = { {}, {} }
    local ok
    ok, self._document = pcall(pdf.openDocument, self.file)
    if not ok then
        error(self._document)  -- will contain error message
    end
    self:updateColorRendering()
    self.is_reflowable = self._document:isDocumentReflowable()
    self.reflowable_font_size = self:convertKoptToReflowableFontSize()
    -- no-op on PDF
    self:layoutDocument()
    self.is_open = true
    self.info.has_pages = true
    self.info.configurable = true
    self.render_mode = 0
    if self._document:needsPassword() then
        self.is_locked = true
    else
        self:_readMetadata()
    end
end

function PdfDocument:updateColorRendering()
    Document.updateColorRendering(self) -- will set self.render_color
    if self._document then
        self._document:setColorRendering(self.render_color)
    end
end

function PdfDocument:layoutDocument(font_size)
    if font_size then
        self.reflowable_font_size = font_size
    end
    self._document:layoutDocument(
        CanvasContext:getWidth(),
        CanvasContext:getHeight(),
        CanvasContext:scaleBySize(self.reflowable_font_size))
end

local default_font_size = 22
-- the koptreader config goes from 0.1 to 3.0, but we want a regular font size
function PdfDocument:convertKoptToReflowableFontSize(font_size)
    if font_size then
        return font_size * default_font_size
    end

    local size
    if DocSettings:hasSidecarFile(self.file) then
        local doc_settings = DocSettings:open(self.file)
        size = doc_settings:readSetting("kopt_font_size")
    end
    if size then
        return size * default_font_size
    elseif G_reader_settings:readSetting("kopt_font_size") then
        return G_reader_settings:readSetting("kopt_font_size") * default_font_size
    elseif G_defaults:readSetting("DKOPTREADER_CONFIG_FONT_SIZE") then
        return G_defaults:readSetting("DKOPTREADER_CONFIG_FONT_SIZE") * default_font_size
    else
        return default_font_size
    end
end

function PdfDocument:unlock(password)
    if not self._document:authenticatePassword(password) then
        return false
    end
    self.is_locked = false
    self:_readMetadata()
    return true
end

function PdfDocument:comparePositions(pos1, pos2)
    return self.koptinterface:comparePositions(self, pos1, pos2)
end

function PdfDocument:getPageTextBoxes(pageno)
    local hash = "textbox|"..self.file.."|"..pageno
    local cached = DocCache:check(hash)
    if not cached then
        local page = self._document:openPage(pageno)
        local text = page:getPageText()
        page:close()
        DocCache:insert(hash, CacheItem:new{text=text, size=text.size})
        return text
    else
        return cached.text
    end
end

function PdfDocument:getPanelFromPage(pageno, pos)
    return self.koptinterface:getPanelFromPage(self, pageno, pos)
end

function PdfDocument:getWordFromPosition(spos)
    return self.koptinterface:getWordFromPosition(self, spos)
end

function PdfDocument:getTextFromPositions(spos0, spos1)
    return self.koptinterface:getTextFromPositions(self, spos0, spos1)
end

function PdfDocument:getTextBoxes(pageno)
    return self.koptinterface:getTextBoxes(self, pageno)
end

function PdfDocument:getPageBoxesFromPositions(pageno, ppos0, ppos1)
    return self.koptinterface:getPageBoxesFromPositions(self, pageno, ppos0, ppos1)
end

function PdfDocument:nativeToPageRectTransform(pageno, rect)
    return self.koptinterface:nativeToPageRectTransform(self, pageno, rect)
end

function PdfDocument:getSelectedWordContext(word, nb_words, pos)
    return self.koptinterface:getSelectedWordContext(word, nb_words, pos)
end

function PdfDocument:getOCRWord(pageno, wbox)
    return self.koptinterface:getOCRWord(self, pageno, wbox)
end

function PdfDocument:getOCRText(pageno, tboxes)
    return self.koptinterface:getOCRText(self, pageno, tboxes)
end

function PdfDocument:getPageBlock(pageno, x, y)
    return self.koptinterface:getPageBlock(self, pageno, x, y)
end

function PdfDocument:getUsedBBox(pageno)
    local hash = "pgubbox|"..self.file.."|"..self.reflowable_font_size.."|"..pageno
    local cached = DocCache:check(hash)
    if cached then
        return cached.ubbox
    end
    local page = self._document:openPage(pageno)
    local used = {}
    used.x0, used.y0, used.x1, used.y1 = page:getUsedBBox()
    local pwidth, pheight = page:getSize(self.dc_null)
    -- clamp to page BBox
    if used.x0 < 0 then used.x0 = 0 end
    if used.x1 > pwidth then used.x1 = pwidth end
    if used.y0 < 0 then used.y0 = 0 end
    if used.y1 > pheight then used.y1 = pheight end
    DocCache:insert(hash, CacheItem:new{
        ubbox = used,
        size = 256, -- might be closer to 160
    })
    page:close()
    return used
end

function PdfDocument:getPageLinks(pageno)
    local hash = "pglinks|"..self.file.."|"..self.reflowable_font_size.."|"..pageno
    local cached = DocCache:check(hash)
    if cached then
        return cached.links
    end
    local page = self._document:openPage(pageno)
    local links = page:getPageLinks()
    DocCache:insert(hash, CacheItem:new{
        links = links,
        size = 64 + (8 * 32 * #links),
    })
    page:close()
    return links
end

-- returns nil if file is not a pdf, true if document is a writable pdf, false else
function PdfDocument:_checkIfWritable()
    local suffix = util.getFileNameSuffix(self.file)
    if string.lower(suffix) ~= "pdf" then return nil end
    if self.is_writable == nil then
        local handle = io.open(self.file, 'r+b')
        self.is_writable = handle ~= nil
        if handle then handle:close() end
    end
    return self.is_writable
end

local function _quadpointsFromPboxes(pboxes)
    -- will also need mupdf_h.lua to be evaluated once
    -- but this is guaranteed at this point
    local n = #pboxes
    local quadpoints = ffi.new("fz_quad[?]", n)
    for i=1, n do
        -- The order must be left bottom, right bottom, left top, right top.
        -- https://bugs.ghostscript.com/show_bug.cgi?id=695130
        quadpoints[i-1].ll.x = pboxes[i].x
        quadpoints[i-1].ll.y = pboxes[i].y + pboxes[i].h - 1
        quadpoints[i-1].lr.x = pboxes[i].x + pboxes[i].w - 1
        quadpoints[i-1].lr.y = pboxes[i].y + pboxes[i].h - 1
        quadpoints[i-1].ul.x = pboxes[i].x
        quadpoints[i-1].ul.y = pboxes[i].y
        quadpoints[i-1].ur.x = pboxes[i].x + pboxes[i].w - 1
        quadpoints[i-1].ur.y = pboxes[i].y
    end
    return quadpoints, n
end

local function _quadpointsToPboxes(quadpoints, n)
    -- reverse of previous function
    local pboxes = {}
    for i=1, n do
        table.insert(pboxes, {
            x = quadpoints[i-1].ul.x,
            y = quadpoints[i-1].ul.y,
            w = quadpoints[i-1].lr.x - quadpoints[i-1].ul.x + 1,
            h = quadpoints[i-1].lr.y - quadpoints[i-1].ul.y + 1,
        })
    end
    return pboxes
end

function PdfDocument:saveHighlight(pageno, item, annot_color)
    local can_write = self:_checkIfWritable()
    if can_write ~= true then return can_write end

    self.is_edited = true
    local quadpoints, n = _quadpointsFromPboxes(item.pboxes)
    local page = self._document:openPage(pageno)
    local annot_type = C.PDF_ANNOT_HIGHLIGHT
    if item.drawer == "lighten" then
        annot_type = C.PDF_ANNOT_HIGHLIGHT
    elseif item.drawer == "underscore" then
        annot_type = C.PDF_ANNOT_UNDERLINE
    elseif item.drawer == "strikeout" then
        annot_type = C.PDF_ANNOT_STRIKE_OUT
    end
    -- NOTE: For highlights, display style may differ compared to ReaderView:drawHighlightRect...
    --       (e.g., we do a MUL blend, MuPDF currently appears to do an OVER blend).
    page:addMarkupAnnotation(quadpoints, n, annot_type, annot_color) -- may update/adjust quadpoints
    -- Update pboxes with the possibly adjusted coordinates (this will have it updated
    -- in self.view.highlight.saved[page])
    item.pboxes = _quadpointsToPboxes(quadpoints, n)
    page:close()
    self:resetTileCacheValidity()
    self:_purgeDisplayListCache()
end

function PdfDocument:deleteHighlight(pageno, item)
    local can_write = self:_checkIfWritable()
    if can_write ~= true then return can_write end

    self.is_edited = true
    local quadpoints, n = _quadpointsFromPboxes(item.pboxes)
    local page = self._document:openPage(pageno)
        local annot = page:getMarkupAnnotation(quadpoints, n)
        if annot ~= nil then
            page:deleteAnnotation(annot)
            self:resetTileCacheValidity()
            self:_purgeDisplayListCache()
        end
        page:close()
end

function PdfDocument:updateHighlightContents(pageno, item, contents)
    local can_write = self:_checkIfWritable()
    if can_write ~= true then return can_write end

    self.is_edited = true
    local quadpoints, n = _quadpointsFromPboxes(item.pboxes)
    local page = self._document:openPage(pageno)
    local annot = page:getMarkupAnnotation(quadpoints, n)
    if annot ~= nil then
        page:updateMarkupAnnotation(annot, contents)
        self:resetTileCacheValidity()
        self:_purgeDisplayListCache()
    end
    page:close()
end

function PdfDocument:getEmbeddedAnnotations()
    local annotations = {}
    for pageno = 1, self.info.number_of_pages do
        local page = self._document:openPage(pageno)
        local page_annots = page:getEmbeddedAnnotations()
        if page_annots then
            annotations[pageno] = page_annots
        end
        page:close()
    end
    return next(annotations) and annotations
end

function PdfDocument:writeDocument()
    logger.info("writing document to", self.file)
    self._document:writeDocument(self.file)
end

function PdfDocument:close()
    -- NOTE: We can't just rely on Document:close's return code for that, as we need self._document
    --       in :writeDocument, and it would have been destroyed.
    local DocumentRegistry = require("document/documentregistry")
    if DocumentRegistry:getReferenceCount(self.file) == 1 then
        -- We're the final reference to this Document instance.
        if self.is_edited then
            self:writeDocument()
        end
    end

    Document.close(self)
end

function PdfDocument:getLinkFromPosition(pageno, pos)
    return self.koptinterface:getLinkFromPosition(self, pageno, pos)
end

function PdfDocument:clipPagePNGFile(pos0, pos1, pboxes, drawer, filename)
    return self.koptinterface:clipPagePNGFile(self, pos0, pos1, pboxes, drawer, filename)
end

function PdfDocument:clipPagePNGString(pos0, pos1, pboxes, drawer)
    return self.koptinterface:clipPagePNGString(self, pos0, pos1, pboxes, drawer)
end

function PdfDocument:getPageBBox(pageno, defer_busy)
    return self.koptinterface:getPageBBox(self, pageno, defer_busy)
end

function PdfDocument:getPageDimensions(pageno, zoom, rotation)
    return self.koptinterface:getPageDimensions(self, pageno, zoom, rotation)
end

function PdfDocument:getCoverPageImage()
    return self.koptinterface:getCoverPageImage(self)
end

function PdfDocument:findText(pattern, origin, reverse, case_insensitive, page)
    return self.koptinterface:findText(self, pattern, origin, reverse, case_insensitive, page)
end

function PdfDocument:findAllText(pattern, case_insensitive, nb_context_words, max_hits)
    return self.koptinterface:findAllText(self, pattern, case_insensitive, nb_context_words, max_hits)
end

function PdfDocument:renderPage(pageno, rect, zoom, rotation, gamma, saturation, hinting)
    return self.koptinterface:renderPage(self, pageno, rect, zoom, rotation, gamma, saturation, hinting)
end

function PdfDocument:hintPage(pageno, zoom, rotation, gamma, saturation, hint_rect, dispatch_only)
    return self.koptinterface:hintPage(self, pageno, zoom, rotation, gamma, saturation, hint_rect, dispatch_only)
end

function PdfDocument:drawPage(target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
    return self.koptinterface:drawPage(self, target, x, y, rect, pageno, zoom, rotation, gamma, saturation)
end

function PdfDocument:register(registry)
    --- Document types ---
    registry:addProvider("cbr", "application/vnd.comicbook-rar", self, 100)
    registry:addProvider("cbr", "application/vnd.rar", self, 100)
    registry:addProvider("cbt", "application/vnd.comicbook+tar", self, 100)
    registry:addProvider("cbz", "application/vnd.comicbook+zip", self, 100)
    registry:addProvider("cbz", "application/x-cbz", self, 100) -- Alternative mimetype for OPDS.
    registry:addProvider("cfb", "application/octet-stream", self, 80) -- Compound File Binary, a Microsoft general-purpose file with a file-system-like structure.
    registry:addProvider("docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", self, 80)
    registry:addProvider("docx", "application/docx", self, 80) -- Alternative mimetype for OPDS.
    registry:addProvider("epub", "application/epub+zip", self, 50)
    registry:addProvider("epub3", "application/epub+zip", self, 50)
    registry:addProvider("fb2", "application/fb2", self, 80)
    registry:addProvider("htm", "text/html", self, 90)
    registry:addProvider("html", "text/html", self, 90)
    registry:addProvider("mobi", "application/x-mobipocket-ebook", self, 80)
    registry:addProvider("pdf", "application/pdf", self, 100)
    registry:addProvider("pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation", self, 80)
    registry:addProvider("tar", "application/x-tar", self, 10)
    registry:addProvider("txt", "text/plain", self, 80)
    registry:addProvider("xhtml", "application/xhtml+xml", self, 90)
    registry:addProvider("xml", "application/xml", self, 10)
    registry:addProvider("xps", "application/oxps", self, 100)
    registry:addProvider("xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", self, 80)
    registry:addProvider("zip", "application/zip", self, 20)

    --- Picture types ---
    registry:addProvider("gif", "image/gif", self, 90)
    -- MS HD Photo == JPEG XR
    registry:addProvider("hdp", "image/vnd.ms-photo", self, 90)
    registry:addProvider("j2k", "image/jp2", self, 90)
    registry:addProvider("jp2", "image/jp2", self, 90)
    registry:addProvider("jpeg", "image/jpeg", self, 90)
    registry:addProvider("jpg", "image/jpeg", self, 90)
    -- JPEG XR
    registry:addProvider("jxr", "image/jxr", self, 90)
    registry:addProvider("pam", "image/x-portable-arbitrarymap", self, 90)
    registry:addProvider("pbm", "image/x‑portable‑bitmap", self, 90)
    registry:addProvider("pgm", "image/x‑portable‑bitmap", self, 90)
    registry:addProvider("png", "image/png", self, 90)
    registry:addProvider("pnm", "image/x‑portable‑bitmap", self, 90)
    registry:addProvider("ppm", "image/x‑portable‑bitmap", self, 90)
    registry:addProvider("svg", "image/svg+xml", self, 80)
    registry:addProvider("tif", "image/tiff", self, 90)
    registry:addProvider("tiff", "image/tiff", self, 90)
    -- Windows Media Photo == JPEG XR
    registry:addProvider("wdp", "image/vnd.ms-photo", self, 90)
end

--
-- Asynchronous background hinting (c.f., base/mupdf_worker.c)
--
-- The main thread records an immutable display list (cheap), hands it to a
-- persistent worker thread which rasterizes it on a cloned MuPDF context,
-- and polls for completion on the UIManager loop. When a synchronous
-- renderPage request collides with an in-flight hint, the job is coalesced
-- by waiting out only its remaining execution time.
--

local COALESCE_WAIT_MS = 250  -- bounded wait for the first coalescing attempt
local POLL_INTERVAL_S = 0.02  -- UIManager polling cadence for job completion

--- Initialize the background worker once per process.
-- @return true when the worker is available.
function PdfDocument:_ensureWorker()
    if self._worker_broken then
        return false
    end
    if not self._worker_initialized then
        local ok, ret = pcall(pdf.workerInit)
        if not ok then
            logger.warn("PdfDocument: cannot initialize background worker:", ret)
            self._worker_broken = true
            return false
        end
        if ret ~= 0 then
            logger.warn("PdfDocument: background worker init failed with code", ret)
            self._worker_broken = true
            return false
        end
        self._worker_initialized = true
    end
    return true
end

function PdfDocument:_colorspaceForWorker()
    if self.render_color then
        return pdf.bgr and pdf.WORKER_CS_BGR or pdf.WORKER_CS_RGB
    end
    return pdf.WORKER_CS_GRAY
end

--- Fetch the page's display list through the 2-slot LRU (MRU in slot 1).
-- The list is resolution-independent — zoom, rotation, gamma and saturation
-- live in the raster matrix the worker applies when running it — so one
-- build serves every viewport slice hinted on the page. Slot 1 is the most
-- recently used page, slot 2 the runner-up (current + predicted-next page
-- covers the entire 2-column navigation flow).
-- @return dlist (or nil on build failure), the cache entry, true when the
-- list was just built (false on a cache hit).
function PdfDocument:_getDisplayList(pageno)
    local slots = self._display_list_slots
    local entry = slots[1]
    if entry.pageno == pageno then
        return entry.dlist, entry, false
    end
    entry = slots[2]
    if entry.pageno == pageno then
        -- Refresh: promote to MRU.
        slots[2], slots[1] = slots[1], slots[2]
        return slots[1].dlist, slots[1], false
    end

    -- Miss: evict the LRU slot and build the list fresh. The document
    -- reference keeps the entry alive; the worker takes its own reference
    -- at submit time, so evicting (or closing) while a job runs is safe.
    local lru = slots[2]
    if lru.dlist then
        pdf.dropDisplayList(lru.dlist)
        lru.dlist = nil
        lru.pageno = nil
    end

    local page = self._document:openPage(pageno)
    local ok, dlist = pcall(pdf.newDisplayListFromPage, page)
    if not ok then
        page:close()
        logger.warn("PdfDocument: display list creation failed:", tostring(dlist))
        return nil
    end
    -- Per-page metadata the dispatch step would otherwise re-derive (and
    -- re-open the page for) on every hint. The bounds ride along from the
    -- same page pass; the transparency flag is stored raw and only applied
    -- when background_cleanup is active at dispatch time.
    local page_w, page_h = page:getSize(self.dc_null)
    local has_transparency_mask = pdf.pageHasTransparencyMask(page.ctx, page.page) ~= 0
    page:close()

    -- Demote the previous MRU, store the fresh build as MRU.
    slots[2] = slots[1]
    slots[1] = {
        pageno = pageno,
        dlist = dlist,
        page_bbox = { w = page_w, h = page_h },
        has_transparency_mask = has_transparency_mask,
    }
    return dlist, slots[1], true
end

--- Drop every cached display list (content mutated, or document closing).
function PdfDocument:_purgeDisplayListCache()
    for i = 1, 2 do
        local entry = self._display_list_slots[i]
        if entry.dlist then
            pdf.dropDisplayList(entry.dlist)
            entry.dlist = nil
            entry.pageno = nil
        end
    end
end

--- Whether an in-flight job's target is still worth its runtime: it matches
-- the view the user is actually looking at (the last paint, c.f.,
-- Document:drawPage recording _active_view) or the hint just parked.
-- A nil rect means the whole page, which covers any viewport slice of it.
local function _jobMatchesTarget(job, pageno, rect, zoom, rotation, gamma, saturation)
    return job.pageno == pageno
        and job.zoom == zoom
        and job.rotation == rotation
        and job.gamma == gamma
        and job.saturation == saturation
        and (job.rect == nil or (rect ~= nil and tostring(job.rect) == tostring(rect)))
end

function PdfDocument:_jobStillRelevant(job)
    local pending = self._pending_hint
    if pending and _jobMatchesTarget(job, pending.pageno, pending.rect,
            pending.zoom, pending.rotation, pending.gamma, pending.saturation) then
        return true
    end
    local active = self._active_view
    if not active then
        -- No view recorded yet (before the first paint): keep the job.
        return true
    end
    return job.pageno == active.pageno
        and job.zoom == active.zoom
        and job.rotation == active.rotation
        and job.gamma == active.gamma
        and job.saturation == active.saturation
        and (job.rect == nil or active.rect == nil
            or tostring(job.rect) == tostring(active.rect))
end

--- Park the latest opportunistic hint while the worker is busy (latest
-- wins); _dispatchPendingHint runs it as soon as the worker goes idle.
function PdfDocument:_queuePendingHint(pageno, rect, zoom, rotation, gamma, saturation)
    local job = self._in_flight_job
    if _jobMatchesTarget(job, pageno, rect, zoom, rotation, gamma, saturation) then
        -- The running job already renders exactly this target.
        PerfProfile.log("PENDING_HINT_COVERED page=%d", pageno)
        return
    end
    self._pending_hint = {
        pageno = pageno,
        rect = rect,
        zoom = zoom,
        rotation = rotation,
        gamma = gamma,
        saturation = saturation,
    }
    -- If what the worker is currently rendering is neither the active view
    -- nor the hint we just parked, nothing can consume it anymore: abort it
    -- (which dispatches the parked hint immediately, the worker idling into
    -- the new request) instead of letting the user reach the target while
    -- its tile still doesn't exist.
    if not self:_jobStillRelevant(job) then
        PerfProfile.log("PENDING_HINT_ABORT_OBSOLETE job_page=%d new_page=%d",
            job.pageno, pageno)
        self:_abortInFlightJob()
    else
        PerfProfile.log("PENDING_HINT_QUEUED page=%d job_page=%d", pageno, job.pageno)
    end
end

--- Dispatch a hint parked by _queuePendingHint; called whenever the worker
-- transitions to idle (job committed, aborted or failed).
function PdfDocument:_dispatchPendingHint()
    local pending = self._pending_hint
    if not pending then
        return
    end
    self._pending_hint = nil
    PerfProfile.log("PENDING_HINT_DISPATCH page=%d rect=%s",
        pending.pageno, tostring(pending.rect))
    -- Dispatched with dispatch_only semantics: a dedupe hit (the tile is
    -- already committed) counts as handled, never as a drop.
    if not self:hintPageAsync(pending.pageno, pending.rect, pending.zoom,
            pending.rotation, pending.gamma, pending.saturation, true) then
        -- Rare submit failure on a still-retiring worker: the next
        -- paint-anchored hint cycle regenerates the prediction anyway.
        PerfProfile.log("PENDING_HINT_DROPPED page=%d", pending.pageno)
    end
end

--- Attempt to dispatch a hint to the background worker.
-- @return true when dispatched or otherwise handled asynchronously
-- (completion is polled), false when the caller should fall back to the
-- synchronous path.
function PdfDocument:hintPageAsync(pageno, rect, zoom, rotation, gamma, saturation, dispatch_only)
    if not self:_ensureWorker() then
        return false
    end
    -- A job may have settled since the last poll tick: commit its tile (or
    -- release its bookkeeping) before treating _in_flight_job as "busy".
    self:_drainFinishedWorker()
    if self._in_flight_job then
        if dispatch_only then
            -- Opportunistic re-hint while the worker is busy: park it
            -- (latest wins) instead of dropping it on the floor — dropped
            -- wrap hints are what left the top of Column 2 cold on
            -- image-heavy pages. _dispatchPendingHint runs it the instant
            -- the worker idles. Never fall back to the synchronous path
            -- here: it would block or abort the running job.
            self:_queuePendingHint(pageno, rect, zoom, rotation, gamma, saturation)
            return true
        end
        -- Don't overlap worker requests; the synchronous fallback in
        -- Document:hintPage will coalesce with the in-flight job.
        return false
    end

    -- Compute the render target exactly like Document:renderPage would.
    local size
    if rect then
        size = rect
    else
        size = self:getPageDimensions(pageno, zoom, rotation)
    end
    local size_x = size.x or 0
    local size_y = size.y or 0

    -- Skip re-dispatching a target that was just committed (onHintPage can
    -- fire several times for the same page within one view lifecycle).
    local hash = self:getFullPageHash(pageno, zoom, rotation, gamma, saturation)
    if rect then
        hash = hash .. "|" .. tostring(rect)
    end
    if hash == self._last_committed_hash then
        -- Already committed; for opportunistic hints report success so the
        -- caller doesn't fall back to a sync render of cached content.
        if dispatch_only then
            return true
        end
        return false
    end

    -- 1. Main-thread step: fetch (or record) the immutable display list.
    --    A cache hit is free; a build parses the content stream (typically
    --    a few ms, noticeably more with embedded images — the reason the
    --    list is cached across a page's viewport slices at all).
    local perf_dlist = PerfProfile.enabled and PerfProfile.now()
    local dlist, dl_entry, dl_fresh = self:_getDisplayList(pageno)
    if not dlist then
        return false
    end
    if perf_dlist then
        PerfProfile.log("DLIST_CACHE state=%s page=%d size=%.0fx%.0f duration=%.2f",
            dl_fresh and "build" or "hit", pageno,
            dl_entry.page_bbox.w, dl_entry.page_bbox.h,
            PerfProfile.now() - perf_dlist)
    end
    local transparency_mask = (self.configurable.background_cleanup or 0) ~= 0
        and dl_entry.has_transparency_mask or false

    -- 2. Allocate the destination buffer (anchored on the job table below
    --    so LuaJIT's GC cannot reclaim it while the worker writes into it).
    local bb = Blitbuffer.new(size.w, size.h, self.render_color and self.color_bb_type or nil)
    if bb.stride ~= size.w * (self.render_color and 4 or 1) then
        -- The worker pixmap assumes the default stride; bail out otherwise.
        logger.warn("PdfDocument: unexpected blitbuffer stride, hint stays synchronous")
        return false
    end

    -- The raster matrix mirrors the synchronous path's draw_new() exactly:
    -- a plain scale (plus rotation) with NO translate — the excerpt origin
    -- is carried by the pixmap bbox alone (fz_new_pixmap_with_bbox_and_data
    -- sets pix->x/y = bbox.x0/y0, so device coords map to pixels as
    -- (device - origin)). The synchronous path does the same: its DrawContext
    -- offsets are only ever set for (never-exercised) document rotation,
    -- while the bbox anchors the render at (size_x, size_y).
    -- The worker's draw device must likewise stay IDENTITY (c.f.,
    -- mupdf_worker.c): passing the matrix there as well double-applies it —
    -- content lands at native*zoom² and is culled/clipped out for any job
    -- whose bbox doesn't start at (0,0), rendering blank tiles.
    local ctm = pdf.makeCTM(zoom, rotation, 0, 0)
    local bbox = ffi.new("fz_irect", size_x, size_y, size_x + size.w, size_y + size.h)
    local scissor = ffi.new("fz_rect", size_x, size_y, size_x + size.w, size_y + size.h)

    -- 3. Dispatch to the background thread. Gamma and saturation travel
    --    with the job: the worker applies them right after rasterizing,
    --    keeping 20-35MB buffer passes off the UI thread on commit.
    local res = pdf.workerSubmit(dlist, ctm, scissor, bbox,
        ffi.cast("unsigned char*", bb.data), bb.stride,
        self:_colorspaceForWorker(),
        self.render_color and 1 or 0,
        transparency_mask and 1 or 0,
        gamma, saturation)
    if res ~= 0 then
        logger.warn("PdfDocument: worker submit failed, hint stays synchronous")
        return false
    end
    -- The worker took its own reference (released when the job finishes);
    -- the cache's reference keeps the list alive for the remaining viewport
    -- slices of this page, so nothing to drop here.

    -- While a job is in flight, wake up an auxiliary core for it (matching
    -- the sync renderPage lifecycle in Document:renderPage/KoptInterface);
    -- released when the job commits, aborts or fails.
    CanvasContext:enableCPUCores(2)

    -- 4. Anchor the in-flight job (buffer GC anchor + coalescing metadata);
    --    the hash was computed (and de-duplicated) at the top of this method.
    self._in_flight_job = {
        pageno = pageno,
        rect = rect, -- nil for full-page hints
        size = size,
        zoom = zoom,
        rotation = rotation,
        gamma = gamma,
        saturation = saturation,
        hash = hash,
        bb = bb,
    }

    -- 5. Poll for completion on the UIManager loop (never blocks).
    local function pollWorker()
        if not self._in_flight_job then
            return
        end
        local status = pdf.workerStatus()
        if status == pdf.WORKER_RUNNING then
            UIManager:scheduleIn(POLL_INTERVAL_S, pollWorker)
        elseif status == pdf.WORKER_DONE then
            self:_commitInFlightJob()
        else -- WORKER_ERROR or WORKER_ABORTED
            PerfProfile.log("ASYNC_FAIL page=%d status=%d", self._in_flight_job.pageno, status)
            self._in_flight_job = nil
            self._in_flight_poll = nil
            CanvasContext:enableCPUCores(1)
        end
    end
    self._in_flight_poll = pollWorker
    UIManager:scheduleIn(POLL_INTERVAL_S, pollWorker)
    return true
end

--- Commit or release a job whose worker state already settled but whose
-- bookkeeping still lingers: completion polling runs on a 20 ms UIManager
-- timer, so workerStatus() can already report WORKER_DONE / WORKER_ABORTED
-- / WORKER_ERROR while _in_flight_job is still set (and a direct abort,
-- c.f. KoptInterface's probe cancellation, lands without any poller tick at
-- all). Every worker-state inspection that gates a decision — dispatching a
-- new hint, resolving against a paint, cancelling a job — must drain first,
-- or it would treat a finished job as busy (and e.g. throw away a completed
-- WORKER_DONE tile without committing it) (round 3.9).
function PdfDocument:_drainFinishedWorker()
    if not self._in_flight_job then
        return
    end
    local status = pdf.workerStatus()
    if status == pdf.WORKER_DONE then
        self:_commitInFlightJob()
    elseif status ~= pdf.WORKER_RUNNING then
        self._in_flight_job = nil
        self._in_flight_poll = nil
        CanvasContext:enableCPUCores(1)
    end
end

--- Commit a completed in-flight job to the tile cache. Gamma and saturation
-- were already applied by the worker (c.f., mupdf_worker.c).
function PdfDocument:_commitInFlightJob()
    local job = self._in_flight_job
    if not job then
        return
    end

    local t0 = PerfProfile.enabled and PerfProfile.now()

    local tile = TileCacheItem:new{
        persistent = true,
        doc_path = self.file,
        created_ts = os.time(),
        excerpt = job.size,
        pageno = job.pageno,
        bb = job.bb,
    }
    tile.size = tonumber(tile.bb.stride) * tile.bb.h + 512
    DocCache:insert(job.hash, tile)

    -- Remember the committed target so duplicate hints don't re-dispatch
    -- identical work. Only track tiles the cache actually retained; under a
    -- shrunken budget a retry (and its eventual cold paint) stays available.
    if DocCache:willAccept(tile.size) then
        self._last_committed_hash = job.hash
    end

    self._in_flight_job = nil
    self._in_flight_poll = nil
    CanvasContext:enableCPUCores(1)
    if t0 then
        PerfProfile.log("ASYNC_COMMIT_MS page=%d duration=%.2f hash=%s",
            job.pageno, PerfProfile.now() - t0, job.hash)
    end
    -- The worker just went idle: run the opportunistic hint parked for
    -- exactly this moment (c.f., _queuePendingHint), if any.
    self:_dispatchPendingHint()
end

--- Cancel the in-flight job and wait until the worker has actually stopped
-- writing into its buffer. The cooperative abort lands at the next render
-- checkpoint or saturation scanline (and the gamma pass is bounded by the
-- pixmap size), so this blocks for milliseconds — but it MUST block: the
-- old 50 ms grace period returned while a slow job was still WORKER_RUNNING,
-- and the caller then rendered on the main thread / opened pages alongside
-- it (round 3.8). Returning only when the worker is idle makes every
-- _abortInFlightJob caller safe by construction.
function PdfDocument:_abortInFlightJob()
    -- Drain first: a job that already finished must be COMMITTED, not
    -- discarded under a cancel (its tile is perfectly valid), and a job
    -- whose abort already landed only needs its bookkeeping released.
    self:_drainFinishedWorker()
    local job = self._in_flight_job
    if not job then
        return
    end
    pdf.workerAbort()
    pdf.workerWait(-1)
    self._in_flight_job = nil
    self._in_flight_poll = nil
    CanvasContext:enableCPUCores(1)
    -- The worker is idle: run the hint parked for this moment, if any.
    self:_dispatchPendingHint()
end

--- Resolve an in-flight background hint against a synchronous renderPage
-- request, implementing coalescing.
-- @return "committed" when the job's tile is now in the cache (caller
-- proceeds and finds it), "covered" when an async job already renders
-- exactly this request (only safe for hinting callers, which may skip),
-- or nil when the caller must render synchronously.
function PdfDocument:resolveInFlightHint(pageno, rect, zoom, rotation, gamma, saturation, hinting)
    -- A settled job must be committed (or released) before same_target is
    -- judged against it (round 3.9).
    self:_drainFinishedWorker()
    local job = self._in_flight_job
    if not job then
        return nil
    end

    local same_target = job.pageno == pageno
        and job.zoom == zoom
        and job.rotation == rotation
        and job.gamma == gamma
        and job.saturation == saturation
        and (job.rect == nil or (rect ~= nil and tostring(job.rect) == tostring(rect)))

    if same_target then
        if pdf.workerStatus() == pdf.WORKER_DONE then
            -- Completion raced ahead of the poller: commit now.
            self:_commitInFlightJob()
            return "committed"
        end
        if hinting then
            -- A duplicate hint; the async job already covers it.
            return "covered"
        end
        -- Synchronous user request: wait out the remaining slice of the
        -- rasterization instead of duplicating it on the main thread.
        PerfProfile.log("COALESCE page=%d", pageno)
        local status = pdf.workerWait(COALESCE_WAIT_MS)
        if status ~= pdf.WORKER_DONE then
            -- Slow worker (a background core can clock down hard on some
            -- devices): an unbounded wait here freezes the UI for seconds.
            -- Abandon the job (cooperative abort lands at the next
            -- scanline checkpoint) and let the caller render it on the
            -- much-awake main thread instead. The zombie anchoring below
            -- keeps the job's buffer safe if the abort is still pending.
            PerfProfile.log("COALESCE_TIMEOUT page=%d", pageno)
            self:_abortInFlightJob()
            return nil
        end
        self:_commitInFlightJob()
        return "committed"
    end

    -- (The old rect-less low-zoom "probe alongside" bypass is gone: letting
    -- a synchronous render proceed here was the one main-thread page render
    -- that could run while the worker is mid-job. Tiny auto-crop probes now
    -- defer at their own site instead (c.f., KoptInterface:getAutoBBox), and
    -- no caller reaches this path with rect == nil and hinting unset.)
    -- Obsolete job (different page or params): cancel it and render sync.
    self:_abortInFlightJob()
    return nil
end

function PdfDocument:close()
    self._pending_hint = nil
    if self._in_flight_job or self._in_flight_poll then
        pdf.workerAbort()
        -- Wait unconditionally: the buffer is about to be released, the
        -- worker must not touch it anymore. Cooperative abort makes this
        -- quick, and we're tearing the document down anyway.
        pdf.workerWait(-1)
        self._in_flight_job = nil
        self._in_flight_poll = nil
        CanvasContext:enableCPUCores(1)
    end
    if self._in_flight_poll then
        UIManager:unschedule(self._in_flight_poll)
        self._in_flight_poll = nil
    end
    self:_purgeDisplayListCache()
    return Document.close(self)
end

return PdfDocument
