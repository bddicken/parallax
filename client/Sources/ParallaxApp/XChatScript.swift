import Foundation
import ParallaxRemote

/// The script `XChatReader` runs in X's chat page (x.com/<handle>/livechat),
/// and what it reports.
///
/// X streams chat to the page as NDJSON that has only user IDs, then looks up
/// names and pictures before showing each comment. So the script reads the
/// finished comments from the page's chat list instead: a React Native Web
/// `FlatList` whose `data` prop holds them, newest first, as
/// `{uuid, timestamp, type, username, displayName, profileImageUrl, body, isModerator}`
/// (`type` 1 is a comment). It's read on every change to the page and once a
/// second.
///
/// The page opens that stream (a `fetch` of api.x.com/live-chat) only while
/// the account is live, so `streamWatcher` reports when it opens and closes.
enum XChatScript {
    static let handlerName = "parallaxXChat"
    static let streamHandlerName = "parallaxXChatStream"

    /// One comment as the script reports it.
    struct Comment: Decodable {
        var id: String
        var handle: String
        var name: String
        var avatarURL: String?
        var text: String
        /// Milliseconds since 1970.
        var timestamp: Double
        var isOwner: Bool
        var isModerator: Bool

        var message: ChatMessage {
            ChatMessage(id: "x-\(id)", platform: .x,
                        author: ChatAuthor(id: handle, displayName: name, avatarURL: avatarURL,
                                           isOwner: isOwner, isModerator: isModerator),
                        text: text, timestamp: Date(timeIntervalSince1970: timestamp / 1000))
        }
    }

    /// Runs before X's own scripts so it sees the chat stream's `fetch`.
    static let streamWatcher = """
    (() => {
      const post = (open) => window.webkit.messageHandlers.\(streamHandlerName).postMessage(open);
      const fetch = window.fetch.bind(window);
      window.fetch = async (...args) => {
        const response = await fetch(...args);
        const url = String(args[0]?.url ?? args[0]);
        if (url.includes('/live-chat?') && response.ok && response.body) {
          post(true);
          const reader = response.clone().body.getReader();
          (async () => {
            try { while (!(await reader.read()).done) {} } catch {}
            post(false);
          })();
        }
        return response;
      };
    })();
    """

    static let source = """
    (() => {
      const post = (comment) => window.webkit.messageHandlers.\(handlerName).postMessage(comment);
      const seen = new Set();

      // The chat list's comments, found by walking React's tree down from the
      // chat container to the first `data` prop that holds comments.
      const comments = () => {
        const root = document.querySelector('[data-testid="chatContainer"]');
        const key = root && Object.keys(root).find((k) => k.startsWith('__reactFiber$'));
        if (!key) return null;
        const stack = [root[key].child];
        for (let n = 0; stack.length && n < 5000; n++) {
          const fiber = stack.pop();
          if (!fiber) continue;
          const data = fiber.memoizedProps?.data;
          if (Array.isArray(data) && data[0] && 'uuid' in data[0] && 'body' in data[0]) return data;
          stack.push(fiber.sibling, fiber.child);
        }
        return null;
      };

      const scan = () => {
        const list = comments();
        if (!list) return;
        const host = location.pathname.split('/')[1]?.toLowerCase();
        for (const c of [...list].reverse()) {
          // No username yet means X is still looking up who sent it.
          if (seen.has(c.uuid) || !c.username || (c.type ?? 1) !== 1) continue;
          seen.add(c.uuid);
          post({
            id: String(c.uuid), handle: c.username, name: c.displayName || c.username,
            avatarURL: c.profileImageUrl ?? null, text: c.body ?? '', timestamp: c.timestamp ?? Date.now(),
            isOwner: c.username.toLowerCase() === host, isModerator: !!c.isModerator,
          });
        }
        if (seen.size > 5000) {
          seen.clear();
          list.forEach((c) => seen.add(c.uuid));
        }
      };

      let pending = false;
      new MutationObserver(() => {
        if (pending) return;
        pending = true;
        setTimeout(() => { pending = false; scan(); }, 200);
      }).observe(document, { childList: true, subtree: true });
      setInterval(scan, 1000);
    })();
    """
}
