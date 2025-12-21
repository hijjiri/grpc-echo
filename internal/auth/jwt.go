package auth

import (
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// GenerateToken は HS256 + MapClaims で JWT を発行する開発用ヘルパです。
// subject ... JWT の sub（今回だと userID / username）
// ttl     ... 有効期限
func GenerateToken(secret string, subject string, ttl time.Duration) (string, error) {
	claims := jwt.MapClaims{
		"sub": subject,
		"exp": time.Now().Add(ttl).Unix(),
		"iat": time.Now().Unix(),
	}

	t := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return t.SignedString([]byte(secret))
}
