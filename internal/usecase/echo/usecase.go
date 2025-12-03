// internal/usecase/echo/usecase.go
package echo

import (
	"context"

	"go.uber.org/zap"
)

// Echo のユースケースが満たすインターフェース
type Usecase interface {
	Echo(ctx context.Context, msg string) (string, error)
}

type usecase struct {
	logger *zap.Logger
}

func New(logger *zap.Logger) Usecase {
	return &usecase{logger: logger}
}

func (u *usecase) Echo(ctx context.Context, msg string) (string, error) {
	// ドメインルールをここに書く
	u.logger.Info("echo usecase called", zap.String("msg", msg))

	// 今はそのまま返すだけ
	return msg, nil
}
