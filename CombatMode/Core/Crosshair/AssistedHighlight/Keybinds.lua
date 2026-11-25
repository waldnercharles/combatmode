---------------------------------------------------------------------------------------
--  Core/Crosshair/AssistedHighlight/Keybinds.lua — CROSSHAIR — assist keybind resolve
---------------------------------------------------------------------------------------
--  What it does: Resolves click-cast or keyboard keybind glyphs for the Assisted Combat
--  suggestion icon (modifier BLPs + mouse atlases, or abbreviated FrizQT OUTLINE text).
--  Owns action-slot / assisted-slot caches and style apply helpers.
--  Architecture / how it works:
--    • CM.AssistedHighlightKeybinds table: GetClickCastDisplayForSpell,
--      FormatKeybindText / GetFirstBindingKeyForSpell, ApplyClickCast/Keyboard styles,
--      STYLE_CLICKCAST / STYLE_KEYBOARD, preview icon markups.
--    • FormatKeybindText follows LibKeyBound's ToShortKey like the UI action bars
--      (SHIFT-F → SF, CTRL-BUTTON4 → CB4, MOUSEWHEELUP → WU, NUMPAD1 → N1).
--    • ActionSlotToBindingName uses CM.Constants.ClickCastBars actionBase ranges
--      (incl. MultiBar5–7 slots 145–180).
--    • CM.InvalidateAssistedHighlightKeybindCache clears slot maps (EventRouter bars).
--    • Controller: pad keys (PAD1, SHIFT-PADRSHOULDER...) format as the connected pad's button
--      glyphs (GetGamepadGlyphMarkup, Forever's InputIconTextureSetUtility; text elsewhere);
--      while the pad is in use a spell on Forever's controller bars shows its button chord.
--  Does not: Own IconMask chrome, ProcLoop/fade, cast swipe/press/break (sibling modules).
--  Related: Core/Crosshair/AssistedHighlight/Assist.lua, Core/Runtime/EventRouter.lua,
--  Core/ClickCasting/BindingOverrides.lua, Constants/Assets.lua
---------------------------------------------------------------------------------------
local _, CM = ...
local _G = _G

-- WoW API
local C_ActionBar = _G.C_ActionBar
local C_GamepadUI = _G.C_GamepadUI
local C_Texture = _G.C_Texture

-- Lua stdlib
local math = _G.math
local ipairs = _G.ipairs
local pairs = _G.pairs
local pcall = _G.pcall
local select = _G.select
local string = _G.string
local table = _G.table
local tonumber = _G.tonumber
local type = _G.type

local Keybinds = {}
CM.AssistedHighlightKeybinds = Keybinds

local assistedActionSlotSet
local actionSlotCommandMap

local KEYBOARD_KEYBIND_FALLBACK_FONT = "Fonts\\FRIZQT__.TTF"
local KEYBOARD_KEYBIND_FONT_SIZE = 15

Keybinds.STYLE_CLICKCAST = "clickcast"
Keybinds.STYLE_KEYBOARD = "keyboard"
Keybinds.KEYBOARD_OFFSET_X = 13
Keybinds.KEYBOARD_OFFSET_Y = 15

-- LibKeyBound English short labels (same as the UI action bars). The gsub order matches
-- ToShortKey.
local SHORT = {
  ALT = "A",
  CTRL = "C",
  SHIFT = "S",
  META = "M",
  NUMPAD = "N",
  BACKSPACE = "BS",
  CAPSLOCK = "Cp",
  CLEAR = "Cl",
  DELETE = "Del",
  END = "En",
  HOME = "HM",
  INSERT = "Ins",
  MOUSEWHEELDOWN = "WD",
  MOUSEWHEELUP = "WU",
  NUMLOCK = "NL",
  PAGEDOWN = "PD",
  PAGEUP = "PU",
  SCROLLLOCK = "SL",
  SPACEBAR = "Sp",
  SPACE = "Sp",
  TAB = "Tb",
  DOWNARROW = "Dn",
  LEFTARROW = "Lf",
  RIGHTARROW = "Rt",
  UPARROW = "Up",
}

local function AbbreviateKey(key)
  if type(key) ~= "string" or key == "" then
    return nil
  end
  key = key:upper():gsub(" ", "")
  key = key:gsub("ALT%-", SHORT.ALT)
  key = key:gsub("CTRL%-", SHORT.CTRL)
  key = key:gsub("SHIFT%-", SHORT.SHIFT)
  key = key:gsub("META%-", SHORT.META)
  key = key:gsub("NUMPAD", SHORT.NUMPAD)
  key = key:gsub("PLUS", "%+")
  key = key:gsub("MINUS", "%-")
  key = key:gsub("MULTIPLY", "%*")
  key = key:gsub("DIVIDE", "%/")
  key = key:gsub("BACKSPACE", SHORT.BACKSPACE)
  local mouseButtons = _G.NUM_MOUSE_BUTTONS
  if type(mouseButtons) ~= "number" or mouseButtons < 1 then
    mouseButtons = 31
  end
  for i = 1, mouseButtons do
    key = key:gsub("BUTTON" .. i, "B" .. i)
  end
  key = key:gsub("CAPSLOCK", SHORT.CAPSLOCK)
  key = key:gsub("CLEAR", SHORT.CLEAR)
  key = key:gsub("DELETE", SHORT.DELETE)
  key = key:gsub("END", SHORT.END)
  key = key:gsub("HOME", SHORT.HOME)
  key = key:gsub("INSERT", SHORT.INSERT)
  key = key:gsub("MOUSEWHEELDOWN", SHORT.MOUSEWHEELDOWN)
  key = key:gsub("MOUSEWHEELUP", SHORT.MOUSEWHEELUP)
  key = key:gsub("NUMLOCK", SHORT.NUMLOCK)
  key = key:gsub("PAGEDOWN", SHORT.PAGEDOWN)
  key = key:gsub("PAGEUP", SHORT.PAGEUP)
  key = key:gsub("SCROLLLOCK", SHORT.SCROLLLOCK)
  key = key:gsub("SPACEBAR", SHORT.SPACEBAR)
  key = key:gsub("SPACE", SHORT.SPACE)
  key = key:gsub("TAB", SHORT.TAB)
  key = key:gsub("DOWNARROW", SHORT.DOWNARROW)
  key = key:gsub("LEFTARROW", SHORT.LEFTARROW)
  key = key:gsub("RIGHTARROW", SHORT.RIGHTARROW)
  key = key:gsub("UPARROW", SHORT.UPARROW)
  return key
end

-- Controller button glyphs. Forever's Controller Support ships the button prompt art for each
-- device family (Xbox letters, PlayStation shapes, Switch) and picks the set from the connected
-- pad's label style; InputIconTextureSetUtility (Forever only) hands out the atlas for a binding
-- key part (PAD1, PADLTRIGGER, SHIFT = left trigger...). These are client art that must follow
-- the device, so they are drawn by name and never shipped; any part the client can't draw drops
-- the whole key back to text.
local GLYPH_SIZE = 22

local function IsGamepadKeyPart(part)
  return string.find(part, "^PAD") ~= nil or part == "DIRPAD"
end

local function GamepadAtlasForKeyPart(part)
  local util = _G.InputIconTextureSetUtility
  if not (util and util.GetNormalActiveInputIconButtonTexture) then
    return nil
  end
  local name = part
  if util.GetInputIconNameFromBindingKey then
    local ok, names = pcall(util.GetInputIconNameFromBindingKey, part)
    if ok and type(names) == "table" and type(names[1]) == "string" then
      name = names[1]
    end
  end
  -- Indexes the device set's table for the key, which errors for keys it has no art for.
  local ok, atlas = pcall(util.GetNormalActiveInputIconButtonTexture, name)
  if not ok or type(atlas) ~= "string" or atlas == "" then
    return nil
  end
  if C_Texture and C_Texture.GetAtlasInfo and not C_Texture.GetAtlasInfo(atlas) then
    return nil
  end
  return atlas
end

--- Inline glyph markup for a binding key that uses a game pad button ("PAD1",
--- "SHIFT-PADRSHOULDER"...), or nil for keyboard / mouse keys and when the client has no art.
function Keybinds.GetGamepadGlyphMarkup(bindingKey)
  if type(bindingKey) ~= "string" or bindingKey == "" then
    return nil
  end
  local parts = {}
  local anyPad = false
  for part in string.gmatch(bindingKey:upper(), "[^%-]+") do
    parts[#parts + 1] = part
    anyPad = anyPad or IsGamepadKeyPart(part)
  end
  if not anyPad then
    return nil
  end
  local markup = {}
  for i, part in ipairs(parts) do
    local atlas = GamepadAtlasForKeyPart(part)
    if not atlas then
      return nil
    end
    markup[i] = "|A:" .. atlas .. ":" .. GLYPH_SIZE .. ":" .. GLYPH_SIZE .. "|a"
  end
  return table.concat(markup)
end

function Keybinds.FormatKeybindText(bindingKey)
  local glyph = Keybinds.GetGamepadGlyphMarkup(bindingKey)
  if glyph then
    return glyph
  end
  return AbbreviateKey(bindingKey) or bindingKey
end

--- First of GetBindingKey's keys, preferring a game pad key while the pad is in use (a command
--- bound to both a key and a pad button shows the one the player is holding).
function Keybinds.PickBindingKey(...)
  local first = ...
  if not (CM.IsGamepadInputActive and CM.IsGamepadInputActive()) then
    return first
  end
  for i = 1, select("#", ...) do
    local key = select(i, ...)
    if type(key) == "string" then
      for part in string.gmatch(key:upper(), "[^%-]+") do
        if IsGamepadKeyPart(part) then
          return key
        end
      end
    end
  end
  return first
end

-- The mouse art is the shipped 52x69 Blizzard atlas (Assets/atlas). |T file:height:width|t must
-- keep that aspect; modifier BLPs stay square.
local CLICK_MOD_ICON_SIZE = 28
local CLICK_MOUSE_ICON_HEIGHT = 28
local CLICK_MOUSE_ICON_WIDTH = math.floor(CLICK_MOUSE_ICON_HEIGHT * 52 / 69 + 0.5) -- 21
local function MouseIconMarkup(atlasName)
  local info = CM.GetAtlasInfo(atlasName)
  return "|T"
    .. info.file
    .. ":"
    .. CLICK_MOUSE_ICON_HEIGHT
    .. ":"
    .. CLICK_MOUSE_ICON_WIDTH
    .. "|t"
end
local CLICK_ICON_LEFT = MouseIconMarkup("newplayertutorial-icon-mouse-leftbutton")
local CLICK_ICON_RIGHT = MouseIconMarkup("newplayertutorial-icon-mouse-rightbutton")

local function ModifierTextureMarkup(path)
  if not path or path == "" then
    return nil
  end
  return "|T" .. path .. ":" .. CLICK_MOD_ICON_SIZE .. ":" .. CLICK_MOD_ICON_SIZE .. "|t"
end

local MOD_ICON_SHIFT = ModifierTextureMarkup(CM.Constants.ModifierKeyShift)
local MOD_ICON_CTRL = ModifierTextureMarkup(CM.Constants.ModifierKeyCtrl)
local MOD_ICON_ALT = ModifierTextureMarkup(CM.Constants.ModifierKeyAlt)

Keybinds.CLICK_ICON_LEFT = CLICK_ICON_LEFT
Keybinds.CLICK_ICON_RIGHT = CLICK_ICON_RIGHT
Keybinds.MOD_ICON_SHIFT = MOD_ICON_SHIFT
Keybinds.MOD_ICON_CTRL = MOD_ICON_CTRL
Keybinds.MOD_ICON_ALT = MOD_ICON_ALT

local CLICKCAST_BINDING_ORDER = {
  { dbKey = "button1", mod = nil, icon = CLICK_ICON_LEFT },
  { dbKey = "button2", mod = nil, icon = CLICK_ICON_RIGHT },
  { dbKey = "shiftbutton1", mod = MOD_ICON_SHIFT, icon = CLICK_ICON_LEFT },
  { dbKey = "shiftbutton2", mod = MOD_ICON_SHIFT, icon = CLICK_ICON_RIGHT },
  { dbKey = "ctrlbutton1", mod = MOD_ICON_CTRL, icon = CLICK_ICON_LEFT },
  { dbKey = "ctrlbutton2", mod = MOD_ICON_CTRL, icon = CLICK_ICON_RIGHT },
  { dbKey = "altbutton1", mod = MOD_ICON_ALT, icon = CLICK_ICON_LEFT },
  { dbKey = "altbutton2", mod = MOD_ICON_ALT, icon = CLICK_ICON_RIGHT },
}

local function BuildActionSlotCommandMap()
  local map = {}
  local actionButtonUtil = _G.ActionButtonUtil
  local buttonNames = (actionButtonUtil and actionButtonUtil.ActionBarButtonNames)
    or _G.DEFAULT_ACTION_BUTTON_NAMES
  local buttonCount = tonumber(_G.NUM_ACTIONBAR_BUTTONS) or 12

  if type(buttonNames) == "table" then
    for _, prefix in ipairs(buttonNames) do
      for index = 1, buttonCount do
        local button = _G[prefix .. index]
        if button then
          local slotID = tonumber(button.action)
          if not slotID and button.GetAttribute then
            slotID = tonumber(button:GetAttribute("action"))
          end
          if slotID and slotID > 0 and not map[slotID] then
            local command = button.commandName or button.keyBoundTarget
            if not command and button.GetName then
              local name = button:GetName()
              if name and name ~= "" then
                command = "CLICK " .. name .. ":LeftButton"
              end
            end
            if command and command ~= "" then
              map[slotID] = command
            end
          end
        end
      end
    end
  end

  return map
end

function CM.InvalidateAssistedHighlightKeybindCache()
  actionSlotCommandMap = nil
  assistedActionSlotSet = nil
end

local function BuildAssistedActionSlotSet()
  if assistedActionSlotSet then
    return assistedActionSlotSet
  end
  local set = {}
  if
    C_ActionBar
    and C_ActionBar.HasAssistedCombatActionButtons
    and C_ActionBar.FindAssistedCombatActionButtons
    and C_ActionBar.HasAssistedCombatActionButtons()
  then
    local ok, slots = pcall(C_ActionBar.FindAssistedCombatActionButtons)
    slots = ok and slots or nil
    if type(slots) == "table" then
      for _, value in ipairs(slots) do
        local slot = tonumber(value)
        if slot and slot > 0 then
          set[slot] = true
        end
      end
      for key, value in pairs(slots) do
        local slot
        if type(value) == "number" then
          slot = value
        elseif value == true and type(key) == "number" then
          slot = key
        end
        if slot and slot > 0 then
          set[slot] = true
        end
      end
    end
  end
  assistedActionSlotSet = set
  return assistedActionSlotSet
end

--- True when `slot` is a Blizzard Assisted Combat action button (suggestion spell churn).
function CM.IsAssistedCombatActionSlot(slot)
  slot = tonumber(slot)
  if not slot or slot <= 0 then
    return false
  end
  return BuildAssistedActionSlotSet()[slot] == true
end

-- FindSpellActionButtons intermittently returns nothing for a spell that is on the bars (seen
-- flipping between slot and nil several times a second for the same spell), which made the
-- click-cast icon blink. The last good slot is reused for a short grace window.
local SLOT_GRACE_SEC = 1.5
local lastGoodSlot = {} -- spellID -> { slot, time }

local function LookupFirstActionSlotForSpell(spellID)
  if not (spellID and C_ActionBar and C_ActionBar.FindSpellActionButtons) then
    return nil
  end
  local ok, slots = pcall(C_ActionBar.FindSpellActionButtons, spellID)
  slots = ok and slots or nil
  if type(slots) ~= "table" then
    return nil
  end

  local assistedSlots = BuildAssistedActionSlotSet()
  local firstSlot
  local firstSlotIncludingAssisted
  for _, value in ipairs(slots) do
    local slot = tonumber(value)
    if slot and slot > 0 then
      if not firstSlotIncludingAssisted or slot < firstSlotIncludingAssisted then
        firstSlotIncludingAssisted = slot
      end
      if not assistedSlots[slot] and (not firstSlot or slot < firstSlot) then
        firstSlot = slot
      end
    end
  end
  for key, value in pairs(slots) do
    local slot
    if type(value) == "number" then
      slot = value
    elseif value == true and type(key) == "number" then
      slot = key
    end
    if slot and slot > 0 then
      if not firstSlotIncludingAssisted or slot < firstSlotIncludingAssisted then
        firstSlotIncludingAssisted = slot
      end
      if not assistedSlots[slot] and (not firstSlot or slot < firstSlot) then
        firstSlot = slot
      end
    end
  end
  return firstSlot or firstSlotIncludingAssisted
end

local function GetFirstActionSlotForSpell(spellID)
  local slot = LookupFirstActionSlotForSpell(spellID)
  if not spellID then
    return slot
  end
  local now = _G.GetTime()
  if slot then
    local entry = lastGoodSlot[spellID]
    if entry then
      entry[1], entry[2] = slot, now
    else
      lastGoodSlot[spellID] = { slot, now }
    end
    return slot
  end
  local entry = lastGoodSlot[spellID]
  if entry and now - entry[2] <= SLOT_GRACE_SEC then
    return entry[1]
  end
  return nil
end

local function ActionSlotToBindingName(actionSlot)
  local slot = tonumber(actionSlot)
  if not slot or slot < 1 then
    return nil
  end
  local bars = CM.Constants and CM.Constants.ClickCastBars
  if bars then
    for _, bar in ipairs(bars) do
      local base = bar.actionBase
      local count = bar.count or 12
      if base and slot >= base and slot < base + count then
        return bar.bind .. (slot - base + 1)
      end
    end
  end
  return nil
end

function Keybinds.GetClickCastDisplayForSpell(spellID)
  if not (CM.DB and CM.DB.global and CM.DB.char) then
    return nil
  end
  local actionSlot = GetFirstActionSlotForSpell(spellID)
  if not actionSlot then
    return nil
  end
  local bindingName = ActionSlotToBindingName(actionSlot)
  if not bindingName then
    return nil
  end

  local location = CM.GetBindingsLocation and CM.GetBindingsLocation() or "char"
  local bindingsRoot = CM.DB[location]
  local bindings = bindingsRoot and bindingsRoot.bindings
  if type(bindings) ~= "table" then
    return nil
  end

  for _, entry in ipairs(CLICKCAST_BINDING_ORDER) do
    local setting = bindings[entry.dbKey]
    if setting and setting.enabled and setting.value == bindingName then
      if entry.mod then
        return entry.mod .. entry.icon, Keybinds.STYLE_CLICKCAST
      end
      return entry.icon, Keybinds.STYLE_CLICKCAST
    end
  end

  return nil
end

local function GetBindingCommandForActionSlot(slot)
  local actionSlot = tonumber(slot)
  if not actionSlot or actionSlot < 1 then
    return nil
  end

  if not actionSlotCommandMap then
    actionSlotCommandMap = BuildActionSlotCommandMap()
  end
  if actionSlotCommandMap and actionSlotCommandMap[actionSlot] then
    return actionSlotCommandMap[actionSlot]
  end

  return ActionSlotToBindingName(actionSlot)
end

-- Forever's controller action bars (Controller Support UI) keep their actions in storage slots
-- past the normal bars: per page 4 bars x 8 buttons, minus 4 reserved UI buttons on the top bar
-- (page-unit slots 5-8), 3 standard pages (GamepadActionBarBindingUtil in
-- Blizzard_GamepadActionBars). A bar's 8 buttons are GAMEPADACTIONBUTTON1-8 (d-pad left / up /
-- right / down, then face left / top / right / bottom); the top bar needs no modifier, the left
-- bar the left crossbar modifier, the right bar the right one, the bottom bar both.
local GAMEPAD_BUTTON_DEFAULT_KEYS = {
  "PADDLEFT",
  "PADDUP",
  "PADDRIGHT",
  "PADDDOWN",
  "PAD3",
  "PAD4",
  "PAD2",
  "PAD1",
}
local GAMEPAD_FIRST_RESERVED_PAGE_SLOT = 5

