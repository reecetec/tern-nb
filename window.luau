--!strict
-- Lets programs outside Tern (agents, scripts) drive notebook blocks through
-- `cx.notebook`, which only window plugins and Carly can reach.
--
-- Transport: a client writes <data>/req/<id>.json, then writes a byte to the
-- doorbell FIFO. A `cat` of the FIFO runs off the UI thread through
-- tern.process.run and exits when the byte arrives, so the window wakes only
-- for requests instead of polling. Each request gets <id>.ack when picked up
-- and <id>.json in <data>/res/ when answered; clients re-ring when no ack
-- arrives, which covers a doorbell swallowed by a reader left over from a reload.

local DATA = tern.plugin.data
local REQ = DATA .. "/req"
local RES = DATA .. "/res"
local BELL = DATA .. "/doorbell"
local READER_PID = DATA .. "/reader.pid"

tern.fs.mkdir(REQ)
tern.fs.mkdir(RES)

-- Writes off the UI thread: answers can carry megabytes of outputs.
local function write_atomic(path: string, text: string)
	tern.process.run(
		{ "/bin/sh", "-c", 'cat > "$1.tmp" && mv "$1.tmp" "$1"', "sh", path },
		{ stdin = text },
		function(result)
			if result.status ~= 0 then
				tern.log.warn("nbbridge: cannot write answer", path, result.stderr)
			end
		end
	)
end

local function answer(id: string, ok: boolean, value: any)
	local body = if ok then { ok = true, result = value } else { ok = false, error = tostring(value) }
	local encoded_ok, text = pcall(tern.json.encode, body)
	if not encoded_ok then
		text = tern.json.encode({ ok = false, error = "cannot encode the answer: " .. tostring(text) })
	end
	write_atomic(RES .. "/" .. id .. ".json", text)
end

local function notebook_path(cx: WindowCx, pane: number): string?
	local ok, read = pcall(function()
		return cx.session:read(pane, { rows = 1, max_chars = 200 })
	end)
	if ok and type(read) == "table" and read.kind == "notebook" then
		return read.path
	end
	return nil
end

local function notebooks(cx: WindowCx): { { [string]: any } }
	local out = tern.json.array()
	for _, p in cx.session:panes() do
		if p.kind == "notebook" then
			local ok, kernel = pcall(function()
				return cx.notebook:kernel_status(p.pane)
			end)
			table.insert(out, {
				pane = p.pane,
				title = p.title,
				path = notebook_path(cx, p.pane) or tern.json.null,
				focused = p.focused == true,
				kernel = if ok then kernel else { status = "unavailable", dead = tostring(kernel) },
			})
		end
	end
	return out
end

-- `nb` is a pane id, an absolute .ipynb path, or nil for the only open notebook.
local function resolve(cx: WindowCx, nb: any): number
	local open = notebooks(cx)
	if type(nb) == "number" then
		for _, n in open do
			if n.pane == nb then
				return nb
			end
		end
		error(`no notebook block {nb} in this window`, 0)
	elseif type(nb) == "string" then
		for _, n in open do
			if n.path == nb then
				return n.pane
			end
		end
		error(`{nb} is not open in a notebook block; open it first`, 0)
	end
	if #open == 1 then
		return open[1].pane
	elseif #open == 0 then
		error("no notebook is open; open one first", 0)
	end
	error("several notebooks are open; name one with --nb", 0)
end

local function find_cell(cells: { NotebookCell }, id: number): NotebookCell?
	for _, c in cells do
		if c.id == id then
			return c
		end
	end
	return nil
end

local function index_of(cells: { NotebookCell }, id: number): number?
	for index, c in cells do
		if c.id == id then
			return index - 1 -- the block's `active` counts from 0
		end
	end
	return nil
end

-- Edits the notebook API lacks (delete, move, change kind, save, interrupt) exist only as view
-- actions on the focused notebook's selected cell. Each step runs in its own timer tick, because
-- a handler that focuses a pane and dispatches in one go overruns the 50 ms hook budget and gets
-- the plugin disabled. The user's focus is restored afterwards.
--   req.cell: cell id to select first (optional); req.actions: view action ids, dispatched in
--   order in one tick, so a double-press action ("notebook.twice.delete") is listed twice.
local function act(cx: WindowCx, id: string, nb: number, req: { [string]: any })
	local before = cx.session:focused()
	local target: number? = nil
	if req.cell ~= nil then
		target = index_of(cx.notebook:cells(nb), req.cell)
		if target == nil then
			error(`no cell {req.cell} in this notebook`, 0)
		end
	end
	local function finish(c: WindowCx, ok: boolean, value: any)
		if before and before ~= nb then
			pcall(function()
				c.layout:focus(before)
			end)
		end
		answer(id, ok, value)
	end
	cx.layout:focus(nb)
	tern.timer(0, function(c1)
		if not c1 then
			return answer(id, false, "the window closed")
		end
		if target ~= nil then
			local read = c1.session:read(nb, { rows = 1, max_chars = 20 })
			local active = if type(read) == "table" then read.active else nil
			if type(active) ~= "number" then
				return finish(c1, false, "the notebook has no selected cell to move from")
			end
			local step = if target > active then "notebook.select_below" else "notebook.select_above"
			for _ = 1, math.abs(target - active) do
				c1:action(step)
			end
		end
		tern.timer(0, function(c2)
			if not c2 then
				return answer(id, false, "the window closed")
			end
			if target ~= nil then
				local read = c2.session:read(nb, { rows = 1, max_chars = 20 })
				if type(read) ~= "table" or read.active ~= target then
					return finish(c2, false, `could not select cell {req.cell}`)
				end
			end
			for _, action in req.actions do
				c2:action(action)
			end
			tern.timer(0, function(c3)
				if not c3 then
					return answer(id, false, "the window closed")
				end
				local read = c3.session:read(nb, { rows = 1, max_chars = 20 })
				finish(c3, true, {
					pane = nb,
					dirty = if type(read) == "table" then read.dirty else tern.json.null,
					cells = c3.notebook:cells(nb),
				})
			end)
		end)
	end)
