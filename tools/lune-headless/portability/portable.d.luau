-- The globals the lune-headless `basic` host level provides (see ../lib/Host.luau). Checking the
-- pure closure against only these flags any other Roblox global or type as an unknown name.

declare script: any
declare shared: { [any]: any }

declare task: {
	spawn: (functionOrThread: ((...any) -> ...any) | thread, ...any) -> thread,
	defer: (functionOrThread: ((...any) -> ...any) | thread, ...any) -> thread,
	delay: (duration: number?, functionOrThread: ((...any) -> ...any) | thread, ...any) -> thread,
	wait: (duration: number?) -> number,
	cancel: (thread: thread) -> (),
	synchronize: () -> (),
	desynchronize: () -> (),
}

declare function warn(...: any): ()
declare function tick(): number
declare function time(): number
declare function elapsedTime(): number
declare function wait(seconds: number?): (number, number)
declare function delay(seconds: number?, callback: (...any) -> ...any): ()
declare function spawn(callback: (...any) -> ...any): ()

declare class Random
	Seed: number
	function NextNumber(self, min: number?, max: number?): number
	function NextInteger(self, min: number, max: number): number
	function Clone(self): Random
	function Shuffle(self, list: { any }): ()
end
declare Random: {
	new: (seed: number?) -> Random,
}

declare class DateTime
	UnixTimestamp: number
	UnixTimestampMillis: number
	function ToIsoDate(self): string
	function ToUniversalTime(self): { [string]: number }
	function ToLocalTime(self): { [string]: number }
	function FormatUniversalTime(self, format: string, locale: string): string
	function FormatLocalTime(self, format: string, locale: string): string
end
declare DateTime: {
	now: () -> DateTime,
	fromUnixTimestamp: (seconds: number) -> DateTime,
	fromUnixTimestampMillis: (milliseconds: number) -> DateTime,
	fromIsoDate: (isoDate: string) -> DateTime?,
	fromUniversalTime: (...number) -> DateTime,
	fromLocalTime: (...number) -> DateTime,
}

declare TweenInfo: {
	new: (...any) -> any,
}
