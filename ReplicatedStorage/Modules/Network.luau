--!native
--[=[
	@class Network
	
	STYLIZED VERSION
	Unified remote wrapper - it groups a RemoteEvent, an UnreliableRemoteEvent,
	a RemoteFunction and a BindableEvent into a single named-connection
	API so callers dont have to think about which underlying Instance
	theyre using

	Also handles a client-ready handshake: the server will not fire client
	connections at a player until that player's client has acknowledged
	that its Network module has finished initializing

	Examples:
	Network:init()

	Network:SetConnection("Damage", Network.RemoteType.REMOTE_EVENT, function(player, amount)
		print(player, "dealt", amount, "damage")
	end)

	Network:FireServerConnection("Damage", Network.RemoteType.REMOTE_EVENT, 10)
]=]

local Signal = require(script.Parent.Signal)

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

export type RemoteTypeValue = "REMOTE_EVENT" | "UREMOTE_EVENT" | "REMOTE_FUNCTION" | "BINDABLE_EVENT"

export type RemoteTypeMap = {
	REMOTE_EVENT: "REMOTE_EVENT",
	UNRELIABLE_REMOTE_EVENT: "UREMOTE_EVENT",
	REMOTE_FUNCTION: "REMOTE_FUNCTION",
	BINDABLE_EVENT: "BINDABLE_EVENT",
}

export type Connection = {
	Name: string,
	Type: RemoteTypeValue,
	Callback: ((...any) -> ...any)?,
	Signal: Signal.Signal?,
}

export type SignalConnection = Signal.Connection
export type ConnectionHandle = Connection | SignalConnection
export type Network = {
	RemoteType: RemoteTypeMap,
	ServiceLive: boolean,
	Connections: { [string]: Connection },
	Signals: { [string]: RBXScriptConnection? },
	ReadyPlayers: { [Player]: boolean },
	PendingReadyPlayers: { [Player]: boolean },
	PendingReadyCount: number,
	BindToCloseRegistered: boolean,
	Initializing: boolean,

	New: (self: Network) -> (),
	SetConnection: (
		self: Network,
		name: string,
		remoteType: RemoteTypeValue,
		callback: (...any) -> ...any
	) -> ConnectionHandle?,
	IsLive: (self: Network) -> boolean,
	FireClientConnection: (
		self: Network,
		player: Player,
		name: string,
		remoteType: RemoteTypeValue,
		...any
	) -> ...any,
	FireAllClientConnection: (
		self: Network,
		name: string,
		remoteType: RemoteTypeValue,
		...any
	) -> (),
	FireServerConnection: (
		self: Network,
		name: string,
		remoteType: RemoteTypeValue,
		...any
	) -> ...any,
	FireConnection: (self: Network, name: string, ...any) -> (),
	GetRemote: (self: Network, remoteType: RemoteTypeValue) -> Instance?,
	RemoveConnection: (
		self: Network,
		name: string,
		remoteType: RemoteTypeValue
	) -> Connection?,
	Destroy: (self: Network) -> (),
	GetProperty: (self: Network, propertyName: string) -> any,
	WaitForLive: (self: Network) -> boolean,
	init: (self: Network) -> (),
}

local RemoteType: RemoteTypeMap = {
	REMOTE_EVENT = "REMOTE_EVENT",
	UNRELIABLE_REMOTE_EVENT = "UREMOTE_EVENT",
	REMOTE_FUNCTION = "REMOTE_FUNCTION",
	BINDABLE_EVENT = "BINDABLE_EVENT",
}

local READY_EVENT_NAME: string = "**NetworkClientReady"
local READY_ACK_EVENT_NAME: string = "**NetworkServerReadyAck"
local READY_RETRY_START: number = 0.5
local READY_RETRY_MAX: number = 5

local Network = {}

--[=[
	@within Network
	@prop RemoteType RemoteTypeMap
	Enum-like table of the remote kinds this module understands: pass one
	of these values wherever a function below asks for a `remoteType`.
]=]
Network.RemoteType = RemoteType

