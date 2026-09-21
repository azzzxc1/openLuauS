--[=[
	@class Signal

	STYLIZED VERSION
	Lightweight signal/event implementation;; each Signal keeps a linked list
	of Connections, so connecting, disconnecting and emitting are all O(1)
	(aside from the emit fan-out itself)

	Examples:
	local signal = Signal.Create()

	local connection = signal:On(function(message)
		print("got:", message)
	end)

	signal:Emit("hello")
	connection:Off()
]=]

local Co = coroutine

export type Connection = {
	Connected: boolean,
	next: Connection | false,
	signal: Signal,
	fn: (...any) -> ...any,
	Off: (self: Connection) -> (),
	Destroy: (self: Connection) -> (),
}
export type Signal = {
	handlerListHead: Connection | false,
	proxyHandler: RBXScriptConnection?,
	yieldedThreads: { [thread]: boolean }?,
	destroyed: boolean,
	On: (self: Signal, callback: (...any) -> ...any) -> Connection,
	Once: (self: Signal, callback: (...any) -> ...any) -> Connection,
	Connections: (self: Signal) -> { Connection },
	Clear: (self: Signal) -> (),
	Emit: (self: Signal, ...any) -> (),
	EmitDeferred: (self: Signal, ...any) -> (),
	Await: (self: Signal) -> ...any,
	Destroy: (self: Signal) -> (),
}
export type SignalModule = {
	Create: () -> Signal,
	From: (rbxSignal: RBXScriptSignal) -> Signal,
	Is: (value: any) -> boolean,
}

-- Thread reuse pool (the "GoodSignal" pattern): instead of spawning a brand
-- new coroutine for every :Emit() a single free thread is kept alive and
-- reused across handler calls so repeated emits don't churn coroutines
local freeRunnerThread: thread? = nil

local function acquireRunnerThreadAndCallEventHandler(handler: (...any) -> ...any, ...: any): ()
	local acquiredRunnerThread: thread? = freeRunnerThread
	freeRunnerThread = nil
	handler(...)
	freeRunnerThread = acquiredRunnerThread
end

local function runEventHandlerInFreeThread(...: any): ()
	acquireRunnerThreadAndCallEventHandler(...)
	while true do
		acquireRunnerThreadAndCallEventHandler(Co.yield())
	end
end

local Connection = {}
Connection.__index = Connection

--[=[
	@within Signal
	@method Off
	Disconnects this connection so its handler stops receiving future
	:Emit() calls
]=]
function Connection:Off(): ()
	if not self.Connected then
		return
	end
	self.Connected = false
	if self == self.signal.handlerListHead then
		self.signal.handlerListHead = self.next
		return
	end
	local handlerListHead = self.signal.handlerListHead
	while handlerListHead and self ~= handlerListHead.next do
		handlerListHead = handlerListHead.next
	end
	if handlerListHead then
		handlerListHead.next = self.next
	end
end

Connection.Destroy = Connection.Off

setmetatable(Connection, {
	__index = function(self: any, key: any): ()
		error(("[Signal:Connection] failed to get: %s (not a valid member)"):format(tostring(key)), 2)
	end,
	__newindex = function(self: any, key: any, value: any): ()
		error(("[Signal:Connection] failed to set: %s (not a valid member)"):format(tostring(key)), 2)
	end,
})

local Signal = {}
Signal.__index = Signal

--[=[
	@within Signal
	@return Signal
	Creates a brand new empty Signal
]=]
function Signal.Create(): Signal
	return (setmetatable({
		handlerListHead = false,
		proxyHandler = nil,
		yieldedThreads = nil,
		destroyed = false,
	}, Signal) :: any) :: Signal
end

--[=[
	@within Signal
	@param rbxSignal RBXScriptSignal
	@return Signal

	Wraps a Roblox RBXScriptSignal (e.g. `Instance.Changed`) so it can be
	used through the same Signal API. The returned Signal stays connected
	to the underlying event until :Destroy() is called on it
]=]
function Signal.From(rbxSignal: RBXScriptSignal): Signal
	assert(typeof(rbxSignal) == "RBXScriptSignal", "arg #1 to Signal.From must be an RBXScriptSignal: got " .. typeof(rbxSignal))
	local newSignal = Signal.Create()
	newSignal.proxyHandler = rbxSignal:Connect(function(...: any)
		newSignal:Emit(...)
	end)
	return newSignal
end

--[=[
	@within Signal
	@param value any
	@return boolean
	Returns true if `value` is a Signal created by this module
]=]
function Signal.Is(value: any): boolean
	return type(value) == "table" and getmetatable(value) == Signal
end

