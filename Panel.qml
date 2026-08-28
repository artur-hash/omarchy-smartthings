import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Three screens: setup, the device list, one device's detail. Owns no network
// access of its own — every call leaves through bin/smartthings.
//
// Ui/Panel is open-state and IPC plumbing; it paints nothing. Every first-party
// panel in this shell builds its own floating card anchored to the bar icon,
// and without one here the content would render clipped to the bar strip rather
// than as a card near the icon. `host` is BarWidget.qml's root Item, injected by
// its Loader, and stands in for the button other panels anchor to.
Panel {
  id: panel

  moduleName: "io.github.artur-hash.smartthings"
  ipcTarget: "io.github.artur-hash.smartthings"

  property QtObject host: null
  property Item anchorButton: null
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  property string busy: ""
  property string actionError: ""
  property string openDeviceId: ""      // "" means the list screen

  readonly property bool hasToken: panel.host ? panel.host.hasToken : false
  readonly property string bin: host ? host.pluginDir + "bin/smartthings" : ""

  readonly property var groups: panel.host
    ? Model.groupByRoom(panel.host.devices, panel.host.rooms,
                        panel.host.roomsScoped, panel.host.roomLocations)
    : []

  readonly property var openDevice: {
    if (!panel.host || panel.openDeviceId === "") return null
    var list = panel.host.devices
    for (var i = 0; i < list.length; i++) if (list[i].id === panel.openDeviceId) return list[i]
    return null
  }
  readonly property var openStatus: (panel.host && panel.openDeviceId !== "")
    ? (panel.host.statuses[panel.openDeviceId] || null) : null

  function statusOf(id) { return (panel.host && panel.host.statuses[id]) || null }

  // What the last write asked for, held until a later read either confirms it or
  // shows the device dropped it. A SmartThings device answers COMPLETED for a
  // command it then silently ignores — an air conditioner drops a setpoint while
  // it is off, and a television has no more reason to be honest — so the only
  // confirmation worth trusting is reading the state back.
  property var pending: null        // { deviceId, key, value, label }
  property string lastWrite: ""     // the device the last command went to
  property int verifyAttempts: 0

  // Gaps between confirmation reads, landing at roughly 3, 5, 7 and 11 seconds.
  // Measured on this hardware: a change was absent from the cloud at 1.4s and
  // present by 3.0-3.2s, so the first check usually settles it and the rest
  // exist for a slow day.
  readonly property var verifyDelays: [3000, 1800, 2500, 4000]

  // A control the last write asked for but nothing has confirmed yet. Drawn
  // selected so the click registers, and dimmed so the panel never claims a
  // state it has not read back.
  function isPending(key, value) {
    return panel.pending !== null && panel.pending.key === key
      && panel.pending.value === String(value)
      && panel.pending.deviceId === panel.openDeviceId
  }

  onOpenedChanged: if (panel.opened) {
    panel.pending = null
    panel.dial = null
    panel.actionError = ""
    if (panel.host) panel.host.refreshAll()
  }

  // ---- writing

  function send(device, capability, command, value, key, label, numeric, expect) {
    if (!panel.host || device === "") return
    panel.actionError = ""
    panel.busy = key || capability
    panel.lastWrite = device
    if (key) panel.pending = { deviceId: device, key: key, label: label || key,
                               value: String(expect !== undefined ? expect : value) }
    var cmd = [panel.bin, "send", "--device", device, "--capability", capability, "--command", command]
    if (value !== undefined && value !== null && value !== "")
      cmd.push(numeric ? "--number" : "--arg", String(value))
    action.command = cmd
    action.running = true
  }

  Process {
    id: action
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function (exitCode) {
      panel.busy = ""
      if (exitCode !== 0) {
        var msg = ""
        try { msg = JSON.parse(String(actionErr.text || "")).error || "" } catch (e) {}
        panel.actionError = msg !== "" ? msg : "Command failed."
        panel.pending = null
        if (panel.host) panel.host.refreshAll()
        return
      }
      // The cloud accepting a command is not the device applying it, and the
      // reported state lags the write. Reading now returns the old value and
      // looks like a failure, so the read waits.
      panel.verifyAttempts = 0
      verifyTimer.interval = panel.verifyDelays[0]
      verifyTimer.restart()
    }
  }

  // Verification reads through its own process rather than the widget's poll,
  // which returns early when a read is already running: a poll in flight would
  // make the confirmation a silent no-op and strand the pending write forever,
  // leaving a button that claims a state nothing ever checked.
  Process {
    id: verifier
    stdout: StdioCollector { id: verifyOut; waitForEnd: true }
    onExited: function (exitCode) {
      var s = Model.parseStatuses(verifyOut.text)
      if (s.ok && panel.host) {
        // Merge rather than replace: this read covers one device, and the rest
        // of the account is still valid.
        var merged = {}
        for (var k in panel.host.statuses) merged[k] = panel.host.statuses[k]
        for (var j in s.byId) merged[j] = s.byId[j]
        panel.host.statuses = merged
      }
      if (!panel.pending) { panel.lastWrite = ""; return }
      panel.settlePending(s.ok ? s.byId[panel.pending.deviceId] : null)
    }
  }

  Timer {
    id: verifyTimer
    interval: 3000
    repeat: false
    onTriggered: {
      var target = panel.pending ? panel.pending.deviceId : panel.lastWrite
      if (!panel.host || target === "") return
      // Come back rather than give up: dropping this tick would strand the
      // pending write with nothing left to settle it.
      if (verifier.running) { verifyTimer.interval = 1000; verifyTimer.restart(); return }
      if (panel.pending) panel.verifyAttempts = panel.verifyAttempts + 1
      verifier.command = [panel.bin, "status", "--device", target]
      verifier.running = true
    }
  }

  function settlePending(st) {
    if (!panel.pending) return
    var want = panel.pending

    // A read that failed says nothing about whether the write landed. Try again
    // while there are tries left rather than quietly dropping the request.
    if (!st) {
      if (panel.verifyAttempts < panel.verifyDelays.length) {
        verifyTimer.interval = panel.verifyDelays[panel.verifyAttempts]
        verifyTimer.restart()
      } else panel.pending = null
      return
    }

    var got = String(st[want.key] === null || st[want.key] === undefined ? "" : st[want.key])
    if (got === want.value) { panel.pending = null; return }

    if (panel.verifyAttempts < panel.verifyDelays.length) {
      verifyTimer.interval = panel.verifyDelays[panel.verifyAttempts]
      verifyTimer.restart()
      return
    }
    panel.pending = null
    panel.actionError = "The device did not apply " + want.label + " " + want.value
      + ". It is still " + (got === "" ? "unchanged" : got)
      + " — some devices ignore settings that do not apply to their current state."
  }

  // ---- the stepper, dialled locally
  // Sending one command per press and disabling the buttons until the cloud
  // answered would mean a round trip per degree. Stepping is local and instant;
  // one write goes out after the presses stop.
  property var dial: null           // { deviceId, key, value, control }

  function stepBy(device, control, delta) {
    var base = (panel.dial && panel.dial.key === control.key) ? panel.dial.value
             : (control.value === null ? control.min : control.value)
    panel.actionError = ""
    panel.dial = { deviceId: device, key: control.key,
                   value: Model.clampSetpoint(base + delta, control.min, control.max),
                   control: control }
    dialSend.restart()
  }

  function shownValue(control) {
    return (panel.dial && panel.dial.key === control.key) ? panel.dial.value : control.value
  }

  Timer {
    id: dialSend
    interval: 600
    repeat: false
    onTriggered: {
      if (!panel.dial) return
      // A write is still on the wire; the last value dialled is the one that
      // should win, so wait rather than send a value about to be superseded.
      if (action.running) { dialSend.restart(); return }
      var d = panel.dial
      panel.dial = null
      panel.send(d.deviceId, d.control.capability, d.control.command, d.value,
                 d.control.key, d.control.label.toLowerCase(), d.control.numeric === true)
    }
  }

  // ---- token

  function saveToken(value) {
    var v = String(value || "").trim()
    if (v === "") return
    panel.actionError = ""
    // Re-enabled every time: setting stdinEnabled false imperatively does not
    // reset, which made the whole process one-shot and meant a correct token
    // pasted after a rejected one needed a shell restart.
    tokenSet.stdinEnabled = true
    tokenSet.pendingToken = v
    tokenSet.running = true
  }

  Process {
    id: tokenSet
    property string pendingToken: ""
    command: [panel.bin, "token", "set"]
    stdinEnabled: true
    stderr: StdioCollector { id: tokenSetErr; waitForEnd: true }
    onStarted: {
      // stdin, never argv: a token as an argument lands in /proc/<pid>/cmdline,
      // readable by every process on this session for the life of the call.
      write(tokenSet.pendingToken + "\n")
      stdinEnabled = false
    }
    onExited: function (exitCode) {
      tokenSet.pendingToken = ""
      if (exitCode !== 0) {
        var msg = "Could not save the token."
        try { msg = JSON.parse(String(tokenSetErr.text)).error || msg } catch (e) {}
        panel.actionError = msg
        return
      }
      panel.actionError = ""
      if (panel.host) panel.host.refreshAll()
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: panel.anchorButton
    owner: panel
    bar: panel.bar
    open: panel.opened
    focusTarget: panel.hasToken ? keyCatcher : tokenField
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(column.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      Keys.priority: Keys.AfterItem
      blocked: !panel.hasToken
    }

    Flickable {
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        // ---- title bar: names the application, and goes back from a detail
        Item {
          width: parent.width
          height: Math.max(titleText.implicitHeight, backButton.height)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)
            PanelActionButton {
              id: backButton
              visible: panel.openDeviceId !== ""
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰅁"
              tooltipText: "All devices"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
              onClicked: { panel.openDeviceId = ""; panel.pending = null; panel.actionError = "" }
            }
            Text {
              id: titleText
              anchors.verticalCenter: parent.verticalCenter
              text: panel.openDevice ? panel.openDevice.label : "SmartThings"
              textFormat: Text.PlainText
              color: panel.foreground
              font.family: panel.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
              width: Math.min(implicitWidth, Style.space(240))
            }
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            // Never on the setup screen: with no token there is no stale data,
            // only no data, and the screen behind this already explains it.
            visible: panel.hasToken && panel.host && panel.host.stale
            text: "stale"
            color: Color.urgent
            font.family: panel.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { width: parent.width; foreground: panel.foreground }

        // Errors live above every screen, not inside one: the setup screen is
        // the one that most needs to show them.
        Text {
          visible: panel.actionError !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          text: panel.actionError
          textFormat: Text.PlainText
          color: Color.urgent
          font.family: panel.fontFamily
          font.pixelSize: Style.font.caption
        }

        // ================================================== 1. setup
        Column {
          visible: !panel.hasToken
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            color: Qt.darker(panel.foreground, 1.3)
            font.family: panel.fontFamily
            font.pixelSize: Style.font.bodySmall
            // Line breaks only between the steps. Wrapping inside one is the
            // Text's job, and hard-wrapping it here fights the panel's width.
            //
            // The CLI is listed first because it is the only credential that
            // lasts, and because for some accounts it is the only one that
            // works at all -- see the note below, which is not a footnote for
            // the curious but the explanation a whole class of user needs.
            text: "The lasting way — the SmartThings CLI holds a session that "
                + "renews itself, so you do this once:\n\n"
                + "    npm install -g @smartthings/cli\n"
                + "    smartthings locations\n\n"
                + "Log in when the browser opens. This panel picks the session up "
                + "on its own.\n\n"
                + "The quick way — paste a personal access token from "
                + "account.smartthings.com/tokens, granting the device scopes "
                + "(list, read, execute) and the location read scope. SmartThings "
                + "expires it 24 hours after it is created, so it has to be done "
                + "again tomorrow."
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            color: Qt.darker(panel.foreground, 1.7)
            font.family: panel.fontFamily
            font.pixelSize: Style.font.caption
            text: "If your home was set up by someone else and shared with you, the "
                + "CLI is the only route: authorising an app requires installing it "
                + "into a location you own, and a shared member owns none. Your "
                + "devices still read and control normally."
          }

          TextField {
            id: tokenField
            width: parent.width
            placeholderText: "Personal access token"
            password: true
            foreground: panel.foreground
            font.family: panel.fontFamily
            onAccepted: { panel.saveToken(text); text = "" }
          }

          Button {
            text: "Save token"
            foreground: panel.foreground
            fontFamily: panel.fontFamily
            onClicked: { panel.saveToken(tokenField.text); tokenField.text = "" }
          }
        }

        // ================================================== 2. device list
        Column {
          visible: panel.hasToken && panel.openDeviceId === ""
          width: parent.width
          spacing: Style.space(10)

          // Said once, quietly, on the screen the user actually lives on. A
          // pasted token works perfectly until tomorrow morning, and finding
          // that out then is worse than reading it now.
          Text {
            visible: panel.host && panel.host.tokenSource === "keyring"
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "This token expires 24 hours after you created it."
            color: Qt.darker(panel.foreground, 1.6)
            font.family: panel.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: panel.host && panel.host.devices.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: "No devices visible with this token."
            textFormat: Text.PlainText
            color: Qt.darker(panel.foreground, 1.4)
            font.family: panel.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: panel.groups
            Column {
              required property var modelData
              width: column.width
              spacing: Style.space(6)

              // With no location scope every device lands in one unnamed group,
              // and the heading simply does not appear.
              Text {
                visible: modelData.room !== ""
                text: modelData.room.toUpperCase()
                textFormat: Text.PlainText
                color: Qt.darker(panel.foreground, 1.7)
                font.family: panel.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              Repeater {
                model: modelData.devices
                Rectangle {
                  required property var modelData
                  readonly property var st: panel.statusOf(modelData.id)
                  readonly property bool switchable: modelData.caps.indexOf("switch") !== -1
                  readonly property bool isOn: st && st.switch === "on"

                  width: parent.width
                  height: rowCol.implicitHeight + Style.space(18)
                  radius: Style.cornerRadius + 2
                  color: Qt.rgba(panel.foreground.r, panel.foreground.g, panel.foreground.b, 0.04)
                  border.width: Style.spacing.hairline
                  border.color: Qt.rgba(panel.foreground.r, panel.foreground.g, panel.foreground.b, 0.12)

                  Column {
                    id: rowCol
                    x: Style.space(10)
                    y: Style.space(9)
                    width: parent.width - Style.space(20) - powerBox.width - Style.space(10)
                    spacing: Style.space(2)
                    Text {
                      width: parent.width
                      text: modelData.label
                      textFormat: Text.PlainText
                      color: panel.foreground
                      font.family: panel.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }
                    Text {
                      width: parent.width
                      visible: text !== ""
                      text: Model.summaryFor(modelData, st)
                      textFormat: Text.PlainText
                      color: Qt.darker(panel.foreground, 1.5)
                      font.family: panel.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  // Filled when running, outlined when not. The common action
                  // costs one click without opening the device.
                  Rectangle {
                    id: powerBox
                    visible: parent.switchable
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(28); height: Style.space(28)
                    radius: Style.cornerRadius
                    color: parent.isOn ? Style.selectedFillFor(panel.foreground, Color.accent) : "transparent"
                    border.width: Style.spacing.hairline
                    border.color: parent.isOn ? Style.selectedBorderFor(panel.foreground, Color.accent)
                                              : Qt.rgba(panel.foreground.r, panel.foreground.g, panel.foreground.b, 0.3)
                    opacity: panel.busy !== "" ? 0.5 : 1.0
                    Text {
                      anchors.centerIn: parent
                      text: "⏻"
                      color: parent.parent.isOn ? Style.selectedStateColor(panel.foreground, Color.accent)
                                                : Qt.darker(panel.foreground, 1.3)
                      font.family: panel.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        var want = parent.parent.isOn ? "off" : "on"
                        panel.send(parent.parent.modelData.id, "switch", want,
                                   undefined, "switch", "power", false, want)
                      }
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    anchors.rightMargin: powerBox.visible ? Style.space(46) : 0
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { panel.openDeviceId = parent.modelData.id; panel.actionError = "" }
                  }
                }
              }
            }
          }
        }

        // ================================================== 3. device detail
        Column {
          visible: panel.hasToken && panel.openDeviceId !== ""
          width: parent.width
          spacing: Style.space(10)

          // A bordered card per function, so the panel does not read as one
          // undifferentiated list of controls.
          component Card: Rectangle {
            default property alias content: cardCol.data
            required property string heading
            width: column.width
            height: cardCol.implicitHeight + Style.space(20)
            radius: Style.cornerRadius + 2
            color: Qt.rgba(panel.foreground.r, panel.foreground.g, panel.foreground.b, 0.04)
            border.width: Style.spacing.hairline
            border.color: Qt.rgba(panel.foreground.r, panel.foreground.g, panel.foreground.b, 0.12)
            Column {
              id: cardCol
              x: Style.space(10); y: Style.space(10)
              width: parent.width - Style.space(20)
              spacing: Style.space(6)
              Text {
                text: heading
                textFormat: Text.PlainText
                color: Qt.darker(panel.foreground, 1.7)
                font.family: panel.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
            }
          }

          // Readings first: what the room is like, before what can be changed.
          Card {
            heading: "READINGS"
            visible: panel.openDevice
              && Model.readingsFor(panel.openDevice, panel.openStatus).length > 0
            Repeater {
              model: panel.openDevice ? Model.readingsFor(panel.openDevice, panel.openStatus) : []
              Row {
                required property var modelData
                spacing: Style.space(10)
                Text {
                  width: Style.space(96)
                  text: modelData.label
                  color: Qt.darker(panel.foreground, 1.6)
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  text: modelData.text
                  textFormat: Text.PlainText
                  color: panel.foreground
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
              }
            }
          }

          Text {
            visible: panel.openDevice && Model.controlsFor(panel.openDevice, panel.openStatus).length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: "This device publishes nothing that can be changed from here."
            textFormat: Text.PlainText
            color: Qt.darker(panel.foreground, 1.5)
            font.family: panel.fontFamily
            font.pixelSize: Style.font.caption
          }

          // Every control is earned by a published capability. Nothing here is
          // keyed on device type, model or vendor, so a device offering
          // different values shows different buttons with no code change.
          Repeater {
            model: panel.openDevice ? Model.controlsFor(panel.openDevice, panel.openStatus) : []

            Card {
              required property var modelData
              heading: modelData.label

              // power / mute
              Rectangle {
                visible: modelData.kind === "power" || modelData.kind === "toggle"
                readonly property bool lit: modelData.kind === "power"
                  ? modelData.value === "on" : modelData.value === true
                width: Style.space(30); height: Style.space(30)
                radius: Style.cornerRadius
                color: lit ? Style.selectedFillFor(panel.foreground, Color.accent) : "transparent"
                border.width: Style.spacing.hairline
                border.color: lit ? Style.selectedBorderFor(panel.foreground, Color.accent)
                                  : Qt.rgba(panel.foreground.r, panel.foreground.g, panel.foreground.b, 0.3)
                Text {
                  anchors.centerIn: parent
                  text: modelData.kind === "power" ? "⏻" : "󰝟"
                  color: parent.lit ? Style.selectedStateColor(panel.foreground, Color.accent)
                                    : Qt.darker(panel.foreground, 1.3)
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: panel.send(
                    panel.openDeviceId, modelData.capability, modelData.command, undefined,
                    modelData.kind === "power" ? "switch" : "mute",
                    modelData.kind === "power" ? "power" : "mute", false,
                    modelData.kind === "power" ? modelData.command
                                               : (modelData.command === "mute" ? "muted" : "unmuted"))
                }
              }

              // steppers: volume, level, setpoint
              Row {
                visible: modelData.kind === "stepper"
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(12)
                PanelActionButton {
                  iconText: "-"; tooltipText: "Less"
                  foreground: panel.foreground; fontFamily: panel.fontFamily
                  onClicked: panel.stepBy(panel.openDeviceId, modelData, -1)
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: panel.shownValue(modelData) === null
                    ? "—" : (panel.shownValue(modelData) + modelData.unit)
                  color: panel.foreground
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  // Crisp while it is the user's own number, dimmed only once it
                  // has been sent and is waiting for the device to agree.
                  opacity: (!panel.dial && panel.isPending(modelData.key, modelData.value)) ? 0.5 : 1.0
                }
                PanelActionButton {
                  iconText: "+"; tooltipText: "More"
                  foreground: panel.foreground; fontFamily: panel.fontFamily
                  onClicked: panel.stepBy(panel.openDeviceId, modelData, 1)
                }
              }

              // choices: mode, fan, swing, preset, input
              Flow {
                visible: modelData.kind === "choice"
                width: parent.width
                spacing: Style.space(4)
                Repeater {
                  model: modelData.kind === "choice" ? modelData.options : []
                  Button {
                    required property var modelData
                    readonly property var control: parent.parent.parent.modelData
                    text: modelData
                    foreground: panel.foreground
                    fontFamily: panel.fontFamily
                    selected: modelData === control.value || panel.isPending(control.key, modelData)
                    // Half strength until a read confirms it: painting a
                    // requested value exactly like a confirmed one would claim a
                    // success nothing had checked.
                    opacity: panel.isPending(control.key, modelData) ? 0.5 : 1.0
                    onClicked: panel.send(panel.openDeviceId, control.capability, control.command,
                                          modelData, control.key, control.label.toLowerCase(), false)
                  }
                }
              }

              // transport and track: fire-and-forget, nothing to read back
              Flow {
                visible: modelData.kind === "transport" || modelData.kind === "track"
                width: parent.width
                spacing: Style.space(4)
                Repeater {
                  model: (modelData.kind === "transport" || modelData.kind === "track")
                    ? modelData.options : []
                  Button {
                    required property var modelData
                    readonly property var control: parent.parent.parent.modelData
                    text: modelData
                    foreground: panel.foreground
                    fontFamily: panel.fontFamily
                    selected: control.kind === "transport" && modelData === control.value
                    onClicked: panel.send(panel.openDeviceId, control.capability, modelData)
                  }
                }
              }
            }
          }
        }

        // Reachable from every screen once a token exists.
        Button {
          visible: panel.hasToken && panel.openDeviceId === ""
          text: "Replace token"
          foreground: panel.foreground
          fontFamily: panel.fontFamily
          onClicked: {
            clearToken.running = true
          }
        }

        Process {
          id: clearToken
          command: [panel.bin, "token", "clear"]
          onExited: if (panel.host) panel.host.refreshAll()
        }
      }
    }
  }
}
