// Package chat aggregates live chat from each platform into a single stream
// and posts replies as the authenticated account.
package chat

import (
	"context"

	"github.com/bddicken/parallax/server/internal/protocol"
)

// Provider is implemented once per platform.
//
// Planned implementations:
//   - YouTube: liveChatMessages.list polling (honouring pollingIntervalMillis)
//     and liveChatMessages.insert for replies. OAuth2, scope youtube.force-ssl.
//   - Twitch: IRC over websocket (irc-ws.chat.twitch.tv) or EventSub; OAuth2.
//   - X: API access for live broadcast chat is limited; investigate before
//     committing to it.
type Provider interface {
	Platform() protocol.Platform
	// Run streams messages into out until ctx is cancelled.
	Run(ctx context.Context, out chan<- protocol.ChatMessage) error
	Send(ctx context.Context, text string) error
}

// Hub fans messages from every provider out to subscribers (client websockets).
type Hub struct {
	providers []Provider
}

func NewHub(providers ...Provider) *Hub { return &Hub{providers: providers} }

// TODO: implement Run (start providers, fan out) and Subscribe.
