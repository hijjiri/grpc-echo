package grpcadapter

import (
	"context"
	"time"

	"google.golang.org/grpc"
)

// wrappedServerStream は stream.Context() を差し替えるための薄いラッパ
type wrappedServerStream struct {
	grpc.ServerStream
	ctx context.Context
}

func (w *wrappedServerStream) Context() context.Context { return w.ctx }

// NewTimeoutUnaryInterceptor は gRPC Unary 全体に timeout を付与する interceptor。
// すでに ctx に deadline が設定されていて、そちらが短い場合は上書きしない。
func NewTimeoutUnaryInterceptor(timeout time.Duration) grpc.UnaryServerInterceptor {
	if timeout <= 0 {
		return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
			return handler(ctx, req)
		}
	}

	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		// 既存 deadline があるなら、それを尊重（短い方を採用）
		if deadline, ok := ctx.Deadline(); ok {
			remain := time.Until(deadline)
			if remain <= timeout {
				return handler(ctx, req)
			}
		}

		ctx2, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()

		return handler(ctx2, req)
	}
}

// NewTimeoutStreamInterceptor は gRPC Stream 全体に timeout を付与する interceptor。
// stream は 1 RPC が長くなりがちなので、必要なら別値に分けてもOK。
func NewTimeoutStreamInterceptor(timeout time.Duration) grpc.StreamServerInterceptor {
	if timeout <= 0 {
		return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
			return handler(srv, ss)
		}
	}

	return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
		// 既存 deadline があるなら、それを尊重（短い方を採用）
		if deadline, ok := ss.Context().Deadline(); ok {
			remain := time.Until(deadline)
			if remain <= timeout {
				return handler(srv, ss)
			}
		}

		ctx2, cancel := context.WithTimeout(ss.Context(), timeout)
		defer cancel()

		return handler(srv, &wrappedServerStream{ServerStream: ss, ctx: ctx2})
	}
}
