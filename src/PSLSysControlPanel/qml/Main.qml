import QtQuick
import QtQuick.Window
import QtQuick.Controls.Basic
import QtQuick.Layouts

ApplicationWindow {
    id: root
    visible: true
    width: 1400
    height: 860
    minimumWidth: 1120
    minimumHeight: 680
    title: "PSL System Control Panel"
    color: theme.bgDeep

    // ---------- Theme ----------
    QtObject {
        id: theme
        readonly property color bgDeep:      "#0A0E1A"
        readonly property color bgSurface:   "#131826"
        readonly property color bgElevated:  "#1A2133"
        readonly property color bgHover:     "#202A42"
        readonly property color bgSelected:  "#1E2B4A"
        readonly property color border:      "#242C42"
        readonly property color borderBright:"#324063"
        readonly property color accent:      "#00D9FF"
        readonly property color accentDim:   "#0099B8"
        readonly property color textPrimary: "#E8EDF5"
        readonly property color textMuted:   "#8B96B0"
        readonly property color textDim:     "#5F6A84"
        readonly property color success:     "#4ADE80"
        readonly property color warning:     "#FBBF24"
        readonly property color danger:      "#F87171"
        readonly property color stopped:     "#6B7280"
        readonly property color starting:    "#60A5FA"

        function statusColor(code) {
            switch (code) {
                case 0: return theme.stopped;   // Stopped
                case 1: return theme.starting;  // Starting
                case 2: return theme.success;   // Running
                case 3: return theme.warning;   // Degraded
                case 4: return theme.danger;    // Crashed
            }
            return theme.textDim;
        }
    }

    property int selectedIndex: 0
    property int tickSignal: 0  // bumps each data refresh to force chart redraw
    property string overlay: ""  // "" | "config" | "logs"

    // Reactive aliases for the active session. Switching hosts replaces
    // hostManager.currentClient/currentModel, which these bindings track,
    // so every inner reference to agentClient/componentModel updates in
    // lockstep without touching the context. Typed as QtObject (not var)
    // because Connections { target: agentClient } needs a plain QObject* —
    // a var-wrapped one wouldn't hook signal subscriptions (method calls
    // through JS dispatch still work, which is why startComponent etc.
    // worked while Connections did not).
    readonly property QtObject agentClient: hostManager.currentClient
    readonly property QtObject componentModel: hostManager.currentModel

    // Reset the row selection when the active host changes — the previous
    // host's component list probably doesn't map to the new one.
    Connections {
        target: hostManager
        function onCurrentIndexChanged() { root.selectedIndex = 0 }
    }
    Timer {
        interval: 1000; running: true; repeat: true
        onTriggered: tickSignal = tickSignal + 1
    }

    // ---- mini-log auto-tail arbitration ----
    // The mini "recent logs" strip wants a live tail running whenever
    // possible, but the dedicated LOGS overlay takes priority when open
    // (only one log_tail session per AgentClient today). Here's the
    // coordination:
    //   * Overlay START — ``startLogTail`` in the overlay button kills
    //     whatever session is active and opens a new one with 64 KiB of
    //     history. The mini's Connections receives onLogTailEnded for the
    //     old session and schedules a retry via ``miniRetry``.
    //   * Overlay STOP / close — tail ends; retry fires after 500 ms and,
    //     since logsOverlay.streaming is now false, the mini starts its
    //     own 4 KiB-history session for the current row's primary log.
    //   * Row change — everything stops and clears; the mini re-arms for
    //     the newly selected row once its log_files are known.
    property bool miniTailActive: false

    function primaryLogFileFor(row) {
        if (!componentModel || row < 0) return "";
        var snap = componentModel.snapshotFor(row);
        if (!snap || !snap.logFiles || snap.logFiles.length === 0) return "";
        return snap.logFiles[0];
    }

    function ensureMiniTail() {
        if (logsOverlay.streaming) return;
        if (!agentClient || agentClient.connectionState !== 3) return;
        if (!agentClient.operatorAuthenticated) return;
        if (miniTailActive) return;
        var path = primaryLogFileFor(root.selectedIndex);
        if (!path) return;
        agentClient.startLogTail(root.selectedIndex, path, "", 4096);
        miniTailActive = true;
    }

    Timer {
        id: miniRetry
        interval: 500
        repeat: false
        onTriggered: ensureMiniTail()
    }

    Connections {
        target: agentClient
        function onConnectionStateChanged() { miniRetry.restart(); }
        function onOperatorAuthenticatedChanged() { miniRetry.restart(); }
        function onComponentListUpdated() { miniRetry.restart(); }
    }

    // ---------- Header ----------
    Rectangle {
        id: headerBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 60
        color: theme.bgSurface
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: theme.border }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 22
            anchors.rightMargin: 22
            spacing: 14

            Rectangle {
                width: 34; height: 34; radius: 8
                color: "transparent"
                border.color: theme.accent; border.width: 2
                Text {
                    anchors.centerIn: parent
                    text: "◆"
                    color: theme.accent
                    font.pixelSize: 18
                }
            }
            ColumnLayout {
                spacing: 0
                Text {
                    text: "PSL SYSTEM CONTROL PANEL"
                    color: theme.textPrimary
                    font.pixelSize: 14
                    font.letterSpacing: 1.6
                    font.weight: Font.DemiBold
                }
                Text {
                    text: "v0.1.0"
                    color: theme.textDim
                    font.pixelSize: 10
                    font.letterSpacing: 0.8
                }
            }
            Item { Layout.fillWidth: true }

            HeaderBadge {
                label: "AGENT"
                value: {
                    // AgentClient.ConnectionState: 0=Disconnected 1=Connecting 2=Handshaking 3=Ready 4=Failed
                    switch (agentClient.connectionState) {
                        case 0: return "disconnected";
                        case 1: return "connecting";
                        case 2: return "handshaking";
                        case 3: return agentClient.agentHostId || "ready";
                        case 4: return "failed";
                    }
                    return "?";
                }
                dotColor: {
                    switch (agentClient.connectionState) {
                        case 3: return theme.success;
                        case 1:
                        case 2: return theme.warning;
                        case 4: return theme.danger;
                    }
                    return theme.textDim;
                }
            }
            HeaderBadge {
                label: "OPERATOR"
                value: agentClient.operatorEnrolled ? "available" : "not enrolled"
                dotColor: agentClient.operatorEnrolled ? theme.accent : theme.textDim
            }
            HeaderBadge {
                label: "CLOCK"
                value: Qt.formatDateTime(new Date(), "hh:mm:ss")
                dotColor: theme.textMuted
                updatesEach: true
            }
        }
    }

    // ---------- Connection-state strip ----------
    // Visible only when the agent is not in the Ready state. Takes zero
    // height when hidden so the body layout isn't disturbed.
    Rectangle {
        id: connStrip
        anchors.top: headerBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        readonly property int stateCode: agentClient.connectionState
        readonly property bool shown: stateCode !== 3
        height: shown ? 26 : 0
        visible: shown
        color: {
            switch (stateCode) {
                case 0: return "#2a1a1a";  // disconnected — dim red
                case 4: return "#3a1d1d";  // failed — more red
                case 1:
                case 2: return "#1f2a3a";  // connecting/handshaking — dim blue
            }
            return theme.bgSurface;
        }
        Rectangle {
            anchors.bottom: parent.bottom; width: parent.width; height: 1; color: theme.border
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            spacing: 10
            Rectangle {
                width: 7; height: 7; radius: 3.5
                color: {
                    switch (connStrip.stateCode) {
                        case 1:
                        case 2: return theme.warning;
                        case 4: return theme.danger;
                    }
                    return theme.textMuted;
                }
            }
            Text {
                text: {
                    switch (connStrip.stateCode) {
                        case 0: return "Disconnected — reconnecting…";
                        case 1: return "Connecting to " + agentClient.agentHostId + "…";
                        case 2: return "Handshaking…";
                        case 4: return "Connection failed: " + agentClient.lastError + " (retrying)";
                    }
                    return "";
                }
                color: theme.textPrimary
                font.pixelSize: 11
                font.family: "Consolas"
            }
            Item { Layout.fillWidth: true }
        }
    }

    // ---------- Host-selector strip ----------
    // Visible only when more than one host session is configured. Renders
    // the host names as tabs; clicking swaps hostManager.currentIndex.
    Rectangle {
        id: hostStrip
        anchors.top: connStrip.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        readonly property bool shown: hostManager.count > 1
        height: shown ? 34 : 0
        visible: shown
        color: theme.bgSurface
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: theme.border }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            Text {
                text: "HOSTS"
                anchors.verticalCenter: parent.verticalCenter
                color: theme.textMuted
                font.pixelSize: 10
                font.letterSpacing: 1.8
                font.weight: Font.DemiBold
                rightPadding: 12
            }

            Repeater {
                model: hostManager.hostNames
                delegate: Rectangle {
                    required property int index
                    required property string modelData
                    readonly property bool active: index === hostManager.currentIndex
                    width: tabLabel.implicitWidth + 22
                    height: 24
                    anchors.verticalCenter: parent.verticalCenter
                    radius: 4
                    color: active ? theme.bgSelected
                                  : (tabArea.containsMouse ? theme.bgHover : "transparent")
                    border.color: active ? theme.accentDim : theme.border
                    border.width: 1
                    Text {
                        id: tabLabel
                        anchors.centerIn: parent
                        text: modelData
                        color: active ? theme.textPrimary : theme.textMuted
                        font.pixelSize: 11
                        font.family: "Consolas"
                        font.weight: active ? Font.DemiBold : Font.Normal
                    }
                    MouseArea {
                        id: tabArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: hostManager.currentIndex = index
                    }
                }
            }
        }
    }

    // ---------- Body: Sidebar + Detail ----------
    Rectangle {
        id: body
        anchors.top: hostStrip.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footerBar.top
        color: theme.bgDeep

        // ----- Sidebar -----
        Rectangle {
            id: sidebar
            width: 320
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            color: theme.bgSurface
            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: theme.border }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "COMPONENTS"
                        color: theme.textMuted
                        font.pixelSize: 11
                        font.letterSpacing: 2.0
                        font.weight: Font.DemiBold
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: componentModel.rowCount() + " total"
                        color: theme.textDim
                        font.pixelSize: 10
                    }
                }

                ListView {
                    id: componentList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 6
                    model: componentModel
                    boundsBehavior: Flickable.StopAtBounds
                    currentIndex: root.selectedIndex

                    delegate: Rectangle {
                        id: card
                        required property int index
                        required property string name
                        required property string host
                        required property int statusCode
                        required property string statusText
                        required property string uptimeText
                        required property real eventsPerSec

                        width: ListView.view.width
                        height: 78
                        radius: 8
                        color: ListView.view.currentIndex === index
                               ? theme.bgSelected
                               : (hover.containsMouse ? theme.bgHover : theme.bgElevated)
                        border.color: ListView.view.currentIndex === index ? theme.accentDim : theme.border
                        border.width: 1

                        Behavior on color { ColorAnimation { duration: 120 } }

                        MouseArea {
                            id: hover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.selectedIndex = index
                        }

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 4

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8

                                Rectangle {
                                    width: 10; height: 10; radius: 5
                                    color: theme.statusColor(statusCode)
                                    SequentialAnimation on opacity {
                                        running: statusCode === 2 || statusCode === 3 || statusCode === 1
                                        loops: Animation.Infinite
                                        NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutQuad }
                                        NumberAnimation { to: 1.0;  duration: 900; easing.type: Easing.InOutQuad }
                                    }
                                }
                                Text {
                                    text: name
                                    color: theme.textPrimary
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }
                                Text {
                                    text: statusText
                                    color: theme.statusColor(statusCode)
                                    font.pixelSize: 9
                                    font.letterSpacing: 1.2
                                    font.weight: Font.Bold
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Text {
                                    text: host
                                    color: theme.textDim
                                    font.pixelSize: 11
                                    font.family: "Consolas"
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    text: statusCode === 0 ? "—" : eventsPerSec.toFixed(1) + " eps"
                                    color: theme.textMuted
                                    font.pixelSize: 11
                                    font.family: "Consolas"
                                }
                            }
                            Text {
                                text: "uptime " + uptimeText
                                color: theme.textDim
                                font.pixelSize: 10
                                font.family: "Consolas"
                                Layout.fillWidth: true
                            }
                        }
                    }
                }

                // Cluster summary card
                Rectangle {
                    Layout.fillWidth: true
                    height: 96
                    radius: 8
                    color: theme.bgElevated
                    border.color: theme.border; border.width: 1

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 6
                        Text {
                            text: "CLUSTER"
                            color: theme.textMuted
                            font.pixelSize: 10; font.letterSpacing: 1.8; font.weight: Font.DemiBold
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 14
                            MiniStat { label: "hosts";   value: "2" }
                            MiniStat { label: "running"; value: "3"; valueColor: theme.success }
                            MiniStat { label: "warn";    value: "1"; valueColor: theme.warning }
                            MiniStat { label: "stopped"; value: "1"; valueColor: theme.textDim }
                        }
                    }
                }
            }
        }

        // ----- Detail pane -----
        Item {
            id: detail
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: sidebar.right
            anchors.right: parent.right

            // The (tickSignal, ...) comma expression creates a binding dependency on
            // tickSignal so the snapshot re-reads each tick without needing per-field
            // NOTIFY signals on the model.
            property var snap: (root.tickSignal,
                                componentModel.snapshotFor(root.selectedIndex))
            readonly property string cName:       snap.name       ?? ""
            readonly property string cHost:       snap.host       ?? ""
            readonly property int    cStatus:     snap.statusCode ?? 0
            readonly property string cStatusText: snap.statusText ?? ""
            readonly property string cUptimeText: snap.uptimeText ?? "—"
            readonly property real   cEvents:     snap.eventsPerSec ?? 0
            readonly property real   cCpu:        snap.cpuPct     ?? 0
            readonly property real   cRss:        snap.rssMb      ?? -1
            readonly property int    cQueue:      snap.queueDepth ?? 0
            readonly property var    cLogFiles:   snap.logFiles   ?? []

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 22
                spacing: 16

                // Title row
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 14

                    ColumnLayout {
                        spacing: 4
                        RowLayout {
                            spacing: 10
                            Rectangle {
                                width: 12; height: 12; radius: 6
                                color: theme.statusColor(detail.cStatus)
                                SequentialAnimation on opacity {
                                    running: detail.cStatus !== 0
                                    loops: Animation.Infinite
                                    NumberAnimation { to: 0.4; duration: 900 }
                                    NumberAnimation { to: 1.0; duration: 900 }
                                }
                            }
                            Text {
                                text: detail.cName
                                color: theme.textPrimary
                                font.pixelSize: 26
                                font.weight: Font.Medium
                            }
                            Rectangle {
                                Layout.alignment: Qt.AlignVCenter
                                implicitWidth: statusLabel.implicitWidth + 16
                                height: 22
                                radius: 4
                                color: "transparent"
                                border.color: theme.statusColor(detail.cStatus)
                                border.width: 1
                                Text {
                                    id: statusLabel
                                    anchors.centerIn: parent
                                    text: detail.cStatusText
                                    color: theme.statusColor(detail.cStatus)
                                    font.pixelSize: 10
                                    font.letterSpacing: 1.6
                                    font.weight: Font.Bold
                                }
                            }
                        }
                        Text {
                            text: detail.cHost + "  ·  uptime " + detail.cUptimeText
                            color: theme.textMuted
                            font.pixelSize: 12
                            font.family: "Consolas"
                        }
                    }

                    Item { Layout.fillWidth: true }

                    ActionButton {
                        label: "START"
                        accent: theme.success
                        // Require: connected + operator authenticated + in a
                        // state that can transition to running. If the agent
                        // reports real state these are the correct gates; in
                        // the offline mockup detail.cStatus is still driven
                        // by the fake ComponentModel.
                        enabledReal: agentClient.connectionState === 3
                                     && agentClient.operatorAuthenticated
                                     && (detail.cStatus === 0 || detail.cStatus === 4)
                        onClicked: agentClient.startComponent(root.selectedIndex)
                    }
                    ActionButton {
                        label: "STOP"
                        accent: theme.danger
                        enabledReal: agentClient.connectionState === 3
                                     && agentClient.operatorAuthenticated
                                     && (detail.cStatus === 2 || detail.cStatus === 3 || detail.cStatus === 1)
                        onClicked: agentClient.stopComponent(root.selectedIndex)
                    }
                    ActionButton {
                        label: "RESTART"
                        accent: theme.accent
                        enabledReal: agentClient.connectionState === 3
                                     && agentClient.operatorAuthenticated
                                     && detail.cStatus !== 0
                        onClicked: agentClient.restartComponent(root.selectedIndex)
                    }
                    ActionButton {
                        label: "CONFIG"
                        accent: theme.accentDim
                        enabledReal: agentClient.connectionState === 3
                                     && agentClient.operatorAuthenticated
                        onClicked: {
                            root.overlay = "config";
                            agentClient.listConfigFiles(root.selectedIndex);
                        }
                    }
                    ActionButton {
                        label: "LOGS"
                        accent: theme.accentDim
                        enabledReal: agentClient.connectionState === 3
                                     && agentClient.operatorAuthenticated
                        onClicked: root.overlay = "logs"
                    }
                }

                // Operator-auth bar: prompts for the operator password when
                // the agent is enrolled but we haven't derived the key yet.
                // Collapses once authenticated.
                Rectangle {
                    Layout.fillWidth: true
                    height: authBar.needed ? 58 : 0
                    visible: authBar.needed
                    radius: 8
                    color: theme.bgSurface
                    border.color: theme.accentDim
                    border.width: 1

                    QtObject {
                        id: authBar
                        property bool needed: agentClient.connectionState === 3
                                              && agentClient.operatorEnrolled
                                              && !agentClient.operatorAuthenticated
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 12
                        Text {
                            text: "OPERATOR PASSWORD"
                            color: theme.textMuted
                            font.pixelSize: 10
                            font.letterSpacing: 1.8
                            font.weight: Font.DemiBold
                        }
                        TextField {
                            id: pwField
                            Layout.fillWidth: true
                            echoMode: TextInput.Password
                            placeholderText: "Required to start/stop components"
                            enabled: !agentClient.operatorAuthInProgress
                            color: theme.textPrimary
                            background: Rectangle {
                                color: theme.bgElevated
                                border.color: theme.border
                                border.width: 1
                                radius: 4
                            }
                            onAccepted: {
                                if (pwField.text.length > 0) {
                                    agentClient.authenticateOperator(pwField.text);
                                    pwField.text = "";
                                }
                            }
                        }
                        ActionButton {
                            label: agentClient.operatorAuthInProgress ? "DERIVING…" : "AUTHENTICATE"
                            accent: theme.accent
                            enabledReal: !agentClient.operatorAuthInProgress && pwField.text.length > 0
                            onClicked: {
                                agentClient.authenticateOperator(pwField.text);
                                pwField.text = "";
                            }
                        }
                    }
                }

                // Metrics row
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    MetricCard {
                        Layout.fillWidth: true
                        label: "EVENTS / SEC"
                        value: detail.cStatus === 0 ? "—" : detail.cEvents.toFixed(1)
                        valueColor: theme.accent
                    }
                    MetricCard {
                        Layout.fillWidth: true
                        label: "CPU"
                        value: detail.cStatus === 0 ? "—" : detail.cCpu.toFixed(1) + "%"
                        valueColor: detail.cCpu > 70 ? theme.warning : theme.textPrimary
                    }
                    MetricCard {
                        Layout.fillWidth: true
                        label: "RSS"
                        value: (detail.cStatus === 0 || detail.cRss < 0)
                               ? "—"
                               : detail.cRss.toFixed(1) + " MB"
                        valueColor: theme.textPrimary
                    }
                    MetricCard {
                        Layout.fillWidth: true
                        label: "QUEUE DEPTH"
                        value: detail.cStatus === 0 ? "—" : detail.cQueue.toString()
                        valueColor: detail.cQueue > 60 ? theme.warning : theme.textPrimary
                    }
                    MetricCard {
                        Layout.fillWidth: true
                        label: "UPTIME"
                        value: detail.cUptimeText
                        valueColor: theme.textPrimary
                    }
                }

                // Chart + logs
                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 12

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: 10
                        color: theme.bgSurface
                        border.color: theme.border; border.width: 1

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 16
                            spacing: 8

                            RowLayout {
                                Text {
                                    text: "EVENTS / SEC  ·  last 60s"
                                    color: theme.textMuted
                                    font.pixelSize: 10
                                    font.letterSpacing: 1.6
                                    font.weight: Font.DemiBold
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    text: detail.cStatus === 0 ? "—" : detail.cEvents.toFixed(1) + " now"
                                    color: theme.accent
                                    font.pixelSize: 11
                                    font.family: "Consolas"
                                }
                            }

                            Canvas {
                                id: chart
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                antialiasing: true

                                property var points: []
                                property real yMax: 100

                                function refresh() {
                                    var raw = componentModel.historyFor(root.selectedIndex);
                                    var pts = [];
                                    var maxY = 20;
                                    for (var i = 0; i < raw.length; ++i) {
                                        var p = raw[i];
                                        pts.push({ x: p.x, y: p.y });
                                        if (p.y > maxY) maxY = p.y;
                                    }
                                    chart.points = pts;
                                    chart.yMax = maxY * 1.25 + 1;
                                    chart.requestPaint();
                                }

                                Connections {
                                    target: root
                                    function onTickSignal() { chart.refresh(); }
                                    function onSelectedIndexChanged() { chart.refresh(); }
                                }
                                Component.onCompleted: refresh()

                                onPaint: {
                                    var ctx = getContext("2d");
                                    ctx.clearRect(0, 0, width, height);

                                    // Grid
                                    ctx.strokeStyle = theme.border;
                                    ctx.lineWidth = 1;
                                    ctx.beginPath();
                                    for (var g = 1; g < 5; ++g) {
                                        var y = (height / 5) * g;
                                        ctx.moveTo(0, y);
                                        ctx.lineTo(width, y);
                                    }
                                    ctx.stroke();

                                    if (points.length < 2) return;

                                    var xMin = points[0].x;
                                    var xMax = points[points.length - 1].x;
                                    var xSpan = Math.max(1, xMax - xMin);
                                    var yMaxLocal = yMax;

                                    function sx(p) { return ((p.x - xMin) / xSpan) * width; }
                                    function sy(p) { return height - (p.y / yMaxLocal) * height; }

                                    // Area fill under line
                                    var grad = ctx.createLinearGradient(0, 0, 0, height);
                                    grad.addColorStop(0, Qt.rgba(0, 0.85, 1.0, 0.28));
                                    grad.addColorStop(1, Qt.rgba(0, 0.85, 1.0, 0.0));
                                    ctx.fillStyle = grad;
                                    ctx.beginPath();
                                    ctx.moveTo(sx(points[0]), height);
                                    for (var i = 0; i < points.length; ++i) {
                                        ctx.lineTo(sx(points[i]), sy(points[i]));
                                    }
                                    ctx.lineTo(sx(points[points.length - 1]), height);
                                    ctx.closePath();
                                    ctx.fill();

                                    // Line
                                    ctx.strokeStyle = theme.accent;
                                    ctx.lineWidth = 2;
                                    ctx.lineJoin = "round";
                                    ctx.beginPath();
                                    ctx.moveTo(sx(points[0]), sy(points[0]));
                                    for (var j = 1; j < points.length; ++j) {
                                        ctx.lineTo(sx(points[j]), sy(points[j]));
                                    }
                                    ctx.stroke();

                                    // Last point marker
                                    var last = points[points.length - 1];
                                    ctx.fillStyle = theme.accent;
                                    ctx.beginPath();
                                    ctx.arc(sx(last), sy(last), 3.5, 0, Math.PI * 2);
                                    ctx.fill();
                                }
                            }
                        }
                    }

                    // Logs panel — mirrors the active LOGS-overlay tail with
                    // a smaller line budget. Same wire-level source as the
                    // overlay; both are driven by the single AgentClient log-
                    // tail session. Cleared on row change and at the start of
                    // every new tail so what's visible is always the current
                    // component's fresh stream, never a stale snapshot.
                    Rectangle {
                        id: miniLogPane
                        Layout.preferredWidth: 420
                        Layout.fillHeight: true
                        radius: 10
                        color: theme.bgSurface
                        border.color: theme.border; border.width: 1

                        // Selectable + horizontally-scrollable mini-log.
                        // Backed by a TextArea so operators can highlight
                        // and copy text; wrapped in a ScrollView so long
                        // lines can be scrolled sideways. Cap and prefix-
                        // compaction are done in JS before append.
                        property int miniMaxLines: 40
                        property int miniLineCount: 0

                        function miniAppend(line) {
                            if (!line) return;
                            // Compact ``YYYY-MM-DD HH:MM:SS.mmm [LEVEL  ]
                            // module.path: msg`` → ``HH:MM:SS [LEVEL] msg``.
                            // Raw pass-through for non-matching lines so
                            // stack traces and foreign formats still show.
                            var re = /^\d{4}-\d{2}-\d{2} (\d{2}:\d{2}:\d{2})(?:\.\d+)? \[\s*(\w+)\s*\] [\w.]+:\s*(.*)$/;
                            var m = line.match(re);
                            var out = m ? (m[1] + " [" + m[2] + "] " + m[3]) : line;
                            if (miniTextArea.length > 0) miniTextArea.append(out);
                            else miniTextArea.text = out;
                            miniLineCount += 1;
                            while (miniLineCount > miniMaxLines) {
                                var nl = miniTextArea.text.indexOf("\n");
                                if (nl < 0) break;
                                miniTextArea.remove(0, nl + 1);
                                miniLineCount -= 1;
                            }
                        }

                        function miniLogClear() {
                            miniTextArea.clear();
                            miniLineCount = 0;
                        }

                        // Row change: stop whichever tail is active, close
                        // the overlay if it was open for the previous row,
                        // clear both views, let the retry timer re-arm the
                        // mini for the new row once its log_files land.
                        Connections {
                            target: root
                            function onSelectedIndexChanged() {
                                if (agentClient) agentClient.stopLogTail();
                                root.miniTailActive = false;
                                miniLogPane.miniLogClear();
                                logsOverlay.tailClear();
                                logsOverlay.streaming = false;
                                if (root.overlay === "logs") root.overlay = "";
                                miniRetry.restart();
                            }
                        }

                        // The mini-log and the overlay both listen to the
                        // same AgentClient signals — writes are independent.
                        Connections {
                            target: hostManager.currentClient
                            function onLogTailStarted(row, path) {
                                if (row !== root.selectedIndex) return;
                                miniLogPane.miniLogClear();
                            }
                            function onLogTailLine(row, lineNo, text) {
                                if (row !== root.selectedIndex) return;
                                miniLogPane.miniAppend(lineNo + "  " + text);
                            }
                            function onLogTailBytes(row, offset, data) {
                                if (row !== root.selectedIndex) return;
                                var s = data;
                                if (typeof data === "object") {
                                    try { s = new TextDecoder().decode(data); }
                                    catch (e) { s = "" + data; }
                                }
                                var lines = String(s).split(/\r?\n/);
                                for (var i = 0; i < lines.length; ++i) {
                                    if (lines[i].length > 0) miniLogPane.miniAppend(lines[i]);
                                }
                            }
                            function onLogTailEnded(row, reason) {
                                root.miniTailActive = false;
                                miniRetry.restart();
                            }
                        }

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 16
                            spacing: 8

                            RowLayout {
                                Text {
                                    text: "RECENT LOGS"
                                    color: theme.textMuted
                                    font.pixelSize: 10
                                    font.letterSpacing: 1.6
                                    font.weight: Font.DemiBold
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    text: logsOverlay.streaming
                                          ? "tail · live"
                                          : "press LOGS to tail"
                                    color: logsOverlay.streaming
                                           ? theme.success
                                           : theme.textDim
                                    font.pixelSize: 10
                                }
                            }

                            Flickable {
                                id: miniScroll
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                contentWidth: Math.max(width, miniTextArea.implicitWidth + 12)
                                contentHeight: Math.max(height, miniTextArea.implicitHeight + 12)
                                flickableDirection: Flickable.HorizontalAndVerticalFlick
                                boundsBehavior: Flickable.StopAtBounds

                                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                                ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }

                                TextEdit {
                                    id: miniTextArea
                                    readOnly: true
                                    selectByMouse: true
                                    selectByKeyboard: true
                                    wrapMode: TextEdit.NoWrap
                                    textFormat: TextEdit.PlainText
                                    color: theme.textMuted
                                    selectedTextColor: theme.textPrimary
                                    selectionColor: theme.accentDim
                                    font.family: "Consolas"
                                    font.pixelSize: 11
                                    onTextChanged: Qt.callLater(snapToEnd)
                                    function snapToEnd() {
                                        miniScroll.contentY = Math.max(
                                            0, miniScroll.contentHeight - miniScroll.height);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---------- Error toast ----------
    // Pops at the bottom-right whenever agentClient.lastError changes to a
    // non-empty string. Auto-dismisses after 5s; click to dismiss early.
    Rectangle {
        id: errorToast
        anchors.right: parent.right
        anchors.bottom: footerBar.top
        anchors.rightMargin: 18
        anchors.bottomMargin: 18
        width: Math.min(440, parent.width - 36)
        height: Math.max(44, toastText.implicitHeight + 22)
        radius: 8
        color: "#3a1d1d"
        border.color: theme.danger
        border.width: 1
        z: 300
        visible: opacity > 0.01
        opacity: 0
        property string message: ""
        Behavior on opacity { NumberAnimation { duration: 160 } }

        Timer {
            id: toastHide
            interval: 5000
            onTriggered: errorToast.opacity = 0
        }

        function show(msg) {
            if (!msg) return;
            errorToast.message = msg;
            errorToast.opacity = 1;
            toastHide.restart();
        }

        RowLayout {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 10
            Rectangle { width: 8; height: 8; radius: 4; color: theme.danger }
            Text {
                id: toastText
                Layout.fillWidth: true
                text: errorToast.message
                color: theme.textPrimary
                font.pixelSize: 11
                font.family: "Consolas"
                wrapMode: Text.WordWrap
            }
            Text {
                text: "×"
                color: theme.textMuted
                font.pixelSize: 18
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: errorToast.opacity = 0
                }
            }
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: errorToast.opacity = 0
            z: -1
        }
    }

    Connections {
        target: hostManager.currentClient
        function onLastErrorChanged() {
            if (agentClient.lastError !== "") {
                errorToast.show(agentClient.lastError);
            }
        }
    }

    // ---------- Footer ----------
    Rectangle {
        id: footerBar
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 26
        color: theme.bgSurface
        Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: theme.border }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            Text {
                text: "ready · 0 pending manager requests"
                color: theme.textDim
                font.pixelSize: 10
                font.family: "Consolas"
            }
            Item { Layout.fillWidth: true }
            Text {
                text: agentClient.connectionState === 3
                      ? "LIVE · components from agent"
                      : "AGENT OFFLINE"
                color: theme.textDim
                font.pixelSize: 10
                font.letterSpacing: 1.8
            }
        }
    }

    // ---------- Inline component definitions ----------
    component HeaderBadge: Rectangle {
        property string label: ""
        property string value: ""
        property color dotColor: theme.textMuted
        property bool updatesEach: false
        implicitWidth: row.implicitWidth + 24
        implicitHeight: 32
        radius: 6
        color: theme.bgElevated
        border.color: theme.border; border.width: 1

        Timer {
            interval: 1000; running: updatesEach; repeat: true
            onTriggered: { /* forces value reeval via the property binding above */ }
        }

        RowLayout {
            id: row
            anchors.centerIn: parent
            spacing: 8
            Rectangle { width: 7; height: 7; radius: 3.5; color: dotColor }
            Text {
                text: label
                color: theme.textDim
                font.pixelSize: 9
                font.letterSpacing: 1.4
                font.weight: Font.DemiBold
            }
            Text {
                text: value
                color: theme.textPrimary
                font.pixelSize: 11
                font.family: "Consolas"
            }
        }
    }

    component MiniStat: ColumnLayout {
        property string label: ""
        property string value: ""
        property color valueColor: theme.textPrimary
        spacing: 2
        Text {
            text: value
            color: valueColor
            font.pixelSize: 18
            font.weight: Font.Medium
        }
        Text {
            text: label
            color: theme.textDim
            font.pixelSize: 9
            font.letterSpacing: 1.4
        }
    }

    component MetricCard: Rectangle {
        property string label: ""
        property string value: ""
        property color valueColor: theme.textPrimary
        Layout.preferredHeight: 92
        radius: 10
        color: theme.bgSurface
        border.color: theme.border; border.width: 1

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 14
            spacing: 6
            Text {
                text: label
                color: theme.textMuted
                font.pixelSize: 10
                font.letterSpacing: 1.6
                font.weight: Font.DemiBold
            }
            Item { Layout.fillHeight: true }
            Text {
                text: value
                color: valueColor
                font.pixelSize: 28
                font.weight: Font.Medium
                Behavior on color { ColorAnimation { duration: 200 } }
            }
        }
    }

    component ActionButton: Rectangle {
        property string label: ""
        property color accent: theme.accent
        property bool enabledReal: true
        signal clicked()

        implicitWidth: 110
        implicitHeight: 34
        radius: 6
        color: enabledReal
               ? (ma.containsMouse ? Qt.rgba(accent.r, accent.g, accent.b, 0.18)
                                   : Qt.rgba(accent.r, accent.g, accent.b, 0.08))
               : Qt.rgba(0.25, 0.28, 0.36, 0.4)
        border.color: enabledReal ? accent : theme.border
        border.width: 1
        opacity: enabledReal ? 1.0 : 0.45

        Behavior on color { ColorAnimation { duration: 120 } }
        Behavior on opacity { NumberAnimation { duration: 120 } }

        Text {
            anchors.centerIn: parent
            text: label
            color: enabledReal ? accent : theme.textDim
            font.pixelSize: 11
            font.letterSpacing: 1.8
            font.weight: Font.Bold
        }
        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: enabledReal ? Qt.PointingHandCursor : Qt.ForbiddenCursor
            onClicked: if (enabledReal) parent.clicked()
        }
    }

    // =============================================================
    // Config-editor overlay
    // =============================================================
    Rectangle {
        id: configOverlay
        anchors.fill: parent
        visible: root.overlay === "config"
        color: Qt.rgba(0, 0, 0, 0.55)
        z: 100

        property string currentPath: ""
        property string loadedSha: ""
        property string loadedContent: ""
        property string statusText: ""
        property color statusColor: theme.textMuted

        Connections {
            target: hostManager.currentClient
            function onConfigFilesListed(row, paths) {
                if (row !== root.selectedIndex) return;
                fileModel.clear();
                for (let i = 0; i < paths.length; ++i) fileModel.append({path: paths[i]});
                if (paths.length > 0) {
                    fileCombo.currentIndex = 0;
                    configOverlay.currentPath = paths[0];
                    agentClient.loadConfigFile(row, paths[0]);
                }
            }
            function onConfigFileLoaded(row, path, content, sha, mtime) {
                if (row !== root.selectedIndex) return;
                configOverlay.loadedSha = sha;
                configOverlay.loadedContent = content;
                editor.text = content;
                configOverlay.statusText = "loaded — sha256 " + sha.substring(0, 10) + "…";
                configOverlay.statusColor = theme.textMuted;
            }
            function onConfigFileSaved(row, path, newSha) {
                if (row !== root.selectedIndex) return;
                configOverlay.loadedSha = newSha;
                configOverlay.loadedContent = editor.text;
                configOverlay.statusText = "saved — sha256 " + newSha.substring(0, 10) + "…";
                configOverlay.statusColor = theme.success;
            }
            function onConfigConflict(row, path, currentSha) {
                if (row !== root.selectedIndex) return;
                configOverlay.statusText =
                    "conflict: file changed on disk (now " + currentSha.substring(0, 10) +
                    "…). Reload to pick up the current content.";
                configOverlay.statusColor = theme.warning;
            }
            function onConfigFailed(row, op, message) {
                if (row !== root.selectedIndex) return;
                configOverlay.statusText = op + ": " + message;
                configOverlay.statusColor = theme.danger;
            }
        }

        ListModel { id: fileModel }

        // Modal click-catcher; clicking outside panel does nothing (avoid
        // accidental loss of edits).
        MouseArea { anchors.fill: parent; hoverEnabled: true }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(960, parent.width - 80)
            height: Math.min(680, parent.height - 80)
            radius: 12
            color: theme.bgSurface
            border.color: theme.border
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 20
                spacing: 14

                RowLayout {
                    spacing: 12
                    Text {
                        text: "CONFIG"
                        color: theme.textMuted
                        font.pixelSize: 11
                        font.letterSpacing: 2.0
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: detail.cName
                        color: theme.textPrimary
                        font.pixelSize: 16
                        font.weight: Font.Medium
                    }
                    Item { Layout.fillWidth: true }
                    ComboBox {
                        id: fileCombo
                        Layout.preferredWidth: 280
                        model: fileModel
                        textRole: "path"
                        onActivated: {
                            configOverlay.currentPath = fileModel.get(currentIndex).path;
                            agentClient.loadConfigFile(
                                root.selectedIndex, configOverlay.currentPath);
                        }
                    }
                    ActionButton {
                        label: "CLOSE"
                        accent: theme.textDim
                        enabledReal: true
                        onClicked: root.overlay = ""
                    }
                }

                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    TextArea {
                        id: editor
                        placeholderText: "(no file loaded)"
                        color: theme.textPrimary
                        font.family: "Consolas"
                        font.pixelSize: 13
                        selectByMouse: true
                        wrapMode: TextEdit.NoWrap
                        background: Rectangle {
                            color: theme.bgDeep
                            border.color: theme.border
                            border.width: 1
                            radius: 4
                        }
                    }
                }

                RowLayout {
                    spacing: 12
                    Text {
                        text: configOverlay.statusText
                        color: configOverlay.statusColor
                        font.pixelSize: 11
                        font.family: "Consolas"
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }
                    ActionButton {
                        label: "RELOAD"
                        accent: theme.textMuted
                        enabledReal: configOverlay.currentPath !== ""
                        onClicked: agentClient.loadConfigFile(
                            root.selectedIndex, configOverlay.currentPath)
                    }
                    ActionButton {
                        label: "SAVE"
                        accent: theme.success
                        enabledReal: configOverlay.currentPath !== ""
                                     && editor.text !== configOverlay.loadedContent
                        onClicked: agentClient.saveConfigFile(
                            root.selectedIndex,
                            configOverlay.currentPath,
                            editor.text,
                            configOverlay.loadedSha)
                    }
                }
            }
        }
    }

    // =============================================================
    // Log-tail overlay
    // =============================================================
    Rectangle {
        id: logsOverlay
        anchors.fill: parent
        visible: root.overlay === "logs"
        color: Qt.rgba(0, 0, 0, 0.55)
        z: 100

        property bool streaming: false
        property string activePath: ""
        property int maxLines: 2000

        // Line bookkeeping for the selectable TextArea backing this view.
        // Using TextArea (instead of a ListView+Text delegate) makes the
        // content natively selectable via mouse / keyboard and gives us
        // horizontal scrolling for free via the wrapping ScrollView.
        // ``lineCount`` is tracked so we can trim the top of the buffer
        // when we exceed ``maxLines`` without scanning the whole string.
        property int lineCount: 0

        function tailAppend(line) {
            if (!line) return;
            if (tailTextArea.length > 0) tailTextArea.append(line);
            else tailTextArea.text = line;
            lineCount += 1;
            while (lineCount > maxLines) {
                var nl = tailTextArea.text.indexOf("\n");
                if (nl < 0) break;
                tailTextArea.remove(0, nl + 1);
                lineCount -= 1;
            }
        }

        function tailClear() {
            tailTextArea.clear();
            lineCount = 0;
        }

        Connections {
            target: hostManager.currentClient
            function onLogTailStarted(row, path) {
                if (row !== root.selectedIndex) return;
                logsOverlay.streaming = true;
                logsOverlay.activePath = path;
                logsOverlay.tailClear();
                logsOverlay.tailAppend("— streaming " + path + " —");
            }
            function onLogTailLine(row, lineNo, text) {
                if (row !== root.selectedIndex) return;
                logsOverlay.tailAppend(lineNo + "  " + text);
            }
            function onLogTailBytes(row, offset, data) {
                if (row !== root.selectedIndex) return;
                var text = data;
                if (typeof data === "object") {
                    try { text = new TextDecoder().decode(data); }
                    catch (e) { text = "" + data; }
                }
                var lines = String(text).split(/\r?\n/);
                for (var i = 0; i < lines.length; ++i) {
                    if (lines[i].length > 0) logsOverlay.tailAppend(lines[i]);
                }
            }
            function onLogTailEnded(row, reason) {
                logsOverlay.streaming = false;
                logsOverlay.tailAppend("— ended: " + reason + " —");
            }
        }

        MouseArea { anchors.fill: parent; hoverEnabled: true }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(1100, parent.width - 60)
            height: Math.min(760, parent.height - 60)
            radius: 12
            color: theme.bgSurface
            border.color: theme.border
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 20
                spacing: 12

                RowLayout {
                    spacing: 12
                    Text {
                        text: "LIVE LOGS"
                        color: theme.textMuted
                        font.pixelSize: 11
                        font.letterSpacing: 2.0
                        font.weight: Font.DemiBold
                    }
                    Text {
                        text: detail.cName
                        color: theme.textPrimary
                        font.pixelSize: 16
                        font.weight: Font.Medium
                    }
                    Rectangle {
                        visible: logsOverlay.streaming
                        implicitWidth: 68; height: 20; radius: 3
                        color: "transparent"
                        border.color: theme.success; border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "● LIVE"
                            color: theme.success
                            font.pixelSize: 10
                            font.letterSpacing: 1.2
                            font.weight: Font.Bold
                        }
                    }
                    Item { Layout.fillWidth: true }
                    ActionButton {
                        label: "CLOSE"
                        accent: theme.textDim
                        enabledReal: true
                        onClicked: { agentClient.stopLogTail(); root.overlay = ""; }
                    }
                }

                RowLayout {
                    spacing: 10
                    TextField {
                        id: pathField
                        Layout.preferredWidth: 260
                        // Pre-fill with the selected component's first log
                        // file; the operator can still override to tail a
                        // secondary log. Refreshed whenever the overlay
                        // becomes visible so stale rows don't persist.
                        text: primaryLogFileFor(root.selectedIndex)
                        placeholderText: "log path (from manifest)"
                        color: theme.textPrimary
                        background: Rectangle {
                            color: theme.bgElevated
                            border.color: theme.border; border.width: 1; radius: 4
                        }
                        Connections {
                            target: root
                            function onOverlayChanged() {
                                if (root.overlay === "logs") {
                                    pathField.text = primaryLogFileFor(root.selectedIndex);
                                }
                            }
                            function onSelectedIndexChanged() {
                                pathField.text = primaryLogFileFor(root.selectedIndex);
                            }
                        }
                    }
                    TextField {
                        id: filterField
                        Layout.fillWidth: true
                        placeholderText: "optional regex filter (server-side, RE2) — empty = raw bytes"
                        color: theme.textPrimary
                        background: Rectangle {
                            color: theme.bgElevated
                            border.color: theme.border; border.width: 1; radius: 4
                        }
                    }
                    ActionButton {
                        // The mini-log keeps a 4 KiB-history tail running in
                        // the background whenever possible, so the overlay
                        // opens with recent data already visible. Clicking
                        // this button requests a bigger (64 KiB) reload —
                        // useful when you want to scroll back through more
                        // context than the mini-log holds.
                        implicitWidth: 150
                        label: "RELOAD"
                        accent: theme.success
                        enabledReal: pathField.text.length > 0
                        onClicked: {
                            agentClient.startLogTail(
                                root.selectedIndex,
                                pathField.text,
                                filterField.text,
                                65536);
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: theme.bgDeep
                    border.color: theme.border
                    border.width: 1
                    radius: 4

                    // Flickable + TextEdit: the classic scrollable log
                    // pattern that works reliably in Qt 6. TextEdit's
                    // implicit size grows with content; Flickable uses
                    // those dimensions as contentWidth/Height so both
                    // axes scroll when lines exceed the viewport.
                    // TextEdit.selectByMouse makes the text selectable.
                    Flickable {
                        id: tailScroll
                        anchors.fill: parent
                        anchors.margins: 8
                        clip: true
                        contentWidth: Math.max(width, tailTextArea.implicitWidth + 12)
                        contentHeight: Math.max(height, tailTextArea.implicitHeight + 12)
                        flickableDirection: Flickable.HorizontalAndVerticalFlick
                        boundsBehavior: Flickable.StopAtBounds

                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                        ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }

                        TextEdit {
                            id: tailTextArea
                            readOnly: true
                            selectByMouse: true
                            selectByKeyboard: true
                            wrapMode: TextEdit.NoWrap
                            textFormat: TextEdit.PlainText
                            color: theme.textPrimary
                            selectedTextColor: theme.textPrimary
                            selectionColor: theme.accentDim
                            font.family: "Consolas"
                            font.pixelSize: 12
                            onTextChanged: Qt.callLater(snapToEnd)
                            function snapToEnd() {
                                tailScroll.contentY = Math.max(
                                    0, tailScroll.contentHeight - tailScroll.height);
                            }
                        }
                    }
                }
            }
        }
    }
}
