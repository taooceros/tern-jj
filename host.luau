--!strict

local ui = tern.ui

require("./changes")
require("./loglens")

tern.on("spawn", function(spec: SpawnSpec): SpawnSpec
	spec.env.JJ_PAGER = "cat"
	return spec
end)

-- `jj status` as Tern's native `git status` shows it: the working copy's change as the
-- header, its changed files (and conflicts) in a collapsible section each, every path
-- linked to its file with the change's kind on the right, then the parent commits.

type File = { path: string, from: string?, kind: string, tone: string }
type Commit = { change: string, commit: string, rest: string }

type State = {
	cwd: string?,
	-- Lines read; nil once the output is too large to show natively.
	count: number?,
	files: { File },
	conflicts: { File },
	-- Which list the next indented path lines belong to.
	into: string?,
	clean: boolean,
	working: Commit?,
	parents: { Commit },
	-- Lines the lens doesn't know (hints, warnings), shown as they are.
	notes: { string },
	status: number?,
}

local KINDS: { [string]: { string } } = {
	A = { "added", "success" },
	M = { "modified", "warning" },
	D = { "deleted", "error" },
	R = { "renamed", "warning" },
	C = { "copied", "success" },
}

-- `dir/{old => new}` (a rename or copy) as the new path and the old one.
local function moved(p: string): (string, string?)
	local head, old, new, tail = string.match(p, "^(.-){(.-) => (.-)}(.*)$")
	if head and old and new and tail then
		local function join(mid: string): string
			return (string.gsub(head .. mid .. tail, "//", "/"))
		end
		return join(new), join(old)
	end
	return p, nil
end

-- `xmwukmsw 9f3b1cfb main | message` after the `Working copy (@) :` label.
local function commit_of(text: string): Commit?
	local change, commit, rest = string.match(text, "^%s*(%l+)%s+(%x+)%s*(.*)$")
	if change and commit and rest then
		return { change = change, commit = commit, rest = rest }
	end
	return nil
end

local status: LensDef<State> = {
	open = function(run, _cx)
		return {
			cwd = run.cwd,
			count = 0,
			files = {},
			conflicts = {},
			into = nil,
			clean = false,
			working = nil,
			parents = {},
			notes = {},
			status = nil,
		}
	end,
	line = function(state, line)
		local count = state.count
		if not count then
			return
		end
		if count == 5000 then
			state.count = nil -- Large output stays raw rather than being truncated.
			return
		end
		state.count = count + 1
		local text = line.text
		local wc = string.match(text, "^Working copy%s+%(@%)%s*:(.*)$")
		local parent = string.match(text, "^Parent commit %(@%-%)%s*:(.*)$")
		local kind, path = string.match(text, "^([AMDRC]) (.+)$")
		if text == "Working copy changes:" then
			state.into = "files"
		elseif text == "The working copy has no changes." then
			state.clean = true
		elseif string.find(text, "^There are unresolved conflicts at these paths:") then
			state.into = "conflicts"
		elseif wc then
			state.working = commit_of(wc)
			state.into = nil
		elseif parent then
			local c = commit_of(parent)
			if c then
				table.insert(state.parents, c)
			end
			state.into = nil
		elseif state.into == "files" and kind and path then
			local k = KINDS[kind]
			local new, old = moved(path)
			table.insert(state.files, { path = new, from = old, kind = k[1], tone = k[2] })
		elseif state.into == "conflicts" and string.match(text, "^%S") then
			-- `path    2-sided conflict`
			local p, what = string.match(text, "^(.-)%s%s+(.*conflict.*)$")
			table.insert(state.conflicts, { path = p or text, kind = what or "conflict", tone = "error" })
		elseif text ~= "" then
			state.into = nil
			table.insert(state.notes, text)
		end
	end,
	finish = function(state, code)
		state.status = code
	end,
	view = function(state)
		local working = state.working
		if state.status ~= 0 or not state.count or not working then
			return nil
		end
		local parts: { Node } = {
			ui.row({
				ui.node("icon", { name = "commit" }),
				ui.text({
					ui.span(working.change, "accent strong"),
					" ",
					ui.span(working.commit, "info"),
					" ",
					ui.span(working.rest, if string.find(working.rest, "^%(") then "muted" else nil),
				}),
			}),
		}
		local function section(title: string, files: { File })
			if #files == 0 then
				return
			end
			local rows: { Node } = {}
			for _, f in files do
				local kind: { Span | string } = {}
				if f.from then
					table.insert(kind, ui.span("from " .. f.from .. "  ", "muted"))
				end
				table.insert(kind, ui.span(f.kind, f.tone))
				table.insert(rows, ui.el("div", { class = "jj-sr" }, {
					ui.text({ ui.path(f.path, state.cwd) }),
					ui.text(kind),
				}))
			end
			table.insert(parts, ui.section({ ui.span(title, "strong"), "  ", ui.span(tostring(#files), "muted") }, rows))
		end
		section("Conflicts", state.conflicts)
		section("Working copy changes", state.files)
		if state.clean then
			table.insert(parts, ui.text({ ui.span("The working copy has no changes.", "success") }))
		end
		for _, p in state.parents do
			table.insert(parts, ui.text({
				ui.span("Parent  ", "muted"),
				ui.span(p.change, "accent"),
				" ",
				ui.span(p.commit, "info"),
				" ",
				p.rest,
			}))
		end
		for _, n in state.notes do
			table.insert(parts, ui.text({ ui.span(n, "muted") }))
		end
		return ui.col(parts)
	end,
}

tern.lens.define("status", status)
