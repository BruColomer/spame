import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Bridge between the panel and helper/spame.py. The helper does all network
// work and answers in JSON; this item only runs it and exposes the results.
Item {
  id: root

  property var settings: ({})

  property bool configured: false
  property string email: ""
  property string lastScan: ""
  property var senders: []          // from the last scan, each with .unsubscribed
  property var unsubscribed: []     // from state.json
  property var categories: []       // [{id, label}] in display order
  property var expanded: ({})       // category id -> true; sections start closed
  property var selected: ({})       // id -> true
  property var rowStatus: ({})      // id -> "working" | "done" | "needs-you"
  property string message: ""
  property bool errorMessage: false

  readonly property var subscribed: senders.filter(function(s) { return !s.unsubscribed })
  readonly property int pendingCount: subscribed.length
  readonly property int selectedCount: Object.keys(selected).length
  readonly property int scanMonths: intSetting("scanMonths", 6, 1, 24)
  readonly property bool scanning: scanProc.running
  readonly property bool unsubscribing: unsubProc.running
  readonly property bool busy: scanProc.running || unsubProc.running || setupProc.running
    || statusProc.running || resubProc.running

  readonly property string helperPath:
    decodeURIComponent(String(Qt.resolvedUrl("helper/spame.py")).replace(/^file:\/\//, ""))
  readonly property int _maxOutput: 8 * 1024 * 1024

  function intSetting(name, fallback, min, max) {
    var v = settings ? settings[name] : undefined
    var n = parseInt(String(v === undefined || v === null ? fallback : v), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function helper(args) { return ["python3", helperPath].concat(args) }

  function append(buf, chunk) {
    return buf.length >= _maxOutput ? buf : buf + chunk + "\n"
  }

  function parseLast(text) {
    var lines = String(text || "").trim().split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      try { return JSON.parse(lines[i]) } catch (e) {}
    }
    return { error: "Spame helper returned nothing (is python3 installed?)" }
  }

  function say(text, isError) {
    message = text || ""
    errorMessage = !!isError
    if (message !== "" && !isError) messageTimer.restart()
  }

  function scanIsStale() {
    if (lastScan === "") return true
    return (Date.now() - Date.parse(lastScan)) > 12 * 3600 * 1000
  }

  // ---------------------------------------------------------------- actions

  function refresh() {
    if (statusProc.running) return
    statusProc._out = ""
    statusProc.command = helper(["status"])
    statusProc.running = true
  }

  function loadCached() {
    if (cachedProc.running) return
    cachedProc._out = ""
    cachedProc.command = helper(["cached"])
    cachedProc.running = true
  }

  function loadUnsubscribed() {
    if (listProc.running) return
    listProc._out = ""
    listProc.command = helper(["list-unsubscribed"])
    listProc.running = true
  }

  function scan() {
    if (!configured || scanProc.running || unsubProc.running) return
    say("Scanning the last " + scanMonths + " months of mail…", false)
    messageTimer.stop()
    scanProc._out = ""
    scanProc.command = helper(["scan", "--months", String(scanMonths)])
    scanProc.running = true
  }

  function connect(address, password) {
    if (setupProc.running) return
    say("Checking with Gmail…", false)
    messageTimer.stop()
    setupProc._out = ""
    setupProc._input = String(address || "").trim() + "\n" + String(password || "") + "\n"
    setupProc.command = helper(["setup"])
    setupProc.running = true
  }

  function forget() {
    forgetProc.command = helper(["forget"])
    forgetProc.running = true
  }

  function toggle(id) {
    if (unsubProc.running) return
    var next = Object.assign({}, selected)
    if (next[id]) delete next[id]
    else next[id] = true
    selected = next
  }

  function selectAll(ids) {
    var next = {}
    for (var i = 0; i < ids.length; i++) next[ids[i]] = true
    selected = next
  }

  function clearSelection() { selected = ({}) }

  function toggleSection(ids) {
    if (unsubProc.running || ids.length === 0) return
    var allOn = ids.every(function(id) { return !!selected[id] })
    var next = Object.assign({}, selected)
    for (var i = 0; i < ids.length; i++) {
      if (allOn) delete next[ids[i]]
      else next[ids[i]] = true
    }
    selected = next
  }

  function toggleExpanded(id) {
    var next = Object.assign({}, expanded)
    if (next[id]) delete next[id]
    else next[id] = true
    expanded = next
  }

  function collapseAll() { expanded = ({}) }

  function unsubscribeSelected() {
    var ids = Object.keys(selected)
    if (ids.length === 0 || unsubProc.running) return
    var status = Object.assign({}, rowStatus)
    for (var i = 0; i < ids.length; i++) status[ids[i]] = "queued"
    rowStatus = status
    say("Unsubscribing from " + ids.length + "…", false)
    messageTimer.stop()
    unsubProc._out = ""
    unsubProc._input = JSON.stringify(ids)
    unsubProc.command = helper(["unsubscribe"])
    unsubProc.running = true
  }

  function resubscribe(id) {
    if (resubProc.running) return
    resubProc._out = ""
    resubProc.command = helper(["resubscribe", id])
    resubProc.running = true
  }

  // ---------------------------------------------------------------- results

  function applySenders(list) {
    senders = list || []
    var keep = {}
    for (var i = 0; i < senders.length; i++)
      if (selected[senders[i].id] && !senders[i].unsubscribed) keep[senders[i].id] = true
    selected = keep
  }

  function handleUnsubLine(line) {
    var obj
    try { obj = JSON.parse(line) } catch (e) { return }
    if (obj.error) { say(obj.error, true); return }
    if (obj.summary) {
      var s = obj.summary
      var text = "Unsubscribed from " + s.done + "."
      if (s.needsYou > 0) text += " " + s.needsYou + " opened in your browser to confirm."
      say(text, false)
      return
    }
    if (!obj.id) return
    var status = Object.assign({}, rowStatus)
    status[obj.id] = obj.status
    rowStatus = status
  }

  function finishUnsubscribe() {
    var list = senders.slice()
    for (var i = 0; i < list.length; i++) {
      var st = rowStatus[list[i].id]
      if (st === "done" || st === "needs-you") list[i] = Object.assign({}, list[i], { unsubscribed: true })
    }
    senders = list
    selected = ({})
    loadUnsubscribed()
    refresh()
    clearStatusTimer.restart()
  }

  Timer { id: messageTimer; interval: 6000; onTriggered: root.message = "" }
  Timer { id: clearStatusTimer; interval: 4000; onTriggered: root.rowStatus = ({}) }

  Component.onCompleted: { refresh(); loadCached(); loadUnsubscribed() }

  Process {
    id: statusProc
    property string _out: ""
    stdout: SplitParser { onRead: function(l) { statusProc._out = root.append(statusProc._out, l) } }
    onExited: {
      var r = root.parseLast(_out)
      if (r.error) return
      root.configured = !!r.configured
      root.email = r.email || ""
      root.lastScan = r.lastScan || ""
    }
  }

  Process {
    id: cachedProc
    property string _out: ""
    stdout: SplitParser { onRead: function(l) { cachedProc._out = root.append(cachedProc._out, l) } }
    onExited: {
      var r = root.parseLast(_out)
      if (r.error) return
      if (r.categories) root.categories = r.categories
      root.applySenders(r.senders)
    }
  }

  Process {
    id: listProc
    property string _out: ""
    stdout: SplitParser { onRead: function(l) { listProc._out = root.append(listProc._out, l) } }
    onExited: {
      var r = root.parseLast(_out)
      if (!r.error) root.unsubscribed = r.senders || []
    }
  }

  Process {
    id: scanProc
    property string _out: ""
    stdout: SplitParser { onRead: function(l) { scanProc._out = root.append(scanProc._out, l) } }
    onExited: {
      var r = root.parseLast(_out)
      if (r.error) { root.say(r.error, true); return }
      if (r.categories) root.categories = r.categories
      root.applySenders(r.senders)
      root.lastScan = r.at || ""
      root.say("Found " + root.pendingCount + " newsletter senders.", false)
    }
  }

  Process {
    id: setupProc
    property string _out: ""
    property string _input: ""
    stdinEnabled: true
    stdout: SplitParser { onRead: function(l) { setupProc._out = root.append(setupProc._out, l) } }
    onStarted: { write(_input); _input = "" }
    onExited: {
      var r = root.parseLast(_out)
      if (r.error) { root.say(r.error, true); return }
      root.configured = true
      root.email = r.email || ""
      root.say("Connected as " + root.email + ".", false)
      root.scan()
    }
  }

  Process {
    id: unsubProc
    property string _out: ""
    property string _input: ""
    stdinEnabled: true
    stdout: SplitParser { onRead: function(l) { root.handleUnsubLine(l) } }
    onStarted: { write(_input + "\n"); _input = "" }
    onExited: root.finishUnsubscribe()
  }

  Process {
    id: resubProc
    property string _out: ""
    stdout: SplitParser { onRead: function(l) { resubProc._out = root.append(resubProc._out, l) } }
    onExited: {
      var r = root.parseLast(_out)
      if (r.error) { root.say(r.error, true); return }
      root.say("Opened " + r.url + " so you can sign back up.", false)
      root.loadUnsubscribed()
      root.loadCached()
    }
  }

  Process {
    id: forgetProc
    onExited: { root.configured = false; root.email = ""; root.say("Disconnected.", false) }
  }
}
