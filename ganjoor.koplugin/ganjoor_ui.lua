--[[
Widgets of the Ganjoor plugin: RTL-mirrored menu / poets grid / text viewer, the poem view
(hemistichs side by side, paginated) and the font preview.
]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Core = require("ganjoor_core")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local InputDialog = require("ui/widget/inputdialog")
local _ = require("gettext")
local Screen = Device.screen

local UI = {}

-- Containers apply BD.mirroredUILayout() at paint time, so flipping it around
-- init/paint mirrors just this plugin's widgets even on an LTR-language UI.
local function withRTLMirroring(fn, ...)
    if BD.mirroredUILayout() then
        return fn(...)
    end
    BD.invert()
    local ok, res = pcall(fn, ...)
    BD.resetInvert()
    if not ok then
        error(res)
    end
    return res
end
UI.withRTLMirroring = withRTLMirroring

-- target must provide applyFilter(query or nil) and may hold filter_query
local function showFilterDialog(target)
    local dialog
    dialog = InputDialog:new{
        title = _("Filter this list"),
        input = target.filter_query or "",
        buttons = {{
            {
                text = _("Clear"),
                callback = function()
                    UIManager:close(dialog)
                    target:applyFilter(nil)
                end,
            },
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Filter"),
                is_enter_default = true,
                callback = function()
                    local query = dialog:getInputText()
                    UIManager:close(dialog)
                    target:applyFilter(query ~= "" and query or nil)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function filterItems(items, query)
    local needle = Core.normalize(query)
    local filtered = {}
    for _i, item in ipairs(items) do
        if item.text and Core.normalize(item.text):find(needle, 1, true) then
            table.insert(filtered, item)
        end
    end
    if #filtered == 0 then
        table.insert(filtered, { text = _("(no matches)") })
    end
    return filtered
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

local GanjoorMenu = Menu:extend{
    is_borderless = true,
    is_popout = false,
    covers_fullscreen = true,
    title_shrink_font_to_fit = true,
    title_bar_left_icon = "appbar.search",
}

function GanjoorMenu:init()
    return withRTLMirroring(Menu.init, self)
end

function GanjoorMenu:updateItems(...)
    return withRTLMirroring(Menu.updateItems, self, ...)
end

function GanjoorMenu:paintTo(...)
    return withRTLMirroring(Menu.paintTo, self, ...)
end

function GanjoorMenu:onSwipe(...)
    return withRTLMirroring(Menu.onSwipe, self, ...)
end

function GanjoorMenu:onMenuSelect(item)
    if item.callback then
        item.callback()
    end
    return true
end

function GanjoorMenu:onMenuHold(item)
    if item.hold_callback then
        item.hold_callback()
    end
    return true
end

function GanjoorMenu:onLeftButtonTap()
    showFilterDialog(self)
end

function GanjoorMenu:applyFilter(query)
    self.filter_query = query
    if not query then
        self:switchItemTable(self.base_title, self.all_items, 1)
        return
    end
    self:switchItemTable(self.base_title .. " \u{2013} " .. query, filterItems(self.all_items, query), 1)
end

UI.Menu = GanjoorMenu

-- ---------------------------------------------------------------------------
-- Plain text viewer (poet biographies)
-- ---------------------------------------------------------------------------

local GanjoorViewer = TextViewer:extend{
    justified = false,
    para_direction_rtl = true,
    title_multilines = true,
}

function GanjoorViewer:init()
    return withRTLMirroring(TextViewer.init, self)
end

function GanjoorViewer:paintTo(...)
    return withRTLMirroring(TextViewer.paintTo, self, ...)
end

UI.Viewer = GanjoorViewer

-- ---------------------------------------------------------------------------
-- Poets grid: paginated cards, first item at the top right
-- ---------------------------------------------------------------------------

local GanjoorGrid = InputContainer:extend{
    title = nil,
    items = nil,
    on_menu = nil, -- callback of the menu button in the footer
    covers_fullscreen = true,
}

function GanjoorGrid:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    if Device:isTouchDevice() then
        self.ges_events.Swipe = {
            GestureRange:new{ ges = "swipe", range = self.dimen },
        }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PrevPage = { { Device.input.group.PgBack } }
    end
    self.all_items = self.items
    self.page = 1
    self:update()
end

function GanjoorGrid:_update()
    local pad = Size.padding.large
    local title_bar = TitleBar:new{
        title = self.filter_query
            and (self.title .. " \u{2013} " .. self.filter_query)
            or self.title,
        width = self.screen_w,
        fullscreen = true,
        with_bottom_line = true,
        title_shrink_font_to_fit = true,
        left_icon = "appbar.search",
        left_icon_tap_callback = function() showFilterDialog(self) end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local ncols = math.max(2, math.floor(self.screen_w / Screen:scaleBySize(180)))
    local cell_w = math.floor((self.screen_w - pad * (ncols + 1)) / ncols)
    local probe = Button:new{
        text = "\u{06AF}\u{0646}\u{062C}", -- representative Persian glyphs for cell height
        width = cell_w,
        radius = Size.radius.window,
        show_parent = self,
    }
    local cell_h = probe:getSize().h

    -- The widgets are mirrored (see withRTLMirroring): the first button is the rightmost one,
    -- and the grid is filled right to left.
    local prev_btn = Button:new{
        icon = "chevron.right",
        bordersize = 0,
        show_parent = self,
        callback = function() self:goToPage(self.page - 1) end,
    }
    local next_btn = Button:new{
        icon = "chevron.left",
        bordersize = 0,
        show_parent = self,
        callback = function() self:goToPage(self.page + 1) end,
    }
    local footer_h = next_btn:getSize().h

    local grid_h = self.screen_h - title_bar:getHeight() - footer_h - 2 * pad
    local nrows = math.max(1, math.floor((grid_h + pad) / (cell_h + pad)))
    local per_page = ncols * nrows
    self.pages = math.max(1, math.ceil(#self.items / per_page))
    if self.page > self.pages then
        self.page = self.pages
    end

    local grid = VerticalGroup:new{ align = "center" }
    local offset = (self.page - 1) * per_page
    for r = 1, nrows do
        if not self.items[offset + (r - 1) * ncols + 1] then
            break
        end
        local row = HorizontalGroup:new{}
        for c = 1, ncols do
            local item = self.items[offset + (r - 1) * ncols + c]
            local widget
            if item then
                widget = Button:new{
                    text = item.text,
                    width = cell_w,
                    radius = Size.radius.window,
                    callback = item.callback,
                    show_parent = self,
                }
            else
                widget = HorizontalSpan:new{ width = cell_w }
            end
            if c > 1 then
                table.insert(row, HorizontalSpan:new{ width = pad })
            end
            table.insert(row, widget)
        end
        if r > 1 then
            table.insert(grid, VerticalSpan:new{ height = pad })
        end
        table.insert(grid, row)
    end

    local footer_items = HorizontalGroup:new{}
    if self.on_menu then
        table.insert(footer_items, Button:new{
            icon = "appbar.menu",
            bordersize = 0,
            show_parent = self,
            callback = self.on_menu,
        })
        table.insert(footer_items, HorizontalSpan:new{ width = 2 * pad })
    end
    table.insert(footer_items, prev_btn)
    table.insert(footer_items, HorizontalSpan:new{ width = 2 * pad })
    table.insert(footer_items, TextWidget:new{
        text = self.page .. " / " .. self.pages,
        face = Font:getFace("cfont"),
    })
    table.insert(footer_items, HorizontalSpan:new{ width = 2 * pad })
    table.insert(footer_items, next_btn)
    local footer = CenterContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = footer_h },
        footer_items,
    }

    local filler_h = self.screen_h - title_bar:getHeight() - pad
        - grid:getSize().h - footer_h - pad
    self[1] = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            title_bar,
            VerticalSpan:new{ height = pad },
            grid,
            VerticalSpan:new{ height = math.max(0, filler_h) },
            footer,
        },
    }
end

function GanjoorGrid:update()
    return withRTLMirroring(self._update, self)
end

function GanjoorGrid:paintTo(...)
    return withRTLMirroring(InputContainer.paintTo, self, ...)
end

function GanjoorGrid:refresh()
    self:update()
    UIManager:setDirty(self, "ui")
end

function GanjoorGrid:goToPage(page)
    if self.pages <= 1 then
        return
    end
    if page < 1 then
        page = self.pages
    elseif page > self.pages then
        page = 1
    end
    self.page = page
    self:refresh()
end

function GanjoorGrid:applyFilter(query)
    self.filter_query = query
    self.items = query and filterItems(self.all_items, query) or self.all_items
    self.page = 1
    self:refresh()
end

function GanjoorGrid:onNextPage()
    self:goToPage(self.page + 1)
    return true
end

function GanjoorGrid:onPrevPage()
    self:goToPage(self.page - 1)
    return true
end

function GanjoorGrid:onSwipe(_arg, ges)
    if ges.direction == "east" then
        self:goToPage(self.page + 1)
    elseif ges.direction == "west" then
        self:goToPage(self.page - 1)
    elseif ges.direction == "south" then
        self:onClose()
    end
    return true
end

function GanjoorGrid:onClose()
    UIManager:close(self)
    return true
end

function GanjoorGrid:onCloseWidget()
    UIManager:setDirty(nil, "ui")
end

UI.Grid = GanjoorGrid

-- ---------------------------------------------------------------------------
-- Poem view: couplets as two columns of hemistichs, paginated
-- ---------------------------------------------------------------------------

-- Draws two hemistichs side by side: the first (right) hemistich on the right.
local PairRow = {}
PairRow.__index = PairRow

local function newPairRow(right, left, width, col_w)
    local h = math.max(right:getSize().h, left:getSize().h)
    return setmetatable({ right = right, left = left, w = width, col_w = col_w, h = h }, PairRow)
end

function PairRow:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

function PairRow:paintTo(bb, x, y)
    local rh, lh = self.right:getSize().h, self.left:getSize().h
    self.right:paintTo(bb, x + self.w - self.col_w, y + math.floor((self.h - rh) / 2))
    self.left:paintTo(bb, x, y + math.floor((self.h - lh) / 2))
end

function PairRow:free()
    self.right:free()
    self.left:free()
end

-- Two centered lines, one below the other (the "stacked" layout).
local StackRow = {}
StackRow.__index = StackRow

local function newStackRow(first, second, width)
    return setmetatable({ first = first, second = second, w = width,
        h = first:getSize().h + second:getSize().h }, StackRow)
end

function StackRow:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

function StackRow:paintTo(bb, x, y)
    self.first:paintTo(bb, x, y)
    self.second:paintTo(bb, x, y + self.first:getSize().h)
end

function StackRow:free()
    self.first:free()
    self.second:free()
end

-- The page body: paints the rows PoemView laid out for the current page.
local PoemBody = Widget:extend{ view = nil }

function PoemBody:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local view = self.view
    local marked = view.marked_rows or {}
    for _i, p in ipairs(view.placed) do
        local src = p.item.src
        if src and (src == view.focus_row or marked[src]) then
            bb:paintRect(x + math.floor(view.pad / 2), y + p.y - 3, self.dimen.w - view.pad, p.h + 6, Blitbuffer.COLOR_GRAY_E)
        end
        p.widget:paintTo(bb, x + view.pad, y + p.y)
    end
end

function PoemBody:free()
    -- the view owns (and frees) the placed widgets
end

local PoemView = InputContainer:extend{
    poem = nil,          -- { t=, m=, v={rows} }
    title = nil,
    subtitle = nil,
    focus_row = nil,     -- row (couplet) to show and highlight
    get_settings = nil,  -- function() -> { face=, size=, layout=, harakat= }
    get_marked = nil,    -- function() -> set of bookmarked rows
    is_bookmarked = nil, -- function() -> bool (whole poem)
    on_toggle_bookmark = nil,
    on_hold_row = nil,   -- function(view, row)
    on_position = nil,   -- function(view, first_row, final) called on page changes / poem changes / close
    on_menu = nil,       -- function(view): tap in the middle of the page
    on_edge = nil,       -- function(view, delta): tried to go past the first/last poem of the list
    on_prev = nil,       -- function(view, from_edge) | nil: previous poem
    on_next = nil,       -- function(view) | nil: next poem
    covers_fullscreen = true,
}

function PoemView:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.pad = Size.padding.large * 2
    self.placed = {}
    if Device:isTouchDevice() then
        self.ges_events.PoemSwipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PrevPage = { { Device.input.group.PgBack } }
    end
    if self.poem then
        self:loadPoem{ poem = self.poem, title = self.title, subtitle = self.subtitle, focus_row = self.focus_row,
            on_prev = self.on_prev, on_next = self.on_next }
    end
end

-- (Re)initialises the view with another poem.
function PoemView:loadPoem(args)
    self:freePlaced()
    self.poem = args.poem
    self.title = args.title
    self.subtitle = args.subtitle
    self.focus_row = args.focus_row
    self.on_prev = args.on_prev
    self.on_next = args.on_next
    if args.get_marked ~= nil or args.is_bookmarked ~= nil then
        self.get_marked = args.get_marked
        self.is_bookmarked = args.is_bookmarked
    end
    self:applySettings()
    self:buildItems()
    self.page_starts = { 1 }
    self.page = 1
    self.at_end = false
    self:update(args.start_row or args.focus_row, args.at_end)
    UIManager:setDirty(self, "partial")
    self:reportPosition(true)
end

function PoemView:reportPosition(final)
    if not self.on_position then
        return
    end
    local row
    for _i, p in ipairs(self.placed) do
        if p.item.src then
            row = p.item.src
            break
        end
    end
    self.on_position(self, row or 1, final)
end

function PoemView:applySettings()
    local s = self.get_settings()
    self.settings = s
    local size = s.size or 22
    self.face = Font:getFace(s.face or "cfont", size) or Font:getFace("cfont", size)
    self.small_face = Font:getFace(s.face or "cfont", math.max(10, size - 5)) or Font:getFace("cfont", math.max(10, size - 5))
    self.vgap = math.floor(self.face.size * 0.7)
end

function PoemView:buildItems()
    local items = {}
    local strip = self.settings.harakat == false
    local function tx(text)
        return strip and Core.stripHarakat(text) or text
    end
    local poem = self.poem
    if poem.m and poem.m ~= "" then
        items[#items + 1] = { kind = "metre", text = poem.m }
    end
    for i, row in ipairs(poem.v) do
        if type(row[1]) == "number" then
            local kind = row[1]
            if kind == 2 then
                items[#items + 1] = { kind = "line", text = tx(row[2]), src = i }
            else
                for _j, piece in ipairs(Core.splitProse(tx(row[2]), 350)) do
                    items[#items + 1] = { kind = kind == 3 and "comment" or "para", text = piece, src = i }
                end
            end
        elseif row[2] == "" then
            items[#items + 1] = { kind = "line", text = tx(row[1]), src = i }
        else
            items[#items + 1] = { kind = "pair", r = tx(row[1]), l = tx(row[2]), src = i }
        end
    end
    self.items = items
end

function PoemView:buildWidget(item)
    local content_w = self.screen_w - 2 * self.pad
    local function tb(text, width, align, face, color)
        return TextBoxWidget:new{
            text = text,
            face = face or self.face,
            width = width,
            alignment = align,
            alignment_strict = true,
            para_direction_rtl = true,
            fgcolor = color or Blitbuffer.COLOR_BLACK,
        }
    end
    local kind = item.kind
    if kind == "pair" then
        if self.settings.layout == "staggered" then
            -- first hemistich on the first line at the right edge, second one on the next line at the left edge
            return newStackRow(tb(item.r, content_w, "right"), tb(item.l, content_w, "left"), content_w)
        elseif self.settings.layout == "stacked" then
            return newStackRow(tb(item.r, content_w, "center"), tb(item.l, content_w, "center"), content_w)
        end
        local gap = math.floor(content_w * 0.07)
        local col_w = math.floor((content_w - gap) / 2)
        return newPairRow(tb(item.r, col_w, "center"), tb(item.l, col_w, "center"), content_w, col_w)
    elseif kind == "line" then
        return tb(item.text, content_w, "center")
    elseif kind == "para" then
        return tb(item.text, content_w, "right")
    elseif kind == "comment" then
        return tb(item.text, content_w, "right", self.small_face, Blitbuffer.COLOR_DARK_GRAY)
    else -- metre
        return tb(item.text, content_w, "center", self.small_face, Blitbuffer.COLOR_DARK_GRAY)
    end
end

function PoemView:freePlaced()
    for _i, p in ipairs(self.placed or {}) do
        p.widget:free()
    end
    self.placed = {}
end

-- Lays out the page starting at item `start`; returns the index of the first item of the next page.
function PoemView:layoutPage(start)
    self:freePlaced()
    local placed, y, i = {}, 0, start
    while i <= #self.items do
        local item = self.items[i]
        local widget = self:buildWidget(item)
        local h = widget:getSize().h
        local gap = (#placed > 0) and ((item.kind == "para" and self.items[i - 1] and self.items[i - 1].src == item.src)
            and math.floor(self.vgap / 3) or self.vgap) or 0
        if #placed > 0 and y + gap + h > self.body_h then
            widget:free()
            break
        end
        y = y + gap
        placed[#placed + 1] = { widget = widget, y = y, h = h, item = item }
        y = y + h
        i = i + 1
    end
    self.placed = placed
    return i
end

function PoemView:_update(focus_row, to_end)
    local pad = Size.padding.large
    self.title_bar = TitleBar:new{
        title = self.title or "",
        subtitle = self.subtitle,
        width = self.screen_w,
        fullscreen = true,
        with_bottom_line = true,
        title_shrink_font_to_fit = true,
        left_icon = (self.is_bookmarked and self.is_bookmarked()) and "star.full" or "star.empty",
        left_icon_tap_callback = function()
            if self.on_toggle_bookmark then
                self.on_toggle_bookmark(self)
            end
        end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local indicator = TextWidget:new{ text = " ", face = Font:getFace("cfont", 16) }
    local footer_h = indicator:getSize().h + pad
    local title_h = self.title_bar:getHeight()
    self.body_h = self.screen_h - title_h - footer_h - pad
    self.body_dimen = Geom:new{ x = 0, y = title_h, w = self.screen_w, h = self.body_h }

    if to_end then
        self:gotoEnd()
    elseif focus_row and focus_row > 0 then
        self:gotoRow(focus_row)
    else
        self.next_idx = self:layoutPage(self.page_starts[self.page])
    end
    self.at_end = self.next_idx > #self.items

    local progress = math.floor(100 * (self.next_idx - 1) / math.max(1, #self.items))
    indicator:free()
    indicator = TextWidget:new{
        text = self.page .. "  \u{00B7}  " .. progress .. "%",
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }
    local footer = CenterContainer:new{
        dimen = Geom:new{ w = self.screen_w, h = footer_h },
        indicator,
    }
    self.body = PoemBody:new{ dimen = Geom:new{ w = self.screen_w, h = self.body_h }, view = self }
    self.marked_rows = self.get_marked and self.get_marked() or {}

    self.ges_events.PoemTap = nil
    self.ges_events.PoemHold = nil
    if Device:isTouchDevice() then
        self.ges_events.PoemTap = { GestureRange:new{ ges = "tap", range = self.body_dimen } }
        self.ges_events.PoemHold = { GestureRange:new{ ges = "hold", range = self.body_dimen } }
    end

    self[1] = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "center", self.title_bar, self.body, footer },
    }
end

function PoemView:update(focus_row, to_end)
    return withRTLMirroring(self._update, self, focus_row, to_end)
end

function PoemView:paintTo(...)
    return withRTLMirroring(InputContainer.paintTo, self, ...)
end

-- Pages forward until the page that shows `row`.
function PoemView:gotoRow(row)
    local page = 1
    while true do
        local start = self.page_starts[page]
        local nxt = self:layoutPage(start)
        self.page_starts[page + 1] = nxt
        self.page = page
        self.next_idx = nxt
        for _i, p in ipairs(self.placed) do
            if p.item.src == row then
                return
            end
        end
        if nxt > #self.items then
            return
        end
        page = page + 1
    end
end

-- Pages forward to the last page of the poem.
function PoemView:gotoEnd()
    local page = 1
    while true do
        local nxt = self:layoutPage(self.page_starts[page])
        self.page_starts[page + 1] = nxt
        self.page = page
        self.next_idx = nxt
        if nxt > #self.items then
            return
        end
        page = page + 1
    end
end

function PoemView:refresh()
    self:update()
    UIManager:setDirty(self, "partial")
    self:reportPosition(false)
end

-- Forward: next part of a long poem; after the last part, the next poem.
function PoemView:nextPage()
    if not self.at_end then
        self.page = self.page + 1
        self.page_starts[self.page] = self.next_idx
        self.focus_row = nil
        self:refresh()
    elseif self.on_next then
        self.on_next(self)
    elseif self.on_edge then
        self.on_edge(self, 1)
    end
end

-- Backward: previous part; before the first part, the end of the previous poem.
function PoemView:prevPage()
    if self.page > 1 then
        self.page = self.page - 1
        self.focus_row = nil
        self:refresh()
    elseif self.on_prev then
        self.on_prev(self, true)
    elseif self.on_edge then
        self.on_edge(self, -1)
    end
end

-- Re-reads settings and lays the poem out again, staying at the same place.
function PoemView:relayout()
    local keep
    for _i, p in ipairs(self.placed) do
        if p.item.src then
            keep = p.item.src
            break
        end
    end
    self:applySettings()
    self:buildItems()
    self.page_starts = { 1 }
    self.page = 1
    self:update(keep)
    UIManager:setDirty(self, "partial")
end

function PoemView:rowAtY(y)
    local rel = y - self.body_dimen.y
    for _i, p in ipairs(self.placed) do
        if rel >= p.y - 6 and rel <= p.y + p.h + 6 then
            return p.item.src
        end
    end
end

function PoemView:onPoemTap(_arg, ges)
    local x = ges.pos.x
    if x > self.screen_w * 2 / 3 then
        self:nextPage() -- Persian is read right to left: forward is the right side
    elseif x < self.screen_w / 3 then
        self:prevPage()
    elseif self.on_menu then
        self.on_menu(self)
    end
    return true
end

function PoemView:onPoemHold(_arg, ges)
    local row = self:rowAtY(ges.pos.y)
    if row and self.on_hold_row then
        self.on_hold_row(self, row)
    end
    return true
end

function PoemView:onPoemSwipe(_arg, ges)
    if ges.direction == "east" then
        self:nextPage()
    elseif ges.direction == "west" then
        self:prevPage()
    elseif ges.direction == "south" then
        self:onClose()
    end
    return true
end

function PoemView:onNextPage()
    self:nextPage()
    return true
end

function PoemView:onPrevPage()
    self:prevPage()
    return true
end

function PoemView:onClose()
    UIManager:close(self)
    return true
end

function PoemView:onCloseWidget()
    self:reportPosition(true)
    self:freePlaced()
    UIManager:setDirty(nil, "ui")
end

UI.PoemView = PoemView

-- ---------------------------------------------------------------------------
-- Font preview: a couplet drawn with the candidate font
-- ---------------------------------------------------------------------------

local SAMPLE_R = "\u{0627}\u{0644}\u{0627} \u{06CC}\u{0627} \u{0627}\u{06CC}\u{0647}\u{0627} \u{0627}\u{0644}\u{0633}\u{0627}\u{0642}\u{06CC} \u{0627}\u{062F}\u{0631} \u{06A9}\u{0623}\u{0633}\u{0627} \u{0648} \u{0646}\u{0627}\u{0648}\u{0644}\u{0647}\u{0627}"
local SAMPLE_L = "\u{06A9}\u{0647} \u{0639}\u{0634}\u{0642} \u{0622}\u{0633}\u{0627}\u{0646} \u{0646}\u{0645}\u{0648}\u{062F} \u{0627}\u{0648}\u{0644} \u{0648}\u{0644}\u{06CC} \u{0627}\u{0641}\u{062A}\u{0627}\u{062F} \u{0645}\u{0634}\u{06A9}\u{0644}\u{200C}\u{0647}\u{0627}"
local SAMPLE_N = "\u{06F1}\u{06F2}\u{06F3}\u{06F4}\u{06F5}\u{06F6}\u{06F7}\u{06F8}\u{06F9}\u{06F0}"

local FontPreview = InputContainer:extend{
    font_path = nil, -- nil: the default UI font
    font_name = "",
    size = 22,
    on_use = nil,
}

function FontPreview:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    if Device:isTouchDevice() then
        self.ges_events.TapClose = { GestureRange:new{ ges = "tap", range = self.dimen } }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    local pad = Size.padding.large
    local inner_w = math.floor(sw * 0.86)
    local face = Font:getFace(self.font_path or "cfont", self.size) or Font:getFace("cfont", self.size)
    local function tb(text, f, align)
        return TextBoxWidget:new{
            text = text, face = f or face, width = inner_w, alignment = align or "center",
            alignment_strict = true, para_direction_rtl = true,
        }
    end
    local buttons = ButtonTable:new{
        width = inner_w,
        show_parent = self,
        buttons = {{
            { text = _("Back"), callback = function() self:onClose() end },
            {
                text = _("Use this font"),
                callback = function()
                    self:onClose()
                    if self.on_use then self.on_use() end
                end,
            },
        }},
    }
    local content = VerticalGroup:new{
        align = "center",
        TextWidget:new{ text = self.font_name, face = Font:getFace("cfont", 18), max_width = inner_w },
        VerticalSpan:new{ height = pad },
        tb(SAMPLE_R),
        VerticalSpan:new{ height = pad },
        tb(SAMPLE_L),
        VerticalSpan:new{ height = pad },
        tb(SAMPLE_N),
        VerticalSpan:new{ height = pad * 2 },
        buttons,
    }
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        bordersize = Size.border.window,
        padding = pad * 2,
        content,
    }
    self[1] = CenterContainer:new{ dimen = self.dimen, self.frame }
end

function FontPreview:paintTo(...)
    return withRTLMirroring(InputContainer.paintTo, self, ...)
end

function FontPreview:onTapClose(_arg, ges)
    if self.frame.dimen and ges.pos:notIntersectWith(self.frame.dimen) then
        self:onClose()
        return true
    end
end

function FontPreview:onClose()
    UIManager:close(self)
    UIManager:setDirty(nil, "ui")
    return true
end

UI.FontPreview = FontPreview

return UI
