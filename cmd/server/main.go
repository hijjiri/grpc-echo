// cmd/server/main.go
package main

import (
	"database/sql"
	"fmt"
	"log"
	"net"
	"os"

	echov1 "github.com/hijjiri/grpc-echo/api/echo/v1"
	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"
	"github.com/hijjiri/grpc-echo/internal/server"
	todopkg "github.com/hijjiri/grpc-echo/internal/todo"

	_ "github.com/go-sql-driver/mysql"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"
)

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	// --- DB 接続設定 ---
	dbHost := getenv("DB_HOST", "127.0.0.1")
	dbPort := getenv("DB_PORT", "3306")
	dbUser := getenv("DB_USER", "app")
	dbPass := getenv("DB_PASSWORD", "app")
	dbName := getenv("DB_NAME", "grpcdb")

	dsn := fmt.Sprintf(
		"%s:%s@tcp(%s:%s)/%s?parseTime=true&charset=utf8mb4&loc=Local",
		dbUser,
		dbPass,
		dbHost,
		dbPort,
		dbName,
	)

	db, err := sql.Open("mysql", dsn)
	if err != nil {
		log.Fatalf("failed to open db: %v", err)
	}
	defer db.Close()

	if err := db.Ping(); err != nil {
		log.Fatalf("failed to ping db: %v", err)
	}

	log.Println("connected to MySQL:", dbHost, dbPort, dbName)

	// --- gRPC ---
	lis, err := net.Listen("tcp", ":50051")
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	s := grpc.NewServer()

	// Echo
	echov1.RegisterEchoServiceServer(s, server.NewEchoServer())

	// Todo: Repository 経由で MySQL 実装を注入
	todoRepo := todopkg.NewMySQLTodoRepository(db)
	todoServer := todopkg.NewTodoServer(todoRepo)
	todov1.RegisterTodoServiceServer(s, todoServer)

	// Health
	healthServer := health.NewServer()
	healthpb.RegisterHealthServer(s, healthServer)

	healthServer.SetServingStatus("", healthpb.HealthCheckResponse_SERVING)
	healthServer.SetServingStatus(echov1.EchoService_ServiceDesc.ServiceName, healthpb.HealthCheckResponse_SERVING)
	healthServer.SetServingStatus(todov1.TodoService_ServiceDesc.ServiceName, healthpb.HealthCheckResponse_SERVING)

	// Reflection
	reflection.Register(s)

	log.Println("gRPC server (Echo + Todo + Health + MySQL) listening on :50051")

	if err := s.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
