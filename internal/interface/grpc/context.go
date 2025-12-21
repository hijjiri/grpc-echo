package grpcadapter

import "context"

type ctxKey string

const (
	ctxKeyUserID    ctxKey = "user-id"
	ctxKeyRequestID ctxKey = "request-id"
)

// ----- user_id -----

func WithUserID(ctx context.Context, userID string) context.Context {
	return context.WithValue(ctx, ctxKeyUserID, userID)
}

func UserIDFromContext(ctx context.Context) (string, bool) {
	v := ctx.Value(ctxKeyUserID)
	s, ok := v.(string)
	return s, ok
}

// ----- request_id -----

func WithRequestID(ctx context.Context, rid string) context.Context {
	return context.WithValue(ctx, ctxKeyRequestID, rid)
}

func RequestIDFromContext(ctx context.Context) (string, bool) {
	v := ctx.Value(ctxKeyRequestID)
	s, ok := v.(string)
	return s, ok
}
