// Super Battery's own logic: settings, the two alert stages, auto power
// saver, charge limit parsing, and the sound list. No QML here, so
// `node test/test_model.js` exercises all of it. The battery popup's display
// helpers are Omarchy's, kept unchanged in PowerModel.js.

var FREEDESKTOP_DIR = "/usr/share/sounds/freedesktop/stereo"

// Omarchy's own omarchy.battery service posts "Time to recharge!" the first
// time a discharge reaches this level. An alert firing at or below it skips
// its notification so the two never stack; the sound still plays.
var OMARCHY_NOTIFY_LEVEL = 10

var LEVEL_MIN = 5
var LEVEL_MAX = 50
var CHARGE_LIMIT_MIN = 50
var CHARGE_LIMIT_MAX = 100
var REPEAT_CHOICES = [0, 1, 2, 5, 10]

var DEFAULTS = {
  showPercentage: false,
  warningOn: true,
  warningLevel: 20,
  warningSound: FREEDESKTOP_DIR + "/dialog-warning.oga",
  criticalOn: true,
  criticalLevel: 10,
  criticalSound: FREEDESKTOP_DIR + "/alarm-clock-elapsed.oga",
  repeatMinutes: 0,
  volume: 80,
  notify: true,
  saverOn: false,
  saverLevel: 20,
  chargeLimitOn: false,
  chargeLimit: 80
}

// Only the freedesktop sounds that work as an alarm. Names are the real
// files: many theme entries are symlinks to these (power-unplug and
// window-attention among them), and listing both would offer one sound twice.
var CURATED_SOUNDS = [
  { file: "dialog-warning.oga", label: "Warning" },
  { file: "alarm-clock-elapsed.oga", label: "Alarm clock" },
  { file: "bell.oga", label: "Bell" },
  { file: "phone-incoming-call.oga", label: "Ringing" },
  { file: "device-removed.oga", label: "Unplugged" },
  { file: "suspend-error.oga", label: "Error tone" },
  { file: "complete.oga", label: "Chime" }
]

var CUSTOM_EXTENSIONS = /\.(oga|ogg|wav|flac|mp3|opus)$/i

function clampInt(value, min, max, fallback) {
  var n = Math.round(Number(value))
  if (value === undefined || value === null || value === "" || !isFinite(n)) return fallback
  return Math.min(max, Math.max(min, n))
}

function bool(value, fallback) {
  return value === undefined ? fallback : value === true
}

function soundPath(value, fallback) {
  return typeof value === "string" && value.charAt(0) === "/" ? value : fallback
}

// The critical level always sits below the warning level. A hand-edited
// entry that breaks that has its critical level pulled down; the popup's
// sliders never produce one (see setLevel).
function normalizeSettings(entry) {
  var s = entry && typeof entry === "object" ? entry : {}
  var repeat = Math.round(Number(s.repeatMinutes))
  var warningLevel = clampInt(s.warningLevel, LEVEL_MIN + 1, LEVEL_MAX, DEFAULTS.warningLevel)
  var criticalLevel = clampInt(s.criticalLevel, LEVEL_MIN, LEVEL_MAX - 1, DEFAULTS.criticalLevel)
  if (criticalLevel >= warningLevel) criticalLevel = warningLevel - 1
  return {
    showPercentage: bool(s.showPercentage, DEFAULTS.showPercentage),
    warningOn: bool(s.warningOn, DEFAULTS.warningOn),
    warningLevel: warningLevel,
    warningSound: soundPath(s.warningSound, DEFAULTS.warningSound),
    criticalOn: bool(s.criticalOn, DEFAULTS.criticalOn),
    criticalLevel: criticalLevel,
    criticalSound: soundPath(s.criticalSound, DEFAULTS.criticalSound),
    repeatMinutes: REPEAT_CHOICES.indexOf(repeat) !== -1 ? repeat : DEFAULTS.repeatMinutes,
    volume: clampInt(s.volume, 0, 100, DEFAULTS.volume),
    notify: bool(s.notify, DEFAULTS.notify),
    saverOn: bool(s.saverOn, DEFAULTS.saverOn),
    saverLevel: clampInt(s.saverLevel, LEVEL_MIN, LEVEL_MAX, DEFAULTS.saverLevel),
    chargeLimitOn: bool(s.chargeLimitOn, DEFAULTS.chargeLimitOn),
    chargeLimit: clampInt(s.chargeLimit, CHARGE_LIMIT_MIN, CHARGE_LIMIT_MAX, DEFAULTS.chargeLimit)
  }
}

// Applies one change. Dragging one alert level across the other pushes the
// other along, so the slider being dragged always gets the value it shows.
function applyChange(settings, key, value) {
  var next = {}
  for (var k in settings) next[k] = settings[k]
  next[key] = value
  if (key === "warningLevel") {
    next.warningLevel = clampInt(value, LEVEL_MIN + 1, LEVEL_MAX, settings.warningLevel)
    if (next.criticalLevel >= next.warningLevel) next.criticalLevel = next.warningLevel - 1
  } else if (key === "criticalLevel") {
    next.criticalLevel = clampInt(value, LEVEL_MIN, LEVEL_MAX - 1, settings.criticalLevel)
    if (next.warningLevel <= next.criticalLevel) next.warningLevel = next.criticalLevel + 1
  }
  return normalizeSettings(next)
}

