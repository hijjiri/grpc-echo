package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"

	"github.com/grpc-ecosystem/grpc-gateway/v2/runtime"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Authorization を必ず gRPC メタデータに通す
	mux := runtime.NewServeMux(
		runtime.WithIncomingHeaderMatcher(customHeaderMatcher),
	)

	grpcEndpoint := getenv("GRPC_ADDR", "localhost:50051")
	opts := []grpc.DialOption{
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	}

	if err := todov1.RegisterTodoServiceHandlerFromEndpoint(
		ctx,
		mux,
		grpcEndpoint,
		opts,
	); err != nil {
		log.Fatalf("failed to register gateway: %v", err)
	}

	// CORS ラッパー
	handler := withCORS(mux)

	addr := getenv("HTTP_ADDR", ":8081")
	log.Printf("HTTP gateway listening on %s (grpc=%s)", addr, grpcEndpoint)

	srv := &http.Server{
		Addr:         addr,
		Handler:      handler,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("gateway server error: %v", err)
	}
}

// Authorization を通すためのヘッダマッチャー
func customHeaderMatcher(key string) (string, bool) {
	switch strings.ToLower(key) {
	case "authorization":
		return "authorization", true
	default:
		return runtime.DefaultHeaderMatcher(key)
	}
}

// CORS
func withCORS(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "http://localhost:5173")
		w.Header().Set("Access-Control-Allow-Credentials", "true")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type,Authorization")
		w.Header().Set("Access-Control-Allow-Methods", "GET,POST,PATCH,DELETE,OPTIONS")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}
