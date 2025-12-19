// internal/auth/auth.go
package auth

import (
	"time"

	"go.uber.org/zap"
)

// アプリ全体で使う Authenticator のラッパ
type Authenticator struct {
	jwt    *JWTAuthenticator
	logger *zap.Logger
}

func NewAuthenticator(secret string, logger *zap.Logger) *Authenticator {
	return &Authenticator{
		jwt:    NewJWTAuthenticator(secret),
		logger: logger,
	}
}

func (a *Authenticator) ValidateToken(raw string) (string, error) {
	sub, err := a.jwt.Validate(raw)
	if err != nil {
		a.logger.Info("invalid token", zap.String("got", raw), zap.Error(err))
		return "", ErrInvalidToken
	}
	return sub, nil
}

// 開発用: トークン発行をここからも呼べるようにしておく（使うかはお好みで）
func (a *Authenticator) GenerateDevToken(sub string) (string, error) {
	return a.jwt.GenerateToken(sub, 24*60*time.Minute)
}
