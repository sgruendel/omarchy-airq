import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "sgruendel.airq"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property color healthColor: panelLoader.item ? panelLoader.item.healthColor : Color.muted
  readonly property color performanceColor: panelLoader.item ? panelLoader.item.performanceColor : Color.muted
  readonly property string pluginDir: {
    if (!bar || !("barWidgetRegistry" in bar)) return ""
    var metadata = bar.barWidgetRegistry.metadataFor(moduleName)
    return metadata && metadata.sourceDir ? String(metadata.sourceDir) : ""
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("pluginDir" in target) target.pluginDir = root.pluginDir
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function credentialStored() {
    if (panelLoader.item && panelLoader.item.credentialStored)
      panelLoader.item.credentialStored()
  }

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onPluginDirChanged: injectPanel()

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
    target: root.moduleName

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : Style.space(34)
    fixedHeight: root.vertical ? Style.space(34) : -1
    tooltipText: panelLoader.item ? panelLoader.item.tooltipText : "air-Q: loading…"
    horizontalMargin: 0

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else if (b === Qt.RightButton) {
        if (panelLoader.item) panelLoader.item.openDevicePage()
      } else root.togglePanel()
    }

    Item {
      anchors.centerIn: parent
      width: root.vertical ? Style.space(10) : Style.space(26)
      height: root.vertical ? Style.space(26) : Style.space(10)

      Row {
        visible: !root.vertical
        anchors.centerIn: parent
        spacing: Style.space(6)

        Rectangle {
          width: Style.space(10)
          height: width
          radius: width / 2
          color: root.healthColor
          border.width: 1
          border.color: Qt.rgba(button.foreground.r, button.foreground.g, button.foreground.b, 0.24)
          Behavior on color { ColorAnimation { duration: 180 } }
        }

        Rectangle {
          width: Style.space(10)
          height: width
          radius: width / 2
          color: root.performanceColor
          border.width: 1
          border.color: Qt.rgba(button.foreground.r, button.foreground.g, button.foreground.b, 0.24)
          Behavior on color { ColorAnimation { duration: 180 } }
        }
      }

      Column {
        visible: root.vertical
        anchors.centerIn: parent
        spacing: Style.space(6)

        Rectangle {
          width: Style.space(10)
          height: width
          radius: width / 2
          color: root.healthColor
          border.width: 1
          border.color: Qt.rgba(button.foreground.r, button.foreground.g, button.foreground.b, 0.24)
          Behavior on color { ColorAnimation { duration: 180 } }
        }

        Rectangle {
          width: Style.space(10)
          height: width
          radius: width / 2
          color: root.performanceColor
          border.width: 1
          border.color: Qt.rgba(button.foreground.r, button.foreground.g, button.foreground.b, 0.24)
          Behavior on color { ColorAnimation { duration: 180 } }
        }
      }
    }
  }
}
