package mysql

import (
	"context"
	"database/sql/driver"
	"errors"
	"net"
	"strings"
	"time"
)

// RetryPolicy は「何回・どのくらい待つか」をまとめた設定。
type RetryPolicy struct {
	MaxAttempts int           // 例: 3（合計3回試す）
	BaseBackoff time.Duration // 例: 50ms
	MaxBackoff  time.Duration // 例: 500ms
}

// DefaultReadRetry は「読み取り（List等）」向けの安全寄りデフォルト。
var DefaultReadRetry = RetryPolicy{
	MaxAttempts: 3,
	BaseBackoff: 50 * time.Millisecond,
	MaxBackoff:  500 * time.Millisecond,
}

// doWithRetry は、retryable なエラーのみをバックオフ付きで再実行する。
// - ctx の deadline/cancel を尊重して即中断する
func doWithRetry(ctx context.Context, policy RetryPolicy, fn func() error) error {
	if policy.MaxAttempts <= 0 {
		policy.MaxAttempts = 1
	}
	if policy.BaseBackoff <= 0 {
		policy.BaseBackoff = 10 * time.Millisecond
	}
	if policy.MaxBackoff <= 0 {
		policy.MaxBackoff = 200 * time.Millisecond
	}

	var lastErr error
	for attempt := 1; attempt <= policy.MaxAttempts; attempt++ {
		// ctx が終了していれば即返す
		if err := ctx.Err(); err != nil {
			return err
		}

		err := fn()
		if err == nil {
			return nil
		}
		lastErr = err

		// retry 対象外なら即返す
		if !isRetryableDBErr(err) {
			return err
		}

		// 最終試行なら返す
		if attempt == policy.MaxAttempts {
			return err
		}

		// backoff
		sleep := backoff(policy.BaseBackoff, policy.MaxBackoff, attempt)
		if err := sleepWithContext(ctx, sleep); err != nil {
			// ctx timeout/cancel
			return err
		}
	}

	return lastErr
}

func sleepWithContext(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// backoff は指数バックオフ（ジッタ無し・安全側の簡易版）
// attempt: 1,2,3...
func backoff(base, max time.Duration, attempt int) time.Duration {
	// base * 2^(attempt-1)
	b := base
	for i := 1; i < attempt; i++ {
		b *= 2
		if b >= max {
			return max
		}
	}
	if b > max {
		return max
	}
	return b
}

// isRetryableDBErr は “一時的に起きがちな” DB/ネットワーク系だけ true。
// 文字列判定は保険（ドライバ依存を避けるため）なので、必要なら後で強化する。
func isRetryableDBErr(err error) bool {
	// ctx 系は retry しない（上位に返す）
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return false
	}

	// database/sql が「接続としてはダメ」と判断するケース
	if errors.Is(err, driver.ErrBadConn) {
		return true
	}

	// net.Error の temporary/timeout
	var ne net.Error
	if errors.As(err, &ne) {
		if ne.Timeout() {
			return true
		}
		// Temporary は Go 1.20+ では推奨されないが、実装が残ってる環境もあるため保険で拾う
		type temporary interface{ Temporary() bool }
		if te, ok := any(ne).(temporary); ok && te.Temporary() {
			return true
		}
	}

	// MySQL でありがちな “一時的” 失敗（文字列ベースの保険）
	msg := strings.ToLower(err.Error())
	switch {
	case strings.Contains(msg, "deadlock"):
		return true
	case strings.Contains(msg, "lock wait timeout"):
		return true
	case strings.Contains(msg, "connection reset"):
		return true
	case strings.Contains(msg, "broken pipe"):
		return true
	case strings.Contains(msg, "timeout"):
		return true
	default:
		return false
	}
}
