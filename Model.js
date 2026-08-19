.pragma library

function cleanText(value) {
  return String(value === undefined || value === null ? "" : value).trim()
}

function validMinutes(value) {
  var text = cleanText(value)
  if (!/^\d+$/.test(text)) return 0

  var minutes = parseInt(text, 10)
  if (!isFinite(minutes) || minutes < 1 || minutes > 525600) return 0
  return minutes
}

// `omarchy reminder` accepts a duration rather than a wall-clock timestamp.
// Keep the date parsing here so the panel can validate calendar values before
// converting them to the whole-minute duration the command needs.
function exactSchedule(dateValue, timeValue, nowValue) {
  var dateText = cleanText(dateValue)
  var timeText = cleanText(timeValue)
  var dateMatch = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dateText)
  var timeMatch = /^(\d{2}):(\d{2})$/.exec(timeText)

  if (!dateMatch || !timeMatch) {
    return { minutes: 0, at: 0, error: "Use YYYY-MM-DD and HH:MM" }
  }

  var year = parseInt(dateMatch[1], 10)
  var month = parseInt(dateMatch[2], 10)
  var day = parseInt(dateMatch[3], 10)
  var hour = parseInt(timeMatch[1], 10)
  var minute = parseInt(timeMatch[2], 10)
  var target = new Date(year, month - 1, day, hour, minute, 0, 0)

  // Date normalizes impossible values (for example February 30) and local
  // times skipped by daylight-saving transitions. Comparing every part turns
  // those normalizations into a clear validation error instead.
  if (year < 1970 || month < 1 || month > 12 || day < 1 || day > 31
      || hour < 0 || hour > 23 || minute < 0 || minute > 59
      || target.getFullYear() !== year || target.getMonth() !== month - 1
      || target.getDate() !== day || target.getHours() !== hour
      || target.getMinutes() !== minute) {
    return { minutes: 0, at: 0, error: "Enter a valid local date and time" }
  }

  var now = Number(nowValue)
  if (!isFinite(now)) now = Date.now()

  var difference = target.getTime() - now
  if (difference <= 0) {
    return { minutes: 0, at: target.getTime(), error: "Choose a future date and time" }
  }

  // Rounding up guarantees an exact-time reminder never fires before the
  // selected minute. It can arrive less than one minute late because the
  // underlying command only accepts whole minutes.
  var minutesUntil = Math.ceil(difference / 60000)
  if (validMinutes(String(minutesUntil)) === 0) {
    return { minutes: 0, at: target.getTime(), error: "Choose a time within the next year" }
  }

  return { minutes: minutesUntil, at: target.getTime(), error: "" }
}

function emptyState() {
  return {
    count: 0,
    active: false,
    tooltip: "Set a reminder",
    reminders: []
  }
}

function normalizedReminder(value) {
  var reminder = value || {}
  return {
    unit: cleanText(reminder.unit),
    timer: cleanText(reminder.timer),
    minutes: Number(reminder.minutes || 0),
    message: cleanText(reminder.message),
    label: cleanText(reminder.label) || "Reminder",
    remaining: cleanText(reminder.remaining),
    remainingSeconds: Number(reminder.remainingSeconds || 0),
    at: Number(reminder.at || 0),
    atTime: cleanText(reminder.atTime)
  }
}

function parseState(raw) {
  try {
    var parsed = JSON.parse(String(raw || "{}"))
    var reminders = []
    var source = Array.isArray(parsed.reminders) ? parsed.reminders : []
    for (var i = 0; i < source.length; i++) reminders.push(normalizedReminder(source[i]))

    reminders.sort(function(a, b) { return a.at - b.at })
    var count = reminders.length
    return {
      count: count,
      active: count > 0,
      tooltip: count === 0 ? "Set a reminder" : count === 1 ? "1 reminder" : count + " reminders",
      reminders: reminders
    }
  } catch (error) {
    return emptyState()
  }
}

function barLabel(count, vertical) {
  var total = Number(count || 0)
  if (vertical) return "" + (total > 0 ? "\n" + total : "")
  return "" + (total > 0 ? " " + total : "")
}

function reminderMeta(reminder) {
  var value = reminder || {}
  var parts = []
  if (cleanText(value.remaining)) parts.push("in " + cleanText(value.remaining))
  if (cleanText(value.atTime)) parts.push(cleanText(value.atTime))
  return parts.join("  ·  ")
}

// ------------------------------------------------------------- recurrence
//
// `omarchy reminder` only knows one-shot timers: it takes a whole number of
// minutes and arms a transient systemd unit. Repeating reminders are therefore
// Ominder's own bookkeeping — a rule is stored, and every time its armed timer
// fires the widget arms the next one.
//
// Re-arming naively (`next = now + period`) would drift, because a fire is only
// noticed on the next poll. So a rule keeps `startedAt` as a fixed anchor and
// each arm is measured against the ideal occurrence on that anchor. Rounding to
// the whole minute the command accepts leaves at most ±30s of error, and that
// error never accumulates.

function repeatLabel(minutes) {
  var total = validMinutes(minutes)
  if (total === 0) return ""

  if (total % 1440 === 0) {
    var days = total / 1440
    return days === 1 ? "every day" : "every " + days + " days"
  }

  if (total % 60 === 0) {
    var hours = total / 60
    return hours === 1 ? "every hour" : "every " + hours + " hours"
  }

  if (total > 60) return "every " + Math.floor(total / 60) + "h " + (total % 60) + "m"
  return total === 1 ? "every minute" : "every " + total + " min"
}

