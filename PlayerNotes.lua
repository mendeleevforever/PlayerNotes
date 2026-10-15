-- PlayerNotes.lua
-- Write notes about other players.
--   * Right-click a player: Create Note / Read Note / Edit Note
--   * Notes appear in player tooltips (toggle + adjustable character limit)
--   * /pn opens the options window (settings, manual add, list of saved notes)
--
-- WoW Forever player names are "First-name Last-name", so names can contain
-- spaces. Names are matched case-insensitively and with extra spaces removed.

local ADDON_NAME = "PlayerNotes"
local VERSION    = "1.2.0"
local PREFIX     = "|cff00ff96Player Notes:|r "

local PN = {}
_G[ADDON_NAME] = PN

local DEFAULT_LIMIT          = 50
local MIN_LIMIT, MAX_LIMIT   = 5, 500
local MAX_NOTE_LEN           = 2000
local NOTE_LABEL             = "|cffffd100Note:|r "

local DEFAULT_SETTINGS = {
    showTooltip  = true,
    tooltipLimit = DEFAULT_LIMIT,
}

-------------------------------------------------------------------------------
-- String helpers
-------------------------------------------------------------------------------
local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"

local function Trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Tidy a player name: trim, collapse runs of spaces into one.
local function CleanName(name)
    if type(name) ~= "string" then return nil end
    name = Trim((name:gsub("%s+", " ")))
    if name == "" then return nil end
    return name
end

-- Lookup key for a name (case-insensitive).
local function NameKey(name)
    name = CleanName(name)
    return name and name:lower() or nil
end

local function Utf8Len(s)
    if strlenutf8 then return strlenutf8(s) end
    local n = 0
    for _ in s:gmatch(UTF8_CHAR) do n = n + 1 end
    return n
end

-- Cut a string to `limit` characters (UTF-8 aware) and add "..." if cut.
local function Truncate(s, limit)
    if not limit or limit <= 0 then return s end
    local count = 0
    for pos in s:gmatch("()" .. UTF8_CHAR) do
        count = count + 1
        if count > limit then
            return Trim(s:sub(1, pos - 1)) .. "..."
        end
    end
    return s
end

-- Make a note safe to show in a FontString / tooltip: a typed "|" (or the
-- "||" an edit box may store) always shows as a single literal "|".
local function ForDisplay(s)
    s = s:gsub("||", "|")
    s = s:gsub("|", "||")
    return s
end

local function FormatDate(t)
    if type(t) ~= "number" then return "?" end
    return date("%b %d, %Y", t)
end

local function ColorName(name, class)
    local colors = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS
    local c = class and colors and colors[class]
    if c then
        return ("|cff%02x%02x%02x%s|r"):format(math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255), name)
    end
    return "|cffe6d6ae" .. name .. "|r"   -- palette text colour
end

-------------------------------------------------------------------------------
-- Name resolution
-------------------------------------------------------------------------------

