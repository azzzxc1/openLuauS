--[=[
	@class Maid

	STYLIZED VERSION
	Tracks a set of "tasks" (functions, connections, threads, Instances or
	objects with a Destroy/DoCleaning/Cleanup method) and cleans all of them
	up at once when asked to, Tasks can also be assigned/replaced directly
	as keys on the Maid, in which case setting a new value for an existing
	key cleans up the old one automatically

	Examples:
	local maid = Maid.new()

	maid._connection = someSignal:Connect(function() end)
	maid:GiveTask(function() print("cleaned up") end)

	maid:DoCleaning() -- disconnects the signal: runs the function
]=]

local Maid = {
	ClassName = "Maid",
}

Maid.__index = Maid

--[=[
	@within Maid
	@return Maid
	Creates a new, empty Maid
]=]
function Maid.new()
	return setmetatable({
		_tasks = {},
	}, Maid)
end

--[=[
	@within Maid
	@param value any
	@return boolean
	Returns true if `value` is a Maid created by this module
]=]
function Maid.isMaid(value)
	return type(value) == "table" and value.ClassName == "Maid"
end

-- Runs the correct cleanup strategy for a single task, based on its type
function Maid:_cleanup(cleanupTask)
	if type(cleanupTask) == "function" then
		cleanupTask()
	elseif typeof(cleanupTask) == "RBXScriptConnection" then
		cleanupTask:Disconnect()
	elseif typeof(cleanupTask) == "thread" then
		task.cancel(cleanupTask)
	elseif typeof(cleanupTask) == "Instance" then
		cleanupTask:Destroy()
	elseif type(cleanupTask) == "table" then
		if cleanupTask.Destroy then
			cleanupTask:Destroy()
		elseif cleanupTask.DoCleaning then
			cleanupTask:DoCleaning()
		elseif cleanupTask.Cleanup then
			cleanupTask:Cleanup()
		end
	end
end

function Maid:__index(key)
	if Maid[key] ~= nil then
		return Maid[key]
	end
	return self._tasks[key]
end

function Maid:__newindex(key, value)
	if Maid[key] ~= nil then
		error(("'%s' is reserved for Maid"):format(tostring(key)), 2)
	end

	local tasks = self._tasks
	local old = tasks[key]

	if old == value then
		return
	end
	tasks[key] = value

	if old then
		Maid:_cleanup(old)
	end
end

--[=[
	@within Maid
	@param object any
	@param methodName string
	@return number -- the task's index

	Shorthand for cleaning up by calling a method on `object` (e.g. a custom
	`:Stop()`) instead of one of the standard Destroy/DoCleaning/Cleanup names
]=]
function Maid:AddWithMethod(object, methodName)
	local cleanup = function()
		local method = object[methodName]
		if method then
			method(object)
		end
	end
	return self:GiveTask(cleanup)
end

--[=[
	@within Maid
	@param task any
	@return number -- the task's index, usable with :Get()/:Remove()/:Replace()

	Registers a task to be cleaned up on :DoCleaning(). Accepts a function,
	an RBXScriptConnection, a thread, an Instance, or a table with a
	Destroy/DoCleaning/Cleanup method
]=]
function Maid:GiveTask(task)
	if task == nil or task == false then
		error("Task cannot be false or nil", 2)
	end
	local index = #self._tasks + 1
	self[index] = task

	if type(task) == "table" and not task.Destroy and not task.DoCleaning and not task.Cleanup then
		warn("[Maid] given a table task with no cleanup method\n\n" .. debug.traceback())
	end
	return index
end

Maid.Add = Maid.GiveTask
Maid.GiveTaskWithMethod = Maid.AddWithMethod

--[=[
	@within Maid
	@param promise any
	@return any -- the same promise, for chaining

	Tracks a Promise so that it gets cancelled/cleaned up along with
	everything else. If the promise isn't pending anymore, it's returned
	as-is without being tracked
]=]
function Maid:GivePromise(promise)
	if not promise:IsPending() then
		return promise
	end

	local resolved = promise:resolved()
	local index = self:GiveTask(resolved)

	resolved:Finally(function()
		self[index] = nil
	end)
	return resolved
end

--[=[
	@within Maid
	@param index number
	Cleans up and removes a single task by its index
]=]
function Maid:Remove(index)
	local task = self._tasks[index]
	if not task then
		return
	end
	self._tasks[index] = nil
	Maid:_cleanup(task)
end

--[=[
	@within Maid
	@param index number
	Removes a task by its index without running its cleanup
]=]
function Maid:RemoveNoClean(index)
	self._tasks[index] = nil
end

--[=[
	@within Maid
	@param index number
	@param newTask any
	@return any -- newTask

	Replaces the task at `index` with `newTask`, cleaning up the old one
	(same behavior as assigning through the Maid's __newindex)
]=]
function Maid:Replace(index, newTask)
	self[index] = newTask
	return newTask
end

--[=[
	@within Maid
	@param index number
	@return any
	Returns the task stored at `index`, without removing or cleaning it up
]=]
function Maid:Get(index)
	return self._tasks[index]
end

--[=[
	@within Maid
	@param index number
	@return boolean
	Returns true if a task is currently stored at `index`
]=]
function Maid:Has(index)
	return self._tasks[index] ~= nil
end

--[=[
	@within Maid
	Cleans up and removes every currently tracked task
]=]
function Maid:DoCleaning()
	local tasks = self._tasks
	for key, task in pairs(tasks) do
		tasks[key] = nil
		Maid:_cleanup(task)
	end
end

Maid.Destroy = Maid.DoCleaning
Maid.Cleanup = Maid.DoCleaning
Maid.Clear = Maid.DoCleaning

--[=[
	@within Maid
	@param instance Instance
	@return RBXScriptConnection

	Ties this Maid's lifetime to an Instance: when `instance` is removed
	from the game (its AncestryChanged parent becomes nil), the Maid runs
	:DoCleaning() automatically. The connection itself is tracked as a task
]=]
function Maid:LinkToInstance(instance, allowMultiple)
	if typeof(instance) ~= "Instance" then
		error("LinkToInstance expects an Instance", 2)
	end
	local connection
	connection = instance.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			connection:Disconnect()
			self:DoCleaning()
		end
	end)

	self:GiveTask(connection)
	return connection
end

--[=[
	@within Maid
	@param signal any
	@param callback (...any) -> ...any
	@return number -- the task's index

	Shorthand for `signal:Connect(callback)` followed by :GiveTask() on the
	resulting connection
]=]
function Maid:GiveConnection(signal, callback)
	local connection = signal:Connect(callback)
	return self:GiveTask(connection)
end

--[=[
	@within Maid
	@param thread thread
	@return number -- the task's index
	Tracks a thread so it gets task.cancel()'d on cleanup
]=]
function Maid:GiveThread(thread)
	if type(thread) ~= "thread" then
		error("GiveThread expected a thread", 2)
	end
	return self:GiveTask(thread)
end

--[=[
	@within Maid
	@param callback (...any) -> ...any
	@return number -- the task's index
	Tracks a plain function so it gets called on cleanup
]=]
function Maid:GiveFunction(callback)
	if type(callback) ~= "function" then
		error("GiveFunction expected a function", 2)
	end
	return self:GiveTask(callback)
end

return Maid
