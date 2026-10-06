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

-- `lane` overrides the cell's lane color (by default its column's), for a run between lanes.
-- `turn` is a curve drawn besides the straight `strokes` (set by `layout` where a run goes on
-- past a corner).
export type Cell = { glyph: string, strokes: string, node: boolean, elided: boolean, cross: boolean?, lane: number?, turn: string? }

-- A graph row: its cells; for a change, the node's kind, its author, the avatar's
-- initials and color, and whether a ref pill on the left connects to the node.
-- `dot` (set by `link`/`layout`) draws the node as a filled dot instead of an avatar.
-- `photo` (a blob id, block only) draws the author's picture in the avatar instead of
-- the initials, with `pick` as its actions so a click selects the row rather than zooming.
export type GraphRow = {
	cells: { Cell },
	kind: string?,
	author: string?,
	label: string?,
	avatar: number?,
	connect: boolean?,
	dot: boolean?,
	photo: string?,
	pick: { [string]: string }?,
	-- Set by `link` on a junction row it moved onto a node: draw nothing for it.
	hidden: boolean?,
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

local function blank(row: GraphRow, i: number): boolean
	local c = row.cells[i]
	return c == nil or (c.strokes == "" and not c.node and not c.elided)
end

local function set(row: GraphRow, i: number, strokes: string)
	while #row.cells < i do
		table.insert(row.cells, { glyph = " ", strokes = "", node = false, elided = false })
	end
	row.cells[i].strokes = strokes
end

-- Moves the junction at row `r`, cell `i` (`├─╮`, `├─╯` and mirrored) onto the node it belongs
-- to: a fork's to the merge node right above it, a merge's to the parent node right below it.
-- The branch then runs from the node's side, and the junction row keeps only straight lanes.
local function fold(rows: { GraphRow }, r: number, i: number): boolean
	local row = rows[r]
	local side = string.sub(row.cells[i].strokes, 3)
	local step = if side == "r" then 1 else -1
	local j = i + step
	while row.cells[j] and row.cells[j].strokes == "lr" do
		j += step
	end
	local corner = row.cells[j]
	local into = if side == "r" then "l" else "r"
	if not corner or (corner.strokes ~= into .. "b" and corner.strokes ~= into .. "t") then
		return false
	end
	local v = string.sub(corner.strokes, 2)
	local target = rows[if v == "b" then r - 1 else r + 1]
	if not target or not (target.cells[i] and target.cells[i].node) then
		return false
	end
	for k = i + step, j, step do
		if not blank(target, k) then
			return false
		end
	end
	target.cells[i].strokes ..= side
	for k = i + step, j - step, step do
		set(target, k, "lr")
		row.cells[k].strokes = ""
	end
	set(target, j, corner.strokes)
	corner.strokes = "tb"
	row.cells[i].strokes = "tb"
	return true
end

-- As in Tern's Git block, an avatar only where the author changes from the avatar or dot
-- above, or (with `tips`, by row) at the top of a branch: the rest are dots. The working
-- copy's ring and the root's diamond show no author, so the next one does.
local function faces(rows: { GraphRow }, tips: { [number]: boolean }?)
	local last: string? = nil
	for r, row in rows do
		if row.kind then
			local face = row.label ~= nil and row.kind ~= "wc"
			local tip = tips ~= nil and tips[r] == true
			row.dot = face and row.kind == "node" and row.author == last and not tip
			last = if face then row.author else nil
		end
	end
end

-- Connects node and `~` cells to their neighbours, in place, keeping jj's layout.
function M.link(rows: { GraphRow })
	faces(rows)
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
	-- A junction next to its change's node: the branch leaves or joins at the node itself. A
	-- junction row left with only straight lanes is hidden: the lanes run on through the rows
	-- next to it.
	for r, row in rows do
		local folded = false
		for i, c in row.cells do
			if not c.node and (c.strokes == "tbr" or c.strokes == "tbl") then
				folded = fold(rows, r, i) or folded
			end
		end
		if folded then
			row.hidden = true
			for _, c in row.cells do
				if c.node or c.elided or string.find(c.strokes, "[lr]") then
					row.hidden = nil
				end
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

-- Where a vertex's edges lead, following jj's strokes down from `(r, i)` entered from `from`
-- (`"t"` moving down, `"l"` moving right, `"r"` moving left): every vertex (node or `~`) they
-- reach, in the order found, straight down first. Strokes never lead back up; `┼` and a `─` hop
-- over a lane go straight through.
local function trace(rows: { GraphRow }, r: number, i: number, from: string, out: { string }, seen: { [string]: boolean })
	local row = rows[r]
	local c = row and row.cells[i]
	local key = r .. ":" .. i .. from
	if not c or seen[key] then
		return
	end
	seen[key] = true
	local s = c.strokes
	if c.node or c.elided then
		if from == "t" and not table.find(out, r .. ":" .. i) then
			table.insert(out, r .. ":" .. i)
		end
		return
	end
	local exits: string
	if from == "t" and s == "lr" then
		exits = "b"
	elseif not string.find(s, from, 1, true) then
		return
	elseif s == "tblr" then
		exits = if from == "t" then "b" elseif from == "l" then "r" else "l"
	else
		exits = ""
		for _, d in { "b", "l", "r" } do
			if d ~= from and string.find(s, d, 1, true) then
				exits ..= d
			end
		end
	end
	for d in string.gmatch(exits, ".") do
		if d == "b" then
			trace(rows, r + 1, i, "t", out, seen)
		elseif d == "r" then
			trace(rows, r, i + 1, "l", out, seen)
		else
			trace(rows, r, i - 1, "r", out, seen)
		end
	end
end

local function blank_cell(): Cell
	return { glyph = " ", strokes = "", node = false, elided = false }
end

-- One vertex's place in a row of the native layout: its lane, the lanes ending in it from
-- above, the lanes leaving it for its other parents, and whether a lane runs on above/below it.
type Place = { cell: Cell, lane: number, ends: { number }, news: { number }, top: boolean, bottom: boolean }

-- Lays the graph out as Tern's Git block does, in place: jj's order and edges, but every edge
-- keeps its own lane down to its parent, where it turns into the parent's row, so a parent's
-- children stem from it at different lengths. Only rows with a node or `~` stay; jj's
-- junction rows are hidden.
function M.layout(rows: { GraphRow })
	local edges: { [string]: { string } } = {}
	local parents: { [string]: boolean } = {}
	for r, row in rows do
		for i, c in row.cells do
			if c.node or c.elided then
				local out: { string } = {}
				trace(rows, r + 1, i, "t", out, {})
				edges[r .. ":" .. i] = out
				for _, dest in out do
					parents[dest] = true
				end
			end
		end
	end
	-- A branch's top: a change no change above has as its parent.
	local tips: { [number]: boolean } = {}
	for r, row in rows do
		for i, c in row.cells do
			if c.node and not parents[r .. ":" .. i] then
				tips[r] = true
			end
		end
	end
	faces(rows, tips)
	local slots: { string | false } = {}
	local places: { [number]: { Place } } = {}
	local passing: { [number]: { [number]: boolean } } = {}
	local lanes = 0
	for r, row in rows do
		local above = table.clone(slots)
		local busy: { [number]: boolean } = {}
		local list: { Place } = {}
		for i, c in row.cells do
			if c.node or c.elided then
				local key = r .. ":" .. i
				local incoming: { number } = {}
				for k, target in slots do
					if target == key then
						table.insert(incoming, k)
						slots[k] = false
						busy[k] = true
					end
				end
				local lane = incoming[1]
				if not lane then
					lane = 1
					while slots[lane] or busy[lane] do
						lane += 1
					end
				end
				busy[lane] = true
				local place: Place = { cell = c, lane = lane, ends = {}, news = {}, top = incoming[1] ~= nil, bottom = false }
				for n = 2, #incoming do
					table.insert(place.ends, incoming[n])
				end
				for n, dest in edges[key] do
					local k = lane
					if n == 1 then
						place.bottom = true
					else
						k = lane + 1
						while slots[k] or busy[k] do
							k += 1
						end
						busy[k] = true
						table.insert(place.news, k)
					end
					slots[k] = dest
				end
				table.insert(list, place)
			end
		end
		if #list > 0 then
			places[r] = list
			local through: { [number]: boolean } = {}
			for k, target in above do
				if target and slots[k] == target then
					through[k] = true
				end
			end
			passing[r] = through
		end
		lanes = math.max(lanes, #slots)
	end
	local width = 2 * lanes - 1
	for r, row in rows do
		local list = places[r]
		local cells: { Cell } = {}
		if list then
			for x = 1, width do
				cells[x] = blank_cell()
			end
			for k in passing[r] do
				cells[2 * k - 1].strokes = "tb"
			end
			for _, p in list do
				local at = 2 * p.lane - 1
				local v = p.cell
				cells[at] = { glyph = v.glyph, strokes = (if p.top then "t" else "") .. (if p.bottom then "b" else ""), node = v.node, elided = v.elided }
				-- Each turn's corner, then the run from the vertex to it, colored as its lane.
				local turns: { { lane: number, v: string } } = {}
				for _, k in p.ends do
					table.insert(turns, { lane = k, v = "t" })
				end
				for _, k in p.news do
					table.insert(turns, { lane = k, v = "b" })
				end
				table.sort(turns, function(a, b)
					return math.abs(a.lane - p.lane) > math.abs(b.lane - p.lane)
				end)
				for _, t in turns do
					local side = if t.lane > p.lane then "l" else "r"
					local step = if t.lane > p.lane then 1 else -1
					local corner = cells[2 * t.lane - 1]
					-- A corner a farther lane's run goes on past: the curve joins the run, which
					-- crosses the whole cell (a curve's rounded corner leaves the cell's center
					-- bare, so a run starting there would show a gap).
					if corner.strokes ~= "" then
						corner.turn, corner.strokes = side .. t.v, "lr"
					else
						corner.strokes = side .. t.v
					end
					corner.lane = nil
					cells[at].strokes ..= if side == "l" then "r" else "l"
					for x = at + step, 2 * t.lane - 1 - step, step do
						local c = cells[x]
						if c.strokes == "tb" then
							c.strokes, c.cross = "lr", true
						elseif c.strokes == "" then
							c.strokes = "lr"
						end
						if not c.cross then
							c.lane = t.lane - 1
						end
					end
				end
				local s = cells[at].strokes
				cells[at].strokes = (if string.find(s, "t") then "t" else "") .. (if string.find(s, "b") then "b" else "")
					.. (if string.find(s, "l") then "l" else "") .. (if string.find(s, "r") then "r" else "")
			end
		else
			row.hidden = true
		end
		row.cells = cells
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
	if row.dot then
		return ui.el("span", { class = class .. " jj-dot" })
	end
	if row.avatar then
		class ..= " jj-a" .. row.avatar
	end
	local label = row.label
	if label and kind ~= "wc" then
		local photo = row.photo
		if photo then
			return ui.el("span", { class = class .. " jj-av jj-ph" }, {
				ui.node("image", { blob = photo, alt = row.author, w = 15, h = 15, role = "jj-face", actions = row.pick }),
			})
		end
		return ui.el("span", { class = class .. " jj-av", text = label })
	end
	return ui.el("span", { class = class })
end

-- Where cell `c` turns between a horizontal and a vertical stroke, as the quadrant the curve
-- takes (its horizontal side, then its vertical one: `"lb"` for `╮`), and the strokes still
-- drawn straight. Only corners turn: a junction stays square where its branch leaves the lane,
-- so `├─╮` meets the lane at a right angle and curves once, into the lane it joins.
local function turn(c: Cell): (string?, string)
	if c.turn then
		return c.turn, c.strokes
	end
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
			local class = "jj-gc jj-l" .. (c.lane or (i - 1) // 2) % 6
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
				elseif not row.label and not row.dot and kind ~= "immutable" then
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
