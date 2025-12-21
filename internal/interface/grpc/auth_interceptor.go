package grpcadapter

import (
	"context"
	"strings"

	"github.com/hijjiri/grpc-echo/internal/auth"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

// Unary 用 Auth interceptor
// cmd/server/main.go からは：grpcadapter.NewAuthUnaryInterceptor(logger, authz)
// と呼ばれる想定（authz は *auth.Authenticator）。
func NewAuthUnaryInterceptor(logger *zap.Logger, authz *auth.Authenticator) grpc.UnaryServerInterceptor {
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

		raw := md.Get("authorization")
		if len(raw) == 0 {
			return nil, status.Error(codes.Unauthenticated, "authorization header not found")
		}

		logger.Info("got authorization header", zap.String("raw", raw[0]))

		parts := strings.SplitN(raw[0], " ", 2)
		if len(parts) != 2 || !strings.EqualFold(parts[0], "bearer") {
			return nil, status.Error(codes.Unauthenticated, "invalid authorization header format")
		}

		token := parts[1]

		// ★ ここで Authenticator 経由で JWT を検証し、sub（userID）を取り出す
		sub, err := authz.Authenticate(token)
		if err != nil {
			logger.Info("invalid token",
				zap.String("got", token),
				zap.Error(err),
			)
			return nil, status.Error(codes.Unauthenticated, "invalid token")
		}

		// userID を context に埋め込む
		ctxWithUser := WithUserID(ctx, sub)

		return handler(ctxWithUser, req)
	}
}

// Stream 用 Auth interceptor
func NewAuthStreamInterceptor(logger *zap.Logger, authz *auth.Authenticator) grpc.StreamServerInterceptor {
	return func(
		srv interface{},
		ss grpc.ServerStream,
		info *grpc.StreamServerInfo,
		handler grpc.StreamHandler,
	) error {
		md, ok := metadata.FromIncomingContext(ss.Context())
		if !ok {
			return status.Error(codes.Unauthenticated, "missing metadata")
		}

		raw := md.Get("authorization")
		if len(raw) == 0 {
			return status.Error(codes.Unauthenticated, "authorization header not found")
		}

		logger.Info("got authorization header (stream)", zap.String("raw", raw[0]))

		parts := strings.SplitN(raw[0], " ", 2)
		if len(parts) != 2 || !strings.EqualFold(parts[0], "bearer") {
			return status.Error(codes.Unauthenticated, "invalid authorization header format")
		}

		token := parts[1]

		sub, err := authz.Authenticate(token)
		if err != nil {
			logger.Info("invalid token (stream)",
				zap.String("got", token),
				zap.Error(err),
			)
			return status.Error(codes.Unauthenticated, "invalid token")
		}

		// userID を context に埋め込んだ新しい ctx を作る
		ctxWithUser := WithUserID(ss.Context(), sub)

		// ctx を差し替えるラッパーで包んで handler に渡す
		wrapped := &serverStreamWithContext{
			ServerStream: ss,
			ctx:          ctxWithUser,
		}

		return handler(srv, wrapped)
	}
}

// context を差し替えるためのラッパー
type serverStreamWithContext struct {
	grpc.ServerStream
	ctx context.Context
}

func (w *serverStreamWithContext) Context() context.Context {
	return w.ctx
}
