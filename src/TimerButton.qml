import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// The shutdown / sleep timer's clock button in the top bar, showing the time left while it runs, and its panel
// (as in the patched FreeTube). The timer itself is SleepTimer, shared by all windows.
ToolButton {
    id: button
    readonly property bool active: SleepTimer.state !== "idle"
    readonly property bool waiting: active && SleepTimer.mode !== "countdown"   // end of video / playlist
    readonly property real timeLeft: SleepTimer.remaining   // ("left" belongs to the button)

    function fmt(ms) {
        const t = Math.ceil(ms / 1000), h = Math.floor(t / 3600), m = Math.floor(t % 3600 / 60), s = t % 60
        return (h ? h + ":" + String(m).padStart(2, "0") : m) + ":" + String(s).padStart(2, "0")
    }
    readonly property string status: !active ? ""
        : waiting ? SleepTimer.verb(SleepTimer.action) + (SleepTimer.mode === "endOfPlaylist" ? " after this playlist" : " after this video")
        : SleepTimer.verb(SleepTimer.action) + " in " + fmt(timeLeft) + (SleepTimer.state === "paused" ? " (paused)" : "")
    readonly property bool urgent: active && !waiting && timeLeft <= 300000     // (the last 5 minutes: amber, then red)
    readonly property color tone: !urgent ? AppState.colors.text : timeLeft <= 60000 ? "#e53935" : AppState.colors.warning

    // Windows' clock icon (Segoe Fluent Icons / MDL2 Assets, U+E823) and, while running, the time left; centred
    // in the button, so the style's round highlight sits around it as around the other buttons
    contentItem: Item {
        implicitWidth: row.implicitWidth
        implicitHeight: row.implicitHeight
        RowLayout {
            id: row
            anchors.centerIn: parent
            spacing: 6
            Label {
                text: ""
                font.family: Qt.fontFamilies().indexOf("Segoe Fluent Icons") >= 0 ? "Segoe Fluent Icons" : "Segoe MDL2 Assets"
                font.pixelSize: 20     // the clock glyph draws a little smaller than back / refresh at the same size
                color: button.tone
                Layout.alignment: Qt.AlignVCenter
            }
            Label {
                visible: button.active
                text: button.waiting ? "end" : button.fmt(button.timeLeft)
                font.pixelSize: 15
                font.bold: button.timeLeft <= 60000 && !button.waiting
                color: button.tone
                Layout.alignment: Qt.AlignVCenter
            }
        }
    }
    onClicked: panel.opened ? panel.close() : panel.open()
    ToolTip.visible: hovered && !panel.opened
    ToolTip.text: active ? status : "Shutdown timer"

    // the choices of the last timer (Data/settings.json)
    property var prefs: Object.assign({ action: "shutdown", mode: "countdown", hours: 0, minutes: 30, graceful: true,
                                        keepAwake: false }, AppState.settings.timerPrefs || {})
    function set(k, v) { const p = Object.assign({}, prefs); p[k] = v; prefs = p }
    property string error: ""

    readonly property var actions: [["shutdown", "Shut down"], ["restart", "Restart"], ["sleep", "Sleep"],
                                    ["hibernate", "Hibernate"], ["signout", "Sign out"], ["lock", "Lock"],
                                    ["pause", "Pause video"], ["close", "Close FTL Player"]]
    readonly property bool canForce: SleepTimer.isPcAction(prefs.action) && prefs.action !== "lock" && prefs.action !== "sleep"

    function startTimer() {
        const minutes = 60 * (+prefs.hours || 0) + (+prefs.minutes || 0)
        if (prefs.mode === "countdown" && minutes <= 0) { error = "Set a time first."; return }
        error = ""
        AppState.setSetting("timerPrefs", prefs)
        SleepTimer.start(prefs.action, prefs.mode, minutes, prefs.graceful, prefs.keepAwake)
    }

    // --- compact controls for the panel
    component SmallRadio: RadioButton {
        font.pixelSize: 13
        topPadding: 2
        bottomPadding: 2
        implicitHeight: 30
    }
    component SmallCheck: CheckBox {
        font.pixelSize: 13
        topPadding: 2
        bottomPadding: 2
        implicitHeight: 30
    }
    // hours / minutes: a small number field (the style's SpinBox was too narrow for its number)
    component NumberField: TextField {
        id: field
        property string key
        property int maxValue
        text: String(button.prefs[key])
        validator: IntValidator { bottom: 0; top: field.maxValue }
        horizontalAlignment: TextInput.AlignHCenter
        inputMethodHints: Qt.ImhDigitsOnly
        selectByMouse: true
        font.pixelSize: 13
        topPadding: 4
        bottomPadding: 4
        implicitHeight: 32
        onTextEdited: { button.set(key, Math.min(maxValue, +text || 0)); button.set("mode", "countdown") }
        Layout.preferredWidth: 52
    }
    // a rounded outlined chip, filled while it is the chosen one
    component ChoiceChip: Button {
        id: chip
        property bool chosen: false
        font.pixelSize: 12
        leftPadding: 12
        rightPadding: 12
        topPadding: 5
        bottomPadding: 5
        topInset: 0             // the style's insets made the outline thinner than the chip
        bottomInset: 0
        implicitHeight: 28
        background: Rectangle {
            radius: height / 2
            color: chip.chosen ? AppState.colors.chipOn : chip.hovered ? AppState.colors.hover : "transparent"
            border.color: chip.chosen ? "#f04242" : AppState.colors.border
            border.width: 1
        }
        contentItem: Label {
            text: chip.text
            font: chip.font
            color: "white"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }
    // a quick time
    component Chip: ChoiceChip {
        property int minutes
        chosen: button.prefs.mode === "countdown" && 60 * button.prefs.hours + button.prefs.minutes === minutes
        onClicked: button.prefs = Object.assign({}, button.prefs, { mode: "countdown",
            hours: Math.floor(minutes / 60), minutes: minutes % 60 })
    }
    component SmallButton: Button {
        font.pixelSize: 13
        topPadding: 6
        bottomPadding: 6
        implicitHeight: 34
        topInset: 0
        bottomInset: 0
    }

    Popup {
        id: panel
        popupType: Popup.Window        // a window of its own: the video's native window can't cover it
        y: button.height
        // centred under the button, but inside the app window: a panel window reaching past its edge onto a
        // screen with another scaling was moved back and forth between the two screens (the app hung)
        onAboutToShow: x = Math.max(8 - button.mapToItem(null, 0, 0).x, button.width / 2 - width / 2)
        width: 320
        padding: 12
        background: Rectangle { color: AppState.colors.popup; radius: 10; border.color: AppState.colors.popupBorder }

        contentItem: ColumnLayout {
            spacing: 4

            Label { text: "Shutdown timer"; font.bold: true; font.pixelSize: 15; Layout.bottomMargin: 2 }

            // --- running
            ColumnLayout {
                visible: button.active
                spacing: 6
                Label { text: button.status; color: button.urgent ? button.tone : AppState.colors.textSoft; font.pixelSize: 13 }
                RowLayout {
                    spacing: 6
                    SmallButton {
                        visible: !button.waiting
                        text: SleepTimer.state === "paused" ? "Resume" : "Pause"
                        onClicked: SleepTimer.state === "paused" ? SleepTimer.resume() : SleepTimer.pause()
                    }
                    SmallButton { visible: !button.waiting; text: "+10 min"; onClicked: SleepTimer.add(10) }
                    SmallButton { visible: !button.waiting; text: "Restart"; onClicked: SleepTimer.restart() }
                }
                SmallButton { text: "Cancel timer"; highlighted: true; onClicked: SleepTimer.cancel() }
            }

            // --- setting up
            ColumnLayout {
                visible: !button.active
                spacing: 2
                Label { text: "When the time is up:"; color: AppState.colors.secondary; font.pixelSize: 12 }
                // A compact drop-down. Its list opens inside the panel's own window (as a separate window it could
                // end up behind the panel); there is room for it below the box.
                ComboBox {
                    id: actionBox
                    model: button.actions.map(a => a[1])
                    currentIndex: Math.max(0, button.actions.findIndex(a => a[0] === button.prefs.action))
                    onActivated: (index) => button.set("action", button.actions[index][0])
                    font.pixelSize: 13
                    implicitHeight: 32
                    topInset: 0
                    bottomInset: 0
                    leftPadding: 10
                    Material.containerStyle: Material.Filled
                    delegate: ItemDelegate {
                        required property int index
                        required property string modelData
                        width: actionBox.width
                        implicitHeight: 28
                        topPadding: 0
                        bottomPadding: 0
                        text: modelData
                        font.pixelSize: 13
                        highlighted: actionBox.highlightedIndex === index
                    }
                    popup.topPadding: 4
                    popup.bottomPadding: 4
                    Layout.fillWidth: true
                    Layout.topMargin: 2
                    Layout.bottomMargin: 4
                }
                RowLayout {
                    spacing: 4
                    SmallRadio {
                        checked: button.prefs.mode === "countdown"
                        onClicked: button.set("mode", "countdown")
                        text: "In"
                    }
                    NumberField { key: "hours"; maxValue: 23 }
                    Label { text: "h"; font.pixelSize: 13 }
                    NumberField { key: "minutes"; maxValue: 59; Layout.leftMargin: 4 }
                    Label { text: "min"; font.pixelSize: 13 }
                    // next to the time: adds 15 minutes to it (the chips below set it)
                    ChoiceChip {
                        Layout.leftMargin: 8
                        text: "+15 min"
                        onClicked: {
                            const total = Math.min(23 * 60 + 59, (button.prefs.mode === "countdown" ? 60 * button.prefs.hours + button.prefs.minutes : 0) + 15)
                            button.prefs = Object.assign({}, button.prefs, { mode: "countdown", hours: Math.floor(total / 60), minutes: total % 60 })
                        }
                    }
                }
                RowLayout {
                    spacing: 6
                    Layout.leftMargin: 32
                    Layout.topMargin: 4
                    Layout.bottomMargin: 4
                    Chip { text: "15 min"; minutes: 15 }
                    Chip { text: "30 min"; minutes: 30 }
                    Chip { text: "1 h"; minutes: 60 }
                    Chip { text: "2 h"; minutes: 120 }
                }
                SmallRadio {
                    text: "At the end of this video"
                    checked: button.prefs.mode === "endOfVideo"
                    onClicked: button.set("mode", "endOfVideo")
                }
                SmallRadio {
                    text: "At the end of this playlist"
                    checked: button.prefs.mode === "endOfPlaylist"
                    onClicked: button.set("mode", "endOfPlaylist")
                }
                SmallCheck {
                    visible: button.canForce
                    text: "Graceful (let other programs close normally)"
                    checked: button.prefs.graceful
                    onToggled: button.set("graceful", checked)
                    ToolTip.visible: hovered
                    ToolTip.text: "Off = other programs are force-closed"
                }
                SmallCheck {
                    text: "Keep the screen awake until then"
                    checked: button.prefs.keepAwake
                    onToggled: button.set("keepAwake", checked)
                }
                Label {
                    visible: button.canForce && !button.prefs.graceful
                    text: "Other programs will be force-closed — unsaved work in them can be lost."
                    color: AppState.colors.warning
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
                Label {
                    visible: SleepTimer.isPcAction(button.prefs.action)
                    text: "You get a 60-second warning with Cancel and Snooze before it happens."
                    color: AppState.colors.tertiary
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
                Label { visible: button.error !== ""; text: button.error; color: "#e53935"; font.pixelSize: 12 }
                SmallButton {
                    text: "Start timer"
                    highlighted: true
                    Layout.topMargin: 6
                    onClicked: { button.startTimer(); panel.close() }
                }
            }
        }
    }
}
