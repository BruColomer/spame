import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.brucolomer.spame"
  ipcTarget: "io.github.brucolomer.spame"
  manageIpc: false

  property string tab: "unsubscribe"
  property string filterText: ""
  property string emailText: ""
  property string passwordText: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property var visibleSenders: {
    var q = filterText.trim().toLowerCase()
    var list = spame.subscribed
    if (q === "") return list
    return list.filter(function(s) {
      return String(s.name).toLowerCase().indexOf(q) >= 0
        || String(s.domain).toLowerCase().indexOf(q) >= 0
        || String(s.subject || "").toLowerCase().indexOf(q) >= 0
    })
  }

  // Only the sections this mailbox actually has, in the helper's order.
  readonly property var sections: {
    var cats = spame.categories.length > 0 ? spame.categories : [{ id: "other", label: "Newsletters" }]
    var known = {}
    var buckets = {}
    for (var c = 0; c < cats.length; c++) { known[cats[c].id] = true; buckets[cats[c].id] = [] }
    for (var i = 0; i < visibleSenders.length; i++) {
      var s = visibleSenders[i]
      var key = known[s.category] ? s.category : "other"
      if (!buckets[key]) buckets[key] = []
      buckets[key].push(s)
    }
    var out = []
    for (var k = 0; k < cats.length; k++) {
      var list = buckets[cats[k].id] || []
      if (list.length > 0) out.push({ id: cats[k].id, label: cats[k].label, senders: list })
    }
    return out
  }

  readonly property int oneClickCount: spame.subscribed.filter(function(s) { return s.method === "one-click" }).length

  function idsOf(list) { return list.map(function(s) { return s.id }) }

  function sectionState(list) {
    var on = 0
    for (var i = 0; i < list.length; i++) if (spame.selected[list[i].id]) on++
    return on === 0 ? "none" : (on === list.length ? "all" : "some")
  }

  function statusGlyph(st) {
    if (st === "done") return "󰄬"
    if (st === "needs-you") return "󰏫"
    if (st === "working" || st === "queued") return "󰔟"
    return ""
  }

  function methodTag(m) {
    if (m === "one-click") return "1-click"
    if (m === "email") return "email"
    return "web"
  }

  function methodLabel(m) {
    if (m === "one-click") return "one-click"
    if (m === "email") return "unsubscribe email"
    if (m === "page" || m === "browser") return "web page"
    return "confirm in browser"
  }

  function relativeScan() {
    if (spame.lastScan === "") return "not scanned yet"
    var mins = Math.round((Date.now() - Date.parse(spame.lastScan)) / 60000)
    if (mins < 1) return "scanned just now"
    if (mins < 60) return "scanned " + mins + " min ago"
    var h = Math.round(mins / 60)
    if (h < 48) return "scanned " + h + " h ago"
    return "scanned " + Math.round(h / 24) + " days ago"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    spame.refresh()
    spame.loadUnsubscribed()
    if (listFlick) listFlick.contentY = 0
    if (spame.configured && spame.scanIsStale()) spame.scan()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: spame
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function scan(): string { spame.scan(); return "ok" }
    function pending(): string { return String(spame.pendingCount) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰇮"
    tooltipText: spame.pendingCount > 0 ? "Spame · " + spame.pendingCount + " newsletter senders" : "Spame"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) spame.scan()
      else root.toggle()
    }

    // Small pulse while scanning or unsubscribing; no unread-style counter.
    Rectangle {
      visible: spame.scanning || spame.unsubscribing
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(3)
      width: Style.space(5); height: width; radius: width / 2
      color: root.accent
      SequentialAnimation on opacity {
        running: spame.scanning || spame.unsubscribing; loops: Animation.Infinite
        NumberAnimation { to: 0.2; duration: 500 }
        NumberAnimation { to: 1.0; duration: 500 }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(
      spame.configured ? Style.space(780) : setupColumn.implicitHeight + header.implicitHeight + Style.space(24),
      Style.space(820))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: emailField.activeFocus || passwordField.activeFocus || filterField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") spame.scan()
        else if (t === "/") filterField.forceActiveFocus()
        else if (t === "1") root.tab = "unsubscribe"
        else if (t === "2") root.tab = "resubscribe"
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(10)

        // -------------------------------------------------------- fixed header

        Column {
          id: header
          Layout.fillWidth: true
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: "Spame"
            meta: !spame.configured ? "Unsubscribe from newsletters in one go"
              : (spame.scanning ? "Scanning your mail…"
              : spame.pendingCount + " senders · " + root.oneClickCount + " one-click · " + root.relativeScan())
            detail: spame.configured ? spame.email : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰇮"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                visible: spame.configured
                iconText: "󰑐"
                tooltipText: "Scan again (r)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !spame.scanning && !spame.unsubscribing
                onClicked: spame.scan()
              }
            }
          }

          Text {
            visible: spame.message !== ""
            width: parent.width
            text: spame.message
            color: spame.errorMessage ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }

          RowLayout {
            visible: spame.configured
            width: parent.width
            spacing: Style.space(8)

            ButtonGroup {
              focusable: false
              foreground: root.foreground
              fontFamily: root.fontFamily
              value: root.tab
              options: [
                { value: "unsubscribe", label: "Unsubscribe · " + spame.pendingCount, icon: "󰗨" },
                { value: "resubscribe", label: "Resubscribe · " + spame.unsubscribed.length, icon: "󰑓" }
              ]
              onChanged: function(v) { root.tab = v }
            }
            Item { Layout.fillWidth: true }
            PanelActionButton {
              iconText: "󰍃"
              tooltipText: "Disconnect " + spame.email
              foreground: root.dim
              hoverColor: root.urgent
              fontFamily: root.fontFamily
              enabled: !spame.busy
              onClicked: spame.forget()
            }
          }

          RowLayout {
            visible: spame.configured && root.tab === "unsubscribe" && spame.subscribed.length > 0
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: filterField
              Layout.fillWidth: true
              foreground: root.foreground
              placeholderText: "Filter by name, domain or subject  (/)"
              text: root.filterText
              onTextChanged: root.filterText = text
              Keys.onEscapePressed: { root.filterText = ""; keyCatcher.forceActiveFocus() }
            }
            PanelActionButton {
              iconText: "󰒆"
              tooltipText: "Select everything shown"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !spame.unsubscribing
              onClicked: spame.selectAll(root.idsOf(root.visibleSenders))
            }
            PanelActionButton {
              iconText: "󰒉"
              tooltipText: "Clear selection"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !spame.unsubscribing && spame.selectedCount > 0
              onClicked: spame.clearSelection()
            }
          }
        }

        // ------------------------------------------------------------ setup

        Column {
          id: setupColumn
          visible: !spame.configured
          Layout.fillWidth: true
          spacing: Style.space(8)

          PanelSeparator { foreground: root.foreground }

          Text {
            width: parent.width
            text: "Spame connects to Gmail with an app password. It only reads mail headers and never deletes anything. The password is stored in your system keyring."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          TextField {
            id: emailField
            width: parent.width
            foreground: root.foreground
            placeholderText: "you@gmail.com"
            text: root.emailText
            onTextChanged: root.emailText = text
            onAccepted: passwordField.forceActiveFocus()
            Keys.onEscapePressed: keyCatcher.forceActiveFocus()
          }

          TextField {
            id: passwordField
            width: parent.width
            foreground: root.foreground
            password: true
            echoMode: TextInput.Password
            placeholderText: "16-character app password"
            text: root.passwordText
            onTextChanged: root.passwordText = text
            onAccepted: spame.connect(root.emailText, root.passwordText)
            Keys.onEscapePressed: keyCatcher.forceActiveFocus()
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Button {
              text: "Create app password"
              iconText: "󰌆"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: Qt.openUrlExternally("https://myaccount.google.com/apppasswords")
            }
            Item { Layout.fillWidth: true }
            Button {
              text: spame.busy ? "Connecting…" : "Connect"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !spame.busy && root.emailText.indexOf("@") > 0 && root.passwordText.length >= 16
              onClicked: {
                spame.connect(root.emailText, root.passwordText)
                root.passwordText = ""
              }
            }
          }
        }

        // ------------------------------------------------------ scrolling list

        Flickable {
          id: listFlick
          visible: spame.configured
          Layout.fillWidth: true
          Layout.fillHeight: true
          contentWidth: width
          contentHeight: root.tab === "unsubscribe" ? sectionsColumn.implicitHeight : resubColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: sectionsColumn
            visible: root.tab === "unsubscribe"
            width: listFlick.width - Style.space(8)
            spacing: Style.space(6)

            Text {
              visible: spame.subscribed.length === 0 && !spame.scanning
              width: parent.width
              topPadding: Style.space(24)
              horizontalAlignment: Text.AlignHCenter
              text: spame.lastScan === "" ? "Press 󰑐 to scan your mailbox." : "All clear. No newsletter senders left."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Text {
              visible: spame.subscribed.length > 0 && root.visibleSenders.length === 0
              width: parent.width
              topPadding: Style.space(24)
              horizontalAlignment: Text.AlignHCenter
              text: "Nothing matches “" + root.filterText + "”."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Repeater {
              model: root.sections
              Section {
                required property var modelData
                width: sectionsColumn.width
                section: modelData
              }
            }
          }

          Column {
            id: resubColumn
            visible: root.tab === "resubscribe"
            width: listFlick.width - Style.space(8)
            spacing: Style.space(2)

            Text {
              width: parent.width
              topPadding: spame.unsubscribed.length === 0 ? Style.space(24) : 0
              bottomPadding: Style.space(6)
              horizontalAlignment: spame.unsubscribed.length === 0 ? Text.AlignHCenter : Text.AlignLeft
              text: spame.unsubscribed.length === 0
                ? "Nothing here yet. Senders you unsubscribe from show up here."
                : "Resubscribe opens the sender's page so you can sign back up."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: spame.unsubscribed.length === 0 ? Style.font.body : Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: spame.unsubscribed
              UnsubscribedRow {
                required property var modelData
                width: resubColumn.width
                entry: modelData
              }
            }
          }
        }

        // ------------------------------------------------------ fixed footer

        Button {
          visible: spame.configured && root.tab === "unsubscribe" && spame.subscribed.length > 0
          Layout.fillWidth: true
          bordered: true
          text: spame.unsubscribing ? "Unsubscribing…"
            : (spame.selectedCount > 0 ? "Done · unsubscribe from " + spame.selectedCount
            : "Tick the senders you don't want")
          iconText: "󰗨"
          selected: spame.selectedCount > 0
          foreground: spame.selectedCount > 0 ? root.foreground : root.dim
          fontFamily: root.fontFamily
          enabled: spame.selectedCount > 0 && !spame.unsubscribing
          onClicked: spame.unsubscribeSelected()
        }
      }
    }
  }

  component Section: Column {
    id: sec
    property var section: ({ id: "", label: "", senders: [] })
    readonly property bool isCollapsed: !!spame.collapsed[section.id]
    readonly property string checkState: root.sectionState(section.senders)
    spacing: Style.space(2)

    CursorSurface {
      id: secHeader
      width: parent.width
      foreground: root.foreground
      fill: root.hoverFill
      implicitHeight: secRow.implicitHeight + Style.space(10)

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: secHeader.hasCursor = true
        onExited: secHeader.hasCursor = false
        onClicked: spame.toggleCollapsed(sec.section.id)
      }

      RowLayout {
        id: secRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(8)

        Text {
          text: sec.isCollapsed ? "󰅂" : "󰅀"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          text: String(sec.section.label).toUpperCase()
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1
          font.bold: true
        }
        Text {
          text: sec.section.senders.length
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Item { Layout.fillWidth: true }
        Text {
          text: sec.checkState === "all" ? "󰄲" : (sec.checkState === "some" ? "󰡖" : "󰄱")
          color: sec.checkState === "none" ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon

          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            cursorShape: Qt.PointingHandCursor
            onClicked: spame.toggleSection(root.idsOf(sec.section.senders))
          }
        }
      }
    }

    Repeater {
      model: sec.isCollapsed ? [] : sec.section.senders
      SenderRow {
        required property var modelData
        width: sec.width
        sender: modelData
      }
    }

    Item { width: 1; height: Style.space(4) }
  }

  component SenderRow: CursorSurface {
    id: row
    property var sender: ({})
    readonly property bool checked: !!spame.selected[sender.id]
    readonly property string status: spame.rowStatus[sender.id] || ""

    foreground: root.foreground
    fill: root.hoverFill
    current: checked
    implicitHeight: rowContent.implicitHeight + Style.space(10)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: spame.unsubscribing ? Qt.ArrowCursor : Qt.PointingHandCursor
      onEntered: row.hasCursor = true
      onExited: row.hasCursor = false
      onClicked: spame.toggle(row.sender.id)
    }

    RowLayout {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(22)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Text {
        text: row.checked ? "󰄲" : "󰄱"
        color: row.checked ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          Text {
            Layout.fillWidth: true
            text: row.sender.name || row.sender.domain
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }
          Text {
            text: row.sender.count + (row.sender.count === 1 ? " email" : " emails")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
        Text {
          Layout.fillWidth: true
          text: row.sender.subject ? row.sender.domain + " · “" + row.sender.subject + "”" : row.sender.domain
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
      }

      Text {
        Layout.preferredWidth: Style.space(44)
        horizontalAlignment: Text.AlignRight
        text: row.status !== "" ? root.statusGlyph(row.status) : root.methodTag(row.sender.method)
        color: row.status === "needs-you" ? root.urgent : (row.status !== "" ? root.foreground : root.dim)
        font.family: root.fontFamily
        font.pixelSize: row.status !== "" ? Style.font.icon : Style.font.caption
      }
    }
  }

  component UnsubscribedRow: CursorSurface {
    id: urow
    property var entry: ({})
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: urowContent.implicitHeight + Style.space(10)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onEntered: urow.hasCursor = true
      onExited: urow.hasCursor = false
    }

    RowLayout {
      id: urowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      Text {
        text: urow.entry.status === "needs-you" ? "󰏫" : "󰄬"
        color: urow.entry.status === "needs-you" ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)
        Text {
          Layout.fillWidth: true
          text: urow.entry.name || urow.entry.domain
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
        Text {
          Layout.fillWidth: true
          text: (urow.entry.status === "needs-you" ? "Confirm in browser" : "Via " + root.methodLabel(urow.entry.method))
            + " · " + String(urow.entry.at || "").substring(0, 10)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
      }

      Button {
        text: "Resubscribe"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        enabled: !spame.busy
        onClicked: spame.resubscribe(urow.entry.id)
      }
    }
  }
}
