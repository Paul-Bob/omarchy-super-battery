// Headless check of Service.qml against the real UPower, pw-play, and
// charge limit files, with a fake shell.json and a stand-in for the shell's
// plugin API, and of how Panel.qml finds the service under each kind of bar.
// No window opens and nothing outside the scratch copy is written: the charge
// limit is only read, never set.
//   test/run-harness.sh
// Plays the warning sound once, quietly, then adds a sound through a fake
// file chooser and stops it right away. Prints PASS/FAIL lines and exits.
import QtQuick
import Quickshell
import "ServiceRegistry.js" as ServiceRegistry

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
    shellConfigPath: harness.scratch("shell.json")
    customSoundDir: harness.scratch("sounds")
    onPlayingChanged: if (playing) harness.sawPlaying = true
    onAddSoundFinished: function(stage) { harness.addedFor = stage; added.start() }
  }

  property string addedFor: ""

  // What each kind of bar hands its widgets. Omarchy's built-in bar gives a
  // shell that finds the plugin's service. A replacement bar gives one whose
  // serviceFor() always returns null.
  QtObject {
    id: builtinShell
    function serviceFor(id) { return id === "paulbob.super-battery" ? harness.otherService : null }
  }
  QtObject {
    id: replacementShell
    function serviceFor(id) { return null }
  }
  Component {
    id: fakeBar
    QtObject {
      property var shell: null
      property color foreground: "white"
      property color barForeground: "white"
      property string fontFamily: "monospace"
    }
  }
  // Stands in for a second service in the registry checks. It has no settings
  // file, so it never alerts.
  Component {
    id: otherServiceComponent
    Service {
      shellConfigPath: harness.scratch("no-such-file.json")
      customSoundDir: harness.scratch("other-sounds")
    }
  }

  property var otherService: null
  property var builtinPanel: null
  property var replacementPanel: null
  property var panelComponent: null

  function makePanel(shellApi) {
    return harness.panelComponent.createObject(null, { bar: fakeBar.createObject(harness, { shell: shellApi }) })
  }

  // Waits for the service's own Component.onCompleted, which runs after this
  // root's. Both widgets start now, so they have had time to do anything they
  // would do later (the checks run about 6 seconds in).
  Component.onCompleted: Qt.callLater(harness.setUpPanels)

  function setUpPanels() {
    harness.expect("the service registers itself", ServiceRegistry.current() === service)
    harness.otherService = otherServiceComponent.createObject(harness)
    harness.expect("the newest service is the registered one", ServiceRegistry.current() === harness.otherService)
    ServiceRegistry.unregister(service)
    harness.expect("an older service going away keeps the newer one", ServiceRegistry.current() === harness.otherService)
    ServiceRegistry.register(service)

    harness.panelComponent = Qt.createComponent("Panel.qml")
    harness.expect("Panel.qml loads", harness.panelComponent.status === Component.Ready, harness.panelComponent.errorString())
    if (harness.panelComponent.status !== Component.Ready) return
    harness.builtinPanel = harness.makePanel(builtinShell)
    harness.replacementPanel = harness.makePanel(replacementShell)
  }

  function scratch(name) {
    return decodeURIComponent(String(Qt.resolvedUrl(name)).replace(/^file:\/\//, ""))
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
      harness.expect("under the built-in bar the widget uses serviceFor()",
        !!harness.builtinPanel && harness.builtinPanel.service === harness.otherService)
      harness.expect("under a replacement bar the widget finds the running service",
        !!harness.replacementPanel && harness.replacementPanel.service === service)
      harness.expect("no widget started a service of its own", ServiceRegistry.current() === service)
      if (harness.replacementPanel) harness.replacementPanel.set("showPercentage", true)
      harness.expect("under a replacement bar the widget saves through that service",
        harness.saved && harness.saved.settings.showPercentage === true)
      service.setSetting("showPercentage", false)

      ServiceRegistry.register(harness.otherService)
      if (harness.builtinPanel) harness.builtinPanel.destroy()
      harness.otherService.destroy()

      harness.sawPlaying = false
      service.addSound("critical")
    }
  }

  // The fake chooser (see run-harness.sh) picks the freedesktop bell.
  Timer {
    id: added
    interval: 1500
    onTriggered: {
      harness.expect("a service going away removes itself", ServiceRegistry.current() === null)
      ServiceRegistry.register(service)

      var copy = harness.scratch("sounds") + "/bell.oga"
      harness.expect("add sound: selects the copy for the alert", harness.addedFor === "critical"
        && service.settings.criticalSound === copy && harness.saved.settings.criticalSound === copy,
        service.settings.criticalSound + " " + service.lastError)
      harness.expect("add sound: the arrows offer it", service.sounds.some(function(s) { return s.value === copy }),
        service.sounds.map(function(s) { return s.label }).join(", "))
      harness.expect("add sound: plays it", harness.sawPlaying)
      service.testSound("warning")
      stopNow.start()
    }
  }

  // Stop while the sound is still going.
  Timer {
    id: stopNow
    interval: 250
    onTriggered: {
      harness.expect("Stop: a sound is playing to stop", service.playing)
      service.stopSound()
      stopped.start()
    }
  }

  Timer {
    id: stopped
    interval: 1000
    onTriggered: {
      harness.expect("Stop cuts the sound off without an error", !service.playing && service.lastError === "", service.lastError)
      console.log(harness.failures === 0 ? "ALL PASS" : harness.failures + " FAILED")
      Qt.exit(harness.failures === 0 ? 0 : 1)
    }
  }
}
