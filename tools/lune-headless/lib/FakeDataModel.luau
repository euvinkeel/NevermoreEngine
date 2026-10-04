--!strict
--[[
	An event-capable fake of Roblox's Instance layer, for the "datamodel" host level.

	Lune's own Instances (@lune/roblox) have no events at all, and their built-in members can't be
	intercepted, so this replaces the Instance layer outright. It uses @lune/roblox only for datatypes
	(Vector3, CFrame, Color3, ...). Written from scratch for this runner; pigxity-games/lune-test
	(Apache-2.0) was read for ideas, no code was copied.

	What's emulated:
	- Instances are `newproxy` userdata, so `type(instance)` is "userdata" as on Roblox, and the host's
	  `typeof` override reports "Instance", "RBXScriptSignal" and "RBXScriptConnection".
	- Events: Changed (ValueBase fires the new value, other classes the property name),
	  GetPropertyChangedSignal, ChildAdded/ChildRemoved, DescendantAdded/DescendantRemoving,
	  AncestryChanged, AttributeChanged/GetAttributeChangedSignal, Destroying.
	- BindableEvent (Fire/Event, tables are copied like Roblox does) and BindableFunction
	  (Invoke/OnInvoke; Invoke waits for a callback if none is set).
	- Services: Workspace, ReplicatedStorage, ServerStorage, ServerScriptService, Players, Lighting,
	  StarterGui, StarterPack, StarterPlayer, SoundService, Chat, Teams, TestService, plus
	  RunService (IsClient/IsServer/IsStudio/IsRunning from config; Heartbeat, Stepped,
	  RenderStepped, PreRender, PreAnimation, PreSimulation, PostSimulation stepped by the host),
	  HttpService (pure JSON/GUID), CollectionService (tags, GetTagged, added/removed signals).

	Fidelity compromises are listed in tools/lune-headless/README.md ("datamodel level").
]]

local RobloxApi = require("./RobloxApi")
local RobloxPure = require("./RobloxPure")
local Scheduler = require("./Scheduler")

local FakeDataModel = {}

export type SignalMode = "deferred" | "immediate"

