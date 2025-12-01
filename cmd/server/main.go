package main

import (
	"log"
	"net"

	echov1 "github.com/hijjiri/grpc-echo/api/echo/v1"
	"github.com/hijjiri/grpc-echo/internal/server"

	"google.golang.org/grpc"
)

func main() {
	// どのアドレスで Listen するか
	lis, err := net.Listen("tcp", ":50051")
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}

	// gRPC サーバー本体
	s := grpc.NewServer()

	// EchoService を登録
	echov1.RegisterEchoServiceServer(s, server.NewEchoServer())

	log.Println("gRPC Echo server listening on :50051")

	// サーバー起動
	if err := s.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
