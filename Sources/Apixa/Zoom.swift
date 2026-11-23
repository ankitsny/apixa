import SwiftUI
import AppKit

/// Zoom shared by every shot, so you can arrow through a burst at 100% and compare focus on the same spot.
/// `scale` nil = fit to window; otherwise original pixels per screen pixel (1 = 100%).
struct ZoomState: Equatable {
    var scale: Double? = nil
    var center = CGPoint(x: 0.5, y: 0.5)   // normalized, top-left origin
}

enum ZoomCommand: String {
    case toggle, zoomIn, zoomOut, fit, actual
    static let notification = Notification.Name("ApixaZoomCommand")
    func post() { NotificationCenter.default.post(name: Self.notification, object: rawValue) }
}

/// Pinch / ⌘-scroll / double-click to zoom, drag or scroll to pan. Backed by NSScrollView magnification.
struct ZoomableImage: NSViewRepresentable {
    let image: NSImage
    /// Size of the image in ORIGINAL pixels (the rendered image may be smaller; it's stretched to this).
    let originalSize: CGSize
    @Binding var zoom: ZoomState
    var background: NSColor = .underPageBackgroundColor
    /// Space around the photo when fitted. The background is the scroll view's own (static) canvas,
    /// so only the photo scales when you zoom.
    var margin: CGFloat = 28

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Always fill the space offered; never push neighbouring panels around.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ZoomScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }

    func makeNSView(context: Context) -> ZoomScrollView {
        let sv = ZoomScrollView()
        sv.coordinator = context.coordinator
        sv.allowsMagnification = true
        sv.hasHorizontalScroller = true
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.drawsBackground = true
        sv.backgroundColor = background
        sv.contentView = CenteringClipView()
        let iv = PanImageView()
        iv.coordinator = context.coordinator
        sv.documentView = iv
        context.coordinator.scrollView = sv
        context.coordinator.observe()
        return sv
    }

    func updateNSView(_ sv: ZoomScrollView, context: Context) {
        context.coordinator.parent = self
        sv.backgroundColor = background
        guard let iv = sv.documentView as? PanImageView else { return }
        if iv.image !== image { iv.image = image }
        if context.coordinator.margin != margin {
            context.coordinator.margin = margin
            if zoom.scale == nil { context.coordinator.refit() }
        }
        let logical = context.coordinator.logicalSize(originalSize, in: sv)
        if iv.frame.size != logical {
            iv.frame = CGRect(origin: .zero, size: logical)
        }
        context.coordinator.apply(zoom, animated: false)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ZoomableImage
        weak var scrollView: ZoomScrollView?
        var margin: CGFloat = 28
        private var applying = false
        private var reportTask: Task<Void, Never>?
        private var lastApplied: ZoomState?

        init(_ p: ZoomableImage) { parent = p }

        /// Document size in points such that magnification 1.0 = 100% (one image pixel per screen pixel).
        func logicalSize(_ px: CGSize, in v: NSView) -> CGSize {
            let bs = v.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            return CGSize(width: max(1, px.width / bs), height: max(1, px.height / bs))
        }

        var fitMagnification: CGFloat {
            guard let sv = scrollView, let doc = sv.documentView, doc.frame.width > 0, doc.frame.height > 0 else { return 1 }
            // Leave a small margin around the fitted image, like the previous padded preview.
            let availW = max(1, sv.frame.width - margin * 2), availH = max(1, sv.frame.height - margin * 2)
            return min(availW / doc.frame.width, availH / doc.frame.height)
        }

        func observe() {
            guard let sv = scrollView else { return }
            sv.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSView.boundsDidChangeNotification, object: sv.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(endLiveMagnify), name: NSScrollView.didEndLiveMagnifyNotification, object: sv)
            NotificationCenter.default.addObserver(self, selector: #selector(command(_:)), name: ZoomCommand.notification, object: nil)
        }

        func apply(_ z: ZoomState, animated: Bool) {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            let fit = fitMagnification
            sv.minMagnification = min(fit, 1) * 0.25   // can zoom out below fit, down to ¼ of it
            sv.maxMagnification = 4
            applying = true
            defer { applying = false }
            if let s = z.scale {
                if abs(sv.magnification - s) > 0.001 {
                    if animated {
                        let center = CGPoint(x: z.center.x * doc.frame.width, y: z.center.y * doc.frame.height)
                        NSAnimationContext.runAnimationGroup { ctx in
                            ctx.duration = 0.18
                            ctx.allowsImplicitAnimation = true
                            sv.animator().setMagnification(s, centeredAt: center)
                        }
                        lastApplied = z
                        return
                    }
                    sv.magnification = s
                }
                let visible = sv.contentView.bounds.size
                let p = CGPoint(x: z.center.x * doc.frame.width - visible.width / 2,
                                y: z.center.y * doc.frame.height - visible.height / 2)
                if z != lastApplied || animated { sv.contentView.scroll(to: sv.contentView.constrainBoundsRect(CGRect(origin: p, size: visible)).origin) }
            } else if abs(sv.magnification - fit) > 0.001 {
                if animated {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.18
                        sv.animator().magnification = fit
                    }
                } else {
                    sv.magnification = fit
                }
            }
            sv.reflectScrolledClipView(sv.contentView)
            lastApplied = z
        }

        func refit() {
            if parent.zoom.scale == nil { apply(parent.zoom, animated: false) }
        }

        /// Pan/zoom events arrive many times per second; tell the rest of the app only once things settle,
        /// so SwiftUI isn't re-rendering (or starting full-res renders) mid-gesture.
        @objc func changed() {
            guard !applying else { return }
            reportTask?.cancel()
            reportTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
                self?.report()
            }
        }

        @objc func endLiveMagnify() {
            reportTask?.cancel()
            report()
        }

        private func report() {
            guard !applying, let sv = scrollView, let doc = sv.documentView, doc.frame.width > 0 else { return }
            let fit = fitMagnification
            let v = sv.contentView.bounds
            var z = ZoomState()
            // "Fit" only when we're actually at fit; smaller or larger is an explicit zoom level.
            if abs(sv.magnification - fit) > fit * 0.01 {
                z.scale = sv.magnification
                z.center = CGPoint(x: v.midX / doc.frame.width, y: v.midY / doc.frame.height)
            }
            if z != parent.zoom {
                lastApplied = z
                parent.zoom = z
            }
        }

        func toggle(at docPoint: CGPoint?) {
            guard let doc = scrollView?.documentView else { return }
            var z = ZoomState()
            if parent.zoom.scale == nil {
                z.scale = 1
                if let p = docPoint { z.center = CGPoint(x: p.x / doc.frame.width, y: p.y / doc.frame.height) }
            }
            parent.zoom = z
            apply(z, animated: true)
        }

        @objc func command(_ n: Notification) {
            guard let raw = n.object as? String, let c = ZoomCommand(rawValue: raw), scrollView?.window?.isKeyWindow == true else { return }
            var z = parent.zoom
            let cur = z.scale ?? Double(fitMagnification)
            switch c {
            case .toggle: toggle(at: nil); return
            case .fit: z.scale = nil
            case .actual: z.scale = 1
            case .zoomIn:
                let fit = Double(fitMagnification)
                if cur < fit * 0.99 && cur * 1.5 > fit { z.scale = nil } else { z.scale = min(4, cur * 1.5) }
            case .zoomOut:
                let fit = Double(fitMagnification)
                // Step through "fit" on the way down, then keep going smaller.
                if cur > fit * 1.01 && cur / 1.5 < fit { z.scale = nil } else { z.scale = max(fit * 0.25, cur / 1.5) }
            }
            parent.zoom = z
            apply(z, animated: true)
        }
    }
}

