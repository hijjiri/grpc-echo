// internal/auth/auth.go
package auth

import (
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"go.uber.org/zap"
)

// 認証失敗時に使う共通エラー
var ErrInvalidToken = errors.New("invalid token")

// JWT を検証するための構造体
type Authenticator struct {
	logger *zap.Logger
	secret []byte
}

// コンストラクタ
func NewAuthenticator(logger *zap.Logger, secret string) *Authenticator {
	return &Authenticator{
		logger: logger,
		secret: []byte(secret),
	}
}

// Authorization ヘッダに載ってきた生のトークンを検証する
// 正常なら subject(ここでは "sub" クレーム) を返す
func (a *Authenticator) Authenticate(rawToken string) (string, error) {
	token, err := jwt.Parse(rawToken, func(t *jwt.Token) (any, error) {
		// HS256 以外は弾く
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
		}
		return a.secret, nil
	})
	if err != nil {
		a.logger.Info("invalid token", zap.String("got", rawToken), zap.Error(err))
		return "", ErrInvalidToken
	}
	if !token.Valid {
		a.logger.Info("invalid token (not valid)", zap.String("got", rawToken))
		return "", ErrInvalidToken
	}

	claims, ok := token.Claims.(jwt.MapClaims)
	if !ok {
		a.logger.Info("invalid token claims type", zap.String("got", rawToken))
		return "", ErrInvalidToken
	}

	// exp チェック（念のため）
	if v, ok := claims["exp"]; ok {
		switch exp := v.(type) {
		case float64:
			if time.Now().Unix() > int64(exp) {
				a.logger.Info("token expired", zap.Any("exp", exp))
				return "", ErrInvalidToken
			}
		}
	}

	sub, _ := claims["sub"].(string)
	return sub, nil
}
