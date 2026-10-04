-- Globals the Lune shim promises to provide. Anything else Roblox-specific is flagged as unknown.
declare game: any
declare script: any
declare class Instance end
declare task: {
	spawn: <T...>(f: ((T...) -> ()) | thread, T...) -> thread,
	defer: <T...>(f: ((T...) -> ()) | thread, T...) -> thread,
	delay: <T...>(sec: number, f: ((T...) -> ()) | thread, T...) -> thread,
	wait: (sec: number?) -> number,
	cancel: (thread) -> (),
}
