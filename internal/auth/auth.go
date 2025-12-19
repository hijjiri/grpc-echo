package auth

import (
	"context"
	"errors"
	"os"

	"go.uber.org/zap"
)

type ctxUserKey struct{}

const defaultToken = "abc123"

// クライアントに返したい代表的なエラー
var ErrInvalidToken = errors.New("invalid token")

// 認証インターフェース
type Authenticator interface {
	Authenticate(ctx context.Context, rawToken string) (context.Context, error)
}

// 単純な「トークン文字列一致チェック」版
type SimpleAuthenticator struct {
	logger     *zap.Logger
	validToken string
}

func NewSimpleAuthenticator(logger *zap.Logger, validToken string) *SimpleAuthenticator {
	return &SimpleAuthenticator{
		logger:     logger,
		validToken: validToken,
	}
}

// 環境変数から Authenticator を作る
// AUTH_SECRET が空なら "abc123" をデフォルトとして使う
func NewAuthenticatorFromEnv(logger *zap.Logger) Authenticator {
	token := os.Getenv("AUTH_SECRET")
	if token == "" {
		token = defaultToken
		logger.Warn("AUTH_SECRET not set, using default token",
			zap.String("token", token))
	}
	return NewSimpleAuthenticator(logger, token)
}

// 実際の認証処理
func (a *SimpleAuthenticator) Authenticate(ctx context.Context, rawToken string) (context.Context, error) {
	if rawToken == "" {
		return ctx, ErrInvalidToken
	}

	if rawToken != a.validToken {
		a.logger.Info("invalid token",
			zap.String("got", rawToken))
		return ctx, ErrInvalidToken
	}

	// デモ用に userID を context に入れておく
	ctx = context.WithValue(ctx, ctxUserKey{}, "demo-user")
	return ctx, nil
}

// ハンドラ側から userID を取り出したくなったとき用
func UserIDFromContext(ctx context.Context) (string, bool) {
	v := ctx.Value(ctxUserKey{})
	if v == nil {
		return "", false
	}
	id, ok := v.(string)
	return id, ok
}
