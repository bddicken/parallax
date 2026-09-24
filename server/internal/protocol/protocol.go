// Package protocol defines the wire types shared between the Parallax client
// and server. The Swift mirror lives in client/Sources/ParallaxRemote/Protocol.swift;
// keep the two in sync. See docs/protocol.md at the repo root.
package protocol

import "time"

type Platform string

const (
	PlatformYouTube Platform = "youtube"
	PlatformX       Platform = "x"
	PlatformTwitch  Platform = "twitch"
	PlatformCustom  Platform = "custom" // arbitrary RTMP(S) target, no chat
)

// Destination is a place the server relays the broadcast to.
type Destination struct {
	ID       string   `json:"id"`
	Platform Platform `json:"platform"`
	Name     string   `json:"name"`
	Enabled  bool     `json:"enabled"`
	// RTMPURL and StreamKey are write-only from the client's perspective;
	// the server never returns StreamKey.
	RTMPURL   string `json:"rtmpURL,omitempty"`
	StreamKey string `json:"streamKey,omitempty"`
}

type DestinationState string

const (
	DestinationIdle       DestinationState = "idle"
	DestinationConnecting DestinationState = "connecting"
	DestinationLive       DestinationState = "live"
	DestinationError      DestinationState = "error"
)

type DestinationStatus struct {
	DestinationID string           `json:"destinationID"`
	State         DestinationState `json:"state"`
	BitrateKbps   int              `json:"bitrateKbps"`
	Error         string           `json:"error,omitempty"`
}

type BroadcastStatus struct {
	Live         bool                `json:"live"`
	IngestActive bool                `json:"ingestActive"`
	StartedAt    *time.Time          `json:"startedAt,omitempty"`
	Destinations []DestinationStatus `json:"destinations"`
}

type ChatAuthor struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	AvatarURL   string `json:"avatarURL,omitempty"`
	IsOwner     bool   `json:"isOwner"`
	IsModerator bool   `json:"isModerator"`
}

type ChatMessage struct {
	ID        string     `json:"id"`
	Platform  Platform   `json:"platform"`
	Author    ChatAuthor `json:"author"`
	Text      string     `json:"text"`
	Timestamp time.Time  `json:"timestamp"`
}

// SendChatRequest posts a message as the authenticated account. An empty
// Platforms list means "every platform that supports chat".
type SendChatRequest struct {
	Text      string     `json:"text"`
	Platforms []Platform `json:"platforms,omitempty"`
}

type StartBroadcastRequest struct {
	DestinationIDs []string `json:"destinationIDs"`
}

// IngestInfo tells the client where to push its single uplink stream.
type IngestInfo struct {
	SRTURL  string `json:"srtURL"`
	RTMPURL string `json:"rtmpURL"`
}

// Event is the envelope for everything pushed over the /v1/events websocket.
type Event struct {
	Type string `json:"type"` // "chat.message" | "broadcast.status"
	Data any    `json:"data"`
}
