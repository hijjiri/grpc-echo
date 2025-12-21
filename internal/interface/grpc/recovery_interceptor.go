package grpcadapter

import (
	"context"
	"runtime/debug"

	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Unary 用 Recovery interceptor
func NewRecoveryUnaryInterceptor(logger *zap.Logger) grpc.UnaryServerInterceptor {
	return func(
		ctx context.Context,
		req interface{},
		info *grpc.UnaryServerInfo,
		handler grpc.UnaryHandler,
	) (resp interface{}, err error) {
		defer func() {
			if r := recover(); r != nil {
				logger.Error("panic recovered in unary handler",
					zap.Any("panic", r),
					zap.String("method", info.FullMethod),
					zap.ByteString("stacktrace", debug.Stack()),
				)
				err = status.Error(codes.Internal, "internal error")
			}
		}()

		return handler(ctx, req)
	}
}

// Streaming 用 Recovery interceptor
func NewRecoveryStreamInterceptor(logger *zap.Logger) grpc.StreamServerInterceptor {
	return func(
		srv interface{},
		ss grpc.ServerStream,
		info *grpc.StreamServerInfo,
		handler grpc.StreamHandler,
	) (err error) {
		defer func() {
			if r := recover(); r != nil {
				logger.Error("panic recovered in stream handler",
					zap.Any("panic", r),
					zap.String("method", info.FullMethod),
					zap.ByteString("stacktrace", debug.Stack()),
				)
				err = status.Error(codes.Internal, "internal error")
			}
		}()

		return handler(srv, ss)
	}
}
