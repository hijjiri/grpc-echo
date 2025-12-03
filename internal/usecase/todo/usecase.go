package todo_usecase

import (
	"context"
	"errors"

	domain_todo "github.com/hijjiri/grpc-echo/internal/domain/todo"
)

// ===== エラー定数（Handler側からも使う） =====

var (
	ErrEmptyTitle = errors.New("title is empty")
	ErrInvalidID  = errors.New("invalid id")
	ErrNotFound   = errors.New("todo not found")
)

// ===== 外部に公開する Usecase インターフェース =====

type Usecase interface {
	Create(ctx context.Context, title string) (*domain_todo.Todo, error)
	List(ctx context.Context) ([]*domain_todo.Todo, error)
	Delete(ctx context.Context, id int64) error
}

// ===== 実装 =====

type usecase struct {
	repo domain_todo.Repository
}

func New(repo domain_todo.Repository) Usecase {
	return &usecase{repo: repo}
}

// Create ユースケース
func (u *usecase) Create(ctx context.Context, title string) (*domain_todo.Todo, error) {
	if title == "" {
		return nil, ErrEmptyTitle
	}

	t := &domain_todo.Todo{
		Title: title,
		Done:  false,
	}

	return u.repo.Create(ctx, t)
}

// List ユースケース
func (u *usecase) List(ctx context.Context) ([]*domain_todo.Todo, error) {
	return u.repo.List(ctx)
}

// Delete ユースケース
func (u *usecase) Delete(ctx context.Context, id int64) error {
	if id <= 0 {
		return ErrInvalidID
	}

	ok, err := u.repo.Delete(ctx, id)
	if err != nil {
		return err
	}
	if !ok {
		return ErrNotFound
	}
	return nil
}
