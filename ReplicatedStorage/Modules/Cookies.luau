--[=[
	@class Cookies

	Small leveled logger. Each Cookies instance carries its own context
	table (merged into every entry it logs) and its own minimum level;
	entries below that level are dropped before reaching any output

	Examples:
	local log = Cookies.new({ module = "Combat" })

	log:info("player joined", { userId = player.UserId })
	log:setLevel("debug")
	log:debug("hit detected", { damage = 12 })
]=]

local Cookies = {}
Cookies.__index = Cookies

local RunService = game:GetService("RunService")
local IS_SERVER: boolean = RunService:IsServer()
local TAG: string = if IS_SERVER then "[SERVER]" else "[CLIENT]"

local MAX_DEPTH: number = 3

local LEVEL_WEIGHT: { [string]: number } = {
	fatal = 1,
	error = 2,
	warn = 3,
	info = 4,
	debug = 5,
	trace = 6,
}

local defaultLevel: string = "info"
local outputs: { (LogEntry) -> () } = {}

export type LogEntry = {
	level: string,
	message: string,
	context: { [string]: any }?,
	tag: string,
}

export type Cookies = {
	context: { [string]: any },
	level: string,

	new: (context: { [string]: any }?) -> Cookies,
	with: (self: Cookies, extra: { [string]: any }) -> Cookies,
	setLevel: (self: Cookies, level: string) -> (),
	log: (
		self: Cookies,
		level: string,
		message: string,
		context: { [string]: any }?
	) -> (),
	fatal: (self: Cookies, msg: string, ctx: { [string]: any }?) -> (),
	error: (self: Cookies, msg: string, ctx: { [string]: any }?) -> (),
	warn: (self: Cookies, msg: string, ctx: { [string]: any }?) -> (),
	info: (self: Cookies, msg: string, ctx: { [string]: any }?) -> (),
	debug: (self: Cookies, msg: string, ctx: { [string]: any }?) -> (),
	trace: (self: Cookies, msg: string, ctx: { [string]: any }?) -> (),
	setDefaultLevel: (level: string) -> (),
	addCallback: (cb: (LogEntry) -> ()) -> (),
}

