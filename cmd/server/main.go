package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/go-sql-driver/mysql"

	echov1 "github.com/hijjiri/grpc-echo/api/echo/v1"
	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"

	"github.com/hijjiri/grpc-echo/internal/auth"
	domain_todo "github.com/hijjiri/grpc-echo/internal/domain/todo"
	mysqlrepo "github.com/hijjiri/grpc-echo/internal/infrastructure/mysql"
	grpcadapter "github.com/hijjiri/grpc-echo/internal/interface/grpc"
	echo_usecase "github.com/hijjiri/grpc-echo/internal/usecase/echo"
	todo_usecase "github.com/hijjiri/grpc-echo/internal/usecase/todo"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"

	otlptracegrpc "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	otelprom "go.opentelemetry.io/otel/exporters/prometheus"

	"go.uber.org/zap"

	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"
)

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	// ---------- Logger ----------
	logger, err := zap.NewProduction()
	if err != nil {
		panic(fmt.Sprintf("failed to init logger: %v", err))
	}
	defer logger.Sync()

	ctx := context.Background()

	// ---------- Tracer ----------
	tp, err := initTracer(ctx, logger)
	if err != nil {
		logger.Fatal("failed to init tracer", zap.Error(err))
	}
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := tp.Shutdown(shutdownCtx); err != nil {
			logger.Warn("failed to shutdown tracer provider", zap.Error(err))
		}
	}()

	// ---------- Metrics ----------
	mp, metricsSrv, err := initMetrics(logger)
	if err != nil {
		logger.Fatal("failed to init metrics", zap.Error(err))
	}
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := mp.Shutdown(shutdownCtx); err != nil {
			logger.Warn("failed to shutdown meter provider", zap.Error(err))
		}
		if err := metricsSrv.Shutdown(shutdownCtx); err != nil && err != http.ErrServerClosed {
			logger.Warn("failed to shutdown metrics http server", zap.Error(err))
		}
	}()

	// ---------- DB 接続 ----------
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

	// ---------- Authenticator & Interceptors ----------
	// 認証の初期化
	authSecret := getenv("AUTH_SECRET", "my-dev-secret-key")
	authz := auth.NewAuthenticator(logger, authSecret)

	unaryInterceptors := []grpc.UnaryServerInterceptor{
		grpcadapter.NewRecoveryUnaryInterceptor(logger),
		grpcadapter.NewLoggingUnaryInterceptor(logger),
		grpcadapter.NewAuthUnaryInterceptor(logger, authz),
	}

	streamInterceptors := []grpc.StreamServerInterceptor{
		grpcadapter.NewRecoveryStreamInterceptor(logger),
		grpcadapter.NewLoggingStreamInterceptor(logger),
		grpcadapter.NewAuthStreamInterceptor(logger, authz),
	}

	// ---------- gRPC Server ----------
	grpcServer := grpc.NewServer(
		grpc.ChainUnaryInterceptor(unaryInterceptors...),
		grpc.ChainStreamInterceptor(streamInterceptors...),
	)

	// ---------- Echo Service ----------
	echoUC := echo_usecase.New(logger)
	echoHandler := grpcadapter.NewEchoHandler(echoUC)
	echov1.RegisterEchoServiceServer(grpcServer, echoHandler)

	// ---------- Todo Service ----------
	var repo domain_todo.Repository = mysqlrepo.NewTodoRepository(db, logger)
	uc := todo_usecase.New(repo, logger)
	handler := grpcadapter.NewTodoHandler(uc)
	todov1.RegisterTodoServiceServer(grpcServer, handler)

	// ---------- Health チェック ----------
	healthServer := health.NewServer()
	healthpb.RegisterHealthServer(grpcServer, healthServer)
	healthServer.SetServingStatus("", healthpb.HealthCheckResponse_SERVING)
	healthServer.SetServingStatus(echov1.EchoService_ServiceDesc.ServiceName, healthpb.HealthCheckResponse_SERVING)
	healthServer.SetServingStatus(todov1.TodoService_ServiceDesc.ServiceName, healthpb.HealthCheckResponse_SERVING)

	// ---------- Reflection ----------
	reflection.Register(grpcServer)

	// ---------- gRPC Listen ----------
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

	// ---------- Shutdown 処理 ----------
	<-ctx.Done()
	logger.Info("shutdown signal received")

	stopped := make(chan struct{})
	go func() {
		grpcServer.GracefulStop()
		close(stopped)
	}()

	const shutdownTimeout = 10 * time.Second
	select {
	case <-stopped:
		logger.Info("gRPC server graceful stop completed")
	case <-time.After(shutdownTimeout):
		logger.Warn("graceful stop timeout; forcing stop")
		grpcServer.Stop()
	}

	if err := db.Close(); err != nil {
		logger.Warn("failed to close db", zap.Error(err))
	} else {
		logger.Info("db connection closed")
	}

	logger.Info("server shutdown completed")
}

// ---------- Tracer 初期化 ----------
func initTracer(ctx context.Context, logger *zap.Logger) (*sdktrace.TracerProvider, error) {
	endpoint := getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317")

	exp, err := otlptracegrpc.New(
		ctx,
		otlptracegrpc.WithEndpoint(endpoint),
		otlptracegrpc.WithInsecure(),
	)
	if err != nil {
		logger.Error("failed to create otlp exporter", zap.Error(err))
		return nil, err
	}

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
	otel.SetTextMapPropagator(propagation.TraceContext{})

	return tp, nil
}

// ---------- Metrics 初期化 ----------
func initMetrics(logger *zap.Logger) (*sdkmetric.MeterProvider, *http.Server, error) {
	// Prometheus用レジストリ
	reg := prometheus.NewRegistry()

	// OTEL → Prometheus Exporter
	exp, err := otelprom.New(
		otelprom.WithRegisterer(reg),
	)
	if err != nil {
		logger.Error("failed to create prometheus exporter", zap.Error(err))
		return nil, nil, err
	}

	// MeterProvider 作成
	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(exp),
	)

	otel.SetMeterProvider(mp)

	// /metrics を公開する HTTP サーバ
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{}))

	srv := &http.Server{
		Addr:    ":9464", // Prometheus がよく使うポート
		Handler: mux,
	}

	// バックグラウンドで起動
	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("metrics http server error", zap.Error(err))
		}
	}()

	logger.Info("metrics server started", zap.String("addr", srv.Addr))
	return mp, srv, nil
}
