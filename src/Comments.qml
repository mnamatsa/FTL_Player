import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// The page under the video: room for the video, its details (given by PlayerView), then the comments (count,
// sort order, comments with their replies). One ListView, so comments are only made as they scroll into view;
// more load near the end.
ListView {
    id: list
    property string videoId: ""
    property bool showComments: true
    property Component details: null    // title, channel, ... (PlayerView)
    property real columnX: 16           // the column under the video
    property real columnWidth: width - 32
    property real topSpace: 0           // room for the video above the details
    signal openChannel(var channel)     // {id, name}
    // A comment's text as rich text with links (PlayerView.descriptionHtml: URLs and timestamps), and what a
    // click on one does (a timestamp seeks).
    property var textHtml: null
    signal linkActivated(string link)
    property var linkClick: null        // (text item, position, button): middle / right click on a link

    property string sort: "top"         // "top" | "new"
    property string count: ""
    property string more: ""            // continuation token
    property bool loading: false
    property string error: ""
    // Replies opened or loaded, by comment ID: delegates come and go while scrolling, this stays.
    property var replyState: ({})
    ListModel { id: commentModel }

    model: commentModel
    boundsBehavior: Flickable.StopAtBounds
    cacheBuffer: Math.max(0, height)
    ScrollBar.vertical: ScrollBar {}
    SmoothScroll { id: smoothScroll; flickable: list }
    function wheelScroll(delta) { smoothScroll.scroll(delta) }
    // How far the page is scrolled from its top. Kept when the header changes height (the details load after
    // the page opens): ListView would keep contentY instead, leaving the page partly scrolled.
    property real scrolled: 0
    onContentYChanged: {
        scrolled = contentY - originY
        if (originY + contentHeight - contentY - height < 800) loadMore()
    }
    onOriginYChanged: contentY = originY + scrolled
    function toTop() { scrolled = 0; contentY = originY }

    onVideoIdChanged: reload()
    onSortChanged: reload()

    function reload() {
        commentModel.clear()
        replyState = {}
        count = ""
        more = ""
        error = ""
        loading = false
        if (videoId) load()
    }
    function load() {
        const id = videoId, token = more
        loading = true
        Helper.call("comments", token ? { more: token } : { videoId: id, sort: sort }, function (r) {
            if (videoId !== id) return
            loading = false
            if (!r.ok) { more = ""; if (!commentModel.count) error = r.error || "error"; return }
            if (r.count) count = r.count
            commentModel.append(r.items)
            more = r.more || ""
            if (!commentModel.count) error = "none"
        })
    }
    function loadMore() { if (more && !loading) load() }

    header: Item {
        width: list.width
        height: column.y + column.height
        ColumnLayout {
            id: column
            x: list.columnX
            y: list.topSpace
            width: list.columnWidth
            spacing: 0
            Loader { sourceComponent: list.details; Layout.fillWidth: true }
            RowLayout {
                visible: list.showComments
                spacing: 16
                Layout.fillWidth: true
                Layout.topMargin: 16
                Layout.bottomMargin: 8
                Label {
                    text: list.count ? list.count + (/comment/i.test(list.count) ? "" : " Comments") : "Comments"
                    font.pixelSize: 17
                    font.bold: true
                }
                ComboBox {
                    model: ["Top comments", "Newest first"]
                    currentIndex: list.sort === "new" ? 1 : 0
                    onActivated: (index) => list.sort = index === 1 ? "new" : "top"
                    implicitContentWidthPolicy: ComboBox.WidestText
                    flat: true
                }
                Item { Layout.fillWidth: true }
            }
            Label {
                visible: list.showComments && list.error !== ""
                text: list.error === "none" || /disabled|turned off|not available|continuation|comment/i.test(list.error)
                      ? "Comments are turned off or not available for this video." : list.error
                color: AppState.colors.secondary
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }
    }

    // One comment or reply: avatar, author and time, text, likes. Children go under the likes (replies).
    component CommentBody: RowLayout {
        id: body
        property var c                  // the comment from the helper
        property bool isReply: false
        default property alias extra: column.data
        spacing: 12

        Avatar {
            source: body.c.avatar || ""
            name: (body.c.author || "?").replace(/^@/, "")
            size: body.isReply ? 28 : 40
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: 4
            HoverHandler { cursorShape: body.c.authorId ? Qt.PointingHandCursor : Qt.ArrowCursor }
            TapHandler {
                enabled: !!body.c.authorId
                onTapped: list.openChannel({ id: body.c.authorId, name: body.c.author })
            }
        }
        ColumnLayout {
            id: column
            spacing: 2
            Layout.fillWidth: true

            Label {
                visible: !!body.c.pinned
                text: "📌 Pinned"
                color: AppState.colors.secondary
                font.pixelSize: 12
            }
            RowLayout {
                spacing: 8
                Label {
                    text: body.c.author || ""
                    font.pixelSize: 13
                    font.bold: true
                    color: body.c.owner ? "#ffffff" : AppState.colors.textSoft
                    font.underline: authorHover.hovered && !!body.c.authorId
                    topPadding: body.c.owner ? 2 : 0
                    bottomPadding: body.c.owner ? 2 : 0
                    leftPadding: body.c.owner ? 6 : 0
                    rightPadding: body.c.owner ? 6 : 0
                    background: Rectangle { visible: !!body.c.owner; radius: 9; color: AppState.colors.badge }
                    HoverHandler { id: authorHover; cursorShape: body.c.authorId ? Qt.PointingHandCursor : Qt.ArrowCursor }
                    TapHandler {
                        enabled: !!body.c.authorId
                        onTapped: list.openChannel({ id: body.c.authorId, name: body.c.author })
                    }
                }
                Label { text: body.c.published || ""; color: AppState.colors.muted; font.pixelSize: 12 }
            }
            TextEdit {
                text: list.textHtml ? list.textHtml(body.c.text || "") : body.c.text || ""
                color: AppState.colors.body
                font.pixelSize: 14
                wrapMode: TextEdit.Wrap
                readOnly: true
                selectByMouse: true
                selectionColor: "#f04242"
                textFormat: list.textHtml ? TextEdit.RichText : TextEdit.PlainText
                Layout.fillWidth: true
                onLinkActivated: (link) => list.linkActivated(link)
                HoverHandler { cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.IBeamCursor }
                TapHandler {
                    enabled: !!list.linkClick
                    acceptedButtons: Qt.MiddleButton | Qt.RightButton
                    onTapped: (point, button) => list.linkClick(parent, point.position, button)
                }
            }
            RowLayout {
                spacing: 14
                Row {
                    spacing: 4
                    Image {   // (white at 2/3: the #aaaaaa of the text)
                        source: AppState.dark ? "assets/thumb_up.svg" : "assets/thumb_up_dark.svg"   // (white on dark, black on light)
                        sourceSize: Qt.size(15, 15)
                        opacity: 0.67
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Label { text: body.c.likes || ""; color: AppState.colors.secondary; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
                }
                Label { visible: !!body.c.hearted; text: "❤"; color: "#f04242"; font.pixelSize: 12 }
            }
        }
    }

    // A top-level comment with its replies, loaded when opened.
    component TopComment: CommentBody {
        id: top
        property var replies: []
        property bool repliesOpen: false
        property bool repliesLoading: false
        property bool moreReplies: false

        Component.onCompleted: {
            const s = list.replyState[c.commentId]
            if (s) { replies = s.items; moreReplies = s.more; repliesOpen = s.open }
        }
        function remember() {
            list.replyState[c.commentId] = { open: repliesOpen, items: replies, more: moreReplies }
        }
        function loadReplies(next) {
            repliesLoading = true
            const id = c.commentId
            Helper.call("replies", next ? { commentId: id, more: true } : { commentId: id }, function (r) {
                const s = list.replyState[id] || { open: true, items: [], more: false }
                if (r.ok) { s.items = (next ? s.items : []).concat(r.items); s.more = !!r.more }
                else s.more = false
                list.replyState[id] = s
                if (top.c && top.c.commentId === id) {   // still showing this comment
                    repliesLoading = false
                    replies = s.items
                    moreReplies = s.more
                }
            })
        }

        Button {
            visible: !!top.c.hasReplies
            flat: true
            text: (top.repliesOpen ? "▲ " : "▼ ") + (top.c.replyCount ? top.c.replyCount + " " : "")
                  + (top.c.replyCount === "1" ? "reply" : "replies")
            Material.foreground: AppState.colors.link
            topPadding: 4
            bottomPadding: 4
            leftPadding: 8
            rightPadding: 8
            Layout.leftMargin: -8
            onClicked: {
                top.repliesOpen = !top.repliesOpen
                top.remember()
                if (top.repliesOpen && !top.replies.length) top.loadReplies(false)
            }
        }
        ColumnLayout {
            visible: top.repliesOpen
            spacing: 10
            Layout.fillWidth: true
            Repeater {
                model: top.repliesOpen ? top.replies : []
                delegate: CommentBody {
                    required property var modelData
                    c: modelData
                    isReply: true
                    Layout.fillWidth: true
                }
            }
            Label { visible: top.repliesLoading; text: "Loading replies…"; color: AppState.colors.muted }
            Button {
                visible: top.moreReplies && !top.repliesLoading
                flat: true
                text: "Show more replies"
                Material.foreground: AppState.colors.link
                topPadding: 4
                bottomPadding: 4
                Layout.leftMargin: -8
                onClicked: top.loadReplies(true)
            }
        }
    }

    delegate: Item {
        id: row
        required property var model
        width: list.width
        height: comment.implicitHeight + 16
        TopComment {
            id: comment
            x: list.columnX
            y: 10
            width: list.columnWidth
            c: row.model
        }
    }

    // A static line rather than a BusyIndicator: its animation slowed every frame of scrolling (~4 ms).
    footer: Item {
        width: list.width
        height: 56
        Label {
            visible: list.loading && list.showComments
            anchors.horizontalCenter: parent.horizontalCenter
            y: 8
            text: "Loading comments…"
            color: AppState.colors.muted
        }
    }
}
