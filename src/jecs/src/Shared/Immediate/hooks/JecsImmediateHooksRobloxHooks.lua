--!nonstrict
--[=[
	@class JecsImmediateHooksRobloxHooks

	The built-in immediate-mode hooks that use Roblox engine API: Instances, binders, ties,
	ValueObject, and a `guid` from HttpService. [JecsImmediateHooksCommonHooks] copies these over
	[JecsImmediateHooksCoreHooks].

	Hook state is keyed by the hook's call site (`debug.info(3, ...)` in
	JecsImmediateHookUtils.getOrCreateHookState), so a hook here must be called directly by game
	code. Replace a core hook; never wrap or delegate to another hook.
]=]
local require = require(script.Parent.loader).load(script)

local HttpService = game:GetService("HttpService")

local JecsImmediateHookUtils = require("JecsImmediateHookUtils")
local RxInstanceUtils = require("RxInstanceUtils")
local TieRealms = require("TieRealms")
local ValueObject = require("ValueObject")

local getOrCreateHookState = JecsImmediateHookUtils.getOrCreateHookState

return function(runtime: JecsImmediateHookUtils.ImmediateRuntime_Jecs_HookBook<any>)
	return {
		guid = function(dis: any?)
			local hookState, _hookMaid = getOrCreateHookState(runtime, dis)
			if hookState.guid == nil then
				hookState.guid = HttpService:GenerateGUID()
			end
			return hookState.guid
		end,

		filterDescendants = function(
			instanceArg: Instance | { Instance },
			filterFunction: (Instance) -> boolean,
			dis: any?
		): { Instance }
			local hookState, hookMaid = getOrCreateHookState(runtime, dis)
			assert(instanceArg, "instanceArg is nil")
			assert(
				typeof(instanceArg) == "Instance" or typeof(instanceArg) == "table",
				"instanceArg must be an Instance or a table of Instances"
			)

			if not hookState.instances then
				hookState.instances = if typeof(instanceArg) == "table"
					then table.clone(instanceArg)
					else { instanceArg }
				for _, instance in hookState.instances do
					assert(instance, "instance is nil")
					assert(instance:IsA("Instance"), "instance must be an Instance")
				end
			end

			if hookState.filteredDescendants == nil then
				local list: { Instance } = {}
				hookState.filteredDescendants = list
				for _, instance in hookState.instances do
					hookMaid:GiveTask(
						RxInstanceUtils.observeDescendantsBrio(instance, filterFunction)
							:Subscribe(function(descendantBrio)
								if descendantBrio:IsDead() then
									return
								end

								local maid, descendant = descendantBrio:ToMaidAndValue()
								table.insert(list, descendant)
								maid:GiveTask(function()
									local index = table.find(list, descendant)
									if index then
										local last = #list
										list[index] = list[last]
										list[last] = nil
									end
								end)
							end)
					)
				end
			end
			return hookState.filteredDescendants
		end,

		findChild = function(parentInstance: Instance, name: string, dis: any?, recursive: boolean?)
			if not parentInstance then
				error(`parentInstance is nil: {dis} {name} {recursive}`)
			end
			local hookState, _hookMaid = getOrCreateHookState(runtime, dis)
			if hookState._init == nil then
				hookState._init = true
				hookState._startedAt = os.clock()
				hookState._warnedAt = os.clock()
				hookState.foundChild = nil
			end
			if hookState.foundChild == nil then
				hookState.foundChild = parentInstance:FindFirstChild(name, recursive)
			end
			if
				hookState.foundChild == nil
				and os.clock() - hookState._startedAt > 5
				and os.clock() - hookState._warnedAt > 5
			then
				hookState._warnedAt = os.clock()
				warn(`findFirstChild: not finding {name} in {parentInstance:GetFullName()} after 5 seconds...`)
			end
			return hookState.foundChild
		end,

		value = function(initialValue: any, dis: any?): ValueObject.ValueObject<any>
			local hookState, hookMaid = getOrCreateHookState(runtime, dis)
			if hookState.valueObject == nil then
				hookState.valueObject = hookMaid:Add(ValueObject.new(initialValue))
			end
			return hookState.valueObject
		end,

		useBinder = function(instance: Instance, binderTag: string, dis: any?, debug: boolean?)
			local hookState, hookMaid = getOrCreateHookState(runtime, dis)

			if hookState.boundObject ~= nil then
				return hookState.boundObject
			end

			if hookState.pendingPromise ~= nil then
				if debug then
					warn(`Pending promise for {binderTag} exists...`)
				end
				return nil
			end

			local binder = runtime.serviceBag:GetService(runtime.require(binderTag))
			if not binder then
				warn(`No binder found for tag {binderTag}`)
				return nil
			end

			if not hookState.startedBinderPromise then
				if debug then
					warn(`Starting promise for {binderTag}`)
				end
				hookState.startedBinderPromise = true
				hookMaid:GivePromise(binder
					:Promise(instance)
					:Then(function(boundObject)
						if debug then
							warn(`Bound object for {binderTag}!`)
						end
						hookState.boundObject = boundObject
					end)
					:Catch(function(err)
						warn(`Failed to start binder promise for {binderTag}`, err)
						hookState.boundObject = nil
					end))
				return binder:Get(instance)
			end

			return nil
		end,

		useTieInterface = function(instance: Instance, tieInterfaceName: string, dis: any?, realm: TieRealms.TieRealm?)
			local hookState, hookMaid = getOrCreateHookState(runtime, dis)
			if hookState.observingBrio == nil then
				local tieInterface = runtime.require(tieInterfaceName)
				if realm then
					tieInterface = tieInterface[realm]
				end
				hookState.observingBrio = hookMaid:GiveTask(tieInterface:ObserveBrio(instance):Subscribe(function(brio)
					if brio:IsDead() then
						hookState.currentInterface = nil
						return
					end
					local _maid, interface = brio:ToMaidAndValue()
					hookState.currentInterface = interface
				end))
			end
			return hookState.currentInterface
		end,
	}
end
