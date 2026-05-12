import SwiftUI

/// Thin horizontal strip that appears above the terminal input row when a
/// pending image is attached. Shows a thumbnail, a remove (✕) control, and an
/// upload state overlay (spinner / error). Renders nothing when no image is
/// pending, so the idle input row keeps its resting height.
struct PendingImagePreviewStrip: View {

    @ObservedObject var state: PendingImageState

    /// §L — host-provided action handler for the error chip's recovery
    /// button. Optional; nil disables the action affordance entirely
    /// (legacy callers that haven't wired the recovery path keep
    /// rendering the categorized text without a CTA).
    var onRecoveryAction: ((ImageUploadFailure) -> Void)? = nil

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

                // §L — categorized error chip with recovery affordance.
                // Replaces the freeform red-string render so the user
                // gets an actionable next step instead of having to
                // decode "no response (last stage: ...)".
                if case .error(let reason) = state.uploadState {
                    let category = ImageUploadFailure.classify(reason: reason)
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.label)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.red)
                                .lineLimit(1)
                            // Original raw reason as secondary line so the
                            // diagnostic stage info isn't lost. Smaller +
                            // muted so it doesn't fight the primary chip.
                            Text(reason)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if !category.actionLabel.isEmpty,
                           let onRecoveryAction {
                            Button {
                                onRecoveryAction(category)
                            } label: {
                                Text(category.actionLabel)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.red.opacity(0.15))
                                    .foregroundStyle(.red)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(category.actionLabel)
                            .accessibilityHint("Recover from \(category.label)")
                            .accessibilityAddTraits(.isButton)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Upload error: \(category.label). \(reason)")
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}