local function GamepadBindingKey(command, fallback)
  local key = _G.GetBindingKey and _G.GetBindingKey(command, 1)
  if type(key) == "string" and key ~= "" then
    return key
  end
  return fallback
end

--- Storage slot → (binding key chord, page) on the controller action bars, or nil.
local function GamepadBarKeyForSlot(slot)
  local consts = _G.Constants and _G.Constants.GamepadActionBarConstants
  if not (consts and C_GamepadUI and C_GamepadUI.GetFirstGamepadActionStorageSlotIndex) then
    return nil
  end
  local slotsPerBar = consts.NUM_SLOTS_PER_GAMEPAD_ACTION_BAR or 8
  local reserved = consts.NUM_RESERVED_SLOTS_PER_GAMEPAD_ACTION_BAR_PAGE_UNIT or 4
  local perPageUnit = consts.NUM_PAGEABLE_SLOTS_PER_GAMEPAD_ACTION_BAR_PAGE_UNIT_STANDARD_PAGE or 32
  local pages = consts.NUM_STANDARD_PAGES_PER_GAMEPAD_ACTION_BAR_PAGE_UNIT or 3
  local perPage = perPageUnit - reserved
  local offset = slot - C_GamepadUI.GetFirstGamepadActionStorageSlotIndex()
  if offset < 0 or offset >= perPage * pages then
    return nil
  end
  local page = math.floor(offset / perPage) + 1
  local pageSlot = (offset % perPage) + 1
  if pageSlot >= GAMEPAD_FIRST_RESERVED_PAGE_SLOT then
    pageSlot = pageSlot + reserved
  end
  local bar = math.floor((pageSlot - 1) / slotsPerBar) + 1
  local button = ((pageSlot - 1) % slotsPerBar) + 1
  local key =
    GamepadBindingKey("GAMEPADACTIONBUTTON" .. button, GAMEPAD_BUTTON_DEFAULT_KEYS[button])
  if not key then
    return nil
  end
  local leftMod = (bar == 2 or bar == 4) and GamepadBindingKey("GAMEPADLEFTMOD", "PADLTRIGGER")
  local rightMod = (bar == 3 or bar == 4) and GamepadBindingKey("GAMEPADRIGHTMOD", "PADRTRIGGER")
  if leftMod and rightMod then
    return leftMod .. "-" .. rightMod .. "-" .. key, page
  elseif leftMod or rightMod then
    return (leftMod or rightMod) .. "-" .. key, page
  end
  return key, page
