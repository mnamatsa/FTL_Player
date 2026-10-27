import QtQuick

// Smooth mouse-wheel scrolling for a Flickable (grid, list or page). Each notch moves a target; the content
// follows it like a critically damped spring, so the speed carries over smoothly from notch to notch (a
// fixed-time glide per notch speeds up at every notch, which feels jerky). Ctrl + wheel is left to others.
WheelHandler {
    id: smooth
    required property Flickable flickable
    // pixels per notch, times Settings > Layout > Scroll speed
    property real step: Math.max(1, Qt.styleHints.wheelScrollLines) * 40 * (AppState.settings.scrollSpeed || 1)
    property real stiffness: 24         // 1/s: settles in about 0.2 s
    property real target: 0
    property real velocity: 0           // pixels per second
    acceptedModifiers: Qt.NoModifier

    function bounds() {
        const f = flickable
        const minY = f.originY - f.topMargin
        return [minY, Math.max(minY, f.originY + f.contentHeight + f.bottomMargin - f.height)]
    }

    onWheel: (event) => { scroll(event.angleDelta.y); event.accepted = true }

    // Also for wheel turns that arrive elsewhere (e.g. over the video): angle delta, 120 per notch.
    function scroll(delta) {
        if (!frames.running) { target = flickable.contentY; velocity = 0 }
        const [minY, maxY] = bounds()
        target = Math.max(minY, Math.min(maxY, target - delta / 120 * step))
        frames.start()
    }

    readonly property FrameAnimation frames: FrameAnimation {      // a handler takes no child objects
        onTriggered: {
            const f = smooth.flickable
            if (f.dragging || f.flicking) { stop(); return }
            const [minY, maxY] = smooth.bounds()
            const w = smooth.stiffness
            let y = f.contentY, v = smooth.velocity
            // small fixed steps keep the spring stable however long the frame was
            for (let left = Math.min(frameTime, 0.1); left > 0; left -= 0.004) {
                const dt = Math.min(0.004, left)
                v += (w * w * (smooth.target - y) - 2 * w * v) * dt
                y += v * dt
            }
            if (y <= minY || y >= maxY) { y = Math.max(minY, Math.min(maxY, y)); v = 0 }
            smooth.velocity = v
            if (Math.abs(smooth.target - y) < 0.5 && Math.abs(v) < 20) { y = smooth.target; stop() }
            f.contentY = y
        }
    }
}