// The widget's entry may sit in any bar section (or in plugins[] while the
// widget is off the bar), and it carries every field, ours or not.
function entryFromShellConfig(raw, pluginId) {
  var config
  try { config = JSON.parse(raw || "{}") } catch (e) { return null }
  if (!config || typeof config !== "object") return null
  var layout = config.bar && config.bar.layout ? config.bar.layout : {}
  var sections = ["left", "center", "right"]
  for (var s = 0; s < sections.length; s++) {
    var list = Array.isArray(layout[sections[s]]) ? layout[sections[s]] : []
    for (var i = 0; i < list.length; i++)
      if (list[i] && list[i].id === pluginId) return list[i]
  }
  var plugins = Array.isArray(config.plugins) ? config.plugins : []
  for (var j = 0; j < plugins.length; j++)
    if (plugins[j] && plugins[j].id === pluginId) return plugins[j]
  return null
}

// Our settings laid over the stored entry, so fields this plugin does not
// know about (anything Omarchy adds to a widget entry later) survive a save.
function mergedEntry(storedEntry, settings) {
  var out = {}
  var stored = storedEntry && typeof storedEntry === "object" ? storedEntry : {}
  for (var k in stored) if (k !== "id") out[k] = stored[k]
  for (var s in settings) out[s] = settings[s]
  return out
}

function batteryLevel(device) {
  if (!device || !device.isPresent) return -1
  return Math.round(Number(device.percentage || 0) * 100)
}

function isDischarging(device, onBattery, dischargingState) {
  return !!(device && device.isPresent && onBattery && device.state === dischargingState)
}

function shouldNotify(settings, level) {
  return settings.notify && level > OMARCHY_NOTIFY_LEVEL
}

// One check. `state` is what survives between checks:
//   { warned, critical, saverApplied, lastPlayedAt }
// Returns the next state plus what to do: `sound` (a path or ""),
// `notices` (any of "warning", "critical", "saver"), and `saver` (switch now).
//
// Each stage fires once per discharge. Reaching critical also counts as
// warned, so the warning never plays after the critical sound. Only the
// critical sound repeats; a warning is a heads-up, not a nag. A stage
// re-arms when the level is back above it (plugging in, or moving its
// slider below the current level), so the next crossing fires again.
function step(state, input) {
  var s = input.settings
  var level = input.level
  var out = {
    warned: !!(state && state.warned),
    critical: !!(state && state.critical),
    saverApplied: !!(state && state.saverApplied),
    lastPlayedAt: state && state.lastPlayedAt ? state.lastPlayedAt : 0,
    sound: "",
    notices: [],
    saver: false
  }

  if (level < 0 || !input.discharging) {
    out.warned = false
    out.critical = false
    out.saverApplied = false
    out.lastPlayedAt = 0
    return out
  }

  if (level > s.warningLevel) out.warned = false
  if (level > s.criticalLevel) out.critical = false
  if (level > s.saverLevel) out.saverApplied = false

  if (s.criticalOn && level <= s.criticalLevel) {
    if (!out.critical) {
      out.critical = true
      out.warned = true
      out.lastPlayedAt = input.now
      out.sound = s.criticalSound
      if (shouldNotify(s, level)) out.notices.push("critical")
    } else if (s.repeatMinutes > 0 && input.now - out.lastPlayedAt >= s.repeatMinutes * 60000) {
      out.lastPlayedAt = input.now
      out.sound = s.criticalSound
    }
  } else if (s.warningOn && level <= s.warningLevel && !out.warned) {
    out.warned = true
    out.lastPlayedAt = input.now
    out.sound = s.warningSound
    if (shouldNotify(s, level)) out.notices.push("warning")
  }

  if (s.saverOn && level <= s.saverLevel && !out.saverApplied) {
    out.saverApplied = true
    out.saver = true
    if (s.notify) out.notices.push("saver")
  }

  return out
}

// Parses `bin/charge-limit status`: tab-separated key/value lines.
//   kind      threshold | types | none
//   value     the current end threshold, or the current charge type
//   writable  1 when this user can write it without a password
function parseChargeStatus(raw) {
  var out = { kind: "none", value: "", writable: false, error: "" }
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var tab = lines[i].indexOf("\t")
    if (tab <= 0) continue
    var key = lines[i].substring(0, tab)
    var value = lines[i].substring(tab + 1).trim()
    if (key === "kind") out.kind = value === "threshold" || value === "types" ? value : "none"
    else if (key === "value") out.value = value
    else if (key === "writable") out.writable = value === "1"
    else if (key === "error") out.error = value
  }
  return out
}

