package main

import (
	"context"
	"log"
	"net/http"

	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"

	"github.com/grpc-ecosystem/grpc-gateway/v2/runtime"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func main() {
	ctx := context.Background()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	mux := runtime.NewServeMux()

	// gRPC サーバへの接続設定（ローカルで :50051 が立っている前提）
	opts := []grpc.DialOption{
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	}

	// proto の HTTP オプションに従ってハンドラを登録
	if err := todov1.RegisterTodoServiceHandlerFromEndpoint(
		ctx,
		mux,
		"localhost:50051",
		opts,
	); err != nil {
		log.Fatalf("failed to register gateway: %v", err)
	}

	log.Println("HTTP gateway listening on :8080")
	if err := http.ListenAndServe(":8080", mux); err != nil {
		log.Fatalf("failed to serve http: %v", err)
	}
}
