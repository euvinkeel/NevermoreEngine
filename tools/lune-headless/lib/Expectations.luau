--!strict
--[[
	Checks a run against an expectations file, so `npm run test:lune` can gate on the specs that are
	known to work headlessly while the rest are still being worked on.

	{
		"mustPass": ["src/maid/src/Shared/MaidTaskUtils.spec.lua", ...],
		"knownFailing": { "src/tie/...spec.lua": "why it can't pass headlessly yet" }
	}

	A must-pass spec that doesn't pass is a regression (exit code 1). A known-failing spec that now
	passes is reported so it can be promoted.
]]

local serde = require("@lune/serde")

local Expectations = {}

export type Report = {
	ok: boolean,
	regressions: { string },
	promotable: { string },
	unlisted: { string },
	messages: { string },
}

function Expectations.check(text: string, specs: { { [string]: any } }): Report
	local data = serde.decode("json" :: any, text)
	local mustPass: { [string]: boolean } = {}
	for _, spec in data.mustPass or {} do
		mustPass[spec] = true
	end
	local knownFailing: { [string]: string } = data.knownFailing or {}

	local report: Report = {
		ok = true,
		regressions = {},
		promotable = {},
		unlisted = {},
		messages = {},
	}

	local ran: { [string]: boolean } = {}
	for _, spec in specs do
		ran[spec.spec] = true
		if mustPass[spec.spec] then
			if spec.status ~= "pass" then
				report.ok = false
				table.insert(report.regressions, spec.spec)
				table.insert(
					report.messages,
					`REGRESSION  {spec.spec} is {spec.status} ({spec.passed}/{spec.passed + spec.failed})`
				)
			end
		elseif knownFailing[spec.spec] then
			if spec.status == "pass" then
				table.insert(report.promotable, spec.spec)
				table.insert(report.messages, `NOW PASSING {spec.spec} (move it to mustPass)`)
			end
		else
			table.insert(report.unlisted, spec.spec)
		end
	end

	for spec in mustPass do
		if not ran[spec] then
			report.ok = false
			table.insert(report.regressions, spec)
			table.insert(report.messages, `MISSING     {spec} is in mustPass but didn't run`)
		end
	end

	table.insert(
		report.messages,
		if report.ok
			then `expectations: OK ({#report.promotable} newly passing, {#report.unlisted} unlisted)`
			else `expectations: {#report.regressions} must-pass spec(s) failed`
	)
	return report
end

return Expectations
