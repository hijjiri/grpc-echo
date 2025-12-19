package auth

import (
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

var (
	// 認証エラーをまとめる（Interceptor から判定しやすくするため）
	ErrInvalidToken = errors.New("invalid token")
)

type JWTAuthenticator struct {
	secret []byte
}

// コンストラクタ
func NewJWTAuthenticator(secret string) *JWTAuthenticator {
	return &JWTAuthenticator{
		secret: []byte(secret),
	}
}

// 開発用: トークン発行（cmd/jwt_gen からもこれを使う）
func (a *JWTAuthenticator) GenerateToken(sub string, ttl time.Duration) (string, error) {
	now := time.Now()

	claims := jwt.RegisteredClaims{
		Subject:   sub,
		ExpiresAt: jwt.NewNumericDate(now.Add(ttl)),
		IssuedAt:  jwt.NewNumericDate(now),
	}

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(a.secret)
}

// トークン検証
func (a *JWTAuthenticator) Validate(rawToken string) (string, error) {
	var claims jwt.RegisteredClaims

	parsed, err := jwt.ParseWithClaims(rawToken, &claims, func(token *jwt.Token) (interface{}, error) {
		// HS256 以外は拒否
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
		}
		if token.Method != jwt.SigningMethodHS256 {
			return nil, fmt.Errorf("unexpected signing method: %v", token.Method.Alg())
		}
		return a.secret, nil
	})
	if err != nil {
		return "", ErrInvalidToken
	}
	if !parsed.Valid {
		return "", ErrInvalidToken
	}

	// 期限チェック（jwt ライブラリもやってくれるが念のため）
	if claims.ExpiresAt != nil && time.Now().After(claims.ExpiresAt.Time) {
		return "", ErrInvalidToken
	}

	// subject（ユーザーID相当）を返す
	return claims.Subject, nil
}
