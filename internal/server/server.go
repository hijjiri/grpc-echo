// internal/server/server.go
package server

import (
	"context"
	"log"

	echov1 "github.com/hijjiri/grpc-echo/api/echo/v1"
)

type EchoServer struct {
	echov1.UnimplementedEchoServiceServer
}

func NewEchoServer() *EchoServer {
	return &EchoServer{}
}

func (s *EchoServer) Echo(ctx context.Context, req *echov1.EchoRequest) (*echov1.EchoResponse, error) {
	msg := req.GetMessage()
	log.Printf("received: %s", msg)

	return &echov1.EchoResponse{
		Message: msg,
	}, nil
}
