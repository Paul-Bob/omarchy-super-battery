import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "Model.js" as Model

// Everything Super Battery does in the background: the two low battery
// alerts, auto power saver, and keeping the charge limit applied. The bar
// widget (Panel.qml) is instantiated once per bar, so it holds no state of
// its own; it reads this service and changes things through setSetting().
//
// Runs alongside Omarchy's omarchy.battery service, which keeps its 10%
// notification and its AC/battery power profile switching.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "paulbob.super-battery"
  readonly property string home: Quickshell.env("HOME")
  // Settable so the test harness can point it at a fake shell.json.
  property string shellConfigPath: home + "/.config/omarchy/shell.json"
  readonly property string customSoundDir: home + "/.local/share/sounds/super-battery"
  readonly property string chargeLimitBin: localPath("bin/charge-limit")
  readonly property string chargeSetupBin: localPath("bin/charge-limit-setup")

  property var settings: Model.normalizeSettings({})
  property var storedEntry: ({})
  property var sounds: []
  property var chargeStatus: Model.parseChargeStatus("")
  property bool chargeSetupRunning: false
  property string lastError: ""

  readonly property int level: Model.batteryLevel(UPower.displayDevice)
  readonly property bool discharging: Model.isDischarging(UPower.displayDevice, UPower.onBattery, UPowerDeviceState.Discharging)
  readonly property bool playing: soundProc.running
  readonly property bool chargeLimitNeedsSetup: chargeStatus.kind !== "none" && !chargeStatus.writable
    && Model.chargeLimitTarget(chargeStatus, settings) !== ""

  property string pendingSound: ""
  property bool stoppingSound: false
  // Set at startup and after the one-time setup: once both the settings and
  // the charge status are known, a limit that is switched on gets written
  // if the laptop lost it. Never the reverse: an unloaded settings file
  // reads as "off", and acting on that would undo a limit set elsewhere.
  property bool applyChargeAfterRefresh: true
  property bool settingsLoaded: false
  property bool chargeKnown: false

  // Survives plugin hot-reload, so saving a file mid-discharge does not
  // replay an alert that was already heard.
  PersistentProperties {
    id: persisted
    reloadableId: "paulbob-super-battery"
    property bool warned: false
    property bool critical: false
    property bool saverApplied: false
    property real lastPlayedAt: 0
  }

  function localPath(relative) {
    return decodeURIComponent(String(Qt.resolvedUrl(relative)).replace(/^file:\/\//, ""))
  }

  // The only writer of this plugin's shell.json entry. Bar widgets on every
  // monitor go through here, so two of them can never race each other.
  function setSetting(key, value) {
    root.settings = Model.applyChange(root.settings, key, value)
    if (root.shell && typeof root.shell.updateEntryInline === "function")
      root.shell.updateEntryInline(root.pluginId, Model.mergedEntry(root.storedEntry, root.settings))
    if (key === "chargeLimitOn" || key === "chargeLimit") root.applyChargeLimit()
    root.check()
  }

  function applyShellConfig(raw) {
    var entry = Model.entryFromShellConfig(raw, root.pluginId)
    // No entry means the plugin is being disabled; keep the last settings
    // rather than flashing defaults in a popup that is about to unload.
    if (!entry) return
    root.storedEntry = entry
    root.settings = Model.normalizeSettings(entry)
    root.settingsLoaded = true
    root.reapplyChargeLimit()
    root.check()
  }

  function reapplyChargeLimit() {
    if (!root.applyChargeAfterRefresh || !root.settingsLoaded || !root.chargeKnown) return
    root.applyChargeAfterRefresh = false
    if (root.settings.chargeLimitOn) root.applyChargeLimit()
  }

  // Waits for the saved settings: defaults could alert at levels the user
  // already moved, or switch on a power saver they never asked for.
  function check() {
    if (!root.settingsLoaded) return
    var result = Model.step(
      { warned: persisted.warned, critical: persisted.critical, saverApplied: persisted.saverApplied, lastPlayedAt: persisted.lastPlayedAt },
      { level: root.level, discharging: root.discharging, settings: root.settings, now: Date.now() })
    persisted.warned = result.warned
    persisted.critical = result.critical
    persisted.saverApplied = result.saverApplied
    persisted.lastPlayedAt = result.lastPlayedAt
    if (result.sound) root.play(result.sound)
    if (result.saver) root.switchToPowerSaver()
    for (var i = 0; i < result.notices.length; i++) root.notify(result.notices[i])
  }

  // The latest request wins: a sound still playing is cut off, so picking a
  // new sound or letting go of the volume slider previews it right away.
  function play(path) {
    root.pendingSound = String(path || "")
    if (soundProc.running) {
      root.stoppingSound = true
      soundProc.running = false
      return
    }
    root.startPendingSound()
  }

  function startPendingSound() {
    if (!root.pendingSound) return
    root.lastError = ""
    root.stoppingSound = false
    soundProc.command = ["pw-play", "--volume", Model.volumeArg(root.settings.volume), root.pendingSound]
    root.pendingSound = ""
    soundProc.running = true
  }

  function testSound(stage) {
    root.play(stage === "critical" ? root.settings.criticalSound : root.settings.warningSound)
  }

  function notify(kind) {
    var args = ["omarchy-notification-send"]
    if (kind === "critical")
      args = args.concat(["-g", "󰂃", "-u", "critical", "-i", "battery-caution", "Battery critical", root.level + "% left. Plug in now."])
    else if (kind === "warning")
      args = args.concat(["-g", "󰂃", "-u", "normal", "-i", "battery-low", "-t", "10000", "Battery low", root.level + "% left. Plug in soon."])
    else
      args = args.concat(["-g", "󰌪", "-u", "low", "-t", "8000", "Power saver on", "Battery at " + root.level + "%. Plugging in switches back."])
    Quickshell.execDetached(args)
  }

  // powerprofilesctl directly, not omarchy-powerprofiles-set: that one would
  // remember power-saver as the battery profile for every later unplug. On
  // plug-in, omarchy.battery restores the AC profile as it always does.
  function switchToPowerSaver() {
    if (saverProc.running) return
    saverProc.running = true
  }

  function refreshCharge() {
    if (!chargeStatusProc.running) chargeStatusProc.running = true
  }

  function applyChargeLimit() {
    var target = Model.chargeLimitTarget(root.chargeStatus, root.settings)
    if (!target || !root.chargeStatus.writable || chargeSetProc.running) return
    chargeSetProc.command = [root.chargeLimitBin, "set", target]
    chargeSetProc.running = true
  }

  function runChargeSetup() {
    if (setupProc.running) return
    root.lastError = ""
    root.chargeSetupRunning = true
    setupProc.running = true
  }

  function scanSounds() {
    if (!scanProc.running) scanProc.running = true
  }

  Process {
    id: soundProc
    stderr: StdioCollector { id: soundErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0 && !root.stoppingSound)
        root.lastError = "Could not play " + Model.soundLabel(command[command.length - 1])
          + (String(soundErr.text || "").trim() ? ": " + String(soundErr.text).trim() : "")
      root.stoppingSound = false
      root.startPendingSound()
    }
  }

  Process {
    id: saverProc
    command: ["powerprofilesctl", "set", "power-saver"]
    stderr: StdioCollector { id: saverErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.lastError = "Could not switch to Power Saver: " + String(saverErr.text || "").trim()
    }
  }

  Process {
    id: chargeStatusProc
    command: [root.chargeLimitBin, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.chargeStatus = Model.parseChargeStatus(text)
        root.chargeKnown = true
        root.reapplyChargeLimit()
      }
    }
  }

  Process {
    id: chargeSetProc
    stderr: StdioCollector { id: chargeErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.lastError = String(chargeErr.text || "").trim() || "Could not change the charge limit"
      root.refreshCharge()
    }
  }

  // pkexec puts up Omarchy's password dialog. Cancelling it exits 126.
  Process {
    id: setupProc
    command: ["pkexec", root.chargeSetupBin]
    stderr: StdioCollector { id: setupErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.chargeSetupRunning = false
      if (exitCode === 126) return
      if (exitCode !== 0) {
        root.lastError = String(setupErr.text || "").trim() || "Setup failed"
        return
      }
      root.applyChargeAfterRefresh = true
      root.refreshCharge()
    }
  }

  // find exits non-zero when the custom folder does not exist yet, but still
  // prints what it found in the system folder, so the exit code is ignored.
  // -L lets a custom sound be a symlink to a file kept elsewhere.
  Process {
    id: scanProc
    command: ["find", "-L", Model.FREEDESKTOP_DIR, root.customSoundDir, "-maxdepth", "1", "-type", "f"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.sounds = Model.soundOptions(String(text || "").split("\n"), root.customSoundDir,
        [root.settings.warningSound, root.settings.criticalSound])
    }
  }

  FileView {
    path: root.shellConfigPath
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.applyShellConfig(text())
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.check()
  }

  Connections {
    target: UPower
    function onOnBatteryChanged() { root.check() }
  }

  Connections {
    target: UPower.displayDevice
    function onPercentageChanged() { root.check() }
    function onStateChanged() { root.check() }
  }

  Component.onCompleted: {
    root.scanSounds()
    root.refreshCharge()
  }
}
