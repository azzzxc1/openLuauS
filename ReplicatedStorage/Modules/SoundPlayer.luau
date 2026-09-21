--!strict

--[=[
	@class SoundPlayer

	Shared audio utility for one-shot sounds and seamless looped playback with crossfading

	Works on both the server and the client (no server-only APIs are used)
	Every public method is wrapped so it never throws: errors are caught, reported
	with a traceback through `warn`, and the method returns `nil`

	```lua
	local SoundPlayer = require(ReplicatedStorage.Modules.SoundPlayer) -- EXAMPLE

	-- One-shot sound with a fade in and a fade out
	local sound = SoundPlayer:play(1234567890, {
		Volume = 0.8,
		FadeIn = 0.5,
		FadeOut = 1,
	})

	-- Random pick from a list, parented to a part (3D audio)
	SoundPlayer:play({ 111111, 222222, 333333 }, { Volume = 0.5 }, workspace.Door)

	-- Looped music with crossfade
	local music = SoundPlayer:createLoop({ Volume = 0.6, CrossFadeTime = 1 })
	music:swapToChoice({ 444444, 555555 })

	-- Change track when the current iteration ends, then fade everything out
	music:swapOnLoop(666666, { MaxLoops = 2 })
	music:onLoopDone(function()
		print("iteration finished")
	end)
	music:stop(2)
	```

	## API index

	### SoundPlayer

	- `SoundPlayer:play(soundId, args?, parent?) -> Sound?`
	- `SoundPlayer:stop(sound, fadeTime?)`
	- `SoundPlayer:fade(sound, targetVolume, tweenTime?) -> Tween?`
	- `SoundPlayer:createLoop(options?) -> LoopedSoundPlayer?`
	- `SoundPlayer:stopAll()`

	### LoopedSoundPlayer

	Configuration
	- `player:setCrossFadeTime(seconds)`
	- `player:setVolumeMultiplier(volume)`
	- `player:setBPM(bpm?)`
	- `player:setSyncPlayback(enabled)`
	- `player:setParent(parent)`

	Playback
	- `player:swapToChoice(soundIds, schedule?)`
	- `player:swapOnLoop(soundId, schedule?)`
	- `player:playOnce(soundId)`
	- `player:playOnceOnLoop(soundId)`
	- `player:stopAfterLoop()`
	- `player:stop(fadeTime?)`

	Events and state
	- `player:waitLoopDone()` (yields)
	- `player:onLoopDone(callback) -> () -> ()`
	- `player:getSound() -> Sound?`
	- `player:isPlaying() -> boolean`
	- `player:destroy()`

	### Types

	- `SoundSource`
	- `PlayArgs`
	- `LoopSchedule`
	- `LoopedSoundPlayerOptions`

	## Sound sources

	Anywhere a `SoundSource` is accepted, any of these forms works
	- a number: `1234567890`
	- a numeric string: `"1234567890"`
	- a full asset string: `"rbxassetid://1234567890"`
	- a `Sound` instance (its `SoundId` is read)
	- a table with a `SoundId` field

	Everything is normalized to `rbxassetid://ID`
	Anything else (negative numbers, decimals, NaN, other URL formats, non-Sound instances)
	is rejected with a warning and the call returns `nil` or does nothing

	## One-shot sounds

	- `play` accepts a single source or an array of sources (one is picked at random)
	- The parent is resolved in this order: the `parent` argument, then `args.Parent`, then `SoundService`
	- `args.Volume` is clamped to 0 to 10 (default 1), `FadeIn` and `FadeOut` to 0 to 3600 seconds
	- Every other key in `args` is applied to the `Sound` as a property
	- `SoundId` and `Parent` can never be overridden through `args`
	- If any property in `args` is invalid, the sound is not created and `play` returns `nil`
	- `FadeOut` is scheduled relative to the end of the sound and is ignored for looped sounds
	- Sounds are destroyed automatically when they end or when they leave the hierarchy
	- `stop` with a fade time tweens the volume to 0 and then destroys the sound, with a
	  fallback timer so the sound is destroyed even if the tween never completes
	- `fade` returns `nil` if the sound is dead or already being stopped

	## Looped playback

	A `LoopedSoundPlayer` plays one "entry" at a time and advances through iterations
	It is driven by a `Heartbeat` connection that only exists while the player is active

	- Crossfade: the next iteration starts `CrossFadeTime` seconds before the current one ends
	  (capped at half the sound length) and the two sounds fade over each other
	- Crossfade is skipped when `CrossFadeTime` is 0 or when the schedule has a `LoopDelay`
	  With crossfade 0 there can be a very small gap between iterations because each
	  iteration is a new `Sound` instance
	- `LoopSchedule.MaxLoops` limits the number of iterations, `nil` means loop forever
	- `LoopSchedule.LoopDelay` waits that many seconds between iterations
	- Sync playback: when `SyncPlayback` is on and a `BPM` is set, every start is delayed until
	  the next beat of the server clock (`workspace:GetServerTimeNow()`), so different clients stay aligned
	- Protection: after 10 consecutive iterations shorter than 0.05 seconds the loop stops with a warning
	- A sound that does not load within 10 seconds, or loads with a length of 0, stops the player
	- The queue holds a single pending entry, a new call to `swapOnLoop` or `playOnceOnLoop`
	  replaces the previous one

	## Defaults and limits

	- `Volume` (loop options): 1, range 0 to 10
	- `CrossFadeTime`: 0.5, range 0 to 60
	- `BPM`: must be greater than 0 and at most 1000, otherwise it is ignored
	- `SyncPlayback`: only `true` enables it
	- `stop` on a loop with no fade time uses the current `CrossFadeTime` as the fade
]=]

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

