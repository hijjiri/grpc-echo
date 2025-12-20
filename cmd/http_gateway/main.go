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
	ctx := context.Background()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	mux := runtime.NewServeMux()

	// ★ 環境変数から gRPC サーバのアドレスを取る（なければローカル用のデフォルト）
	grpcAddr := os.Getenv("GRPC_SERVER_ADDR")
	if grpcAddr == "" {
		grpcAddr = "localhost:50051"
	}

	opts := []grpc.DialOption{
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	}

	// proto の HTTP オプションに従ってハンドラを登録
	if err := todov1.RegisterTodoServiceHandlerFromEndpoint(
		ctx,
		mux,
		grpcAddr,
		opts,
	); err != nil {
		log.Fatalf("failed to register gateway: %v", err)
	}

	// CORS 設定（React フロント用）
	c := cors.New(cors.Options{
		AllowedOrigins:   []string{"http://localhost:5173"},
		AllowedMethods:   []string{"GET", "POST", "PATCH", "DELETE", "OPTIONS"},
		AllowedHeaders:   []string{"Content-Type", "Authorization"},
		AllowCredentials: true,
	})

	handler := c.Handler(mux)

	addr := ":8081"
	log.Printf("HTTP gateway listening on %s (grpc=%s)\n", addr, grpcAddr)

	if err := http.ListenAndServe(addr, handler); err != nil {
		log.Fatalf("failed to serve http: %v", err)
	}
}