--[=[
	@within Network
	@prop ServiceLive boolean
	True once :init() has finished setting everything up. See :IsLive().
]=]
Network.ServiceLive = false
Network.Connections = {} :: { [string]: Connection }
Network.Signals = {} :: { [string]: RBXScriptConnection? }
Network.ReadyPlayers = {} :: { [Player]: boolean }
Network.PendingReadyPlayers = {} :: { [Player]: boolean }
Network.PendingReadyCount = 0
Network.BindToCloseRegistered = false
Network.Initializing = false

local remoteEvent: RemoteEvent? = nil
local remoteFunction: RemoteFunction? = nil
local unreliableRemoteEvent: UnreliableRemoteEvent? = nil
local bindableEvent: BindableEvent? = nil
local remotesByType: { [RemoteTypeValue]: Instance }? = nil
local readyAcknowledged: boolean = false
local readyAttempt: number = 0

-- Finds an existing remote under ReplicatedStorage.Events, or creates it
-- if were on the server and it doesn't exist yet
local function getOrCreate(className: string, waitName: string): Instance
	local events: Instance?

	if RunService:IsServer() then
		events = ReplicatedStorage:FindFirstChild("Events")

		if not events then
			events = Instance.new("Folder")
			events.Name = "Events"
			events.Parent = ReplicatedStorage
		end

		local existing = events:FindFirstChild(waitName)
		if existing then
			return existing
		end

		local remote = Instance.new(className)
		remote.Name = waitName
		remote.Parent = events

		return remote
	end

	events = ReplicatedStorage:WaitForChild("Events")
	return events:WaitForChild(waitName)
end
-- Routes an incoming remote payload to the matching registered connection,
-- if one exists and its type matches.
local function dispatch(
	connections: { [string]: Connection },
	player: Player?,
	remoteType: RemoteTypeValue,
	name: string,
	...: any
): ...any
	local connection = connections[name]
	if not connection then
		return
	end
	if connection.Type ~= remoteType then
		return
	end

	if connection.Type == RemoteType.REMOTE_FUNCTION then
		if player then
			return connection.Callback(player, ...)
		end
		return connection.Callback(...)
	end

	if player then
		connection.Signal:Emit(player, ...)
	else
		connection.Signal:Emit(...)
	end
end
-- Clears the local BindableEvent;; used on both :New() (rebuild) and :Destroy().
local function destroyBindable(): ()
	if remotesByType then
		remotesByType[RemoteType.BINDABLE_EVENT] = nil
	end
	if bindableEvent then
		bindableEvent:Destroy()
		bindableEvent = nil
	end
end
-- @client
-- Tells the server "my Network module is ready" retrying with backoff
-- until the server acknowledges it (see READY_ACK_EVENT_NAME).
local function announceReady(remote: RemoteEvent): ()
	readyAcknowledged = false
	readyAttempt = readyAttempt + 1
	local attempt = readyAttempt

	task.spawn(function()
		local interval = READY_RETRY_START
		while not readyAcknowledged and readyAttempt == attempt and remote.Parent do
			remote:FireServer(READY_EVENT_NAME)
			task.wait(interval)
			interval = math.min(interval * 2, READY_RETRY_MAX)
		end
	end)
end

