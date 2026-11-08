-- Text and box fitting for UI specs. Pure (no engine calls), so it runs headless.
-- Fit.apply makes every text in a spec tree stay inside a bounded width: texts with spaces get wrap=true, flow texts get
-- a maxWidth (and shrink) from their nearest sized ancestor, single-line texts (absolute-positioned, or inside a box of
-- fixed height) are cut with "..." instead of wrapping into their neighbours. Fit.check reports what is still wrong.
-- The font is JetBrains Mono, whose advance is 0.6 em, so widths are exact without the engine.
local Theme = require("@scripts/config/theme")

local Fit = {}

Fit.advance = 0.6
Fit.lineHeight = 1.3
Fit.ellipsis = "..."

local function flat(style, out)
  out = out or {}
  if style == nil then return out end
  for key, value in pairs(style) do
    if type(key) == "number" then flat(value, out) else out[key] = value end
  end
  return out
end

-- Style values are numbers, "N%" or "auto"; nil when not a plain pixel size.
local function px(value, base: number?): number?
  if type(value) == "number" then return value end
  if type(value) == "string" and base then
    local percent = string.match(value, "^(-?[%d%.]+)%%$")
    if percent then return base * tonumber(percent) / 100 end
  end
  return nil
end

local function pad(s, specific: string, axis: string): number
  return s[specific] or s[axis] or s.padding or 0
end

local function padX(s): number
  return pad(s, "paddingLeft", "paddingX") + pad(s, "paddingRight", "paddingX")
end

local function padY(s): number
  return pad(s, "paddingTop", "paddingY") + pad(s, "paddingBottom", "paddingY")
end

local function marginX(s): number
  local all = s.margin or 0
  local both = s.marginX or all
  return (s.marginLeft or both) + (s.marginRight or both)
end

