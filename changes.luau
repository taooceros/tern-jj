--!strict
-- The `changes` block: every visible change in the repository (`all()`, up to `LIMIT`) as a
-- native commit graph, the selected change's summary in the dock, its diff in a
-- sheet, and a few one-key operations. Every operation is a plain `jj`
-- command, so `u` (jj undo) reverts any of them.
--
-- Keys: ↑/↓ (or k/j) move, g/G first/last, @ working copy, Enter (or d) show
-- the diff, Esc close it, n new change on the selected one, e edit it, u undo,
-- r refresh.

local ui = tern.ui
local graph = require("./graph")
local avatars = require("./avatars")

local LIMIT = 200
-- Every visible change, not just jj's default log revset (mutable changes and trunk): the
-- whole history, as in Tern's Git block, newest first.
local REVSET = "all()"
local SEP = "\x1f"
local REC = "\x1e"
local ROW_ID = "main.graph."
local MAX_DIFF_BYTES = 512 * 1024
local SUMMARY_FILES = 6

-- jj draws the graph; each change's record follows its node glyph after \x1e,
-- with fields joined by \x1f, so descriptions and names never need escaping.
local LOG_TEMPLATE = '"\\x1e" ++ '
	.. table.concat({
		"commit_id",
		"change_id.shortest(8).prefix()",
		"change_id.shortest(8).rest()",
		"commit_id.short(8)",
		"description.first_line()",
		"author.name()",
		"committer.timestamp().ago()",
		"local_bookmarks.map(|b| b.name()).join(\" \")",
		"concat(if(current_working_copy, \"@\"), if(empty, \"e\"), if(conflict, \"c\"), if(immutable, \"i\"), if(divergent, \"d\"))",
		"tags.map(|t| t.name()).join(\" \")",
		"if(!root, committer.timestamp().local().format(\"%b %-d\"))",
		"committer.timestamp().local().format(\"%Y-%m-%d %H:%M\")",
		-- Only the working copy pays for a diff stat: files, lines added, removed.
		"if(current_working_copy, self.diff().files().len() ++ \" \" ++ self.diff().stat().total_added() ++ \" \" ++ self.diff().stat().total_removed())",
		"author.email()",
		-- Co-authors from `Co-authored-by: Name <email>` trailers, and the authors of the
		-- parents a merge brings in, each `name\x1cemail`, joined by \x1d.
		'trailers.filter(|t| t.key().lower() == "co-authored-by").map(|t| t.value()).join("\\x1d")',
		'parents.map(|p| p.author().name() ++ "\\x1c" ++ p.author().email()).join("\\x1d")',
	}, ' ++ "\\x1f" ++ ')
	.. ' ++ "\\n"'

-- `jj` by name first, then where package managers put it: the daemon may run
-- with a PATH that lacks those directories.
local function candidates(): { string }
	local home = tern.getenv("HOME") or ""
	return {
		"jj",
		"/opt/homebrew/bin/jj",
		"/usr/local/bin/jj",
		"/opt/zerobrew/bin/jj",
		home .. "/.cargo/bin/jj",
		home .. "/.local/bin/jj",
		home .. "/.nix-profile/bin/jj",
		"/home/linuxbrew/.linuxbrew/bin/jj",
		"/usr/bin/jj",
	}
end

local found: string? = nil

-- Runs `jj args…` in `cwd`; returns the spawn error when no jj starts.
local function jj(args: { string }, cwd: string?, done: (ProcessResult) -> ()): string?
	local last = "jj is not on this machine's PATH"
	local list: { string } = if found then { found } else candidates()
	for _, bin in list do
		if bin == "jj" or bin == found or tern.fs.exists(bin) then
			local argv: { string } = { bin, "--color=never", "--no-pager" }
			for _, a in args do
				table.insert(argv, a)
			end
			local opts: ProcessOptions = {
				cwd = cwd,
				timeout_ms = 30000,
				-- Nothing the block runs may wait for an editor or a credential prompt.
				env = { JJ_EDITOR = "true", GIT_TERMINAL_PROMPT = "0" },
			}
			local ok, err = pcall(function()
				tern.process.run(argv, opts, function(result: ProcessResult, _)
					done(result)
				end)
			end)
			if ok then
				found = bin
				return nil
			end
			last = tostring(err)
		end
	end
	return last
