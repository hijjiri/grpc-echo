// cmd/jwt_gen/main.go
package main

import (
	"fmt"
	"os"

	"github.com/hijjiri/grpc-echo/internal/auth"
	"go.uber.org/zap"
)

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	logger, _ := zap.NewDevelopment()
	defer logger.Sync()

	// サーバと同じ SECRET を使う（k8s の AUTH_SECRET と合わせる）
	secret := getenv("AUTH_SECRET", "my-dev-secret-key")

	a := auth.NewAuthenticator(secret, logger)

	// ひとまず subject は固定で OK（必要なら引数にしてもよい）
	token, err := a.GenerateDevToken("user-123")
	if err != nil {
		logger.Fatal("failed to generate token", zap.Error(err))
	}

	// そのまま標準出力に 1 行だけ出す
	fmt.Println(token)

	// おまけ: ちゃんと Validate 通るか自己検証
	if _, err := a.ValidateToken(token); err != nil {
		logger.Warn("self validate failed", zap.Error(err))
	}
}
