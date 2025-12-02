package main

import (
	"log"
	"net"

	echov1 "github.com/hijjiri/grpc-echo/api/echo/v1"
	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"
	"github.com/hijjiri/grpc-echo/internal/server"
	todosrv "github.com/hijjiri/grpc-echo/internal/todo"

	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"
)

func main() {
	lis, err := net.Listen("tcp", ":50051")
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	s := grpc.NewServer()

	// 各サービスの登録
	echov1.RegisterEchoServiceServer(s, server.NewEchoServer())
	todov1.RegisterTodoServiceServer(s, todosrv.NewTodoServer())

	// Health サーバー
	healthServer := health.NewServer()
	healthpb.RegisterHealthServer(s, healthServer)

	// 全体（サービス名空文字）のステータス
	healthServer.SetServingStatus("", healthpb.HealthCheckResponse_SERVING)

	// 各サービス単位のステータス
	healthServer.SetServingStatus(echov1.EchoService_ServiceDesc.ServiceName, healthpb.HealthCheckResponse_SERVING)
	healthServer.SetServingStatus(todov1.TodoService_ServiceDesc.ServiceName, healthpb.HealthCheckResponse_SERVING)

	// Reflection
	reflection.Register(s)

	log.Println("gRPC server (Echo + Todo + Health) listening on :50051")

	if err := s.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
