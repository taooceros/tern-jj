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

export type Cell = { glyph: string, strokes: string, node: boolean, elided: boolean }

-- A graph row: its cells, and the node's kind when it holds a change.
export type GraphRow = { cells: { Cell }, kind: string? }

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
end

-- The widest row, in cells.
function M.width(rows: { GraphRow }): number
	local w = 0
	for _, row in rows do
		w = math.max(w, #row.cells)
	end
	return w
end

local function spacer(n: number): Node
	return ui.el("span", { class = "jj-gs", min = { w = n .. "ch" }, max = { w = n .. "ch" } })
end

-- The graph column of `row`, `width` cells wide.
function M.view(row: GraphRow, width: number): Node
	local kids: { Node } = {}
	local blank = 0
	for i, c in row.cells do
		if c.strokes == "" and not c.node then
			blank += 1
		else
			if blank > 0 then
				table.insert(kids, spacer(blank))
				blank = 0
			end
			local class = "jj-gc jj-l" .. ((i - 1) // 2) % 6
			for s in string.gmatch(c.strokes, ".") do
				class ..= " jj-s" .. s
			end
			if c.elided then
				class ..= " jj-el"
			end
			local inner: { Node }? = nil
			if c.node then
				inner = { ui.el("span", { class = "jj-n jj-n-" .. (row.kind or "node") }) }
			end
			-- `min`/`max` in `ch` are terminal cells; a stylesheet's `1ch` is not.
			table.insert(kids, ui.el("span", { class = class, min = { w = "1ch" }, max = { w = "1ch" } }, inner))
		end
	end
	blank += width - #row.cells
	if blank > 0 then
		table.insert(kids, spacer(blank))
	end
	return ui.el("div", { class = "jj-g" }, kids)
end

return M