function normalizedRule(value) {
  var rule = value || {}
  var minutes = validMinutes(rule.minutes)
  if (minutes === 0) return null

  var id = cleanText(rule.id)
  if (id === "") return null

  return {
    id: id,
    minutes: minutes,
    message: cleanText(rule.message),
    startedAt: Math.max(0, Number(rule.startedAt || 0)),
    nextAt: Math.max(0, Number(rule.nextAt || 0)),
    armedAt: Math.max(0, Number(rule.armedAt || 0)),
    armedMinutes: validMinutes(rule.armedMinutes) || minutes
  }
}

// The first arm is issued by the panel through the normal create path, so a
// fresh rule is already armed for one period when it is stored.
function createRule(minutes, message, now, seed) {
  var period = validMinutes(minutes)
  if (period === 0) return null

  var at = Math.max(0, Number(now || 0))
  var suffix = Math.floor(Math.abs(Number(seed || 0)) * 1000000)

  return {
    id: "ominder-" + at + "-" + suffix,
    minutes: period,
    message: cleanText(message),
    startedAt: at,
    nextAt: at + period * 60,
    armedAt: at,
    armedMinutes: period
  }
}

function parseRules(raw) {
  try {
    var parsed = JSON.parse(String(raw || "{}"))
    var source = Array.isArray(parsed) ? parsed : Array.isArray(parsed.rules) ? parsed.rules : []
    var rules = []

    for (var i = 0; i < source.length; i++) {
      var rule = normalizedRule(source[i])
      if (rule) rules.push(rule)
    }
    return rules
  } catch (error) {
    return []
  }
}

function serializeRules(rules) {
  var source = Array.isArray(rules) ? rules : []
  var out = []

  for (var i = 0; i < source.length; i++) {
    var rule = normalizedRule(source[i])
    if (rule) out.push(rule)
  }
  return JSON.stringify({ version: 1, rules: out }, null, 2)
}

function withoutRule(rules, id) {
  var source = Array.isArray(rules) ? rules : []
  var wanted = cleanText(id)
  var out = []

  for (var i = 0; i < source.length; i++) {
    var rule = normalizedRule(source[i])
    if (rule && rule.id !== wanted) out.push(rule)
  }
  return out
}

function hasRule(rules, id) {
  var source = Array.isArray(rules) ? rules : []
  var wanted = cleanText(id)

  for (var i = 0; i < source.length; i++) {
    if (cleanText((source[i] || {}).id) === wanted) return true
  }
  return false
}

// First occurrence strictly after `now` on the rule's fixed anchor.
function nextOccurrence(startedAt, minutes, now) {
  var period = validMinutes(minutes) * 60
  var at = Math.max(0, Number(now || 0))
  if (period === 0) return at

  var anchor = Math.max(0, Number(startedAt || 0))
  if (anchor === 0 || anchor > at) return at + period

  return anchor + (Math.floor((at - anchor) / period) + 1) * period
}

// Whole minutes to hand to `omarchy reminder` for the next occurrence. Never
// zero (the command rejects it) and never more than one full period.
function armMinutes(rule, now) {
  var value = rule || {}
  var period = validMinutes(value.minutes)
  if (period === 0) return 0

  var at = Math.max(0, Number(now || 0))
  var minutes = Math.round((nextOccurrence(value.startedAt, period, at) - at) / 60)
  if (minutes < 1) return 1
  if (minutes > period) return period
  return minutes
}

// Reminders are only identifiable by their duration, so this deliberately
// errs towards "still armed": a false match keeps a rule alive, while a false
// miss would silently cancel one.
function hasArmedTimer(reminders, minutes) {
  var source = Array.isArray(reminders) ? reminders : []
  var wanted = Number(minutes || 0)

  for (var i = 0; i < source.length; i++) {
    if (Number((source[i] || {}).minutes || 0) === wanted) return true
  }
  return false
}

// One tick of the re-arm loop, kept pure so it can be tested without a shell.
// Returns the next rule list, the reminders to arm, and whether anything moved
// (the caller only rewrites the state file when it did).
function planRepeats(rules, reminders, now, graceSeconds) {
  var source = Array.isArray(rules) ? rules : []
  var at = Math.max(0, Number(now || 0))
  var grace = Math.max(0, Number(graceSeconds || 0))
  var next = []
  var arm = []
  var changed = false

  for (var i = 0; i < source.length; i++) {
    var rule = normalizedRule(source[i])
    if (!rule) {
      changed = true
      continue
    }

    if (at >= rule.nextAt) {
      var minutes = armMinutes(rule, at)
      rule.armedMinutes = minutes
      rule.armedAt = at
      rule.nextAt = at + minutes * 60
      arm.push({ id: rule.id, minutes: minutes, message: rule.message })
      next.push(rule)
      changed = true
      continue
    }

    // Cleared behind our back — by `omarchy reminder clear` or the built-in
    // reminders panel. The grace period covers the gap between arming a timer
    // and the next state poll seeing it.
    if (at - rule.armedAt > grace && !hasArmedTimer(reminders, rule.armedMinutes)) {
      changed = true
      continue
    }

    next.push(rule)
  }

  return { rules: next, arm: arm, changed: changed }
}

if (typeof module !== "undefined") {
  module.exports = {
    armMinutes: armMinutes,
    barLabel: barLabel,
    cleanText: cleanText,
    createRule: createRule,
    emptyState: emptyState,
    exactSchedule: exactSchedule,
    hasArmedTimer: hasArmedTimer,
    hasRule: hasRule,
    nextOccurrence: nextOccurrence,
    parseRules: parseRules,
    parseState: parseState,
    planRepeats: planRepeats,
    reminderMeta: reminderMeta,
    repeatLabel: repeatLabel,
    serializeRules: serializeRules,
    validMinutes: validMinutes,
    withoutRule: withoutRule
  }
}
