package grpcadapter

import (
	"context"
	"errors"
	"strings"

	"github.com/hijjiri/grpc-echo/internal/auth"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

// Unary 用の認証インターセプタ
func NewAuthUnaryInterceptor(
	logger *zap.Logger,
	authenticator auth.Authenticator,
) grpc.UnaryServerInterceptor {
	return func(
		ctx context.Context,
		req interface{},
		info *grpc.UnaryServerInfo,
		handler grpc.UnaryHandler,
	) (interface{}, error) {
		md, ok := metadata.FromIncomingContext(ctx)
		if !ok {
			return nil, status.Error(codes.Unauthenticated, "missing metadata")
		}

		values := md.Get("authorization")
		if len(values) == 0 {
			return nil, status.Error(codes.Unauthenticated, "missing authorization header")
		}

		raw := strings.TrimSpace(values[0])
		// "Bearer xxx" 形式ならプレフィックスを剥がす
		lower := strings.ToLower(raw)
		if strings.HasPrefix(lower, "bearer ") {
			raw = strings.TrimSpace(raw[len("bearer "):])
		}

		newCtx, err := authenticator.Authenticate(ctx, raw)
		if err != nil {
			if errors.Is(err, auth.ErrInvalidToken) {
				return nil, status.Error(codes.Unauthenticated, "invalid token")
			}
			logger.Error("authenticator error", zap.Error(err))
			return nil, status.Error(codes.Internal, "auth internal error")
		}

		// 認証 OK → 次のハンドラへ
		return handler(newCtx, req)
	}
}
