import assert from "node:assert/strict"
import fs from "node:fs"
import vm from "node:vm"

const source = fs.readFileSync(new URL("../Model.js", import.meta.url), "utf8")
  .replace(/^\.pragma library\s*/m, "")

const context = { module: { exports: {} }, JSON, Array, Date, Math, Number, String, parseInt, isFinite }
vm.runInNewContext(source, context, { filename: "Model.js" })
const Model = context.module.exports

assert.equal(Model.validMinutes("15"), 15)
assert.equal(Model.validMinutes("0"), 0)
assert.equal(Model.validMinutes("1.5"), 0)
assert.equal(Model.validMinutes("tomorrow"), 0)
assert.equal(Model.validMinutes("525601"), 0)

const exactNow = new Date(2026, 7, 19, 10, 0, 30).getTime()
const exact = Model.exactSchedule("2026-08-19", "10:05", exactNow)
assert.equal(exact.minutes, 5, "exact reminders round up so they never fire early")
assert.equal(exact.at, new Date(2026, 7, 19, 10, 5, 0).getTime())
assert.equal(exact.error, "")
assert.equal(Model.exactSchedule("2026-02-30", "10:00", exactNow).minutes, 0)
assert.equal(Model.exactSchedule("2026-08-19", "24:00", exactNow).minutes, 0)
assert.equal(Model.exactSchedule("19/08/2026", "10:05", exactNow).minutes, 0)
assert.equal(Model.exactSchedule("2026-08-19", "10:00", exactNow).error, "Choose a future date and time")
assert.equal(Model.exactSchedule("2027-08-20", "10:00", exactNow).error, "Choose a time within the next year")

const state = Model.parseState(JSON.stringify({
  reminders: [
    { label: "Later", remaining: "20m", at: 200, atTime: "12:20" },
    { label: "Soon", remaining: "5m", at: 100, atTime: "12:05" }
  ]
}))

assert.equal(state.count, 2)
assert.equal(state.tooltip, "2 reminders")
assert.equal(state.reminders[0].label, "Soon")
assert.equal(Model.barLabel(2, false), " 2")
assert.equal(Model.barLabel(0, false), "")
assert.equal(Model.reminderMeta(state.reminders[0]), "in 5m  ·  12:05")
assert.equal(Model.parseState("not-json").count, 0)

// ------------------------------------------------------------- recurrence

assert.equal(Model.repeatLabel(30), "every 30 min")
assert.equal(Model.repeatLabel(60), "every hour")
assert.equal(Model.repeatLabel(90), "every 1h 30m")
assert.equal(Model.repeatLabel(1440), "every day")
assert.equal(Model.repeatLabel(0), "")

const rule = Model.createRule(30, "Stretch", 1000, 0.5)
assert.equal(rule.minutes, 30)
assert.equal(rule.message, "Stretch")
assert.equal(rule.startedAt, 1000)
assert.equal(rule.nextAt, 1000 + 1800, "a new rule is already armed for one period")
assert.equal(Model.createRule("nope", "", 1000, 0), null)

// Occurrences stay on the anchor, whenever they are asked for.
assert.equal(Model.nextOccurrence(1000, 30, 1000), 2800)
assert.equal(Model.nextOccurrence(1000, 30, 2799), 2800)
assert.equal(Model.nextOccurrence(1000, 30, 2800), 4600)
assert.equal(Model.nextOccurrence(1000, 30, 100000), 101800, "long gaps do not replay missed occurrences")

// Noticing a fire late shortens the next arm instead of letting error pile up.
assert.equal(Model.armMinutes({ minutes: 30, startedAt: 1000 }, 2800), 30)
assert.equal(Model.armMinutes({ minutes: 30, startedAt: 1000 }, 2810), 30)
assert.equal(Model.armMinutes({ minutes: 30, startedAt: 1000 }, 2845), 29)
assert.equal(Model.armMinutes({ minutes: 1, startedAt: 1000 }, 1090), 1, "an arm is never below the one minute the command needs")

// Rules serialize and reload without losing their schedule.
const stored = Model.serializeRules([rule, { id: "", minutes: 5 }, { id: "x", minutes: 0 }])
assert.equal(Model.parseRules(stored).length, 1, "rules without an id or a duration are dropped")
assert.equal(JSON.stringify(Model.parseRules(stored)[0]), JSON.stringify(rule))
assert.equal(Model.parseRules("not-json").length, 0)
assert.equal(Model.withoutRule([rule], rule.id).length, 0)
assert.equal(Model.withoutRule([rule], "other").length, 1)
assert.equal(Model.hasRule([rule], rule.id), true)
assert.equal(Model.hasRule([rule], "other"), false)

// A rule that has not come due yet, with its timer still armed, is left alone.
const armed = [{ minutes: 30, label: "Stretch" }]
const idle = Model.planRepeats([rule], armed, 2000, 45)
assert.equal(idle.changed, false)
assert.equal(idle.arm.length, 0)

// Once it comes due it is re-armed, and the plan says exactly what to run.
const fired = Model.planRepeats([rule], [], 2805, 45)
assert.equal(fired.changed, true)
assert.equal(fired.arm.length, 1)
assert.equal(fired.arm[0].id, rule.id)
assert.equal(fired.arm[0].minutes, 30)
assert.equal(fired.arm[0].message, "Stretch")
assert.equal(fired.rules[0].nextAt, 2805 + 1800)
assert.equal(fired.rules[0].armedAt, 2805)
assert.equal(fired.rules[0].startedAt, 1000, "the anchor survives re-arming")

// A timer cleared behind our back retires the rule instead of resurrecting it.
const cleared = Model.planRepeats([rule], [], 2000, 45)
assert.equal(cleared.rules.length, 0)
assert.equal(cleared.changed, true)

// ...but only after the grace period, so the poll that races an arm is safe.
assert.equal(Model.planRepeats([rule], [], 1030, 45).rules.length, 1)
assert.equal(Model.hasArmedTimer(armed, 30), true)
assert.equal(Model.hasArmedTimer(armed, 15), false)

// Every due rule is arm-listed, not just the first.
const many = Model.planRepeats(
  [Model.createRule(5, "a", 1000, 0.1), Model.createRule(10, "b", 1000, 0.2)],
  [],
  100000,
  45
)
assert.equal(many.arm.length, 2)

console.log("Model tests passed")
