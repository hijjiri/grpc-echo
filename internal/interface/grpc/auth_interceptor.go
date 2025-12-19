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

func NewAuthUnaryInterceptor(a *auth.Authenticator, logger *zap.Logger) grpc.UnaryServerInterceptor {
	return func(
		ctx context.Context,
		req interface{},
		info *grpc.UnaryServerInfo,
		handler grpc.UnaryHandler,
	) (interface{}, error) {
		// Health / Reflection は認証スキップ
		if strings.HasPrefix(info.FullMethod, "/grpc.health.v1.Health/") ||
			strings.HasPrefix(info.FullMethod, "/grpc.reflection.v1.") {
			return handler(ctx, req)
		}

		md, ok := metadata.FromIncomingContext(ctx)
		if !ok {
			logger.Info("no metadata in context")
			return nil, status.Error(codes.Unauthenticated, "missing metadata")
		}

		// gRPC の MD キーは小文字で持たれるので "authorization"
		vals := md.Get("authorization")
		if len(vals) == 0 {
			logger.Info("missing authorization header", zap.Any("metadata", md))
			return nil, status.Error(codes.Unauthenticated, "missing authorization header")
		}

		raw := strings.TrimSpace(vals[0])
		logger.Info("got authorization header", zap.String("raw", raw))

		// "Bearer <token>" を素直にパース（大文字小文字は無視）
		parts := strings.Fields(raw)
		if len(parts) != 2 || strings.ToLower(parts[0]) != "bearer" {
			logger.Info("invalid authorization header format", zap.String("raw", raw))
			return nil, status.Error(codes.Unauthenticated, "invalid authorization header")
		}
		token := parts[1]

		// JWT 検証
		sub, err := a.ValidateToken(token)
		if err != nil {
			if errors.Is(err, auth.ErrInvalidToken) {
				return nil, status.Error(codes.Unauthenticated, "invalid token")
			}
			logger.Error("token validation error", zap.Error(err))
			return nil, status.Error(codes.Internal, "internal auth error")
		}

		// 必要ならここで sub を context に詰めるが、今は未使用なのでスキップ
		_ = sub

		return handler(ctx, req)
	}
}
