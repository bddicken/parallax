import ParallaxRemote
import SwiftUI

struct ChatPanel: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var target: Platform?

    private var broadcast: BroadcastModel { model.broadcast }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Chat") {
                Toggle(isOn: mockBinding) { Text("Mock") }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .tint(.orange)
                    .disabled(broadcast.service.mode == .server)
                    .help(broadcast.service.mode == .server
                          ? "Connected to a real server; mock chat is unavailable."
                          : "Fill chat with fake messages to try out chat, replies, and on-screen comments.")
                if broadcast.connectionError != nil {
                    Image(systemName: "wifi.exclamationmark").foregroundStyle(.red).help(broadcast.connectionError ?? "")
                }
            }
            Divider()
            ScrollViewReader { proxy in
                List(broadcast.messages) { message in
                    ChatRow(message: message, isFeatured: message.id == broadcast.featuredMessageID) {
                        broadcast.toggleFeatured(message.id)
                    }
                    .id(message.id)
                }
                .listStyle(.plain)
                .onChange(of: broadcast.messages.last?.id) { _, last in
                    if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
                .overlay {
                    if broadcast.messages.isEmpty {
                        if broadcast.service.mode == .offline {
                            ContentUnavailableView {
                                Label("Chat not connected", systemImage: "bubble.left.and.bubble.right")
                            } description: {
                                Text("Chat from YouTube, X, and Twitch shows up here once parallax-server is set up in Settings › Server. Turn on Mock to try it with fake messages.")
                            }
                        } else {
                            ContentUnavailableView("No messages yet", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Menu {
                    Button("All platforms") { target = nil }
                    ForEach(Platform.allCases.filter(\.supportsChat), id: \.self) { p in
                        Button(p.displayName) { target = p }
                    }
                } label: {
                    Text(target?.displayName ?? "All")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                TextField("Reply as yourself…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "paperplane.fill") }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
    }

    private var mockBinding: Binding<Bool> {
        Binding(get: { broadcast.service.mode == .mock }, set: { on in
            model.profile.broadcast.useMockServer = on
            broadcast.connect(model.profile.broadcast)
        })
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await broadcast.send(text, to: target.map { [$0] }) }
    }
}

private struct ChatRow: View {
    let message: ChatMessage
    let isFeatured: Bool
    let toggleFeatured: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PlatformBadge(platform: message.platform)
                .help(message.platform.displayName)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(message.author.displayName).font(.callout.weight(.semibold))
                    if message.author.isOwner { Image(systemName: "person.crop.circle.badge.checkmark").font(.caption) }
                    if message.author.isModerator { Image(systemName: "shield.fill").font(.caption).foregroundStyle(.green) }
                }
                Text(message.text).font(.callout).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button(action: toggleFeatured) {
                Image(systemName: isFeatured ? "star.fill" : "star")
                    .foregroundStyle(isFeatured ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .opacity(hovering || isFeatured ? 1 : 0)
            .help(isFeatured ? "Remove from screen" : "Show on screen (needs a Featured Comment source)")
        }
        .padding(.vertical, 3)
        .listRowBackground(isFeatured ? Color.yellow.opacity(0.12) : Color.clear)
        .onHover { hovering = $0 }
    }
}

/// SF Symbols has no X logo, so X gets a text glyph.
struct PlatformBadge: View {
    let platform: Platform

    var body: some View {
        Group {
            if platform == .x {
                Text("𝕏").font(.caption.bold())
            } else {
                Image(systemName: platform.symbol).font(.caption)
            }
        }
        .foregroundStyle(platform.accent.color)
        .frame(width: 16)
    }
}