end

--- The spell's button on the controller action bars (lowest page first), as a key chord.
local function GetGamepadBarKeyForSpell(spellID)
  if not (spellID and C_ActionBar and C_ActionBar.FindSpellActionButtons) then
    return nil
  end
  local ok, slots = pcall(C_ActionBar.FindSpellActionButtons, spellID)
  if not ok or type(slots) ~= "table" then
    return nil
  end
  local bestKey, bestPage
  for _, value in pairs(slots) do
    local slot = tonumber(value)
    if slot then
      local key, page = GamepadBarKeyForSlot(slot)
      if key and (not bestPage or page < bestPage) then
        bestKey, bestPage = key, page
      end
    end
  end
  return bestKey
end

function Keybinds.GetFirstBindingKeyForSpell(spellID)
  if CM.IsGamepadInputActive and CM.IsGamepadInputActive() then
    local padKey = GetGamepadBarKeyForSpell(spellID)
    if padKey then
      return padKey
    end
  end
  local slot = GetFirstActionSlotForSpell(spellID)
  if not slot then
    return nil
  end
  local command = GetBindingCommandForActionSlot(slot)
  if not command or not _G.GetBindingKey then
    return nil
  end
  local key1, key2 = _G.GetBindingKey(command)
  return Keybinds.PickBindingKey(key1, key2) or key2
