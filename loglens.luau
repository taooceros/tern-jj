--!strict
-- The `log` lens: `jj` and `jj log` in jj's default (compact, graph) format as
-- native rows, one per change: graph, change ID, description, refs, author,
-- time and commit ID. A click copies the change ID. Output in any other
-- format (a custom template, --no-graph, patches, stats) stays raw.

local ui = tern.ui

local MAX_ROWS = 5000
local NBSP = "\u{00A0}"

-- Glyphs jj's curved/square graph styles draw; node glyphs mark a change's line.
local GRAPH: { [string]: boolean } = {}
for _, g in { "│", "├", "┤", "─", "╮", "╯", "╭", "╰", "┼", "┬", "┴", "~", " " } do
	GRAPH[g] = true
end
local NODES: { [string]: string } = {
	["@"] = "success strong",
	["○"] = "muted",
	["◆"] = "info",
	["×"] = "error strong",
	["◉"] = "muted",
	["●"] = "muted",
	["◌"] = "dim",
	["⊕"] = "muted",
}
for g in NODES do
	GRAPH[g] = true
end

-- Arguments whose output is not the compact graph this lens reads.
local DECLINE: { [string]: boolean } = {}
for _, a in { "-T", "--template", "-p", "--patch", "-s", "--summary", "--stat", "--types", "--name-only", "--git", "--color-words", "--tool", "--no-graph", "-G", "--help", "-h" } do
	DECLINE[a] = true
end

export type Change = {
	node: string,
	change: string,
	author: string,
	time: string,
	refs: string,
	commit: string,
	flags: { string },
	empty: boolean,
	description: string?,
}

-- A graph-only row (a fork, a merge, elided revisions) or a change.
export type Row = { graph: string, change: Change?, note: string? }

export type State = { rows: { Row }, failed: boolean, declined: boolean, status: number?, more: number }

-- Splits a line into its graph prefix and its text: the graph is the leading
-- run of graph glyphs and spaces, up to its last double space (jj separates
-- the graph from the text by at least two), so text starting with `@` or `~`
-- stays text.
local function split(text: string): (string, string)
	local last = 0 -- byte index of the end of the last double space
	local prev_space = false
	local stop = #text + 1
	for pos, cp in utf8.codes(text) do
		local ch = utf8.char(cp)
		if not GRAPH[ch] then
			stop = pos
			break
		end
		if ch == " " and prev_space then
			last = pos
		end
		prev_space = ch == " "
	end
	if stop > #text then
		return text, ""
	end
	return string.sub(text, 1, last), string.sub(text, last + 1)
end

local function node_of(graph: string): string?
	for _, cp in utf8.codes(graph) do
		local ch = utf8.char(cp)
		if NODES[ch] then
			return ch
		end
	end
	return nil
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or s
end

