// Run with: node test/test_model.js
const assert = require("assert")
const M = require("../Model.js")

const MIN = 60000
const cfg = (over) => M.normalizeSettings(Object.assign({}, over))
const at = (level, settings, now, discharging) =>
  ({ level, settings: settings || cfg(), now: now || 0, discharging: discharging !== false })

function run(name, fn) {
  try { fn(); console.log("ok   " + name) }
  catch (e) { console.log("FAIL " + name + "\n     " + e.message); process.exitCode = 1 }
}

// ---------- settings ----------

run("defaults fill an empty entry", () => {
  assert.deepStrictEqual(M.normalizeSettings({ id: "x" }), M.DEFAULTS)
})

run("levels are clamped into range", () => {
  const s = cfg({ warningLevel: 99, criticalLevel: 1, saverLevel: 0, chargeLimit: 20, volume: 300 })
  assert.strictEqual(s.warningLevel, M.LEVEL_MAX)
  assert.strictEqual(s.criticalLevel, M.LEVEL_MIN)
  assert.strictEqual(s.saverLevel, M.LEVEL_MIN)
  assert.strictEqual(s.chargeLimit, 50)
  assert.strictEqual(s.volume, 100)
})

run("a hand-edited critical level above warning is pulled under it", () => {
  const s = cfg({ warningLevel: 15, criticalLevel: 30 })
  assert.strictEqual(s.warningLevel, 15)
  assert.strictEqual(s.criticalLevel, 14)
})

run("dragging critical past warning pushes warning up", () => {
  const s = M.applyChange(cfg({ warningLevel: 20, criticalLevel: 10 }), "criticalLevel", 25)
  assert.strictEqual(s.criticalLevel, 25)
  assert.strictEqual(s.warningLevel, 26)
})

run("dragging warning under critical pushes critical down", () => {
  const s = M.applyChange(cfg({ warningLevel: 20, criticalLevel: 10 }), "warningLevel", 8)
  assert.strictEqual(s.warningLevel, 8)
  assert.strictEqual(s.criticalLevel, 7)
})

run("a repeat interval the popup cannot offer falls back to once", () => {
  assert.strictEqual(cfg({ repeatMinutes: 3 }).repeatMinutes, 0)
  assert.strictEqual(cfg({ repeatMinutes: "5" }).repeatMinutes, 5)
})

run("a relative sound path is refused", () => {
  assert.strictEqual(cfg({ warningSound: "bell.oga" }).warningSound, M.DEFAULTS.warningSound)
})

run("the entry is found in any bar section, then plugins[]", () => {
  const raw = JSON.stringify({
    bar: { layout: { left: [{ id: "a" }], right: [{ id: "omarchy.clock" }, { id: "me", warningLevel: 33 }] } },
    plugins: [{ id: "other", warningLevel: 9 }]
  })
  assert.strictEqual(M.entryFromShellConfig(raw, "me").warningLevel, 33)
  assert.strictEqual(M.entryFromShellConfig(raw, "other").warningLevel, 9)
  assert.strictEqual(M.entryFromShellConfig(raw, "missing"), null)
  assert.strictEqual(M.entryFromShellConfig("{not json", "me"), null)
})

run("saving keeps fields this plugin does not own", () => {
  const out = M.mergedEntry({ id: "me", futureOmarchyField: 7, volume: 10 }, cfg({ volume: 55 }))
  assert.strictEqual(out.futureOmarchyField, 7)
  assert.strictEqual(out.volume, 55)
  assert.strictEqual(out.id, undefined)
})

// ---------- alerts ----------

run("warning plays once on crossing, with its notification", () => {
  const r = M.step({}, at(20))
  assert.strictEqual(r.sound, M.DEFAULTS.warningSound)
  assert.deepStrictEqual(r.notices, ["warning"])
  const again = M.step(r, at(19, cfg(), 60 * MIN))
  assert.strictEqual(again.sound, "")
})

