package grpcadapter

import (
	"context"
	"time"

	"go.uber.org/zap"
	"google.golang.org/grpc"
)

// ----- Unary -----

func NewLoggingUnaryInterceptor(logger *zap.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		start := time.Now()

		resp, err := handler(ctx, req)

		fields := []zap.Field{
			zap.String("method", info.FullMethod),
			zap.Duration("duration", time.Since(start)),
		}

		if userID, ok := UserIDFromContext(ctx); ok {
			fields = append(fields, zap.String("user_id", userID))
		}
		if rid, ok := RequestIDFromContext(ctx); ok {
			fields = append(fields, zap.String("request_id", rid))
		}

		if err != nil {
			logger.Error("gRPC unary request", append(fields, zap.Error(err))...)
		} else {
			logger.Info("gRPC unary request", fields...)
		}

		return resp, err
	}
}

// ----- Stream -----

func NewLoggingStreamInterceptor(logger *zap.Logger) grpc.StreamServerInterceptor {
	return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
		start := time.Now()
		ctx := ss.Context()

		fields := []zap.Field{
			zap.String("method", info.FullMethod),
		}

		if userID, ok := UserIDFromContext(ctx); ok {
			fields = append(fields, zap.String("user_id", userID))
		}
		if rid, ok := RequestIDFromContext(ctx); ok {
			fields = append(fields, zap.String("request_id", rid))
		}

		err := handler(srv, ss)

		fields = append(fields, zap.Duration("duration", time.Since(start)))

		if err != nil {
			logger.Error("gRPC stream request", append(fields, zap.Error(err))...)
		} else {
			logger.Info("gRPC stream request", fields...)
		}

		return err
	}
}
