--!strict
-- Draws jj's commit graph natively. jj lays the graph out (curved style); this
-- module reads each graph character as strokes from the cell's center (up,
-- down, left, right) and draws them with `jj.css`, so lanes stay continuous
-- whatever the row height. Node glyphs and `~` connect to their neighbours:
-- up when the cell above strokes down, down when the cell below strokes up.

local ui = tern.ui

local M = {}

-- Strokes of each line glyph jj's curved and square styles draw.
local STROKES: { [string]: string } = {
	["│"] = "tb",
	["─"] = "lr",
	["├"] = "tbr",
	["┤"] = "tbl",
	["┼"] = "tblr",
	["┬"] = "lrb",
	["┴"] = "lrt",
	["╮"] = "lb",
	["┐"] = "lb",
	["╯"] = "lt",
	["┘"] = "lt",
	["╭"] = "rb",
	["┌"] = "rb",
	["╰"] = "rt",
	["└"] = "rt",
}

-- What a node glyph means when jj drew it (the `jj log` lens has no flags).
local GLYPH_KIND: { [string]: string } = {
	["@"] = "wc",
	["◆"] = "immutable",
	["×"] = "conflict",
	["◌"] = "hidden",
}

export type Cell = { glyph: string, strokes: string, node: boolean, elided: boolean, cross: boolean? }

-- A graph row: its cells; for a change, the node's kind, the avatar's initials
-- and color, and whether a ref pill on the left connects to the node.
export type GraphRow = {
	cells: { Cell },
	kind: string?,
	label: string?,
	avatar: number?,
	connect: boolean?,
}