-- Renders a value for log output: primitives via tostring, tables as a
-- shallow `{k=v, ...}` string that stops recursing past MAX_DEPTH
local function stringify(value: any, depth: number?): string
	if type(value) ~= "table" then
		return tostring(value)
	end
	local d: number = depth or 0
	if d > MAX_DEPTH then
		return "{...}"
	end
	local parts: { string } = {}
	for k, v in value do
		parts[#parts + 1] = tostring(k) .. "=" .. stringify(v, d + 1)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function hasEntries(t: { [string]: any }?): boolean
	return t ~= nil and next(t) ~= nil
end

-- Default output: formats an entry as "[SERVER] [LEVEL] message {ctx}" and
-- routes it to error/warn/print depending on its level
local function baseOutput(entry: LogEntry): ()
	local ctxStr: string = hasEntries(entry.context) and (" " .. stringify(entry.context)) or ""

	local line: string = string.format(
		"%s [%s] %s%s",
		entry.tag,
		string.upper(entry.level),
		entry.message,
		ctxStr
	)

	if entry.level == "fatal" then
		error(line, 0)
	elseif entry.level == "error" or entry.level == "warn" then
		warn(line)
	else
		print(line)
	end
end

table.insert(outputs, baseOutput)

--[=[
	@within Cookies
	@param context { [string]: any }?
	@return Cookies
	Creates a new logger. `context` is merged into every entry this
	instance logs
]=]
function Cookies.new(context: { [string]: any }?): Cookies
	local self = setmetatable({} :: any, Cookies) :: Cookies
	self.context = context or {}
	self.level = defaultLevel
	return self
end

--[=[
	@within Cookies
	@param extra { [string]: any }
	@return Cookies

	Returns a new logger whose context is this one's context merged with
	`extra` (extra's keys win on conflict), and whose level is inherited
	from this logger. The original logger is left untouched
]=]
function Cookies:with(extra: { [string]: any }): Cookies
	local merged: { [string]: any } = table.clone(self.context)
	for k, val in extra do
		merged[k] = val
	end
	local child = self.new(merged)
	child.level = self.level
	return child
end

--[=[
	@within Cookies
	@param level string -- one of: fatal, error, warn, info, debug, trace
	Sets this instance's minimum level, entries logged below this level
	are dropped
]=]
function Cookies:setLevel(level: string): ()
	if not LEVEL_WEIGHT[level] then
		error(`[Cookies] invalid level: {level}`)
	end
	self.level = level
end

--[=[
	@within Cookies
	@param level string -- one of: fatal, error, warn, info, debug, trace
	@param message string
	@param context { [string]: any }? -- merged on top of the instance's own context for this entry only

	Logs a single entry if `level` meets this instance's minimum level,
	dispatching it to every registered output (see .addCallback())
]=]
function Cookies:log(level: string, message: string, context: { [string]: any }?): ()
	local weight: number? = LEVEL_WEIGHT[level]
	if not weight then
		error(`[Cookies] invalid level: {level}`)
	end
	if weight > LEVEL_WEIGHT[self.level] then
		return
	end

	local ctx: { [string]: any } = self.context
	if context then
		ctx = table.clone(self.context)
		for k, val in context do
			ctx[k] = val
		end
	end

	local entry: LogEntry = {
		level = level,
		message = message,
		context = ctx,
		tag = TAG,
	}

	for _, out in outputs do
		if level == "fatal" then
			-- Run synchronously so a fatal entry can actually halt the
			-- calling thread (the default output raises a Luau error for
			-- this level). Every other level stays isolated in its own
			-- spawned thread, same as before.
			out(entry)
		else
			task.spawn(out, entry)
		end
	end
end

--[=[
	@within Cookies
	@param msg string
	@param ctx { [string]: any }?
	Logs at the `fatal` level. The default output raises a Luau error for
	this level, so this call will not return under default output config
]=]
function Cookies:fatal(msg: string, ctx: { [string]: any }?): ()
	self:log("fatal", msg, ctx)
end

--[=[
	@within Cookies
	@param msg string
	@param ctx { [string]: any }?
	Logs at the `error` level
]=]
function Cookies:error(msg: string, ctx: { [string]: any }?): ()
	self:log("error", msg, ctx)
end

--[=[
	@within Cookies
	@param msg string
	@param ctx { [string]: any }?
	Logs at the `warn` level
]=]
function Cookies:warn(msg: string, ctx: { [string]: any }?): ()
	self:log("warn", msg, ctx)
end

--[=[
	@within Cookies
	@param msg string
	@param ctx { [string]: any }?
	Logs at the `info` level
]=]
function Cookies:info(msg: string, ctx: { [string]: any }?): ()
	self:log("info", msg, ctx)
end

--[=[
	@within Cookies
	@param msg string
	@param ctx { [string]: any }?
	Logs at the `debug` level
]=]
function Cookies:debug(msg: string, ctx: { [string]: any }?): ()
	self:log("debug", msg, ctx)
end

--[=[
	@within Cookies
	@param msg string
	@param ctx { [string]: any }?
	Logs at the `trace` level
]=]
function Cookies:trace(msg: string, ctx: { [string]: any }?): ()
	self:log("trace", msg, ctx)
end

--[=[
	@within Cookies
	@param level string -- one of: fatal, error, warn, info, debug, trace

	Sets the default minimum level newly-created loggers start with (via
	.new()). Does not affect loggers that already exist
]=]
function Cookies.setDefaultLevel(level: string): ()
	if not LEVEL_WEIGHT[level] then
		error(`[Cookies] invalid level: {level}`)
	end
	defaultLevel = level
end

--[=[
	@within Cookies
	@param cb (LogEntry) -> ()

	Registers an additional output. Every logged entry (from every
	instance) is dispatched to every registered output, each in its own
	spawned thread
]=]
function Cookies.addCallback(cb: (LogEntry) -> ()): ()
	if type(cb) ~= "function" then
		error("[Cookies] callback must be a function")
	end
	table.insert(outputs, cb)
end

return (Cookies :: any) :: Cookies
