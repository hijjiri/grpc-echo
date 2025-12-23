package grpcadapter

import (
	"context"
	"errors"
	"time"

	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// NewTimeoutUnaryInterceptor は、各 unary RPC にタイムアウトを付与する interceptor。
// - timeout <= 0 の場合は何もしない
// - 既に ctx に deadline がある場合は「より短い方」を優先（上書き事故を防ぐ）
//
// 目的：handler/usecase/repo まで ctx deadline を伝播させ、DB 等のブロックを切る
func NewTimeoutUnaryInterceptor(logger *zap.Logger, timeout time.Duration) grpc.UnaryServerInterceptor {
	if logger == nil {
		logger = zap.NewNop()
	}

	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if timeout <= 0 {
			return handler(ctx, req)
		}

		// 既に deadline があるなら、より短い方を採用
		if dl, ok := ctx.Deadline(); ok {
			remain := time.Until(dl)
			if remain <= timeout {
				return handler(ctx, req)
			}
		}

		ctx2, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()

		resp, err := handler(ctx2, req)

		// タイムアウト時は gRPC の DeadlineExceeded に寄せる（上位で統一）
		if err != nil && errors.Is(err, context.DeadlineExceeded) {
			logger.Warn("request timeout",
				zap.String("method", info.FullMethod),
				zap.Duration("timeout", timeout),
			)
			return nil, status.Error(codes.DeadlineExceeded, "request timeout")
		}

		// ctx が deadline exceeded で落ちた場合でも、err が nil のパターンはほぼ無いが保険
		if err == nil && ctx2.Err() != nil && errors.Is(ctx2.Err(), context.DeadlineExceeded) {
			logger.Warn("request timeout (no handler error)",
				zap.String("method", info.FullMethod),
				zap.Duration("timeout", timeout),
			)
			return nil, status.Error(codes.DeadlineExceeded, "request timeout")
		}

		return resp, err
	}
}
