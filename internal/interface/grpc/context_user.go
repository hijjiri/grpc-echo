package grpcadapter

import "context"

// context の key 用の独自型
type ctxKey string

const ctxKeyUserID ctxKey = "userID"

// WithUserID は userID を context に埋め込む
func WithUserID(ctx context.Context, userID string) context.Context {
	if userID == "" {
		return ctx
	}
	return context.WithValue(ctx, ctxKeyUserID, userID)
}

// UserIDFromContext は context から userID を取り出す
func UserIDFromContext(ctx context.Context) (string, bool) {
	v := ctx.Value(ctxKeyUserID)
	if v == nil {
		return "", false
	}
	s, ok := v.(string)
	return s, ok
}
