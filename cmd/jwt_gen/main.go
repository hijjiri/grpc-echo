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
	// サーバと同じシークレットを使う
	secret := getenv("AUTH_SECRET", "my-dev-secret-key")

	// 開発用の固定ユーザー ID（なんでも OK）
	const subject = "user-123"

	token, err := auth.GenerateToken(secret, subject, 24*time.Hour)
	if err != nil {
		// 単純なツールなので雑に panic で OK
		panic(err)
	}

	// 他のスクリプトや curl から使いやすいように、標準出力にそのまま出す
	fmt.Println(token)
}
