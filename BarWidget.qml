import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar entry. Owns the poll timer and the device inventory; the panel owns
// every screen and every write.
Item {
  id: root

  property var bar: null
  property var settings: ({})

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  // Ui/Panel supplies neither of these; every plugin derives them from the bar.
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // Structure changes rarely and costs one request, so it is read once per
  // session rather than per tick. Status is the expensive part: there is no
  // bulk endpoint -- /devices/status and /devices/health both answer HTTP 400 --
  // so it costs one request per device and only devices whose state is on
  // screen are worth paying for.
  property var devices: []
  property var rooms: ({})
  property bool roomsScoped: false
  property var statuses: ({})
  property int consecutiveFailures: 0
  property bool hasToken: false

  readonly property string label: Model.barLabel(root.devices, root.statuses)
  readonly property bool stale: root.consecutiveFailures > 0

  // The panel anchors its popup to this, not to the widget root: Ui/KeyboardPanel
  // positions from anchorItem's mapped geometry, and the root Item is not the
  // thing the user clicked.
  readonly property alias anchorButton: button

  readonly property bool panelOpen: panelLoader.item ? panelLoader.item.opened : false
  readonly property int pollBase: root.panelOpen ? 20000 : 90000

  function open()  { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  // Re-injected rather than set once on load: at onLoaded the button is not yet
  // inside the bar's window, so anchorItem.QsWindow is undefined and the panel
  // resolves no screen -- it then shows nothing, silently.
  function injectPanel() {
    var t = panelLoader.item
    if (!t) return
    t.host = root
    t.bar = root.bar
    t.anchorButton = button
  }
  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // ---- reading

  function refreshAll() {
    tokenCheck.running = true
  }

  function loadInventory() {
    if (deviceReader.running) return
    deviceReader.command = [root.pluginDir + "bin/smartthings", "devices"]
    deviceReader.running = true
  }

  // Only devices whose state a row or a detail screen actually shows. Everything
  // else would cost a request per tick to display nothing.
  function refreshStatuses() {
    if (statusReader.running || root.devices.length === 0) return
    var wanted = Model.devicesNeedingStatus(root.devices)
    if (wanted.length === 0) return
    var cmd = [root.pluginDir + "bin/smartthings", "status"]
    for (var i = 0; i < wanted.length; i++) cmd.push("--device", wanted[i].id)
    statusReader.command = cmd
    statusReader.running = true
  }

  Process {
    id: tokenCheck
    command: [root.pluginDir + "bin/smartthings", "token", "status"]
    stdout: StdioCollector { id: tokenOut; waitForEnd: true }
    onExited: function (exitCode) {
      var had = root.hasToken
      try { root.hasToken = JSON.parse(String(tokenOut.text)).hasToken === true }
      catch (e) { root.hasToken = false }
      if (!root.hasToken) {
        // A missing token is not a failed read. Left counting, the failures from
        // the moment the old token expired keep the bar dimmed and put "stale"
        // on the setup screen -- competing with the one screen that already says
        // exactly what is wrong, and blaming the network for it.
        root.devices = []
        root.statuses = ({})
        root.consecutiveFailures = 0
        return
      }
      if (!had || root.devices.length === 0) root.loadInventory()
      else root.refreshStatuses()
    }
  }

  Process {
    id: deviceReader
    stdout: StdioCollector { id: deviceOut; waitForEnd: true }
    onExited: function (exitCode) {
      // Exit 3 means the backend cleared a rejected token. Without reading it
      // the panel would keep claiming a token it no longer has and show an
      // empty list with no way back to setup.
      if (exitCode === 3) { root.hasToken = false; root.devices = []; return }
      var d = Model.parseDevices(deviceOut.text)
      if (!d.ok) { root.consecutiveFailures = root.consecutiveFailures + 1; return }
      root.devices = d.devices
      root.consecutiveFailures = 0
      roomReader.running = true
    }
  }

  Process {
    id: roomReader
    command: [root.pluginDir + "bin/smartthings", "rooms"]
    stdout: StdioCollector { id: roomOut; waitForEnd: true }
    onExited: function (exitCode) {
      // A token without location scope is an ordinary configuration, not a
      // fault: the backend answers with an empty map and exit 0, and the panel
      // shows one flat list without mentioning it.
      var r = Model.parseRooms(roomOut.text)
      root.rooms = r.rooms
      root.roomsScoped = r.scoped
      root.refreshStatuses()
    }
  }

  Process {
    id: statusReader
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode === 3) { root.hasToken = false; return }
      var s = Model.parseStatuses(statusOut.text)
      if (s.ok) {
        root.statuses = s.byId
        root.consecutiveFailures = 0
      } else {
        // Keep the last known state rather than blanking the bar, but stop
        // claiming it is current. Staleness is shown, never hidden.
        root.consecutiveFailures = root.consecutiveFailures + 1
      }
    }
  }

  // The interval is a binding, not an assignment. Written imperatively in a
  // change handler it reads pollBase before that binding has re-evaluated, so
  // opening applies the closed interval and closing applies the open one --
  // backwards, and silently so.
  Timer {
    id: poll
    interval: Model.nextInterval(root.pollBase, root.consecutiveFailures)
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refreshAll()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // A house glyph stands in whenever nothing is on: WidgetButton hides itself
    // on empty text, and a widget that vanishes when the house is quiet is a
    // widget you cannot click to check. Opacity carries the state instead.
    text: root.label !== "" ? root.label : "󰋜"
    labelVisible: true
    opacity: root.stale ? 0.5 : (root.label !== "" ? 1.0 : 0.6)
    onPressed: function (b) { if (b === Qt.LeftButton) root.togglePanel() }
  }

  Loader {
    id: panelLoader
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: {
      root.injectPanel()
      item.foreground = Qt.binding(function () { return root.contentForeground })
      item.fontFamily = Qt.binding(function () { return root.contentFontFamily })
    }
  }
}