end

local function handle(cx: WindowCx, id: string, req: { [string]: any })
	local op = req.op
	if op == "list" then
		return answer(id, true, notebooks(cx))
	elseif op == "act" then
		return act(cx, id, resolve(cx, req.nb), req)
	elseif op == "open" then
		for _, n in notebooks(cx) do
			if n.path == req.path then
				return answer(id, true, { pane = n.pane, opened = false })
			end
		end
		return answer(id, true, { pane = cx.notebook:open(req.path), opened = true })
	end

	local nb = resolve(cx, req.nb)
	if op == "cells" then
		answer(id, true, { pane = nb, cells = cx.notebook:cells(nb) })
	elseif op == "kernel" then
		answer(id, true, cx.notebook:kernel_status(nb))
	elseif op == "add" then
		local cell = cx.notebook:add(nb, { kind = req.kind or "code", source = req.source, after = req.after })
		answer(id, true, { pane = nb, cell = cell })
	elseif op == "edit" then
		cx.notebook:edit(nb, req.cell, req.source)
		answer(id, true, { pane = nb, cell = req.cell })
	elseif op == "run" or op == "exec" then
		local opts: { cell: number?, all: boolean? }
		if op == "exec" then
			local after = req.after
			if after == nil then
				local cells = cx.notebook:cells(nb)
				after = if #cells > 0 then cells[#cells].id else 0
			end
			opts = { cell = cx.notebook:add(nb, { kind = "code", source = req.source, after = after }) }
		elseif req.all then
			opts = { all = true }
		else
			opts = { cell = req.cell }
		end
		cx.notebook:run(nb, opts):next(function(cells, err)
			if err then
				answer(id, false, err)
			else
				answer(id, true, { pane = nb, cells = cells or tern.json.array() })
			end
		end)
	elseif op == "restart" then
		cx.notebook:kernel_restart(nb):next(function(kernel, err)
			if err then
				answer(id, false, err)
			else
				answer(id, true, kernel)
			end
		end)
	else
		error(`unknown op {tostring(op)}`, 0)
	end
end

local function drain(cx: WindowCx)
	local ok, names = pcall(tern.fs.list, REQ)
	if not ok then
		tern.log.warn("nbbridge: cannot list requests", names)
		return
	end
	for _, name in names do
		local id = string.match(name, "^([%w%-_]+)%.json$")
		if id then
			local path = REQ .. "/" .. name
			local read_ok, text = pcall(tern.fs.read, path)
			pcall(tern.fs.remove, path)
			if read_ok then
				tern.fs.write(RES .. "/" .. id .. ".ack", "")
				local decoded, req = pcall(tern.json.decode, text)
				if not decoded then
					answer(id, false, "bad request JSON: " .. tostring(req))
				else
					local handled, err = pcall(handle, cx, id, req)
					if not handled then
						answer(id, false, err)
					end
				end
			end
		end
	end
end

local function listen()
	-- `exec` keeps the pid in the file the next load kills, so a reader from a
	-- dropped VM doesn't keep swallowing doorbells.
	tern.process.run(
		{ "/bin/sh", "-c", 'echo $$ > "$1"; exec cat "$2" > /dev/null', "sh", READER_PID, BELL },
		{},
		function(result, cx)
			listen()
			if cx and result.status == 0 then
				drain(cx)
			end
		end
	)
end

tern.process.run({
	"/bin/sh",
	"-c",
	'[ -f "$1" ] && kill "$(cat "$1")" 2>/dev/null; rm -f "$1"; [ -p "$2" ] || { rm -f "$2"; mkfifo -m 600 "$2"; }',
	"sh",
	READER_PID,
	BELL,
}, {}, function(result, cx)
	if result.status ~= 0 then
		tern.log.error("nbbridge: cannot set up the doorbell", result.stderr)
		return
	end
	listen()
	-- Requests written while no window listened.
	if cx then
		drain(cx)
	end
end)
