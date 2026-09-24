// Package api is the control plane the Mac client talks to: destinations,
// broadcast start/stop, chat, and a websocket of live events.
package api

import (
	"encoding/json"
	"net/http"
	"sync"

	"github.com/bddicken/parallax/server/internal/protocol"
)

type Server struct {
	token string

	mu           sync.Mutex
	destinations []protocol.Destination
	status       protocol.BroadcastStatus
}

func New(token string) *Server {
	return &Server{token: token, status: protocol.BroadcastStatus{Destinations: []protocol.DestinationStatus{}}}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.Handle("GET /v1/status", s.auth(s.getStatus))
	mux.Handle("GET /v1/ingest", s.auth(s.notImplemented))
	mux.Handle("GET /v1/destinations", s.auth(s.listDestinations))
	mux.Handle("PUT /v1/destinations", s.auth(s.notImplemented))
	mux.Handle("POST /v1/broadcast/start", s.auth(s.notImplemented))
	mux.Handle("POST /v1/broadcast/stop", s.auth(s.notImplemented))
	mux.Handle("POST /v1/chat/send", s.auth(s.notImplemented))
	mux.Handle("GET /v1/events", s.auth(s.notImplemented)) // websocket upgrade
	return mux
}

func (s *Server) auth(next http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.token == "" || r.Header.Get("Authorization") != "Bearer "+s.token {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	})
}

func (s *Server) getStatus(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	writeJSON(w, s.status)
}

func (s *Server) listDestinations(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]protocol.Destination, len(s.destinations))
	for i, d := range s.destinations {
		d.StreamKey = ""
		out[i] = d
	}
	writeJSON(w, out)
}

func (s *Server) notImplemented(w http.ResponseWriter, r *http.Request) {
	http.Error(w, "not implemented", http.StatusNotImplemented)
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}
