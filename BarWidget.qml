import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "io.github.sahzudin.ominder"

  property var reminderState: Model.emptyState()

  // Repeating reminders live here rather than in the panel: the panel is only
  // a view, while the widget ticks for as long as the bar does.
  property var repeatRules: []
  property bool rulesLoaded: false
  property bool directoryReady: false
  property bool pendingSave: false

  // Set once a reminder query has actually succeeded. Rules must never be
  // reconciled against a timer list we failed to read, or a transient error
  // would look exactly like the user clearing everything.
  property bool stateKnown: false

  // One reminder command at a time: several rules can come due on one tick.
  property var armQueue: []

  readonly property string stateDirectory: {
    var configured = Quickshell.env("XDG_STATE_HOME")
    var base = configured && configured.length > 0
      ? configured
      : Quickshell.env("HOME") + "/.local/state"
    return base + "/ominder"
  }

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function refresh() {
    if (!reminderProcess.running) reminderProcess.running = true
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function applyState(raw) {
    reminderState = Model.parseState(raw)
  }

  function saveRules() {
    if (!directoryReady) {
      pendingSave = true
      return
    }
    pendingSave = false
    rulesFile.setText(Model.serializeRules(root.repeatRules))
  }

  function loadRules(raw) {
    repeatRules = Model.parseRules(raw)
    rulesLoaded = true
    evaluateRepeats()
  }

  // Runs after every successful state refresh, so a fired reminder is re-armed
  // within one poll of disappearing from the timer list.
  function evaluateRepeats() {
    if (!rulesLoaded || !stateKnown) return

    var plan = Model.planRepeats(root.repeatRules, root.reminderState.reminders, root.nowSeconds(), 45)
    if (!plan.changed) return

    repeatRules = plan.rules
    saveRules()

    for (var i = 0; i < plan.arm.length; i++) root.armQueue.push(plan.arm[i])
    drainArmQueue()
  }

  function nowSeconds() {
    return Math.floor(Date.now() / 1000)
  }

  function registerRepeat(minutes, message) {
    var rule = Model.createRule(minutes, message, root.nowSeconds(), Math.random())
    if (!rule) return false

    repeatRules = root.repeatRules.concat([rule])
    saveRules()
    return true
  }

  function stopRepeat(id) {
    var next = Model.withoutRule(root.repeatRules, id)
    if (next.length === root.repeatRules.length) return

    repeatRules = next
    saveRules()
  }

  function clearRepeats() {
    if (root.repeatRules.length === 0) return

    repeatRules = []
    saveRules()
  }

  function drainArmQueue() {
    if (armProcess.running) return

    while (root.armQueue.length > 0) {
      var item = root.armQueue.shift()

      // Stopped or cleared between being queued and being armed.
      if (!Model.hasRule(root.repeatRules, item.id)) continue

      var command = ["omarchy", "reminder", String(item.minutes)]
      if (item.message !== "") command.push(item.message)

      armProcess.command = command
      armProcess.running = true
      return
    }
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Component.onCompleted: {
    ensureDirectory.running = true
    refresh()
  }

  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: ensureDirectory
    command: ["mkdir", "-p", root.stateDirectory]
    onExited: function(exitCode) {
      root.directoryReady = exitCode === 0
      if (!root.directoryReady) {
        root.rulesLoaded = true
        return
      }

      rulesFile.reload()
      if (root.pendingSave) root.saveRules()
    }
  }

  FileView {
    id: rulesFile
    path: root.stateDirectory + "/repeating.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadRules(text())
    onLoadFailed: root.loadRules("")
    onFileChanged: reload()
  }

  Process {
    id: armProcess
    command: ["true"]
    onExited: {
      root.refresh()
      Qt.callLater(root.drainArmQueue)
    }
  }

  Process {
    id: reminderProcess
    command: ["omarchy", "reminder", "show", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyState(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.reminderState = Model.emptyState()
        return
      }

      root.stateKnown = true
      root.evaluateRepeats()
    }
  }

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
    target: "io.github.sahzudin.ominder"

    function refresh(): void { root.refresh() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.barLabel(root.reminderState.count, root.vertical)
    tooltipText: root.reminderState.tooltip
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.RightButton) root.refresh()
    }
  }
}
