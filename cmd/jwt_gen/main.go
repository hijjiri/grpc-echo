package main

import (
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func main() {
	// 本来は引数とかにするけど、まずは固定値で
	secret := "dev-secret" // auth.defaultSecret と合わせる
	userID := "user-123"   // sub に入れる値

	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"sub": userID,
		"exp": time.Now().Add(24 * time.Hour).Unix(),
	})

	signed, err := token.SignedString([]byte(secret))
	if err != nil {
		panic(err)
	}

	fmt.Println(signed)
}