run("critical follows warning, with its own sound", () => {
  const warned = M.step({}, at(20))
  const crit = M.step(warned, at(12, cfg({ criticalLevel: 12 })))
  assert.strictEqual(crit.sound, M.DEFAULTS.criticalSound)
  assert.deepStrictEqual(crit.notices, ["critical"])
})

run("dropping straight into critical plays only the critical sound, and warning never follows", () => {
  const crit = M.step({}, at(8))
  assert.strictEqual(crit.sound, M.DEFAULTS.criticalSound)
  const later = M.step(crit, at(8, cfg(), MIN))
  assert.strictEqual(later.sound, "")
})

run("after critical, moving its slider under the battery does not replay the milder warning", () => {
  const crit = M.step({}, at(8))
  const moved = M.step(crit, at(8, cfg({ criticalLevel: 5 }), MIN))
  assert.strictEqual(moved.sound, "")
})

run("no notification at or below Omarchy's own 10% warning", () => {
  const crit = M.step({}, at(10))
  assert.strictEqual(crit.sound, M.DEFAULTS.criticalSound)
  assert.deepStrictEqual(crit.notices, [])
  const higher = M.step({}, at(15, cfg({ criticalLevel: 15 })))
  assert.deepStrictEqual(higher.notices, ["critical"])
})

run("notifications off keeps the sounds", () => {
  const r = M.step({}, at(20, cfg({ notify: false })))
  assert.strictEqual(r.sound, M.DEFAULTS.warningSound)
  assert.deepStrictEqual(r.notices, [])
})

run("only critical repeats, and only once the interval has passed", () => {
  const s = cfg({ repeatMinutes: 2 })
  const warned = M.step({}, at(20, s, 0))
  assert.strictEqual(M.step(warned, at(19, s, 10 * MIN)).sound, "")
  const crit = M.step(warned, at(10, s, 10 * MIN))
  assert.strictEqual(M.step(crit, at(10, s, 12 * MIN - 1)).sound, "")
  const due = M.step(crit, at(9, s, 12 * MIN))
  assert.strictEqual(due.sound, M.DEFAULTS.criticalSound)
  assert.deepStrictEqual(due.notices, [])
})

run("stays quiet while charging, above the levels, or with no battery", () => {
  assert.strictEqual(M.step({}, at(21)).sound, "")
  assert.strictEqual(M.step({}, at(5, cfg(), 0, false)).sound, "")
  assert.strictEqual(M.step({}, at(-1)).sound, "")
})

run("plugging in re-arms every stage", () => {
  const crit = M.step(M.step({}, at(20)), at(9))
  const plugged = M.step(crit, at(9, cfg(), MIN, false))
  assert.strictEqual(plugged.warned, false)
  assert.strictEqual(plugged.critical, false)
  assert.strictEqual(M.step(plugged, at(9, cfg(), 2 * MIN)).sound, M.DEFAULTS.criticalSound)
})

run("moving a level below the battery re-arms that stage", () => {
  const warned = M.step({}, at(18))
  const moved = M.step(warned, at(18, cfg({ warningLevel: 15 }), MIN))
  assert.strictEqual(moved.warned, false)
  assert.strictEqual(moved.sound, "")
})

run("a stage switched off stays quiet and does not swallow the other", () => {
  const r = M.step({}, at(9, cfg({ criticalOn: false })))
  assert.strictEqual(r.sound, M.DEFAULTS.warningSound)
  assert.strictEqual(r.critical, false)
  const none = M.step({}, at(9, cfg({ criticalOn: false, warningOn: false })))
  assert.strictEqual(none.sound, "")
})

// ---------- power saver ----------

run("power saver is off by default", () => {
  assert.strictEqual(M.step({}, at(5)).saver, false)
})

run("power saver switches once per discharge, then re-arms on plug-in", () => {
  const s = cfg({ saverOn: true, saverLevel: 25 })
  const first = M.step({}, at(25, s))
  assert.strictEqual(first.saver, true)
  assert.deepStrictEqual(first.notices, ["saver"])
  // Picking another profile by hand afterwards must not be fought.
  assert.strictEqual(M.step(first, at(22, s, MIN)).saver, false)
  const plugged = M.step(first, at(22, s, MIN, false))
  assert.strictEqual(M.step(plugged, at(22, s, 2 * MIN)).saver, true)
})

