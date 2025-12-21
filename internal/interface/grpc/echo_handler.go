package grpcadapter

import (
	"context"

	echov1 "github.com/hijjiri/grpc-echo/api/echo/v1"
	echo_usecase "github.com/hijjiri/grpc-echo/internal/usecase/echo"
)

// EchoService の実装
type EchoHandler struct {
	echov1.UnimplementedEchoServiceServer
	uc echo_usecase.Usecase
}

func NewEchoHandler(uc echo_usecase.Usecase) *EchoHandler {
	return &EchoHandler{uc: uc}
}

func (h *EchoHandler) Echo(ctx context.Context, req *echov1.EchoRequest) (*echov1.EchoResponse, error) {
	msg, err := h.uc.Echo(ctx, req.GetMessage())
	if err != nil {
		// いまは特別なエラーは無いので default ハンドリングで OK
		return nil, toGRPCError(err)
	}

	return &echov1.EchoResponse{
		Message: msg,
	}, nil
}
