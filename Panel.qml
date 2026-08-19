pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.sahzudin.ominder"
  ipcTarget: "io.github.sahzudin.ominder"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var reminders: []
  property string statusText: ""
  property bool busy: false
  property bool repeatEnabled: false
  property string scheduleMode: "in"

  // Set when the reminder now being created should also become a rule, so the
  // toggle can be reset without losing what the user actually asked for.
  property int pendingRepeatMinutes: 0
  property string pendingRepeatMessage: ""

  readonly property var repeatRules: hostWidget && hostWidget.repeatRules
    ? hostWidget.repeatRules
    : []

  readonly property var barIdentity: hostWidget || root
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color contentDim: Qt.darker(contentForeground, 1.5)
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  function open() {
    refresh()
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) {
        root.setCenterHoverRevealSuppressed(true)
        if (root.scheduleMode === "at") dateField.forceActiveFocus()
        else minutesField.forceActiveFocus()
      }
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    if (!listProcess.running) listProcess.running = true
  }

  function applyState(raw) {
    var state = Model.parseState(raw)
    reminders = state.reminders
  }

  function setPreset(value) {
    minutesField.text = String(value)
    messageField.forceActiveFocus()
  }

  function setScheduleMode(value) {
    if (value !== "in" && value !== "at") return

    scheduleMode = value
    statusText = ""

    if (value === "at") {
      repeatEnabled = false

      if (dateField.text === "" || timeField.text === "") {
        var suggested = new Date(Date.now() + 60 * 60 * 1000)
        suggested.setSeconds(0, 0)
        dateField.text = Qt.formatDate(suggested, "yyyy-MM-dd")
        timeField.text = Qt.formatTime(suggested, "HH:mm")
      }

      Qt.callLater(function() { dateField.forceActiveFocus() })
    } else {
      Qt.callLater(function() { minutesField.forceActiveFocus() })
    }
  }

  function createReminder() {
    var minutes = 0
    var exact = null

    if (scheduleMode === "at") {
      exact = Model.exactSchedule(dateField.text, timeField.text, Date.now())
      if (exact.error !== "") {
        statusText = exact.error
        dateField.forceActiveFocus()
        return
      }
      minutes = exact.minutes
    } else {
      minutes = Model.validMinutes(minutesField.text)
      if (minutes === 0) {
        statusText = "Enter a whole number of minutes"
        minutesField.forceActiveFocus()
        return
      }
    }

    if (createProcess.running || clearProcess.running) return

    var command = ["omarchy", "reminder", String(minutes)]
    var message = Model.cleanText(messageField.text)
    if (message !== "") command.push(message)

    pendingRepeatMinutes = scheduleMode === "in" && repeatEnabled ? minutes : 0
    pendingRepeatMessage = message

    statusText = pendingRepeatMinutes > 0
      ? "Setting repeating reminder…"
      : exact ? "Setting reminder for " + Qt.formatDateTime(new Date(exact.at), "MMM d, H:mm") + "…"
      : "Setting reminder…"
    busy = true
    createProcess.command = command
    createProcess.running = true
  }

  // The command above arms the first occurrence; the rule only covers the ones
  // after it, so it is registered once that command has actually succeeded.
  function createFinished(exitCode) {
    var repeating = false

    if (exitCode === 0 && pendingRepeatMinutes > 0 && hostWidget && hostWidget.registerRepeat)
      repeating = hostWidget.registerRepeat(pendingRepeatMinutes, pendingRepeatMessage) === true

    pendingRepeatMinutes = 0
    pendingRepeatMessage = ""
    if (exitCode === 0) repeatEnabled = false

    actionFinished(exitCode, repeating ? "Repeating reminder set" : "Reminder set")
  }

  function stopRepeat(id) {
    if (hostWidget && hostWidget.stopRepeat) hostWidget.stopRepeat(id)
  }

  function repeatMeta(rule) {
    var parts = [Model.repeatLabel(rule.minutes)]
    if (rule.nextAt > 0) parts.push("next " + Qt.formatTime(new Date(rule.nextAt * 1000), "H:mm"))
    return parts.join("  ·  ")
  }

  function clearReminders() {
    if ((reminders.length === 0 && repeatRules.length === 0) || createProcess.running || clearProcess.running) return

    // "Clear all" means all of it: leaving the rules behind would quietly
    // re-arm the reminders the user just dismissed.
    if (hostWidget && hostWidget.clearRepeats) hostWidget.clearRepeats()

    statusText = "Clearing reminders…"
    busy = true
    clearProcess.running = true
  }

  function actionFinished(exitCode, successMessage) {
    busy = false
    statusText = exitCode === 0 ? successMessage : "The reminder command failed"
    if (exitCode === 0) {
      minutesField.text = ""
      dateField.text = ""
      timeField.text = ""
      messageField.text = ""
      scheduleMode = "in"
    }
    refresh()
    if (hostWidget && hostWidget.refresh) hostWidget.refresh()
  }

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: listProcess
    command: ["omarchy", "reminder", "show", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyState(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.statusText = "Could not load reminders"
    }
  }

  Process {
    id: createProcess
    command: ["true"]
    onExited: function(exitCode) { root.createFinished(exitCode) }
  }

  Process {
    id: clearProcess
    command: ["omarchy", "reminder", "clear"]
    onExited: function(exitCode) { root.actionFinished(exitCode, "Reminders cleared") }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: root.scheduleMode === "at" ? dateField : minutesField
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: minutesField.activeFocus || dateField.activeFocus
        || timeField.activeFocus || messageField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        RowLayout {
          width: parent.width
          spacing: Style.space(8)

          Text {
            text: "󰂜"
            textFormat: Text.PlainText
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.heading
            Layout.alignment: Qt.AlignVCenter
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(1)

            Text {
              Layout.fillWidth: true
              text: "Ominder"
              textFormat: Text.PlainText
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              Layout.fillWidth: true
              text: root.reminders.length === 0
                ? "No upcoming reminders"
                : root.reminders.length === 1 ? "1 upcoming reminder" : root.reminders.length + " upcoming reminders"
              textFormat: Text.PlainText
              color: root.contentDim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelActionButton {
            iconText: "󰑐"
            tooltipText: "Refresh"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            enabled: !listProcess.running
            onClicked: root.refresh()
          }
        }

        RowLayout {
          width: parent.width
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            text: "REMIND ME"
            textFormat: Text.PlainText
            color: root.contentDim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1
          }

          ButtonGroup {
            options: [
              { value: "in", label: "In" },
              { value: "at", label: "At" }
            ]
            value: root.scheduleMode
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            fontSize: Style.font.bodySmall
            enabled: !root.busy
            onChanged: function(value) { root.setScheduleMode(value) }
          }
        }

        RowLayout {
          visible: root.scheduleMode === "in"
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: minutesField
            Layout.preferredWidth: Style.space(72)
            placeholderText: "Min"
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            inputMethodHints: Qt.ImhDigitsOnly
            enabled: !root.busy
            onAccepted: messageField.forceActiveFocus()
            Keys.onEscapePressed: root.close()
          }

          Text {
            Layout.fillWidth: true
            text: "minutes from now"
            textFormat: Text.PlainText
            color: root.contentDim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }
        }

        RowLayout {
          visible: root.scheduleMode === "at"
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: dateField
            Layout.preferredWidth: Style.space(132)
            placeholderText: "YYYY-MM-DD"
            maximumLength: 10
            validator: RegularExpressionValidator { regularExpression: /^\d{4}-\d{2}-\d{2}$/ }
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            enabled: !root.busy
            onAccepted: timeField.forceActiveFocus()
            Keys.onEscapePressed: root.close()
          }

          TextField {
            id: timeField
            Layout.preferredWidth: Style.space(82)
            placeholderText: "HH:MM"
            maximumLength: 5
            validator: RegularExpressionValidator { regularExpression: /^\d{2}:\d{2}$/ }
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            enabled: !root.busy
            onAccepted: messageField.forceActiveFocus()
            Keys.onEscapePressed: root.close()
          }

          Text {
            Layout.fillWidth: true
            text: "local time"
            textFormat: Text.PlainText
            color: root.contentDim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }
        }

        RowLayout {
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: messageField
            Layout.fillWidth: true
            placeholderText: "What should I remind you?"
            foreground: root.contentForeground
            font.family: root.contentFontFamily
            enabled: !root.busy
            onAccepted: root.createReminder()
            Keys.onEscapePressed: root.close()
          }

          Button {
            text: "Set"
            bordered: true
            focusable: true
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            enabled: !root.busy
            onClicked: root.createReminder()
          }
        }

        RowLayout {
          visible: root.scheduleMode === "in"
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: [
              { label: "5 min", minutes: 5 },
              { label: "10 min", minutes: 10 },
              { label: "15 min", minutes: 15 },
              { label: "30 min", minutes: 30 },
              { label: "1 hour", minutes: 60 },
              { label: "24 hours", minutes: 1440 }
            ]

            Button {
              required property var modelData
              Layout.fillWidth: true
              Layout.minimumWidth: 0
              Layout.preferredWidth: 1
              text: modelData.label
              bordered: true
              focusable: true
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(6)
              enabled: !root.busy
              onClicked: root.setPreset(modelData.minutes)
            }
          }
        }

        Toggle {
          visible: root.scheduleMode === "in"
          width: parent.width
          label: "Repeat"
          description: {
            if (!root.repeatEnabled) return "Fires once, then stops"

            var minutes = Model.validMinutes(minutesField.text)
            if (minutes === 0) return "Enter minutes to repeat on that interval"
            return "Keeps firing " + Model.repeatLabel(minutes)
          }
          checked: root.repeatEnabled
          enabled: !root.busy
          foreground: root.contentForeground
          accent: Color.accent
          fontFamily: root.contentFontFamily
          titleSize: Style.font.body
          onClicked: root.repeatEnabled = !root.repeatEnabled
        }

        PanelSeparator {
          width: parent.width
          foreground: root.contentForeground
        }

        RowLayout {
          width: parent.width

          Text {
            Layout.fillWidth: true
            text: "UPCOMING"
            textFormat: Text.PlainText
            color: root.contentDim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.letterSpacing: 1
          }

          Button {
            visible: root.reminders.length > 0 || root.repeatRules.length > 0
            text: "Clear all"
            focusable: true
            foreground: Color.urgent
            fontFamily: root.contentFontFamily
            enabled: !root.busy
            onClicked: root.clearReminders()
          }
        }

        Text {
          visible: root.reminders.length === 0
          width: parent.width
          text: "Choose a quick duration or an exact local date and time above."
          textFormat: Text.PlainText
          color: root.contentDim
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        ListView {
          id: reminderList
          visible: root.reminders.length > 0
          width: parent.width
          height: Math.min(contentHeight, Style.space(190))
          model: root.reminders
          spacing: Style.space(4)
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          delegate: Rectangle {
            required property var modelData
            width: reminderList.width
            height: reminderContent.implicitHeight + Style.space(12)
            color: Style.controlFill(false, hoverHandler.hovered, root.contentForeground, Color.accent)
            radius: Style.cornerRadius

            HoverHandler { id: hoverHandler }

            RowLayout {
              id: reminderContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(8)

              Text {
                text: "󰃭"
                textFormat: Text.PlainText
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.icon
                Layout.alignment: Qt.AlignVCenter
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(1)

                Text {
                  Layout.fillWidth: true
                  text: modelData.label
                  textFormat: Text.PlainText
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  Layout.fillWidth: true
                  text: Model.reminderMeta(modelData)
                  textFormat: Text.PlainText
                  color: root.contentDim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }
          }
        }

        PanelSeparator {
          visible: root.repeatRules.length > 0
          width: parent.width
          foreground: root.contentForeground
        }

        Text {
          visible: root.repeatRules.length > 0
          width: parent.width
          text: "REPEATING"
          textFormat: Text.PlainText
          color: root.contentDim
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 1
        }

        ListView {
          id: repeatList
          visible: root.repeatRules.length > 0
          width: parent.width
          height: Math.min(contentHeight, Style.space(140))
          model: root.repeatRules
          spacing: Style.space(4)
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          delegate: Rectangle {
            required property var modelData
            width: repeatList.width
            height: repeatContent.implicitHeight + Style.space(12)
            color: Style.controlFill(false, repeatHover.hovered, root.contentForeground, Color.accent)
            radius: Style.cornerRadius

            HoverHandler { id: repeatHover }

            RowLayout {
              id: repeatContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(8)

              Text {
                text: "󰑖"
                textFormat: Text.PlainText
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.icon
                Layout.alignment: Qt.AlignVCenter
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(1)

                Text {
                  Layout.fillWidth: true
                  text: modelData.message !== "" ? modelData.message : modelData.minutes + "-min reminder"
                  textFormat: Text.PlainText
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  Layout.fillWidth: true
                  text: root.repeatMeta(modelData)
                  textFormat: Text.PlainText
                  color: root.contentDim
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              PanelActionButton {
                iconText: "󰅖"
                tooltipText: "Stop repeating"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                enabled: !root.busy
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.stopRepeat(modelData.id)
              }
            }
          }
        }

        Text {
          visible: root.statusText !== ""
          width: parent.width
          text: root.statusText
          textFormat: Text.PlainText
          color: root.contentDim
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignRight
        }
      }
    }
  }
}