run("power saver and the warning fire together when their levels match", () => {
  const s = cfg({ saverOn: true, saverLevel: 20 })
  const r = M.step({}, at(20, s))
  assert.strictEqual(r.saver, true)
  assert.strictEqual(r.sound, M.DEFAULTS.warningSound)
  assert.deepStrictEqual(r.notices, ["warning", "saver"])
})

// ---------- charge limit ----------

run("charge status parses all three kinds", () => {
  assert.deepStrictEqual(M.parseChargeStatus("kind\tthreshold\nvalue\t80\nwritable\t1\n"),
    { kind: "threshold", value: "80", writable: true, error: "" })
  assert.deepStrictEqual(M.parseChargeStatus("kind\ttypes\nvalue\tStandard\nwritable\t0\n"),
    { kind: "types", value: "Standard", writable: false, error: "" })
  assert.strictEqual(M.parseChargeStatus("").kind, "none")
  assert.strictEqual(M.parseChargeStatus("kind\tbogus\n").kind, "none")
})

run("charge limit target: threshold laptops get the number, or 100 when off", () => {
  const status = { kind: "threshold", value: "100" }
  assert.strictEqual(M.chargeLimitTarget(status, cfg({ chargeLimitOn: true, chargeLimit: 80 })), "80")
  assert.strictEqual(M.chargeLimitTarget({ kind: "threshold", value: "80" }, cfg({ chargeLimitOn: true })), "")
  assert.strictEqual(M.chargeLimitTarget({ kind: "threshold", value: "80" }, cfg()), "100")
})

run("charge limit target: conservation laptops toggle Long_Life", () => {
  assert.strictEqual(M.chargeLimitTarget({ kind: "types", value: "Standard" }, cfg({ chargeLimitOn: true })), "Long_Life")
  assert.strictEqual(M.chargeLimitTarget({ kind: "types", value: "Long_Life" }, cfg()), "Standard")
  assert.strictEqual(M.chargeLimitTarget({ kind: "types", value: "Long_Life" }, cfg({ chargeLimitOn: true })), "")
  assert.strictEqual(M.chargeLimitTarget({ kind: "none", value: "" }, cfg({ chargeLimitOn: true })), "")
})

// ---------- sounds and labels ----------

run("sound list: curated first in order, then custom, skipping non-audio", () => {
  const fd = M.FREEDESKTOP_DIR
  const opts = M.soundOptions([
    fd + "/bell.oga", fd + "/audio-channel-front-left.oga", fd + "/dialog-warning.oga",
    "/home/u/.local/share/sounds/battery-sound/my_alarm-2.mp3",
    "/home/u/.local/share/sounds/battery-sound/notes.txt", ""
  ], "/home/u/.local/share/sounds/battery-sound", [fd + "/dialog-warning.oga"])
  assert.deepStrictEqual(opts.map(o => o.label), ["Warning", "Bell", "My alarm 2"])
})

run("a deleted chosen sound stays selectable and says so", () => {
  const opts = M.soundOptions([], "/c", ["/c/gone.wav", "/c/gone.wav"])
  assert.deepStrictEqual(opts, [{ value: "/c/gone.wav", label: "Gone (missing)" }])
})

run("volume maps to pw-play's 0-1 scale", () => {
  assert.strictEqual(M.volumeArg(80), "0.80")
  assert.strictEqual(M.volumeArg(150), "1.00")
})

run("summaries read as one line", () => {
  assert.strictEqual(M.alertSummary(true, 10, M.DEFAULTS.criticalSound, 2), "At 10% · Alarm clock sound · repeats every 2 min")
  assert.strictEqual(M.alertSummary(false, 10, "", 0), "Off")
  assert.strictEqual(M.chargeSummary({ kind: "threshold" }, cfg({ chargeLimitOn: true, chargeLimit: 85 })), "Stops charging at 85%")
})