function Fit.textWidth(str: string, size: number): number
  return (utf8.len(str) or #str) * size * Fit.advance
end

local function maxChars(width: number, size: number): number
  return math.max(1, math.floor((width + 0.01) / (size * Fit.advance)))
end

-- One line cut to `width` pixels, ending in "..." when it was cut.
function Fit.truncate(str: string, size: number, width: number): string
  local n = utf8.len(str) or #str
  local limit = maxChars(width, size)
  if n <= limit then return str end
  local keep = math.max(0, limit - #Fit.ellipsis)
  local cut = utf8.offset(str, keep + 1)
  return (cut and string.sub(str, 1, cut - 1) or str) .. Fit.ellipsis
end

local function truncateLines(str: string, size: number, width: number): string
  if not string.find(str, "\n", 1, true) then return Fit.truncate(str, size, width) end
  local out = {}
  for line in string.gmatch(str .. "\n", "(.-)\n") do out[#out + 1] = Fit.truncate(line, size, width) end
  return table.concat(out, "\n")
end

-- Lines a text takes once wrapped between words at `width`.
function Fit.lineCount(str: string, size: number, width: number): number
  local limit = maxChars(width, size)
  local lines = 0
  for paragraph in string.gmatch(str .. "\n", "(.-)\n") do
    lines += 1
    local used = 0
    for word in string.gmatch(paragraph, "%S+") do
      local len = utf8.len(word) or #word
      if used == 0 then
        used = len
      elseif used + 1 + len <= limit then
        used += 1 + len
      else
        lines += 1
        used = len
      end
    end
  end
  return lines
end

local function hasBreak(str: string): boolean
  return string.find(str, "[ \n]") ~= nil
end

-- Width a node can take: its own width, else what is left of the parent's (minus its offset when absolute).
local function outerWidth(s, ctx): number?
  local outer = px(s.width, ctx.inner)
  if not outer then
    outer = ctx.inner
    if outer then
      if s.position == "absolute" and s.left then outer -= s.left end
      outer -= marginX(s)
    end
  end
  local cap = px(s.maxWidth, ctx.inner)
  if outer and cap then outer = math.min(outer, cap) end
  return outer
end

-- ctx = { inner = width children can use, fixedHeight = the parent has a numeric height }
local function visit(node, ctx)
  local s = flat(node.style)
  local outer = outerWidth(s, ctx)
  local height = px(s.height)

  if node.text and not node.input then
    local t = node.text
    local size = t.size or 24
    local avail = outer and math.max(size, outer - padX(s)) or nil
    local single = s.position == "absolute" or ctx.fixedHeight or height ~= nil
    if t.text ~= "" and avail then
      if single then t.text = truncateLines(t.text, size, avail) end
      if hasBreak(t.text) then t.wrap = true end
      if s.width == nil and s.maxWidth == nil then
        node.style = { { maxWidth = math.floor(avail), shrink = s.shrink == nil and 1 or nil }, node.style }
      end
    elseif hasBreak(t.text) then
      t.wrap = true
    end
  end

  if node.children then
    local inner = outer and (outer - padX(s) - 2 * (s.border or 0)) or ctx.inner
    local child = { inner = inner, fixedHeight = height ~= nil }
    for _, kid in ipairs(node.children) do visit(kid, child) end
  end
end

-- Bounds the text of a whole spec tree to the width it can have; the root is sized by its own style (or the view).
function Fit.apply(root, viewWidth: number)
  visit(root, { inner = viewWidth, fixedHeight = false })
  return root
end

-- The characters of `text` the font has no glyph for (they would draw as "?"), as a list of code points. Invalid UTF-8 counts too.
function Fit.missingGlyphs(text: string): { number }
	local out = {}
	local ok = pcall(function()
		for _, cp in utf8.codes(text) do
			local has = false
			for _, r in ipairs(Theme.font.glyphs) do
				if cp >= r[1] and cp <= r[2] then has = true break end
			end
			if not has and cp ~= 10 then out[#out + 1] = cp end
		end
	end)
	if not ok then out[#out + 1] = 0xFFFD end
	return out
end

-- Problems left in a spec: { "path: what" }. `view` = { w, h }.
function Fit.check(root, view)
  local problems = {}
  local function report(path: string, what: string) problems[#problems + 1] = path .. ": " .. what end

  local function walk(node, ctx, path)
    local s = flat(node.style)
    local outer = outerWidth(s, ctx)
    local height = px(s.height, ctx.height)
    local ox, oy = ctx.x, ctx.y
    if s.position == "absolute" then
      ox += s.left or 0
      oy += s.top or 0
      local w = px(s.width, ctx.inner)
      if ox < -0.5 or oy < -0.5 or (w and ox + w > view.w + 0.5) or (height and oy + height > view.h + 0.5) then
        report(path, ("absolute box leaves the view (x=%s y=%s w=%s h=%s)"):format(ox, oy, tostring(w), tostring(height)))
      end
    end

    local t = node.text
    if t and t.text ~= "" then
      local missing = Fit.missingGlyphs(t.text)
      if #missing > 0 then
        report(path .. " '" .. string.sub(t.text, 1, 24) .. "'", ("no glyph in the UI font for U+%04X"):format(missing[1]))
      end
    end
    if t and not node.input and t.text ~= "" then
      local size = t.size or 24
      local avail = outer and (outer - padX(s)) or nil
      local label = path .. " '" .. string.sub(t.text, 1, 24) .. "'"
      if string.find(t.text, " ", 1, true) and not t.wrap then report(label, "text with spaces is not wrap=true") end
      if not avail then
        report(label, "no bounded width above this text")
      elseif t.wrap then
        for word in string.gmatch(t.text, "%S+") do
          if Fit.textWidth(word, size) > avail + 0.5 then report(label, ("word '%s' is wider than %d px"):format(word, avail)) end
        end
        local room = height or (ctx.fixedHeight and ctx.height) or nil
        if room and Fit.lineCount(t.text, size, avail) * size * Fit.lineHeight > room + 1 then
          report(label, "wrapped text taller than its fixed-height box")
        end
      else
        for line in string.gmatch(t.text .. "\n", "(.-)\n") do
          if Fit.textWidth(line, size) > avail + 0.5 then
            report(label, ("line is %d px, box is %d px"):format(Fit.textWidth(line, size), avail))
          end
        end
      end
    end

    if node.children then
      local inner = outer and (outer - padX(s) - 2 * (s.border or 0)) or ctx.inner
      local child = { inner = inner, x = ox, y = oy, fixedHeight = height ~= nil, height = height and (height - padY(s)) or nil }
      for i, kid in ipairs(node.children) do walk(kid, child, path .. "/" .. i) end
      -- single-line texts placed on the same row must not run into each other
      local runs = {}
      for i, kid in ipairs(node.children) do
        local ks, kt = flat(kid.style), kid.text
        if ks.position == "absolute" and ks.left and ks.top and kt and not kid.input and not kt.wrap and kt.text ~= "" then
          runs[#runs + 1] = { left = ks.left, top = ks.top, right = ks.left + Fit.textWidth(kt.text, kt.size or 24), size = kt.size or 24, label = path .. "/" .. i .. " '" .. string.sub(kt.text, 1, 24) .. "'" }
        end
      end
      table.sort(runs, function(a, b) return a.left < b.left end)
      for i = 1, #runs do
        for j = i + 1, #runs do
          local a, b = runs[i], runs[j]
          if b.left >= a.right - 0.5 then break end
          if math.abs(a.top - b.top) < math.min(a.size, b.size) * 0.5 then report(a.label, "runs into the text at x=" .. b.left .. " (ends at " .. math.floor(a.right) .. ")") end
        end
      end
    end
  end

  walk(root, { inner = view.w, x = 0, y = 0, fixedHeight = false }, "root")
  return problems
end

return Fit