export type Config = {
	scheduler: Scheduler.Scheduler,
	-- "deferred" (default, like Roblox's default SignalBehavior) queues handlers with task.defer;
	-- "immediate" runs each handler at once in its own thread.
	signalMode: SignalMode?,
	isClient: boolean?,
	isServer: boolean?,
	isStudio: boolean?,
	isRunning: boolean?,
	-- Datatype constructors from @lune/roblox (Vector3, CFrame, Color3, Enum, ...).
	datatypes: { [string]: any },
	-- roblox.getReflectionDatabase() from @lune/roblox.
	reflection: any,
	-- Event and method names from the luau-lsp definitions, if available (see RobloxApi).
	api: RobloxApi.Api?,
	onStrayError: (message: string) -> (),
}

local KIND_INSTANCE = "Instance"
local KIND_SIGNAL = "RBXScriptSignal"
local KIND_CONNECTION = "RBXScriptConnection"

function FakeDataModel.new(config: Config)
	local scheduler = config.scheduler
	local taskLib = scheduler.task
	local signalMode: SignalMode = config.signalMode or "deferred"
	local D = config.datatypes

	-- object -> kind, for typeof()
	local kinds: { [any]: string } = setmetatable({}, { __mode = "k" }) :: any

	local function typeofValue(value: any): string
		return kinds[value] or typeof(value)
	end

	-- Signals ----------------------------------------------------------------------------------
	--
	-- Signals and connections are userdata (as on Roblox) with their state kept on the side.

	type SignalState = {
		name: string,
		connections: { any }, -- connection proxies, in connection order
		waiting: { thread },
		clientOnly: string?, -- set on RenderStepped/PreRender on a server: using them throws
	}
	type ConnectionState = {
		connected: boolean,
		fn: (...any) -> (),
		signal: SignalState,
	}

	local signalStates: { [any]: SignalState } = setmetatable({}, { __mode = "k" }) :: any
	local connectionStates: { [any]: ConnectionState } = setmetatable({}, { __mode = "k" }) :: any

	local function newUserdata(meta: { [string]: any }): any
		local proxy = newproxy(true)
		local proxyMeta = getmetatable(proxy)
		for key, value in meta do
			proxyMeta[key] = value
		end
		return proxy
	end

	local function runHandler(fn: (...any) -> ...any, ...: any)
		local ok, err = xpcall(fn, function(e)
			return debug.traceback(tostring(e), 2)
		end, ...)
		if not ok then
			config.onStrayError(err)
		end
	end

	local function checkUsable(state: SignalState)
		if state.clientOnly then
			error(`{state.clientOnly} event can only be used from local scripts`, 3)
		end
	end

	local function disconnect(connection: any)
		local state = connectionStates[connection]
		if not state.connected then
			return
		end
		state.connected = false
		local index = table.find(state.signal.connections, connection)
		if index then
			table.remove(state.signal.connections, index)
		end
	end

	local ConnectionMeta = {
		__index = function(self: any, key: any): any
			if key == "Connected" then
				return connectionStates[self].connected
			elseif key == "Disconnect" then
				return disconnect
			end
			error(`{tostring(key)} is not a valid member of RBXScriptConnection`, 2)
		end,
		__tostring = function(): string
			return "Connection"
		end,
		__metatable = "The metatable is locked",
	}

	local function connect(self: any, fn: (...any) -> ()): any
		local state = signalStates[self]
		checkUsable(state)
		if type(fn) ~= "function" then
			error("Attempt to connect failed: Passed value is not a function", 2)
		end
		local connection = newUserdata(ConnectionMeta)
		connectionStates[connection] = { connected = true, fn = fn, signal = state }
		kinds[connection] = KIND_CONNECTION
		table.insert(state.connections, connection)
		return connection
	end

	local SignalMethods: { [string]: (...any) -> ...any } = {
		Connect = connect,
		ConnectParallel = connect,
		Once = function(self: any, fn: (...any) -> ()): any
			checkUsable(signalStates[self])
			local connection
			connection = connect(self, function(...)
				if connectionStates[connection].connected then
					disconnect(connection)
					fn(...)
				end
			end)
			return connection
		end,
		Wait = function(self: any): ...any
			local state = signalStates[self]
			checkUsable(state)
			table.insert(state.waiting, coroutine.running())
			return coroutine.yield()
		end,
	}

	local SignalMeta = {
		__index = function(_self: any, key: any): any
			local method = SignalMethods[key]
			if method then
				return method
			end
			error(`{tostring(key)} is not a valid member of RBXScriptSignal`, 2)
		end,
		__tostring = function(self: any): string
			return "Signal " .. signalStates[self].name
		end,
		__metatable = "The metatable is locked",
	}

	local function newSignal(name: string): any
		local signal = newUserdata(SignalMeta)
		signalStates[signal] = { name = name, connections = {}, waiting = {} }
		kinds[signal] = KIND_SIGNAL
		return signal
	end

	local function resume(fnOrThread: any, ...: any)
		if signalMode == "deferred" then
			taskLib.defer(fnOrThread, ...)
		else
			taskLib.spawn(fnOrThread, ...)
		end
	end

	-- Handlers are captured when the event fires; a deferred handler still runs if its connection
	-- is disconnected before the resumption point (Destroy disconnects everything right away).
	local function fire(signal: any, ...: any)
		local state = signalStates[signal]
		if #state.connections == 0 and #state.waiting == 0 then
			return
		end
		local snapshot = table.clone(state.connections)
		local threads = table.clone(state.waiting)
		table.clear(state.waiting)
		for _, connection in snapshot do
			resume(runHandler, connectionStates[connection].fn, ...)
		end
		for _, thread in threads do
			resume(thread, ...)
		end
	end

	local function disconnectAll(signal: any)
		for _, connection in table.clone(signalStates[signal].connections) do
			disconnect(connection)
		end
	end

	-- Classes ----------------------------------------------------------------------------------
	--
	-- Class names, superclasses, NotCreatable/Service tags, scriptable properties, their types and
	-- defaults come from the reflection database bundled with @lune/roblox (rbx-dom). It has no
	-- events or methods: the events below are declared by hand, and methods are implemented further
	-- down. An event that isn't declared here is "not a valid member".

	local database = config.reflection
	local api = config.api
	local NIL = newproxy(false) -- a property explicitly holding nil

	type PropertyInfo = {
		datatype: string,
		readOnly: boolean,
		default: any, -- NIL for nil
	}
	type ClassInfo = {
		name: string,
		super: string?,
		creatable: boolean,
		service: boolean,
		properties: { [string]: PropertyInfo }, -- declared on this class only
		events: { [string]: true }, -- declared on this class only
	}

	local EVENTS: { [string]: { string } } = {
		Instance = {
			"Changed",
			"ChildAdded",
			"ChildRemoved",
			"DescendantAdded",
			"DescendantRemoving",
			"AncestryChanged",
			"AttributeChanged",
			"Destroying",
		},
		DataModel = { "Close", "Loaded" },
		BasePart = { "Touched", "TouchEnded" },
		Humanoid = {
			"Died",
			"HealthChanged",
			"StateChanged",
			"StateEnabledChanged",
			"Running",
			"Jumping",
			"Seated",
			"Climbing",
			"FreeFalling",
			"FallingDown",
			"GettingUp",
			"PlatformStanding",
			"Ragdoll",
			"Strafing",
			"Swimming",
			"MoveToFinished",
			"AnimationPlayed",
		},
		Players = { "PlayerAdded", "PlayerRemoving", "PlayerMembershipChanged" },
		Player = { "CharacterAdded", "CharacterRemoving", "CharacterAppearanceLoaded", "Chatted", "Idled" },
		Team = { "PlayerAdded", "PlayerRemoved" },
		RemoteEvent = { "OnServerEvent", "OnClientEvent" },
		UnreliableRemoteEvent = { "OnServerEvent", "OnClientEvent" },
		BindableEvent = { "Event" },
		Tool = { "Activated", "Deactivated", "Equipped", "Unequipped" },
		Sound = { "Played", "Paused", "Resumed", "Stopped", "Ended", "Loaded", "DidLoop" },
		AnimationTrack = { "Stopped", "Ended", "KeyframeReached", "DidLoop" },
		Animator = { "AnimationPlayed" },
		GuiObject = {
			"InputBegan",
			"InputChanged",
			"InputEnded",
			"MouseEnter",
			"MouseLeave",
			"MouseMoved",
			"SelectionGained",
			"SelectionLost",
		},
		GuiButton = {
			"Activated",
			"MouseButton1Click",
			"MouseButton1Down",
			"MouseButton1Up",
			"MouseButton2Click",
			"MouseButton2Down",
			"MouseButton2Up",
		},
		TextBox = { "FocusLost", "Focused", "ReturnPressedFromOnScreenKeyboard" },
		ProximityPrompt = {
			"Triggered",
			"TriggerEnded",
			"PromptButtonHoldBegan",
			"PromptButtonHoldEnded",
			"PromptShown",
			"PromptHidden",
		},
		ClickDetector = { "MouseClick", "RightMouseClick", "MouseHoverEnter", "MouseHoverLeave" },
		Camera = { "InterpolationFinished" },
		RunService = {
			"Heartbeat",
			"Stepped",
			"RenderStepped",
			"PreRender",
			"PreAnimation",
			"PreSimulation",
			"PostSimulation",
		},
		CollectionService = { "TagAdded", "TagRemoved" },
		UserInputService = {
			"InputBegan",
			"InputChanged",
			"InputEnded",
			"LastInputTypeChanged",
			"TextBoxFocused",
			"TextBoxFocusReleased",
			"WindowFocused",
			"WindowFocusReleased",
		},
		GuiService = { "MenuOpened", "MenuClosed" },
		LogService = { "MessageOut" },
		ScriptContext = { "Error" },
	}

	-- A default for a property the database has no default for (most often on NotCreatable classes).
	local function typeDefault(datatype: string): any
		if datatype == "Bool" then
			return false
		elseif datatype == "Float32" or datatype == "Float64" or datatype == "Int32" or datatype == "Int64" then
			return 0
		elseif datatype == "String" or datatype == "Content" or datatype == "ContentId" then
			return ""
		elseif string.sub(datatype, 1, 5) == "Enum." then
			local enum = D.Enum[string.sub(datatype, 6)]
			return enum and enum:GetEnumItems()[1] or NIL
		elseif D[datatype] and D[datatype].new and datatype ~= "BrickColor" then
			local ok, value = pcall(D[datatype].new)
			return if ok then value else NIL
		end
		return NIL
	end

	local classes: { [string]: ClassInfo } = {}
	local missingClasses: { [string]: true } = {}

	-- Builds and caches what this runner needs from a reflection class. nil if there's no such class.
	local function classInfo(name: string): ClassInfo?
		local cached = classes[name]
		if cached or missingClasses[name] then
			return cached
		end
		local reflected = database:GetClass(name)
		if not reflected then
			missingClasses[name] = true
			return nil
		end
		local info: ClassInfo = {
			name = name,
			super = reflected.Superclass,
			creatable = not table.find(reflected.Tags, "NotCreatable"),
			service = table.find(reflected.Tags, "Service") ~= nil,
			properties = {},
			events = {},
		}
		local defaults = reflected.DefaultProperties
		for propertyName, property in reflected.Properties do
			local scriptability = property.Scriptability
			if
				(scriptability == "ReadWrite" or scriptability == "Read")
				and propertyName ~= "Name"
				and propertyName ~= "Parent"
			then
				local default = defaults[propertyName]
				info.properties[propertyName] = {
					datatype = property.Datatype,
					readOnly = scriptability == "Read",
					default = if default == nil then typeDefault(property.Datatype) else default,
				}
			end
		end
		local declaredEvents: { string } = EVENTS[name] or {}
		for _, event in declaredEvents do
			info.events[event] = true
		end
		classes[name] = info
		return info
	end

	local function isA(className: string, ancestor: string): boolean
		local current: string? = className
		while current do
			if current == ancestor then
				return true
			end
			local info = classInfo(current)
			current = info and info.super
		end
		return false
	end

	local function findProperty(className: string, property: string): PropertyInfo?
		local current: string? = className
		while current do
			local info = classInfo(current)
			if not info then
				return nil
			end
			local found = info.properties[property]
			if found then
				return found
			end
			current = info.super
		end
		return nil
	end

	local function hasEvent(className: string, event: string): boolean
		local current: string? = className
		while current do
			local info = classInfo(current)
			if not info then
				return false
			end
			if info.events[event] then
				return true
			end
			local apiClass = api and api[current]
			if apiClass and apiClass.events[event] then
				return true
			end
			current = info.super
		end
		return false
	end

	-- "method" or "property" when the real class has a member by that name that this fake doesn't
	-- implement (per the definitions file); nil otherwise.
	local function unemulatedMember(className: string, key: string): string?
		if not api then
			return nil
		end
		local current: string? = className
		while current do
			local apiClass = api[current]
			if apiClass then
				if apiClass.methods[key] then
					return "method"
				elseif apiClass.properties[key] then
					return "property"
				end
				current = apiClass.superclass
			else
				local info = classInfo(current)
				current = info and info.super
			end
		end
		return nil
	end

	local function float32(value: number): number
		return (string.unpack("<f", string.pack("<f", value)))
	end

	-- Checks and converts a value written to a property, the way Roblox does for these types.
	local function coerce(key: string, info: PropertyInfo, value: any): any
		local datatype = info.datatype
		local function bad(expected: string)
			error(`Unable to assign property {key}. {expected} expected, got {typeofValue(value)}`, 4)
		end
		if datatype == "Ref" then
			if value == nil then
				return NIL
			end
			if kinds[value] ~= KIND_INSTANCE then
				bad("Instance")
			end
			return value
		elseif datatype == "Bool" then
			if value == nil then
				return false
			elseif type(value) ~= "boolean" then
				bad("bool")
			end
			return value
		elseif datatype == "String" or datatype == "Content" or datatype == "ContentId" then
			if type(value) == "number" then
				return tostring(value)
			elseif type(value) ~= "string" then
				bad("string")
			end
			return value
		elseif datatype == "Float32" or datatype == "Float64" or datatype == "Int32" or datatype == "Int64" then
			local number = if type(value) == "string" then tonumber(value) else value
			if type(number) ~= "number" then
				bad("number")
			end
			return if datatype == "Float32" then float32(number) else number
		elseif string.sub(datatype, 1, 5) == "Enum." then
			local enumName = string.sub(datatype, 6)
			local enum = D.Enum[enumName]
			if typeof(value) == "EnumItem" then
				if value.EnumType ~= enum then
					error(`Unable to assign property {key}. Expected Enum.{enumName}, got {tostring(value)}`, 4)
				end
				return value
			end
			for _, item in enum:GetEnumItems() do
				if item.Value == value or item.Name == value then
					return item
				end
			end
			bad(`Enum.{enumName}`)
		end
		if D[datatype] and typeofValue(value) ~= datatype then
			bad(datatype)
		end
		return value
	end

	-- Instances --------------------------------------------------------------------------------

	type State = {
		className: string,
		name: string,
		parent: any,
		children: { any },
		properties: { [string]: any }, -- written values only (NIL for nil); reads fall back to defaults
		attributes: { [string]: any },
		tags: { [string]: boolean },
		signals: { [string]: any },
		propertySignals: { [string]: any },
		attributeSignals: { [string]: any },
		destroyed: boolean,
		parentLocked: boolean,
		callbacks: { [string]: any },
	}

	local stateOf: { [any]: State } = setmetatable({}, { __mode = "k" }) :: any
	local InstanceMeta: any = {}
	local Methods: { [string]: (...any) -> ...any } = {}

	local game: any -- the DataModel, created below
	local collection: any -- CollectionService internals, set below
	local onTagPresence: (instance: any, tag: string, present: boolean) -> () = function() end

	local function stateFor(instance: any): State
		local state = stateOf[instance]
		if not state then
			error("Expected an Instance", 3)
		end
		return state
	end

	-- (true, value) if `key` is a scriptable property of the instance's class.
	local function readProperty(state: State, key: string): (boolean, any)
		local value = state.properties[key]
		if value == nil then
			local info = findProperty(state.className, key)
			if not info then
				return false, nil
			end
			value = info.default
		end
		if value == NIL then
			return true, nil
		end
		return true, value
	end

	local function getSignal(state: State, name: string): any
		local signal = state.signals[name]
		if not signal then
			signal = newSignal(state.name .. "." .. name)
			state.signals[name] = signal
		end
		return signal
	end

	local function firePropertyChanged(instance: any, state: State, property: string, value: any)
		local propertySignal = state.propertySignals[property]
		if propertySignal then
			fire(propertySignal)
		end
		local changed = state.signals.Changed
		if changed then
			if isA(state.className, "ValueBase") and property == "Value" then
				fire(changed, value)
			elseif not isA(state.className, "ValueBase") then
				fire(changed, property)
			end
		end
	end

	local function newInstance(className: string): any
		local proxy = newproxy(true)
		local meta = getmetatable(proxy)
		for key, value in InstanceMeta do
			meta[key] = value
		end
		local properties = {}
		stateOf[proxy] = {
			className = className,
			name = className,
			parent = nil,
			children = {},
			properties = properties,
			attributes = {},
			tags = {},
			signals = {},
			propertySignals = {},
			attributeSignals = {},
			destroyed = false,
			parentLocked = false,
			callbacks = {},
		}
		kinds[proxy] = KIND_INSTANCE
		return proxy
	end

	local function eachDescendant(instance: any, fn: (any) -> ())
		for _, child in stateOf[instance].children do
			fn(child)
			eachDescendant(child, fn)
		end
	end

	local function isDescendantOf(instance: any, ancestor: any): boolean
		local current = stateOf[instance].parent
		while current do
			if current == ancestor then
				return true
			end
			current = stateOf[current].parent
		end
		return false
	end

	local function inDataModel(instance: any): boolean
		return instance == game or isDescendantOf(instance, game)
	end

	local function setParent(instance: any, state: State, newParent: any)
		if state.parentLocked then
			error(
				`The Parent property of {state.name} is locked, current parent: {if state.parent
					then stateOf[state.parent].name
					else "NULL"}, new parent {if newParent then stateOf[newParent].name else "NULL"}`,
				3
			)
		end
		local oldParent = state.parent
		if oldParent == newParent then
			return
		end
		if newParent ~= nil then
			if not stateOf[newParent] then
				error("Invalid value for Parent: expected an Instance", 3)
			end
			if newParent == instance or isDescendantOf(newParent, instance) then
				error(
					`Attempt to set parent of {state.name} to {stateOf[newParent].name} would result in circular reference`,
					3
				)
			end
		end
		local wasInDataModel = inDataModel(instance)

		local moved = { instance }
		eachDescendant(instance, function(d)
			table.insert(moved, d)
		end)

		-- DescendantRemoving fires on the old ancestors before the move.
		local ancestor = oldParent
		while ancestor do
			local ancestorState = stateOf[ancestor]
			if ancestorState.signals.DescendantRemoving then
				for _, d in moved do
					fire(ancestorState.signals.DescendantRemoving, d)
				end
			end
			ancestor = ancestorState.parent
		end

		if oldParent then
			local siblings = stateOf[oldParent].children
			local index = table.find(siblings, instance)
			if index then
				table.remove(siblings, index)
			end
		end
		state.parent = newParent
		if newParent then
			table.insert(stateOf[newParent].children, instance)
		end

		if oldParent and stateOf[oldParent].signals.ChildRemoved then
			fire(stateOf[oldParent].signals.ChildRemoved, instance)
		end
		if newParent and stateOf[newParent].signals.ChildAdded then
			fire(stateOf[newParent].signals.ChildAdded, instance)
		end
		ancestor = newParent
		while ancestor do
			local ancestorState = stateOf[ancestor]
			if ancestorState.signals.DescendantAdded then
				for _, d in moved do
					fire(ancestorState.signals.DescendantAdded, d)
				end
			end
			ancestor = ancestorState.parent
		end
		for _, d in moved do
			local s = stateOf[d]
			if s.signals.AncestryChanged then
				fire(s.signals.AncestryChanged, instance, newParent)
			end
		end
		firePropertyChanged(instance, state, "Parent", newParent)

		local nowInDataModel = inDataModel(instance)
		if wasInDataModel ~= nowInDataModel then
			for _, d in moved do
				for tag in stateOf[d].tags do
					onTagPresence(d, tag, nowInDataModel)
				end
			end
		end
	end

	local function validateAttribute(name: any, value: any)
		if type(name) ~= "string" then
			error("Attribute name must be a string", 3)
		end
		if #name > 100 or not string.match(name, "^[%w_]+$") or string.sub(name, 1, 3) == "RBX" then
			error(`Attribute name '{name}' is not valid`, 3)
		end
		local kind = typeofValue(value)
		local allowed = {
			["nil"] = true,
			boolean = true,
			number = true,
			string = true,
			UDim = true,
			UDim2 = true,
			BrickColor = true,
			Color3 = true,
			Vector2 = true,
			Vector3 = true,
			CFrame = true,
			NumberSequence = true,
			ColorSequence = true,
			NumberRange = true,
			Rect = true,
			Font = true,
			EnumItem = true,
		}
		if not allowed[kind] then
			if kind == "table" then
				error("Table types are not supported", 3)
			end
			error(`{kind} is not a supported attribute type`, 3)
		end
	end

	-- Roblox copies tables passed through Bindables (no metatables, Instances kept).
	local function copyForBindable(value: any, seen: { [any]: any }?): any
		if type(value) ~= "table" then
			return value
		end
		local visited = seen or {}
		if visited[value] then
			return visited[value]
		end
		local copy = {}
		visited[value] = copy
		for k, v in value do
			copy[copyForBindable(k, visited)] = copyForBindable(v, visited)
		end
		return copy
	end
	local function copyArgs(...: any): ...any
		local args = table.pack(...)
		for i = 1, args.n do
			args[i] = copyForBindable(args[i])
		end
		return table.unpack(args, 1, args.n)
	end

	function Methods.GetFullName(self: any): string
		if self == game then
			return stateOf[self].name
		end
		local parts = {}
		local current = self
		while current and current ~= game do
			table.insert(parts, 1, stateOf[current].name)
			current = stateOf[current].parent
		end
		return table.concat(parts, ".")
	end
	function Methods.FindFirstChild(self: any, name: string, recursive: boolean?): any
		for _, child in stateFor(self).children do
			if stateOf[child].name == name then
				return child
			end
		end
		if recursive then
			for _, child in stateOf[self].children do
				local found = Methods.FindFirstChild(child, name, true)
				if found then
					return found
				end
			end
		end
		return nil
	end
	function Methods.FindFirstChildOfClass(self: any, className: string): any
		for _, child in stateFor(self).children do
			if stateOf[child].className == className then
				return child
			end
		end
		return nil
	end
	function Methods.FindFirstChildWhichIsA(self: any, className: string, recursive: boolean?): any
		for _, child in stateFor(self).children do
			if isA(stateOf[child].className, className) then
				return child
			end
		end
		if recursive then
			for _, child in stateOf[self].children do
				local found = Methods.FindFirstChildWhichIsA(child, className, true)
				if found then
					return found
				end
			end
		end
		return nil
	end
	function Methods.FindFirstAncestor(self: any, name: string): any
		local current = stateFor(self).parent
		while current do
			if stateOf[current].name == name then
				return current
			end
			current = stateOf[current].parent
		end
		return nil
	end
	function Methods.FindFirstAncestorOfClass(self: any, className: string): any
		local current = stateFor(self).parent
		while current do
			if stateOf[current].className == className then
				return current
			end
			current = stateOf[current].parent
		end
		return nil
	end
	function Methods.FindFirstAncestorWhichIsA(self: any, className: string): any
		local current = stateFor(self).parent
		while current do
			if isA(stateOf[current].className, className) then
				return current
			end
			current = stateOf[current].parent
		end
		return nil
	end
	function Methods.WaitForChild(self: any, name: string, timeout: number?): any
		local found = Methods.FindFirstChild(self, name)
		if found then
			return found
		end
		local thread = coroutine.running()
		local done = false
		local connection
		connection = Methods.GetSignalFor(self, "ChildAdded"):Connect(function(child)
			if not done and stateOf[child].name == name then
				done = true
				connection:Disconnect()
				taskLib.spawn(thread, child)
			end
		end)
		if timeout then
			taskLib.delay(timeout, function()
				if not done then
					done = true
					connection:Disconnect()
					taskLib.spawn(thread, nil)
				end
			end)
		end
		return coroutine.yield()
	end
	function Methods.GetChildren(self: any): { any }
		return table.clone(stateFor(self).children)
	end
	function Methods.GetDescendants(self: any): { any }
		local list = {}
		eachDescendant(self, function(d)
			table.insert(list, d)
		end)
		return list
	end
	function Methods.ClearAllChildren(self: any)
		for _, child in table.clone(stateFor(self).children) do
			child:Destroy()
		end
	end
	function Methods.IsA(self: any, className: string): boolean
		return isA(stateFor(self).className, className)
	end
	function Methods.IsDescendantOf(self: any, ancestor: any): boolean
		if ancestor == nil then
			return false
		end
		return isDescendantOf(self, ancestor)
	end
	function Methods.IsAncestorOf(self: any, descendant: any): boolean
		return descendant ~= nil and isDescendantOf(descendant, self)
	end
	function Methods.GetPropertyChangedSignal(self: any, property: string): any
		local state = stateFor(self)
		if
			property ~= "Name"
			and property ~= "Parent"
			and property ~= "ClassName"
			and not findProperty(state.className, property)
		then
			error(`{property} is not a valid property name.`, 2)
		end
		local signal = state.propertySignals[property]
		if not signal then
			signal = newSignal(state.name .. "." .. property .. "Changed")
			state.propertySignals[property] = signal
		end
		return signal
	end
	function Methods.GetAttribute(self: any, name: string): any
		return stateFor(self).attributes[name]
	end
	function Methods.GetAttributes(self: any): { [string]: any }
		return table.clone(stateFor(self).attributes)
	end
	function Methods.SetAttribute(self: any, name: string, value: any)
		local state = stateFor(self)
		validateAttribute(name, value)
		if state.attributes[name] == value then
			return
		end
		state.attributes[name] = value
		if state.attributeSignals[name] then
			fire(state.attributeSignals[name])
		end
		if state.signals.AttributeChanged then
			fire(state.signals.AttributeChanged, name)
		end
	end
	function Methods.GetAttributeChangedSignal(self: any, name: string): any
		local state = stateFor(self)
		local signal = state.attributeSignals[name]
		if not signal then
			signal = newSignal(state.name .. ".Attribute." .. name)
			state.attributeSignals[name] = signal
		end
		return signal
	end
	function Methods.AddTag(self: any, tag: string)
		local state = stateFor(self)
		if not state.tags[tag] then
			state.tags[tag] = true
			if inDataModel(self) then
				onTagPresence(self, tag, true)
			end
		end
	end
	function Methods.RemoveTag(self: any, tag: string)
		local state = stateFor(self)
		if state.tags[tag] then
			state.tags[tag] = nil
			if inDataModel(self) then
				onTagPresence(self, tag, false)
			end
		end
	end
	function Methods.HasTag(self: any, tag: string): boolean
		return stateFor(self).tags[tag] == true
	end
	function Methods.GetTags(self: any): { string }
		local tags = {}
		for tag in stateFor(self).tags do
			table.insert(tags, tag)
		end
		table.sort(tags)
		return tags
	end
	function Methods.Destroy(self: any)
		local state = stateFor(self)
		if state.destroyed then
			return
		end
		if state.signals.Destroying then
			fire(state.signals.Destroying)
		end
		for _, child in table.clone(state.children) do
			Methods.Destroy(child)
		end
		state.parentLocked = false
		setParent(self, state, nil)
		state.parentLocked = true
		state.destroyed = true
		for _, signal in state.signals do
			disconnectAll(signal)
		end
		for _, signal in state.propertySignals do
			disconnectAll(signal)
		end
		for _, signal in state.attributeSignals do
			disconnectAll(signal)
		end
	end
	function Methods.Remove(self: any)
		setParent(self, stateFor(self), nil)
	end
	function Methods.Clone(self: any): any
		local state = stateFor(self)
		if not select(2, readProperty(state, "Archivable")) then
			return nil
		end
		local map: { [any]: any } = {}
		local function cloneTree(source: any): any
			local sourceState = stateOf[source]
			local copy = newInstance(sourceState.className)
			local copyState = stateOf[copy]
			copyState.name = sourceState.name
			for k, v in sourceState.properties do
				copyState.properties[k] = v
			end
			copyState.attributes = table.clone(sourceState.attributes)
			copyState.tags = table.clone(sourceState.tags)
			map[source] = copy
			for _, child in sourceState.children do
				if select(2, readProperty(stateOf[child], "Archivable")) then
					local childCopy = cloneTree(child)
					stateOf[childCopy].parent = copy
					table.insert(copyState.children, childCopy)
				end
			end
			return copy
		end
		local root = cloneTree(self)
		-- References inside the cloned tree point at the clones.
		for _, copy in map do
			local properties = stateOf[copy].properties
			for k, v in properties do
				if map[v] then
					properties[k] = map[v]
				end
			end
		end
		return root
	end
	function Methods.GetActor(_self: any): any
		return nil
	end
	function Methods.GetPivot(self: any): any
		local state = stateFor(self)
		local hasCFrame, cframe = readProperty(state, "CFrame")
		if hasCFrame and isA(state.className, "BasePart") then
			return cframe
		end
		local hasPivot, pivot = readProperty(state, "WorldPivot")
		return if hasPivot then pivot else D.CFrame.new()
	end
	function Methods.PivotTo(self: any, cframe: any)
		local state = stateFor(self)
		if isA(state.className, "BasePart") then
			self.CFrame = cframe
		elseif findProperty(state.className, "WorldPivot") then
			self.WorldPivot = cframe
		end
	end
	-- Internal: event by name with the same lookup as `instance.Event`.
	function Methods.GetSignalFor(self: any, name: string): any
		return getSignal(stateFor(self), name)
	end

	-- Class-specific methods.
	local ClassMethods: { [string]: { [string]: (...any) -> ...any } } = {
		BindableEvent = {
			Fire = function(self: any, ...: any)
				fire(getSignal(stateFor(self), "Event"), copyArgs(...))
			end,
		},
		BindableFunction = {
			Invoke = function(self: any, ...: any): ...any
				local state = stateFor(self)
				local callback = state.callbacks.OnInvoke
				while not callback do
					-- Roblox waits until a callback is set.
					getSignal(state, "__OnInvokeSet"):Wait()
					callback = state.callbacks.OnInvoke
				end
				local results = table.pack(callback(copyArgs(...)))
				return copyArgs(table.unpack(results, 1, results.n))
			end,
		},
	}
	local CALLBACKS =
		{ OnInvoke = "BindableFunction", OnServerInvoke = "RemoteFunction", OnClientInvoke = "RemoteFunction" }

	local function methodFor(className: string, key: string): any
		local current: string? = className
		while current do
			local methods = ClassMethods[current]
			if methods and methods[key] then
				return methods[key]
			end
			local info = classInfo(current)
			current = info and info.super
		end
		return Methods[key]
	end

	InstanceMeta.__index = function(self: any, key: any): any
		local state = stateOf[self]
		if key == "Name" then
			return state.name
		elseif key == "Parent" then
			return state.parent
		elseif key == "ClassName" then
			return state.className
		end
		local isProperty, value = readProperty(state, key)
		if isProperty then
			return value
		end
		if CALLBACKS[key] and isA(state.className, CALLBACKS[key]) then
			error(
				`{key} is a callback member of {state.className}; you can only set the callback value, get is not available`,
				2
			)
		end
		local method = methodFor(state.className, key)
		if method and key ~= "GetSignalFor" then
			return method
		end
		if hasEvent(state.className, key) then
			return getSignal(state, key)
		end
		local unemulated = unemulatedMember(state.className, key)
		if unemulated == "method" then
			return function()
				error(`[lune-headless] {state.className}:{key}() is not emulated at host level "datamodel"`, 2)
			end
		elseif unemulated == "property" then
			error(`[lune-headless] {state.className}.{key} is not emulated at host level "datamodel"`, 2)
		end
		for _, child in state.children do
			if stateOf[child].name == key then
				return child
			end
		end
		error(`{tostring(key)} is not a valid member of {state.className} "{Methods.GetFullName(self)}"`, 2)
	end

	InstanceMeta.__newindex = function(self: any, key: any, value: any)
		local state = stateOf[self]
		if key == "Parent" then
			setParent(self, state, value)
			return
		elseif key == "Name" then
			if type(value) ~= "string" and type(value) ~= "number" then
				error("Invalid value for Name: expected a string", 2)
			end
			local name = tostring(value)
			if state.name ~= name then
				state.name = name
				firePropertyChanged(self, state, "Name", name)
			end
			return
		elseif key == "ClassName" then
			error("Unable to assign property ClassName. Property is read only", 2)
		end
		if CALLBACKS[key] and isA(state.className, CALLBACKS[key]) then
			state.callbacks[key] = value
			local setSignal = state.signals.__OnInvokeSet
			if setSignal and value ~= nil then
				fire(setSignal)
			end
			return
		end
		local info = findProperty(state.className, key)
		if not info then
			if unemulatedMember(state.className, key) == "property" then
				error(`[lune-headless] {state.className}.{key} is not emulated at host level "datamodel"`, 2)
			end
			error(`{tostring(key)} is not a valid member of {state.className} "{Methods.GetFullName(self)}"`, 2)
		end
		if info.readOnly then
			error(`Unable to assign property {key}. Property is read only`, 2)
		end
		local stored = coerce(key, info, value)
		local _, old = readProperty(state, key)
		local new = if stored == NIL then nil else stored
		state.properties[key] = stored
		if old ~= new then
			firePropertyChanged(self, state, key, new)
			-- Keep BasePart Position and CFrame in step.
			if isA(state.className, "BasePart") then
				if key == "CFrame" then
					state.properties.Position = new.Position
					firePropertyChanged(self, state, "Position", new.Position)
				elseif key == "Position" then
					local _, cframe = readProperty(state, "CFrame")
					cframe = cframe - cframe.Position + new
					state.properties.CFrame = cframe
					firePropertyChanged(self, state, "CFrame", cframe)
				end
			end
		end
	end

	InstanceMeta.__tostring = function(self: any): string
		return stateOf[self].name
	end
	InstanceMeta.__metatable = "The metatable is locked"

	-- Instance.new ------------------------------------------------------------------------------

	local InstanceLib = {}
	function InstanceLib.new(className: string, parent: any?): any
		local info = if type(className) == "string" then classInfo(className) else nil
		if not info or not info.creatable then
			error(`Unable to create an Instance of type "{tostring(className)}"`, 2)
		end
		local instance = newInstance(className)
		if parent ~= nil then
			instance.Parent = parent
		end
		return instance
	end
	function InstanceLib.fromExisting(existing: any): any
		local copy = newInstance(stateFor(existing).className)
		for k, v in stateOf[existing].properties do
			stateOf[copy].properties[k] = v
		end
		stateOf[copy].name = stateOf[existing].name
		return copy
	end

	-- DataModel and services --------------------------------------------------------------------

	game = newInstance("DataModel")
	stateOf[game].name = "Game"
	local services: { [string]: any } = {}

	local function makeService(name: string): any
		local service = newInstance(name)
		stateOf[service].name = name
		local state = stateOf[service]
		state.parent = game
		table.insert(stateOf[game].children, service)
		services[name] = service
		return service
	end

	local workspace = makeService("Workspace")
	local camera = newInstance("Camera")
	camera.Name = "Camera"
	camera.Parent = workspace
	stateOf[workspace].properties.CurrentCamera = camera
	local terrain = newInstance("Terrain")
	terrain.Name = "Terrain"
	terrain.Parent = workspace
	stateOf[workspace].properties.Terrain = terrain

	-- RunService
	local runService = makeService("RunService")
	local runConfig = {
		isClient = if config.isClient ~= nil then config.isClient else false,
		isServer = if config.isServer ~= nil then config.isServer else true,
		isStudio = if config.isStudio ~= nil then config.isStudio else false,
		isRunning = if config.isRunning ~= nil then config.isRunning else true,
	}
	local renderSteps: { { name: string, priority: number, fn: (number) -> () } } = {}
	ClassMethods.RunService = {
		IsClient = function()
			return runConfig.isClient
		end,
		IsServer = function()
			return runConfig.isServer
		end,
		IsStudio = function()
			return runConfig.isStudio
		end,
		IsRunning = function()
			return runConfig.isRunning
		end,
		IsRunMode = function()
			return runConfig.isRunning and runConfig.isStudio
		end,
		IsEdit = function()
			return not runConfig.isRunning
		end,
		-- On a server this binds without erroring and never runs the callback, as on Roblox.
		BindToRenderStep = function(_self: any, name: string, priority: number, fn: (number) -> ())
			table.insert(renderSteps, { name = name, priority = priority, fn = fn })
			table.sort(renderSteps, function(a, b)
				return a.priority < b.priority
			end)
		end,
		UnbindFromRenderStep = function(_self: any, name: string)
			for i, step in renderSteps do
				if step.name == name then
					table.remove(renderSteps, i)
					return
				end
			end
		end,
	}

	if not runConfig.isClient then
		for _, name in { "RenderStepped", "PreRender" } do
			signalStates[getSignal(stateOf[runService], name)].clientOnly = name
		end
	end

	-- HttpService (pure)
	local httpService = makeService("HttpService")
	ClassMethods.HttpService = {
		JSONEncode = RobloxPure.HttpService.JSONEncode :: any,
		JSONDecode = RobloxPure.HttpService.JSONDecode :: any,
		GenerateGUID = RobloxPure.HttpService.GenerateGUID :: any,
		UrlEncode = RobloxPure.HttpService.UrlEncode :: any,
	}
	local _ = httpService

	-- CollectionService
	local collectionService = makeService("CollectionService")
	collection = {
		tagged = {} :: { [string]: { any } },
		added = {} :: { [string]: any },
		removed = {} :: { [string]: any },
	}
	onTagPresence = function(instance: any, tag: string, present: boolean)
		local list = collection.tagged[tag]
		if not list then
			list = {}
			collection.tagged[tag] = list
		end
		local index = table.find(list, instance)
		if present and not index then
			table.insert(list, instance)
			if collection.added[tag] then
				fire(collection.added[tag], instance)
			end
		elseif not present and index then
			table.remove(list, index)
			if collection.removed[tag] then
				fire(collection.removed[tag], instance)
			end
		end
	end
	ClassMethods.CollectionService = {
		AddTag = function(_self: any, instance: any, tag: string)
			Methods.AddTag(instance, tag)
		end,
		RemoveTag = function(_self: any, instance: any, tag: string)
			Methods.RemoveTag(instance, tag)
		end,
		HasTag = function(_self: any, instance: any, tag: string)
			return Methods.HasTag(instance, tag)
		end,
		GetTags = function(_self: any, instance: any)
			return Methods.GetTags(instance)
		end,
		GetTagged = function(_self: any, tag: string)
			return table.clone(collection.tagged[tag] or {})
		end,
		GetAllTags = function()
			local tags = {}
			for tag, list in collection.tagged do
				if #list > 0 then
					table.insert(tags, tag)
				end
			end
			table.sort(tags)
			return tags
		end,
		GetInstanceAddedSignal = function(_self: any, tag: string)
			collection.added[tag] = collection.added[tag] or newSignal("InstanceAdded." .. tag)
			return collection.added[tag]
		end,
		GetInstanceRemovedSignal = function(_self: any, tag: string)
			collection.removed[tag] = collection.removed[tag] or newSignal("InstanceRemoved." .. tag)
			return collection.removed[tag]
		end,
	}
	local _ = collectionService

	for _, name in
		{
			"ReplicatedStorage",
			"ReplicatedFirst",
			"ServerStorage",
			"ServerScriptService",
			"Players",
			"Lighting",
			"StarterGui",
			"StarterPack",
			"StarterPlayer",
			"SoundService",
			"Chat",
			"Teams",
			"TestService",
		}
	do
		makeService(name)
	end

	ClassMethods.DataModel = {
		GetService = function(_self: any, name: string): any
			local service = services[name]
			if service then
				return service
			end
			local info = if type(name) == "string" then classInfo(name) else nil
			if info and info.service then
				return makeService(name)
			end
			error(`'{tostring(name)}' is not a valid Service name`, 2)
		end,
		FindService = function(_self: any, name: string): any
			return services[name]
		end,
		IsLoaded = function()
			return true
		end,
		BindToClose = function() end,
	}
	-- ReflectionService, answered from the reflection database (classes, properties) and the
	-- definitions file (events, methods). Members are { Name, Owner } plus, for properties, Type
	-- and Permits. Permits values are `true` placeholders, not SecurityCapability values.
	local function reflectedClassChain(className: string, filter: any?): { string }?
		if type(className) ~= "string" or not classInfo(className) then
			return nil
		end
		local chain = {}
		local current: string? = className
		while current do
			table.insert(chain, current)
			if filter and filter.ExcludeInherited then
				break
			end
			local info = classInfo(current)
			current = info and info.super
		end
		return chain
	end
	ClassMethods.ReflectionService = {
		GetClass = function(_self: any, className: string, _filter: any?): any
			local info = if type(className) == "string" then classInfo(className) else nil
			if not info then
				return nil
			end
			return {
				Name = info.name,
				Superclass = info.super,
				Permits = {
					New = if info.creatable then true else nil,
					GetService = if info.service then true else nil,
				},
			}
		end,
		GetPropertiesOfClass = function(_self: any, className: string, filter: any?): any
			local chain = reflectedClassChain(className, filter)
			if not chain then
				return nil
			end
			local list: { any } = {}
			for _, owner in chain do
				local info = classInfo(owner) :: ClassInfo
				for name, property in info.properties do
					table.insert(list, {
						Name = name,
						Owner = owner,
						Type = property.datatype,
						Permits = { Read = true, Write = if property.readOnly then nil else true },
					})
				end
				if owner == "Instance" then
					for _, name in { "Name", "Parent" } do
						table.insert(list, { Name = name, Owner = owner, Permits = { Read = true, Write = true } })
					end
					table.insert(list, { Name = "ClassName", Owner = owner, Permits = { Read = true } })
				end
			end
			return list
		end,
		GetEventsOfClass = function(_self: any, className: string, filter: any?): any
			local chain = reflectedClassChain(className, filter)
			if not chain then
				return nil
			end
			local list = {}
			local seen = {}
			for _, owner in chain do
				local names = {}
				for name in (classInfo(owner) :: ClassInfo).events do
					table.insert(names, name)
				end
				local apiClass = api and api[owner]
				if apiClass then
					for name in apiClass.events do
						table.insert(names, name)
					end
				end
				for _, name in names do
					if not seen[name] then
						seen[name] = true
						table.insert(list, { Name = name, Owner = owner })
					end
				end
			end
			return list
		end,
		GetMethodsOfClass = function(_self: any, className: string, filter: any?): any
			local chain = reflectedClassChain(className, filter)
			if not chain then
				return nil
			end
			local list = {}
			local seen = {}
			for _, owner in chain do
				local names = {}
				local emulated: { [string]: any } = ClassMethods[owner] or {}
				for name in emulated do
					table.insert(names, name)
				end
				if owner == "Instance" then
					for name in Methods do
						if name ~= "GetSignalFor" then
							table.insert(names, name)
						end
					end
				end
				local apiClass = api and api[owner]
				if apiClass then
					for name in apiClass.methods do
						table.insert(names, name)
					end
				end
				for _, name in names do
					if not seen[name] then
						seen[name] = true
						table.insert(list, { Name = name, Owner = owner })
					end
				end
			end
			return list
		end,
	}
	ClassMethods.Players = {
		GetPlayers = function()
			return {}
		end,
		GetPlayerFromCharacter = function()
			return nil
		end,
		GetPlayerByUserId = function()
			return nil
		end,
	}

	-- Frame stepping ---------------------------------------------------------------------------

	local frameTime = 0
	local function step(dt: number)
		frameTime += dt
		local rs = stateOf[runService]
		local function fireRun(name: string, ...: any)
			local signal = rs.signals[name]
			if signal then
				-- Frame events run their handlers right away, in order, like the engine's task scheduler.
				local signalState = signalStates[signal]
				for _, connection in table.clone(signalState.connections) do
					taskLib.spawn(runHandler, connectionStates[connection].fn, ...)
				end
				local threads = table.clone(signalState.waiting)
				table.clear(signalState.waiting)
				for _, thread in threads do
					taskLib.spawn(thread, ...)
				end
			end
		end
		if runConfig.isClient then
			for _, bound in table.clone(renderSteps) do
				taskLib.spawn(runHandler, bound.fn, dt)
			end
			fireRun("RenderStepped", dt)
			fireRun("PreRender", dt)
		end
		-- A DataModel that isn't running (a Nevermore test place) doesn't simulate: Stepped,
		-- PreAnimation and PreSimulation never fire there, Heartbeat does.
		if runConfig.isRunning then
			fireRun("PreAnimation", dt)
			fireRun("Stepped", frameTime, dt)
			fireRun("PreSimulation", dt)
		end
		fireRun("PostSimulation", dt)
		fireRun("Heartbeat", dt)
	end

	local dataModel = {
		Instance = table.freeze(InstanceLib),
		game = game,
		workspace = workspace,
		services = services,
		step = step,
		runConfig = runConfig,
	}

	-- typeof that knows the fake objects, for the host to install.
	dataModel.typeof = typeofValue

	function dataModel.isInstance(value: any): boolean
		return kinds[value] == KIND_INSTANCE
	end

	return dataModel
end

return FakeDataModel
