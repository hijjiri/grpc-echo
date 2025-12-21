package mysql

import (
	"context"
	"database/sql"
	"fmt"

	"go.uber.org/zap"
)

// context にぶら下げる用のキー
type txKey struct{}

// ctx に *sql.Tx を埋め込む（外からは使わない想定なので小文字）
func withTx(ctx context.Context, tx *sql.Tx) context.Context {
	return context.WithValue(ctx, txKey{}, tx)
}

// Repository 側で「この ctx に Tx がぶら下がっているか？」を見るためのヘルパ
func TxFromContext(ctx context.Context) (*sql.Tx, bool) {
	tx, ok := ctx.Value(txKey{}).(*sql.Tx)
	return tx, ok
}

// TxManager は「この DB でトランザクションを貼る」ための小さなラッパ
type TxManager struct {
	db     *sql.DB
	logger *zap.Logger
}

func NewTxManager(db *sql.DB, logger *zap.Logger) *TxManager {
	if logger == nil {
		logger = zap.NewNop()
	}
	return &TxManager{
		db:     db,
		logger: logger,
	}
}

// WithinTx は「ctx を引き継いだトランザクション」を開始し、fn をその中で実行する。
// fn 内では、ctx から Tx が見えるようになる（Repository 側で自動的に切り替え）。
func (m *TxManager) WithinTx(ctx context.Context, fn func(ctx context.Context) error) error {
	tx, err := m.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}

	ctxWithTx := withTx(ctx, tx)

	if err := fn(ctxWithTx); err != nil {
		if rbErr := tx.Rollback(); rbErr != nil {
			m.logger.Error("failed to rollback tx", zap.Error(rbErr))
		}
		return err
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit tx: %w", err)
	}

	return nil
}
