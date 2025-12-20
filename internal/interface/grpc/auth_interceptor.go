// internal/interface/grpc/auth_interceptor.go
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

// JWT 認証用の Unary インターセプタ
func NewAuthUnaryInterceptor(logger *zap.Logger, authenticator *auth.Authenticator) grpc.UnaryServerInterceptor {
	return func(
		ctx context.Context,
		req any,
		info *grpc.UnaryServerInfo,
		handler grpc.UnaryHandler,
	) (any, error) {
		// HealthCheck など認証不要なものをここで除外したければこの条件に追加
		if info.FullMethod == "/grpc.health.v1.Health/Check" {
			return handler(ctx, req)
		}

		md, ok := metadata.FromIncomingContext(ctx)
		if !ok {
			return nil, status.Error(codes.Unauthenticated, "missing metadata")
		}

		values := md.Get("authorization")
		if len(values) == 0 {
			return nil, status.Error(codes.Unauthenticated, "missing authorization header")
		}

		raw := values[0]
		logger.Info("got authorization header", zap.String("raw", raw))

		const prefix = "Bearer "
		if !strings.HasPrefix(raw, prefix) {
			return nil, status.Error(codes.Unauthenticated, "invalid authorization header format")
		}

		token := strings.TrimSpace(raw[len(prefix):])
		if token == "" {
			return nil, status.Error(codes.Unauthenticated, "invalid authorization header format")
		}

		_, err := authenticator.Authenticate(token)
		if err != nil {
			if errors.Is(err, auth.ErrInvalidToken) {
				return nil, status.Error(codes.Unauthenticated, "invalid token")
			}
			logger.Error("failed to authenticate token", zap.Error(err))
			return nil, status.Error(codes.Internal, "internal error")
		}

		// 認証 OK なのでハンドラへ
		return handler(ctx, req)
	}
}
