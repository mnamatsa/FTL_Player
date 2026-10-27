import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// Basic settings, saved to Data/settings.json as they change.
Item {
    id: page
    signal importRequested()
    signal exportRequested()
    property string dataMessage: ""     // result of the last import/export, set by Main

    component Section: ColumnLayout {
        property alias title: heading.text
        default property alias content: rows.data
        spacing: 4
        Layout.fillWidth: true
        Layout.topMargin: 16
        Label { id: heading; font.pixelSize: 17; font.bold: true; color: "#f04242" }
        ColumnLayout { id: rows; spacing: 2; Layout.fillWidth: true }
    }
    component Row: RowLayout {
        property alias label: labelText.text
        property alias hint: hintText.text
        spacing: 16
        Layout.fillWidth: true
        Layout.minimumHeight: 48
        ColumnLayout {
            spacing: 0
            Layout.fillWidth: true
            Label { id: labelText; font.pixelSize: 14; Layout.fillWidth: true }  // keeps controls right-aligned
            Label {
                id: hintText
                color: AppState.colors.muted
                font.pixelSize: 12
                visible: hintText.text !== ""
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }
    }
    // ComboBox whose entries are [label, value] pairs bound to one setting.
    component SettingCombo: ComboBox {
        property string setting
        property var options: []        // [[label, value], ...]
        model: options.map(o => o[0])
        currentIndex: Math.max(0, options.findIndex(o => o[1] === AppState.settings[setting]))
        onActivated: (index) => AppState.setSetting(setting, options[index][1])
        implicitContentWidthPolicy: ComboBox.WidestText
        Layout.preferredWidth: 240
    }
    // A hotkey: shows its key; click it, then press the new key (Esc cancels, Backspace clears).
    // A key taken from another action leaves that one unbound.
    component HotkeyButton: Button {
        id: hk
        property string hotkeyAction        // ("action" belongs to Button)
        property bool listening: false
        readonly property string key: AppState.hotkeys[hotkeyAction] || ""
        function label(k) {
            const names = { LEFT: "\u2190", RIGHT: "\u2192", UP: "\u2191", DOWN: "\u2193", SPACE: "Space", ENTER: "Enter",
                            BS: "Backspace", PGUP: "Page Up", PGDWN: "Page Down", DEL: "Delete", INS: "Insert",
                            HOME: "Home", END: "End", TAB: "Tab", SHARP: "#", ",": ", (<)", ".": ". (>)" }
            // a capital letter is Shift + that letter (mpv tells them apart); the "+" key itself stays whole
            return k.split(/\+(?=.)/).map(p => names[p] || (p.length === 1 && p !== p.toLowerCase() ? "Shift + " + p
                                                            : p.length === 1 ? p.toUpperCase() : p)).join(" + ")
        }
        text: listening ? "Press a key\u2026" : key ? label(key) : "\u2014"
        implicitWidth: 150
        implicitHeight: 38
        font.pixelSize: 14
        // looks like a key cap
        background: Rectangle {
            radius: 7
            color: hk.listening ? AppState.colors.listening : hk.hovered ? AppState.colors.hover : AppState.colors.placeholder
            border.color: hk.listening ? "#f04242" : AppState.colors.border
            border.width: 1
        }
        onClicked: { listening = true; forceActiveFocus() }
        onActiveFocusChanged: if (!activeFocus) listening = false
        Keys.onPressed: (event) => {
            if (!listening) return
            event.accepted = true
            if (event.key === Qt.Key_Escape) { listening = false; return }
            const keys = Object.assign({}, AppState.hotkeys)
            if (event.key === Qt.Key_Backspace) keys[hotkeyAction] = ""
            else {
                const name = KeyNames.name(event.key, event.modifiers, event.text)
                if (!name) return                              // a modifier on its own: wait for the key
                for (const a in keys) if (keys[a] === name) keys[a] = ""
                keys[hotkeyAction] = name
            }
            AppState.setSetting("hotkeys", keys)
            listening = false
        }
    }
    // A slider bound to one setting, its value shown to its left (valueText formats it). The slider is as wide
    // as the menus, so both line up.
    component SettingSlider: RowLayout {
        id: ss
        property string setting
        property alias from: slider.from
        property alias to: slider.to
        property alias stepSize: slider.stepSize
        property var valueText: (v) => String(v)
        spacing: 8
        Label {
            text: ss.valueText(Math.round(Math.round(slider.value / slider.stepSize) * slider.stepSize * 100) / 100)
            horizontalAlignment: Text.AlignRight
            Layout.preferredWidth: 120
        }
        Slider {
            id: slider
            snapMode: Slider.SnapAlways
            value: AppState.settings[ss.setting]
            // the value as a whole number of steps (no 2.7500000001)
            onMoved: AppState.setSetting(ss.setting, Math.round(Math.round(value / stepSize) * stepSize * 100) / 100)
            leftPadding: 0      // the track starts at the slider's edge, like a menu's box
            rightPadding: 0
            Layout.preferredWidth: 240
        }
    }
    component SettingSwitch: Switch {
        property string setting
        checked: !!AppState.settings[setting]
        onToggled: AppState.setSetting(setting, checked)
    }

    ScrollView {
        id: settingsScroll
        anchors.fill: parent
        contentWidth: availableWidth
        // (on the content: it gets the wheel before the ScrollView's Flickable)
        SmoothScroll { flickable: settingsScroll.contentItem }

        ColumnLayout {
            width: Math.min(parent.width - 48, 820)
            x: 24
            spacing: 0

            Section {
                title: "Layout"
                Row {
                    label: "Theme"
                    hint: "Dark or light pages (and title bars, and the icon: a black laser on dark, a white one on light). System follows Windows (Settings > Personalization > Colors)."
                    SettingCombo {
                        setting: "theme"
                        options: [["Dark", "dark"], ["Light", "light"], ["System", "system"]]
                    }
                }
                Row {
                    label: "Video grid size"
                    hint: "Size of the video and playlist cards. Ctrl + mouse wheel over a grid changes it too."
                    SettingCombo {
                        setting: "gridScale"
                        options: AppState.gridScales.map(v => [v === 1 ? "Normal (100%)" : Math.round(v * 100) + "%", v])
                    }
                }
                Row {
                    label: "Scroll speed"
                    hint: "How far one turn of the mouse wheel scrolls pages and lists."
                    SettingSlider {
                        setting: "scrollSpeed"
                        from: 0.25; to: 4; stepSize: 0.25
                        valueText: (v) => v === 1 ? "Normal (1×)" : v + "×"
                    }
                }
                Row {
                    label: "Preview on video cards"
                    hint: "Moving the pointer along the bar at the bottom of a thumbnail shows the video at that point."
                    SettingSwitch { setting: "cardPreview" }
                }
            }

            Section {
                title: "Windows"
                Row {
                    label: "Open new windows in the background"
                    hint: "\"Open in new window\" (or middle click) opens it behind this one and flashes its taskbar button."
                    SettingSwitch { setting: "openInBackground" }
                }
                Row {
                    label: "Open maximized"
                    hint: "The app, and new windows, open filling the screen (windows opened in the background keep their place)."
                    SettingSwitch { setting: "startMaximized" }
                }
                Row {
                    label: "Open links from other apps in a new window"
                    hint: "\"Open in FTL Player\" in the browser opens a new window, instead of replacing what this one shows."
                    SettingSwitch { setting: "externalNewWindow" }
                }
                Row {
                    label: "Open links from other apps in the background"
                    hint: "The browser stays in front; the window opening the link (a new one, or this one) flashes its taskbar button."
                    SettingSwitch { setting: "externalBackground" }
                }
                Row {
                    label: "Open videos in background windows unloaded"
                    hint: "A video opened in a window behind the others (\"Open new windows in the background\", links from other apps) shows its details and thumbnail, and loads its player when you go to that window."
                    SettingSwitch { setting: "openUnloaded" }
                }
                Row {
                    label: "Unload background videos"
                    hint: "Each loaded video takes about 300 to 400 MB. Unloaded ones show their thumbnail and go on where they were when you go back to their window."
                    SettingCombo {
                        setting: "unloadMode"
                        options: [["By number kept loaded", "count"], ["When paused for a while", "time"]]
                    }
                }
                Row {
                    label: "Videos kept loaded"
                    hint: "The last used ones across all windows stay loaded, also when paused. One beyond them unloads when it is paused in the background (a playing one keeps going)."
                    enabled: AppState.settings.unloadMode !== "time"
                    opacity: enabled ? 1 : 0.45
                    SettingCombo {
                        setting: "loadedPlayers"
                        options: [["1", 1], ["2", 2], ["3", 3], ["4", 4], ["5", 5], ["Unlimited", 0]]
                    }
                }
                Row {
                    label: "Unload paused videos after"
                    hint: "A video paused this long with its window in the background unloads, however many are loaded."
                    enabled: AppState.settings.unloadMode === "time"
                    opacity: enabled ? 1 : 0.45
                    SettingCombo {
                        setting: "unloadPausedAfter"
                        options: [["1 minute", 1], ["3 minutes", 3], ["5 minutes", 5], ["10 minutes", 10], ["30 minutes", 30]]
                    }
                }
            }

            Section {
                title: "Player"
                Row {
                    label: "Default quality"
                    hint: "Auto uses the resolution of the screen the window is on."
                    SettingCombo {
                        setting: "quality"
                        options: [["Auto", 0], ["2160p (4K)", 2160], ["1440p", 1440], ["1080p", 1080], ["720p", 720], ["480p", 480], ["360p", 360]]
                    }
                }
                Row {
                    label: "Start playing automatically"
                    hint: "When off, videos open paused at the first frame (or where you left off)."
                    SettingSwitch { setting: "autoplay" }
                }
                Row {
                    label: "Show captions"
                    hint: "Turns on the first track in the language below, when the video has one."
                    SettingSwitch { setting: "captions" }
                }
                Row {
                    label: "Caption language"
                    SettingCombo {
                        setting: "captionLanguage"
                        options: [["English", "en"], ["Russian", "ru"], ["Ukrainian", "uk"], ["German", "de"], ["French", "fr"],
                                  ["Spanish", "es"], ["Portuguese", "pt"], ["Italian", "it"], ["Polish", "pl"], ["Japanese", "ja"],
                                  ["Korean", "ko"], ["Chinese", "zh"]]
                    }
                }
                Row {
                    label: "Default playback speed"
                    hint: "Every video starts at this speed."
                    SettingSlider {
                        setting: "speed"
                        from: 0.25; to: 3; stepSize: 0.05
                        valueText: (v) => v === 1 ? "Normal (1×)" : v + "×"
                    }
                }
                Row {
                    label: "Speed step for the slower / faster keys"
                    hint: "See Hotkeys below ( [ and ] work too)."
                    SettingCombo {
                        setting: "speedStep"
                        options: [["0.05×", 0.05], ["0.1×", 0.1], ["0.25×", 0.25], ["0.5×", 0.5]]
                    }
                }
                Row {
                    label: "Show seek bar preview"
                    hint: "A picture of that moment while pointing at the seek bar. Off: only the time (and the chapter) show."
                    SettingSwitch { setting: "preview" }
                }
                Row {
                    label: "Seek bar preview size"
                    hint: "The picture shown while pointing at the seek bar."
                    enabled: AppState.settings.preview !== false
                    SettingSlider {
                        setting: "previewScale"
                        from: 0.5; to: 3; stepSize: 0.25
                        valueText: (v) => v === 1 ? "Normal (100%)" : Math.round(v * 100) + "%"
                    }
                }
                Row {
                    label: "Mouse wheel over the video"
                    hint: "Where it doesn't change the volume, it scrolls the page. The same goes for the parts of "
                          + "the control bar without a wheel action of their own; the volume button always changes the volume."
                    SettingCombo {
                        setting: "wheelVolume"
                        options: [["Changes the volume", 2], ["Volume in fullscreen only", 1], ["Never changes the volume", 0]]
                    }
                }
                Row {
                    label: "Mouse wheel over the seek bar"
                    hint: "Seeks 10 s per notch. Where it doesn't seek, it scrolls the page."
                    SettingCombo {
                        setting: "wheelSeek"
                        options: [["Seeks", 2], ["Seeks in fullscreen only", 1], ["Never seeks", 0]]
                    }
                }
                Row {
                    label: "Mouse wheel over the speed button"
                    hint: "Changes the speed by the speed step per notch. Where it doesn't, it scrolls the page."
                    SettingCombo {
                        setting: "wheelSpeed"
                        options: [["Changes the speed", 2], ["Speed in fullscreen only", 1], ["Never changes the speed", 0]]
                    }
                }
                Row {
                    label: "Video codec"
                    hint: "Automatic picks the highest resolution and frame rate first. A preferred codec is used "
                          + "whenever the video has it, even at a lower resolution. From the next video."
                    SettingCombo {
                        setting: "codec"
                        options: [["Automatic", "auto"], ["Prefer VP9", "vp9"], ["Prefer H.264", "h264"], ["Prefer AV1", "av1"]]
                    }
                }
                Row {
                    readonly property string integrated: GpuInfo.name("integrated")
                    readonly property string dedicated: GpuInfo.name("dedicated")
                    // only with a choice: a PC with one GPU gets the same one for both
                    visible: integrated !== "" && dedicated !== "" && integrated !== dedicated
                    label: "Graphics card"
                    hint: "Integrated: " + integrated + " (decodes " + (GpuInfo.decodes("integrated") || "none") + "). "
                          + "Dedicated: " + dedicated + " (decodes " + (GpuInfo.decodes("dedicated") || "none") + "). "
                          + "The video uses it from the next video, the rest of the app after a restart."
                    SettingCombo {
                        setting: "gpu"
                        options: [["Automatic", "auto"], ["Integrated", "integrated"], ["Dedicated", "dedicated"]]
                        ToolTip.visible: hovered && !popup.visible
                        ToolTip.delay: 400
                        ToolTip.text: "Automatic: videos play on the GPU Windows gives apps by default"
                                      + (GpuInfo.name("auto") ? " (on this PC: " + GpuInfo.name("auto") + ")" : "")
                                      + ", unless it can't decode the video's codec in hardware and the other GPU can "
                                      + "(for example AV1): then on that one. The rest of the app stays on the default GPU.
"
                                      + "Windows' Settings > System > Display > Graphics can change the default."
                    }
                }
                Row {
                    label: "Show chapters"
                    hint: "Chapter gaps in the seek bar, the chapter name while pointing at it, and the chapter list under the description."
                    SettingSwitch { setting: "chapters" }
                }
                Row {
                    label: "Hardware decoding"
                    hint: "Decodes video on the graphics chip. Applies from the next video."
                    SettingSwitch { setting: "hardwareDecoding" }
                }
            }

            Section {
                title: "SponsorBlock"
                Row {
                    label: "Use SponsorBlock"
                    hint: "Segments marked by the community (sponsor.ajay.app), shown in their colour on the seek bar. "
                          + "Only the first characters of a hash of the video ID are sent, so the server doesn't learn what you watch."
                    SettingSwitch { setting: "sponsorBlock" }
                }
                Repeater {
                    model: AppState.sponsorCategories
                    delegate: Row {
                        required property var modelData
                        label: modelData.name
                        enabled: !!AppState.settings.sponsorBlock
                        Rectangle { width: 14; height: 14; radius: 3; color: "#" + modelData.color }
                        SettingCombo {
                            setting: "sb_" + modelData.id
                            options: modelData.skippable
                                ? [["Skip automatically", "skip"], ["Show in seek bar", "show"], ["Off", "off"]]
                                : [["Show", "show"], ["Off", "off"]]
                        }
                    }
                }
            }

            Section {
                title: "Hotkeys"
                Label {
                    text: "Click a key, then press the new one (Esc cancels, Backspace clears). They work while the video has the keyboard (click it first)."
                    color: AppState.colors.muted
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                    Layout.bottomMargin: 4
                }
                Row { label: "Slower"; HotkeyButton { hotkeyAction: "speedDown" } }
                Row { label: "Faster"; HotkeyButton { hotkeyAction: "speedUp" } }
                Row {
                    label: "Jump back / forward " + (AppState.settings.seekStep || 5) + " s"
                    HotkeyButton { hotkeyAction: "seekBack" }
                    HotkeyButton { hotkeyAction: "seekForward" }
                }
                Row {
                    readonly property real longJump: Math.round((AppState.settings.seekStep || 5) * (AppState.settings.jumpMultiplier || 2) * 100) / 100
                    label: "Jump back / forward " + longJump + " s"
                    HotkeyButton { hotkeyAction: "jumpBack" }
                    HotkeyButton { hotkeyAction: "jumpForward" }
                }
                Row {
                    label: "One frame back / forward"
                    hint: "Pauses the video."
                    HotkeyButton { hotkeyAction: "frameBack" }
                    HotkeyButton { hotkeyAction: "frameForward" }
                }
                Row {
                    label: "Short jump"
                    SettingSlider {
                        setting: "seekStep"
                        from: 1; to: 20; stepSize: 1
                        valueText: (v) => v + " s"
                    }
                }
                Row {
                    label: "Long jump"
                    hint: "A multiple of the short jump."
                    SettingSlider {
                        setting: "jumpMultiplier"
                        from: 1.25; to: 10; stepSize: 0.25
                        valueText: (v) => v + "\u00d7 (" + Math.round((AppState.settings.seekStep || 5) * v * 100) / 100 + " s)"
                    }
                }
                Button {
                    text: "Reset hotkeys"
                    flat: true
                    onClicked: AppState.setSettings({ hotkeys: {}, seekStep: 5, jumpMultiplier: 2 })
                }
            }

            Section {
                title: "Subscriptions"
                Row {
                    label: "Feed source"
                    hint: "RSS refreshes all channels in seconds but has no video durations. Full shows durations "
                          + "and takes about four times longer."
                    SettingCombo { setting: "feedSource"; options: [["RSS (fast)", "rss"], ["Full", "full"]] }
                }
                Row { label: "Hide Shorts in the feed"; SettingSwitch { setting: "hideShorts" } }
                Row { label: "Hide watched videos in the feed"; SettingSwitch { setting: "hideWatched" } }
                Row {
                    label: "Hide upcoming premieres"
                    hint: "Premieres that haven't started, in the Videos feed."
                    SettingSwitch { setting: "hideUpcomingPremieres" }
                }
                Row {
                    label: "Hide upcoming live streams"
                    hint: "Scheduled live streams that haven't started, in the Live feed. (They never show in Videos.)"
                    SettingSwitch { setting: "hideUpcomingLive" }
                }
                Row {
                    label: AppState.subscriptions.length + " subscribed channels"
                    hint: "Import from or export to FreeTube (.db), YouTube Takeout (.csv), NewPipe (.json) or OPML."
                    Button { text: "Import…"; onClicked: page.importRequested() }
                    Button { text: "Export…"; enabled: AppState.subscriptions.length > 0; onClicked: page.exportRequested() }
                }
                Label {
                    visible: page.dataMessage !== ""
                    text: page.dataMessage
                    color: AppState.colors.success
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
            }

            Section {
                title: "History"
                Row { label: "Remember watched videos"; SettingSwitch { setting: "rememberHistory" } }
                Row {
                    label: "Continue where you left off"
                    hint: "Reopening a partly watched video resumes at the saved position."
                    SettingSwitch { setting: "resume" }
                }
                Row {
                    label: AppState.history.length + " videos in history"
                    Button { text: "Clear history"; enabled: AppState.history.length > 0; onClicked: confirm.open() }
                }
            }

            Section {
                title: "About"
                Label {
                    text: "FTL Player 0.2 • Qt " + "6.11" + " • mpv • youtubei.js 18.2 on Deno 2.9\n"
                          + "Settings, subscriptions and history are stored in the Data folder next to the app."
                    color: AppState.colors.secondary
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                    Layout.bottomMargin: 24
                }
            }
        }
    }

    Dialog {
        id: confirm
        anchors.centerIn: parent
        modal: true
        title: "Clear watch history?"
        Label { text: "All " + AppState.history.length + " entries and their saved positions will be removed." }
        standardButtons: Dialog.Yes | Dialog.Cancel
        onAccepted: AppState.clearHistory()
    }
}