-- Remove a "-Realm" suffix, but only when it really is a realm name, so a
-- hyphenated last name (e.g. "Anna Smith-Jones") is never cut.
local function StripRealm(name, server)
    name = CleanName(name)
    if not name then return nil end
    local realms = {}
    if type(server) == "string" and server ~= "" then realms[#realms + 1] = server end
    if GetRealmName then realms[#realms + 1] = GetRealmName() end
    if GetNormalizedRealmName then realms[#realms + 1] = GetNormalizedRealmName() end
    for _, realm in ipairs(realms) do
        if type(realm) == "string" and realm ~= "" then
            local suffix = ("-" .. realm):lower()
            if #name > #suffix and name:sub(-#suffix):lower() == suffix then
                return CleanName(name:sub(1, -#suffix - 1))
            end
        end
    end
    return name
end

-- On WoW Forever, UnitName(unit) returns TWO values: first name and surname
-- (other clients return name and realm). GetUnitName(unit) returns the
-- complete "First Surname" as one string. Use both so the surname is kept.
local function NameFromUnit(unit)
    if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
    local first, surname = UnitName(unit)
    if not first or first == "" or first == UNKNOWNOBJECT or first == UNKNOWN then return nil end

    if type(surname) == "string" and surname ~= "" then
        return CleanName(first .. " " .. surname)
    end

    if GetUnitName then
        local full = GetUnitName(unit, false)
        if type(full) == "string" then
            -- other clients may add a cross-realm marker such as " (*)"
            if FOREIGN_SERVER_LABEL and FOREIGN_SERVER_LABEL ~= "" then
                local label = FOREIGN_SERVER_LABEL
                if full:sub(-#label) == label then full = full:sub(1, -#label - 1) end
            end
            full = CleanName(full)
            if full and full:lower():find(first:lower(), 1, true) == 1 then return full end
        end
    end

    return CleanName(first)
end

local function ClassFromUnit(unit)
    if not unit or not UnitExists(unit) then return nil end
    local _, class = UnitClass(unit)
    return class
end

local function IsSelf(name)
    local me = NameFromUnit("player")
    return me ~= nil and NameKey(me) == NameKey(name)
end

-- contextData from a right-click menu -> player name, class
local function ResolveContextName(ctx)
    if type(ctx) ~= "table" then return nil end
    local unit = ctx.unit
    if unit and UnitExists(unit) then
        if not UnitIsPlayer(unit) then return nil end          -- NPCs, pets
        local n = NameFromUnit(unit)
        if n then
            local class = ClassFromUnit(unit)
            PN:RepairFirstNameNote(n, class)
            return n, class
        end
    end
    if type(ctx.name) == "string" and ctx.name ~= "" then
        return StripRealm(ctx.name, ctx.server), nil
    end
    return nil
end

-------------------------------------------------------------------------------
-- Quick Note words (adjective + noun, each with a colour)
-------------------------------------------------------------------------------
-- Simple colour palette offered when creating / editing a word
local PALETTE = {
    { name = "White",        hex = "ffffff" },
    { name = "Grey",         hex = "9d9d9d" },
    { name = "Bright Green", hex = "1eff00" },
    { name = "Dark Green",   hex = "2e9e3e" },
    { name = "Blue",         hex = "3d8bff" },
    { name = "Light Blue",   hex = "69ccf0" },
    { name = "Purple",       hex = "a335ee" },
    { name = "Pink",         hex = "ff6eb4" },
    { name = "Red",          hex = "ff3333" },
    { name = "Orange",       hex = "ff8000" },
    { name = "Yellow",       hex = "ffe14d" },
    { name = "Brown",        hex = "b07b43" },
}

local KINDS = {
    adj  = { list = "adjectives", label = "Adjective", lower = "adjective", plural = "Adjectives" },
    noun = { list = "nouns",      label = "Noun",      lower = "noun",      plural = "Nouns" },
}
local KIND_ORDER = { "adj", "noun" }
local MAX_WORDS, MAX_WORD_LEN = 30, 20

local DEFAULT_WORDS = {
    adj = {
        { id = "adj_good", text = "Good", color = "1eff00" },   -- bright green
        { id = "adj_okay", text = "Okay", color = "ffffff" },   -- white
        { id = "adj_bad",  text = "Bad",  color = "ff3333" },   -- red
    },
    noun = {
        { id = "noun_tank",   text = "Tank",   color = "3d8bff" },   -- blue
        { id = "noun_healer", text = "Healer", color = "2e9e3e" },   -- dark green
        { id = "noun_dps",    text = "DPS",    color = "ffffff" },   -- white
    },
}

local function ValidHex(h)
    return type(h) == "string" and h:match("^%x%x%x%x%x%x$") ~= nil
end

local function HexToRGB(h)
    if not ValidHex(h) then return 1, 1, 1 end
    return tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255
end

-- A word as coloured text
local function WordText(word)
    if not word then return nil end
    return "|cff" .. (ValidHex(word.color) and word.color or "ffffff") .. ForDisplay(word.text) .. "|r"
end

function PN:GetWords(kind)
    return self.db.words[KINDS[kind].list]
end

function PN:GetWord(kind, id)
    if not id or not self.db then return nil end
    for _, w in ipairs(self:GetWords(kind)) do
        if w.id == id then return w end
    end
    return nil
end

-- "Good Tank" with each word in its colour (nil if the note has no Quick Note)
function PN:QuickNoteText(entry)
    if not entry then return nil end
    local a = WordText(self:GetWord("adj", entry.adj))
    local n = WordText(self:GetWord("noun", entry.noun))
    if a and n then return a .. " " .. n end
    return a or n
end

-- Lower-case words of the Quick Note, for searching
function PN:QuickNotePlain(entry)
    local a, n = self:GetWord("adj", entry.adj), self:GetWord("noun", entry.noun)
    return ((a and a.text or "") .. " " .. (n and n.text or "")):lower()
end

function PN:FindWordByText(kind, text, exceptId)
    local key = Trim(text):lower()
    for _, w in ipairs(self:GetWords(kind)) do
        if w.id ~= exceptId and w.text:lower() == key then return w end
    end
    return nil
end

-- Creates a word (id = nil) or updates one. Returns the word's id.
function PN:SaveWord(kind, id, text, color)
    local w = id and self:GetWord(kind, id)
    if w then
        w.text, w.color = text, color
    else
        self.db.nextWordId = (self.db.nextWordId or 0) + 1
        w = { id = kind .. "_c" .. self.db.nextWordId, text = text, color = color }
        local list = self:GetWords(kind)
        list[#list + 1] = w
    end
    self:WordsChanged()
    return w.id
end

function PN:CountWordUses(kind, id)
    local n = 0
    for _, e in pairs(self.db.notes) do
        if type(e) == "table" and e[kind] == id then n = n + 1 end
    end
    return n
end

-- Custom words only. Notes using the word lose that half of their Quick Note.
function PN:DeleteWord(kind, id)
    local list = self:GetWords(kind)
    for i, w in ipairs(list) do
        if w.id == id then
            if w.default then return false end
            table.remove(list, i)
            break
        end
    end
    for key, e in pairs(self.db.notes) do
        if type(e) == "table" and e[kind] == id then
            e[kind] = nil
            if (e.text or "") == "" and not e.adj and not e.noun then self.db.notes[key] = nil end
        end
    end
    self:WordsChanged()
    self:NotesChanged()
    return true
end

-- Redraw everything that shows words after one is created, edited or deleted
function PN:WordsChanged()
    if self.dropList and self.dropList:IsShown() then self.dropList:Hide() end
    for _, dd in ipairs(self.dropdowns or {}) do dd:SetValue(dd.value) end
    if self.options and self.options:IsShown() then
        self:RefreshWordLists()
        self:RefreshList()
    end
    local f = self.noteFrame
    if f and f:IsShown() and f.mode == "read" then self:UpdateNoteFrame() end
end

-------------------------------------------------------------------------------
-- Note storage
-------------------------------------------------------------------------------
-- A note exists if it has text or a Quick Note
local function HasContent(e)
    return type(e) == "table"
        and ((type(e.text) == "string" and e.text ~= "") or e.adj ~= nil or e.noun ~= nil)
end

function PN:GetNote(name)
    local key = NameKey(name)
    if not key or not self.db then return nil end
    local e = self.db.notes[key]
    if HasContent(e) then
        if type(e.text) ~= "string" then e.text = "" end
        return e, key
    end
    return nil
end

-- adj / noun are word ids (or nil for none)
function PN:SetNote(name, text, class, adj, noun)
    name = CleanName(name)
    if not name or not self.db then return false end
    text = Trim(text)
    if adj and not self:GetWord("adj", adj) then adj = nil end
    if noun and not self:GetWord("noun", noun) then noun = nil end
    if text == "" and not adj and not noun then
        self:DeleteNote(name)
        return true
    end
    local key = NameKey(name)
    local now = time()
    local e = self.db.notes[key]
    if type(e) == "table" then
        e.name, e.text, e.adj, e.noun, e.updated = name, text, adj, noun, now
        if class then e.class = class end
        e.created = e.created or now
    else
        self.db.notes[key] = { name = name, text = text, adj = adj, noun = noun, class = class, created = now, updated = now }
    end
    self:NotesChanged()
    return true
end

function PN:DeleteNote(name)
    local key = NameKey(name)
    if key and self.db and self.db.notes[key] then
        self.db.notes[key] = nil
        self:NotesChanged()
        return true
    end
    return false
end

-- Version 1.0.0 saved notes made from the right-click menu / "/pn target"
-- under the first name only ("Burr" instead of "Burr Duskweaver"). WoW Forever
-- names always have two parts, so when we see the full name and there is no
-- note for it but there is one for the first name alone (and the class matches,
-- if known), move that note to the full name.
function PN:RepairFirstNameNote(fullName, class)
    fullName = CleanName(fullName)
    if not fullName or not self.db or not fullName:find(" ", 1, true) then return end
    local fullKey = NameKey(fullName)
    if self.db.notes[fullKey] then return end
    local firstKey = NameKey(fullName:match("^(%S+)"))
    local e = firstKey and self.db.notes[firstKey]
    if type(e) ~= "table" then return end
    if class and e.class and e.class ~= class then return end
    self.db.notes[firstKey] = nil
    e.name = fullName
    if class then e.class = class end
    self.db.notes[fullKey] = e
    self:NotesChanged()
end

function PN:CountNotes()
    local n = 0
    for _ in pairs(self.db.notes) do n = n + 1 end
    return n
end

-- Search matches the player name, the note text or the Quick Note words
function PN:GetSortedNotes(filter)
    local out = {}
    filter = Trim(filter):lower()
    for key, e in pairs(self.db.notes) do
        if HasContent(e) then
            e.name = e.name or key
            e.text = type(e.text) == "string" and e.text or ""
            if filter == "" or key:find(filter, 1, true) or e.text:lower():find(filter, 1, true)
                or self:QuickNotePlain(e):find(filter, 1, true) then
                out[#out + 1] = e
            end
        end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

function PN:NotesChanged()
    if self.options and self.options:IsShown() then
        self:RefreshList()
        self:RefreshWordLists()     -- "used in N notes" counts
    end
    if self.options then self:UpdateAddStatus() end
end

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------
function PN:SetTooltipEnabled(on)
    self.db.settings.showTooltip = on and true or false
    self:UpdateOptionsControls()
    if self.options and self.options:IsShown() then self:RefreshList() end
end

function PN:SetTooltipLimit(n)
    n = tonumber(n)
    if not n then n = self.db.settings.tooltipLimit end
    n = math.floor(n + 0.5)
    if n < MIN_LIMIT then n = MIN_LIMIT end
    if n > MAX_LIMIT then n = MAX_LIMIT end
    self.db.settings.tooltipLimit = n
    self:UpdateOptionsControls()
end

-------------------------------------------------------------------------------
-- Confirmation popups
-------------------------------------------------------------------------------
StaticPopupDialogs["PLAYERNOTES_CONFIRM_DELETE"] = {
    text = "Delete your note about %s?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(self, data)
        PN:DeleteNote(data)
        local f = PN.noteFrame
        if f and f:IsShown() and NameKey(f.playerName) == NameKey(data) then f:Hide() end
        print(PREFIX .. "Deleted note about " .. tostring(data) .. ".")
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["PLAYERNOTES_CONFIRM_OVERWRITE"] = {
    text = "You already have a note about %s.\nReplace it with the new note?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(self, data)
        PN:SetNote(data.name, data.text, nil, data.adj, data.noun)
        PN:ClearAddForm()
        PN:SetAddStatus("|cff66ff66Note about " .. data.name .. " replaced.|r")
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["PLAYERNOTES_CONFIRM_DELETE_WORD"] = {
    text = "Delete the %s\n%s",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(self, data)
        PN:DeleteWord(data.kind, data.id)
        local ed = PN.wordEditor
        if ed and ed:IsShown() and ed.wordId == data.id then ed:Hide() end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function ConfirmDelete(name)
    StaticPopup_Show("PLAYERNOTES_CONFIRM_DELETE", name, nil, name)
end

local function ConfirmDeleteWord(kind, id)
    local w = PN:GetWord(kind, id)
    if not w or w.default then return end
    local uses = PN:CountWordUses(kind, id)
    local usage = uses > 0 and ("It is used in %d %s; %s will lose this word."):format(
        uses, uses == 1 and "note" or "notes", uses == 1 and "that note" or "those notes") or ""
    StaticPopup_Show("PLAYERNOTES_CONFIRM_DELETE_WORD",
        KINDS[kind].lower .. " " .. WordText(w) .. "?", usage, { kind = kind, id = id })
end


-------------------------------------------------------------------------------
-- UI style: same look as Heal Rank Advisor and Waylaid Crate Advisor
-- (solid dark window, layered gold trim, title plate on the top edge)
-------------------------------------------------------------------------------

-- Palette (r, g, b) — shared with Heal Rank Advisor / Waylaid Crate Advisor
local C = {
    bg        = { 0.118, 0.082, 0.051 },
    gold      = { 0.541, 0.416, 0.173 },
    goldLight = { 0.722, 0.569, 0.235 },
    outline   = { 0.169, 0.118, 0.055 },
    inner     = { 0.290, 0.212, 0.094 },
    rule      = { 0.420, 0.314, 0.137 },
    header    = { 0.831, 0.627, 0.090 },
    text      = { 0.902, 0.839, 0.682 },
    muted     = { 0.612, 0.553, 0.439 },
    legend    = { 0.720, 0.650, 0.520 },
    plate     = { 0.165, 0.114, 0.063 },
    field     = { 0.071, 0.047, 0.027 },
    stripe    = { 0.353, 0.263, 0.125 },
}
local DOT = "   |cff7d705a•|r   "     -- separator used in info lines

local function SetColor(obj, rgb) obj:SetTextColor(rgb[1], rgb[2], rgb[3]) end

-- Draws a rectangular border of the given thickness, `inset` px inside the frame edge
-- (negative inset draws outside it). Returns the four edge textures.
local function AddBorder(frame, layer, rgb, alpha, thickness, inset)
    local function edge()
        local t = frame:CreateTexture(nil, layer)
        t:SetColorTexture(rgb[1], rgb[2], rgb[3], alpha)
        return t
    end
    local top, bottom, left, right = edge(), edge(), edge(), edge()
    top:SetPoint("TOPLEFT", inset, -inset)
    top:SetPoint("TOPRIGHT", -inset, -inset)
    top:SetHeight(thickness)
    bottom:SetPoint("BOTTOMLEFT", inset, inset)
    bottom:SetPoint("BOTTOMRIGHT", -inset, inset)
    bottom:SetHeight(thickness)
    left:SetPoint("TOPLEFT", inset, -inset)
    left:SetPoint("BOTTOMLEFT", inset, inset)
    left:SetWidth(thickness)
    right:SetPoint("TOPRIGHT", -inset, -inset)
    right:SetPoint("BOTTOMRIGHT", -inset, inset)
    right:SetWidth(thickness)
    return { top, bottom, left, right }
end

local function SetEdgeColor(edges, rgb)
    for _, t in ipairs(edges) do t:SetColorTexture(rgb[1], rgb[2], rgb[3], 1) end
end

local function PlaceFrame(f, posKey, point, x, y)
    local pos = PN.db and PN.db.positions[posKey]
    f:ClearAllPoints()
    if pos then
        f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        f:SetPoint(point or "CENTER", UIParent, point or "CENTER", x or 0, y or 0)
    end
end

local function SavePosition(f, posKey)
    local p, _, rp, x, y = f:GetPoint()
    if p and PN.db then PN.db.positions[posKey] = { p, rp, x, y } end
end

-- A window: solid background, layered trim, title plate overlapping the top
-- edge, close button and an info line under the plate.
local function MakeWindow(globalName, w, h, posKey)
    local f = CreateFrame("Frame", globalName, UIParent)
    f:SetSize(w, h)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition(self, posKey) end)
    PlaceFrame(f, posKey, "CENTER", 0, 0)
    f:Hide()
    tinsert(UISpecialFrames, globalName)   -- Escape closes the window

    -- Solid background (opaque, so the world doesn't show through)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetColorTexture(C.bg[1], C.bg[2], C.bg[3], 0.97)
    bg:SetAllPoints()

    -- Layered trim: dark outline, gold band, faint inner line
    AddBorder(f, "BORDER",  C.outline, 1, 2, -2)
    AddBorder(f, "BORDER",  C.gold,    1, 3,  0)
    AddBorder(f, "ARTWORK", C.inner,   1, 1,  3)

    -- Title plate overlapping the top edge (also a drag handle)
    local plate = CreateFrame("Frame", nil, f)
    plate:SetSize(300, 34)
    plate:SetPoint("TOP", 0, 18)
    plate:SetFrameLevel(f:GetFrameLevel() + 5)
    plate:EnableMouse(true)
    plate:RegisterForDrag("LeftButton")
    plate:SetScript("OnDragStart", function() f:StartMoving() end)
    plate:SetScript("OnDragStop", function() f:StopMovingOrSizing(); SavePosition(f, posKey) end)
    local pbg = plate:CreateTexture(nil, "BACKGROUND")
    pbg:SetColorTexture(C.plate[1], C.plate[2], C.plate[3], 1)
    pbg:SetAllPoints()
    AddBorder(plate, "BORDER", C.outline,   1, 2, -2)
    AddBorder(plate, "BORDER", C.goldLight, 1, 2,  0)
    local title = plate:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER", 0, 0)
    title:SetTextColor(1, 0.82, 0)
    if title.SetWordWrap then title:SetWordWrap(false) end
    f.plate, f.title = plate, title

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() f:Hide() end)

    -- Info line under the title plate
    f.info = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.info:SetPoint("TOP", 0, -26)
    SetColor(f.info, C.legend)

    return f
end

-- Sets the plate title and widens the plate for long names
local function SetWindowTitle(f, text)
    f.title:SetText(text)
    local w = f:GetWidth()
    local minW = math.min(300, w - 100)
    f.plate:SetWidth(math.max(minW, math.min(w - 80, f.title:GetStringWidth() + 48)))
end

-- Footer: rule across the bottom, above the buttons
local function AddFooterRule(f, y)
    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(C.rule[1], C.rule[2], C.rule[3], 1)
    rule:SetPoint("BOTTOMLEFT", 20, y)
    rule:SetPoint("BOTTOMRIGHT", -20, y)
    rule:SetHeight(1)
    return rule
end

-- Section heading: gold label with a gold rule under it (like the crate tiers)
-- x1 = left edge of the column, x2 = right edge as an offset from the window's right
local function AddSection(parent, text, y, x1, x2)
    x1, x2 = x1 or 20, x2 or -20
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", x1 + 2, y)
    fs:SetJustifyH("LEFT")
    SetColor(fs, C.header)
    fs:SetText(text)
    local rule = parent:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.55)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", x1, y - 16)
    rule:SetPoint("TOPRIGHT", x2, y - 16)
    return fs
end

local function AddLabel(parent, text, font, rgb)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
    fs:SetJustifyH("LEFT")
    SetColor(fs, rgb or C.text)
    fs:SetText(text)
    return fs
end

-- Dark text field behind a multi-line edit box / note text.
-- Drawn on the parent so it always sits under the scroll frame's text.
local function AddFieldBox(parent, left, top, right, bottom)
    local t = parent:CreateTexture(nil, "ARTWORK", nil, -1)
    t:SetColorTexture(C.field[1], C.field[2], C.field[3], 0.9)
    t:SetPoint("TOPLEFT", left, top)
    t:SetPoint("BOTTOMRIGHT", right, bottom)
    local edges = {}
    local function Edge(p1, p2, w, h)
        local e = parent:CreateTexture(nil, "ARTWORK")
        e:SetColorTexture(C.rule[1], C.rule[2], C.rule[3], 1)
        e:SetPoint(p1, t, p1)
        e:SetPoint(p2, t, p2)
        if w then e:SetWidth(w) end
        if h then e:SetHeight(h) end
        edges[#edges + 1] = e
    end
    Edge("TOPLEFT", "TOPRIGHT", nil, 1)
    Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    Edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
    Edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
    return t, edges
end

-- Placeholder text shown while an edit box is empty and unfocused
local function AddPlaceholder(eb, text, multiLine)
    local ph = eb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if multiLine then ph:SetPoint("TOPLEFT", 6, -6) else ph:SetPoint("LEFT", 7, 0) end
    SetColor(ph, C.muted)
    ph:SetText(text)
    local function Update()
        if eb:GetText() == "" and not eb:HasFocus() then ph:Show() else ph:Hide() end
    end
    eb:HookScript("OnTextChanged", Update)
    eb:HookScript("OnEditFocusGained", Update)
    eb:HookScript("OnEditFocusLost", Update)
    Update()
    return ph
end

-- Single-line input in the window's palette (border lights up when focused)
local function MakeInput(globalName, parent, w)
    local eb = CreateFrame("EditBox", globalName, parent)
    eb:SetSize(w, 22)
    eb:SetAutoFocus(false)
    eb:SetFontObject(ChatFontNormal or GameFontHighlight)
    eb:SetTextInsets(7, 7, 0, 0)
    SetColor(eb, C.text)
    local bg = eb:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(C.field[1], C.field[2], C.field[3], 0.9)
    local edges = AddBorder(eb, "BORDER", C.rule, 1, 1, 0)
    eb:HookScript("OnEditFocusGained", function() SetEdgeColor(edges, C.goldLight) end)
    eb:HookScript("OnEditFocusLost", function() SetEdgeColor(edges, C.rule) end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return eb
end

-- Multi-line edit box inside a scroll frame. Returns scrollFrame, editBox.
-- `edges` (from AddFieldBox) light up while the box has focus.
local function CreateScrollingEditBox(globalName, parent, width, edges)
    local scroll = CreateFrame("ScrollFrame", globalName .. "Scroll", parent, "UIPanelScrollFrameTemplate")
    local eb = CreateFrame("EditBox", globalName, scroll)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject(ChatFontNormal or GameFontHighlight)
    SetColor(eb, C.text)
    eb:SetWidth(width)
    eb:SetHeight(40)
    eb:SetMaxLetters(MAX_NOTE_LEN)
    eb:SetTextInsets(4, 4, 4, 4)
    scroll:SetScrollChild(eb)

    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnTextChanged", function(self)
        if ScrollingEdit_OnTextChanged then ScrollingEdit_OnTextChanged(self, scroll) end
        if self.onChanged then self.onChanged(self) end
    end)
    eb:SetScript("OnCursorChanged", function(self, x, y, w, h)
        if ScrollingEdit_OnCursorChanged then ScrollingEdit_OnCursorChanged(self, x, y, w, h) end
    end)
    eb:SetScript("OnUpdate", function(self, elapsed)
        if ScrollingEdit_OnUpdate then ScrollingEdit_OnUpdate(self, elapsed, scroll) end
    end)
    if edges then
        eb:HookScript("OnEditFocusGained", function() SetEdgeColor(edges, C.goldLight) end)
        eb:HookScript("OnEditFocusLost", function() SetEdgeColor(edges, C.rule) end)
    end

    -- Clicking anywhere in the text area focuses the edit box
    scroll:EnableMouse(true)
    scroll:SetScript("OnMouseDown", function() eb:SetFocus() end)

    return scroll, eb
end

-- Small flat button in the title-plate style (row Edit / X, limit - / +)
local function FlatButton(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h or 18)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(C.plate[1], C.plate[2], C.plate[3], 1)
    AddBorder(b, "BORDER", C.gold, 1, 1, 0)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.25)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER", 0, 0)
    SetColor(fs, C.header)
    fs:SetText(text)
    b.label = fs
    b:SetScript("OnMouseDown", function() fs:SetPoint("CENTER", 1, -1) end)
    b:SetScript("OnMouseUp", function() fs:SetPoint("CENTER", 0, 0) end)
    return b
end

-- Standard window button (same template and size as the other addons)
local function MenuButton(parent, text, w)
    local b = CreateFrame("Button", nil, parent, "GameMenuButtonTemplate")
    b:SetSize(w or 110, 26)
    b:SetText(text)
    return b
end

local function AddHoverTip(widget, title, body)
    widget:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(title, 1, 0.82, 0)
        if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    widget:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-------------------------------------------------------------------------------
-- Quick Note dropdown (custom, drawn in the window palette)
-------------------------------------------------------------------------------
local DROP_ITEM_H = 18

local function SetShownSafe(obj, shown)
    if shown then obj:Show() else obj:Hide() end
end

local function DropdownSetValue(dd, id)
    local w = PN:GetWord(dd.kind, id)
    dd.value = w and id or nil
    if w then
        dd.text:SetText(WordText(w))
    else
        dd.text:SetText("|cff9c8d70" .. KINDS[dd.kind].label .. "|r")
    end
end

local function MakeWordDropdown(parent, kind, width)
    local dd = CreateFrame("Button", nil, parent)
    dd:SetSize(width, 22)
    local bg = dd:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(C.field[1], C.field[2], C.field[3], 0.9)
    dd.edges = AddBorder(dd, "BORDER", C.rule, 1, 1, 0)
    local hl = dd:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.12)

    local arrow = dd:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up")
    arrow:SetTexCoord(0.2, 0.8, 0.2, 0.8)
    arrow:SetSize(14, 14)
    arrow:SetPoint("RIGHT", -4, 0)

    dd.text = dd:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dd.text:SetPoint("LEFT", 7, 0)
    dd.text:SetPoint("RIGHT", arrow, "LEFT", -4, 0)
    dd.text:SetJustifyH("LEFT")
    if dd.text.SetWordWrap then dd.text:SetWordWrap(false) end

    dd.kind = kind
    dd.SetValue = DropdownSetValue
    dd:SetScript("OnClick", function(self) PN:ToggleDropList(self) end)
    dd:SetScript("OnHide", function(self)
        if PN.dropList and PN.dropList.owner == self then PN.dropList:Hide() end
    end)
    AddHoverTip(dd, "Quick Note " .. KINDS[kind].lower,
        "Pick a word, or choose \"Create " .. KINDS[kind].label .. "\" at the bottom of the list to add your own.")
    dd:SetValue(nil)

    PN.dropdowns = PN.dropdowns or {}
    tinsert(PN.dropdowns, dd)
    return dd
end

function PN:GetDropList()
    if self.dropList then return self.dropList end
    local l = CreateFrame("Frame", "PlayerNotesDropList", UIParent)
    l:SetFrameStrata("FULLSCREEN_DIALOG")
    l:SetClampedToScreen(true)
    l:EnableMouse(true)
    l:Hide()
    local bg = l:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(C.bg[1], C.bg[2], C.bg[3], 0.98)
    AddBorder(l, "BORDER", C.outline, 1, 1, -1)
    AddBorder(l, "BORDER", C.gold,    1, 1,  0)
    l.items = {}

    -- Close when clicking anywhere else
    l:SetScript("OnShow", function(self) pcall(self.RegisterEvent, self, "GLOBAL_MOUSE_DOWN") end)
    l:SetScript("OnHide", function(self)
        pcall(self.UnregisterEvent, self, "GLOBAL_MOUSE_DOWN")
        if self.owner then SetEdgeColor(self.owner.edges, C.rule) end
        self.owner = nil
    end)
    l:SetScript("OnEvent", function(self)
        if not self:IsMouseOver() and not (self.owner and self.owner:IsMouseOver()) then self:Hide() end
    end)
    self.dropList = l
    return l
end

local function GetDropItem(l, i)
    if l.items[i] then return l.items[i] end
    local b = CreateFrame("Button", nil, l)
    b:SetHeight(DROP_ITEM_H)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.22)
    b.check = b:CreateTexture(nil, "OVERLAY")
    b.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    b.check:SetSize(14, 14)
    b.check:SetPoint("LEFT", 4, 0)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("LEFT", 20, 0)
    b.text:SetPoint("RIGHT", -6, 0)
    b.text:SetJustifyH("LEFT")
    if b.text.SetWordWrap then b.text:SetWordWrap(false) end
    b.sep = b:CreateTexture(nil, "ARTWORK")
    b.sep:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.55)
    b.sep:SetHeight(1)
    b.sep:SetPoint("BOTTOMLEFT", b, "TOPLEFT", 6, 2)
    b.sep:SetPoint("BOTTOMRIGHT", b, "TOPRIGHT", -6, 2)
    b:SetScript("OnClick", function(self)
        local fn = self.onClick
        l:Hide()
        if fn then fn() end
    end)
    l.items[i] = b
    return b
end

-- Opens (or closes) the list under a dropdown: None, every word, Create...
function PN:ToggleDropList(dd)
    local l = self:GetDropList()
    if l:IsShown() and l.owner == dd then l:Hide(); return end
    if l:IsShown() then l:Hide() end

    local kind = dd.kind
    local function Changed() if dd.onChange then dd.onChange(dd) end end
    local entries = { { text = "|cff9c8d70None|r", value = false } }
    for _, w in ipairs(self:GetWords(kind)) do
        entries[#entries + 1] = { text = WordText(w), value = w.id }
    end
    entries[#entries + 1] = { text = "|cffd4a017+ Create " .. KINDS[kind].label .. "...|r", create = true }

    local y = -4
    for i, e in ipairs(entries) do
        local b = GetDropItem(l, i)
        if e.create then y = y - 6 end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", 0, y)
        b:SetPoint("TOPRIGHT", 0, y)
        b.text:SetText(e.text)
        SetShownSafe(b.sep, e.create)
        local checked = not e.create and ((e.value == false and dd.value == nil) or e.value == dd.value)
        SetShownSafe(b.check, checked)
        if e.create then
            b.onClick = function()
                PN:OpenWordEditor(kind, nil, function(id) dd:SetValue(id); Changed() end)
            end
        else
            b.onClick = function() dd:SetValue(e.value or nil); Changed() end
        end
        b:Show()
        y = y - DROP_ITEM_H
    end
    for i = #entries + 1, #l.items do l.items[i]:Hide() end

    l:SetSize(math.max(dd:GetWidth(), 160), -y + 4)
    l:ClearAllPoints()
    l:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -2)
    l.owner = dd
    SetEdgeColor(dd.edges, C.goldLight)
    l:Show()
    l:Raise()
end

-------------------------------------------------------------------------------
-- Create / Edit Word window (name + colour palette)
-------------------------------------------------------------------------------
local SWATCH, SWATCH_GAP = 24, 6

local function SetEdgesShown(edges, shown)
    for _, t in ipairs(edges) do SetShownSafe(t, shown) end
end

function PN:CreateWordEditor()
    if self.wordEditor then return self.wordEditor end
    local f = MakeWindow("PlayerNotesWordEditor", 340, 262, "words")

    local nameLabel = AddLabel(f, "Word")
    nameLabel:SetPoint("TOPLEFT", 26, -58)
    local nb = MakeInput("PlayerNotesWordName", f, 222)
    nb:SetPoint("TOPLEFT", 90, -53)
    nb:SetMaxLetters(MAX_WORD_LEN)
    nb:SetScript("OnTextChanged", function() PN:UpdateWordPreview() end)
    nb:SetScript("OnEnterPressed", function() PN:SaveWordFromEditor() end)
    f.nameBox = nb

    local colorLabel = AddLabel(f, "Color")
    colorLabel:SetPoint("TOPLEFT", 26, -94)
    f.swatches = {}
    for i, p in ipairs(PALETTE) do
        local col, row = (i - 1) % 6, math.floor((i - 1) / 6)
        local s = CreateFrame("Button", nil, f)
        s:SetSize(SWATCH, SWATCH)
        s:SetPoint("TOPLEFT", 90 + col * (SWATCH + SWATCH_GAP), -88 - row * (SWATCH + SWATCH_GAP))
        local r, g, b = HexToRGB(p.hex)
        local fill = s:CreateTexture(nil, "ARTWORK")
        fill:SetPoint("TOPLEFT", 2, -2)
        fill:SetPoint("BOTTOMRIGHT", -2, 2)
        fill:SetColorTexture(r, g, b, 1)
        AddBorder(s, "BORDER", C.outline, 1, 2, 0)
        s.sel = AddBorder(s, "OVERLAY", { 1, 0.82, 0 }, 1, 2, -2)    -- shown when selected
        s.hex = p.hex
        s:SetScript("OnClick", function() f.color = p.hex; PN:UpdateWordPreview() end)
        AddHoverTip(s, p.name)
        f.swatches[i] = s
    end

    local previewLabel = AddLabel(f, "Preview")
    previewLabel:SetPoint("TOPLEFT", 26, -160)
    f.preview = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.preview:SetPoint("LEFT", previewLabel, "LEFT", 64, 0)

    f.error = AddLabel(f, "", nil, { 1, 0.40, 0.33 })
    f.error:SetPoint("TOPLEFT", 26, -186)
    f.error:SetWidth(290)

    AddFooterRule(f, 48)
    f.btnSave = MenuButton(f, "Save", 90)
    f.btnSave:SetPoint("BOTTOMLEFT", 20, 14)
    f.btnSave:SetScript("OnClick", function() PN:SaveWordFromEditor() end)
    f.btnDelete = MenuButton(f, "Delete", 90)
    f.btnDelete:SetPoint("LEFT", f.btnSave, "RIGHT", 6, 0)
    f.btnDelete:SetScript("OnClick", function() ConfirmDeleteWord(f.kind, f.wordId) end)
    f.btnCancel = MenuButton(f, "Cancel", 90)
    f.btnCancel:SetPoint("BOTTOMRIGHT", -20, 14)
    f.btnCancel:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnHide", function() nb:ClearFocus() end)
    self.wordEditor = f
    return f
end

-- kind = "adj" / "noun"; id = word to edit, or nil to create one.
-- onSaved(id) runs after saving (used to select a new word in a dropdown).
function PN:OpenWordEditor(kind, id, onSaved)
    local f = self:CreateWordEditor()
    local w = id and self:GetWord(kind, id)
    local k = KINDS[kind]
    f.kind, f.wordId, f.onSaved = kind, w and w.id or nil, onSaved
    f.color = w and w.color or "ffffff"

    SetWindowTitle(f, (w and "Edit " or "Create ") .. k.label)
    if w then
        local uses = self:CountWordUses(kind, w.id)
        f.info:SetText((w.default and ("Default " .. k.lower .. " (can be edited, not deleted)") or ("Custom " .. k.lower))
            .. DOT .. ("Used in %d %s"):format(uses, uses == 1 and "note" or "notes"))
    else
        f.info:SetText("New Quick Note " .. k.lower)
    end
    f.nameBox:SetText(w and w.text or "")
    f.error:SetText("")
    SetShownSafe(f.btnDelete, w and not w.default)

    f:Show()
    f:Raise()
    f.nameBox:SetFocus()
    self:UpdateWordPreview()
end

function PN:UpdateWordPreview()
    local f = self.wordEditor
    if not f then return end
    local text = Trim(f.nameBox:GetText())
    if text == "" then text = KINDS[f.kind].label end
    f.preview:SetText("|cff" .. f.color .. ForDisplay(text) .. "|r")
    for _, s in ipairs(f.swatches) do SetEdgesShown(s.sel, s.hex == f.color) end
end

function PN:SaveWordFromEditor()
    local f = self.wordEditor
    local k = KINDS[f.kind]
    local text = Trim((f.nameBox:GetText():gsub("|", ""):gsub("%s+", " ")))
    if text == "" then
        f.error:SetText("Enter a word.")
        return
    end
    if self:FindWordByText(f.kind, text, f.wordId) then
        f.error:SetText(("That %s already exists."):format(k.lower))
        return
    end
    if not f.wordId and #self:GetWords(f.kind) >= MAX_WORDS then
        f.error:SetText(("You can have up to %d %s."):format(MAX_WORDS, k.plural:lower()))
        return
    end
    local id = self:SaveWord(f.kind, f.wordId, text, f.color)
    local cb = f.onSaved
    f:Hide()
    if cb then cb(id) end
end

-------------------------------------------------------------------------------
-- Note window (Read / Edit / Create)
-------------------------------------------------------------------------------
local NOTE_W, NOTE_H = 460, 390
local NOTE_BODY_W    = NOTE_W - 26 - 44

function PN:CreateNoteFrame()
    if self.noteFrame then return self.noteFrame end

    local f = MakeWindow("PlayerNotesNoteFrame", NOTE_W, NOTE_H, "note")

    -- Quick Note row: two dropdowns while editing, coloured words while reading
    local qLabel = AddLabel(f, "Quick Note")
    qLabel:SetPoint("TOPLEFT", 24, -54)
    f.adjDD = MakeWordDropdown(f, "adj", 140)
    f.adjDD:SetPoint("TOPLEFT", 104, -48)
    f.nounDD = MakeWordDropdown(f, "noun", 140)
    f.nounDD:SetPoint("LEFT", f.adjDD, "RIGHT", 6, 0)
    f.quickText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.quickText:SetPoint("LEFT", qLabel, "LEFT", 80, 0)

    -- Text area
    local _, edges = AddFieldBox(f, 20, -80, -20, 60)

    -- Read view: plain text in a scroll frame
    local readScroll = CreateFrame("ScrollFrame", "PlayerNotesReadScroll", f, "UIPanelScrollFrameTemplate")
    readScroll:SetPoint("TOPLEFT", 26, -86)
    readScroll:SetPoint("BOTTOMRIGHT", -44, 66)
    local readChild = CreateFrame("Frame", nil, readScroll)
    readChild:SetSize(NOTE_BODY_W, 10)
    readScroll:SetScrollChild(readChild)
    local readText = readChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    readText:SetPoint("TOPLEFT", 4, -4)
    readText:SetWidth(NOTE_BODY_W - 8)
    readText:SetJustifyH("LEFT")
    readText:SetJustifyV("TOP")
    SetColor(readText, C.text)
    if readText.SetSpacing then readText:SetSpacing(3) end
    f.readScroll, f.readChild, f.readText = readScroll, readChild, readText

    -- Edit view: multi-line edit box
    local editScroll, editBox = CreateScrollingEditBox("PlayerNotesNoteEditBox", f, NOTE_BODY_W, edges)
    editScroll:SetPoint("TOPLEFT", 26, -86)
    editScroll:SetPoint("BOTTOMRIGHT", -44, 66)
    editBox.onChanged = function(self)
        f.counter:SetText(("%d / %d"):format(Utf8Len(self:GetText()), MAX_NOTE_LEN))
    end
    AddPlaceholder(editBox, "Write your note here (optional if you set a Quick Note)...", true)
    f.editScroll, f.editBox = editScroll, editBox

    -- Footer
    AddFooterRule(f, 48)

    f.btnPrimary = MenuButton(f, "Save", 100)
    f.btnPrimary:SetPoint("BOTTOMLEFT", 20, 14)

    f.btnDelete = MenuButton(f, "Delete", 100)
    f.btnDelete:SetPoint("LEFT", f.btnPrimary, "RIGHT", 6, 0)
    f.btnDelete:SetScript("OnClick", function() ConfirmDelete(f.playerName) end)

    f.btnClose = MenuButton(f, "Close", 100)
    f.btnClose:SetPoint("BOTTOMRIGHT", -20, 14)

    f.counter = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.counter:SetPoint("RIGHT", f.btnClose, "LEFT", -12, 0)
    f.counter:SetJustifyH("RIGHT")
    SetColor(f.counter, C.muted)

    f:SetScript("OnHide", function() editBox:ClearFocus() end)

    self.noteFrame = f
    return f
end

function PN:SaveNoteFromFrame()
    local f = self.noteFrame
    local text = Trim(f.editBox:GetText())
    local adj, noun = f.adjDD.value, f.nounDD.value
    if text == "" and not adj and not noun then
        if self:GetNote(f.playerName) then
            ConfirmDelete(f.playerName)        -- saving an empty note = delete
        else
            print(PREFIX .. "Write a note or choose a Quick Note first.")
        end
        return
    end
    self:SetNote(f.playerName, text, f.playerClass, adj, noun)
    f.mode = "read"
    self:UpdateNoteFrame()
end

function PN:UpdateNoteFrame()
    local f = self.noteFrame
    if not f then return end
    local entry = self:GetNote(f.playerName)
    local class = f.playerClass or (entry and entry.class)

    if f.mode == "read" and not entry then f.mode = "edit" end
    SetWindowTitle(f, ColorName(f.playerName, class))

    if f.mode == "read" then
        local info = "Created " .. FormatDate(entry.created)
        if entry.updated and entry.created and entry.updated - entry.created > 60 then
            info = info .. DOT .. "Edited " .. FormatDate(entry.updated)
        end
        f.info:SetText(info)

        f.adjDD:Hide()
        f.nounDD:Hide()
        f.quickText:SetText(self:QuickNoteText(entry) or "|cff9c8d70None|r")
        f.quickText:Show()

        f.editScroll:Hide()
        f.readScroll:Show()
        if entry.text ~= "" then
            f.readText:SetText(ForDisplay(entry.text))
        else
            f.readText:SetText("|cff9c8d70No written note.|r")
        end
        f.readChild:SetHeight(math.max(f.readText:GetStringHeight() + 8, 10))
        if f.readScroll.UpdateScrollChildRect then f.readScroll:UpdateScrollChildRect() end
        f.readScroll:SetVerticalScroll(0)

        f.btnPrimary:SetText("Edit")
        f.btnPrimary:SetScript("OnClick", function()
            f.mode = "edit"
            PN:UpdateNoteFrame()
            PN:FocusNoteEditor()
        end)
        f.btnDelete:Show()
        f.btnClose:SetText("Close")
        f.btnClose:SetScript("OnClick", function() f:Hide() end)
        f.counter:SetText("")
    else
        local isNew = entry == nil
        f.info:SetText(isNew and "New note" or ("Editing note" .. DOT .. "Last edited " .. FormatDate(entry.updated)))

        f.quickText:Hide()
        f.adjDD:Show()
        f.nounDD:Show()
        f.adjDD:SetValue(entry and entry.adj)
        f.nounDD:SetValue(entry and entry.noun)

        f.readScroll:Hide()
        f.editScroll:Show()
        f.editBox:SetText(entry and entry.text or "")
        f.editScroll:SetVerticalScroll(0)
        f.editBox.onChanged(f.editBox)

        f.btnPrimary:SetText("Save")
        f.btnPrimary:SetScript("OnClick", function() PN:SaveNoteFromFrame() end)
        if isNew then f.btnDelete:Hide() else f.btnDelete:Show() end
        f.btnClose:SetText("Cancel")
        f.btnClose:SetScript("OnClick", function()
            if PN:GetNote(f.playerName) then
                f.mode = "read"
                PN:UpdateNoteFrame()
            else
                f:Hide()
            end
        end)
    end
end

function PN:FocusNoteEditor()
    local eb = self.noteFrame.editBox
    eb:SetFocus()
    eb:SetCursorPosition(#eb:GetText())
end

-- Open the note window for a player. mode = "read" or "edit".
-- Reading a player with no note opens the editor instead.
function PN:ShowNote(name, mode, class)
    name = CleanName(name)
    if not name then return end
    local f = self:CreateNoteFrame()
    local entry = self:GetNote(name)
    f.playerName  = name
    f.playerClass = class or (entry and entry.class)
    f.mode        = (mode == "read" and entry) and "read" or "edit"
    f:Show()
    f:Raise()
    self:UpdateNoteFrame()
    if f.mode == "edit" then self:FocusNoteEditor() end
end

-------------------------------------------------------------------------------
-- Player Notes window (/pn)
--   left:  Tooltip settings, Add a Player and Note, Saved Notes list
--   right: Quick Note Words (adjectives and nouns)
-------------------------------------------------------------------------------
local OPT_W, OPT_H = 780, 680
local LEFT_R       = 520                    -- right edge of the left column
local RIGHT_X      = 540                    -- left edge of the right column
local SCROLL_LEFT  = 20
local CHILD_W      = LEFT_R - 20 - SCROLL_LEFT
local ROW_H        = 20
local LIST_COLS    = { name = { x = 6, w = 140 }, quick = { x = 152, w = 118 }, note = { x = 276 } }
local WORD_ROW_H   = 18
local WORD_CHILD_W = (OPT_W - 40) - RIGHT_X

local function GetListRow(f, i)
    if f.rows[i] then return f.rows[i] end
    local row = CreateFrame("Button", nil, f.child)
    row:SetSize(CHILD_W, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:RegisterForClicks("LeftButtonUp")

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    if i % 2 == 0 then
        row.bg:SetColorTexture(C.stripe[1], C.stripe[2], C.stripe[3], 0.22)
    else
        row.bg:SetColorTexture(0, 0, 0, 0)
    end
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.18)

    row.del = FlatButton(row, "X", 18, 16)
    row.del:SetPoint("RIGHT", -4, 0)
    row.del:SetScript("OnClick", function(self) ConfirmDelete(self:GetParent().entry.name) end)
    AddHoverTip(row.del, "Delete note")

    row.edit = FlatButton(row, "Edit", 38, 16)
    row.edit:SetPoint("RIGHT", row.del, "LEFT", -4, 0)
    row.edit:SetScript("OnClick", function(self)
        local e = self:GetParent().entry
        PN:ShowNote(e.name, "edit", e.class)
    end)

    local function Cell(col, font)
        local fs = row:CreateFontString(nil, "OVERLAY", font)
        fs:SetPoint("LEFT", col.x, 0)
        if col.w then fs:SetWidth(col.w) end
        fs:SetJustifyH("LEFT")
        if fs.SetWordWrap then fs:SetWordWrap(false) end
        return fs
    end
    row.name  = Cell(LIST_COLS.name, "GameFontNormalSmall")
    row.quick = Cell(LIST_COLS.quick, "GameFontNormalSmall")
    row.preview = Cell(LIST_COLS.note, "GameFontHighlightSmall")
    row.preview:SetPoint("RIGHT", row.edit, "LEFT", -8, 0)
    SetColor(row.preview, C.text)

    row:SetScript("OnClick", function(self) PN:ShowNote(self.entry.name, "read", self.entry.class) end)
    row:SetScript("OnEnter", function(self)
        local e = self.entry
        if not e then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetMinimumWidth then GameTooltip:SetMinimumWidth(260) end
        GameTooltip:AddLine(ColorName(e.name, e.class))
        local quick = PN:QuickNoteText(e)
        if quick then GameTooltip:AddLine(quick) end
        if e.text ~= "" then
            GameTooltip:AddLine(ForDisplay(Truncate(e.text, 400)), C.text[1], C.text[2], C.text[3], true)
        end
        GameTooltip:AddLine("Edited " .. FormatDate(e.updated) .. "  •  click to read", C.muted[1], C.muted[2], C.muted[3])
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        if GameTooltip.SetMinimumWidth then GameTooltip:SetMinimumWidth(0) end
        GameTooltip:Hide()
    end)
    f.rows[i] = row
    return row
end

-- One row in an Adjectives / Nouns list
local function GetWordRow(panel, i)
    if panel.rows[i] then return panel.rows[i] end
    local row = CreateFrame("Button", nil, panel.child)
    row:SetSize(WORD_CHILD_W, WORD_ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * WORD_ROW_H)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    if i % 2 == 0 then
        bg:SetColorTexture(C.stripe[1], C.stripe[2], C.stripe[3], 0.22)
    else
        bg:SetColorTexture(0, 0, 0, 0)
    end
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(C.goldLight[1], C.goldLight[2], C.goldLight[3], 0.18)

    row.swatch = row:CreateTexture(nil, "ARTWORK")
    row.swatch:SetSize(10, 10)
    row.swatch:SetPoint("LEFT", 6, 0)

    row.del = FlatButton(row, "X", 18, 16)
    row.del:SetPoint("RIGHT", -4, 0)
    row.del:SetScript("OnClick", function(self) ConfirmDeleteWord(panel.kind, self:GetParent().word.id) end)
    AddHoverTip(row.del, "Delete " .. KINDS[panel.kind].lower)

    row.edit = FlatButton(row, "Edit", 34, 16)
    row.edit:SetPoint("RIGHT", -26, 0)
    row.edit:SetScript("OnClick", function(self) PN:OpenWordEditor(panel.kind, self:GetParent().word.id) end)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.text:SetPoint("LEFT", 22, 0)
    row.text:SetPoint("RIGHT", row.edit, "LEFT", -4, 0)
    row.text:SetJustifyH("LEFT")
    if row.text.SetWordWrap then row.text:SetWordWrap(false) end

    row:SetScript("OnClick", function(self) PN:OpenWordEditor(panel.kind, self.word.id) end)
    row:SetScript("OnEnter", function(self)
        local w = self.word
        if not w then return end
        local uses = PN:CountWordUses(panel.kind, w.id)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(WordText(w))
        GameTooltip:AddLine(w.default and ("Default " .. KINDS[panel.kind].lower .. ": can be edited, not deleted")
            or ("Custom " .. KINDS[panel.kind].lower), C.text[1], C.text[2], C.text[3])
        GameTooltip:AddLine(("Used in %d %s  •  click to edit"):format(uses, uses == 1 and "note" or "notes"),
            C.muted[1], C.muted[2], C.muted[3])
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    panel.rows[i] = row
    return row
end

-- Adjectives / Nouns list with a "+ Create" button, in the right column
local function MakeWordPanel(f, kind, y, bottomY)
    local panel = { kind = kind, rows = {} }
    panel.header = AddSection(f, KINDS[kind].plural, y, RIGHT_X, -20)

    local create = FlatButton(f, "+ Create", 64, 18)
    create:SetPoint("TOPRIGHT", f, "TOPRIGHT", -22, y + 2)
    create:SetScript("OnClick", function() PN:OpenWordEditor(kind, nil) end)
    AddHoverTip(create, "Create " .. KINDS[kind].label, "Add a word to the Quick Note " .. KINDS[kind].lower .. " dropdown.")

    local scroll = CreateFrame("ScrollFrame", "PlayerNotes" .. KINDS[kind].label .. "Scroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", RIGHT_X, y - 20)
    scroll:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -40, bottomY)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(WORD_CHILD_W, 10)
    scroll:SetScrollChild(child)
    panel.scroll, panel.child = scroll, child
    return panel
end

function PN:CreateOptions()
    if self.options then return self.options end

    local f = MakeWindow("PlayerNotesOptionsFrame", OPT_W, OPT_H, "options")
    SetWindowTitle(f, "Player Notes")
    local LEFT_RULE = -(OPT_W - LEFT_R)       -- section rules stop at the left column

    -- Divider between the two columns
    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(C.rule[1], C.rule[2], C.rule[3], 0.7)
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", (LEFT_R + RIGHT_X) / 2, -46)
    divider:SetPoint("BOTTOMLEFT", (LEFT_R + RIGHT_X) / 2, 56)

    ---------------------------------------------------------------- Tooltip
    AddSection(f, "Tooltip", -46, 20, LEFT_RULE)

    local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb:SetPoint("TOPLEFT", 20, -70)
    local cbText = AddLabel(cb, "Show notes in player tooltips")
    cbText:SetPoint("LEFT", cb, "RIGHT", 1, 1)
    cb:SetScript("OnClick", function(self) PN:SetTooltipEnabled(self:GetChecked()) end)
    AddHoverTip(cb, "Show notes in player tooltips",
        "When you hover a player you have a note about, their Quick Note and the start of the note are added to the bottom of their tooltip.")
    f.tooltipCheck = cb

    local limitLabel = AddLabel(f, "Tooltip character limit")
    limitLabel:SetPoint("TOPLEFT", 26, -102)

    local minus = FlatButton(f, "-", 20, 20)
    minus:SetPoint("LEFT", limitLabel, "RIGHT", 12, 0)

    local lb = MakeInput("PlayerNotesLimitBox", f, 46)
    lb:SetPoint("LEFT", minus, "RIGHT", 4, 0)
    lb:SetNumeric(true)
    lb:SetMaxLetters(3)
    lb:SetJustifyH("CENTER")
    lb:SetScript("OnEscapePressed", function(self)
        self:SetText(tostring(PN.db.settings.tooltipLimit))
        self:ClearFocus()
    end)
    lb:SetScript("OnEditFocusLost", function(self) PN:SetTooltipLimit(self:GetText()) end)

    local plus = FlatButton(f, "+", 20, 20)
    plus:SetPoint("LEFT", lb, "RIGHT", 4, 0)

    local function Step(d)
        local step = IsShiftKeyDown() and 50 or 10
        PN:SetTooltipLimit(PN.db.settings.tooltipLimit + d * step)
    end
    minus:SetScript("OnClick", function() Step(-1) end)
    plus:SetScript("OnClick", function() Step(1) end)
    AddHoverTip(minus, "Shorter", "-10 characters (Shift: -50)")
    AddHoverTip(plus, "Longer", "+10 characters (Shift: +50)")

    local limitHint = AddLabel(f, ("%d-%d, default %d"):format(MIN_LIMIT, MAX_LIMIT, DEFAULT_LIMIT), nil, C.muted)
    limitHint:SetPoint("LEFT", plus, "RIGHT", 10, 0)

    f.limitBox = lb
    f.limitWidgets = { limitLabel, minus, lb, plus, limitHint }

    ---------------------------------------------------------------- Add a note
    AddSection(f, "Add a Player and Note", -132, 20, LEFT_RULE)

    local nameLabel = AddLabel(f, "Player name")
    nameLabel:SetPoint("TOPLEFT", 26, -162)

    local nameBox = MakeInput("PlayerNotesAddName", f, 260)
    nameBox:SetPoint("TOPLEFT", 110, -157)
    nameBox:SetMaxLetters(60)
    AddPlaceholder(nameBox, "First-name Last-name")
    f.nameBox = nameBox

    local quickLabel = AddLabel(f, "Quick Note")
    quickLabel:SetPoint("TOPLEFT", 26, -192)
    f.addAdjDD = MakeWordDropdown(f, "adj", 150)
    f.addAdjDD:SetPoint("TOPLEFT", 110, -187)
    f.addNounDD = MakeWordDropdown(f, "noun", 150)
    f.addNounDD:SetPoint("LEFT", f.addAdjDD, "RIGHT", 6, 0)

    local noteLabel = AddLabel(f, "Note")
    noteLabel:SetPoint("TOPLEFT", 26, -222)

    local _, noteEdges = AddFieldBox(f, 110, -217, LEFT_RULE, OPT_H - 283)   -- box from y=-217 to y=-283
    local noteScroll, noteBox = CreateScrollingEditBox("PlayerNotesAddNote", f, LEFT_R - 24 - 114, noteEdges)
    noteScroll:SetPoint("TOPLEFT", 114, -221)
    noteScroll:SetPoint("BOTTOMRIGHT", f, "TOPLEFT", LEFT_R - 24, -279)
    AddPlaceholder(noteBox, "Write your note here...", true)
    f.noteBox = noteBox

    nameBox:SetScript("OnTextChanged", function() PN:UpdateAddStatus() end)
    nameBox:SetScript("OnEnterPressed", function() noteBox:SetFocus() end)
    nameBox:SetScript("OnTabPressed", function() noteBox:SetFocus() end)

    local saveBtn = MenuButton(f, "Save Note", 110)
    saveBtn:SetPoint("TOPLEFT", 108, -292)
    saveBtn:SetScript("OnClick", function() PN:SaveFromAddForm() end)

    local clearBtn = MenuButton(f, "Clear", 80)
    clearBtn:SetPoint("LEFT", saveBtn, "RIGHT", 6, 0)
    clearBtn:SetScript("OnClick", function() PN:ClearAddForm(); PN:SetAddStatus("") end)

    local status = AddLabel(f, "")
    status:SetPoint("LEFT", clearBtn, "RIGHT", 10, 0)
    status:SetPoint("RIGHT", f, "LEFT", LEFT_R, 0)
    f.addStatus = status

    ---------------------------------------------------------------- Saved notes
    f.listHeader = AddSection(f, "Saved Notes", -332, 20, LEFT_RULE)

    local search = MakeInput("PlayerNotesSearchBox", f, 230)
    search:SetPoint("TOPLEFT", 20, -358)
    search:SetMaxLetters(60)
    AddPlaceholder(search, "Search names, Quick Notes or notes...")
    search:SetScript("OnTextChanged", function() PN:RefreshList() end)
    f.search = search

    local hint = AddLabel(f, "Click a note to read it", nil, C.muted)
    hint:SetPoint("LEFT", search, "RIGHT", 12, 0)

    -- Fixed column headers
    local headerY = -390
    local function Header(text, col)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", SCROLL_LEFT + col.x, headerY)
        SetColor(fs, C.header)
        fs:SetText(text)
    end
    Header("Player", LIST_COLS.name)
    Header("Quick Note", LIST_COLS.quick)
    Header("Note", LIST_COLS.note)
    local headRule = f:CreateTexture(nil, "ARTWORK")
    headRule:SetColorTexture(C.rule[1], C.rule[2], C.rule[3], 1)
    headRule:SetPoint("TOPLEFT", SCROLL_LEFT, headerY - 18)
    headRule:SetPoint("TOPRIGHT", f, "TOPLEFT", LEFT_R, headerY - 18)
    headRule:SetHeight(1)

    -- Scrolling list; right inset leaves room for the scrollbar
    local scroll = CreateFrame("ScrollFrame", "PlayerNotesListScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", SCROLL_LEFT, headerY - 22)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", LEFT_R - 20, 56)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(CHILD_W, 10)
    scroll:SetScrollChild(child)
    f.scroll, f.child, f.rows = scroll, child, {}

    f.empty = child:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.empty:SetPoint("TOP", 0, -40)
    f.empty:SetWidth(CHILD_W - 40)
    SetColor(f.empty, C.muted)

    ---------------------------------------------------------------- Quick Note words
    AddSection(f, "Quick Note Words", -46, RIGHT_X, -20)
    local intro = AddLabel(f, "Words for the two Quick Note dropdowns. Click a word to change its name or color. Default words can be edited but not deleted.", nil, C.muted)
    intro:SetPoint("TOPLEFT", RIGHT_X + 2, -70)
    intro:SetWidth(OPT_W - 20 - RIGHT_X - 2)
    intro:SetJustifyV("TOP")
    if intro.SetSpacing then intro:SetSpacing(2) end

    f.wordPanels = {
        MakeWordPanel(f, "adj",  -124, -364),
        MakeWordPanel(f, "noun", -378, -(OPT_H - 56)),
    }

    ---------------------------------------------------------------- Footer
    AddFooterRule(f, 48)

    local legend = AddLabel(f, "Right-click a player to Create, Read or Edit a note" .. DOT .. "/pn help", nil, C.legend)
    legend:SetPoint("BOTTOMLEFT", SCROLL_LEFT + 4, 20)

    local closeBtn = MenuButton(f, "Close", 110)
    closeBtn:SetPoint("BOTTOMRIGHT", -20, 14)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnShow", function()
        PN:UpdateOptionsControls()
        PN:RefreshList()
        PN:RefreshWordLists()
        PN:UpdateAddStatus()
    end)
    f:SetScript("OnHide", function()
        nameBox:ClearFocus(); noteBox:ClearFocus(); search:ClearFocus(); lb:ClearFocus()
    end)

    self.options = f
    return f
end

function PN:RefreshWordLists()
    local f = self.options
    if not f or not f.wordPanels then return end
    for _, panel in ipairs(f.wordPanels) do
        local words = self:GetWords(panel.kind)
        panel.header:SetText(("%s  |cffa8987a(%d)|r"):format(KINDS[panel.kind].plural, #words))
        for i, w in ipairs(words) do
            local row = GetWordRow(panel, i)
            row.word = w
            row.swatch:SetColorTexture(HexToRGB(w.color))
            row.text:SetText(WordText(w))
            SetShownSafe(row.del, not w.default)
            row:Show()
        end
        for i = #words + 1, #panel.rows do
            panel.rows[i].word = nil
            panel.rows[i]:Hide()
        end
        panel.child:SetHeight(math.max(#words * WORD_ROW_H, 10))
        if panel.scroll.UpdateScrollChildRect then panel.scroll:UpdateScrollChildRect() end
    end
end

function PN:UpdateOptionsControls()
    local f = self.options
    if not f then return end
    local s = self.db.settings
    f.tooltipCheck:SetChecked(s.showTooltip)
    if not f.limitBox:HasFocus() then f.limitBox:SetText(tostring(s.tooltipLimit)) end
    for _, w in ipairs(f.limitWidgets) do w:SetAlpha(s.showTooltip and 1 or 0.45) end
end

function PN:SetAddStatus(text)
    if self.options then self.options.addStatus:SetText(text or "") end
end

-- Warn when the typed name already has a note
function PN:UpdateAddStatus()
    local f = self.options
    if not f then return end
    local name = CleanName(f.nameBox:GetText())
    local e = name and self:GetNote(name)
    if e then
        self:SetAddStatus("|cffffe64d" .. e.name .. " already has a note. Saving replaces it.|r")
    elseif f.addStatus:GetText() and f.addStatus:GetText():find("already has a note", 1, true) then
        self:SetAddStatus("")
    end
end

function PN:ClearAddForm()
    local f = self.options
    if not f then return end
    f.nameBox:SetText("")
    f.noteBox:SetText("")
    f.addAdjDD:SetValue(nil)
    f.addNounDD:SetValue(nil)
    f.nameBox:ClearFocus()
    f.noteBox:ClearFocus()
end

function PN:SaveFromAddForm()
    local f = self.options
    local name = CleanName(f.nameBox:GetText())
    local text = Trim(f.noteBox:GetText())
    local adj, noun = f.addAdjDD.value, f.addNounDD.value
    if not name then
        self:SetAddStatus("|cffff6655Enter a player name.|r")
        f.nameBox:SetFocus()
        return
    end
    if text == "" and not adj and not noun then
        self:SetAddStatus("|cffff6655Write a note or choose a Quick Note.|r")
        f.noteBox:SetFocus()
        return
    end
    local existing = self:GetNote(name)
    if existing then
        StaticPopup_Show("PLAYERNOTES_CONFIRM_OVERWRITE", existing.name, nil,
            { name = name, text = text, adj = adj, noun = noun })
        return
    end
    self:SetNote(name, text, nil, adj, noun)
    self:ClearAddForm()
    self:SetAddStatus("|cff66ff66Saved note about " .. name .. ".|r")
end

function PN:RefreshList()
    local f = self.options
    if not f then return end
    local data = self:GetSortedNotes(f.search:GetText())
    local total = self:CountNotes()

    if #data ~= total then
        f.listHeader:SetText(("Saved Notes  |cffa8987a(%d of %d)|r"):format(#data, total))
    else
        f.listHeader:SetText(("Saved Notes  |cffa8987a(%d)|r"):format(total))
    end
    f.info:SetText(("%d %s saved"):format(total, total == 1 and "note" or "notes") .. DOT
        .. "Tooltip notes " .. (self.db.settings.showTooltip and "|cff66ff66on|r" or "|cffff6655off|r"))

    for i, e in ipairs(data) do
        local row = GetListRow(f, i)
        row.entry = e
        row.name:SetText(ColorName(e.name, e.class))
        row.quick:SetText(self:QuickNoteText(e) or "|cff7d705a—|r")
        row.preview:SetText(ForDisplay((e.text:gsub("%s+", " "))))
        row:Show()
    end
    for i = #data + 1, #f.rows do
        f.rows[i].entry = nil
        f.rows[i]:Hide()
    end
    f.child:SetHeight(math.max(#data * ROW_H, 10))
    if f.scroll.UpdateScrollChildRect then f.scroll:UpdateScrollChildRect() end

    if total == 0 then
        f.empty:SetText("No notes yet.\nRight-click a player, or add one above.")
    elseif #data == 0 then
        f.empty:SetText("No notes match your search.")
    else
        f.empty:SetText("")
    end
end

function PN:ToggleOptions()
    local f = self:CreateOptions()
    if f:IsShown() then f:Hide() else f:Show(); f:Raise() end
end

-------------------------------------------------------------------------------
-- Entry in the game's Interface / AddOns options (opens the window above)
-------------------------------------------------------------------------------
function PN:RegisterBlizzardOptions()
    local panel = CreateFrame("Frame")
    panel.name = "Player Notes"

    local t = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t:SetPoint("TOPLEFT", 16, -16)
    t:SetText("Player Notes")

    local d = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    d:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -10)
    d:SetWidth(520)
    d:SetJustifyH("LEFT")
    d:SetText("Tooltip settings, manually adding players and the list of saved notes are in the Player Notes options window. You can also open it with /pn.")

    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(220, 24)
    b:SetPoint("TOPLEFT", d, "BOTTOMLEFT", 0, -14)
    b:SetText("Open Player Notes Options")
    b:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
        if InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown() then HideUIPanel(InterfaceOptionsFrame) end
        if GameMenuFrame and GameMenuFrame:IsShown() then HideUIPanel(GameMenuFrame) end
        local f = PN:CreateOptions()
        f:Show()
        f:Raise()
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

-------------------------------------------------------------------------------
-- Right-click menus
-------------------------------------------------------------------------------
local MENU_TITLE = "Player Notes"

-- Modern menu system (Menu.ModifyMenu)
local MODERN_MENU_TAGS = {
    "MENU_UNIT_PLAYER", "MENU_UNIT_ENEMY_PLAYER", "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS",
    "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_RAID",
    "MENU_UNIT_FRIEND", "MENU_UNIT_FRIEND_OFFLINE",
    "MENU_UNIT_GUILD", "MENU_UNIT_GUILD_OFFLINE", "MENU_UNIT_CHAT_ROSTER",
    "MENU_UNIT_COMMUNITIES_MEMBER", "MENU_UNIT_COMMUNITIES_WOW_MEMBER", "MENU_UNIT_COMMUNITIES_GUILD_MEMBER",
    "MENU_UNIT_WORLD_STATE_SCORE",
}

local function AddModernMenuItems(owner, root, ctx)
    if not PN.db or not root then return end
    local name, class = ResolveContextName(ctx)
    if not name or IsSelf(name) then return end
    local hasNote = PN:GetNote(name) ~= nil

    if root.CreateDivider then root:CreateDivider() end
    if root.CreateTitle then root:CreateTitle(MENU_TITLE) end
    if hasNote then
        root:CreateButton("Read Note", function() PN:ShowNote(name, "read", class) end)
        root:CreateButton("Edit Note", function() PN:ShowNote(name, "edit", class) end)
    else
        root:CreateButton("Create Note", function() PN:ShowNote(name, "edit", class) end)
    end
end

-- Older UnitPopup / UIDropDownMenu system
local LEGACY_WHICH = {
    PLAYER = true, ENEMY_PLAYER = true, TARGET = true, FOCUS = true,
    PARTY = true, RAID_PLAYER = true, RAID = true,
    FRIEND = true, FRIEND_OFFLINE = true, GUILD = true, GUILD_OFFLINE = true,
    CHAT_ROSTER = true, WORLD_STATE_SCORE = true,
    COMMUNITIES_WOW_MEMBER = true, COMMUNITIES_GUILD_MEMBER = true,
}

local function AddLegacyMenuItems(dropdownMenu, which, unit, name)
    if not PN.db or (UIDROPDOWNMENU_MENU_LEVEL or 1) ~= 1 or not LEGACY_WHICH[which] then return end
    local ctx = {
        unit   = unit or (dropdownMenu and dropdownMenu.unit),
        name   = name or (dropdownMenu and dropdownMenu.name),
        server = dropdownMenu and dropdownMenu.server,
    }
    local pname, class = ResolveContextName(ctx)
    if not pname or IsSelf(pname) then return end
    local hasNote = PN:GetNote(pname) ~= nil

    local info = UIDropDownMenu_CreateInfo()
    info.text, info.isTitle, info.notCheckable = MENU_TITLE, true, true
    UIDropDownMenu_AddButton(info, 1)

    local function Add(text, mode)
        local b = UIDropDownMenu_CreateInfo()
        b.text, b.notCheckable = text, true
        b.func = function()
            CloseDropDownMenus()
            PN:ShowNote(pname, mode, class)
        end
        UIDropDownMenu_AddButton(b, 1)
    end
    if hasNote then
        Add("Read Note", "read")
        Add("Edit Note", "edit")
    else
        Add("Create Note", "edit")
    end
end

function PN:HookMenus()
    if Menu and Menu.ModifyMenu then
        for _, tag in ipairs(MODERN_MENU_TAGS) do
            Menu.ModifyMenu(tag, function(owner, root, ctx)
                local ok, err = pcall(AddModernMenuItems, owner, root, ctx)
                if not ok then print(PREFIX .. "|cffff4040menu error:|r " .. tostring(err)) end
            end)
        end
        self.menuSystem = "Menu.ModifyMenu"
    elseif type(UnitPopup_ShowMenu) == "function" then
        hooksecurefunc("UnitPopup_ShowMenu", function(dropdownMenu, which, unit, name)
            local ok, err = pcall(AddLegacyMenuItems, dropdownMenu, which, unit, name)
            if not ok then print(PREFIX .. "|cffff4040menu error:|r " .. tostring(err)) end
        end)
        self.menuSystem = "UnitPopup_ShowMenu"
    else
        self.menuSystem = "none found"
        print(PREFIX .. "|cffff4040Could not find the right-click menu system. Use /pn instead.|r")
    end
end

-------------------------------------------------------------------------------
-- Tooltip
-------------------------------------------------------------------------------
-- Guards against adding the line twice when both hook types fire.
local function TooltipHasNote(tooltip)
    local tipName = tooltip.GetName and tooltip:GetName()
    if not tipName then return false end
    for i = 1, tooltip:NumLines() do
        local fs = _G[tipName .. "TextLeft" .. i]
        local t = fs and fs:GetText()
        if t and t:find(NOTE_LABEL, 1, true) == 1 then return true end
    end
    return false
end

local function AddNoteToTooltip(tooltip, data)
    if not PN.db or not PN.db.settings.showTooltip then return end
    if not tooltip or (tooltip.IsForbidden and tooltip:IsForbidden()) or not tooltip.GetUnit then return end

    local name, class
    local _, unit = tooltip:GetUnit()
    if unit then
        if not UnitIsPlayer(unit) then return end
        name, class = NameFromUnit(unit), ClassFromUnit(unit)
    elseif type(data) == "table" and type(data.guid) == "string" and data.guid:find("^Player%-") and GetPlayerInfoByGUID then
        local _, cls, _, _, _, n, second = GetPlayerInfoByGUID(data.guid)
        if type(n) == "string" and type(second) == "string" and second ~= ""
            and second ~= (GetRealmName and GetRealmName())
            and second ~= (GetNormalizedRealmName and GetNormalizedRealmName()) then
            n = n .. " " .. second        -- Forever: surname, not realm
        end
        name, class = CleanName(n), cls
    end
    if not name then return end

    PN:RepairFirstNameNote(name, class)
    local entry = PN:GetNote(name)
    if not entry or TooltipHasNote(tooltip) then return end

    -- Keep the stored spelling and class in sync with what the game reports
    entry.name = name
    if class then entry.class = class end

    -- "Note: Good Tank - first 50 characters..." (limit applies to the written note)
    local text = Trim((entry.text:gsub("%s+", " ")))
    if text ~= "" then text = ForDisplay(Truncate(text, PN.db.settings.tooltipLimit)) end
    local quick = PN:QuickNoteText(entry)
    local line = NOTE_LABEL .. (quick or "")
    if quick and text ~= "" then line = line .. "  |cff9c8d70-|r  " end
    tooltip:AddLine(line .. text, 1, 1, 1, true)
    tooltip:Show()
end

function PN:HookTooltips()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
        and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
            pcall(AddNoteToTooltip, tooltip, data)
        end)
    end
    -- Older clients: OnTooltipSetUnit (pcall because newer clients removed it)
    pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", function(tooltip)
        pcall(AddNoteToTooltip, tooltip)
    end)
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
SLASH_PLAYERNOTES1 = "/pn"
SLASH_PLAYERNOTES2 = "/playernotes"
SlashCmdList["PLAYERNOTES"] = function(msg)
    msg = Trim(msg)
    local lower = msg:lower()

    if lower == "" or lower == "options" or lower == "config" then
        PN:ToggleOptions()
    elseif lower == "help" then
        print(PREFIX .. "commands:")
        print("  /pn                  Open / close the options window")
        print("  /pn target           Read or create a note for your target")
        print("  /pn First Last       Read or create a note for that player")
        print("  /pn tooltip          Turn tooltip notes on/off")
        print("  /pn limit <number>   Set the tooltip character limit (" .. MIN_LIMIT .. "-" .. MAX_LIMIT .. ")")
        print("  Right-click a player for Create Note / Read Note / Edit Note.")
    elseif lower == "target" then
        local name = NameFromUnit("target")
        if not name then
            print(PREFIX .. "Target a player first.")
        else
            local class = ClassFromUnit("target")
            PN:RepairFirstNameNote(name, class)
            PN:ShowNote(name, "read", class)
        end
    elseif lower == "tooltip" then
        PN:SetTooltipEnabled(not PN.db.settings.showTooltip)
        print(PREFIX .. "Tooltip notes " .. (PN.db.settings.showTooltip and "|cff66ff66on|r" or "|cffff4040off|r") .. ".")
    elseif lower:match("^limit%s*") and not lower:match("^limit%S") then
        local n = tonumber(lower:match("^limit%s+(%d+)"))
        if n then PN:SetTooltipLimit(n) end
        print(PREFIX .. "Tooltip character limit: " .. PN.db.settings.tooltipLimit .. ".")
    elseif lower == "debug" then
        print(PREFIX .. "v" .. VERSION .. "  •  notes: " .. PN:CountNotes()
            .. "  •  menus: " .. tostring(PN.menuSystem)
            .. "  •  tooltip hook: " .. ((TooltipDataProcessor and "TooltipDataProcessor") or "OnTooltipSetUnit"))
    else
        PN:ShowNote(msg, "read")
    end
end

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------
local function InitDB()
    PlayerNotesDB = type(PlayerNotesDB) == "table" and PlayerNotesDB or {}
    local db = PlayerNotesDB
    db.notes     = type(db.notes) == "table" and db.notes or {}
    db.settings  = type(db.settings) == "table" and db.settings or {}
    db.positions = type(db.positions) == "table" and db.positions or {}
    for k, v in pairs(DEFAULT_SETTINGS) do
        if db.settings[k] == nil then db.settings[k] = v end
    end
    local lim = tonumber(db.settings.tooltipLimit) or DEFAULT_LIMIT
    db.settings.tooltipLimit = math.max(MIN_LIMIT, math.min(MAX_LIMIT, math.floor(lim)))

    -- Quick Note words: create the defaults, repair anything broken, and make
    -- sure the three defaults of each kind are always present
    db.words = type(db.words) == "table" and db.words or {}
    for _, kind in ipairs(KIND_ORDER) do
        local listKey = KINDS[kind].list
        local list = type(db.words[listKey]) == "table" and db.words[listKey] or {}
        for i = #list, 1, -1 do
            local w = list[i]
            if type(w) ~= "table" or type(w.id) ~= "string" or type(w.text) ~= "string" or w.text == "" then
                table.remove(list, i)
            elseif not ValidHex(w.color) then
                w.color = "ffffff"
            end
        end
        for pos, d in ipairs(DEFAULT_WORDS[kind]) do
            local found
            for _, w in ipairs(list) do if w.id == d.id then found = w; break end end
            if found then
                found.default = true
            else
                table.insert(list, math.min(pos, #list + 1), { id = d.id, text = d.text, color = d.color, default = true })
            end
        end
        db.words[listKey] = list
    end

    -- Drop empty notes and re-key any saved under a non-normalized key
    -- (changes are collected first: a table must not gain keys while it is traversed)
    local remove, move = {}, {}
    for key, e in pairs(db.notes) do
        if type(e) ~= "table" then
            remove[#remove + 1] = key
        else
            if type(e.text) ~= "string" then e.text = "" end
            e.text = Trim(e.text)
            if e.text == "" and e.adj == nil and e.noun == nil then
                remove[#remove + 1] = key
            else
                local proper = NameKey(e.name or key)
                if proper and proper ~= key then move[#move + 1] = { key, proper } end
            end
        end
    end
    for _, key in ipairs(remove) do db.notes[key] = nil end
    for _, m in ipairs(move) do
        if not db.notes[m[2]] then db.notes[m[2]] = db.notes[m[1]] end
        db.notes[m[1]] = nil
    end
    PN.db = db
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        InitDB()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        local ok, err = pcall(function()
            PN:HookMenus()
            PN:HookTooltips()
            PN:RegisterBlizzardOptions()
        end)
        if not ok then print(PREFIX .. "|cffff4040load error:|r " .. tostring(err)) end
        print(("|cff00ff96Player Notes %s|r loaded  —  /pn for options, right-click a player to add a note"):format(VERSION))
    end
end)
