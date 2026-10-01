/// Runs in the Suno window so Parallax can see and control Suno's own
/// player. It reads the Media Session metadata Suno publishes for the
/// system's Now Playing (title, artist) and calls the same play/pause/next
/// handlers the keyboard's media keys would, falling back to the page's
/// audio element.
enum SunoPlayerScript {
    static let handlerName = "parallaxMedia"

    /// What the page reports, about once a second while something plays and
    /// whenever anything changes.
    struct State: Decodable, Equatable {
        var title: String?
        var artist: String?
        var playing: Bool
        var position: Double?
        var duration: Double?
        var canSkip: Bool
    }

    enum Action: String {
        case play, pause, nexttrack, previoustrack
    }

    static func perform(_ action: Action) -> String {
        "window.__parallaxMedia && window.__parallaxMedia.perform('\(action.rawValue)')"
    }

    static func seek(to seconds: Double) -> String {
        "window.__parallaxMedia && window.__parallaxMedia.seek(\(seconds))"
    }

    /// Injected at document start, before Suno's code registers its handlers.
    static let source = #"""
    (() => {
      if (window.__parallaxMedia) return;
      const post = (state) => {
        try { window.webkit.messageHandlers.parallaxMedia.postMessage(state); } catch (e) {}
      };
      const handlers = {};
      const session = navigator.mediaSession;
      if (session) {
        const setActionHandler = session.setActionHandler.bind(session);
        session.setActionHandler = (action, handler) => {
          handlers[action] = handler;
          try { setActionHandler(action, handler); } catch (e) {}
        };
      }

      // The element that played most recently is Suno's player.
      let media = null;
      const watch = (element) => {
        media = element;
        if (element.__parallaxWatched) return;
        element.__parallaxWatched = true;
        for (const type of ['play', 'playing', 'pause', 'ended', 'loadedmetadata', 'durationchange', 'emptied']) {
          element.addEventListener(type, () => { media = element; report(); });
        }
      };
      const play = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function () {
        watch(this);
        return play.apply(this, arguments);
      };

      let last = '';
      const report = () => {
        const metadata = session && session.metadata;
        const finite = (n) => (Number.isFinite(n) ? n : null);
        const state = {
          title: (metadata && metadata.title) || null,
          artist: (metadata && metadata.artist) || null,
          playing: !!(media && !media.paused && !media.ended),
          position: media ? finite(media.currentTime) : null,
          duration: media ? finite(media.duration) : null,
          canSkip: !!handlers.nexttrack,
        };
        const key = JSON.stringify(state);
        if (key !== last) { last = key; post(state); }
      };
      setInterval(report, 1000);

      window.__parallaxMedia = {
        perform(action) {
          const handler = handlers[action];
          if (handler) {
            try { handler({ action }); return true; } catch (e) {}
          }
          const element = media || document.querySelector('audio, video');
          if (!element) return false;
          if (action === 'play') element.play();
          else if (action === 'pause') element.pause();
          else return false;
          return true;
        },
        seek(seconds) {
          if (media) media.currentTime = seconds;
        },
      };
    })();
    """#
}
