import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Kavita reader bar widget: a book icon plus the host for the browser/reader
// panel. Data lives in the headless Service.qml; this is a view over it and
// passes it down to the panel through `svc`.
BarWidget {
  id: root
  moduleName: "saigkill.kavita-reader"

  // shell._services is reassigned wholesale, so reading it in a binding
  // registers a dependency and this re-fires when the service instantiates.
  readonly property var svc: (bar && bar.shell && typeof bar.shell.serviceFor === "function")
    ? bar.shell.serviceFor(moduleName) : null

  readonly property bool connected: svc ? svc.loggedIn : false
  readonly property string tooltipText: connected
    ? "Kavita: " + (svc.username || "verbunden")
    : "Kavita Reader: nicht verbunden"

  readonly property color stateColor: connected
    ? (bar ? bar.barForeground : Color.foreground)
    : Qt.darker(bar ? bar.barForeground : Color.foreground, 1.6)

  // ---- panel lifecycle (shape contract for shell summon/hide/toggle) ---
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "saigkill.kavita-reader"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf02d"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    active: root.connected
    enabled: true
    foreground: root.stateColor
    tooltipText: root.tooltipText

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.toggle()
    }
  }
}