--[=[
	@type SoundSource string | number | Sound | { SoundId: any }
	@within SoundPlayer

	Any value that can be resolved to a sound asset
]=]
export type SoundSource = string | number | Sound | { SoundId: any }

--[=[
	@interface PlayArgs
	@within SoundPlayer
	.Parent Instance? -- Parent of the sound, used when no explicit parent argument is given
	.Volume number? -- Target volume from 0 to 10, defaults to 1
	.FadeIn number? -- Seconds to fade in from silence
	.FadeOut number? -- Seconds to fade out at the end of the sound
	.[string] any -- Any other key is applied to the Sound as a property
]=]
export type PlayArgs = {
	Parent: Instance?,
	Volume: number?,
	FadeIn: number?,
	FadeOut: number?,
	[string]: any,
}

--[=[
	@interface LoopSchedule
	@within SoundPlayer
	.MaxLoops number? -- Maximum number of iterations, nil loops forever
	.LoopDelay number? -- Seconds to wait between iterations
]=]
export type LoopSchedule = {
	MaxLoops: number?,
	LoopDelay: number?,
}

--[=[
	@interface LoopedSoundPlayerOptions
	@within SoundPlayer
	.Parent Instance? -- Parent of the created sounds, defaults to SoundService
	.Volume number? -- Volume multiplier from 0 to 10, defaults to 1
	.CrossFadeTime number? -- Crossfade duration in seconds from 0 to 60, defaults to 0.5
	.BPM number? -- Beats per minute used for synced playback
	.SyncPlayback boolean? -- Aligns every start to the next beat of the server clock
]=]
export type LoopedSoundPlayerOptions = {
	Parent: Instance?,
	Volume: number?,
	CrossFadeTime: number?,
	BPM: number?,
	SyncPlayback: boolean?,
}
export type LoopedSoundPlayer = {
	setCrossFadeTime: (self: LoopedSoundPlayer, seconds: number) -> (),
	setVolumeMultiplier: (self: LoopedSoundPlayer, volume: number) -> (),
	setBPM: (self: LoopedSoundPlayer, bpm: number?) -> (),
	setSyncPlayback: (self: LoopedSoundPlayer, enabled: boolean) -> (),
	setParent: (self: LoopedSoundPlayer, parent: Instance) -> (),
	swapToChoice: (self: LoopedSoundPlayer, soundIds: { SoundSource }, schedule: LoopSchedule?) -> (),
	swapOnLoop: (self: LoopedSoundPlayer, soundId: SoundSource, schedule: LoopSchedule?) -> (),
	playOnce: (self: LoopedSoundPlayer, soundId: SoundSource) -> (),
	playOnceOnLoop: (self: LoopedSoundPlayer, soundId: SoundSource) -> (),
	stopAfterLoop: (self: LoopedSoundPlayer) -> (),
	stop: (self: LoopedSoundPlayer, fadeTime: number?) -> (),
	waitLoopDone: (self: LoopedSoundPlayer) -> (),
	onLoopDone: (self: LoopedSoundPlayer, callback: () -> ()) -> () -> (),
	getSound: (self: LoopedSoundPlayer) -> Sound?,
	isPlaying: (self: LoopedSoundPlayer) -> boolean,
	destroy: (self: LoopedSoundPlayer) -> (),
}

export type SoundPlayer = {
	play: (self: SoundPlayer, soundId: SoundSource | { SoundSource }, args: PlayArgs?, parent: Instance?) -> Sound?,
	stop: (self: SoundPlayer, sound: Sound, fadeTime: number?) -> (),
	fade: (self: SoundPlayer, sound: Sound, targetVolume: number, tweenTime: number?) -> Tween?,
	createLoop: (self: SoundPlayer, options: LoopedSoundPlayerOptions?) -> LoopedSoundPlayer?,
	stopAll: (self: SoundPlayer) -> (),
}

-- Internal LoopedSoundPlayer data
type Entry = {
	id: string,
	loops: boolean,
	maxLoops: number?,
	loopDelay: number,
	iterations: number,
}
type PlayerData = {
	parent: Instance,
	volumeMultiplier: number,
	crossFadeTime: number,
	bpm: number?,
	syncPlayback: boolean,
	entry: Entry?,
	queued: Entry?,
	sound: Sound?,
	outgoing: { [Sound]: boolean },
	stopAfter: boolean,
	transitioning: boolean,
	token: number,
	loopCount: number,
	rapidCount: number,
	callbacks: { [number]: () -> () },
	nextCallbackId: number,
	connection: RBXScriptConnection?,
	startedAt: number,
	destroyed: boolean,
}

local SoundPlayer = {}
SoundPlayer.__index = SoundPlayer

local LoopedSoundPlayer: any = {}
LoopedSoundPlayer.__index = LoopedSoundPlayer