end

type Person = { name: string, email: string }

-- The change's people (see `Change.people`) from the author and the template's co-author
-- and parent fields.
local function people_of(name: string, email: string, coauthors: string, parents: string): { Person }
	local people: { Person } = {}
	local seen: { [string]: boolean } = {}
	local function add(n: string, e: string)
		n, e = (string.gsub(n, "^%s+", "")), (string.gsub(e, "^%s+", ""))
		n, e = (string.gsub(n, "%s+$", "")), (string.gsub(e, "%s+$", ""))
		local key = string.lower(if e ~= "" then e else n)
		if key ~= "" and not seen[key] then
			seen[key] = true
			table.insert(people, { name = n, email = e })
		end
	end
	add(name, email)
	for _, value in string.split(coauthors, "\x1d") do
		local n, e = string.match(value, "^(.-)%s*<([^>]*)>%s*$")
		if n and e then
			add(n, e)
		elseif value ~= "" then
			add(value, "")
		end
	end
	local list = string.split(parents, "\x1d")
	for n = 2, #list do
		local pn, pe = string.match(list[n], "^(.-)\x1c(.*)$")
		if pn and pe then
			add(pn, pe)
		end
	end
	return people
end

type Change = {
	commit: string,
	prefix: string,
	rest: string,
	short: string,
	description: string,
	author: string,
	-- Everyone who wrote the change: its author, its co-authors, and the authors of the
	-- parents a merge brings in (all but the first), each once.
	people: { Person },
	-- Their names, joined: the author alone for a change by one person.
	names: string,
	ago: string,
	bookmarks: string,
	flags: string,
	tags: string,
	date: string,
	time: string,
	-- The working copy's `files added removed`, else "".
	stat: string,
	email: string,
}

-- A graph row: a change, an edge row (`├─╮`) or elided revisions (`~`).
type Row = graph.GraphRow & { change: Change?, elided: boolean }

type FileDiff = {
	path: string,
	old: string?,
	kind: string,
	adds: number,
	dels: number,
	hunks: boolean,
	binary: boolean,
	text: string,
}

type Detail = { files: { FileDiff }?, error: string? }

type State = {
	cx: BlockCx,
	cwd: string?,
	root: string?,
	changes: { Change }?,
	rows: { Row },
	cursor: string?,
	details: { [string]: Detail },
	diff: boolean,
	loading: boolean,
	-- Blob ids of the authors' GitHub avatars by lowercased email; "" while loading or none.
	photos: { [string]: string },
	busy: string?,
	notice: { tone: string, text: string }?,
	problem: string?,
}

local running: { [number]: State } = {}

local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	running[state.cx.pane] = nil
	return false
end

local function first_line(text: string): string
	return string.match(text, "^%s*([^\n]*)") or ""
end

local function has(change: Change, flag: string): boolean
	return string.find(change.flags, flag, 1, true) ~= nil
end

local function kind_of(change: Change): string
	return if has(change, "@") then "wc"
		elseif has(change, "c") then "conflict"
		elseif has(change, "i") then "immutable"
		else "node"
end

