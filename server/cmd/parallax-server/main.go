package main

import (
	"log"
	"net/http"
	"os"

	"github.com/bddicken/parallax/server/internal/api"
)

func main() {
	addr := envOr("PARALLAX_ADDR", ":8080")
	token := os.Getenv("PARALLAX_TOKEN")
	if token == "" {
		log.Fatal("PARALLAX_TOKEN must be set")
	}
	log.Printf("parallax-server listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, api.New(token).Handler()))
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
