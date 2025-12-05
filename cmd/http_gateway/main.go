package main

import (
	"context"
	"log"
	"net/http"
	"os"

	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"

	"github.com/grpc-ecosystem/grpc-gateway/v2/runtime"
	"github.com/rs/cors"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func main() {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	mux := runtime.NewServeMux()

	// gRPC サーバのエンドポイント（必要なら環境変数で上書き）
	grpcEndpoint := getenv("GRPC_SERVER_ENDPOINT", "localhost:50051")

	opts := []grpc.DialOption{
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	}

	// gRPC-Gateway のハンドラ登録
	if err := todov1.RegisterTodoServiceHandlerFromEndpoint(
		ctx,
		mux,
		grpcEndpoint,
		opts,
	); err != nil {
		log.Fatalf("failed to register gateway: %v", err)
	}

	// CORS 設定（とりあえず全部許可）
	handler := cors.AllowAll().Handler(mux)

	httpAddr := ":8081" // ★ ここを 8081 に変更
	log.Printf("HTTP gateway listening on %s (grpc=%s)\n", httpAddr, grpcEndpoint)
	if err := http.ListenAndServe(httpAddr, handler); err != nil {
		log.Fatalf("failed to serve http: %v", err)
	}
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
