// Super Battery's bar widget: Omarchy's battery popup (omarchy.power, copied
// from Omarchy 4.0.6 under its MIT license, see NOTICE.md) with Alerts and
// Automations sections added below the power profile picker. Everything
// above the "Super Battery" marker further down is Omarchy's, changed only
// where a comment says so, to keep later upstream changes easy to carry over.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "PowerModel.js" as Model
import "Model.js" as SB

Panel {
  id: root
  moduleName: "paulbob.super-battery"
  ipcTarget: "paulbob.super-battery"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the togglePercentage method below.
  manageIpc: false
  property var batteryInfo: ({})
  property var systemInfo: ({})
  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false

  // Super Battery: the service holds every setting and all background work.
  // It can load after the bar does, so keep asking until it is there.
  property var service: null
  readonly property var sb: service ? service.settings : SB.normalizeSettings(root.settings)
  property string expanded: ""

  function findService() {
    if (!root.service && root.bar && root.bar.shell && typeof root.bar.shell.serviceFor === "function")
      root.service = root.bar.shell.serviceFor(root.moduleName)
  }

  function set(key, value) {
    if (root.service) root.service.setSetting(key, value)
  }

  function toggleExpanded(section) {
    root.expanded = root.expanded === section ? "" : section
  }

  // The file chooser is a normal window, and the open popup's layer would
  // cover it, so the popup closes while the chooser is up. Only the bar the
  // button was pressed on reopens it afterwards.
  property bool waitingForSound: false

  function addSound(stage) {
    if (!root.service || root.service.addingSound) return
    root.waitingForSound = true
    root.close()
    root.service.addSound(stage)
  }

  Connections {
    target: root.service
    function onAddSoundFinished(stage) {
      if (!root.waitingForSound) return
      root.waitingForSound = false
      root.expanded = stage
      root.open()
    }
  }

  Timer {
    interval: 1000
    running: !root.service
    repeat: true
    triggeredOnStart: true
    onTriggered: root.findService()
  }

  // Super Battery: read from the service so every bar shows the same value.
  readonly property bool showPercentage: (root.service ? root.sb.showPercentage : setting("showPercentage", false)) === true
  // With the percentage shown the button paints a text block wider than an
  // icon, so the open-panel mark takes the painted width instead of the
  // icon-sized fraction of the slot the fallback assumes.
  readonly property real openPanelIndicatorWidth: showPercentage && !button.vertical ? button.glyphPaintedWidth : 0
  readonly property bool batteryPresent: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent)
  }

  function upowerStates() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge
    }
  }

  function selectProfileByDelta(delta) {
    profileIndex = Model.selectProfileIndex(profileIndex, delta, profiles)
  }

  function activateSelectedProfile() {
    if (profileIndex < 0 || profileIndex >= profiles.length) return
    setProfile(profiles[profileIndex])
  }

  function batteryIcon() {
    var device = UPower.displayDevice
    return Model.batteryIcon(device, root.discharging, upowerStates())
  }

  function modeLabel() {
    var device = UPower.displayDevice
    return Model.modeLabel(device, root.discharging, upowerStates())
  }

  function profileIcon(name) {
    return Model.profileIcon(name)
  }

  readonly property bool fullyCharged: {
    var device = UPower.displayDevice
    return device && device.isPresent && device.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive
  }
  readonly property bool discharging: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent && UPower.onBattery)
  }
  readonly property bool chargeThresholdActive: {
    var device = UPower.displayDevice
    return Model.chargeThresholdActive(device, root.discharging, upowerStates())
  }
  readonly property bool batteryFull: fullyCharged || (!root.discharging && batteryFraction >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargeThresholdActive

  // 0..1 charge level, used by the visual progress bar.
  readonly property real batteryFraction: {
    var d = UPower.displayDevice
    return Model.batteryFraction(d)
  }

  readonly property bool charging: {
    var d = UPower.displayDevice
    return d && d.isPresent && !UPower.onBattery && !root.batteryFlowIdle
  }

  readonly property color batteryFillColor: {
    return root.bar ? root.bar.foreground : Commons.Color.foreground
  }

  // Cute agent-flavored phrases shown in the hero status line, rotated on a
  // timer so the panel feels alive when current is flowing (either direction).
  readonly property var chargingPhrases: [
    "Pumping power",
    "Injecting electrons",
    "Pouring juice",
    "Amassing watts",
    "Hoarding joules",
    "Sucking volts",
    "Topping reserves",
    "Soaking amps",
    "Inhaling kilowatts"
  ]
  readonly property var onBatteryPhrases: [
    "Slurping power",
    "Spending joules",
    "Draining watts",
    "Burning electrons",
    "Sipping juice",
    "Spending coulombs",
    "Bleeding amps",
    "Guzzling volts",
    "Munching reserves"
  ]
  property int phraseIndex: 0

  // Whichever list is "active" given the current power state.
  readonly property var activePhrases: {
    if (fullyCharged) return []
    if (charging) return chargingPhrases
    if (discharging) return onBatteryPhrases
    return []
  }
  readonly property bool rotatingPhrases: activePhrases.length > 0

  readonly property string heroStatusText: {
    if (fullyCharged) return "Fully charged"
    if (rotatingPhrases) return activePhrases[phraseIndex % activePhrases.length]
    return modeLabel()
  }

  function refresh() {
    if (!batteryPresent) return

    if (!batteryProc.running) batteryProc.running = true
    if (!profilesProc.running) profilesProc.running = true
    if (!systemProc.running) systemProc.running = true
  }

  function updateKeyValue(raw, targetName) {
    var next = Model.parseKeyValue(raw)
    // Keep last known good data if a refresh briefly returns nothing — happens
    // around AC plug/unplug events. Avoids the section collapsing mid-transition.
    if (Object.keys(next).length === 0) return
    if (targetName === "battery") batteryInfo = next
    else systemInfo = next
  }

  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    // Same guard as battery: preserve the last known profile list across
    // transient empty payloads so the buttons don't blink out.
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = parsed.profileIndex
    if (opened && !cursorActive) {
      var idx = profiles.indexOf(activeProfile)
      if (idx >= 0) profileIndex = idx
    }
  }

  function setProfile(profile) {
    if (!profile || actionProc.running) return
    actionProc.command = ["omarchy-powerprofiles-set", root.discharging ? "battery" : "ac", profile]
    actionProc.running = true
  }

  // Super Battery: saved through the service, the entry's only writer.
  function togglePercentage() {
    root.set("showPercentage", !root.showPercentage)
  }

  IpcHandler {
    target: "paulbob.super-battery"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.togglePercentage() }
    // Super Battery: open with one row's controls showing, e.g.
    //   omarchy-shell paulbob.super-battery openSection critical
    function openSection(section: string): void {
      root.expanded = section
      root.open()
    }
  }

  onOpenedChanged: {
    if (opened) {
      if (!batteryPresent) {
        close()
        return
      }

      refresh()
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
      // Super Battery: new custom sounds and a finished setup show up on open.
      if (root.service) {
        root.service.scanSounds()
        root.service.refreshCharge()
      }
    } else {
      root.expanded = ""
    }
  }

  onBatteryPresentChanged: if (!batteryPresent) close()

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  Process {
    id: batteryProc
    command: ["omarchy-battery-status", "--shell"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "battery") }
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: systemProc
    command: ["omarchy-system-stats"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "system") }
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  Timer { interval: 5000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  // Rotate the status phrase while the panel is open and we're in a
  // rotating state (charging or on battery). The text swap is wrapped in a
  // fade so the changeover reads as one organism rather than a hard cut.
  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    triggeredOnStart: false
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: {
        var n = root.activePhrases.length
        if (n > 0) root.phraseIndex = (root.phraseIndex + 1) % n
      }
    }
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  // If we leave a rotating state mid-swap, halt the animation and snap back
  // to full opacity so "FULLY CHARGED" is legible immediately rather than
  // appearing dimmed.
  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        heroStatus.opacity = 1.0
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showPercentage && !vertical
      ? Math.round(root.batteryFraction * 100) + "% " + root.batteryIcon()
      : root.batteryIcon()
    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? 2 : 1)
    tooltipText: ""
    onPressed: function(b) {
      if (!root.batteryPresent) return
      if (b === Qt.RightButton) root.togglePercentage()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.selectProfileByDelta(dx)
        else if (dy !== 0) root.selectProfileByDelta(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // Super Battery: scrolls when the open sections outgrow the screen.
      // The Column inside keeps Omarchy's indentation so upstream diffs apply.
      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds

      Column {
        id: column
        width: scroller.width
        spacing: Style.space(14)

        // ---------- Hero: battery icon · title/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.batteryIcon()
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Battery"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.heroStatusText.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.batteryInfo.percentage || "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // ---------- Battery progress bar ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Rectangle {
            id: barFill
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.batteryFillColor
            width: Math.max(barTrack.height, barTrack.width * root.batteryFraction)

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }

            // Subtle pulse while charging — visible signal that energy is flowing in.
            SequentialAnimation on opacity {
              running: root.charging && !root.fullyCharged && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }

        // ---------- Stats ----------
        // Visibility is intentionally only gated by "we've ever loaded data" so
        // the section never collapses mid-transition. fullyCharged is *not* part
        // of the condition: UPower briefly reports FullyCharged on plug-in when
        // the battery sits above the charge-control start threshold, and we
        // refuse to flicker the whole panel for that ~1s window.
        Row {
          visible: root.batteryInfo.percentage !== undefined
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Battery size"; value: root.batteryInfo.size || "" }
            InfoPair { label: "Charge cycles"; value: root.batteryInfo.cycles || "—" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: root.chargeThresholdActive ? "Charge limit" : (root.discharging ? "Time left" : "Time to full")
              value: root.chargeThresholdActive ? (root.batteryInfo.threshold || "-") : (root.batteryFlowIdle ? "-" : (root.batteryInfo.time || "—"))
            }
            InfoPair {
              label: root.chargeThresholdActive ? "Battery state" : (root.discharging ? "Discharging" : "Charging")
              value: root.chargeThresholdActive ? "Holding" : (root.batteryFull ? "-" : (root.batteryInfo.rate || ""))
            }
          }
        }

        // ---------- Power profile picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "POWER PROFILE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.profiles.length > 0
              ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length
              : 0

            Repeater {
              model: root.profiles
              Button {
                required property var modelData
                required property int index
                width: profileRow.cellWidth
                iconText: root.profileIcon(String(modelData))
                iconSize: Style.font.title
                text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.activeProfile === modelData
                hasCursor: root.cursorActive && root.profileIndex === index
                onClicked: root.setProfile(modelData)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.profileIndex = index
                  }
                }
              }
            }
          }
        }

        // ============================ Super Battery ============================
        // Everything from here to the end of the column is new. Each row shows
        // its current setting in one line; clicking a row opens its controls,
        // one row at a time, so the popup stays short.

        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          PanelSectionHeader {
            text: "ALERTS"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bottomPadding: Style.space(4)
          }

          SettingRow {
            section: "warning"
            glyph: "󰁼"
            title: "Warning"
            summary: SB.alertSummary(root.sb.warningOn, root.sb.warningLevel, root.sb.warningSound, 0)
            checked: root.sb.warningOn
            onSwitched: root.set("warningOn", !root.sb.warningOn)
          }

          Details {
            section: "warning"

            LevelSlider {
              label: "Play at"
              value: root.sb.warningLevel
              minimum: SB.LEVEL_MIN + 1
              maximum: SB.LEVEL_MAX
              onPicked: function(value) { root.set("warningLevel", value) }
            }

            SoundPicker {
              stage: "warning"
              value: root.sb.warningSound
            }

            AddSoundButton { stage: "warning" }
          }

          SettingRow {
            section: "critical"
            glyph: "󰁺"
            title: "Critical"
            summary: SB.alertSummary(root.sb.criticalOn, root.sb.criticalLevel, root.sb.criticalSound, root.sb.repeatMinutes)
            checked: root.sb.criticalOn
            onSwitched: root.set("criticalOn", !root.sb.criticalOn)
          }

          Details {
            section: "critical"

            LevelSlider {
              label: "Play at"
              value: root.sb.criticalLevel
              minimum: SB.LEVEL_MIN
              maximum: SB.LEVEL_MAX - 1
              onPicked: function(value) { root.set("criticalLevel", value) }
            }

            SoundPicker {
              stage: "critical"
              value: root.sb.criticalSound
            }

            AddSoundButton { stage: "critical" }

            DetailLabel { text: "Repeat" }

            Row {
              id: repeatRow
              width: parent.width - parent.leftPadding - parent.rightPadding
              spacing: Style.space(4)

              readonly property var choices: SB.repeatOptions()

              Repeater {
                model: repeatRow.choices
                Button {
                  required property var modelData
                  width: (repeatRow.width - repeatRow.spacing * (repeatRow.choices.length - 1)) / repeatRow.choices.length
                  text: modelData.value === "0" ? "Once" : modelData.value + " min"
                  fontSize: Style.font.caption
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  horizontalPadding: Style.space(2)
                  bordered: true
                  active: String(root.sb.repeatMinutes) === modelData.value
                  onClicked: root.set("repeatMinutes", Number(modelData.value))
                }
              }
            }
          }

          SettingRow {
            section: "sound"
            glyph: "󰕾"
            title: "Volume and notifications"
            summary: root.sb.volume + "% · " + (root.sb.notify ? "notifications on" : "sound only")
            switchable: false
          }

          Details {
            section: "sound"

            LevelSlider {
              label: "Volume"
              value: root.sb.volume
              minimum: 0
              maximum: 100
              // Letting go plays the warning sound at the new level.
              onPicked: function(value) {
                root.set("volume", value)
                if (root.service) root.service.testSound("warning")
              }
            }

            Toggle {
              width: parent.width - parent.leftPadding - parent.rightPadding
              label: "Show notifications"
              description: "Alerts at 10% or lower stay sound only: Omarchy already says \"Time to recharge!\" there."
              checked: root.sb.notify
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.set("notify", !root.sb.notify)
            }
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          PanelSectionHeader {
            text: "AUTOMATIONS"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bottomPadding: Style.space(4)
          }

          SettingRow {
            section: "saver"
            glyph: "󰌪"
            title: "Auto power saver"
            summary: SB.saverSummary(root.sb)
            checked: root.sb.saverOn
            onSwitched: root.set("saverOn", !root.sb.saverOn)
          }

          Details {
            section: "saver"

            LevelSlider {
              label: "Switch at"
              value: root.sb.saverLevel
              minimum: SB.LEVEL_MIN
              maximum: SB.LEVEL_MAX
              onPicked: function(value) { root.set("saverLevel", value) }
            }

            DetailLabel { text: "Once per discharge, so picking another profile afterwards sticks. Plugging in switches back to your AC profile." }
          }

          SettingRow {
            readonly property var status: root.service ? root.service.chargeStatus : SB.parseChargeStatus("")
            section: "charge"
            glyph: "󰂄"
            title: "Charge limit"
            summary: root.service && root.service.chargeLimitNeedsSetup
              ? "Needs a one-time setup"
              : SB.chargeSummary(status, root.sb)
            checked: root.sb.chargeLimitOn
            switchable: status.kind !== "none"
            onSwitched: root.set("chargeLimitOn", !root.sb.chargeLimitOn)
          }

          Details {
            section: "charge"
            readonly property var status: root.service ? root.service.chargeStatus : SB.parseChargeStatus("")

            LevelSlider {
              visible: parent.status.kind === "threshold"
              label: "Stop charging at"
              value: root.sb.chargeLimit
              minimum: 50
              maximum: 100
              step: 5
              onPicked: function(value) { root.set("chargeLimit", value) }
            }

            DetailLabel {
              visible: parent.status.kind === "types"
              text: "This laptop has a conservation mode instead of a number: its firmware holds the battery at a fixed level (60% on most Lenovo models) to make it last longer."
            }

            DetailLabel {
              visible: parent.status.kind === "none"
              text: "This laptop's battery driver has no charge limit control."
            }
          }

          // Shown whenever the saved limit cannot be written yet, open or not:
          // it is the one thing here that needs the user to act.
          Item {
            visible: !!root.service && root.service.chargeLimitNeedsSetup
            width: parent.width
            implicitHeight: setupRow.implicitHeight + Style.space(8)

            RowLayout {
              id: setupRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              DetailLabel {
                Layout.fillWidth: true
                text: root.service && root.service.chargeSetupRunning
                  ? "Waiting for your password…"
                  : "Changing the charge limit needs your password once."
              }

              Button {
                text: "Set up"
                iconText: "󰌾"
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                onClicked: if (root.service) root.service.runChargeSetup()
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: !!root.service && root.service.lastError !== ""
          text: root.service ? root.service.lastError : ""
          color: Commons.Color.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
          width: parent.width
        }
      }
      }
    }
  }

  // ----------------------------- Super Battery -----------------------------

  // One setting on one line: glyph, title, current value, and a switch.
  // Clicking the row (not the switch) opens its controls below it.
  component SettingRow: Item {
    id: row

    property string section: ""
    property string glyph: ""
    property string title: ""
    property string summary: ""
    property bool checked: false
    property bool switchable: true
    readonly property bool isExpanded: root.expanded === section

    signal switched()

    width: parent ? parent.width : 0
    implicitHeight: Math.max(Style.space(38), rowLabels.implicitHeight + Style.space(12))

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: rowHover.hovered || row.isExpanded
        ? Style.hoverFillFor(root.bar.foreground, Commons.Color.accent, Commons.Color.urgent)
        : "transparent"
    }

    HoverHandler { id: rowHover }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleExpanded(row.section)
    }

    Text {
      id: rowGlyph
      textFormat: Text.PlainText
      text: row.glyph
      color: root.bar.foreground
      opacity: row.switchable && !row.checked ? 0.45 : 1
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.iconLarge
      width: Style.space(26)
      horizontalAlignment: Text.AlignHCenter
      anchors.left: parent.left
      anchors.leftMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
    }

    Column {
      id: rowLabels
      anchors.left: rowGlyph.right
      anchors.leftMargin: Style.space(8)
      anchors.right: chevron.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        text: row.title
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width
      }

      Text {
        textFormat: Text.PlainText
        text: row.summary
        color: root.bar.foreground
        opacity: 0.6
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        width: parent.width
      }
    }

    Text {
      id: chevron
      text: row.isExpanded ? "󰅀" : "󰅂"
      color: root.bar.foreground
      opacity: 0.5
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      anchors.right: rowSwitch.visible ? rowSwitch.left : parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    ToggleSwitch {
      id: rowSwitch
      visible: row.switchable
      checked: row.checked
      foreground: root.bar.foreground
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      onToggled: row.switched()
    }
  }

  // A row's controls. Only the open row's are shown.
  component Details: Column {
    property string section: ""

    visible: root.expanded === section
    width: parent ? parent.width : 0
    leftPadding: Style.space(38)
    rightPadding: Style.space(4)
    topPadding: Style.space(4)
    bottomPadding: Style.space(10)
    spacing: Style.space(10)
  }

  component DetailLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.Wrap
    // Inside Details it spans the padded width; inside a layout the layout
    // sizes it (Layout.fillWidth), and a RowLayout has no padding to read.
    width: parent && parent.leftPadding !== undefined ? parent.width - parent.leftPadding - parent.rightPadding : implicitWidth
  }

  // A labeled percentage slider that saves when let go, not on every step
  // of the drag: each save rewrites shell.json.
  component LevelSlider: Column {
    id: levelSlider

    property string label: ""
    property real value: 0
    property real minimum: 0
    property real maximum: 100
    property real step: 1

    signal picked(int value)

    width: parent ? parent.width - parent.leftPadding - parent.rightPadding : 0
    spacing: Style.space(4)

    Item {
      width: parent.width
      implicitHeight: sliderLabel.implicitHeight

      InfoLabel {
        id: sliderLabel
        text: levelSlider.label
        anchors.left: parent.left
      }

      InfoValue {
        text: Math.round(slider.liveValue) + "%"
        anchors.right: parent.right
      }
    }

    PanelSlider {
      id: slider
      width: parent.width
      bar: root.bar
      minimum: levelSlider.minimum
      maximum: levelSlider.maximum
      step: levelSlider.step
      integer: true
      value: levelSlider.value
      tickColor: Commons.Color.popups.background
      onReleased: function(value) { levelSlider.picked(Math.round(value)) }
    }
  }

  // ‹ Sound name › plus a Test button. Arrows instead of a dropdown: a
  // dropdown's list would be cut off at the edge of the bar popup's window.
  // Each step plays the sound it lands on.
  component SoundPicker: RowLayout {
    id: picker

    property string stage: "warning"
    property string value: ""
    readonly property var options: root.service ? root.service.sounds : []
    readonly property int index: {
      for (var i = 0; i < options.length; i++) if (options[i].value === value) return i
      return -1
    }

    function move(delta) {
      if (options.length === 0) return
      var next = options[((index < 0 ? 0 : index) + delta + options.length) % options.length].value
      root.set(picker.stage === "critical" ? "criticalSound" : "warningSound", next)
      if (root.service) root.service.play(next)
    }

    width: parent ? parent.width - parent.leftPadding - parent.rightPadding : 0
    spacing: Style.space(4)

    Button {
      iconText: "󰅁"
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
      bordered: true
      onClicked: picker.move(-1)
    }

    InfoValue {
      Layout.fillWidth: true
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      text: picker.index >= 0 ? picker.options[picker.index].label : SB.soundLabel(picker.value)
    }

    Button {
      iconText: "󰅂"
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
      bordered: true
      onClicked: picker.move(1)
    }

    // Turns into Stop while any sound plays, since a song can run for minutes.
    Button {
      readonly property bool playing: !!root.service && root.service.playing
      text: playing ? "Stop" : "Test"
      iconText: playing ? "󰓛" : "󰐊"
      fontSize: Style.font.bodySmall
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
      bordered: true
      onClicked: {
        if (!root.service) return
        if (playing) root.service.stopSound()
        else root.service.testSound(picker.stage)
      }
    }
  }

  // Picks a file with the desktop file chooser, adds it to the sounds the
  // arrows step through, and selects it for this alert.
  component AddSoundButton: Button {
    property string stage: "warning"

    width: parent ? parent.width - parent.leftPadding - parent.rightPadding : 0
    text: "Add a sound file"
    iconText: "󰐕"
    fontSize: Style.font.bodySmall
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    bordered: true
    onClicked: root.addSound(stage)
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
