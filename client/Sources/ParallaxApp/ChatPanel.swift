import ParallaxCore
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
                PopOutChatMenu()
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
            OnStreamBar()
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
                                Text("Chat from your connected platforms shows up here once parallax-server is set up in Settings › Server. Turn on Mock to try it with fake messages.")
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
            model.connectBroadcast()
        })
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await broadcast.send(text, to: target.map { [$0] }) }
    }
}

/// Opens each platform's own chat page in the browser the user picks.
private struct PopOutChatMenu: View {
    @Environment(AppModel.self) private var model

    private var broadcast: BroadcastModel { model.broadcast }

    var body: some View {
        Menu {
            if broadcast.xChatPage != nil {
                Button("Read X Chat in Parallax…", action: broadcast.showXChat)
            }
            Section("Open Chats In") {
                ForEach(BrowserWindows.browsers()) { browser in
                    Button {
                        Task {
                            await broadcast.refreshDestinations()
                            await BrowserWindows.open(broadcast.chatPages, in: browser)
                        }
                    } label: {
                        Label { Text(browser.isDefault ? "\(browser.name) (Default)" : browser.name) } icon: { Image(nsImage: browser.icon) }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.forward.app")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(broadcast.chatPages.isEmpty && broadcast.xChatPage == nil)
        .help(broadcast.chatPages.isEmpty
              ? "Pop out each platform's chat in your browser. Twitch works once connected, YouTube once you go live there, and X once the server has X_USERNAME."
              : "Pop out each platform's chat in a browser you pick, or read X chat in Parallax.")
    }
}

/// Puts chat on the stream in the live scene: the recent-messages feed and
/// the starred comment. Fine-tune by dragging it in the preview.
private struct OnStreamBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let feed = model.chatItem(.chatFeed)
        let placement = feed.flatMap { ChatPlacement(matching: $0.frame) }
        HStack(spacing: 6) {
            Text("On stream").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            toggle(.chatFeed, "Chat", systemImage: "bubble.left.and.bubble.right.fill",
                   help: "Show recent chat on the stream in this scene. Drag it in the preview to move it, or drag a corner to resize.")
            toggle(.featuredChat, "Featured", systemImage: "star.fill",
                   help: "Show the comment you star on the stream in this scene.")
            Menu {
                Section("Place Chat") {
                    ForEach(ChatPlacement.allCases) { p in
                        Toggle(isOn: Binding(get: { placement == p }, set: { _ in model.placeChat(p) })) {
                            Label(p.title, systemImage: p.symbol)
                        }
                    }
                }
                Section("Text Size") {
                    ForEach(ChatTextSize.allCases) { size in
                        Toggle(size.title, isOn: Binding(get: { model.profile.chatTextSize == size }, set: { _ in setTextSize(size) }))
                    }
                }
                Divider()
                Button("Adjust in Preview") { model.selectedItemID = feed?.id }
                    .disabled(feed?.isVisible != true)
            } label: {
                Image(systemName: placement?.symbol ?? "rectangle.dashed")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Where chat sits on the stream and how big its text is. Or drag it in the preview.")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func setTextSize(_ size: ChatTextSize) {
        model.edit("Chat Text Size") { model.profile.chatTextSize = size }
    }

    private func toggle(_ kind: VideoSourceKind, _ title: String, systemImage: String, help: String) -> some View {
        Toggle(isOn: Binding(get: { model.isOnScreen(kind) }, set: { model.setOnScreen(kind, $0) })) {
            Label(title, systemImage: systemImage)
        }
        .toggleStyle(.button)
        .help(help)
    }
}

private struct ChatRow: View {
    let message: ChatMessage
    let isFeatured: Bool
    let toggleFeatured: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ChatAvatar(author: message.author, platform: message.platform)
                .help("\(message.author.displayName) on \(message.platform.displayName)")
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
            .help(isFeatured ? "Remove from screen" : "Show on screen (turn on Featured above)")
        }
        .padding(.vertical, 3)
        .listRowBackground(isFeatured ? Color.yellow.opacity(0.12) : Color.clear)
        .onHover { hovering = $0 }
    }
}

/// The sender's profile picture with their platform's badge on the corner.
/// Falls back to their initial when there's no picture (or it won't load).
private struct ChatAvatar: View {
    let author: ChatAuthor
    let platform: Platform

    private static let size: CGFloat = 28

    var body: some View {
        picture
            .frame(width: Self.size, height: Self.size)
            .clipShape(Circle())
            .overlay(alignment: .bottomTrailing) {
                PlatformBadge(platform: platform, font: .system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(.background))
                    .offset(x: 4, y: 4)
            }
            .padding(.trailing, 4)
            .padding(.bottom, 4)
    }

    @ViewBuilder private var picture: some View {
        if let url = author.avatarURL.flatMap(URL.init(string:)) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    initial
                }
            }
        } else {
            initial
        }
    }

    private var initial: some View {
        Text(author.displayName.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(platform.accent.color.opacity(0.8))
    }
}

/// SF Symbols has no X logo, so X gets a text glyph.
struct PlatformBadge: View {
    let platform: Platform
    var font: Font = .caption

    var body: some View {
        Group {
            if platform == .x {
                Text("𝕏").bold()
            } else {
                Image(systemName: platform.symbol)
            }
        }
        .font(font)
        .foregroundStyle(platform.accent.color)
        .frame(minWidth: 14)
    }
}
