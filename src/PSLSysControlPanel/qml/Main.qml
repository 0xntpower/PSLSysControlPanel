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
    Timer {
        interval: 1000; running: true; repeat: true
        onTriggered: tickSignal = tickSignal + 1
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
                    text: "v0.1.0 · mockup build"
                    color: theme.textDim
                    font.pixelSize: 10
                    font.letterSpacing: 0.8
                }
            }
            Item { Layout.fillWidth: true }

            HeaderBadge { label: "MESH";     value: "tailscale"; dotColor: theme.success }
            HeaderBadge { label: "IPC";      value: "connected"; dotColor: theme.success }
            HeaderBadge { label: "OPERATOR"; value: "authenticated"; dotColor: theme.accent }
            HeaderBadge { label: "CLOCK";    value: Qt.formatDateTime(new Date(), "hh:mm:ss"); dotColor: theme.textMuted; updatesEach: true }
        }
    }

    // ---------- Body: Sidebar + Detail ----------
    Rectangle {
        id: body
        anchors.top: headerBar.bottom
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
            readonly property int    cQueue:      snap.queueDepth ?? 0

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
                        enabledReal: detail.cStatus === 0 || detail.cStatus === 4
                        onClicked: componentModel.startComponent(root.selectedIndex)
                    }
                    ActionButton {
                        label: "STOP"
                        accent: theme.danger
                        enabledReal: detail.cStatus === 2 || detail.cStatus === 3 || detail.cStatus === 1
                        onClicked: componentModel.stopComponent(root.selectedIndex)
                    }
                    ActionButton {
                        label: "RESTART"
                        accent: theme.accent
                        enabledReal: detail.cStatus !== 0
                        onClicked: componentModel.restartComponent(root.selectedIndex)
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

                    // Logs panel
                    Rectangle {
                        Layout.preferredWidth: 420
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
                                    text: "RECENT LOGS"
                                    color: theme.textMuted
                                    font.pixelSize: 10
                                    font.letterSpacing: 1.6
                                    font.weight: Font.DemiBold
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    text: "tail · live"
                                    color: theme.textDim
                                    font.pixelSize: 10
                                }
                            }

                            ListView {
                                id: logList
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                model: []
                                boundsBehavior: Flickable.StopAtBounds
                                spacing: 2
                                verticalLayoutDirection: ListView.TopToBottom

                                Connections {
                                    target: root
                                    function onTickSignal() {
                                        logList.model = componentModel.logsFor(root.selectedIndex);
                                        logList.positionViewAtEnd();
                                    }
                                    function onSelectedIndexChanged() {
                                        logList.model = componentModel.logsFor(root.selectedIndex);
                                        logList.positionViewAtEnd();
                                    }
                                }
                                Component.onCompleted: model = componentModel.logsFor(root.selectedIndex)

                                delegate: Text {
                                    required property string modelData
                                    width: logList.width
                                    text: modelData
                                    color: modelData.indexOf("WARN") >= 0 ? theme.warning
                                         : modelData.indexOf("ERROR") >= 0 ? theme.danger
                                         : theme.textMuted
                                    font.pixelSize: 11
                                    font.family: "Consolas"
                                    wrapMode: Text.NoWrap
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }
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
                text: "MOCKUP · fake data"
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
}
