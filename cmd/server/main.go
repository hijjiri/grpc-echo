package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	echov1 "github.com/hijjiri/grpc-echo/api/echo/v1"
	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"

	_ "github.com/go-sql-driver/mysql"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"

	// クリーンアーキの構成
	domain_todo "github.com/hijjiri/grpc-echo/internal/domain/todo"
	mysqlrepo "github.com/hijjiri/grpc-echo/internal/infrastructure/mysql"
	grpcadapter "github.com/hijjiri/grpc-echo/internal/interface/grpc"
	todo_usecase "github.com/hijjiri/grpc-echo/internal/usecase/todo"

	// Echo は既存の internal/server のまま利用
	"github.com/hijjiri/grpc-echo/internal/server"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/stdout/stdouttrace"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.uber.org/zap"

	otelgrpc "go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
)

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	logger, err := zap.NewProduction()
	if err != nil {
		panic(fmt.Sprintf("failed to init logger: %v", err))
	}
	defer logger.Sync()

	ctx := context.Background()
	tp, err := initTracer(ctx, logger)
	if err != nil {
		logger.Fatal("failed to init tracer", zap.Error(err))
	}
	// シャットダウン時にフラッシュ
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := tp.Shutdown(shutdownCtx); err != nil {
			logger.Warn("failed to shutdown tracer provider", zap.Error(err))
		}
	}()

	// --- DB 接続 ---
	dbHost := getenv("DB_HOST", "127.0.0.1")
	dbPort := getenv("DB_PORT", "3306")
	dbUser := getenv("DB_USER", "app")
	dbPass := getenv("DB_PASSWORD", "app")
	dbName := getenv("DB_NAME", "grpcdb")

	dsn := fmt.Sprintf(
		"%s:%s@tcp(%s:%s)/%s?parseTime=true&charset=utf8mb4&loc=Local",
		dbUser,
		dbPass,
		dbHost,
		dbPort,
		dbName,
	)

	db, err := sql.Open("mysql", dsn)
	if err != nil {
		logger.Fatal("failed to open db", zap.Error(err))
	}

	// DB 起動待ち
	const maxAttempts = 20
	var pingErr error
	for i := 1; i <= maxAttempts; i++ {
		if pingErr = db.Ping(); pingErr == nil {
			logger.Info("connected to MySQL",
				zap.String("host", dbHost),
				zap.String("port", dbPort),
				zap.String("db", dbName),
			)
			break
		}
		logger.Warn("failed to ping db",
			zap.Int("attempt", i),
			zap.Int("maxAttempts", maxAttempts),
			zap.Error(pingErr),
		)
		time.Sleep(time.Second)
	}
	if pingErr != nil {
		logger.Fatal("failed to ping db after max attempts",
			zap.Int("maxAttempts", maxAttempts),
			zap.Error(pingErr),
		)
	}

	// --- gRPC サーバ構築 ---
	grpcServer := grpc.NewServer(
		// OpenTelemetry: StatsHandler で計装
		grpc.StatsHandler(otelgrpc.NewServerHandler()),

		// いつものログインターセプタ
		grpc.ChainUnaryInterceptor(
			grpcadapter.NewLoggingUnaryInterceptor(logger),
		),
		grpc.ChainStreamInterceptor(
			grpcadapter.NewLoggingStreamInterceptor(logger),
		),
	)

	// Echo Service
	echov1.RegisterEchoServiceServer(grpcServer, server.NewEchoServer())

	// Todo Service（クリーンアーキ）
	var repo domain_todo.Repository = mysqlrepo.NewTodoRepository(db, logger)
	uc := todo_usecase.New(repo, logger)
	handler := grpcadapter.NewTodoHandler(uc)
	todov1.RegisterTodoServiceServer(grpcServer, handler)

	// Healthチェック
	healthServer := health.NewServer()
	healthpb.RegisterHealthServer(grpcServer, healthServer)
	healthServer.SetServingStatus("", healthpb.HealthCheckResponse_SERVING)
	healthServer.SetServingStatus(echov1.EchoService_ServiceDesc.ServiceName, healthpb.HealthCheckResponse_SERVING)
	healthServer.SetServingStatus(todov1.TodoService_ServiceDesc.ServiceName, healthpb.HealthCheckResponse_SERVING)

	// Reflection（grpcurl等で使える）
	reflection.Register(grpcServer)

	// --- 起動 ---
	lis, err := net.Listen("tcp", ":50051")
	if err != nil {
		logger.Fatal("failed to listen", zap.Error(err))
	}

	// OS シグナルを受け取るコンテキスト
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// サーバ起動
	go func() {
		logger.Info("gRPC server is starting",
			zap.String("addr", ":50051"),
		)

		if err := grpcServer.Serve(lis); err != nil && !errors.Is(err, grpc.ErrServerStopped) {
			// GracefulStop のときは ErrServerStopped が返るので、それ以外だけエラー扱い
			logger.Error("gRPC server stopped with error", zap.Error(err))
		}
	}()

	// ---- ここから Shutdown 処理 ----

	// シグナルを待つ（Ctrl+C や SIGTERM）
	<-ctx.Done()
	logger.Info("shutdown signal received")

	// 新規リクエスト受付を止めて、実行中 RPC の終了を待つ
	stopped := make(chan struct{})
	go func() {
		grpcServer.GracefulStop()
		close(stopped)
	}()

	// 一定時間待っても終わらなければ強制終了
	const shutdownTimeout = 10 * time.Second
	select {
	case <-stopped:
		logger.Info("gRPC server graceful stop completed")
	case <-time.After(shutdownTimeout):
		logger.Warn("graceful stop timeout; forcing stop")
		grpcServer.Stop()
	}

	// DB クローズ（defer db.Close() を消して、ここで明示的に）
	if err := db.Close(); err != nil {
		logger.Warn("failed to close db", zap.Error(err))
	} else {
		logger.Info("db connection closed")
	}

	logger.Info("server shutdown completed")
}

func initTracer(ctx context.Context, logger *zap.Logger) (*sdktrace.TracerProvider, error) {
	// stdout に span を吐く exporter
	exp, err := stdouttrace.New(
		stdouttrace.WithPrettyPrint(),
	)
	if err != nil {
		logger.Error("failed to create stdout exporter", zap.Error(err))
		return nil, err
	}

	// このサービスの情報
	res, err := resource.New(ctx,
		resource.WithAttributes(
			attribute.String("service.name", "grpc-echo"),
			attribute.String("service.version", "1.0.0"),
		),
	)
	if err != nil {
		logger.Error("failed to create otel resource", zap.Error(err))
		return nil, err
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp),
		sdktrace.WithResource(res),
	)

	otel.SetTracerProvider(tp)
	// HTTP/gRPC で使われる標準のプロパゲータ
	otel.SetTextMapPropagator(propagation.TraceContext{})

	return tp, nil
}
