import AppKit
import SwiftUI

/// Matches the document indicator while keeping the native sidebar's scrolling and rows.
struct SidebarScrollIndicator: NSViewRepresentable {
    var width: CGFloat

    func makeNSView(context: Context) -> IndicatorView { IndicatorView() }
    func updateNSView(_ view: IndicatorView, context: Context) {
        view.indicatorWidth = width
        view.connect()
    }
    static func dismantleNSView(_ view: IndicatorView, coordinator: ()) { view.disconnect() }

    @MainActor final class HiddenScroller: NSScroller {
        override func draw(_ dirtyRect: NSRect) {}
        override func drawKnob() {}
        override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor final class IndicatorView: NSView {
        var indicatorWidth: CGFloat = 3 { didSet { needsDisplay = true } }
        private weak var scrollView: NSScrollView?
        private var hideWork: DispatchWorkItem?
        private var fadeTimer: Timer?
        private var thumbOpacity: CGFloat = 0 { didSet { needsDisplay = true } }
        private var draggingThumb = false
        private var dragOffsetY: CGFloat = 0
        private var lastOrigin = NSPoint.zero
        private var attempts = 0

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let superview, let thumb = thumbRect() else { return nil }
            let local = convert(point, from: superview)
            return thumb.insetBy(dx: -5, dy: -4).contains(local) ? self : nil
        }
        override func mouseDown(with event: NSEvent) {
            guard let thumb = thumbRect() else { return }
            let local = convert(event.locationInWindow, from: nil)
            dragOffsetY = local.y - thumb.minY
            draggingThumb = true
            showThumb()
        }
        override func mouseDragged(with event: NSEvent) {
            guard draggingThumb, let scroll = scrollView, let document = scroll.documentView,
                  let thumb = thumbRect() else { return }
            let travel = bounds.height - thumb.height
            guard travel > 0 else { return }
            let visible = scroll.documentVisibleRect
            let contentTravel = document.bounds.height - visible.height
            guard contentTravel > 0 else { return }
            let local = convert(event.locationInWindow, from: nil)
            let ratio = max(0, min(1, (local.y - dragOffsetY) / travel))
            let origin = NSPoint(x: scroll.contentView.bounds.origin.x,
                y: document.bounds.minY + ratio * contentTravel)
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            showThumb()
        }
        override func mouseUp(with event: NSEvent) {
            draggingThumb = false
            scheduleHide()
        }
        override func scrollWheel(with event: NSEvent) {
            scrollView?.scrollWheel(with: event)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { disconnect() } else { attempts = 0; connect() }
        }
        override func layout() { super.layout(); needsDisplay = true }

        func connect() {
            guard window != nil, scrollView == nil else { return }
            var ancestor = superview
            while let root = ancestor {
                if let scroll = findTable(in: root)?.enclosingScrollView {
                    scrollView = scroll
                    scroll.scrollerStyle = .overlay
                    scroll.verticalScroller = HiddenScroller()
                    scroll.hasHorizontalScroller = false
                    lastOrigin = scroll.contentView.bounds.origin
                    thumbOpacity = 0
                    scroll.contentView.postsBoundsChangedNotifications = true
                    scroll.documentView?.postsFrameChangedNotifications = true
                    NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
                    if let document = scroll.documentView {
                        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSView.frameDidChangeNotification, object: document)
                    }
                    return
                }
                ancestor = root.superview
            }
            guard attempts < 10 else { return }
            attempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.connect() }
        }

        private func findTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews { if let table = findTable(in: child) { return table } }
            return nil
        }

        func disconnect() {
            hideWork?.cancel()
            fadeTimer?.invalidate(); fadeTimer = nil
            NotificationCenter.default.removeObserver(self)
            scrollView = nil
            draggingThumb = false
            thumbOpacity = 0
        }

        @objc private func resized() { needsDisplay = true }
        @objc private func scrolled() {
            guard let scroll = scrollView else { return }
            let origin = scroll.contentView.bounds.origin
            guard origin != lastOrigin else { needsDisplay = true; return }
            lastOrigin = origin
            showThumb()
        }
        private func showThumb() {
            hideWork?.cancel()
            fadeTimer?.invalidate(); fadeTimer = nil
            thumbOpacity = 1
            if !draggingThumb { scheduleHide() }
        }
        private func scheduleHide() {
            hideWork?.cancel()
            guard !draggingThumb else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    self.thumbOpacity = 0
                    return
                }
                self.fadeTimer?.invalidate()
                self.fadeTimer = Timer.scheduledTimer(timeInterval: 0.02, target: self,
                    selector: #selector(self.fadeTick(_:)), userInfo: nil, repeats: true)
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        }
        @objc private func fadeTick(_ timer: Timer) {
            thumbOpacity = max(0, thumbOpacity - 0.1)
            if thumbOpacity == 0 { timer.invalidate(); fadeTimer = nil }
        }

        private func thumbRect() -> NSRect? {
            guard let scroll = scrollView, let document = scroll.documentView else { return nil }
            let visible = scroll.documentVisibleRect
            let contentHeight = document.bounds.height
            guard contentHeight > visible.height, bounds.height > 0 else { return nil }
            let height = min(bounds.height, max(28, visible.height / contentHeight * bounds.height))
            let ratio = max(0, min(1, (visible.minY - document.bounds.minY) / (contentHeight - visible.height)))
            let width = max(1, min(8, indicatorWidth))
            return NSRect(x: bounds.width - width - 5, y: ratio * (bounds.height - height), width: width, height: height)
        }
        override func draw(_ dirtyRect: NSRect) {
            guard let thumb = thumbRect(), thumbOpacity > 0 else { return }
            NSColor(calibratedWhite: 120.0 / 255, alpha: 0.5 * thumbOpacity).setFill()
            NSBezierPath(roundedRect: thumb, xRadius: 2, yRadius: 2).fill()
        }
    }
}
