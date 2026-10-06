--!strict
-- The window half: a palette command (bound to ⌥⌘J) that opens the Jujutsu
-- changes block for the focused pane's directory, or focuses the one already
-- open in this tab.

local KIND = "jj.changes"

local function open_changes(cx: WindowCx)
	local focused = cx.session:focused()
	local here = if focused then cx.session:pane(focused) else nil
	local tab = if focused then cx.session:tab_of(focused) else nil
	for _, pane in cx.session:panes() do
		if pane.block == KIND and pane.tab == tab then
			cx.layout:focus(pane.pane)
			return
		end
	end
	local cwd = if here and here.cwd and here.cwd ~= "" then here.cwd else nil
	if cx:new_block(KIND, if cwd then { cwd } else nil, "beside") == nil then
		cx:toast("error", "Jujutsu is not loaded on this host", "Install the jj plugin where your panes run.")
	end
end

tern.command({
	id = "open",
	title = "Open Jujutsu changes",
	icon = "commit",
	keys = { "alt+cmd+j" },
	run = open_changes,
})
