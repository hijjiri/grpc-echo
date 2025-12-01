package server

import (
	"context"
	"log"

	echov1 "github.com/hijjiri/grpc-echo/api/echo/v1"
)

// EchoServer は EchoService の実装
type EchoServer struct {
	echov1.UnimplementedEchoServiceServer
}

// コンストラクタっぽいもの
func NewEchoServer() *EchoServer {
	return &EchoServer{}
}

// Echo RPC の実装
func (s *EchoServer) Echo(ctx context.Context, req *echov1.EchoRequest) (*echov1.EchoResponse, error) {
	msg := req.GetMessage()
	log.Printf("received: %s", msg)

	// そのまま返すだけの Echo
	return &echov1.EchoResponse{
		Message: msg,
	}, nil
}
