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

    // ---------- Event parser ----------
    // Filters the live log stream down to "major events" per component.
    // Reads the same line stream that drives the mini-log and the LOGS
    // overlay (no new networking). Each component has its own regex
    // table; first match wins. Unmatched lines are dropped.
    //
    // Each rule yields { kind, summary }. ``kind`` indexes into kindMeta
    // for color + display label. ``summary`` is the rendered body —
    // short, structured, not the raw log line.
    QtObject {
        id: eventParser

        // Visual metadata for each event kind. Keep labels ≤ 10 chars so
        // the badge column stays narrow and the summary column gets the
        // remaining width without truncation.
        readonly property var kindMeta: ({
            "signal_swap":     { label: "SIGNAL",   color: theme.accent  },
            "bet_placed":      { label: "BET",      color: theme.accent  },
            "fill":            { label: "FILL",     color: theme.starting },
            "early_exit":      { label: "EXIT",     color: theme.warning },
            "win":             { label: "WIN",      color: theme.success },
            "loss":            { label: "LOSS",     color: theme.danger  },
            "breaker_open":    { label: "BREAKER",  color: theme.danger  },
            "breaker_recover": { label: "BREAKER",  color: theme.success },
            "risk_halt":       { label: "RISK",     color: theme.danger  },
            "bankroll_drift":  { label: "BANKROLL", color: theme.warning },
            "midnight_reset":  { label: "RESET",    color: theme.textMuted },
            "delivered":       { label: "SENT",     color: theme.success },
            "no_signal":       { label: "NO-SEND",  color: theme.warning },
            "engine_run":      { label: "ENGINE",   color: theme.textMuted },
            "cycle":           { label: "CYCLE",    color: theme.textMuted },
            "new_window":      { label: "WINDOW",   color: theme.accent  },
            "tokens":          { label: "TOKENS",   color: theme.starting },
            "promoted":        { label: "RESOLVED", color: theme.success },
            "archived":        { label: "ARCHIVE",  color: theme.textMuted },
        })

        // Per-component rule tables. Each rule: { re, kind, fmt }.
        // ``fmt`` is a function (match-array → summary string).
        // Order matters — earlier rules win.
        readonly property var rules: ({
            "PolyTraderLightning": [
                { re: /SIGNAL_SWAP_ACTIVE:\s*(.+)$/,
                  kind: "signal_swap",
                  fmt: function(m) { return m[1]; } },
                { re: /WINDOW_DECISION\s+\[WIN\]\s+rank=(\d+)\s+side=(\w+)\s+pnl=\$?(-?[\d.]+)\s+entry=([\d.]+)\s+size=\$?([\d.]+)/,
                  kind: "win",
                  fmt: function(m) { return "rank=" + m[1] + " " + m[2] + "  pnl=$" + m[3] + "  entry=" + m[4] + "  size=$" + m[5]; } },
                { re: /WINDOW_DECISION\s+\[LOSS\]\s+rank=(\d+)\s+side=(\w+)\s+pnl=\$?(-?[\d.]+)\s+entry=([\d.]+)\s+size=\$?([\d.]+)/,
                  kind: "loss",
                  fmt: function(m) { return "rank=" + m[1] + " " + m[2] + "  pnl=$" + m[3] + "  entry=" + m[4] + "  size=$" + m[5]; } },
                { re: /(\w+)\s+(maker|taker)\s+order placed:\s*id=(\w+)\s+price=([\d.]+)\s+size=([\d.]+)/,
                  kind: "bet_placed",
                  fmt: function(m) { return m[2].toUpperCase() + "  " + m[1] + "  price=" + m[4] + "  shares=" + m[5] + "  id=" + m[3]; } },
                { re: /LIVE FILL DETECTED:\s*order=(\w+)\s+token=(\w+)\s+price=([\d.]+)\s+size=([\d.]+)\s+usd=\$?([\d.]+)\s+confirmed=(\w+)/,
                  kind: "fill",
                  fmt: function(m) { return "price=" + m[3] + "  size=" + m[4] + "  $" + m[5] + "  confirmed=" + m[6] + "  id=" + m[1]; } },
                { re: /live early-exit resolution:\s*window=(\d+)\s+side=(\w+)\s+sell=([\d.]+)/,
                  kind: "early_exit",
                  fmt: function(m) { return "window=" + m[1] + "  " + m[2] + "  sell=" + m[3]; } },
                { re: /circuit breaker \[([^\]]+)\]:\s*\w+\s*->\s*OPEN\s+after\s+(\d+)\s+failures.*?cooldown=([\d.]+)/,
                  kind: "breaker_open",
                  fmt: function(m) { return m[1] + "  → OPEN  failures=" + m[2] + "  cooldown=" + m[3] + "s"; } },
                { re: /circuit breaker \[([^\]]+)\]:\s*\w+\s*→\s*CLOSED/,
                  kind: "breaker_recover",
                  fmt: function(m) { return m[1] + "  → CLOSED"; } },
                { re: /risk halted:\s*(.+?)\s+—/,
                  kind: "risk_halt",
                  fmt: function(m) { return m[1]; } },
                { re: /BANKROLL_STARTUP_DRIFT\s+(.+)$/,
                  kind: "bankroll_drift",
                  fmt: function(m) { return m[1]; } },
                { re: /midnight UTC\b.*resetting risk counters/,
                  kind: "midnight_reset",
                  fmt: function(m) { return "session summary sent · counters reset"; } },
            ],
            "SignalOrchestrator": [
                { re: /DELIVERING\s+(\w+)\s+signal:\s*(.+)$/,
                  kind: "delivered",
                  fmt: function(m) { return m[1] + "  " + m[2]; } },
                { re: /no signal passed all delivery gates/,
                  kind: "no_signal",
                  fmt: function(m) { return "all candidates rejected — no fire this cycle"; } },
                { re: /engine produced:\s*(\S+)/,
                  kind: "engine_run",
                  fmt: function(m) { return m[1]; } },
                { re: /---\s*cycle start\s*\[([^\]]+)\]\s*---/,
                  kind: "cycle",
                  fmt: function(m) { return "cycle " + m[1]; } },
            ],
            "PolyDataCollector": [
                { re: /New window:\s*(\S+)\s+\(([\d.]+)s remaining\)/,
                  kind: "new_window",
                  fmt: function(m) { return m[1] + "  (" + m[2] + "s remaining)"; } },
                { re: /CLOB subscribed:\s*up=(\w+)\s+down=(\w+)/,
                  kind: "tokens",
                  fmt: function(m) { return "up=" + m[1] + "  down=" + m[2]; } },
                { re: /promoted\s+(\S+)\s+->\s+(\S+)/,
                  kind: "promoted",
                  fmt: function(m) { return m[1] + " → " + m[2]; } },
                { re: /archive: compressing\s+(\d+)\s+files\s*->\s*(\S+)/,
                  kind: "archived",
                  fmt: function(m) { return m[1] + " files → " + m[2]; } },
                { re: /rolling pool: archived\s+(\S+)/,
                  kind: "archived",
                  fmt: function(m) { return m[1]; } },
            ],
        })

        // ``parse`` strips an optional ``lineNo  `` prefix (the live-tail
        // path prepends it; the bulk-reload path does not), then strips
        // the ``YYYY-MM-DD HH:MM:SS.mmm [LEVEL] module:`` header so
        // regexes can anchor on the message body. Returns null on miss.
        function parse(componentName, line) {
            if (!line || !componentName) return null;
            var componentRules = rules[componentName];
            if (!componentRules) return null;
            // Capture the wall-clock time so the row can render it.
            var headerRe = /^(?:\d+\s+)?\d{4}-\d{2}-\d{2}\s+(\d{2}:\d{2}:\d{2})(?:\.\d+)?\s+\[\s*\w+\s*\]\s+[\w.]+:\s*(.*)$/;
            var hm = line.match(headerRe);
            var time = hm ? hm[1] : "";
            var body = hm ? hm[2] : line;
            for (var i = 0; i < componentRules.length; ++i) {
                var rule = componentRules[i];
                var m = body.match(rule.re);
                if (m) {
                    return { kind: rule.kind, time: time, summary: rule.fmt(m) };
                }
            }
            return null;
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
        function onCurrentIndexChanged() {
            root.selectedIndex = 0;
            // Different host = different agent, different files. Drop
            // every buffered line — they belong to the previous host's
            // view of the world. New tails will spin up via tailRetry
            // once the new host's agent is Ready + authenticated.
            dropAllBuffers();
        }
    }
    Timer {
        interval: 1000; running: true; repeat: true
        onTriggered: tickSignal = tickSignal + 1
    }

    // ---- per-component log buffering (parallel tails) ----
    // Architecture: while the agent is connected AND the operator is
    // authenticated, the panel runs ONE log_tail session per component
    // with declared log_files (see ``ensureAllTails``). Each session
    // streams into a per-component buffer kept in
    // ``componentBuffers[row]``. Switching the visible row is a pure
    // view rebind — we copy the cached row's buffer into the
    // mini-log TextEdit and the events ListModel — no network round-
    // trip, no fetch, no clearing. Other components keep accumulating
    // in the background while their row is hidden.
    //
    // Cache lifetime is tied to authenticated agent connection:
    //   * Auth becomes true → start tails for every component with
    //     log_files; allocate buffers.
    //   * Auth or connection lost → stop all tails; drop buffers (the
    //     user said: don't hold a cache for un-authenticated agents).
    //   * Host change → buffers are dropped along with the agent.
    //   * componentList refresh → diff against running tails; start
    //     missing, stop ones whose components vanished.
    //
    // Each buffer:
    //   {
    //     rawLines: array<string>,     // raw log lines, FIFO-capped
    //     compactLines: array<string>, // post-parse "[LEVEL] msg" lines
    //     events: array,               // [{kind, time, summary}, ...]
    //     lastOffset: int,             // for resume on tail death
    //     path: string,                // file being tailed
    //     componentName: string,       // for the event parser dispatch
    //   }
    //
    // Lines are stored as arrays (not as += concatenated strings) so
    // appends are O(1) instead of O(n²) — under a network-stall release
    // burst the old scheme had to rebuild the whole buffer on every
    // single line. Trim is bulk via splice() once the array grows past
    // the soft cap, so the amortized append cost stays O(1). The
    // visible text is materialized lazily in rebindFromBuffer via join().
    property var componentBuffers: ({})
    // Per-row "is a tail session running for this row?" map. Used to
    // make ``ensureAllTails`` idempotent so the periodic
    // ``componentListUpdated`` poll doesn't tear down and re-create
    // every session every few seconds. Cleared on disconnect / auth
    // loss along with the buffers.
    property var componentTailActive: ({})
    readonly property int bufferMaxLines: 5000
    readonly property int bufferMaxEvents: 50
    // Initial history pulled when a tail starts fresh (no resume offset).
    // Capped so a fresh connect over a high-latency link doesn't have to
    // stream the entire current log file in base64 chunks before the UI
    // can show anything. 256 KB is roughly 2-3 thousand lines of typical
    // structured logging — plenty of context for the recent-logs view.
    readonly property int initialTailHistoryBytes: 256 * 1024
    // RELOAD button. The operator clicked it explicitly so they probably
    // want more, but still capped to prevent multi-MB floods on slow links.
    readonly property int reloadTailHistoryBytes: 1024 * 1024

    function primaryLogFileFor(row) {
        if (!componentModel || row < 0) return "";
        var snap = componentModel.snapshotFor(row);
        if (!snap || !snap.logFiles || snap.logFiles.length === 0) return "";
        return snap.logFiles[0];
    }

    function componentNameFor(row) {
        if (!componentModel || row < 0) return "";
        var snap = componentModel.snapshotFor(row);
        return snap ? (snap.name || "") : "";
    }

    // Parse + transform a raw log line the same way the mini-log does
    // for its compact display. Used to build the persistent buffer
    // text so view rebinds match what's seen during live streaming.
    function compactLogLine(line) {
        if (!line) return "";
        var re = /^(?:\d+\s+)?\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)? \[\s*(\w+)\s*\] [\w.]+:\s*(.*)$/;
        var m = line.match(re);
        return m ? ("[" + m[1] + "] " + m[2]) : line;
    }

    function appendToBuffer(row, line) {
        var buf = componentBuffers[row];
        if (!buf) return;
        if (!line) return;
        // Raw + compacted views are kept in lock-step so a row switch
        // can rebind whichever surface needs which view (LOGS overlay
        // wants the raw line with timestamp/module; the mini-log wants
        // the compact ``[LEVEL] msg`` form). Identical lengths after
        // every append/trim keeps the two views in sync.
        buf.rawLines.push(line);
        buf.compactLines.push(compactLogLine(line));
        // Bulk trim once we drift past 1.5x the soft cap — keeps the
        // amortized cost of each push at O(1). Per-append shift() would
        // be O(n) and bring back the freeze under floods.
        var hardCap = Math.floor(bufferMaxLines * 1.5);
        if (buf.rawLines.length > hardCap) {
            var dropN = buf.rawLines.length - bufferMaxLines;
            buf.rawLines.splice(0, dropN);
            buf.compactLines.splice(0, dropN);
        }
        // Try to recognize an event for the component-specific
        // taxonomy (signal swap, bet placed, win/loss, etc.).
        var ev = eventParser.parse(buf.componentName, line);
        if (ev) {
            buf.events.push(ev);
            while (buf.events.length > bufferMaxEvents) buf.events.shift();
        }
    }

    function ensureBuffer(row, path, componentName) {
        if (!componentBuffers[row]) {
            componentBuffers[row] = {
                rawLines: [],
                compactLines: [],
                events: [],
                lastOffset: -1,
                path: path,
                componentName: componentName,
            };
        }
        return componentBuffers[row];
    }

    function dropAllBuffers() {
        componentBuffers = ({});
        componentTailActive = ({});
    }

    // Force the visible widgets to show empty content. Used on auth /
    // connection loss so the operator doesn't keep seeing the
    // previous session's lines while disconnected.
    function blankVisibleWidgets() {
        if (typeof miniLogPane !== "undefined" && miniLogPane.miniLogClear) {
            miniLogPane.miniLogClear();
        }
        if (typeof eventsModel !== "undefined") {
            eventsModel.clear();
        }
        if (typeof logsOverlay !== "undefined" && logsOverlay.tailClear) {
            logsOverlay.tailClear();
            logsOverlay.streaming = false;
        }
    }

    // Start (or resume) tails for every component with declared
    // log_files. Idempotent — only opens a session for rows whose
    // tail isn't already running (tracked in ``componentTailActive``).
    // Skipped entirely when the agent isn't authenticated; the user
    // explicitly does not want caches for un-authenticated components.
    function ensureAllTails() {
        if (!agentClient || agentClient.connectionState !== 3) return;
        if (!agentClient.operatorAuthenticated) return;
        if (!componentModel) return;
        var n = componentModel.rowCount();
        for (var row = 0; row < n; ++row) {
            var path = primaryLogFileFor(row);
            if (!path) continue;
            var componentName = componentNameFor(row);
            var buf = ensureBuffer(row, path, componentName);
            // If the path changed (rare — manifest edit), reset the
            // buffer for that component and force a full re-fetch.
            if (buf.path !== path) {
                buf.rawLines = [];
                buf.compactLines = [];
                buf.events = [];
                buf.lastOffset = -1;
                buf.path = path;
                componentTailActive[row] = false;
            }
            if (componentTailActive[row]) continue;  // session live → skip
            // Resume from where we left off if we have an offset; else
            // request the entire current file.
            var resume = (typeof buf.lastOffset === "number" && buf.lastOffset >= 0)
                         ? buf.lastOffset
                         : -1;
            var historyArg = resume >= 0 ? 0 : initialTailHistoryBytes;
            agentClient.startLogTail(row, path, "", historyArg, resume);
            componentTailActive[row] = true;
        }
    }

    Timer {
        id: tailRetry
        interval: 500
        repeat: false
        onTriggered: ensureAllTails()
    }

    Connections {
        target: agentClient
        function onConnectionStateChanged() {
            // Lost connection → tear down everything. The C++ side
            // already stops its sessions on socket teardown but the
            // panel-side buffers and visible widgets must also drop
            // so we don't render stale content for an un-authenticated
            // agent.
            if (!agentClient || agentClient.connectionState !== 3) {
                dropAllBuffers();
                blankVisibleWidgets();
                return;
            }
            tailRetry.restart();
        }
        function onOperatorAuthenticatedChanged() {
            // Auth lost → drop everything (per operator request:
            // un-authenticated agents do not get a cache).
            if (!agentClient || !agentClient.operatorAuthenticated) {
                if (agentClient) agentClient.stopLogTail();
                dropAllBuffers();
                blankVisibleWidgets();
                return;
            }
            tailRetry.restart();
        }
        function onComponentListUpdated() { tailRetry.restart(); }
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

            // Filtered "major events" stream — populated from the same
            // log-tail signals that drive the mini-log. See eventParser.
            // ``eventsModel`` is the rendering surface for the currently-
            // selected row only; the durable per-component history lives
            // in ``componentBuffers[row].events`` and is rebound here on
            // row switch via ``rebindEventsFromBuffer``.
            ListModel { id: eventsModel }
            readonly property int eventsMax: 50

            function pushEvent(componentName, line) {
                var ev = eventParser.parse(componentName, line);
                if (!ev) return;
                eventsModel.append(ev);
                while (eventsModel.count > detail.eventsMax) {
                    eventsModel.remove(0);
                }
            }

            // Replace ``eventsModel`` contents with the selected row's
            // buffered events. JS-array → ListModel copy is the cheapest
            // path; ``eventsMax`` cap means we're copying ≤ 50 small
            // objects, so this is microseconds even on a slow machine.
            // After the rebind, snap the ListView to the bottom so the
            // most recent events are visible by default. The per-append
            // ``onCountChanged`` handler also fires positionViewAtEnd
            // but the final call there can race ListView layout; an
            // explicit Qt.callLater after the loop is the reliable
            // path for "I just rebuilt the model, show the end".
            function rebindEventsFromBuffer() {
                eventsModel.clear();
                var buf = componentBuffers[root.selectedIndex];
                if (!buf || !buf.events) return;
                for (var i = 0; i < buf.events.length; ++i) {
                    eventsModel.append(buf.events[i]);
                }
                Qt.callLater(function() {
                    if (typeof eventsList !== "undefined") {
                        eventsList.positionViewAtEnd();
                    }
                });
            }

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
                        label: "EVENTS"
                        // Live count of parsed major events in the buffer
                        // (not raw log lines — only what the parser has
                        // recognized as a "major event" per component).
                        value: detail.cStatus === 0 ? "—" : eventsModel.count.toString()
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
                                    text: "EVENTS  ·  live"
                                    color: theme.textMuted
                                    font.pixelSize: 10
                                    font.letterSpacing: 1.6
                                    font.weight: Font.DemiBold
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    text: eventsModel.count + " in buffer"
                                    color: theme.accent
                                    font.pixelSize: 11
                                    font.family: "Consolas"
                                }
                            }

                            // Filtered "major events" timeline. Driven by
                            // the same log stream the mini-log consumes;
                            // ``eventParser`` recognizes a per-component
                            // catalogue of patterns (signal swap, bet
                            // placed, fill, win/loss, breaker open, etc.)
                            // and drops everything else. Each row renders
                            // a colored kind-badge + monospace summary +
                            // wall-clock time so an operator can scan the
                            // session at a glance without parsing raw logs.
                            ListView {
                                id: eventsList
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                model: eventsModel
                                spacing: 4
                                boundsBehavior: Flickable.StopAtBounds
                                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                                // Auto-stick to the bottom whenever a new
                                // event arrives so the latest row is the
                                // one in view, without locking the user
                                // out of scrolling back through history.
                                onCountChanged: Qt.callLater(function() {
                                    eventsList.positionViewAtEnd();
                                })

                                delegate: Rectangle {
                                    width: ListView.view.width
                                    height: 26
                                    radius: 4
                                    color: index % 2 === 0
                                           ? theme.bgElevated
                                           : Qt.rgba(0, 0, 0, 0)

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 8
                                        anchors.rightMargin: 8
                                        spacing: 10

                                        // Kind badge: colored pill with a
                                        // short uppercase label. Width is
                                        // fixed so summaries align across
                                        // rows even as kinds vary.
                                        Rectangle {
                                            implicitWidth: 78; implicitHeight: 18
                                            radius: 3
                                            color: "transparent"
                                            border.width: 1
                                            border.color: (eventParser.kindMeta[model.kind]
                                                           ? eventParser.kindMeta[model.kind].color
                                                           : theme.textDim)
                                            Text {
                                                anchors.centerIn: parent
                                                text: (eventParser.kindMeta[model.kind]
                                                       ? eventParser.kindMeta[model.kind].label
                                                       : model.kind.toUpperCase())
                                                color: (eventParser.kindMeta[model.kind]
                                                        ? eventParser.kindMeta[model.kind].color
                                                        : theme.textDim)
                                                font.pixelSize: 9
                                                font.letterSpacing: 1.0
                                                font.weight: Font.Bold
                                            }
                                        }

                                        // Selectable summary. TextEdit
                                        // (read-only) gives the operator
                                        // mouse + keyboard selection and
                                        // copy without changing how the
                                        // row looks. ``elide`` isn't
                                        // available on TextEdit, so the
                                        // surrounding RowLayout's
                                        // ``Layout.fillWidth`` plus the
                                        // delegate's clipping ListView
                                        // do the truncation visually;
                                        // the full text is still
                                        // selectable via drag.
                                        TextEdit {
                                            Layout.fillWidth: true
                                            text: model.summary
                                            color: theme.textPrimary
                                            selectedTextColor: theme.textPrimary
                                            selectionColor: theme.accentDim
                                            font.family: "Consolas"
                                            font.pixelSize: 12
                                            readOnly: true
                                            selectByMouse: true
                                            selectByKeyboard: true
                                            wrapMode: TextEdit.NoWrap
                                            // ``activeFocusOnPress`` so
                                            // a click drags-selects
                                            // instead of being eaten by
                                            // the ListView's flick
                                            // handler.
                                            activeFocusOnPress: true
                                        }

                                        TextEdit {
                                            text: model.time
                                            color: theme.textDim
                                            selectedTextColor: theme.textPrimary
                                            selectionColor: theme.accentDim
                                            font.family: "Consolas"
                                            font.pixelSize: 10
                                            readOnly: true
                                            selectByMouse: true
                                            selectByKeyboard: true
                                            activeFocusOnPress: true
                                        }
                                    }
                                }

                                // Empty-state placeholder. Visible until
                                // the first event lands; helps operators
                                // tell "no events yet" from "panel broken".
                                Text {
                                    anchors.centerIn: parent
                                    visible: eventsModel.count === 0
                                    text: detail.cStatus === 0
                                          ? "component stopped — no events"
                                          : "waiting for events…"
                                    color: theme.textDim
                                    font.pixelSize: 11
                                    font.italic: true
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
                        // Backed by a TextEdit so operators can highlight
                        // and copy text; wrapped in a Flickable so long
                        // lines can be scrolled sideways. The TextEdit
                        // is just a rendering surface — durable state
                        // lives in ``componentBuffers[row]`` and is
                        // rebound here on row switch. Cap matches
                        // ``bufferMaxLines`` so trim semantics are
                        // consistent between buffer and view.
                        property int miniMaxLines: bufferMaxLines
                        property int miniLineCount: 0

                        // Coalesces N append() calls within one frame into
                        // a single rebind from componentBuffers[row].compactLines.
                        // The previous approach did textArea.append() and
                        // textArea.remove(0, nl+1) per line, which under a
                        // burst of buffered tail frames was O(n²) on the
                        // GUI thread — the freeze the operator was seeing.
                        // Now: per-line work is O(1) (push to JS array in
                        // appendToBuffer), and the TextEdit is rebuilt at
                        // most once per ~16ms (one display frame).
                        Timer {
                            id: miniRebindTimer
                            interval: 16
                            repeat: false
                            onTriggered: miniLogPane.rebindFromBuffer()
                        }

                        function miniAppend(line) {
                            // The buffer was already updated by
                            // appendToBuffer() before this was called;
                            // we just need to schedule a rebind. Restart
                            // semantics give us debounced behavior — a
                            // 1000-line burst becomes one rebind.
                            miniRebindTimer.restart();
                        }

                        function miniLogClear() {
                            miniTextArea.clear();
                            miniLineCount = 0;
                        }

                        // Replace the visible TextEdit content with the
                        // currently-selected component's buffered text.
                        // Cheap (one assignment) and renders instantly;
                        // this is what makes row switching feel
                        // immediate instead of "wait for tail to start".
                        //
                        // The cursorPosition assignment is a Qt 6
                        // workaround: when ``text`` is set
                        // programmatically, the TextEdit sometimes
                        // doesn't lay out / paint until the widget is
                        // interacted with — symptom is a blank view
                        // that "fills in" only when the operator
                        // clicks it. Setting cursorPosition triggers
                        // ensureVisible which forces a layout pass and
                        // a paint request synchronously, so the
                        // content appears immediately on row switch.
                        function rebindFromBuffer() {
                            var buf = componentBuffers[root.selectedIndex];
                            var lines = (buf && Array.isArray(buf.compactLines))
                                        ? buf.compactLines
                                        : [];
                            // Single join() is O(n) once, vs. the per-line
                            // append+trim path which was O(n²) over a flood.
                            miniTextArea.text = lines.join("\n");
                            miniLineCount = lines.length;
                            miniTextArea.cursorPosition = miniTextArea.length;
                            // Snap to bottom on rebind so the operator
                            // sees the most recent lines first.
                            Qt.callLater(function() {
                                miniScroll.contentY = Math.max(
                                    0,
                                    miniScroll.contentHeight - miniScroll.height);
                            });
                        }

                        // Row change: rebind the visible widgets to the
                        // newly-selected row's buffer. No tails are
                        // stopped, no fetch happens — every component
                        // with declared log_files already has a tail
                        // running and accumulating into its buffer.
                        // This is what makes switching feel instant.
                        Connections {
                            target: root
                            function onSelectedIndexChanged() {
                                miniLogPane.rebindFromBuffer();
                                detail.rebindEventsFromBuffer();
                                logsOverlay.rebindFromBuffer();
                                if (root.overlay === "logs") root.overlay = "";
                            }
                        }

                        // Live-stream subscriber. Signals carry ``row``
                        // so we always route a chunk to the buffer for
                        // the component that wrote it — even when the
                        // operator is currently looking at a different
                        // row. The visible widgets only mirror the
                        // selected row to keep rendering cheap.
                        Connections {
                            target: hostManager.currentClient
                            function onLogTailStarted(row, path) {
                                // Tail (re)started for this row. If we
                                // were resuming, the buffer should keep
                                // its content; if this is a fresh fetch
                                // (e.g. RELOAD), the operator-initiated
                                // restart already cleared things via
                                // ``stopLogTailForRow``. Don't clear
                                // here — that would erase content right
                                // before the agent re-streams it.
                            }
                            function onLogTailLine(row, lineNo, text) {
                                appendToBuffer(row, text);
                                if (row === root.selectedIndex) {
                                    miniLogPane.miniAppend(text);
                                    detail.pushEvent(detail.cName, text);
                                }
                            }
                            function onLogTailBytes(row, offset, data) {
                                // Decode + book-keep the byte chunk
                                // before fanning out. ``byteLength`` is
                                // the right unit for ``lastOffset``
                                // (matches the agent's notion of file
                                // position) even when the rendered
                                // string length differs.
                                var s = data;
                                var byteLen = 0;
                                if (typeof data === "object") {
                                    if (typeof data.byteLength === "number") {
                                        byteLen = data.byteLength;
                                    }
                                    try { s = new TextDecoder().decode(data); }
                                    catch (e) { s = "" + data; }
                                }
                                if (byteLen === 0 && typeof s === "string") {
                                    byteLen = s.length;
                                }
                                var buf = componentBuffers[row];
                                if (buf) {
                                    var next = offset + byteLen;
                                    if (typeof buf.lastOffset !== "number"
                                        || next > buf.lastOffset) {
                                        buf.lastOffset = next;
                                    }
                                }
                                var lines = String(s).split(/\r?\n/);
                                var isSelected = (row === root.selectedIndex);
                                for (var i = 0; i < lines.length; ++i) {
                                    if (lines[i].length === 0) continue;
                                    appendToBuffer(row, lines[i]);
                                    if (isSelected) {
                                        miniLogPane.miniAppend(lines[i]);
                                        detail.pushEvent(detail.cName, lines[i]);
                                    }
                                }
                            }
                            function onLogTailEnded(row, reason) {
                                // The session for this row died (network
                                // hiccup, file rotated, agent restart).
                                // Mark the row as needing a new tail and
                                // schedule a retry — ``ensureAllTails``
                                // sees ``componentTailActive[row]`` is
                                // false and resumes from ``buf.lastOffset``,
                                // so the user doesn't see content gaps
                                // when the new tail catches up.
                                componentTailActive[row] = false;
                                tailRetry.restart();
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
                                    font.pixelSize: 12
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

        // Coalescing rebind, same rationale as miniRebindTimer above.
        // The visible overlay is rebuilt from componentBuffers[row].rawLines
        // at most once per frame; the per-line work upstream stays O(1).
        Timer {
            id: tailRebindTimer
            interval: 16
            repeat: false
            onTriggered: logsOverlay.rebindFromBuffer()
        }

        function tailAppend(line) {
            // The buffer is updated upstream in appendToBuffer(); this
            // just schedules a debounced rebind.
            tailRebindTimer.restart();
        }

        function tailClear() {
            tailTextArea.clear();
            lineCount = 0;
        }

        // Repopulate the overlay's TextEdit from the selected row's
        // RAW buffer (full timestamps + module names — the overlay is
        // the "give me everything" view, distinct from the mini-log's
        // compacted form). Snaps to the bottom on rebind. See the
        // mini-log's ``rebindFromBuffer`` for the cursorPosition
        // workaround that prevents the "blank until clicked" Qt 6
        // TextEdit paint stall.
        function rebindFromBuffer() {
            var buf = componentBuffers[root.selectedIndex];
            var lines = (buf && Array.isArray(buf.rawLines)) ? buf.rawLines : [];
            tailTextArea.text = lines.join("\n");
            lineCount = lines.length;
            tailTextArea.cursorPosition = tailTextArea.length;
            logsOverlay.streaming = !!agentClient
                                    && agentClient.connectionState === 3
                                    && agentClient.operatorAuthenticated;
            logsOverlay.activePath = buf ? (buf.path || "") : "";
            Qt.callLater(function() {
                tailScroll.contentY = Math.max(
                    0, tailScroll.contentHeight - tailScroll.height);
            });
        }

        // Live mirror: when a tail event lands for the row the operator
        // is currently viewing, append to the overlay's TextEdit too so
        // the displayed view stays in sync with the buffer. Rows the
        // operator isn't viewing don't render here — the buffer alone
        // captures them, ready for an instant rebind on row switch.
        Connections {
            target: hostManager.currentClient
            function onLogTailStarted(row, path) {
                if (row !== root.selectedIndex) return;
                logsOverlay.streaming = true;
                logsOverlay.activePath = path;
            }
            // The buffer is updated by the upstream Connections block
            // (under miniLogPane) before these handlers fire — the
            // ordering is FIFO by declaration. We only need to schedule
            // a debounced rebind from the now-updated buffer; no need
            // to re-decode bytes or split lines a second time.
            function onLogTailLine(row, lineNo, text) {
                if (row !== root.selectedIndex) return;
                tailRebindTimer.restart();
            }
            function onLogTailBytes(row, offset, data) {
                if (row !== root.selectedIndex) return;
                tailRebindTimer.restart();
            }
            function onLogTailEnded(row, reason) {
                if (row !== root.selectedIndex) return;
                logsOverlay.streaming = false;
            }
        }

        // When the overlay is opened, sync its TextEdit with whatever
        // is already in the buffer for the current row instead of
        // showing an empty view until the next live line arrives.
        Connections {
            target: root
            function onOverlayChanged() {
                if (root.overlay === "logs") {
                    logsOverlay.rebindFromBuffer();
                }
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
                        // Closing the overlay no longer stops the
                        // background tail — the per-component tails
                        // are persistent so the mini-log keeps showing
                        // live data. The overlay is just a different
                        // view onto the same buffer.
                        onClicked: { root.overlay = ""; }
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
                        // RELOAD wipes the buffer for the current row
                        // and restarts its tail with a full-file fetch,
                        // applying whatever regex filter the operator
                        // typed. Other rows' tails and buffers are
                        // untouched (per-row session model). The
                        // overlay rebinds to the cleared buffer first
                        // so the user immediately sees the wipe rather
                        // than stale content during the round-trip.
                        implicitWidth: 150
                        label: "RELOAD"
                        accent: theme.success
                        enabledReal: pathField.text.length > 0
                        onClicked: {
                            var row = root.selectedIndex;
                            var buf = componentBuffers[row];
                            if (buf) {
                                buf.rawLines = [];
                                buf.compactLines = [];
                                buf.events = [];
                                buf.lastOffset = -1;
                            }
                            logsOverlay.rebindFromBuffer();
                            miniLogPane.rebindFromBuffer();
                            detail.rebindEventsFromBuffer();
                            agentClient.startLogTail(
                                row,
                                pathField.text,
                                filterField.text,
                                reloadTailHistoryBytes,
                                -1);
                            // Eagerly mark active so a concurrent
                            // ``ensureAllTails`` (e.g. from a periodic
                            // componentList poll) doesn't race us by
                            // starting yet another session for the
                            // same row.
                            componentTailActive[row] = true;
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