--[=[
	@within Network
	Builds (or rebuilds) all underlying remotes and their listeners.
	Called once by :init() — you shouldnt need to call this directly.
]=]
function Network:New(): ()
	if self.Signals then
		for _, connection in pairs(self.Signals) do
			if connection then
				connection:Disconnect()
			end
		end
	end
	destroyBindable()

	remoteEvent = getOrCreate("RemoteEvent", "RemoteEvent") :: RemoteEvent
	remoteFunction = getOrCreate("RemoteFunction", "RemoteFunction") :: RemoteFunction
	unreliableRemoteEvent = getOrCreate("UnreliableRemoteEvent", "UnreliableRemoteEvent") :: UnreliableRemoteEvent

	bindableEvent = Instance.new("BindableEvent")
	bindableEvent.Name = "BindableEvent"
	remotesByType = {
		[RemoteType.REMOTE_EVENT] = remoteEvent,
		[RemoteType.UNRELIABLE_REMOTE_EVENT] = unreliableRemoteEvent,
		[RemoteType.REMOTE_FUNCTION] = remoteFunction,
		[RemoteType.BINDABLE_EVENT] = bindableEvent,
	}

	self.Connections = self.Connections or {}
	self.ReadyPlayers = self.ReadyPlayers or {}
	self.PendingReadyPlayers = self.PendingReadyPlayers or {}
	self.PendingReadyCount = 0

	if RunService:IsServer() then
		self.Signals = {
			RemoteEvent = remoteEvent and remoteEvent.OnServerEvent:Connect(function(player: Player, ...: any)
				local name = ...
				if name == READY_EVENT_NAME then
					if player.Parent and not self.ReadyPlayers[player] then
						self.ReadyPlayers[player] = true

						if self.PendingReadyPlayers[player] then
							self.PendingReadyPlayers[player] = nil
							self.PendingReadyCount = math.max(0, self.PendingReadyCount - 1)
						end
					end
					if player.Parent and remoteEvent then
						remoteEvent:FireClient(player, READY_ACK_EVENT_NAME)
					end
					return
				end
				dispatch(self.Connections, player, RemoteType.REMOTE_EVENT, ...)
			end),

			UnreliableRemoteEvent = unreliableRemoteEvent and unreliableRemoteEvent.OnServerEvent:Connect(function(player: Player, ...: any)
				dispatch(self.Connections, player, RemoteType.UNRELIABLE_REMOTE_EVENT, ...)
			end),

			BindableEvent = bindableEvent and bindableEvent.Event:Connect(function(...: any)
				dispatch(self.Connections, nil, RemoteType.BINDABLE_EVENT, ...)
			end),

			PlayerAdded = Players.PlayerAdded:Connect(function(player: Player)
				if not self.ReadyPlayers[player] and not self.PendingReadyPlayers[player] then
					self.PendingReadyPlayers[player] = true
					self.PendingReadyCount = self.PendingReadyCount + 1
				end
			end),

			PlayerRemoving = Players.PlayerRemoving:Connect(function(player: Player)
				if self.ReadyPlayers[player] then
					self.ReadyPlayers[player] = nil
				elseif self.PendingReadyPlayers[player] then
					self.PendingReadyPlayers[player] = nil
					self.PendingReadyCount = math.max(0, self.PendingReadyCount - 1)
				end
			end),
		}

		for _, player in ipairs(Players:GetPlayers()) do
			if not self.ReadyPlayers[player] and not self.PendingReadyPlayers[player] then
				self.PendingReadyPlayers[player] = true
				self.PendingReadyCount = self.PendingReadyCount + 1
			end
		end
	else
		self.Signals = {
			RemoteEvent = remoteEvent and remoteEvent.OnClientEvent:Connect(function(...: any)
				local name = ...
				if name == READY_ACK_EVENT_NAME then
					readyAcknowledged = true
					return
				end
				dispatch(self.Connections, nil, RemoteType.REMOTE_EVENT, ...)
			end),

			UnreliableRemoteEvent = unreliableRemoteEvent and unreliableRemoteEvent.OnClientEvent:Connect(function(...: any)
				dispatch(self.Connections, nil, RemoteType.UNRELIABLE_REMOTE_EVENT, ...)
			end),

			BindableEvent = bindableEvent and bindableEvent.Event:Connect(function(...: any)
				dispatch(self.Connections, nil, RemoteType.BINDABLE_EVENT, ...)
			end),
		}
	end

	if remoteFunction then
		if RunService:IsServer() then
			remoteFunction.OnServerInvoke = function(player: Player, ...: any)
				return dispatch(self.Connections, player, RemoteType.REMOTE_FUNCTION, ...)
			end
		else
			remoteFunction.OnClientInvoke = function(...: any)
				return dispatch(self.Connections, nil, RemoteType.REMOTE_FUNCTION, ...)
			end
		end
	end

	if not RunService:IsServer() and remoteEvent then
		announceReady(remoteEvent)
	end

	self.ServiceLive = true
end

