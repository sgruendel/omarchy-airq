import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "sgruendel.airq"

  property var anchorItem: null
  property var hostWidget: null
  property string pluginDir: ""
  readonly property var barIdentity: hostWidget || root
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color healthyColor: "#4caf50"
  readonly property color warningColor: "#fbc02d"
  readonly property color criticalColor: bar ? bar.urgent : Color.urgent
  readonly property color unavailableColor: Color.muted
  readonly property int maxResponseBytes: 64 * 1024

  property var readings: null
  property string devicePassword: ""
  property string fetchError: ""
  property bool fetching: false
  property bool stale: false
  property int retries: 0
  property real nowMs: Date.now()
  property bool credentialTimedOut: false
  property bool credentialStoreTimedOut: false
  property bool fetchTimedOut: false
  property bool credentialEntryVisible: false
  property string pendingCredential: ""
  property string credentialLookupSerial: ""
  property string credentialStoreSerial: ""

  readonly property string configuredHost: String(setting("host", ""))
    .replace(/^https?:\/\//, "").replace(/\/+$/, "")
  readonly property string configuredSerial: String(setting("serial", ""))
  readonly property int refreshSeconds: integerSetting("refreshSeconds", 30, 10, 3600)
  readonly property int warningThreshold: integerSetting("radonWarning", 100, 10, 10000)
  readonly property int indexGreenThreshold: integerSetting("indexGreenThreshold", 80, 0, 100)
  readonly property int indexYellowThreshold: Math.min(indexGreenThreshold,
    integerSetting("indexYellowThreshold", 60, 0, 100))
  readonly property real radonValue: Model.number(readings, "radon")
  readonly property real healthIndex: Model.indexPercent(readings, "health")
  readonly property real performanceIndex: Model.indexPercent(readings, "performance")
  readonly property bool indexDataCurrent: readings !== null && !stale && fetchError === ""
  readonly property string healthState: indexDataCurrent
    ? Model.indexState(healthIndex, indexGreenThreshold, indexYellowThreshold) : "unavailable"
  readonly property string performanceState: indexDataCurrent
    ? Model.indexState(performanceIndex, indexGreenThreshold, indexYellowThreshold) : "unavailable"
  readonly property color healthColor: indexColor(healthState)
  readonly property color performanceColor: indexColor(performanceState)
  readonly property string radonState: Model.radonState(radonValue, warningThreshold)
  readonly property bool needsAttention: stale || fetchError !== ""
    || (isFinite(radonValue) && radonValue >= warningThreshold)
  readonly property string tooltipPlainText: readings
    ? "Health: " + Model.score(readings, "health") + " (" + healthState + ")"
      + "\nPerformance: " + Model.score(readings, "performance") + " (" + performanceState + ")"
      + "\n" + Model.tooltipText(readings, nowMs, stale)
      + (fetchError !== "" ? "\n" + fetchError : "")
    : (fetchError !== "" ? "air-Q: " + fetchError : "air-Q: fetching…")
  // The bar owns the tooltip Text item and leaves it in AutoText mode. Supply
  // an escaped rich-text document so device/error strings stay inert there.
  readonly property string tooltipText: Model.inertTooltipText(tooltipPlainText)
  readonly property var sensorCards: Model.metricRows(readings)
  readonly property var sensorStatus: Model.statusLines(readings)
  readonly property string measurementAge: readings
    ? Model.measurementAge(readings.timestamp, nowMs) : "unknown age"

  function integerSetting(name, fallback, minimum, maximum) {
    var value = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, value))
  }

  function indexColor(state) {
    if (state === "green") return healthyColor
    if (state === "yellow") return warningColor
    if (state === "red") return criticalColor
    return unavailableColor
  }

  function setCenterHoverRevealSuppressed(value) {
    if (bar && "centerHoverRevealSuppressed" in bar) bar.centerHoverRevealSuppressed = value
  }

  function open() {
    controller.show()
    refresh()
    Qt.callLater(function() {
      if (root.opened) root.setCenterHoverRevealSuppressed(true)
      if (root.opened && root.credentialEntryVisible)
        credentialPasswordField.forceActiveFocus()
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    controller.hide()
  }

  function toggle() {
    if (opened) close()
    else open()
  }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function refresh() {
    retries = 0
    fetch()
  }

  function credentialStored() {
    devicePassword = ""
    credentialEntryVisible = false
    credentialPasswordField.text = ""
    fetchError = ""
    retries = 0
    fetch()
  }

  function storeCredential() {
    if (credentialStoreProc.running || !configuredSerial) return
    var password = credentialPasswordField.text
    if (!password) return
    if (!pluginDir) {
      failNow("Could not locate the air-Q plugin files")
      return
    }
    credentialStoreSerial = configuredSerial
    pendingCredential = password
    credentialStoreTimedOut = false
    credentialStoreProc.command = [pluginDir + "/scripts/keyring-store.sh", credentialStoreSerial]
    credentialStoreTimeout.restart()
    credentialStoreProc.running = true
  }

  function failNow(message) {
    fetching = false
    stale = readings !== null
    fetchError = message
  }

  function processError(raw, fallback) {
    var lines = String(raw || "").trim().split(/\r?\n/)
    return lines[0] ? fallback + ": " + lines[0] : fallback
  }

  function fetch() {
    if (!configuredHost || !configuredSerial) {
      fetching = false
      fetchError = "Set the device host and serial number in widget settings"
      return
    }
    if (fetchProc.running || credentialProc.running || credentialStoreProc.running) return
    if (!devicePassword) {
      if (credentialEntryVisible) {
        fetching = false
        return
      }
      fetching = true
      credentialLookupSerial = configuredSerial
      credentialProc.command = [
        "secret-tool", "lookup",
        "application", "omarchy-airq",
        "serial", credentialLookupSerial
      ]
      credentialTimedOut = false
      credentialTimeout.restart()
      credentialProc.running = true
      return
    }
    fetching = true
    fetchProc.command = ["curl", "-fsS", "--connect-timeout", "3", "--max-time", "8",
      "--max-filesize", String(maxResponseBytes),
      "http://" + configuredHost + "/data/"]
    fetchTimedOut = false
    fetchTimeout.restart()
    fetchProc.running = true
  }

  function applyDeviceResponse(raw) {
    fetching = false
    var parsed = Model.parseDataResponse(raw, devicePassword)
    if (!parsed) {
      if (retries >= 3) {
        devicePassword = ""
        credentialEntryVisible = true
        failNow("Could not read or decrypt the air-Q response · re-enter the device password")
        return
      }
      scheduleRetry("Could not read or decrypt the air-Q response")
      return
    }
    credentialEntryVisible = false
    readings = parsed
    stale = false
    retries = 0
    fetchError = ""
    nowMs = Date.now()
  }

  function scheduleRetry(message) {
    fetching = false
    stale = readings !== null
    if (retries >= 3) {
      fetchError = message
      return
    }
    retries++
    fetchError = message + " · retry " + retries + "/3"
    retryTimer.restart()
  }

  onConfiguredHostChanged: Qt.callLater(refresh)
  onConfiguredSerialChanged: {
    devicePassword = ""
    credentialEntryVisible = false
    Qt.callLater(function() {
      credentialPasswordField.text = ""
      root.refresh()
    })
  }

  onOpenedChanged: if (!root.opened) credentialPasswordField.text = ""
  onCredentialEntryVisibleChanged: if (root.credentialEntryVisible && root.opened)
    Qt.callLater(function() { credentialPasswordField.forceActiveFocus() })

  Process {
    id: credentialProc
    stdout: StdioCollector { id: credentialStdout; waitForEnd: true }
    stderr: StdioCollector { id: credentialStderr; waitForEnd: true }
    onExited: function(exitCode) {
      credentialTimeout.stop()
      if (root.credentialTimedOut) {
        root.credentialTimedOut = false
        if (root.credentialLookupSerial !== root.configuredSerial)
          Qt.callLater(root.fetch)
        return
      }
      if (root.credentialLookupSerial !== root.configuredSerial) {
        Qt.callLater(root.fetch)
        return
      }
      var secret = String(credentialStdout.text || "").replace(/\r?\n$/, "")
      if (exitCode !== 0 || !secret) {
        root.credentialEntryVisible = true
        var fallback = exitCode === 1 || (exitCode === 0 && !secret)
          ? "Enter the device password to continue"
          : "Could not access GNOME Keyring"
        root.failNow(root.processError(credentialStderr.text, fallback))
        return
      }
      root.devicePassword = secret
      root.credentialEntryVisible = false
      root.fetchError = ""
      Qt.callLater(root.fetch)
    }
  }

  Process {
    id: credentialStoreProc
    stdinEnabled: true
    stderr: StdioCollector { id: credentialStoreStderr; waitForEnd: true }
    onStarted: {
      if (root.credentialStoreSerial === root.configuredSerial)
        root.devicePassword = root.pendingCredential
      write(root.pendingCredential + "\n")
      root.pendingCredential = ""
      credentialPasswordField.text = ""
    }
    onExited: function(exitCode) {
      credentialStoreTimeout.stop()
      root.pendingCredential = ""
      if (root.credentialStoreTimedOut) {
        root.credentialStoreTimedOut = false
        if (root.credentialStoreSerial !== root.configuredSerial)
          Qt.callLater(root.fetch)
        return
      }
      if (root.credentialStoreSerial !== root.configuredSerial) {
        root.devicePassword = ""
        root.credentialEntryVisible = false
        Qt.callLater(root.fetch)
        return
      }
      if (exitCode !== 0) {
        root.devicePassword = ""
        root.credentialEntryVisible = true
        root.failNow(root.processError(credentialStoreStderr.text,
          "Could not save the device password to GNOME Keyring"))
        return
      }
      root.credentialEntryVisible = false
      root.fetchError = ""
      root.retries = 0
      if (root.hostWidget && typeof root.hostWidget.broadcast === "function")
        root.hostWidget.broadcast("credentialStored")
      else
        Qt.callLater(root.credentialStored)
    }
  }

  function openDevicePage() {
    openPageProc.command = ["xdg-open", "http://" + configuredHost + "/"]
    openPageProc.running = true
  }

  Process {
    id: fetchProc
    stdout: StdioCollector { id: fetchStdout; waitForEnd: true }
    stderr: StdioCollector { id: fetchStderr; waitForEnd: true }
    onExited: function(exitCode) {
      fetchTimeout.stop()
      if (root.fetchTimedOut) {
        root.fetchTimedOut = false
        return
      }
      if (exitCode === 63) {
        root.scheduleRetry("air-Q response exceeded the 64 KiB limit")
        return
      }
      if (exitCode !== 0) {
        root.scheduleRetry(root.processError(fetchStderr.text, "air-Q request failed"))
        return
      }
      root.applyDeviceResponse(fetchStdout.text)
    }
  }

  Process { id: openPageProc }

  Timer {
    id: retryTimer
    interval: 2500
    onTriggered: root.fetch()
  }

  Timer {
    id: credentialTimeout
    interval: 10000
    onTriggered: {
      var stillCurrent = root.credentialLookupSerial === root.configuredSerial
      root.credentialTimedOut = true
      credentialProc.running = false
      if (stillCurrent)
        root.failNow("GNOME Keyring did not respond within 10 seconds")
    }
  }

  Timer {
    id: fetchTimeout
    interval: 10000
    onTriggered: {
      root.fetchTimedOut = true
      fetchProc.running = false
      root.scheduleRetry("air-Q request timed out")
    }
  }

  Timer {
    id: credentialStoreTimeout
    interval: 10000
    onTriggered: {
      var stillCurrent = root.credentialStoreSerial === root.configuredSerial
      root.credentialStoreTimedOut = true
      root.pendingCredential = ""
      root.devicePassword = ""
      credentialPasswordField.text = ""
      credentialStoreProc.running = false
      root.credentialEntryVisible = stillCurrent
      if (stillCurrent)
        root.failNow("GNOME Keyring did not save the password within 10 seconds")
    }
  }

  Timer {
    interval: root.refreshSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(500))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: credentialPasswordField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh()
        if (text === "o" || text === "O") root.openDevicePage()
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(14)

          Item {
            width: parent.width
            height: heroRow.implicitHeight

            Row {
              id: heroRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(28)

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  text: "RADON"
                  color: Qt.darker(root.barForeground, 1.4)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                Row {
                  spacing: Style.space(5)
                  Text {
                    text: Model.reading(root.readings, "radon", root.radonValue < 10 ? 1 : 0, "")
                    color: root.needsAttention ? root.criticalColor : root.barForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: 52
                    font.bold: true
                  }
                  Text {
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Style.space(9)
                    text: "Bq/m³"
                    color: Qt.darker(root.barForeground, 1.35)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                  }
                }
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  text: root.radonState.toUpperCase()
                  color: root.needsAttention ? root.criticalColor : root.barForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
                Text {
                  text: "Health " + Model.score(root.readings, "health")
                    + "   Performance " + Model.score(root.readings, "performance")
                  color: Qt.darker(root.barForeground, 1.35)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  text: root.fetching ? "Refreshing…" : "Measured " + root.measurementAge
                  color: Qt.darker(root.barForeground, 1.55)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          Column {
            visible: root.sensorStatus.length > 0
            width: parent.width
            spacing: Style.space(5)

            Repeater {
              model: root.sensorStatus

              Text {
                required property string modelData
                width: parent.width
                text: modelData
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                color: Qt.darker(root.barForeground, 1.35)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.italic: true
              }
            }
          }

          Rectangle {
            visible: root.fetchError !== ""
            width: parent.width
            height: visible ? errorText.implicitHeight + Style.space(18) : 0
            radius: Style.cornerRadius
            color: Qt.rgba(root.criticalColor.r, root.criticalColor.g,
                           root.criticalColor.b, 0.14)

            Text {
              id: errorText
              anchors.centerIn: parent
              width: parent.width - Style.space(24)
              text: root.fetchError
              textFormat: Text.PlainText
              color: root.criticalColor
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
            }
          }

          Rectangle {
            visible: root.credentialEntryVisible && root.configuredHost !== ""
              && root.configuredSerial !== ""
            width: parent.width
            height: visible ? credentialColumn.implicitHeight + Style.space(28) : 0
            radius: Style.cornerRadius
            color: Qt.rgba(root.barForeground.r, root.barForeground.g,
                           root.barForeground.b, 0.055)

            Column {
              id: credentialColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              spacing: Style.space(8)

              Text {
                width: parent.width
                text: "Save the device password in GNOME Keyring"
                color: root.barForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                textFormat: Text.PlainText
              }

              Text {
                width: parent.width
                text: "The password is sent over stdin and is never stored in widget settings."
                color: Qt.darker(root.barForeground, 1.45)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
              }

              Row {
                id: credentialRow
                width: parent.width
                spacing: Style.space(8)

                TextField {
                  id: credentialPasswordField
                  width: credentialRow.width - saveCredentialButton.width - credentialRow.spacing
                  password: true
                  maximumLength: 1024
                  enabled: !credentialStoreProc.running
                  placeholderText: "Device password"
                  foreground: root.barForeground
                  font.family: root.contentFontFamily
                  onAccepted: root.storeCredential()
                  Keys.onEscapePressed: {
                    credentialPasswordField.text = ""
                    credentialPasswordField.focus = false
                  }
                }

                Button {
                  id: saveCredentialButton
                  anchors.verticalCenter: credentialPasswordField.verticalCenter
                  text: credentialStoreProc.running ? "Saving…" : "Save"
                  enabled: !credentialStoreProc.running && credentialPasswordField.text.length > 0
                  opacity: saveCredentialButton.enabled ? 1 : 0.45
                  bordered: true
                  foreground: root.barForeground
                  fontFamily: root.contentFontFamily
                  onClicked: root.storeCredential()
                }
              }
            }
          }

          Rectangle {
            width: parent.width
            height: Style.spacing.hairline
            color: root.barForeground
            opacity: 0.12
          }

          Grid {
            anchors.horizontalCenter: parent.horizontalCenter
            columns: 2
            spacing: Style.space(10)

            Repeater {
              model: root.sensorCards

              Rectangle {
                id: sensorCard
                required property var modelData
                width: Style.space(224)
                height: Style.space(68)
                radius: Style.cornerRadius
                color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.055)

                Column {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(14)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)

                  Text {
                    text: sensorCard.modelData.label
                    color: Qt.darker(root.barForeground, 1.45)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.letterSpacing: 1
                  }
                  Text {
                    text: sensorCard.modelData.text
                    color: root.barForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.title
                  }
                }
              }
            }
          }

          Text {
            visible: root.readings !== null
            width: parent.width
            text: "Measured " + root.measurementAge + (root.stale ? " · stale" : "")
            color: Qt.darker(root.barForeground, 1.55)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(12)

            Repeater {
              model: [
                { keys: "R", action: "Refresh" },
                { keys: "O", action: "Open Device" },
                { keys: "Esc", action: "Close" }
              ]

              delegate: Row {
                id: shortcut

                required property var modelData

                height: keycap.height
                spacing: Style.space(4)

                Rectangle {
                  id: keycap
                  width: keyText.implicitWidth + Style.space(8)
                  height: Math.max(Style.space(20), Style.font.caption + Style.space(6))
                  radius: Math.min(Style.cornerRadius, height / 2)
                  color: Qt.rgba(root.barForeground.r, root.barForeground.g,
                                 root.barForeground.b, 0.08)

                  Text {
                    id: keyText
                    anchors.centerIn: parent
                    text: shortcut.modelData.keys
                    color: root.barForeground
                    opacity: 0.85
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  height: keycap.height
                  text: shortcut.modelData.action
                  color: root.barForeground
                  opacity: 0.58
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  verticalAlignment: Text.AlignVCenter
                }
              }
            }
          }
        }
      }
    }
  }
}
