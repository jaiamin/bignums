import SwiftUI

/// Ask anything about your money. Runs on Apple's on-device model, so nothing leaves the Mac.
struct AskView: View {
    let store: Store

    var body: some View {
        switch AssistantSupport.status {
        case .available:
            if #available(macOS 26.0, *) {
                AskConversation(assistant: AssistantProvider.assistant(for: store))
            }
        case .needsAppleIntelligence:
            unavailable("Turn on Apple Intelligence", "Open System Settings → Apple Intelligence & Siri, then ask again. Answers are worked out on this Mac.")
        case .modelNotReady:
            unavailable("Getting ready", "The on-device model is still downloading. Try again in a few minutes.")
        case .notSupported:
            unavailable("Not available on this Mac", "Asking needs macOS 26 or later on a Mac with Apple Intelligence.")
        }
    }

    private func unavailable(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, MenuView.inset)
        .padding(.vertical, 4)
    }
}

@available(macOS 26.0, *)
private struct AskConversation: View {
    let assistant: Assistant
    @State private var input = ""
    @FocusState private var focused: Bool

    private static let suggestions = [
        "How much did I spend on food this month?",
        "Which bills are due this week?",
        "What's my net worth?",
        "Am I spending more than usual?",
        "What changed since last month?",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if assistant.turns.isEmpty {
                greeting
            } else {
                conversation
            }
            composer
                .padding(.top, 12)
            Text("Runs on your Mac with Apple Intelligence. Answers can be wrong.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
        }
        .onAppear { focused = true }
    }

    // MARK: Greeting

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 0) {
            Avatar(size: 30)
                .padding(.horizontal, MenuView.inset)
            Text("What do you want to know?")
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, MenuView.inset)
                .padding(.top, 10)
            Text("Ask about your spending, bills and balances.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, MenuView.inset)
                .padding(.top, 2)
            Chips(items: Self.suggestions) { assistant.send($0) }
                .padding(.top, 16)
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Avatar(size: 18)
                    Text("Ask")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { assistant.reset() } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(assistant.isResponding)
                .help("New chat")
            }
            .padding(.horizontal, MenuView.inset)
            .padding(.bottom, 10)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(assistant.turns) { turn in
                            Group {
                                UserBubble(text: turn.question)
                                answer(turn)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, MenuView.inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: MenuMetrics.tabMaxHeight - 110)
                .onChange(of: assistant.turns.last?.answer) { proxy.scrollTo("end") }
                .onChange(of: assistant.turns.count) { proxy.scrollTo("end") }
                .onChange(of: assistant.activity) { proxy.scrollTo("end") }
            }
        }
    }

    @ViewBuilder
    private func answer(_ turn: Assistant.Turn) -> some View {
        let isLast = turn.id == assistant.turns.last?.id
        HStack(alignment: .top, spacing: 8) {
            Avatar(size: 20)
            VStack(alignment: .leading, spacing: 8) {
                if turn.answer.isEmpty {
                    HStack(spacing: 8) {
                        TypingDots()
                        if let activity = assistant.activity, activity != "Thinking…" {
                            Text(activity)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 20)
                } else {
                    Text(turn.answer)
                        .font(.system(size: 13))
                        .foregroundStyle(turn.failed ? Color.orange : Color.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isLast && !assistant.isResponding {
                        actions(turn)
                    }
                }
                if isLast && !assistant.isResponding && !turn.followUps.isEmpty {
                    Chips(items: turn.followUps, inset: 0, compact: true) { assistant.send($0) }
                }
            }
        }
    }

    /// Copy and try again, quiet until needed.
    private func actions(_ turn: Assistant.Turn) -> some View {
        HStack(spacing: 2) {
            iconButton("doc.on.doc", help: "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(turn.answer, forType: .string)
            }
            iconButton("arrow.clockwise", help: "Try again") { assistant.retry() }
        }
        .padding(.leading, -5)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.tertiary)
        .help(help)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask anything…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    // Return sends; Shift-Return adds a line.
                    if press.modifiers.contains(.shift) { return .ignored }
                    send()
                    return .handled
                }
                .padding(.vertical, 2)
            sendButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(focused ? 0.18 : 0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var sendButton: some View {
        let empty = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if assistant.isResponding {
            Button { assistant.stop() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary))
            }
            .buttonStyle(.plain)
            .help("Stop")
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(empty ? Color.secondary : Color(nsColor: .windowBackgroundColor))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(empty ? Color.primary.opacity(0.1) : Color.primary.opacity(0.88)))
            }
            .buttonStyle(.plain)
            .disabled(empty)
        }
    }

    private func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        input = ""
        assistant.send(question)
    }
}

// MARK: - Pieces

/// The assistant's mark: a soft circle with a sparkle, beside everything it says.
private struct Avatar: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.75))
            .frame(width: size, height: size)
            .background(Circle().fill(Color.primary.opacity(0.08)))
    }
}

/// The user's message, right-aligned in a filled bubble.
private struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16,
                                           style: .continuous)
                        .fill(Color.primary.opacity(0.88))
                )
        }
    }
}

/// Three pulsing dots while the answer hasn't started.
private struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate * 3) % 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 5, height: 5)
                        .opacity(index == phase ? 1 : 0.35)
                }
            }
        }
    }
}

/// Tappable suggestion pills that wrap onto as many lines as they need.
private struct Chips: View {
    let items: [String]
    var inset: CGFloat = MenuView.inset
    var compact = false
    let action: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button { action(item) } label: {
                    Text(item)
                        .font(.system(size: compact ? 12 : 12.5))
                        .foregroundStyle(.primary.opacity(0.85))
                        .padding(.horizontal, 11)
                        .padding(.vertical, compact ? 5 : 6)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, inset)
    }
}

/// Lays children out left to right, starting a new line when one doesn't fit.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for ((subview, origin), size) in zip(zip(subviews, result.origins), result.sizes) {
            // Place at the measured size, so a chip that had to wrap stays wrapped.
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: ProposedViewSize(size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint], sizes: [CGSize]) {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins, sizes)
    }
}
