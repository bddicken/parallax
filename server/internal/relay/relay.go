// Package relay takes the single stream the client uploads and republishes it
// to every enabled destination.
package relay

import (
	"context"

	"github.com/bddicken/parallax/server/internal/protocol"
)

// Relay fans one ingest stream out to N RTMP(S) destinations without
// re-encoding.
//
// First implementation plan: supervise one `ffmpeg -i <ingest> -c copy -f flv
// <dest>` process per destination (or a single process using the tee muxer),
// restarting with backoff on failure. Replace with a native Go remuxer later if
// process-per-destination becomes a problem.
type Relay interface {
	Start(ctx context.Context, destinations []protocol.Destination) error
	Stop() error
	Status() []protocol.DestinationStatus
}
