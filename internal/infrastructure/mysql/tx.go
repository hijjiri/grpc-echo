package mysql

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

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

// Tx リトライ設定（本番寄り：短く・回数少なめ）
type TxRetryPolicy struct {
	MaxAttempts int
	BaseBackoff time.Duration
	MaxBackoff  time.Duration
}

// デフォルト：deadlock/lock wait timeout だけを狙って軽くリトライ
var DefaultTxRetry = TxRetryPolicy{
	MaxAttempts: 3,
	BaseBackoff: 50 * time.Millisecond,
	MaxBackoff:  500 * time.Millisecond,
}

// WithinTx は「ctx を引き継いだトランザクション」を開始し、fn をその中で実行する。
// fn 内では、ctx から Tx が見えるようになる（Repository 側で自動的に切り替え）。
//
// 追加仕様（本番目線）:
// - deadlock / lock wait timeout 等 “Tx をやり直せば治る系” だけ Tx 全体を再試行
// - commit 失敗は結果が不明になり得るため自動リトライしない（事故防止）
func (m *TxManager) WithinTx(ctx context.Context, fn func(ctx context.Context) error) error {
	p := DefaultTxRetry
	if p.MaxAttempts <= 0 {
		p.MaxAttempts = 1
	}
	if p.BaseBackoff <= 0 {
		p.BaseBackoff = 10 * time.Millisecond
	}
	if p.MaxBackoff <= 0 {
		p.MaxBackoff = 200 * time.Millisecond
	}

	var lastErr error

	for attempt := 1; attempt <= p.MaxAttempts; attempt++ {
		if err := ctx.Err(); err != nil {
			return err
		}

		tx, err := m.db.BeginTx(ctx, nil)
		if err != nil {
			// begin 失敗はリトライ可能性があるが、まずは Tx リトライ条件に乗るものだけ
			lastErr = fmt.Errorf("begin tx: %w", err)
			if attempt == p.MaxAttempts || !isRetryableTxErr(lastErr) {
				return lastErr
			}
			m.logger.Warn("begin tx failed (retrying)",
				zap.Int("attempt", attempt),
				zap.Int("max_attempts", p.MaxAttempts),
				zap.Error(lastErr),
			)
			if err := sleepWithContext(ctx, backoff(p.BaseBackoff, p.MaxBackoff, attempt)); err != nil {
				return err
			}
			continue
		}

		ctxWithTx := withTx(ctx, tx)

		// fn 実行
		if err := fn(ctxWithTx); err != nil {
			lastErr = err

			// rollback は必須（失敗してもログして返す）
			if rbErr := tx.Rollback(); rbErr != nil && !errors.Is(rbErr, sql.ErrTxDone) {
				m.logger.Error("failed to rollback tx", zap.Error(rbErr))
				// rollback できてない場合は状態が怪しいのでリトライせず返す
				return lastErr
			}

			// retryable な Tx エラーだけ再試行
			if attempt == p.MaxAttempts || !isRetryableTxErr(lastErr) {
				return lastErr
			}

			m.logger.Warn("tx failed (retrying)",
				zap.Int("attempt", attempt),
				zap.Int("max_attempts", p.MaxAttempts),
				zap.Error(lastErr),
			)

			if err := sleepWithContext(ctx, backoff(p.BaseBackoff, p.MaxBackoff, attempt)); err != nil {
				return err
			}
			continue
		}

		// commit（ここは“結果不明”になり得るので自動リトライしない）
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("commit tx: %w", err)
		}

		return nil
	}

	return lastErr
}

// Tx リトライは “Tx を貼り直してやり直せば治る系” に限定する（本番目線）。
func isRetryableTxErr(err error) bool {
	// ctx 系はリトライしない
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return false
	}

	msg := strings.ToLower(err.Error())

	// MySQL で典型的に Tx リトライするやつ
	if strings.Contains(msg, "deadlock") {
		return true
	}
	if strings.Contains(msg, "lock wait timeout") {
		return true
	}

	// begin 時の一時的エラーや接続揺れは retry.go に寄せる（ただし commit はリトライしない）
	return isRetryableDBErr(err)
}
