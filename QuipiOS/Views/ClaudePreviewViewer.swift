import SwiftUI
import UIKit

/// Q-87: a file Claude opened on the Mac, full screen. Pinch zooms, one finger
/// pans, double-tap toggles fit / 100 %, pull down at fit (or Done) closes.
/// Shows the thumbnail at once and swaps in the full image when it arrives.
struct ClaudePreviewViewer: View {
    let item: ClaudePreviewItem
    let client: WebSocketClient
    @Environment(\.dismiss) private var dismiss

    @State private var full: UIImage?
    @State private var pageCount: Int?
    @State private var error: String?
    @State private var loading = true
    @State private var watchdog: Task<Void, Never>?

    private var thumbImage: UIImage? {
        item.thumb.flatMap { Data(base64Encoded: $0) }.flatMap { UIImage(data: $0) }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = full ?? thumbImage {
                ZoomableImageView(image: image, onPullToDismiss: { dismiss() })
                    .ignoresSafeArea()
            }
            VStack(spacing: 0) {
                topBar
                Spacer()
                status
                bottomBar
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            client.onClaudePreviewImage = { handle($0) }
            request()
        }
        .onDisappear {
            client.onClaudePreviewImage = nil
            watchdog?.cancel()
        }
    }

    private var topBar: some View {
        HStack {
            Button("Done") { dismiss() }
                .fontWeight(.semibold)
            Spacer()
            Text(item.name)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let full {
                ShareLink(item: Image(uiImage: full), preview: SharePreview(item.name, image: Image(uiImage: full))) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share \(item.name)")
            } else {
                Image(systemName: "square.and.arrow.up").opacity(0.3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder private var status: some View {
        if let error {
            VStack(spacing: 8) {
                Text(error).font(.footnote)
                Button("Try again") { request() }.font(.footnote.weight(.semibold))
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 12)
        } else if loading {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading full image…").font(.footnote)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 12)
        } else if let pageCount, pageCount > 1 {
            Text("Page 1 of \(pageCount)")
                .font(.footnote)
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder private var bottomBar: some View {
        if item.hasDesktopWindow {
            Button {
                client.send(ClaudePreviewDismissMessage(id: item.id, closeOnDesktop: true))
                client.claudePreviews.removeAll { $0.id == item.id }
                dismiss()
            } label: {
                Label("Close on Mac", systemImage: "xmark.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
    }

    private func request() {
        loading = true
        error = nil
        client.send(ClaudePreviewRequestMessage(id: item.id))
        watchdog?.cancel()
        watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, loading, full == nil else { return }
            loading = false
            error = "The Mac didn't send the image."
        }
    }

    private func handle(_ msg: ClaudePreviewImageMessage) {
        guard msg.id == item.id else { return }
        watchdog?.cancel()
        loading = false
        if let reason = msg.error {
            error = reason
            return
        }
        guard let data = Data(base64Encoded: msg.data), let image = UIImage(data: data) else {
            error = "Couldn't read the image."
            return
        }
        pageCount = msg.pageCount
        full = image
    }
}

/// `UIScrollView` zooming, wrapped for SwiftUI: native pinch, pan, momentum
/// and bounce, which SwiftUI gestures over an `Image` don't match.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var onPullToDismiss: () -> Void

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        view.onPullToDismiss = onPullToDismiss
        view.setImage(image)
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.onPullToDismiss = onPullToDismiss
        if view.image !== image { view.setImage(image) }
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private(set) var image: UIImage?
    var onPullToDismiss: (() -> Void)?
    private var lastBoundsSize: CGSize = .zero

    /// Pulled this far down at fit zoom, letting go closes the viewer.
    private static let pullToDismissDistance: CGFloat = 90

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        alwaysBounceVertical = true
        bouncesZoom = true
        backgroundColor = .clear
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityHint = "Pinch to zoom. Double-tap to switch between fit and full size."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var imageSize: CGSize {
        guard let image else { return .zero }
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    private var fitScale: CGFloat { ZoomMath.fitScale(image: imageSize, viewport: bounds.size) }
    private var pixelScale: CGFloat {
        ZoomMath.pixelScale(screenScale: window?.screen.scale ?? traitCollection.displayScale)
    }
    private var isAtFit: Bool { abs(zoomScale - fitScale) <= fitScale * 0.02 }

    /// Swapping the thumbnail for the full image keeps what the user is looking
    /// at: same zoom relative to fit, same centre point.
    func setImage(_ newImage: UIImage) {
        let hadImage = image != nil && bounds.width > 0
        let relativeZoom = hadImage ? zoomScale / max(fitScale, .leastNonzeroMagnitude) : 1
        let centre = hadImage
            ? CGPoint(x: (contentOffset.x + bounds.width / 2) / max(contentSize.width, 1),
                      y: (contentOffset.y + bounds.height / 2) / max(contentSize.height, 1))
            : CGPoint(x: 0.5, y: 0.5)

        image = newImage
        imageView.image = newImage
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: imageSize)
        contentSize = imageSize
        guard bounds.width > 0 else { return }
        configureScales()
        zoomScale = min(max(fitScale * relativeZoom, minimumZoomScale), maximumZoomScale)
        centreContent()
        if hadImage, relativeZoom > 1.02 {
            contentOffset = CGPoint(x: centre.x * contentSize.width - bounds.width / 2,
                                    y: centre.y * contentSize.height - bounds.height / 2)
        }
    }

    private func configureScales() {
        let fit = fitScale, pixel = pixelScale
        minimumZoomScale = ZoomMath.minScale(fit: fit, pixel: pixel)
        maximumZoomScale = ZoomMath.maxScale(fit: fit, pixel: pixel)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastBoundsSize, bounds.width > 0, image != nil else { return }
        // First layout, or rotation: re-fit if the user was at fit.
        let refit = lastBoundsSize == .zero || isAtFit
        lastBoundsSize = bounds.size
        configureScales()
        if refit { zoomScale = fitScale }
        centreContent()
    }

    private func centreContent() {
        let insets = ZoomMath.centeringInsets(content: contentSize, viewport: bounds.size)
        contentInset = UIEdgeInsets(top: insets.vertical, left: insets.horizontal,
                                    bottom: insets.vertical, right: insets.horizontal)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centreContent() }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        // Only at fit: while zoomed in, dragging pans and must never close.
        guard isAtFit else { return }
        let pulled = -(contentOffset.y + contentInset.top)
        if pulled > Self.pullToDismissDistance || (velocity.y < -1.5 && pulled > 30) {
            onPullToDismiss?()
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        let target = ZoomMath.doubleTapTarget(current: zoomScale, fit: fitScale, pixel: pixelScale)
        if abs(target - fitScale) < 0.0001 {
            setZoomScale(fitScale, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            zoom(to: ZoomMath.zoomRect(around: point, scale: target, viewport: bounds.size, image: imageSize),
                 animated: true)
        }
    }
}
