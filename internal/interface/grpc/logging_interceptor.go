package grpcadapter

import (
	"context"
	"time"

	"go.uber.org/zap"
	"google.golang.org/grpc"
)

// NewLoggingUnaryInterceptor logs unary RPCs with method, duration, error and user_id(あれば).
func NewLoggingUnaryInterceptor(logger *zap.Logger) grpc.UnaryServerInterceptor {
	return func(
		ctx context.Context,
		req interface{},
		info *grpc.UnaryServerInfo,
		handler grpc.UnaryHandler,
	) (interface{}, error) {
		start := time.Now()

		resp, err := handler(ctx, req)

		duration := time.Since(start)

		// context から userID を取り出す（auth_interceptor で WithUserID 済みの想定）
		userID, _ := UserIDFromContext(ctx)

		fields := []zap.Field{
			zap.String("method", info.FullMethod),
			zap.Duration("duration", duration),
		}
		if userID != "" {
			fields = append(fields, zap.String("user_id", userID))
		}

		if err != nil {
			logger.Error("gRPC unary request", append(fields, zap.Error(err))...)
		} else {
			logger.Info("gRPC unary request", fields...)
		}

		return resp, err
	}
}

// NewLoggingStreamInterceptor logs stream RPCs with method, duration, error and user_id(あれば).
func NewLoggingStreamInterceptor(logger *zap.Logger) grpc.StreamServerInterceptor {
	return func(
		srv interface{},
		ss grpc.ServerStream,
		info *grpc.StreamServerInfo,
		handler grpc.StreamHandler,
	) error {
		start := time.Now()

		err := handler(srv, ss)

		duration := time.Since(start)

		// stream から context を取って userID を取得
		ctx := ss.Context()
		userID, _ := UserIDFromContext(ctx)

		fields := []zap.Field{
			zap.String("method", info.FullMethod),
			zap.Duration("duration", duration),
		}
		if userID != "" {
			fields = append(fields, zap.String("user_id", userID))
		}

		if err != nil {
			logger.Error("gRPC stream request", append(fields, zap.Error(err))...)
		} else {
			logger.Info("gRPC stream request", fields...)
		}

		return err
	}
}
