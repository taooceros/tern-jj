--!strict
-- The `changes` block: the repository's changes (jj's default log revset) as a
-- native list, the selected change's files as native diffs, and a few
-- one-key operations. Every operation is a plain `jj` command, so `u` (jj undo)
-- reverts any of them.
--
-- Keys: ↑/↓ (or k/j) move, g/G first/last, @ working copy, n new change on the
-- selected one, e edit it, u undo, r refresh.

local ui = tern.ui

local LIMIT = 200
local SEP = "\x1f"
local REC = "\x1e"
local LIST_ID = "main.changes."
local MAX_DIFF_BYTES = 512 * 1024

-- One record per change; fields are joined by \x1f and records end with \x1e,
-- so descriptions and names never need escaping.
local LOG_TEMPLATE = table.concat({
	"commit_id",
	"change_id.shortest(8).prefix()",
	"change_id.shortest(8).rest()",
	"commit_id.short(8)",
	"description.first_line()",
	"author.name()",
	"committer.timestamp().ago()",
	"local_bookmarks.map(|b| b.name()).join(\" \")",
	"concat(if(current_working_copy, \"@\"), if(empty, \"e\"), if(conflict, \"c\"), if(immutable, \"i\"), if(divergent, \"d\"))",
}, ' ++ "\\x1f" ++ ') .. ' ++ "\\x1e"'

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

type Change = {
	commit: string,
	prefix: string,
	rest: string,
	short: string,
	description: string,
	author: string,
	ago: string,
	bookmarks: string,
	flags: string,
}

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
	cursor: string?,
	details: { [string]: Detail },
	loading: boolean,
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

local function parse_log(stdout: string): { Change }
	local changes: { Change } = {}
	for record in string.gmatch(stdout, "([^" .. REC .. "]+)") do
		local f = string.split(record, SEP)
		if #f >= 9 then
			table.insert(changes, {
				commit = string.match(f[1], "%x+") or f[1],
				prefix = f[2],
				rest = f[3],
				short = f[4],
				description = f[5],
				author = f[6],
				ago = f[7],
				bookmarks = f[8],
				flags = f[9],
			})
		end
	end
	return changes
end

local function has(change: Change, flag: string): boolean
	return string.find(change.flags, flag, 1, true) ~= nil
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

-- Reloads the list, keeping the cursor on the same commit when it still exists,
-- else on the working copy.
local function refresh(state: State)
	if not alive(state) or state.loading then
		return
	end
	state.loading = true
	local function load_log()
		local spawn_error = jj({ "log", "--no-graph", "--limit", tostring(LIMIT), "-T", LOG_TEMPLATE }, state.root, function(result)
			if not alive(state) then
				return
			end
			state.loading = false
			if result.status ~= 0 then
				state.problem = first_line(result.stderr)
			else
				local changes = parse_log(result.stdout)
				state.changes, state.problem = changes, nil
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

local function button(label: string, act: string, tone: string): Node
	local node = ui.badge(label, tone)
	local p: { [string]: any } = node.p or {}
	p.actions = { click = act }
	node.p = p
	return node
end

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function list_view(state: State): Node
	local changes: { Change } = state.changes or {}
	local items: { Item } = {}
	for _, c in changes do
		local label: { Span | string } = {
			ui.span(if has(c, "@") then "@ " else "  ", "accent strong"),
			ui.span(c.prefix, "accent strong"),
			ui.span(c.rest .. "  ", "muted"),
		}
		if c.bookmarks ~= "" then
			table.insert(label, ui.span(c.bookmarks .. "  ", "info"))
		end
		if has(c, "c") then
			table.insert(label, ui.span("conflict  ", "error"))
		end
		if c.description ~= "" then
			table.insert(label, ui.span(c.description, if has(c, "i") then "muted" else nil))
		else
			table.insert(label, ui.span(if has(c, "e") then "(empty)" else "(no description set)", "warning"))
		end
		table.insert(items, {
			label = label,
			value = { ui.span(c.author .. "  ", "muted"), ui.span(c.ago, "muted num") },
			icon = if has(c, "i") then "lock" else "commit",
			tone = if has(c, "c") then "error" elseif has(c, "@") then "accent" else nil,
		})
	end
	local list = ui.list(items)
	local kids = list.c or {}
	for i, c in changes do
		with(kids[i], { key = c.commit })
	end
	return with(list, {
		key = "changes",
		selected = if state.cursor then LIST_ID .. state.cursor else nil,
		empty = { ui.span("No changes in jj's default log revset.", "muted") },
		max = { lines = math.max(5, math.floor(state.cx.rows * 0.35)) },
	})
end

local KIND_TONE = { A = "success", D = "error", R = "warning", M = "warning" }

local function detail_view(state: State): Node?
	local change = selected(state)
	if not change then
		return nil
	end
	local head: { Span | string } = {
		ui.span(change.prefix, "accent strong"),
		ui.span(change.rest .. " ", "muted"),
		ui.span(change.short, "info"),
	}
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
			local fhead: { Span | string } = {
				ui.span(f.kind .. " ", KIND_TONE[f.kind] or "muted"),
				ui.path(f.path, state.root),
				ui.span("  +" .. f.adds, "success num"),
				ui.span(" −" .. f.dels, "error num"),
			}
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
			table.insert(children, with(ui.card(fhead, { body }), {
				key = "f:" .. f.path,
				collapsible = true,
			}))
		end
	end
	return with(ui.section(head, children), { key = "detail" })
end

local function dock_view(state: State): Node
	local lines: { Node } = {}
	local status: { Span | string } = {}
	if state.busy then
		table.insert(status, ui.span("jj " .. state.busy .. "…", "muted"))
	elseif state.notice then
		table.insert(status, ui.span(state.notice.text, state.notice.tone))
	elseif state.root then
		table.insert(status, ui.span(state.root, "muted"))
	end
	table.insert(lines, ui.row({
		button("New", "new", "accent"),
		button("Edit", "edit", "neutral"),
		button("Undo", "undo", "neutral"),
		button("Refresh", "refresh", "neutral"),
		with(ui.text(status), { grow = 1, truncate = "end" }),
	}))
	table.insert(lines, ui.text({ ui.span("↑↓ move  @ working copy  n new  e edit  u undo  r refresh", "dim") }))
	return ui.col({ ui.lines(lines) })
end

local function move(state: State, to: number)
	local changes = state.changes or {}
	local c = changes[math.clamp(to, 1, math.max(1, #changes))]
	if c then
		state.cursor = c.commit
		load_detail(state)
	end
end

local function act(state: State, name: string): boolean
	local change = selected(state)
	if name == "refresh" then
		refresh(state)
	elseif name == "undo" then
		operate(state, "undo", { "undo" })
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
			cursor = nil,
			details = {},
			loading = false,
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
					ui.row({ button("Retry", "refresh", "accent") }),
				})
				return { main = ui.col({ with(card, { tone = "error" }) }) }
			end
			return { main = ui.col({ ui.progress(nil, "Reading the repository…") }) }
		end
		local main: { Node } = { list_view(state) }
		local detail = detail_view(state)
		if detail then
			table.insert(main, detail)
		end
		return { main = ui.col(main), dock = dock_view(state) }
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
			act(state, ev.act)
		elseif ev.ev == "select" and type(ev.item) == "string" then
			state.cursor = string.sub(ev.item, #LIST_ID + 1)
			load_detail(state)
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
