package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"strings"

	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"

	"github.com/grpc-ecosystem/grpc-gateway/v2/runtime"
	"github.com/rs/cors"
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
	ctx := context.Background()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	grpcEndpoint := getenv("GRPC_ENDPOINT", "localhost:50051")

	// Authorization ヘッダを gRPC メタデータに渡すためのヘッダマッチャ
	headerMatcher := func(key string) (string, bool) {
		switch strings.ToLower(key) {
		case "authorization":
			// -> gRPC 側では "authorization" メタデータとして届く
			return "authorization", true
		default:
			return runtime.DefaultHeaderMatcher(key)
		}
	}

	mux := runtime.NewServeMux(
		runtime.WithIncomingHeaderMatcher(headerMatcher),
	)

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

	// CORS 設定：Vite Dev サーバ (http://localhost:5173) から叩けるように
	c := cors.New(cors.Options{
		AllowedOrigins:   []string{"http://localhost:5173"},
		AllowedMethods:   []string{"GET", "POST", "PATCH", "DELETE", "OPTIONS"},
		AllowedHeaders:   []string{"Content-Type", "Authorization"},
		AllowCredentials: true,
	})

	handler := c.Handler(mux)

	addr := ":8081" // 以前 8081 にしていた想定
	log.Printf("HTTP gateway listening on %s (grpc=%s)\n", addr, grpcEndpoint)

	if err := http.ListenAndServe(addr, handler); err != nil {
		log.Fatalf("failed to serve http: %v", err)
	}
}
