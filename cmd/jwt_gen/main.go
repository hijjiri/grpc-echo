package main

import (
	"fmt"
	"os"
	"time"

	"github.com/hijjiri/grpc-echo/internal/auth"
)

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	secret := getenv("AUTH_SECRET", "my-dev-secret-key")
	// デフォルトの subject は以前と同じ user-123 にしておく
	subject := getenv("JWT_SUBJECT", "user-123")
	ttl := 24 * time.Hour

	token, err := auth.GenerateToken(secret, subject, ttl)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to generate token: %v\n", err)
		os.Exit(1)
	}

	// Makefile の `make jwt` 用に、標準出力にはトークンだけを出す
	fmt.Print(token)
}
