import SwiftUI

/// Thin horizontal strip that appears above the terminal input row when a
/// pending image is attached. Shows a thumbnail, a remove (✕) control, and an
/// upload state overlay (spinner / error). Renders nothing when no image is
/// pending, so the idle input row keeps its resting height.
struct PendingImagePreviewStrip: View {

    @ObservedObject var state: PendingImageState

    var body: some View {
        if let image = state.image {
            HStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            switch state.uploadState {
                            case .uploading:
                                Color.black.opacity(0.45)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                ProgressView()
                                    .tint(.white)
                            case .justSent:
                                // Green tint + checkmark for the brief moment
                                // between ack arrival and the thumbnail clearing.
                                Color.green.opacity(0.55)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(.white)
                            case .idle, .error:
                                EmptyView()
                            }
                        }

                    // ✕ is available in every state except `.justSent`
                    // (the brief green-flash between ack and auto-clear).
                    // Previously gated to `.idle` only — which left the user
                    // stuck staring at a frozen thumbnail when the upload
                    // wedged mid-flight or the watchdog tripped into
                    // `.error`. If cancelling during `.uploading`, the
                    // local thumbnail is cleared immediately; any in-flight
                    // watchdog no-ops (it checks uploadState before firing).
                    if state.uploadState != .justSent {
                        Button {
                            state.clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white, .black.opacity(0.7))
                                .offset(x: 6, y: -6)
                        }
                        .accessibilityLabel("Remove pending image")
                    }
                }

                if case .error(let reason) = state.uploadState {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}
