package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/leedo/web-imageproxy/internal/proxy"
)

func main() {
	secret := os.Getenv("IMAGOR_SECRET")
	if secret == "" {
		log.Fatal("IMAGOR_SECRET is required")
	}

	h := &proxy.Handler{
		ImagorURL: getenv("IMAGOR_URL", "http://imagor:8000"),
		Secret:    secret,
		Client: &http.Client{
			Timeout: 65 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}

	srv := &http.Server{
		Addr:              getenv("LISTEN", ":5007"),
		Handler:           h,
		ReadHeaderTimeout: 10 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Printf("listening on %s, imagor at %s", srv.Addr, h.ImagorURL)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()

	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Print(err)
	}
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