final class ZoomScrollView: NSScrollView {
    weak var coordinator: ZoomableImage.Coordinator?

    override func layout() {
        super.layout()
        MainActor.assumeIsolated { coordinator?.refit() }
    }

    /// Plain scroll wheel pans; ⌘ or ⌥ + scroll zooms around the pointer.
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option), let doc = documentView {
            let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
            let p = doc.convert(event.locationInWindow, from: nil)
            setMagnification(min(maxMagnification, max(minMagnification, magnification * factor)), centeredAt: p)
            MainActor.assumeIsolated { coordinator?.changed() }
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Keeps the image centred when it's smaller than the viewport.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }

    override var isFlipped: Bool { true }
}

/// Image view that pans on drag and toggles fit/100% on double-click.
///
/// The photo is the layer's contents: it's uploaded to the GPU once and every zoom/pan step is just
/// a GPU rescale (with mipmaps when zoomed out), instead of AppKit redrawing the picture on the CPU.
final class PanImageView: NSView {
    weak var coordinator: ZoomableImage.Coordinator?

    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            // HDR renders carry a content headroom; let the layer show them above SDR white.
            layer?.preferredDynamicRange = HDR.isHDR(cg) ? .high : .standard
            layer?.contents = cg ?? image
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    private var dragStart: NSPoint?
    private var originStart: NSPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let p = convert(event.locationInWindow, from: nil)
            MainActor.assumeIsolated { coordinator?.toggle(at: p) }
            return
        }
        dragStart = event.locationInWindow
        originStart = enclosingScrollView?.contentView.bounds.origin
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart, let o = originStart, let sv = enclosingScrollView else { return }
        let m = sv.magnification
        let dx = (event.locationInWindow.x - s.x) / m, dy = (event.locationInWindow.y - s.y) / m
        let target = NSPoint(x: o.x - dx, y: o.y + dy)
        sv.contentView.scroll(to: sv.contentView.constrainBoundsRect(NSRect(origin: target, size: sv.contentView.bounds.size)).origin)
        sv.reflectScrolledClipView(sv.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { NSCursor.pop() }
        dragStart = nil
    }
}