--[=[
	@within Network
	@param name string -- the connection's identifier
	@param remoteType RemoteTypeValue -- which underlying remote to use
	@param callback (...any) -> ...any -- handler for incoming calls
	@return ConnectionHandle?

	Registers a handler for a named connection.

	For `REMOTE_FUNCTION`: `callback` is stored directly and invoked on the
	receiving side (server for FireServerConnection-style calls, client for
	FireClientConnection-style calls);; only one callback per name.

	For every other `remoteType`: returns a Signal connection you can later
	`:Disconnect()` multiple listeners can share the same name/remoteType.
]=]
function Network:SetConnection(name: string, remoteType: RemoteTypeValue, callback: (...any) -> ...any): ConnectionHandle?
	if not name or not remoteType or not callback then
		return
	end

	if remoteType == RemoteType.REMOTE_FUNCTION then
		local connection: Connection = {
			Name = name,
			Type = remoteType,
			Callback = callback,
		}
		self.Connections[name] = connection
		return connection
	end

	local connection: Connection? = self.Connections[name]
	if not connection then
		connection = {
			Name = name,
			Type = remoteType,
			Signal = Signal.Create(),
		}
		self.Connections[name] = connection
	elseif connection.Type ~= remoteType then
		warn(("[Network] '%s' is already registered under a different RemoteType"):format(name))
		return
	end

	return (connection.Signal :: Signal.Signal):On(callback)
end

--[=[
	@within Network
	@return boolean
	Returns true once :init() has finished setting everything up.
]=]
function Network:IsLive(): boolean
	return self.ServiceLive
end

--[=[
	@within Network
	@server
	@param player Player
	@param name string
	@param remoteType RemoteTypeValue

	Fires a named connection on one specific client, silently does nothing
	if that clients Network module hasn't acknowledged readiness yet
]=]
function Network:FireClientConnection(player: Player, name: string, remoteType: RemoteTypeValue, ...: any): ...any
	if RunService:IsClient() then
		return
	end
	if not player or not player:IsA("Player") then
		return
	end

	if remoteType == RemoteType.REMOTE_EVENT and remoteEvent then
		if not self.ReadyPlayers[player] then
			return
		end
		remoteEvent:FireClient(player, name, ...)
	elseif remoteType == RemoteType.UNRELIABLE_REMOTE_EVENT and unreliableRemoteEvent then
		if not self.ReadyPlayers[player] then
			return
		end
		unreliableRemoteEvent:FireClient(player, name, ...)
	elseif remoteType == RemoteType.REMOTE_FUNCTION and remoteFunction then
		if not self.ReadyPlayers[player] then
			return
		end
		return remoteFunction:InvokeClient(player, name, ...)
	end
end

