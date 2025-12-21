package grpcadapter

import (
	"context"
	"time"

	authv1 "github.com/hijjiri/grpc-echo/api/auth/v1"
	"github.com/hijjiri/grpc-echo/internal/auth"

	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// AuthHandler は AuthService の gRPC 実装。
type AuthHandler struct {
	// ★ これを埋め込むことで mustEmbedUnimplementedAuthServiceServer が満たされる
	authv1.UnimplementedAuthServiceServer

	authSecret string
	logger     *zap.Logger
}

// NewAuthHandler は AuthHandler を初期化するコンストラクタです。
func NewAuthHandler(logger *zap.Logger, authSecret string) *AuthHandler {
	return &AuthHandler{
		authSecret: authSecret,
		logger:     logger,
	}
}

// Login は「username / password を受け取って JWT を返す」シンプル版。
// 本格的なユーザー管理は後続ステップで (DB / ハッシュ化など) やる想定。
func (h *AuthHandler) Login(ctx context.Context, req *authv1.LoginRequest) (*authv1.LoginResponse, error) {
	username := req.GetUsername()
	password := req.GetPassword()

	if username == "" || password == "" {
		return nil, status.Error(codes.InvalidArgument, "username and password are required")
	}

	// ★開発用ダミー認証ロジック
	//   - username: なんでもOK
	//   - password: "password" で固定
	if password != "password" {
		h.logger.Info("login failed (invalid password)",
			zap.String("username", username),
		)
		return nil, status.Error(codes.Unauthenticated, "invalid credentials")
	}

	// JWT の subject には username をそのまま使う。
	subject := username
	ttl := 24 * time.Hour

	token, err := auth.GenerateToken(h.authSecret, subject, ttl)
	if err != nil {
		h.logger.Error("failed to generate jwt",
			zap.String("username", username),
			zap.Error(err),
		)
		return nil, status.Error(codes.Internal, "failed to generate token")
	}

	expiresAt := time.Now().Add(ttl).Unix()

	h.logger.Info("login success",
		zap.String("username", username),
		zap.Int64("expires_at", expiresAt),
	)

	return &authv1.LoginResponse{
		AccessToken: token,
		TokenType:   "Bearer",
		ExpiresAt:   expiresAt,
	}, nil
}