--[=[
	@within Signal
	@param callback (...any) -> ...any
	@return Connection

	Registers a handler to run on every future :Emit(), each call runs in
	its own (pooled) thread so a handler that errors or yields does not
	block the others
]=]
function Signal:On(callback: (...any) -> ...any): Connection
	if self.destroyed then
		error("attempted to connect to an already-destroyed signal", 2)
	end
	assert(typeof(callback) == "function", "arg #1 to Signal:On must be a function: got " .. typeof(callback))

	local connection = (setmetatable({
		Connected = true,
		next = false,
		signal = self,
		fn = callback,
	}, Connection) :: any) :: Connection

	if self.handlerListHead then
		connection.next = self.handlerListHead
		self.handlerListHead = connection
		return connection
	end

	self.handlerListHead = connection
	return connection
end

--[=[
	@within Signal
	@param callback (...any) -> ...any
	@return Connection
	Same as :On() but the handler automatically disconnects itself after
	its first call
]=]
function Signal:Once(callback: (...any) -> ...any): Connection
	local connection: Connection? = nil
	local called: boolean = false

	connection = self:On(function(...: any)
		if called then
			return
		end
		called = true
		connection:Off()
		callback(...)
	end)

	return connection :: Connection
end

--[=[
	@within Signal
	@return { Connection }
	Returns a snapshot array of every currently-connected Connection
]=]
function Signal:Connections(): { Connection }
	local connections: { Connection } = {}
	local handlerListHead = self.handlerListHead
	while handlerListHead do
		table.insert(connections, handlerListHead)
		handlerListHead = handlerListHead.next
	end
	return connections
end

--[=[
	@within Signal
	Disconnects every connection on this Signal and cancels any threads
	still yielded on :Await()
]=]
function Signal:Clear(): ()
	local handlerListHead = self.handlerListHead
	while handlerListHead do
		handlerListHead.Connected = false
		handlerListHead = handlerListHead.next
	end
	self.handlerListHead = false

	local yieldedThreads: { [thread]: boolean }? = rawget(self, "yieldedThreads")
	if yieldedThreads then
		for thread in yieldedThreads do
			if Co.status(thread) == "suspended" then
				warn(debug.traceback(thread, "signal disconnected: yielded thread cancelled", 2))
				task.cancel(thread)
			end
		end
		table.clear(self.yieldedThreads)
	end
end

--[=[
	@within Signal
	@param ... any
	Fires every connected handler immediately each in its own pooled
	thread, Handlers connected after this call started will not be
	included in this emit
]=]
function Signal:Emit(...: any): ()
	local handlerListHead = self.handlerListHead
	while handlerListHead do
		if handlerListHead.Connected then
			if not freeRunnerThread then
				freeRunnerThread = Co.create(runEventHandlerInFreeThread)
			end
			task.spawn(freeRunnerThread, handlerListHead.fn, ...)
		end
		handlerListHead = handlerListHead.next
	end
end

--[=[
	@within Signal
	@param ... any
	Same as :Emit() but each handler runs on the next resumption cycle
	(via task.defer) instead of immediately
]=]
function Signal:EmitDeferred(...: any): ()
	local handlerListHead = self.handlerListHead
	while handlerListHead do
		local connection = handlerListHead

		task.defer(function(...: any)
			if connection.Connected then
				connection.fn(...)
			end
		end, ...)

		handlerListHead = handlerListHead.next
	end
end

--[=[
	@within Signal
	@yields
	@return ...any

	Yields the calling thread until the next :Emit(), then resumes it with
	whatever arguments were passed. If the Signal is :Clear()'d or
	:Destroy()'d while a thread is waiting that thread is cancelled instead
]=]
function Signal:Await(): ...any
	local yieldedThreads: { [thread]: boolean }? = rawget(self, "yieldedThreads")
	if not yieldedThreads then
		yieldedThreads = {}
		rawset(self, "yieldedThreads", yieldedThreads)
	end

	local thread = Co.running()
	yieldedThreads[thread] = true

	self:Once(function(...: any)
		yieldedThreads[thread] = nil
		if Co.status(thread) == "suspended" then
			task.spawn(thread, ...)
		end
	end)

	return Co.yield()
end

--[=[
	@within Signal
	Disconnects every connection, cancels any yielded :Await() threads, and
	disconnects the underlying RBXScriptSignal if this Signal came from
	Signal.From(), safe to call more than once
]=]
function Signal:Destroy(): ()
	if self.destroyed then
		return
	end
	self.destroyed = true
	self:Clear()

	local proxyHandler: RBXScriptConnection? = rawget(self, "proxyHandler")
	if proxyHandler then
		proxyHandler:Disconnect()
	end
end

setmetatable(Signal, {
	__index = function(self: any, key: any): ()
		error(("[Signal] failed to get: %s (not a valid member)"):format(tostring(key)), 2)
	end,
	__newindex = function(self: any, key: any, value: any): ()
		error(("[Signal] failed to set: %s (not a valid member)"):format(tostring(key)), 2)
	end,
})

return (table.freeze({
	Create = Signal.Create,
	From = Signal.From,
	Is = Signal.Is,
}) :: any) :: SignalModule
