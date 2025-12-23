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

func getenvDuration(key string, def time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return def
	}
	return d
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

	// ★追加：gRPC unary request timeout
	GRPCRequestTimeout time.Duration
}

func loadConfig() Config {
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

		// 例: 3s / 500ms（未設定なら 3s）
		GRPCRequestTimeout: getenvDuration("GRPC_REQUEST_TIMEOUT", 3*time.Second),
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
	logger, err := zap.NewProduction()
	if err != nil {
		panic(fmt.Sprintf("failed to init logger: %v", err))
	}
	defer logger.Sync()

	cfg := loadConfig()
	logger.Info("loaded config",
		zap.String("grpc_addr", cfg.GRPCAddr),
		zap.String("metrics_addr", cfg.MetricsAddr),
		zap.String("db_host", cfg.DB.Host),
		zap.String("db_port", cfg.DB.Port),
		zap.String("db_name", cfg.DB.Name),
		zap.String("otel_exporter_endpoint", cfg.OTELExporterEndpoint),
		zap.Duration("grpc_request_timeout", cfg.GRPCRequestTimeout),
	)

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

	txMgr := mysqlrepo.NewTxManager(db, logger)
	authz := auth.NewAuthenticator(logger, cfg.AuthSecret)

	// ---- gRPC Server + Interceptor ----
	// 推奨順：
	// - Recovery: 最外でパニック保護
	// - Logging: できれば全体計測（timeout も含む）
	// - Timeout: handler/usecase/repo まで deadline を伝播
	// - Auth: 認証（必要なら timeout の内側/外側は好みでOK）
	unaryInterceptors := []grpc.UnaryServerInterceptor{
		grpcadapter.NewRecoveryUnaryInterceptor(logger),
		grpcadapter.NewLoggingUnaryInterceptor(logger),
		grpcadapter.NewTimeoutUnaryInterceptor(logger, cfg.GRPCRequestTimeout),
		grpcadapter.NewAuthUnaryInterceptor(logger, authz),
	}

	streamInterceptors := []grpc.StreamServerInterceptor{
		grpcadapter.NewRecoveryStreamInterceptor(logger),
		grpcadapter.NewLoggingStreamInterceptor(logger),
	}

	grpcServer := grpc.NewServer(
		grpc.ChainUnaryInterceptor(unaryInterceptors...),
		grpc.ChainStreamInterceptor(streamInterceptors...),
	)

	healthSrv := health.NewServer()
	healthpb.RegisterHealthServer(grpcServer, healthSrv)
	reflection.Register(grpcServer)

	var repo domain_todo.Repository = mysqlrepo.NewTodoRepository(db, logger)
	uc := todo_usecase.New(repo, txMgr, logger)
	handler := grpcadapter.NewTodoHandler(uc)
	todov1.RegisterTodoServiceServer(grpcServer, handler)

	authHandler := grpcadapter.NewAuthHandler(logger, cfg.AuthSecret)
	authv1.RegisterAuthServiceServer(grpcServer, authHandler)

	go func() {
		mux := http.NewServeMux()
		mux.Handle("/metrics", promhttp.Handler())

		logger.Info("metrics server started", zap.String("addr", cfg.MetricsAddr))

		if err := http.ListenAndServe(cfg.MetricsAddr, mux); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("metrics server error", zap.Error(err))
		}
	}()

	lis, err := net.Listen("tcp", cfg.GRPCAddr)
	if err != nil {
		logger.Fatal("failed to listen", zap.String("addr", cfg.GRPCAddr), zap.Error(err))
	}

	logger.Info("gRPC server is starting", zap.String("addr", cfg.GRPCAddr))

	if err := grpcServer.Serve(lis); err != nil {
		logger.Fatal("gRPC server exited with error", zap.Error(err))
	}
}