// What the charge limit should be written as, or "" when it already is.
// Conservation-style laptops have no number to set: on is the firmware's
// Long_Life mode, which picks its own cap.
function chargeLimitTarget(status, settings) {
  if (status.kind === "threshold") {
    var want = settings.chargeLimitOn ? String(settings.chargeLimit) : "100"
    return status.value === want ? "" : want
  }
  if (status.kind === "types") {
    var type = settings.chargeLimitOn ? "Long_Life" : "Standard"
    return status.value === type ? "" : type
  }
  return ""
}

function chargeLimitActive(status) {
  if (status.kind === "threshold") return Number(status.value) < 100
  if (status.kind === "types") return status.value === "Long_Life"
  return false
}

function fileName(path) {
  var parts = String(path || "").split("/")
  return parts[parts.length - 1]
}

function customLabel(path) {
  var name = fileName(path).replace(CUSTOM_EXTENSIONS, "").replace(/[-_]+/g, " ").trim()
  return name ? name.charAt(0).toUpperCase() + name.slice(1) : fileName(path)
}

function soundLabel(path) {
  for (var i = 0; i < CURATED_SOUNDS.length; i++)
    if (path === FREEDESKTOP_DIR + "/" + CURATED_SOUNDS[i].file) return CURATED_SOUNDS[i].label
  return customLabel(path)
}

// `paths` is whatever the sound scan found. Curated freedesktop sounds come
// first in a fixed order, then anything in the custom folder, sorted. Every
// sound currently chosen stays listed, so a deleted file still shows as
// selected instead of the dropdown silently jumping.
function soundOptions(paths, customDir, chosen) {
  var found = {}
  var custom = []
  var prefix = String(customDir || "").replace(/\/$/, "") + "/"
  for (var i = 0; i < paths.length; i++) {
    var path = String(paths[i] || "").trim()
    if (!path) continue
    found[path] = true
    if (prefix !== "/" && path.indexOf(prefix) === 0 && CUSTOM_EXTENSIONS.test(path)) custom.push(path)
  }

  var options = []
  for (var c = 0; c < CURATED_SOUNDS.length; c++) {
    var curated = FREEDESKTOP_DIR + "/" + CURATED_SOUNDS[c].file
    if (found[curated]) options.push({ value: curated, label: CURATED_SOUNDS[c].label })
  }
  custom.sort()
  for (var k = 0; k < custom.length; k++)
    options.push({ value: custom[k], label: customLabel(custom[k]) })

  var picks = Array.isArray(chosen) ? chosen : []
  for (var p = 0; p < picks.length; p++) {
    var pick = picks[p]
    if (pick && !options.some(function(o) { return o.value === pick }))
      options.push({ value: pick, label: soundLabel(pick) + " (missing)" })
  }
  return options
}

// pw-play takes a linear 0.0-1.0 volume.
function volumeArg(volume) {
  return (clampInt(volume, 0, 100, DEFAULTS.volume) / 100).toFixed(2)
}

function repeatOptions() {
  return [
    { value: "0", label: "Once" },
    { value: "1", label: "Every minute" },
    { value: "2", label: "Every 2 minutes" },
    { value: "5", label: "Every 5 minutes" },
    { value: "10", label: "Every 10 minutes" }
  ]
}

function repeatLabel(minutes) {
  if (minutes === 0) return ""
  return minutes === 1 ? "repeats every minute" : "repeats every " + minutes + " min"
}

function alertSummary(on, level, sound, repeatMinutes) {
  if (!on) return "Off"
  var parts = ["At " + level + "%", soundLabel(sound) + " sound"]
  var repeat = repeatLabel(repeatMinutes || 0)
  if (repeat) parts.push(repeat)
  return parts.join(" · ")
}

function saverSummary(settings) {
  return settings.saverOn ? "Switches to Power Saver at " + settings.saverLevel + "%" : "Off"
}

function chargeSummary(status, settings) {
  if (status.kind === "none") return "Not supported on this laptop"
  if (status.kind === "types")
    return settings.chargeLimitOn ? "Conservation mode: the laptop caps the charge (often 60%)" : "Off: charges to 100%"
  return settings.chargeLimitOn ? "Stops charging at " + settings.chargeLimit + "%" : "Off: charges to 100%"
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULTS: DEFAULTS,
    FREEDESKTOP_DIR: FREEDESKTOP_DIR,
    OMARCHY_NOTIFY_LEVEL: OMARCHY_NOTIFY_LEVEL,
    LEVEL_MIN: LEVEL_MIN,
    LEVEL_MAX: LEVEL_MAX,
    normalizeSettings: normalizeSettings,
    applyChange: applyChange,
    entryFromShellConfig: entryFromShellConfig,
    mergedEntry: mergedEntry,
    batteryLevel: batteryLevel,
    isDischarging: isDischarging,
    step: step,
    parseChargeStatus: parseChargeStatus,
    chargeLimitTarget: chargeLimitTarget,
    chargeLimitActive: chargeLimitActive,
    soundOptions: soundOptions,
    soundLabel: soundLabel,
    volumeArg: volumeArg,
    repeatOptions: repeatOptions,
    alertSummary: alertSummary,
    saverSummary: saverSummary,
    chargeSummary: chargeSummary
  }
}
