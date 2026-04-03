import SwiftUI

struct TerminalContentOverlay: View {
    let content: String
    let windowName: String
    var onDismiss: () -> Void
    var onRefresh: () -> Void

    let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text(windowName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Button { onRefresh() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.trailing, 8)
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.06))

                // Content
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(content)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .id("bottom")
                    }
                    .onAppear {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .background(Color(red: 0.08, green: 0.08, blue: 0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(8)
        }
        .onReceive(refreshTimer) { _ in
            onRefresh()
        }
    }
}
