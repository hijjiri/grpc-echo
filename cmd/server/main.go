package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"time"

	authv1 "github.com/hijjiri/grpc-echo/api/auth/v1"
	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"
	"github.com/hijjiri/grpc-echo/internal/auth"
	domain_todo "github.com/hijjiri/grpc-echo/internal/domain/todo"
	mysqlrepo "github.com/hijjiri/grpc-echo/internal/infrastructure/mysql"
	grpcadapter "github.com/hijjiri/grpc-echo/internal/interface/grpc"
	todo_usecase "github.com/hijjiri/grpc-echo/internal/usecase/todo"

	_ "github.com/go-sql-driver/mysql"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"
)

//----------------------
// 共通: getenv ヘルパ
//----------------------

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

//----------------------
// Config struct
//----------------------

type DBConfig struct {
	Host     string
	Port     string
	User     string
	Password string
	Name     string
}

type Config struct {
	GRPCAddr             string
	MetricsAddr          string
	DB                   DBConfig
	OTELExporterEndpoint string
	AuthSecret           string

	// 追加：gRPC request timeout
	GRPCRequestTimeout time.Duration
}

// env から Config を読み込む（既存の挙動と齟齬が出ないようにする）
func loadConfig(logger *zap.Logger) Config {
	// timeout は parse が必要なので、まず文字列で読む
	rawTimeout := getenv("GRPC_REQUEST_TIMEOUT", "3s")
	timeout, err := time.ParseDuration(rawTimeout)
	if err != nil {
		// 本番目線：起動失敗にせず、warn して安全なデフォルトに落とす
		logger.Warn("invalid GRPC_REQUEST_TIMEOUT, fallback to 3s",
			zap.String("raw", rawTimeout),
			zap.Error(err),
		)
		timeout = 3 * time.Second
	}

	return Config{
		GRPCAddr:    getenv("GRPC_ADDR", ":50051"),
		MetricsAddr: getenv("METRICS_ADDR", ":9464"),
		DB: DBConfig{
			Host:     getenv("DB_HOST", "127.0.0.1"),
			Port:     getenv("DB_PORT", "3306"),
			User:     getenv("DB_USER", "root"),
			Password: getenv("DB_PASSWORD", "root"),
			Name:     getenv("DB_NAME", "grpcdb"),
		},
		OTELExporterEndpoint: getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "otel-collector:4317"),
		AuthSecret:           getenv("AUTH_SECRET", "my-dev-secret-key"),
		GRPCRequestTimeout:   timeout,
	}
}

//----------------------
// DB 接続 & ヘルスチェック
//----------------------

func buildMySQLDSN(cfg DBConfig) string {
	return fmt.Sprintf(
		"%s:%s@tcp(%s:%s)/%s?parseTime=true&loc=Asia%%2FTokyo&charset=utf8mb4&timeout=5s",
		cfg.User,
		cfg.Password,
		cfg.Host,
		cfg.Port,
		cfg.Name,
	)
}

func pingMySQLWithRetry(ctx context.Context, db *sql.DB, logger *zap.Logger, maxAttempts int, interval time.Duration) error {
	for i := 1; i <= maxAttempts; i++ {
		if err := db.PingContext(ctx); err != nil {
			logger.Warn("failed to ping db",
				zap.Int("attempt", i),
				zap.Int("maxAttempts", maxAttempts),
				zap.Error(err),
			)
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(interval):
				continue
			}
		} else {
			return nil
		}
	}
	return fmt.Errorf("failed to ping db after %d attempts", maxAttempts)
}

//----------------------
// main
//----------------------

func main() {
	// ---- Logger ----
	logger, err := zap.NewProduction()
	if err != nil {
		panic(fmt.Sprintf("failed to init logger: %v", err))
	}
	defer logger.Sync()

	// ---- Config 読み込み ----
	cfg := loadConfig(logger)
	logger.Info("loaded config",
		zap.String("grpc_addr", cfg.GRPCAddr),
		zap.String("metrics_addr", cfg.MetricsAddr),
		zap.String("db_host", cfg.DB.Host),
		zap.String("db_port", cfg.DB.Port),
		zap.String("db_name", cfg.DB.Name),
		zap.String("otel_exporter_endpoint", cfg.OTELExporterEndpoint),
		zap.Duration("grpc_request_timeout", cfg.GRPCRequestTimeout),
	)

	// ---- DB 接続 ----
	dsn := buildMySQLDSN(cfg.DB)
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		logger.Fatal("failed to open db", zap.Error(err))
	}
	defer db.Close()

	ctx := context.Background()

	if err := pingMySQLWithRetry(ctx, db, logger, 20, 3*time.Second); err != nil {
		logger.Fatal("failed to connect db", zap.Error(err))
	}

	logger.Info("connected to MySQL",
		zap.String("host", cfg.DB.Host),
		zap.String("port", cfg.DB.Port),
		zap.String("db", cfg.DB.Name),
	)

	// ---- TxManager ----
	txMgr := mysqlrepo.NewTxManager(db, logger)

	// ---- Auth（JWT）----
	authz := auth.NewAuthenticator(logger, cfg.AuthSecret)

	// ---- gRPC Server + Interceptor ----
	unaryInterceptors := []grpc.UnaryServerInterceptor{
		grpcadapter.NewRecoveryUnaryInterceptor(logger),
		grpcadapter.NewTimeoutUnaryInterceptor(cfg.GRPCRequestTimeout),
		grpcadapter.NewLoggingUnaryInterceptor(logger),
		grpcadapter.NewAuthUnaryInterceptor(logger, authz),
	}

	streamInterceptors := []grpc.StreamServerInterceptor{
		grpcadapter.NewRecoveryStreamInterceptor(logger),
		grpcadapter.NewTimeoutStreamInterceptor(cfg.GRPCRequestTimeout),
		grpcadapter.NewLoggingStreamInterceptor(logger),
	}

	grpcServer := grpc.NewServer(
		grpc.ChainUnaryInterceptor(unaryInterceptors...),
		grpc.ChainStreamInterceptor(streamInterceptors...),
	)

	// ---- Health & Reflection ----
	healthSrv := health.NewServer()
	healthpb.RegisterHealthServer(grpcServer, healthSrv)
	reflection.Register(grpcServer)

	// ---- Todo Service ----
	var repo domain_todo.Repository = mysqlrepo.NewTodoRepository(db, logger)
	uc := todo_usecase.New(repo, txMgr, logger)
	handler := grpcadapter.NewTodoHandler(uc)
	todov1.RegisterTodoServiceServer(grpcServer, handler)

	// ---- Auth Service ----
	authHandler := grpcadapter.NewAuthHandler(logger, cfg.AuthSecret)
	authv1.RegisterAuthServiceServer(grpcServer, authHandler)

	// ---- metrics HTTP サーバ (/metrics) ----
	go func() {
		mux := http.NewServeMux()
		mux.Handle("/metrics", promhttp.Handler())

		logger.Info("metrics server started", zap.String("addr", cfg.MetricsAddr))

		if err := http.ListenAndServe(cfg.MetricsAddr, mux); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("metrics server error", zap.Error(err))
		}
	}()

	// ---- gRPC サーバ listen ----
	lis, err := net.Listen("tcp", cfg.GRPCAddr)
	if err != nil {
		logger.Fatal("failed to listen", zap.String("addr", cfg.GRPCAddr), zap.Error(err))
	}

	logger.Info("gRPC server is starting", zap.String("addr", cfg.GRPCAddr))

	if err := grpcServer.Serve(lis); err != nil {
		logger.Fatal("gRPC server exited with error", zap.Error(err))
	}
}
