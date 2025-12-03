package todo

import "context"

type Repository interface {
	Create(ctx context.Context, t *Todo) (*Todo, error)
	List(ctx context.Context) ([]*Todo, error)
	Delete(ctx context.Context, id int64) (bool, error)
	Update(ctx context.Context, t *Todo) (*Todo, error)
}
