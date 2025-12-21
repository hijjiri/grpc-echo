package main

import (
	"context"
	"log"
	"net/http"
	"os"

	authv1 "github.com/hijjiri/grpc-echo/api/auth/v1"
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

	// gRPC サーバのアドレス（ローカル: localhost:50051, k8s: grpc-echo:50051）
	grpcAddr := getenv("GRPC_SERVER_ADDR", "localhost:50051")
	// HTTP の Listen アドレス（デフォルト :8081）
	httpAddr := getenv("HTTP_LISTEN_ADDR", ":8081")

	// --- gRPC-Gateway Mux ---
	gwMux := runtime.NewServeMux()

	opts := []grpc.DialOption{
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	}

	// TodoService のハンドラ登録 (/v1/... 系)
	if err := todov1.RegisterTodoServiceHandlerFromEndpoint(
		ctx,
		gwMux,
		grpcAddr,
		opts,
	); err != nil {
		log.Fatalf("failed to register todo gateway: %v", err)
	}

	// AuthService のハンドラ登録 (/auth/login)
	if err := authv1.RegisterAuthServiceHandlerFromEndpoint(
		ctx,
		gwMux,
		grpcAddr,
		opts,
	); err != nil {
		log.Fatalf("failed to register auth gateway: %v", err)
	}

	// ルート用 mux （/healthz と Gateway を共存）
	rootMux := http.NewServeMux()

	// gRPC-Gateway (REST エンドポイント: /v1/..., /auth/...)
	rootMux.Handle("/", gwMux)

	// /healthz (k8s の liveness/readinessProbe 用)
	rootMux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	// CORS 設定
	handler := cors.New(cors.Options{
		AllowedOrigins:   []string{"http://localhost:5173"},
		AllowedMethods:   []string{"GET", "POST", "PATCH", "DELETE", "OPTIONS"},
		AllowedHeaders:   []string{"Content-Type", "Authorization"},
		AllowCredentials: true,
	}).Handler(rootMux)

	log.Printf("HTTP gateway listening on %s (grpc=%s)", httpAddr, grpcAddr)

	if err := http.ListenAndServe(httpAddr, handler); err != nil {
		log.Fatalf("failed to serve http: %v", err)
	}
}