local LOAD_TIMEOUT: number = 10
local MIN_ITERATION_TIME: number = 0.05
local MAX_RAPID_RESTARTS: number = 10
local STOP_FALLBACK_TIME: number = 0.25

local activeTweens: { [Sound]: Tween } = setmetatable({}, { __mode = "k" }) :: any
local activeSounds: { [Sound]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local activePlayers: { [PlayerData]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local stopping: { [Sound]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- Sanitized number: rejects NaN/nil/non-numeric values and clamps to the range
local function readNumber(
	value: any,
	min: number,
	max: number,
	fallback: number
): number
	local number = tonumber(value)
	if number == nil or number ~= number then
		return fallback
	end

	return math.clamp(number, min, max)
end
local function copyTable(
	tbl: { [any]: any },
	deep: boolean?,
	seen: { [any]: any }?
): { [any]: any }
	local visited: { [any]: any } = seen or {}
	local existing = visited[tbl]
	if existing then
		return existing
	end

	local copy: { [any]: any } = {}
	visited[tbl] = copy

	for key, value in pairs(tbl) do
		if deep ~= false and typeof(value) == "table" then
			copy[key] = copyTable(value, true, visited)
		else
			copy[key] = value
		end
	end

	return copy
end
local function normalizeSoundId(
	soundId: any
): string?
	if typeof(soundId) == "Instance" then
		if not soundId:IsA("Sound") then
			return nil
		end
		soundId = soundId.SoundId
	elseif type(soundId) == "table" then
		soundId = soundId.SoundId
		if typeof(soundId) == "Instance" then
			if not soundId:IsA("Sound") then
				return nil
			end
			soundId = soundId.SoundId
		end
	end

	if type(soundId) == "number" then
		if soundId ~= soundId
			or soundId <= 0
			or soundId == math.huge
			or soundId ~= math.floor(soundId) then
			return nil
		end
		soundId = string.format("%.0f", soundId)
	end

	if type(soundId) ~= "string" then
		return nil
	end

	local id = soundId:match("^rbxassetid://(%d+)$")
	if not id then
		id = soundId:match("^(%d+)$")
	end
	if not id then
		return nil
	end

	return "rbxassetid://" .. id
end
local function isAlive(
	instance: any
): boolean
	if typeof(instance) ~= "Instance" then
		return false
	end

	return instance.Parent ~= nil
		and instance:IsA("Sound")
end
local function cancelTween(
	sound: Sound
): ()
	local tween = activeTweens[sound]
	if tween then
		activeTweens[sound] = nil
		tween:Cancel()
	end
end
local function cleanup(
	sound: any
): ()
	if typeof(sound) ~= "Instance" then
		return
	end

	local target = sound :: Sound
	cancelTween(target)
	activeSounds[target] = nil
	stopping[target] = nil
	target:Stop()
	target:Destroy()
end
local function tweenVolume(
	sound: Sound,
	targetVolume: number,
	tweenTime: number
): Tween
	cancelTween(sound)

	local duration = readNumber(tweenTime, 0, 3600, 0)
	local volume = readNumber(targetVolume, 0, 10, 1)

	local tween = TweenService:Create(
		sound,
		TweenInfo.new(
			duration,
			Enum.EasingStyle.Quad,
			Enum.EasingDirection.Out
		),
		{
			Volume = volume,
		}
	)

	activeTweens[sound] = tween
	tween.Completed:Once(function()
		if activeTweens[sound] == tween then
			activeTweens[sound] = nil
		end
	end)

	tween:Play()
	return tween
end
-- Stops a sound, and with fadeTime it fades the volume to 0 before destroying it
local function stopSound(
	sound: any,
	fadeTime: any
): ()
	if typeof(sound) ~= "Instance" or not sound:IsA("Sound") then
		return
	end

	local target = sound :: Sound
	local duration = readNumber(fadeTime, 0, 3600, 0)

	if duration <= 0 or not isAlive(target) then
		cleanup(target)
		return
	end
	if stopping[target] then
		return
	end

	stopping[target] = true

	local tween = tweenVolume(target, 0, duration)
	tween.Completed:Once(function()
		cleanup(target)
	end)

	-- fallback: if the tween never completes, the sound is still destroyed
	task.delay(duration + STOP_FALLBACK_TIME, function()
		if stopping[target] then
			cleanup(target)
		end
	end)
end
local function applyProperties(
	instance: Instance,
	properties: any
): boolean
	if type(properties) ~= "table" then
		return true
	end

	local success = true
	for key, value in pairs(properties) do
		-- pcall needed: the keys come from the caller and may be invalid
		local ok = pcall(function()
			(instance :: any)[key] = value
		end)
		if not ok then
			success = false
			warn("[SoundPlayer] invalid property: " .. tostring(key))
		end
	end

	return success
end
local function createSound(
	soundId: any,
	properties: any,
	parent: Instance
): Sound?
	local normalizedId = normalizeSoundId(soundId)
	if not normalizedId then
		warn("[SoundPlayer] invalid SoundId:", typeof(soundId), tostring(soundId))
		return nil
	end

	-- SoundId and Parent cannot be overridden through args: always rbxassetid://ID
	local props: any = nil
	if type(properties) == "table" then
		props = copyTable(properties, false)
		props.SoundId = nil
		props.Parent = nil
	end

	local sound = Instance.new("Sound")
	sound.Name = normalizedId
	sound.SoundId = normalizedId
	sound.Volume = 1
	sound.PlaybackSpeed = 1
	sound.Looped = false

	if not applyProperties(sound, props) then
		sound:Destroy()
		return nil
	end

	-- pcall needed: the Parent may be locked or destroyed
	local okParent = pcall(function()
		sound.Parent = parent
	end)
	if not okParent then
		warn("[SoundPlayer] could not parent Sound")
		sound:Destroy()
		return nil
	end

	return sound
end
local function destroyWhenEnded(
	sound: Sound
): ()
	if not isAlive(sound) then
		return
	end

	local endedConnection: RBXScriptConnection?
	local ancestryConnection: RBXScriptConnection?
	local released = false

	local function disconnect(): ()
		if endedConnection then
			endedConnection:Disconnect()
			endedConnection = nil
		end
		if ancestryConnection then
			ancestryConnection:Disconnect()
			ancestryConnection = nil
		end
	end

	local function release(): ()
		if released then
			return
		end
		released = true
		disconnect()
		cleanup(sound)
	end

	endedConnection = sound.Ended:Connect(release)
	ancestryConnection = sound.AncestryChanged:Connect(function(_: Instance, newParent: Instance?)
		if newParent then
			return
		end
		release()
	end)
end
-- Fades the volume to 0 during the last "fadeOut" seconds of the sound
local function scheduleFadeOut(
	sound: Sound,
	fadeOut: number
): ()
	local function arm(): ()
		if not isAlive(sound) or sound.Looped then
			return
		end

		local speed = math.max(sound.PlaybackSpeed, 0.01)
		local remaining = (sound.TimeLength - sound.TimePosition) / speed

		task.delay(math.max(remaining - fadeOut, 0), function()
			if isAlive(sound) and not sound.Looped and not stopping[sound] then
				tweenVolume(sound, 0, fadeOut)
			end
		end)
	end

	if sound.IsLoaded then
		arm()
	else
		sound.Loaded:Once(arm)
	end
end

-- LoopedSoundPlayer (helpers)
local function makeEntry(
	id: string,
	loops: boolean,
	schedule: LoopSchedule?
): Entry
	local maxLoops: number? = nil
	local loopDelay = 0

	if type(schedule) == "table" then
		local rawMax = tonumber(schedule.MaxLoops)
		if rawMax ~= nil and rawMax == rawMax then
			maxLoops = math.floor(rawMax)
		end
		loopDelay = readNumber(schedule.LoopDelay, 0, 3600, 0)
	end

	return {
		id = id,
		loops = loops,
		maxLoops = maxLoops,
		loopDelay = loopDelay,
		iterations = 1,
	}
end
local function getStartDelay(
	self: PlayerData,
	extraDelay: number
): number
	local bpm = self.bpm
	if not self.syncPlayback or not bpm or bpm <= 0 then
		return extraDelay
	end

	-- aligns the start to the next beat of the server clock
	local now = workspace:GetServerTimeNow()
	local beatLength = 60 / bpm
	local remainder = (now + extraDelay) % beatLength
	if remainder < 0.001 then
		return extraDelay
	end

	return extraDelay + (beatLength - remainder)
end
local function disconnectLoop(
	self: PlayerData
): ()
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end
end
local function fireLoopDone(
	self: PlayerData
): ()
	self.loopCount += 1
	for _, callback in pairs(self.callbacks) do
		task.spawn(callback)
	end
end
-- The player becomes inactive and the current sound ends on its own
local function finish(
	self: PlayerData
): ()
	self.entry = nil
	self.queued = nil
	self.stopAfter = false
	self.transitioning = false
	self.rapidCount = 0
	disconnectLoop(self)
end

local step: (self: PlayerData) -> ()

-- Starts an entry (after an optional delay), crossfading from the current sound if there is one
local function startEntry(
	self: PlayerData,
	entry: Entry,
	extraDelay: number
): ()
	self.token += 1
	local token = self.token

	self.entry = entry
	self.queued = nil
	self.stopAfter = false
	self.transitioning = true

	local function begin(): ()
		if self.destroyed or self.token ~= token then
			return
		end

		if self.stopAfter then
			finish(self)
			return
		end

		local fadeTime = self.crossFadeTime
		local old = self.sound

		for other in pairs(self.outgoing) do
			if not isAlive(other) then
				self.outgoing[other] = nil
			end
		end

		local sound = createSound(
			entry.id,
			{ Volume = if fadeTime > 0 then 0 else self.volumeMultiplier },
			self.parent
		)
		if not sound then
			finish(self)
			return
		end

		destroyWhenEnded(sound)
		sound:Play()

		if old and old ~= sound then
			self.outgoing[old] = true
			stopSound(old, fadeTime)
		end
		if fadeTime > 0 then
			tweenVolume(sound, self.volumeMultiplier, fadeTime)
		end

		self.sound = sound
		self.startedAt = os.clock()
		self.transitioning = false
	end

	if not self.connection then
		self.connection = RunService.Heartbeat:Connect(function()
			-- pcall needed: if the loop fails it stops instead of spamming errors every frame
			local ok, err = pcall(function(): any
				step(self)
				return nil
			end)
			if not ok then
				warn("[SoundPlayer] error in the loop, stopping it: " .. tostring(err))
				LoopedSoundPlayer.stop(self, 0)
			end
		end)
	end

	local waitTime = getStartDelay(self, extraDelay)
	if waitTime > 0 then
		task.delay(waitTime, begin)
	else
		begin()
	end
end
local function advance(
	self: PlayerData
): ()
	local entry = self.entry
	if not entry then
		return
	end

	fireLoopDone(self)

	local queued = self.queued
	if queued then
		startEntry(self, queued, 0)
		return
	end

	if self.stopAfter then
		finish(self)
		return
	end

	local maxLoops = entry.maxLoops
	if entry.loops and (maxLoops == nil or entry.iterations < maxLoops) then
		-- protection: sounds that end instantly must not restart endlessly
		if os.clock() - self.startedAt < MIN_ITERATION_TIME then
			self.rapidCount += 1
			if self.rapidCount >= MAX_RAPID_RESTARTS then
				warn("[SoundPlayer] sound restarts too fast, stopping the loop: " .. entry.id)
				finish(self)
				return
			end
		else
			self.rapidCount = 0
		end

		entry.iterations += 1
		startEntry(self, entry, entry.loopDelay)
		return
	end

	finish(self)
end
step = function(self: PlayerData): ()
	if self.destroyed or self.transitioning then
		return
	end

	local entry = self.entry
	local sound = self.sound
	if not entry or not sound then
		return
	end

	-- the sound ended (or was destroyed): next iteration
	if not isAlive(sound) then
		advance(self)
		return
	end

	if not sound.IsLoaded then
		if os.clock() - self.startedAt > LOAD_TIMEOUT then
			warn("[SoundPlayer] sound failed to load in time: " .. sound.SoundId)
			cleanup(sound)
			self.sound = nil
			finish(self)
		end
		return
	end

	local timeLength = sound.TimeLength
	if timeLength <= 0 then
		warn("[SoundPlayer] sound loaded with zero length: " .. sound.SoundId)
		cleanup(sound)
		self.sound = nil
		finish(self)
		return
	end

	local speed = math.max(sound.PlaybackSpeed, 0.01)
	local remaining = (timeLength - sound.TimePosition) / speed

	-- only advance to the next iteration early (crossfade) if there really is one
	local maxLoops = entry.maxLoops
	local hasNext = self.queued ~= nil
		or (entry.loops and not self.stopAfter and (maxLoops == nil or entry.iterations < maxLoops))

	local window = 0
	if hasNext and entry.loopDelay <= 0 and self.crossFadeTime > 0 then
		window = math.min(self.crossFadeTime, timeLength * 0.5)
	end

	if remaining <= window then
		advance(self)
	end
end

--[[API]] --19/09/26
--[=[
	Plays a one-shot sound

	If `soundId` is an array of sources, one of them is picked at random
	The parent is resolved as: `parent` argument, then `args.Parent`, then `SoundService`
	Returns `nil` (with a warning) if the source, the parent or any property in `args` is invalid

	```lua
	local sound = SoundPlayer:play(1234567890, { Volume = 0.8, FadeIn = 0.5, FadeOut = 1 })
	SoundPlayer:play({ 111111, 222222 }, nil, workspace.Door)
	```

	@method play
	@within SoundPlayer
	@param soundId SoundSource | { SoundSource } -- Sound source or an array of sources to pick from
	@param args PlayArgs? -- Volume, fades and any other Sound property
	@param parent Instance? -- Where the sound is parented, overrides `args.Parent`
	@return Sound? -- The playing sound, or nil if it could not be created
]=]
function SoundPlayer:play(
	soundId: SoundSource | { SoundSource },
	args: PlayArgs?,
	parent: Instance?
): Sound?
	local finalSoundId: any = soundId

	if type(finalSoundId) == "table" and finalSoundId.SoundId == nil and #finalSoundId > 0 then
		finalSoundId = finalSoundId[math.random(1, #finalSoundId)]
	end

	local options: any = if type(args) == "table" then copyTable(args, false) else {}

	local finalParent: any = parent or options.Parent or SoundService
	if typeof(finalParent) ~= "Instance" then
		warn("[SoundPlayer] invalid Parent")
		return nil
	end

	local fadeIn = readNumber(options.FadeIn, 0, 3600, 0)
	local fadeOut = readNumber(options.FadeOut, 0, 3600, 0)
	local targetVolume = readNumber(options.Volume, 0, 10, 1)

	options.Parent = nil
	options.FadeIn = nil
	options.FadeOut = nil
	options.Volume = if fadeIn > 0 then 0 else targetVolume

	local sound = createSound(finalSoundId, options, finalParent)
	if not sound then
		return nil
	end

	activeSounds[sound] = true
	destroyWhenEnded(sound)
	sound:Play()

	if fadeIn > 0 then
		tweenVolume(sound, targetVolume, fadeIn)
	end
	if fadeOut > 0 and not sound.Looped then
		scheduleFadeOut(sound, fadeOut)
	end

	return sound
end
--[=[
	Stops and destroys a sound, optionally fading it out first

	Without a fade time the sound is destroyed immediately
	Calling it again on a sound that is already fading out does nothing

	@method stop
	@within SoundPlayer
	@param sound Sound -- The sound to stop
	@param fadeTime number? -- Seconds to fade the volume to 0 before destroying, from 0 to 3600
]=]
function SoundPlayer:stop(
	sound: Sound,
	fadeTime: number?
): ()
	stopSound(sound, fadeTime)
end
--[=[
	Tweens the volume of a sound

	Returns `nil` if the sound is dead, is being stopped, or `targetVolume` is not a number

	```lua
	SoundPlayer:fade(sound, 0.2, 1.5)
	```

	@method fade
	@within SoundPlayer
	@param sound Sound -- The sound to fade
	@param targetVolume number -- Target volume from 0 to 10
	@param tweenTime number? -- Duration in seconds, defaults to 0
	@return Tween? -- The running tween, or nil if the fade could not start
]=]
function SoundPlayer:fade(
	sound: Sound,
	targetVolume: number,
	tweenTime: number?
): Tween?
	if not isAlive(sound) or stopping[sound] then
		return nil
	end
	if type(targetVolume) ~= "number" then
		return nil
	end

	return tweenVolume(sound, targetVolume, readNumber(tweenTime, 0, 3600, 0))
end
--[=[
	Creates a looped sound player with crossfading between iterations and tracks

	See the LoopedSoundPlayer class for everything the returned object can do

	```lua
	local music = SoundPlayer:createLoop({ Volume = 0.6, CrossFadeTime = 1, BPM = 120, SyncPlayback = true })
	music:swapToChoice({ 111111, 222222 })
	```

	@method createLoop
	@within SoundPlayer
	@param options LoopedSoundPlayerOptions? -- Parent, volume, crossfade time, BPM and sync settings
	@return LoopedSoundPlayer? -- The new player
]=]
function SoundPlayer:createLoop(
	options: LoopedSoundPlayerOptions?
): LoopedSoundPlayer?
	return LoopedSoundPlayer.new(options)
end
--[=[
	Stops every active loop player immediately and destroys every sound created with `SoundPlayer:play`

	@method stopAll
	@within SoundPlayer
]=]
function SoundPlayer:stopAll(): ()
	for player in pairs(activePlayers) do
		LoopedSoundPlayer.stop(player, 0)
	end

	for sound in pairs(activeSounds) do
		cleanup(sound)
	end
end

--[[LoopedSoundPlayer]]
--[=[
	@class LoopedSoundPlayer

	Plays one looping entry at a time with crossfading, scheduling, queueing and optional BPM sync
	Created with `SoundPlayer:createLoop`

	An entry is a sound plus its schedule (`MaxLoops`, `LoopDelay`)
	Each time the sound finishes (or reaches its crossfade window) the player advances to
	the next iteration, to the queued entry, or becomes idle

	```lua
	local player = SoundPlayer:createLoop({ CrossFadeTime = 1 })

	player:swapToChoice({ 111111, 222222 }, { MaxLoops = 4 }) -- starts now
	player:playOnceOnLoop(333333) -- plays after the current iteration
	player:stopAfterLoop() -- cancels the queue and stops after the current iteration

	player:waitLoopDone() -- yields until the current iteration ends
	player:destroy()
	```
]=]

-- Creates a player, exposed publicly through SoundPlayer:createLoop
function LoopedSoundPlayer.new(
	options: LoopedSoundPlayerOptions?
): LoopedSoundPlayer
	local opts: any = if type(options) == "table" then options else {}

	local parent: any = opts.Parent or SoundService
	if typeof(parent) ~= "Instance" then
		warn("[SoundPlayer] invalid Parent, using SoundService")
		parent = SoundService
	end

	local rawBpm = tonumber(opts.BPM)
	local bpm: number? = nil
	if rawBpm ~= nil and rawBpm > 0 and rawBpm <= 1000 then
		bpm = rawBpm
	end

	local self: PlayerData = {
		parent = parent,
		volumeMultiplier = readNumber(opts.Volume, 0, 10, 1),
		crossFadeTime = readNumber(opts.CrossFadeTime, 0, 60, 0.5),
		bpm = bpm,
		syncPlayback = opts.SyncPlayback == true,
		entry = nil,
		queued = nil,
		sound = nil,
		outgoing = setmetatable({}, { __mode = "k" }) :: any,
		stopAfter = false,
		transitioning = false,
		token = 0,
		loopCount = 0,
		rapidCount = 0,
		callbacks = {},
		nextCallbackId = 0,
		connection = nil,
		startedAt = 0,
		destroyed = false,
	}

	setmetatable(self :: any, LoopedSoundPlayer)
	activePlayers[self] = true

	return (self :: any) :: LoopedSoundPlayer
end
--[=[
	Sets the crossfade duration used for future transitions

	Invalid values keep the current one

	@method setCrossFadeTime
	@within LoopedSoundPlayer
	@param seconds number -- Duration from 0 to 60
]=]
function LoopedSoundPlayer.setCrossFadeTime(
	self: PlayerData,
	seconds: number
): ()
	self.crossFadeTime = readNumber(seconds, 0, 60, self.crossFadeTime)
end
--[=[
	Sets the volume multiplier and smoothly applies it to the current sound (0.1 second tween)

	@method setVolumeMultiplier
	@within LoopedSoundPlayer
	@param volume number -- Volume from 0 to 10
]=]
function LoopedSoundPlayer.setVolumeMultiplier(
	self: PlayerData,
	volume: number
): ()
	self.volumeMultiplier = readNumber(volume, 0, 10, self.volumeMultiplier)

	local sound = self.sound
	if sound and isAlive(sound) and not stopping[sound] then
		tweenVolume(sound, self.volumeMultiplier, 0.1)
	end
end
--[=[
	Sets the BPM used for synced playback

	Values outside the range greater than 0 and at most 1000 (or nil) clear the BPM

	@method setBPM
	@within LoopedSoundPlayer
	@param bpm number? -- Beats per minute
]=]
function LoopedSoundPlayer.setBPM(
	self: PlayerData,
	bpm: number?
): ()
	local rawBpm = tonumber(bpm)
	if rawBpm ~= nil and rawBpm > 0 and rawBpm <= 1000 then
		self.bpm = rawBpm
	else
		self.bpm = nil
	end
end
--[=[
	Enables or disables aligning every start to the next beat of the server clock

	Requires a BPM to have any effect

	@method setSyncPlayback
	@within LoopedSoundPlayer
	@param enabled boolean -- Only `true` enables it
]=]
function LoopedSoundPlayer.setSyncPlayback(
	self: PlayerData,
	enabled: boolean
): ()
	self.syncPlayback = enabled == true
end
--[=[
	Changes the parent of future sounds and moves the current sound to it

	@method setParent
	@within LoopedSoundPlayer
	@param parent Instance -- The new parent
]=]
function LoopedSoundPlayer.setParent(
	self: PlayerData,
	parent: Instance
): ()
	if typeof(parent) ~= "Instance" then
		warn("[SoundPlayer] invalid Parent")
		return
	end

	self.parent = parent

	local sound = self.sound
	if sound and isAlive(sound) then
		-- pcall needed: the new Parent may be locked
		pcall(function()
			sound.Parent = parent
		end)
	end
end
--[=[
	Switches immediately (with crossfade) to a random option from the list and loops it

	If one of the options is already playing it is not restarted, only its schedule is
	updated and any queued entry or pending stop is cleared

	```lua
	player:swapToChoice({ 111111, 222222, 333333 }, { MaxLoops = 3, LoopDelay = 0.5 })
	```

	@method swapToChoice
	@within LoopedSoundPlayer
	@param soundIds { SoundSource } -- List of sources to pick from, invalid ones are skipped
	@param schedule LoopSchedule? -- MaxLoops and LoopDelay for the new entry
]=]
function LoopedSoundPlayer.swapToChoice(
	self: PlayerData,
	soundIds: { SoundSource },
	schedule: LoopSchedule?
): ()
	if self.destroyed then
		return
	end
	if type(soundIds) ~= "table" then
		warn("[SoundPlayer] swapToChoice expects a list of SoundIds")
		return
	end

	local ids: { string } = {}
	for _, source in ipairs(soundIds) do
		local id = normalizeSoundId(source)
		if id then
			table.insert(ids, id)
		end
	end
	if #ids == 0 then
		warn("[SoundPlayer] swapToChoice: no valid SoundId")
		return
	end

	-- if one of the options is already playing it is not restarted, only the schedule is updated
	local current = self.entry
	local currentSound = self.sound
	if current and current.loops and currentSound and isAlive(currentSound) and table.find(ids, current.id) then
		local fresh = makeEntry(current.id, true, schedule)
		current.maxLoops = fresh.maxLoops
		current.loopDelay = fresh.loopDelay
		self.queued = nil
		self.stopAfter = false
		return
	end

	startEntry(self, makeEntry(ids[math.random(1, #ids)], true, schedule), 0)
end
--[=[
	Switches to a looping sound when the current iteration ends

	Starts immediately if nothing is playing
	Only one entry can be queued, a new call replaces the previous one and cancels `stopAfterLoop`

	@method swapOnLoop
	@within LoopedSoundPlayer
	@param soundId SoundSource -- The sound to switch to
	@param schedule LoopSchedule? -- MaxLoops and LoopDelay for the new entry
]=]
function LoopedSoundPlayer.swapOnLoop(
	self: PlayerData,
	soundId: SoundSource,
	schedule: LoopSchedule?
): ()
	if self.destroyed then
		return
	end

	local id = normalizeSoundId(soundId)
	if not id then
		warn("[SoundPlayer] swapOnLoop: invalid SoundId")
		return
	end

	local entry = makeEntry(id, true, schedule)
	if not self.entry then
		startEntry(self, entry, 0)
	else
		self.queued = entry
		self.stopAfter = false
	end
end
--[=[
	Plays a sound once, immediately (with crossfade), then the player becomes idle

	@method playOnce
	@within LoopedSoundPlayer
	@param soundId SoundSource -- The sound to play
]=]
function LoopedSoundPlayer.playOnce(
	self: PlayerData,
	soundId: SoundSource
): ()
	if self.destroyed then
		return
	end

	local id = normalizeSoundId(soundId)
	if not id then
		warn("[SoundPlayer] playOnce: invalid SoundId")
		return
	end

	startEntry(self, makeEntry(id, false, nil), 0)
end
--[=[
	Plays a sound once when the current iteration ends, then the player becomes idle

	Starts immediately if nothing is playing
	Only one entry can be queued, a new call replaces the previous one and cancels `stopAfterLoop`

	@method playOnceOnLoop
	@within LoopedSoundPlayer
	@param soundId SoundSource -- The sound to play
]=]
function LoopedSoundPlayer.playOnceOnLoop(
	self: PlayerData,
	soundId: SoundSource
): ()
	if self.destroyed then
		return
	end

	local id = normalizeSoundId(soundId)
	if not id then
		warn("[SoundPlayer] playOnceOnLoop: invalid SoundId")
		return
	end

	local entry = makeEntry(id, false, nil)
	if not self.entry then
		startEntry(self, entry, 0)
	else
		self.queued = entry
		self.stopAfter = false
	end
end
--[=[
	Clears the queue and stops the player when the current iteration ends

	Does nothing if the player is idle

	@method stopAfterLoop
	@within LoopedSoundPlayer
]=]
function LoopedSoundPlayer.stopAfterLoop(
	self: PlayerData
): ()
	if not self.entry then
		return
	end

	self.queued = nil
	self.stopAfter = true
end
--[=[
	Stops the player, fading the current sound out

	With a fade time of 0 the sound and any leftover crossfade sounds are cut immediately

	@method stop
	@within LoopedSoundPlayer
	@param fadeTime number? -- Fade duration in seconds, defaults to the current crossfade time
]=]
function LoopedSoundPlayer.stop(
	self: PlayerData,
	fadeTime: number?
): ()
	self.token += 1
	self.transitioning = false
	self.entry = nil
	self.queued = nil
	self.stopAfter = false
	self.rapidCount = 0
	disconnectLoop(self)

	local duration = readNumber(fadeTime, 0, 3600, self.crossFadeTime)
	local sound = self.sound
	self.sound = nil

	if sound then
		stopSound(sound, duration)
	end

	-- immediate stop: also cut the leftover crossfade sounds
	if duration <= 0 then
		for other in pairs(self.outgoing) do
			cleanup(other)
		end
		table.clear(self.outgoing)
	end
end
--[=[
	Blocks until the current iteration ends (or the player stops or is destroyed)

	Returns immediately if the player is idle

	@method waitLoopDone
	@within LoopedSoundPlayer
	@yields
]=]
function LoopedSoundPlayer.waitLoopDone(
	self: PlayerData
): ()
	if not self.entry then
		return
	end

	local startCount = self.loopCount
	while self.entry ~= nil and self.loopCount == startCount and not self.destroyed do
		task.wait()
	end
end
--[=[
	Registers a callback that runs every time an iteration ends

	Callbacks run in their own thread through `task.spawn`

	```lua
	local disconnect = player:onLoopDone(function()
		print("iteration finished")
	end)
	disconnect()
	```

	@method onLoopDone
	@within LoopedSoundPlayer
	@param callback () -> () -- Function to call
	@return () -> () -- Call it to unregister the callback
]=]
function LoopedSoundPlayer.onLoopDone(
	self: PlayerData,
	callback: () -> ()
): () -> ()
	self.nextCallbackId += 1
	local id = self.nextCallbackId
	self.callbacks[id] = callback

	return function()
		self.callbacks[id] = nil
	end
end
--[=[
	Returns the sound that is currently playing

	@method getSound
	@within LoopedSoundPlayer
	@return Sound? -- The current sound, or nil if there is none
]=]
function LoopedSoundPlayer.getSound(
	self: PlayerData
): Sound?
	local sound = self.sound
	if sound and isAlive(sound) then
		return sound
	end

	return nil
end
--[=[
	Returns whether the player has an active entry

	This stays true during a `LoopDelay` or a synced start delay

	@method isPlaying
	@within LoopedSoundPlayer
	@return boolean -- True while an entry is active
]=]
function LoopedSoundPlayer.isPlaying(
	self: PlayerData
): boolean
	return self.entry ~= nil
end
--[=[
	Stops the player immediately and releases everything it holds

	After this, the player ignores any play or swap call

	@method destroy
	@within LoopedSoundPlayer
]=]
function LoopedSoundPlayer.destroy(
	self: PlayerData
): ()
	if self.destroyed then
		return
	end

	LoopedSoundPlayer.stop(self, 0)
	self.destroyed = true
	activePlayers[self] = nil

	for sound in pairs(self.outgoing) do
		cleanup(sound)
	end

	table.clear(self.outgoing)
	table.clear(self.callbacks)
end

-- The public API never throws: errors are caught, reported with a traceback, and nil is returned
local function protectMethods(
	class: { [string]: any },
	className: string,
	skip: { [string]: boolean }
): ()
	for name, method in pairs(class) do
		if type(method) == "function" and not skip[name] then
			local label = className .. "." .. name

			local wrapped: any = function(...)
				local results = table.pack(xpcall(method, function(err: any): string
					return debug.traceback(tostring(err), 2)
				end, ...))

				if results[1] then
					return table.unpack(results, 2, results.n)
				end

				warn("[SoundPlayer] error in " .. label .. ":\n" .. tostring(results[2]))
				return nil
			end

			class[name] = wrapped
		end
	end
end

protectMethods(SoundPlayer :: any, "SoundPlayer", {})
protectMethods(LoopedSoundPlayer, "LoopedSoundPlayer", { new = true })

return (SoundPlayer :: any) :: SoundPlayer