end

-- Cream title color of the options panel (UI.Colors.text, #F1E6D3) for the interactable name.
local TEXT_COLOR = { 0.945, 0.902, 0.827 }
-- Muted description grey (UI.Colors.textDim, #9C968C) for the keybind badge.
local KEY_COLOR = { 0.612, 0.588, 0.549 }

-- Outline + slug + soft 1px shadow, shared by both HUD texts.
local function ApplyOutlineSlug(label, font, size, color)
  CM.ApplyOutlineSlug(label, font, size)
  color = color or TEXT_COLOR
  label:SetTextColor(color[1], color[2], color[3], 1)
end

--- Click-cast label: only inline |T / |A icons, so it keeps the plain font path (no slug).
function Keybinds.ApplyClickCastKeybindStyle(label)
  if not label then
    return
  end
  label:SetTextColor(1, 1, 1, 1)
  label:SetShadowColor(0, 0, 0, 1)
  label:SetShadowOffset(1, -1)
end

--- Interactable name: outline + slug, keeps the label's current font and size.
function Keybinds.ApplyNameStyle(label)
  if not label then
    return
  end
  local font, size = label:GetFont()
  ApplyOutlineSlug(label, font, size, TEXT_COLOR)
end

function Keybinds.ApplyKeyboardKeybindStyle(label)
  if not label then
    return
  end
  -- The client's locale font (Friz is Latin-only, so CJK / Cyrillic key text would be tofu).
  local localeFont = _G.GameFontNormal and _G.GameFontNormal:GetFont()
  if type(localeFont) ~= "string" or localeFont == "" then
    localeFont = KEYBOARD_KEYBIND_FALLBACK_FONT
  end
  ApplyOutlineSlug(label, localeFont, KEYBOARD_KEYBIND_FONT_SIZE, KEY_COLOR)
end
