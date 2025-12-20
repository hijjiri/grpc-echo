package auth

import (
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// GenerateToken は HS256 で署名された JWT を生成します。
//
// secret  : 署名に使うシークレット（AUTH_SECRET）
// subject : "sub" クレームに入れるユーザーIDなど
// ttl     : 有効期限（現在時刻からの相対時間）
func GenerateToken(secret, subject string, ttl time.Duration) (string, error) {
	now := time.Now()

	claims := jwt.MapClaims{
		"sub": subject,
		"iat": now.Unix(),
		"exp": now.Add(ttl).Unix(),
	}

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString([]byte(secret))
}