-- Width of one graph character. jj draws a lane every two characters, so this
-- spaces lanes wide enough for an avatar; `min`/`max` in `ch` are terminal
-- cells, and a fractional count works (a stylesheet's `ch` does not).
local CELL = 1.35

-- `n` graph characters as a `min`/`max` width.
function M.span(n: number): string
	return string.format("%.2fch", n * CELL)
end

-- Initials for an avatar: the first letters of the first two words of a name
-- (or of an email's local part), else its first two letters.
function M.initials(name: string): string
	local base = string.match(name, "^([^@]+)@") or name
	local words: { string } = {}
	for w in string.gmatch(base, "[%w]+") do
		table.insert(words, w)
	end
	if #words >= 2 then
		return string.upper(string.sub(words[1], 1, 1) .. string.sub(words[2], 1, 1))
	elseif words[1] then
		return string.upper(string.sub(words[1], 1, 2))
	end
	return "?"
end

-- A stable avatar color (0–7) for an author: FNV-1a over the name.
function M.avatar(name: string): number
	local h = 2166136261
	for i = 1, #name do
		h = bit32.bxor(h, string.byte(name, i))
		-- h * 16777619 mod 2^32, split so every product stays exact in a double.
		h = ((h % 256) * 16777216 + h * 403) % 4294967296
	end
	return (h // 8) % 8
end

-- The lane (0-based) of the row's node, for coloring the row's message bar.
function M.lane(row: GraphRow): number
	for i, c in row.cells do
		if c.node then
			return ((i - 1) // 2) % 6
		end
	end
	return 0
end

-- The cells of a graph prefix, trailing blanks trimmed.
function M.cells(prefix: string): { Cell }
	local cells: { Cell } = {}
	for _, cp in utf8.codes(prefix) do
		local ch = utf8.char(cp)
		local strokes = STROKES[ch]
		table.insert(cells, {
			glyph = ch,
			strokes = strokes or "",
			node = strokes == nil and ch ~= " " and ch ~= "~",
			elided = ch == "~",
		})
	end
	while #cells > 0 and cells[#cells].glyph == " " do
		table.remove(cells)
	end
	return cells
end

-- The kind of the first node glyph in `cells` (`"node"` for a plain one).
function M.glyph_kind(cells: { Cell }): string?
	for _, c in cells do
		if c.node then
			return GLYPH_KIND[c.glyph] or "node"
		end
	end
	return nil
end

local function strokes_down(row: GraphRow?, i: number): boolean
	local c = row and row.cells[i]
	return c ~= nil and (c.node or string.find(c.strokes, "b", 1, true) ~= nil)
end

local function strokes_up(row: GraphRow?, i: number): boolean
	local c = row and row.cells[i]
	return c ~= nil and (c.node or c.elided or string.find(c.strokes, "t", 1, true) ~= nil)
end

-- Connects node and `~` cells to their neighbours, in place.
function M.link(rows: { GraphRow })
	for r, row in rows do
		for i, c in row.cells do
			if c.node or c.elided then
				local s = ""
				if strokes_down(rows[r - 1], i) then
					s ..= "t"
				end
				if strokes_up(rows[r + 1], i) then
					s ..= "b"
				end
				c.strokes = s
			end
		end
	end
	-- A horizontal hop over a vertical lane: the lane runs through the cell above and below.
	for r, row in rows do
		for i, c in row.cells do
			local hop = string.find(c.strokes, "[lr]") ~= nil and string.find(c.strokes, "[tb]") == nil
			if hop and not c.node and strokes_down(rows[r - 1], i) and strokes_up(rows[r + 1], i) then
				c.cross = true
			end
		end
	end
end

-- The widest row, in cells.
function M.width(rows: { GraphRow }): number
	local w = 0
	for _, row in rows do
		w = math.max(w, #row.cells)
	end
	return w
end

local function spacer(n: number, connector: boolean): Node
	local w = M.span(n)
	return ui.el("span", { class = if connector then "jj-gs jj-cx" else "jj-gs", min = { w = w }, max = { w = w } })
end

-- The node: an avatar with the author's initials for an ordinary change, a
-- ring for the working copy, a diamond for an immutable one.
local function node(row: GraphRow): Node
	local kind = row.kind or "node"
	local class = "jj-n jj-n-" .. kind
	if row.avatar then
		class ..= " jj-a" .. row.avatar
	end
	local label = row.label
	if label and kind ~= "wc" then
		return ui.el("span", { class = class .. " jj-av", text = label })
	end
	return ui.el("span", { class = class })
end

-- Where cell `c` turns between a horizontal and a vertical stroke, as the quadrant the curve
-- takes (its horizontal side, then its vertical one: `"lb"` for `╮`), and the strokes still
-- drawn straight. Only corners turn: a junction stays square where its branch leaves the lane,
-- so `├─╮` meets the lane at a right angle and curves once, into the lane it joins.
local function turn(c: Cell): (string?, string)
	local s = c.strokes
	if s == "lb" or s == "lt" or s == "rb" or s == "rt" then
		return s, ""
	end
	return nil, s
end

-- The graph column of `row`, `width` characters wide.
function M.view(row: GraphRow, width: number): Node
	local kids: { Node } = {}
	local blank = 0
	-- Cells left of the node carry the connector from the row's ref pills.
	local before_node = row.connect == true
	for i, c in row.cells do
		if c.node then
			if blank > 0 then
				table.insert(kids, spacer(blank, before_node))
				blank = 0
			end
			before_node = false
		end
		if c.strokes == "" and not c.node then
			blank += 1
		else
			if blank > 0 then
				table.insert(kids, spacer(blank, before_node))
				blank = 0
			end
			local class = "jj-gc jj-l" .. ((i - 1) // 2) % 6
			local quadrant, straight = turn(c)
			for s in string.gmatch(straight, ".") do
				class ..= " jj-s" .. s
			end
			if c.elided then
				class ..= " jj-el"
			end
			if c.cross then
				class ..= " jj-x"
			end
			if before_node then
				class ..= " jj-cx"
			elseif c.node and row.connect then
				class ..= " jj-cxh"
			end
			local w = M.span(1)
			local inner: { Node }? = nil
			if c.node then
				inner = { node(row) }
				-- The working copy's ring and a plain ring are see-through: the lane stops at them.
				local kind = row.kind or "node"
				if kind == "wc" then
					class ..= " jj-nw"
				elseif not row.label and kind ~= "immutable" then
					class ..= " jj-nr"
				end
			elseif quadrant then
				inner = { ui.el("span", { class = "jj-k jj-k-" .. quadrant }) }
			elseif c.strokes == "tbr" or c.strokes == "tbl" then
				-- Where a branch leaves or joins a lane: a dot on the lane, as in Tern's Git block.
				inner = { ui.el("span", { class = "jj-j" }) }
			end
			table.insert(kids, ui.el("span", { class = class, min = { w = w }, max = { w = w } }, inner))
		end
	end
	blank += width - #row.cells
	if blank > 0 then
		table.insert(kids, spacer(blank, false))
	end
	return ui.el("div", { class = if row.connect then "jj-g jj-gx" else "jj-g" }, kids)
end

return M