-- `xmwukmsw ada@example.com 2026-10-06 10:21:14 main v1 9f3b1cfb (conflict)`
local function parse_change(node: string, text: string): Change?
	local change, rest = string.match(text, "^(%S+)%s+(.*)$")
	if not change or not rest then
		return nil
	end
	local flags: { string } = {}
	while true do
		local before, flag = string.match(rest, "^(.-)%s+%(([%a ]+)%)$")
		if not before or not flag then
			break
		end
		table.insert(flags, 1, flag)
		rest = before
	end
	local commit = string.match(rest, "(%x+)$")
	if not commit or #commit < 6 then
		return nil
	end
	rest = trim(string.sub(rest, 1, #rest - #commit))
	if rest == "root()" then
		return { node = node, change = change, author = "", time = "", refs = "root()", commit = commit, flags = flags, empty = false }
	end
	local author, date, time, refs = string.match(rest, "^(.-)%s*(%d%d%d%d%-%d%d%-%d%d) (%d%d:%d%d):%d%d%s*(.*)$")
	if not author or not date or not time or not refs then
		return nil
	end
	return {
		node = node,
		change = change,
		author = author,
		time = date .. " " .. time,
		refs = refs,
		commit = commit,
		flags = flags,
		empty = false,
	}
end

local function only_lines(graph: string): boolean
	return string.find((string.gsub(graph, "│", "")), "%S") == nil
end

-- Feeds one output line into `state`.
local function feed(state: State, text: string)
	if state.failed then
		return
	end
	local rows = state.rows
	local graph, body = split(text)
	local node = node_of(graph)
	local last = rows[#rows]
	local pending = if last and last.change and last.change.description == nil then last.change else nil
	if #rows == 0 and not node then
		-- Bare `jj` prints a hint (`Hint: Use `jj -h`…`) on stderr before the log.
		return
	elseif node then
		local change = parse_change(node, body)
		if not change then
			state.failed = true
			return
		end
		table.insert(rows, { graph = graph, change = change })
	elseif pending and body ~= "" then
		-- The change's description line: `(empty) (no description set)`.
		local d = body
		if string.sub(d, 1, 8) == "(empty) " then
			pending.empty = true
			d = string.sub(d, 9)
		end
		pending.description = if d == "(no description set)" then "" else d
		if not only_lines(graph) then
			table.insert(rows, { graph = graph })
		end
	elseif body == "" or body == "(elided revisions)" then
		table.insert(rows, { graph = graph, note = if body ~= "" then body else nil })
	else
		state.failed = true
	end
end

local function rtrim(s: string): string
	return (string.gsub(s, "%s+$", ""))
end

local function graph_spans(graph: string, width: number): { Span | string }
	local spans: { Span | string } = {}
	local run = ""
	local n = 0
	for _, cp in utf8.codes(graph) do
		local ch = utf8.char(cp)
		n += 1
		local tone = NODES[ch]
		if tone then
			if run ~= "" then
				table.insert(spans, ui.span(run, "dim"))
				run = ""
			end
			table.insert(spans, ui.span(ch, tone))
		else
			run ..= if ch == " " then NBSP else ch
		end
	end
	run ..= string.rep(NBSP, width - n)
	if run ~= "" then
		table.insert(spans, ui.span(run, "dim"))
	end
	return spans
end

local function text(spans: { Span | string }, props: { [string]: any }?): Node
	local node = ui.text(spans)
	local p: { [string]: any } = node.p or {}
	p.wrap = "none"
	local extra: { [string]: any } = props or {}
	for k, v in extra do
		p[k] = v
	end
	node.p = p
	return node
end

local function view(state: State): Node?
	if state.failed or state.declined or state.status ~= 0 or #state.rows == 0 then
		return nil
	end
	local width, author_w, time_w = 0, 0, 0
	for _, r in state.rows do
		width = math.max(width, utf8.len(rtrim(r.graph)) or 0)
		local c = r.change
		if c then
			author_w = math.max(author_w, utf8.len(c.author) or 0)
			time_w = math.max(time_w, #c.time)
		end
	end
	local lines: { Node } = {}
	for _, r in state.rows do
		local g = text(graph_spans(rtrim(r.graph), width + 1), { basis = "content" })
		local c = r.change
		if not c then
			local kids = { g }
			if r.note then
				table.insert(kids, text({ ui.span(r.note, "dim") }))
			end
			table.insert(lines, ui.node("row", { gap = "none" }, kids))
			continue
		end
		local desc: { Span | string } = {}
		for _, flag in c.flags do
			table.insert(desc, ui.span(flag .. " ", if flag == "conflict" or flag == "divergent" then "error" else "warning"))
		end
		if c.empty then
			table.insert(desc, ui.span("(empty) ", "success"))
		end
		if c.refs == "root()" then
			table.insert(desc, ui.span("root()", "success"))
		elseif c.description == nil or c.description == "" then
			table.insert(desc, ui.span("(no description set)", "warning"))
		else
			table.insert(desc, ui.span(c.description :: string, if c.node == "@" then "strong" else nil))
		end
		local kids: { Node } = {
			g,
			text({ ui.span(c.change, if c.node == "@" then "accent strong" else "accent") }, { basis = "content" }),
			text(desc, { grow = 1, truncate = "end" }),
		}
		if c.refs ~= "" and c.refs ~= "root()" then
			table.insert(kids, text({ ui.span(c.refs, "info strong") }, { basis = "content" }))
		end
		table.insert(kids, text({ ui.span(c.author, "muted") }, { min = { w = author_w .. "ch" } }))
		table.insert(kids, text({ ui.span(c.time, "muted num") }, { min = { w = time_w .. "ch" } }))
		table.insert(kids, text({ ui.span(c.commit, "info") }, { basis = "content" }))
		table.insert(lines, ui.node("row", {
			gap = "md",
			actions = { click = "copy=" .. c.change },
			title = "Click to copy the change ID",
		}, kids))
	end
	if state.more > 0 then
		table.insert(lines, ui.overflow(state.more))
	end
	return ui.card("Jujutsu log", { ui.lines(lines) })
end

local lens: LensDef<State> = {
	open = function(run, _cx)
		local declined = false
		for _, a in run.args do
			local flag = string.match(a, "^(%-%-?[%w-]+)")
			if flag and DECLINE[flag] or string.match(a, "^%-T.") or string.match(a, "^%-%-template=") then
				declined = true
			end
		end
		return { rows = {}, failed = false, declined = declined, status = nil, more = 0 }
	end,
	line = function(state, l)
		if #state.rows >= MAX_ROWS then
			state.more += 1
		else
			feed(state, l.text)
		end
	end,
	finish = function(state, status)
		state.status = status
	end,
	view = view,
	event = function(_state, ev, cx)
		if ev.ev == "action" and ev.act == "copy" and type(ev.value) == "string" then
			cx:copy(ev.value)
			cx:toast("success", "Copied " .. ev.value)
		end
	end,
}

tern.lens.define("log", lens)

return { feed = feed, split = split }
