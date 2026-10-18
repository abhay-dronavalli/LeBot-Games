--!strict
-- Everything one arena game owns that has to go away in Stop(): connections, threads and instances.
--
-- The standalone arena ran for the life of the server, so nothing in it was ever torn down: modules
-- connected to signals in their constructors and spawned threads that ended whenever they ended.
-- As an arcade mode it starts and stops many times per server, and the contract is that nothing from
-- one game leaks into the next. So every module gets the session's Tasks and goes through it instead
-- of calling Connect / task.spawn / task.delay directly, and Stop() calls clean() once.
--
--   local tasks = Tasks.new()
--   tasks:connect(signal, fn)       -> the connection, disconnected in clean()
--   tasks:spawn(fn, ...)            -> task.spawn, cancelled in clean() if still running
--   tasks:delay(seconds, fn, ...)   -> task.delay, cancelled in clean() if not run yet
--   tasks:add(instance)             -> the instance, destroyed in clean()
--   tasks:clean()                   -> all of the above; afterwards spawn/delay do nothing
--   tasks.dead                      -> true once cleaned

local Tasks = {}
Tasks.__index = Tasks

local PRUNE_AT = 64 -- finished threads are dropped from the list once it grows past this

function Tasks.new()
	local self = setmetatable({}, Tasks)
	self.conns = {} :: { RBXScriptConnection }
	self.threads = {} :: { thread }
	self.items = {} :: { Instance }
	self.dead = false
	return self
end

function Tasks.connect(self, signal: RBXScriptSignal, fn: (...any) -> ()): RBXScriptConnection
	local c = signal:Connect(fn)
	table.insert(self.conns, c)
	if self.dead then
		c:Disconnect()
	end
	return c
end

local function track(self, thread: thread)
	if #self.threads >= PRUNE_AT then
		local live = {}
		for _, t in self.threads do
			if coroutine.status(t) ~= "dead" then
				table.insert(live, t)
			end
		end
		self.threads = live
	end
	table.insert(self.threads, thread)
end

function Tasks.spawn(self, fn: (...any) -> (), ...: any): thread?
	if self.dead then
		return nil
	end
	local t = task.spawn(fn, ...)
	track(self, t)
	return t
end

function Tasks.delay(self, seconds: number, fn: (...any) -> (), ...: any): thread?
	if self.dead then
		return nil
	end
	local t = task.delay(seconds, fn, ...)
	track(self, t)
	return t
end

function Tasks.add(self, instance: Instance): Instance
	table.insert(self.items, instance)
	return instance
end

-- Safe to call from inside one of its own threads: that one is left to finish rather than cancelled
-- out from under the caller.
function Tasks.clean(self)
	self.dead = true
	local me = coroutine.running()
	for _, t in self.threads do
		if t ~= me and coroutine.status(t) ~= "dead" then
			pcall(task.cancel, t)
		end
	end
	table.clear(self.threads)
	for _, c in self.conns do
		c:Disconnect()
	end
	table.clear(self.conns)
	for _, inst in self.items do
		pcall(inst.Destroy, inst)
	end
	table.clear(self.items)
end

return Tasks
