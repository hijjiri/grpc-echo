package main

import (
	"database/sql"
	"fmt"
	"log"
	"net"
	"os"
	"time"

	echov1 "github.com/hijjiri/grpc-echo/api/echo/v1"
	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"

	_ "github.com/go-sql-driver/mysql"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"

	// クリーンアーキの構成
	domain_todo "github.com/hijjiri/grpc-echo/internal/domain/todo"
	mysqlrepo "github.com/hijjiri/grpc-echo/internal/infrastructure/mysql"
	grpcadapter "github.com/hijjiri/grpc-echo/internal/interface/grpc"
	todo_usecase "github.com/hijjiri/grpc-echo/internal/usecase/todo"

	// Echo は既存の internal/server のまま利用
	"github.com/hijjiri/grpc-echo/internal/server"
)

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {

	// --- DB 接続 ---
	dbHost := getenv("DB_HOST", "127.0.0.1")
	dbPort := getenv("DB_PORT", "3306")
	dbUser := getenv("DB_USER", "app")
	dbPass := getenv("DB_PASSWORD", "app")
	dbName := getenv("DB_NAME", "grpcdb")

	dsn := fmt.Sprintf(
		"%s:%s@tcp(%s:%s)/%s?parseTime=true&charset=utf8mb4&loc=Local",
		dbUser, dbPass, dbHost, dbPort, dbName,
	)

	db, err := sql.Open("mysql", dsn)
	if err != nil {
		log.Fatalf("failed to open db: %v", err)
	}
	defer db.Close()

	// DB 起動待ち
	const maxAttempts = 20
	var pingErr error
	for i := 1; i <= maxAttempts; i++ {
		if pingErr = db.Ping(); pingErr == nil {
			log.Println("connected to MySQL:", dbHost, dbPort, dbName)
			break
		}
		log.Printf("failed to ping db (attempt %d/%d): %v", i, maxAttempts, pingErr)
		time.Sleep(time.Second)
	}
	if pingErr != nil {
		log.Fatalf("failed to ping db after %d attempts: %v", maxAttempts, pingErr)
	}

	// --- gRPC サーバ構築 ---
	grpcServer := grpc.NewServer()

	// Echo Service
	echov1.RegisterEchoServiceServer(grpcServer, server.NewEchoServer())

	// Todo Service（クリーンアーキ）
	var repo domain_todo.Repository = mysqlrepo.NewTodoRepository(db)
	uc := todo_usecase.New(repo)
	handler := grpcadapter.NewTodoHandler(uc)
	todov1.RegisterTodoServiceServer(grpcServer, handler)

	// Healthチェック
	healthServer := health.NewServer()
	healthpb.RegisterHealthServer(grpcServer, healthServer)
	healthServer.SetServingStatus("", healthpb.HealthCheckResponse_SERVING)
	healthServer.SetServingStatus(echov1.EchoService_ServiceDesc.ServiceName, healthpb.HealthCheckResponse_SERVING)
	healthServer.SetServingStatus(todov1.TodoService_ServiceDesc.ServiceName, healthpb.HealthCheckResponse_SERVING)

	// Reflection（grpcurl等で使える）
	reflection.Register(grpcServer)

	// --- 起動 ---
	lis, err := net.Listen("tcp", ":50051")
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	log.Println("gRPC server is running on :50051 (Echo + Todo + Health + MySQL)")

	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
