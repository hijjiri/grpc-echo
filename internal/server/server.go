// internal/server/server.go
package server

import (
	"context"

	echov1 "github.com/hijjiri/grpc-echo/api/echo/v1"
)

// EchoServer はシンプルなエコー用 gRPC サーバー
type EchoServer struct {
	echov1.UnimplementedEchoServiceServer
}

func NewEchoServer() *EchoServer {
	return &EchoServer{}
}

func (s *EchoServer) Echo(ctx context.Context, req *echov1.EchoRequest) (*echov1.EchoResponse, error) {
	return &echov1.EchoResponse{
		Message: req.GetMessage(),
	}, nil
}