-- The graph rows and changes of `jj log -T LOG_TEMPLATE` output.
local function parse_log(stdout: string): ({ Row }, { Change })
	local rows: { Row } = {}
	local changes: { Change } = {}
	for line in string.gmatch(stdout, "([^\n]*)\n?") do
		local at = string.find(line, REC, 1, true)
		local prefix = if at then string.sub(line, 1, at - 1) else line
		local rest = if at then string.sub(line, at + 1) else ""
		local elided = not at and string.find(line, "(elided revisions)", 1, true) ~= nil
		if elided then
			prefix = string.sub(line, 1, (string.find(line, "(elided revisions)", 1, true) :: number) - 1)
		end
		local cells = graph.cells(prefix)
		if at then
			local f = string.split(rest, SEP)
			if #f >= 16 then
				local people = people_of(f[6], f[14], f[15], f[16])
				local names: { string } = {}
				for _, p in people do
					table.insert(names, if p.name ~= "" then p.name else p.email)
				end
				local change: Change = {
					commit = f[1],
					prefix = f[2],
					rest = f[3],
					short = f[4],
					description = f[5],
					author = f[6],
					people = people,
					names = table.concat(names, ", "),
					ago = f[7],
					bookmarks = f[8],
					flags = f[9],
					tags = f[10],
					date = f[11],
					time = f[12],
					stat = f[13],
					email = f[14],
				}
				local root = change.date == ""
				table.insert(changes, change)
				local who = if change.author ~= "" then change.author else change.email
				table.insert(rows, {
					cells = cells,
					kind = kind_of(change),
					-- The whole team: a change by the same people as the one above is a dot.
					author = if root then nil else change.names,
					label = if root or who == "" then nil else graph.initials(who),
					avatar = if root then nil else graph.avatar(who),
					connect = change.bookmarks ~= "" or change.tags ~= "",
					change = change,
					elided = false,
				})
			end
		elseif #cells > 0 then
			table.insert(rows, { cells = cells, kind = nil, change = nil, elided = elided })
		end
	end
	graph.layout(rows)
	return rows, changes
end

