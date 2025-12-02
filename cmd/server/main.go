package main

import (
	"log"
	"net"

	echov1 "github.com/hijjiri/grpc-echo/api/echo/v1"
	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"
	"github.com/hijjiri/grpc-echo/internal/server"
	todosrv "github.com/hijjiri/grpc-echo/internal/todo"

	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
)

func main() {
	lis, err := net.Listen("tcp", ":50051")
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	s := grpc.NewServer()

	// 既存サービスの登録
	echov1.RegisterEchoServiceServer(s, server.NewEchoServer())
	todov1.RegisterTodoServiceServer(s, todosrv.NewTodoServer())

	// ★ ここで reflection を有効化
	reflection.Register(s)

	log.Println("gRPC server (Echo + Todo) listening on :50051")

	if err := s.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