--[=[
	@within Network
	@server
	@param name string
	@param remoteType RemoteTypeValue

	Fires a named connection on every currently-ready client. REMOTE_FUNCTION
	is not supported here (there's no single return value to give back)
]=]
function Network:FireAllClientConnection(name: string, remoteType: RemoteTypeValue, ...: any): ()
	if RunService:IsClient() or remoteType == RemoteType.REMOTE_FUNCTION then
		return
	end

	if remoteType == RemoteType.REMOTE_EVENT and remoteEvent then
		if self.PendingReadyCount == 0 then
			remoteEvent:FireAllClients(name, ...)
		else
			for _, player in ipairs(Players:GetPlayers()) do
				if self.ReadyPlayers[player] then
					remoteEvent:FireClient(player, name, ...)
				end
			end
		end
	elseif remoteType == RemoteType.UNRELIABLE_REMOTE_EVENT and unreliableRemoteEvent then
		if self.PendingReadyCount == 0 then
			unreliableRemoteEvent:FireAllClients(name, ...)
		else
			for _, player in ipairs(Players:GetPlayers()) do
				if self.ReadyPlayers[player] then
					unreliableRemoteEvent:FireClient(player, name, ...)
				end
			end
		end
	end
end

--[=[
	@within Network
	@client
	@param name string
	@param remoteType RemoteTypeValue

	Fires a named connection on the server
]=]
function Network:FireServerConnection(name: string, remoteType: RemoteTypeValue, ...: any): ...any
	if RunService:IsServer() then
		return
	end

	if remoteType == RemoteType.REMOTE_EVENT and remoteEvent then
		remoteEvent:FireServer(name, ...)
	elseif remoteType == RemoteType.UNRELIABLE_REMOTE_EVENT and unreliableRemoteEvent then
		unreliableRemoteEvent:FireServer(name, ...)
	elseif remoteType == RemoteType.REMOTE_FUNCTION and remoteFunction then
		return remoteFunction:InvokeServer(name, ...)
	end
end

--[=[
	@within Network
	@param name string
	Fires a same-side BindableEvent connection. No network traffic — this
	never leaves the server or the client it's called from
]=]
function Network:FireConnection(name: string, ...: any): ()
	if bindableEvent then
		bindableEvent:Fire(name, ...)
	end
end

--[=[
	@within Network
	@param remoteType RemoteTypeValue
	@return Instance?

	Returns the raw remote Instance backing a given remoteType, if you need
	to work with it directly instead of going through SetConnection/Fire*
]=]
function Network:GetRemote(remoteType: RemoteTypeValue): Instance?
	local remote = remotesByType and remotesByType[remoteType]
	if not remote then
		warn("[Network] could not find the requested remote: check the RemoteType")
	end
	return remote
end

--[=[
	@within Network
	@param name string
	@param remoteType RemoteTypeValue
	@return Connection?
	Unregisters a connection and destroys its Signal (if it has one)
]=]
function Network:RemoveConnection(name: string, remoteType: RemoteTypeValue): Connection?
	local connection = self.Connections[name]
	if not connection then
		return
	end
	if connection.Type ~= remoteType then
		return
	end
	if connection.Signal then
		connection.Signal:Destroy()
	end
	self.Connections[name] = nil
	return connection
end

--[=[
	@within Network
	Tears down every connection, signal and remote. After this, :init()
	(via :New()) would need to run again before the module is usable
]=]
function Network:Destroy(): ()
	readyAttempt = readyAttempt + 1

	for _, connection in pairs(self.Connections) do
		if connection.Signal then
			connection.Signal:Destroy()
		end
	end
	table.clear(self.Connections)

	for _, connection in pairs(self.Signals) do
		if connection then
			connection:Disconnect()
		end
	end
	table.clear(self.Signals)

	table.clear(self.ReadyPlayers)
	table.clear(self.PendingReadyPlayers)
	self.PendingReadyCount = 0

	destroyBindable()

	if remoteFunction then
		if RunService:IsServer() then
			remoteFunction.OnServerInvoke = nil
		else
			remoteFunction.OnClientInvoke = nil
		end
	end

	self.ServiceLive = false
end

--[=[
	@within Network
	@param propertyName string
	@return any
	Generic getter mostly useful for debugging/inspection
]=]
function Network:GetProperty(propertyName: string): any
	return self[propertyName]
end

--[=[
	@within Network
	@yields
	@return boolean
	Blocks (yields) until the module has finished :init()
]=]
function Network:WaitForLive(): boolean
	if self.ServiceLive then
		return true
	end
	repeat
		task.wait()
	until self.ServiceLive
	return true
end

--[=[
	@within Network
	Starts the module. Safe to call once per side (server/client); a second
	call is ignored with a warning instead of rebuilding everything
]=]
function Network:init(): ()
	if self.ServiceLive or self.Initializing then
		warn("[Network] network is already initialized: ignoring the 2nd call")
		return
	end

	self.Initializing = true
	local success, err = xpcall(function()
		self:New()
		if RunService:IsServer() and not self.BindToCloseRegistered then
			self.BindToCloseRegistered = true
			game:BindToClose(function()
				self:Destroy()
			end)
		end
		self.ServiceLive = true
		script:SetAttribute("ServiceLive", true)
	end, debug.traceback)

	if not success then
		self:Destroy()
		self.Initializing = false
		warn("[Network] failed to initialize:\n" .. err)
		return
	end

	self.Initializing = false
end

return (Network :: any) :: Network