-- Splits `jj diff --git` output into one entry per file.
local function split_diff(text: string): { FileDiff }
	local files: { FileDiff } = {}
	local current: FileDiff? = nil
	local lines: { string } = {}
	local in_hunk = false
	local function close()
		if current then
			current.text = table.concat(lines, "\n")
			table.insert(files, current)
		end
	end
	for line in string.gmatch(text, "([^\n]*)\n?") do
		local header = string.match(line, "^diff %-%-git (.*)$")
		if header then
			close()
			-- `a/P b/P`: without a rename both halves are the same path.
			local half = (#header - 5) // 2
			local path = if half > 0 then string.sub(header, 3, 2 + half) else header
			current = { path = path, kind = "M", adds = 0, dels = 0, hunks = false, binary = false, text = "" }
			lines = { line }
			in_hunk = false
		elseif current then
			table.insert(lines, line)
			if string.sub(line, 1, 2) == "@@" then
				in_hunk = true
				current.hunks = true
			elseif in_hunk and string.sub(line, 1, 1) == "+" then
				current.adds += 1
			elseif in_hunk and string.sub(line, 1, 1) == "-" then
				current.dels += 1
			elseif not in_hunk then
				if string.match(line, "^new file mode") then
					current.kind = "A"
				elseif string.match(line, "^deleted file mode") then
					current.kind = "D"
				elseif string.match(line, "^rename from ") then
					current.old = string.sub(line, 13)
				elseif string.match(line, "^rename to ") then
					current.kind = "R"
					current.path = string.sub(line, 11)
				elseif string.match(line, "^Binary files ") or line == "GIT binary patch" then
					current.binary = true
				elseif string.match(line, "^%+%+%+ b/") then
					current.path = string.sub(line, 7)
				end
			end
		end
	end
	close()
	return files
end

local function index_of(state: State): number
	local changes: { Change } = state.changes or {}
	for i, c in changes do
		if c.commit == state.cursor then
			return i
		end
	end
	return 0
end

local function selected(state: State): Change?
	local changes = state.changes
	return if changes then changes[index_of(state)] else nil
end

-- Loads the selected change's diff once; commit ids name immutable content.
local function load_detail(state: State)
	local change = selected(state)
	if not change or state.details[change.commit] then
		return
	end
	local commit = change.commit
	state.details[commit] = {}
	local spawn_error = jj({ "diff", "--git", "--ignore-working-copy", "-r", commit }, state.root, function(result)
		if not alive(state) then
			return
		end
		if result.status ~= 0 then
			state.details[commit] = { error = first_line(result.stderr) }
		elseif #result.stdout > MAX_DIFF_BYTES then
			state.details[commit] = { error = "The diff is too large to show here; run jj show " .. commit }
		else
			state.details[commit] = { files = split_diff(result.stdout) }
		end
		state.cx:render()
	end)
	if spawn_error then
		state.details[commit] = { error = spawn_error }
	end
end

-- Asks for the GitHub avatar of everyone not seen yet; each one that arrives is sent to the
-- block as a blob and redraws it.
local function load_photos(state: State)
	for _, c in state.changes or {} do
		for _, p in c.people do
			local email = string.lower(p.email)
			if email ~= "" and state.photos[email] == nil then
				state.photos[email] = ""
				avatars.load(email, function(image)
					if alive(state) then
						state.photos[email] = state.cx:blob(image.bytes, image.mime)
						state.cx:render()
					end
				end)
			end
		end
	end
end

-- A person's GitHub avatar blob, when it has arrived.
local function photo_of(state: State, p: Person): string?
	local photo = if p.email ~= "" then state.photos[string.lower(p.email)] else nil
	return if photo ~= "" then photo else nil
end

-- Reloads the list, keeping the cursor on the same commit when it still exists,
-- else on the working copy.
local function refresh(state: State)
	if not alive(state) or state.loading then
		return
	end
	state.loading = true
	local function load_log()
		local args = { "log", "-r", REVSET, "--config", "ui.graph.style=curved", "--limit", tostring(LIMIT), "-T", LOG_TEMPLATE }
		local spawn_error = jj(args, state.root, function(result)
			if not alive(state) then
				return
			end
			state.loading = false
			if result.status ~= 0 then
				state.problem = first_line(result.stderr)
			else
				local rows, changes = parse_log(result.stdout)
				state.rows, state.changes, state.problem = rows, changes, nil
				if index_of(state) == 0 then
					state.cursor = nil
					for _, c in changes do
						if has(c, "@") then
							state.cursor = c.commit
						end
					end
					state.cursor = state.cursor or (if changes[1] then changes[1].commit else nil)
				end
				load_detail(state)
				load_photos(state)
			end
			state.cx:render()
		end)
		if spawn_error then
			state.loading = false
			state.problem = spawn_error
		end
	end
	if state.root then
		load_log()
		return
	end
	local spawn_error = jj({ "root" }, state.cwd, function(result)
		if not alive(state) then
			return
		end
		if result.status ~= 0 then
			state.loading = false
			state.problem = first_line(result.stderr)
			state.cx:render()
			return
		end
		state.root = first_line(result.stdout)
		load_log()
	end)
	if spawn_error then
		state.loading = false
		state.problem = spawn_error
	end
end

-- Runs one jj operation, reports it in the dock, then reloads.
local function operate(state: State, label: string, args: { string })
	if state.busy or not state.root then
		return
	end
	state.busy = label
	local spawn_error = jj(args, state.root, function(result)
		if not alive(state) then
			return
		end
		state.busy = nil
		if result.status == 0 then
			-- jj reports what it did on stderr ("Working copy now at: …").
			local said = first_line(result.stderr)
			state.notice = { tone = "success", text = if said ~= "" then said else label .. " done" }
		else
			state.notice = { tone = "error", text = first_line(result.stderr) }
			state.cx:toast("error", "jj " .. label .. " failed", first_line(result.stderr))
		end
		-- The working copy commit is rewritten by most operations: follow @.
		state.cursor = nil
		refresh(state)
		state.cx:render()
	end)
	if spawn_error then
		state.busy = nil
		state.notice = { tone = "error", text = spawn_error }
	end
end

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function text(spans: { Span | string }, props: { [string]: any }): Node
	local node = ui.text(spans)
	local p: { [string]: any } = node.p or {}
	p.wrap = "none"
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function description_spans(c: Change): { Span | string }
	local spans: { Span | string } = {}
	if has(c, "c") then
		table.insert(spans, ui.span("conflict ", "error"))
	end
	if has(c, "d") then
		table.insert(spans, ui.span("divergent ", "error"))
	end
	if c.description ~= "" then
		table.insert(spans, ui.span(c.description, if has(c, "@") then "strong" elseif has(c, "i") then "muted" else nil))
	elseif c.commit == string.rep("0", #c.commit) then
		table.insert(spans, ui.span("root()", "success"))
	else
		table.insert(spans, ui.span(if has(c, "e") then "(empty)" else "(no description set)", if has(c, "e") then "success" else "warning"))
	end
	return spans
end

-- Column widths, in terminal cells, shared by the rows and the column header. The description
-- column takes the spare width but never less than MSG_W: below that the rows scroll sideways.
local REFS_W = "20ch"
local MSG_W = "22ch"
local DATE_W = "7ch"
local ID_W = "9ch"

local function fixed(w: string): { [string]: any }
	return { min = { w = w }, max = { w = w } }
end

local function el(tag: string, props: { [string]: any }, kids: { Node }?): Node
	return ui.el(tag, props, kids)
end

local function pill(class: string, icon: string?, label: string, title: string?): Node
	local kids: { Node } = {}
	if icon then
		table.insert(kids, ui.node("icon", { name = icon }))
	end
	table.insert(kids, el("span", { text = label }))
	return el("span", { class = "jj-pill " .. class, title = title }, kids)
end

-- The ref column: bookmark and tag pills, then the connector toward the node.
local function refs_view(c: Change): Node
	local kids: { Node } = {}
	local here = has(c, "@")
	for name in string.gmatch(c.bookmarks, "%S+") do
		table.insert(kids, pill("jj-bm" .. (if here then " jj-here" else ""), if here then "check" else "branch", name))
	end
	for name in string.gmatch(c.tags, "%S+") do
		table.insert(kids, pill("jj-tag", "tag", name))
	end
	if #kids > 0 then
		table.insert(kids, el("span", { class = "jj-cline" }))
	end
	local props = fixed(REFS_W)
	props.class = "jj-refs"
	return el("div", props, kids)
end

-- The message column: the lane's color bar, the working copy's pills, then the description.
local function message_view(row: Row, c: Change): Node
	local kids: { Node } = { el("span", { class = "jj-bar jj-l" .. graph.lane(row) }) }
	if has(c, "@") then
		table.insert(kids, pill("jj-wc", "pen", "Working copy"))
		local files, adds, dels = string.match(c.stat, "^(%d+) (%d+) (%d+)$")
		if files and files ~= "0" then
			table.insert(kids, pill("jj-stat", nil, files .. (if files == "1" then " file" else " files")))
			table.insert(kids, text({ ui.span("+" .. (adds :: string), "success num"), ui.span(" −" .. (dels :: string), "error num") }, { basis = "content" }))
		end
	end
	if has(c, "c") then
		table.insert(kids, pill("jj-conf", "warn", "conflict"))
	end
	if has(c, "d") then
		table.insert(kids, pill("jj-conf", "warn", "divergent"))
	end
	local desc: { Span | string } = {}
	if c.description ~= "" then
		table.insert(desc, ui.span(c.description, if has(c, "i") then "muted" else nil))
	elseif c.date == "" then
		table.insert(desc, ui.span("root()", "muted"))
	else
		table.insert(desc, ui.span(if has(c, "e") then "(empty)" else "(no description set)", "dim"))
	end
	table.insert(kids, text(desc, { grow = 1, truncate = "end" }))
	return el("div", { class = "jj-msg", min = { w = MSG_W } }, kids)
end

local function id_view(c: Change): Node
	local props = fixed(ID_W)
	props.class = "jj-id"
	props.title = c.short
	return el("span", props, {
		el("span", { class = "jj-idp", text = c.prefix }),
		el("span", { text = c.rest }),
	})
end

-- One row of the graph, laid out like a row of Tern's Git block.
local function row_view(state: State, row: Row, i: number, width: number): Node
	local c = row.change
	if not c then
		local kids: { Node } = { el("span", fixed(REFS_W)), graph.view(row, width) }
		if row.elided then
			table.insert(kids, text({ ui.span("elided revisions", "dim") }, {}))
		end
		return el("div", { class = "jj-r jj-edge", key = "e" .. i }, kids)
	end
	local date = fixed(DATE_W)
	date.class, date.text, date.title = "jj-date", c.date, if c.time ~= "" then c.time .. " · " .. c.names else nil
	local pick = { click = "sel=" .. c.commit, dblclick = "open=" .. c.commit }
	row.photo = if c.people[1] then photo_of(state, c.people[1]) else nil
	local extra: { graph.Face } = {}
	for n = 2, #c.people do
		local p = c.people[n]
		local who = if p.name ~= "" then p.name else p.email
		table.insert(extra, { name = who, label = graph.initials(who), avatar = graph.avatar(who), photo = photo_of(state, p) })
	end
	row.extra = extra
	row.pick = pick
	return el("div", {
		class = "jj-r jj-pick" .. (if c.commit == state.cursor then " jj-sel" else ""),
		key = c.commit,
		actions = pick,
	}, {
		refs_view(c),
		graph.view(row, width),
		message_view(row, c),
		el("span", date),
		id_view(c),
	})
end

local function button(icon: string, act: string, title: string, busy: boolean?): Node
	return el("span", {
		class = "jj-btn" .. (if busy then " jj-busy" else ""),
		title = title,
		actions = { click = act },
	}, { ui.node("icon", { name = icon }) })
end

-- The toolbar and column header, pinned to the top of the pane. The header scrolls sideways
-- with the rows; the toolbar, capped at the pane's width, stays put.
local function top_view(state: State, width: number): Node
	local where: { Node } = { ui.node("icon", { name = "commit" }) }
	local all: { Change } = state.changes or {}
	for _, c in all do
		if has(c, "@") then
			table.insert(where, el("span", { text = "@ " .. c.prefix .. c.rest }))
		end
	end
	local status: { Span | string } = {}
	if state.busy then
		table.insert(status, ui.span("jj " .. state.busy .. "…", "muted"))
	elseif state.notice then
		table.insert(status, ui.span(state.notice.text, state.notice.tone))
	end
	local bar: { Node } = {
		el("span", { class = "jj-where" }, where),
		button("repeat", "refresh", "Refresh (r)", state.loading),
		button("fetch", "fetch", "Fetch from remotes (jj git fetch)", state.busy == "git fetch"),
		el("span", { class = "jj-sep" }),
		button("undo", "undo", "Undo the last operation (u)"),
		button("redo", "redo", "Redo"),
		el("span", { class = "jj-sep" }),
		button("plus", "new", "New change on the selected one (n)"),
		button("pen", "edit", "Edit the selected change (e)"),
		button("diff", "diff", "Show the selected change's diff (⏎)"),
		el("span", { class = "jj-grow" }),
		text(status, { truncate = "end", max = { w = 0.5 } }),
	}
	local hd = fixed(REFS_W)
	hd.text = "Bookmarks"
	local hg = fixed(graph.span(width))
	hg.text = "Graph"
	local hdate = fixed(DATE_W)
	hdate.text = "Date"
	local hid = fixed(ID_W)
	hid.text = "Change"
	return el("div", { class = "jj-top", key = "top" }, {
		el("div", { class = "jj-bar-row", max = { w = state.cx.cols .. "ch" } }, bar),
		el("div", { class = "jj-r jj-hd" }, {
			el("span", hd),
			el("span", hg),
			el("span", { class = "jj-hd-msg", text = "Description", min = { w = MSG_W } }),
			el("span", hdate),
			el("span", hid),
		}),
	})
end

local function graph_view(state: State): { Node }
	local width = math.max(graph.width(state.rows), 4)
	local rows: { Node } = {}
	for i, row in state.rows do
		if not row.hidden then
			table.insert(rows, row_view(state, row, i, width))
		end
	end
	local changes = state.changes or {}
	local foot: string
	if #changes == 0 then
		foot = "No changes"
	elseif #changes >= LIMIT then
		foot = "Showing the latest " .. LIMIT .. " changes"
	elseif changes[#changes].date == "" then
		foot = "Beginning of history · " .. #changes .. " changes"
	else
		foot = #changes .. " changes"
	end
	table.insert(rows, el("div", { class = "jj-foot", key = "foot", text = foot }))
	return {
		top_view(state, width),
		-- `wrap` keeps every row mounted, so revealing the selection always finds it. The rows
		-- and the footer share the widest row's width, so the pane scrolls them sideways together.
		ui.node("col", { key = "graph", role = "jj.rows", gap = "none", wrap = true }, rows),
	}
end

local KIND_TONE = { A = "success", D = "error", R = "warning", M = "warning" }

local function file_head(state: State, f: FileDiff): { Span | string }
	return {
		ui.span(f.kind .. " ", KIND_TONE[f.kind] or "muted"),
		ui.path(f.path, state.root),
		ui.span("  +" .. f.adds, "success num"),
		ui.span(" −" .. f.dels, "error num"),
	}
end

-- The diff sheet: one collapsible card per file.
local function diff_layer(state: State, change: Change): Node
	local children: { Node } = {}
	local detail = state.details[change.commit]
	if not detail or (not detail.files and not detail.error) then
		table.insert(children, ui.progress(nil, "Loading diff…"))
	elseif detail.error then
		table.insert(children, ui.text({ ui.span(detail.error, "error") }))
	elseif detail.files and #detail.files == 0 then
		table.insert(children, ui.text({ ui.span("This change has no file changes.", "muted") }))
	elseif detail.files then
		for _, f in detail.files do
			-- A rename, mode change or binary file has no hunks: `diff` would draw its headers as lines.
			local body = if f.hunks
				then ui.diff(f.text, f.path)
				else ui.text({
					ui.span(
						if f.binary then "Binary file"
							elseif f.old then "Renamed from " .. f.old
							else "No content changes",
						"muted"
					),
				})
			table.insert(children, with(ui.card(file_head(state, f), { body }), {
				key = "f:" .. f.path,
				collapsible = true,
			}))
		end
	end
	table.insert(children, ui.text({ ui.span("↑↓ next change  esc close", "dim") }))
	local head: { Span | string } = {
		ui.span(change.prefix, "accent strong"),
		ui.span(change.rest .. "  ", "dim"),
		ui.span(change.short .. "  ", "info"),
	}
	for _, s in description_spans(change) do
		table.insert(head, s)
	end
	return ui.col({
		ui.node("overlay", { key = "diff", head = head, size = "full", modal = true }, children),
	})
end

-- The dock: the selected change's summary, then the operations.
local function dock_view(state: State): Node
	local lines: { Node } = {}
	local c = selected(state)
	if c then
		local head: { Span | string } = {
			ui.span(c.prefix, "accent strong"),
			ui.span(c.rest .. "  ", "dim"),
			ui.span(c.short .. "  ", "info"),
		}
		if c.names ~= "" then
			table.insert(head, ui.span(c.names .. " · " .. c.ago .. "  ", "muted"))
		end
		for _, s in description_spans(c) do
			table.insert(head, s)
		end
		table.insert(lines, text(head, { truncate = "end" }))
		local detail = state.details[c.commit]
		local files = detail and detail.files
		if files then
			for n, f in files do
				if n > SUMMARY_FILES then
					table.insert(lines, text({ ui.span("… " .. (#files - SUMMARY_FILES) .. " more files", "dim") }, {}))
					break
				end
				table.insert(lines, text(file_head(state, f), { truncate = "start" }))
			end
		elseif detail and detail.error then
			table.insert(lines, text({ ui.span(detail.error, "error") }, { truncate = "end" }))
		end
	end
	table.insert(lines, ui.text({ ui.span("↑↓ move  ⏎ diff  @ working copy  n new  e edit  u undo  r refresh", "dim") }))
	return ui.col({ ui.el("div", { class = "jj-dock" }, lines) })
end

-- Selects change `n` and scrolls its row into view.
local function move(state: State, to: number)
	local changes = state.changes or {}
	local c = changes[math.clamp(to, 1, math.max(1, #changes))]
	if c then
		state.cursor = c.commit
		load_detail(state)
		state.cx:frame({ { "reveal", ROW_ID .. c.commit, "nearest" } })
	end
end

local function act(state: State, name: string, value: string?): boolean
	local change = selected(state)
	if name == "sel" and value then
		state.cursor = value
		load_detail(state)
	elseif name == "open" and value then
		state.cursor, state.diff = value, true
		load_detail(state)
	elseif name == "diff" then
		state.diff = change ~= nil
	elseif name == "close" then
		state.diff = false
	elseif name == "refresh" then
		refresh(state)
	elseif name == "undo" then
		operate(state, "undo", { "undo" })
	elseif name == "redo" then
		operate(state, "redo", { "redo" })
	elseif name == "fetch" then
		operate(state, "git fetch", { "git", "fetch" })
	elseif name == "new" and change then
		operate(state, "new", { "new", change.commit })
	elseif name == "edit" and change then
		if has(change, "i") then
			state.notice = { tone = "warning", text = change.prefix .. change.rest .. " is immutable" }
		else
			operate(state, "edit", { "edit", change.commit })
		end
	else
		return false
	end
	return true
end

local block: BlockDef<State> = {
	init = function(cx: BlockCx, args: { string }, _saved: any): State
		local state: State = {
			cx = cx,
			cwd = args[1] or cx.cwd,
			root = nil,
			changes = nil,
			rows = {},
			cursor = nil,
			details = {},
			diff = false,
			loading = false,
			photos = {},
			busy = nil,
			notice = nil,
			problem = nil,
		}
		running[cx.pane] = state
		refresh(state)
		return state
	end,

	title = function(state: State): string?
		local root = state.root
		return if root then "jj · " .. (string.match(root, "([^/]+)/?$") or root) else "Jujutsu"
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		if not state.changes then
			if state.problem then
				local card = ui.card({ ui.span("Jujutsu", "strong") }, {
					ui.text({ ui.span(state.problem, "error") }),
					ui.text({ ui.span(state.cwd or "", "muted") }),
					ui.row({ with(ui.badge("Retry", "accent"), { actions = { click = "refresh" } }) }),
				})
				return { main = ui.col({ with(card, { tone = "error" }) }) }
			end
			return { main = ui.col({ ui.progress(nil, "Reading the repository…") }) }
		end
		local change = selected(state)
		return {
			main = ui.col(graph_view(state)),
			dock = dock_view(state),
			layer = if state.diff and change then diff_layer(state, change) else nil,
		}
	end,

	key = function(state: State, key: Key, _cx: BlockCx): boolean?
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local i = index_of(state)
		local k = key.text or key.name
		if key.name == "up" or k == "k" then
			move(state, i - 1)
		elseif key.name == "down" or k == "j" then
			move(state, i + 1)
		elseif key.name == "page_up" then
			move(state, i - 10)
		elseif key.name == "page_down" then
			move(state, i + 10)
		elseif key.name == "home" or k == "g" then
			move(state, 1)
		elseif key.name == "end" or k == "G" then
			move(state, #(state.changes or {}))
		elseif key.name == "enter" or k == "d" or k == "o" then
			act(state, "diff")
		elseif key.name == "escape" or k == "q" then
			if not state.diff then
				return false
			end
			act(state, "close")
		elseif k == "@" then
			local changes: { Change } = state.changes or {}
			for n, c in changes do
				if has(c, "@") then
					move(state, n)
				end
			end
		elseif k == "n" then
			act(state, "new")
		elseif k == "e" then
			act(state, "edit")
		elseif k == "u" then
			act(state, "undo")
		elseif k == "r" then
			act(state, "refresh")
		else
			return false
		end
		return true
	end,

	event = function(state: State, ev: UiEvent, _cx: BlockCx)
		if ev.ev == "action" and type(ev.act) == "string" then
			act(state, ev.act, if type(ev.value) == "string" then ev.value else nil)
		end
	end,
}

tern.block.define("changes", block)

-- jj commands typed in a pane change the repository: reload open blocks.
tern.on("command_finished", function(ev: CommandFinishedEvent, _cx: EffectCx)
	local program = string.match(ev.line, "^%s*%S-([^/%s]+)%f[%s%z]")
	if program ~= "jj" then
		return
	end
	for _, state in running do
		if alive(state) then
			refresh(state)
		end
	end
end)

return {}
