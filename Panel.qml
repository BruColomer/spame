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
      return String(s.name).toLowerCase().indexOf(q) >= 0 || String(s.domain).toLowerCase().indexOf(q) >= 0
    })
  }

  function visibleIds() { return visibleSenders.map(function(s) { return s.id }) }

  function statusGlyph(st) {
    if (st === "done") return "󰄬"
    if (st === "needs-you") return "󰏫"
    if (st === "working" || st === "queued") return "󰔟"
    return ""
  }

  function methodLabel(m) {
    if (m === "one-click") return "one-click"
    if (m === "email") return "unsubscribe email"
    if (m === "page" || m === "browser") return "web page"
    return "confirm in browser"
  }

  function relativeScan() {
    if (spame.lastScan === "") return "Not scanned yet"
    var mins = Math.round((Date.now() - Date.parse(spame.lastScan)) / 60000)
    if (mins < 1) return "Scanned just now"
    if (mins < 60) return "Scanned " + mins + " min ago"
    var h = Math.round(mins / 60)
    if (h < 48) return "Scanned " + h + " h ago"
    return "Scanned " + Math.round(h / 24) + " days ago"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    spame.refresh()
    spame.loadUnsubscribed()
    if (panelFlick) panelFlick.contentY = 0
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
    tooltipText: spame.pendingCount > 0 ? spame.pendingCount + " newsletter senders" : "Spame"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) spame.scan()
      else root.toggle()
    }

    Rectangle {
      visible: spame.pendingCount > 0 && !spame.busy
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(1)
      anchors.topMargin: Style.space(2)
      width: Math.max(height, badgeText.implicitWidth + Style.space(6))
      height: badgeText.implicitHeight + Style.space(1)
      radius: height / 2
      color: root.accent

      Text {
        id: badgeText
        anchors.centerIn: parent
        text: spame.pendingCount > 99 ? "99+" : String(spame.pendingCount)
        color: Color.background
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption - 1
        font.bold: true
      }
    }

    Rectangle {
      visible: spame.busy
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(3)
      width: Style.space(5); height: width; radius: width / 2
      color: root.accent
      SequentialAnimation on opacity {
        running: spame.busy; loops: Animation.Infinite
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
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

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

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(10)

          PanelHero {
            id: hero
            width: parent.width
            title: "Spame"
            meta: !spame.configured ? "Unsubscribe from newsletters in one go"
              : (spame.scanning ? "Scanning your mail…"
              : spame.pendingCount + " senders · " + root.relativeScan())
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

          // ------------------------------------------------------------ setup

          Column {
            visible: !spame.configured
            width: parent.width
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

          // ------------------------------------------------------------ tabs

          ButtonGroup {
            visible: spame.configured
            focusable: false
            foreground: root.foreground
            fontFamily: root.fontFamily
            value: root.tab
            options: [
              { value: "unsubscribe", label: "Unsubscribe (" + spame.pendingCount + ")", icon: "󰗨" },
              { value: "resubscribe", label: "Resubscribe (" + spame.unsubscribed.length + ")", icon: "󰑓" }
            ]
            onChanged: function(v) { root.tab = v }
          }

          // ------------------------------------------------------ unsubscribe

          Column {
            visible: spame.configured && root.tab === "unsubscribe"
            width: parent.width
            spacing: Style.space(8)

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: filterField
                Layout.fillWidth: true
                foreground: root.foreground
                placeholderText: "Filter senders (/)"
                text: root.filterText
                onTextChanged: root.filterText = text
                Keys.onEscapePressed: { root.filterText = ""; keyCatcher.forceActiveFocus() }
              }
              PanelActionButton {
                iconText: "󰒆"
                tooltipText: "Select all shown"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !spame.unsubscribing
                onClicked: spame.selectAll(root.visibleIds())
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

            Text {
              visible: spame.subscribed.length === 0 && !spame.scanning
              width: parent.width
              topPadding: Style.space(12)
              bottomPadding: Style.space(12)
              horizontalAlignment: Text.AlignHCenter
              text: spame.lastScan === "" ? "Press 󰑐 to scan your mailbox." : "Inbox is clean. No newsletter senders left."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Column {
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: root.visibleSenders
                SenderRow {
                  required property var modelData
                  width: parent.width
                  sender: modelData
                }
              }
            }

            Button {
              width: parent.width
              visible: spame.subscribed.length > 0
              bordered: true
              text: spame.unsubscribing ? "Unsubscribing…"
                : (spame.selectedCount > 0 ? "Done · unsubscribe from " + spame.selectedCount : "Tick the senders you don't want")
              iconText: "󰗨"
              foreground: spame.selectedCount > 0 ? root.urgent : root.dim
              fontFamily: root.fontFamily
              enabled: spame.selectedCount > 0 && !spame.unsubscribing
              onClicked: spame.unsubscribeSelected()
            }
          }

          // ------------------------------------------------------ resubscribe

          Column {
            visible: spame.configured && root.tab === "resubscribe"
            width: parent.width
            spacing: Style.space(2)

            Text {
              visible: spame.unsubscribed.length === 0
              width: parent.width
              topPadding: Style.space(12)
              bottomPadding: Style.space(12)
              horizontalAlignment: Text.AlignHCenter
              text: "Nothing here yet. Senders you unsubscribe from show up here."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Text {
              visible: spame.unsubscribed.length > 0
              width: parent.width
              bottomPadding: Style.space(4)
              text: "Resubscribe opens the sender's page so you can sign back up."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: spame.unsubscribed
              UnsubscribedRow {
                required property var modelData
                width: parent.width
                entry: modelData
              }
            }
          }

          Button {
            visible: spame.configured
            text: "Disconnect " + spame.email
            iconText: "󰍃"
            foreground: root.dim
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            enabled: !spame.busy
            onClicked: spame.forget()
          }
        }
      }
    }
  }

  component SenderRow: CursorSurface {
    id: row
    property var sender: ({})
    readonly property bool checked: !!spame.selected[sender.id]
    readonly property string status: spame.rowStatus[sender.id] || ""

    foreground: root.foreground
    fill: root.hoverFill
    current: checked
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

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
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Text {
        text: row.checked ? "󰄲" : "󰄱"
        color: row.checked ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

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
          Layout.fillWidth: true
          text: row.sender.domain + " · " + row.sender.count + (row.sender.count === 1 ? " email" : " emails")
            + " · " + root.methodLabel(row.sender.method)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
      }

      Text {
        visible: row.status !== ""
        text: root.statusGlyph(row.status)
        color: row.status === "needs-you" ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }
    }
  }

  component UnsubscribedRow: CursorSurface {
    id: urow
    property var entry: ({})
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: urowContent.implicitHeight + Style.spacing.rowPaddingX

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
