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

// 認証をスキップしてよいメソッドかどうかを判定。
// fullMethod 例: "/auth.v1.AuthService/Login"
func isAuthSkippedMethod(fullMethod string) bool {
	// ログイン API は「まだトークンを持っていない」前提なので認証不要
	if strings.HasPrefix(fullMethod, "/auth.v1.AuthService/") {
		return true
	}

	// ヘルスチェックも認証スキップしておくと便利
	if fullMethod == "/grpc.health.v1.Health/Check" {
		return true
	}

	return false
}

// Unary 用 Auth Interceptor
func NewAuthUnaryInterceptor(logger *zap.Logger, authz *auth.Authenticator) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		// ★ AuthService / Health は認証スキップ
		if isAuthSkippedMethod(info.FullMethod) {
			return handler(ctx, req)
		}

		md, _ := metadata.FromIncomingContext(ctx)

		// ---- x-request-id を拾って Context に詰める（あれば）----
		if vals := md.Get("x-request-id"); len(vals) > 0 {
			ctx = WithRequestID(ctx, vals[0])
		}

		// ---- Authorization: Bearer xxx ----
		raw := ""
		if vals := md.Get("authorization"); len(vals) > 0 {
			raw = vals[0]
		}
		logger.Info("got authorization header", zap.String("raw", raw))

		if raw == "" {
			return nil, status.Error(codes.Unauthenticated, "missing authorization header")
		}

		const prefix = "Bearer "
		if !strings.HasPrefix(raw, prefix) {
			return nil, status.Error(codes.Unauthenticated, "invalid authorization header format")
		}

		token := strings.TrimPrefix(raw, prefix)

		// ctx を渡す版 Authenticate（今の実装で OK）
		userID, err := authz.Authenticate(ctx, token)
		if err != nil {
			return nil, status.Error(codes.Unauthenticated, "invalid token")
		}

		// userID を Context に入れて、後続 interceptor / handler が使えるようにする
		ctx = WithUserID(ctx, userID)

		return handler(ctx, req)
	}
}

// ---- Stream 用（Server Streaming / Client Streaming / Bidi 両対応）----

type authStream struct {
	grpc.ServerStream
	ctx context.Context
}

func (s *authStream) Context() context.Context {
	return s.ctx
}

func NewAuthStreamInterceptor(logger *zap.Logger, authz *auth.Authenticator) grpc.StreamServerInterceptor {
	return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
		// ★ AuthService / Health は認証スキップ
		if isAuthSkippedMethod(info.FullMethod) {
			return handler(srv, ss)
		}

		ctx := ss.Context()
		md, _ := metadata.FromIncomingContext(ctx)

		// x-request-id を拾って Context に詰める
		if vals := md.Get("x-request-id"); len(vals) > 0 {
			ctx = WithRequestID(ctx, vals[0])
		}

		// Authorization も metadata から取得
		raw := ""
		if vals := md.Get("authorization"); len(vals) > 0 {
			raw = vals[0]
		}
		logger.Info("got authorization header (stream)", zap.String("raw", raw))

		if raw == "" {
			return status.Error(codes.Unauthenticated, "missing authorization header")
		}

		const prefix = "Bearer "
		if !strings.HasPrefix(raw, prefix) {
			return status.Error(codes.Unauthenticated, "invalid authorization header format")
		}

		token := strings.TrimPrefix(raw, prefix)

		userID, err := authz.Authenticate(ctx, token)
		if err != nil {
			return status.Error(codes.Unauthenticated, "invalid token")
		}

		ctx = WithUserID(ctx, userID)

		// Context を差し替えた ServerStream をラップして次へ
		wrapped := &authStream{
			ServerStream: ss,
			ctx:          ctx,
		}
		return handler(srv, wrapped)
	}
}
