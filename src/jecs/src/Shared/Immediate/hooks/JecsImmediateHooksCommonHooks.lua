--!nonstrict
--[=[
	@class JecsImmediateHooksCommonHooks

	Built-in immediate-mode hooks: [JecsImmediateHooksCoreHooks] (no engine API) with
	[JecsImmediateHooksRobloxHooks] copied over it. Each pack is `(runtime) -> { name = fn }`;
	functions close over `runtime` so call sites are `hooks.gate()` etc.

	The merge is flat: every entry is the pack's own function, so a call costs the same as before
	the split, and the `debug.info(3, ...)` call-site keying in
	JecsImmediateHookUtils.getOrCreateHookState still sees game code. Never wrap a hook here.

	`dis` is always the first optional argument, after every required argument.
]=]
local require = require(script.Parent.loader).load(script)

local JecsImmediateHookUtils = require("JecsImmediateHookUtils")
local JecsImmediateHooksCoreHooks = require("JecsImmediateHooksCoreHooks")
local JecsImmediateHooksRobloxHooks = require("JecsImmediateHooksRobloxHooks")

export type SchedulerState = JecsImmediateHooksCoreHooks.SchedulerState

return function(runtime: JecsImmediateHookUtils.ImmediateRuntime_Jecs_HookBook<any>)
	local hooks = JecsImmediateHooksCoreHooks(runtime)
	local robloxHooks = JecsImmediateHooksRobloxHooks(runtime)
	for name, hook in robloxHooks do
		hooks[name] = hook
	end
	return hooks :: typeof(hooks) & typeof(robloxHooks)
end
