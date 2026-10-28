// Headless check of Service.qml against the real UPower, pw-play, and
// charge limit files, with a fake shell.json and a stand-in for the shell's
// plugin API. No window opens and nothing outside the scratch copy is
// written: the charge limit is only read, never set.
//   test/run-harness.sh
// Plays the warning sound once, quietly. Prints PASS/FAIL lines and exits.
import QtQuick
import Quickshell

ShellRoot {
  id: harness

  property var saved: null
  property int failures: 0
  // Process.running flips once the child has actually started, which is
  // after testSound() returns, so a single read right after it proves nothing.
  property bool sawPlaying: false

  function expect(name, ok, detail) {
    console.log((ok ? "PASS " : "FAIL ") + name + (detail ? "  (" + detail + ")" : ""))
    if (!ok) harness.failures++
  }

  QtObject {
    id: fakeShell
    function updateEntryInline(id, settings) {
      harness.saved = { id: id, settings: JSON.parse(JSON.stringify(settings)) }
      return true
    }
  }

  Service {
    id: service
    shell: fakeShell
    manifest: ({ id: "paulbob.super-battery" })
    shellConfigPath: decodeURIComponent(String(Qt.resolvedUrl("shell.json")).replace(/^file:\/\//, ""))
    onPlayingChanged: if (playing) harness.sawPlaying = true
  }

  Timer {
    interval: 2000
    running: true
    onTriggered: {
      harness.expect("reads the battery", service.level >= 0, "level " + service.level + "%, discharging " + service.discharging)
      harness.expect("loads settings from the bar entry", service.settingsLoaded && service.settings.warningLevel === 33,
        "warningLevel " + service.settings.warningLevel)
      harness.expect("finds sounds", service.sounds.length > 0, service.sounds.map(function(s) { return s.label }).join(", "))
      harness.expect("reads the charge limit", service.chargeKnown && service.chargeStatus.kind !== "",
        JSON.stringify(service.chargeStatus))
      harness.expect("no setup asked for while the limit is off", !service.chargeLimitNeedsSetup)

      service.setSetting("volume", 30)
      harness.expect("saves through the shell API, keeping unknown fields",
        harness.saved && harness.saved.id === "paulbob.super-battery"
          && harness.saved.settings.volume === 30 && harness.saved.settings.futureField === "kept"
          && harness.saved.settings.warningLevel === 33,
        JSON.stringify(harness.saved))

      if (service.chargeStatus.kind !== "none" && !service.chargeStatus.writable) {
        service.setSetting("chargeLimitOn", !service.chargeStatus.value || service.chargeStatus.value === "Standard" || service.chargeStatus.value === "100")
        harness.expect("asks for the one-time setup when the limit cannot be written yet", service.chargeLimitNeedsSetup)
        service.setSetting("chargeLimitOn", false)
      }

      service.testSound("warning")
      done.start()
    }
  }

  Timer {
    id: done
    interval: 4000
    onTriggered: {
      harness.expect("pw-play ran", harness.sawPlaying)
      harness.expect("sound finished without error", !service.playing && service.lastError === "", service.lastError)
      console.log(harness.failures === 0 ? "ALL PASS" : harness.failures + " FAILED")
      Qt.exit(harness.failures === 0 ? 0 : 1)
    }
  }
}
