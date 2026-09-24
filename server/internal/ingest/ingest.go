// Package ingest accepts the client's uplink stream.
//
// Plan: SRT listener (caller from the client, H.264 + AAC in MPEG-TS) with the
// stream authenticated by streamid. RTMP is the fallback because it is easier
// to produce from the client, at the cost of worse behaviour on lossy links.
package ingest

import "context"

type Server interface {
	// ListenAndServe accepts one active publisher at a time and exposes it
	// to the relay as a local URL (e.g. udp://127.0.0.1:port or a pipe).
	ListenAndServe(ctx context.Context) error
	Active() bool
}
