package todo

import (
	"context"

	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"
)

// TodoRepository は Todo の永続化を抽象化するインターフェース
type TodoRepository interface {
	Create(ctx context.Context, title string) (*todov1.Todo, error)
	List(ctx context.Context) ([]*todov1.Todo, error)
	Delete(ctx context.Context, id int64) (bool, error)
}
