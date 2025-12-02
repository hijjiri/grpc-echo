package main

import (
	"log"
	"net"

	echov1 "github.com/hijjiri/grpc-echo/api/echo/v1"
	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"
	"github.com/hijjiri/grpc-echo/internal/server"
	todosrv "github.com/hijjiri/grpc-echo/internal/todo"

	"google.golang.org/grpc"
)

func main() {
	lis, err := net.Listen("tcp", ":50051")
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	s := grpc.NewServer()

	// 既存の EchoService
	echov1.RegisterEchoServiceServer(s, server.NewEchoServer())

	// 追加した TodoService
	todov1.RegisterTodoServiceServer(s, todosrv.NewTodoServer())

	log.Println("gRPC server (Echo + Todo) listening on :50051")

	if err := s.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
