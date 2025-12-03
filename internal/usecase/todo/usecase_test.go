// internal/usecase/todo/usecase_test.go
package todo_usecase

import (
	"context"
	"testing"

	domain_todo "github.com/hijjiri/grpc-echo/internal/domain/todo"
	"go.uber.org/zap"
)

// テスト用のモック Repository
type mockRepo struct {
	// 挙動を制御するためのフィールド
	createFn func(ctx context.Context, t *domain_todo.Todo) (*domain_todo.Todo, error)
	listFn   func(ctx context.Context) ([]*domain_todo.Todo, error)
	deleteFn func(ctx context.Context, id int64) (bool, error)
	updateFn func(ctx context.Context, t *domain_todo.Todo) (*domain_todo.Todo, error)
}

func (m *mockRepo) Create(ctx context.Context, t *domain_todo.Todo) (*domain_todo.Todo, error) {
	if m.createFn != nil {
		return m.createFn(ctx, t)
	}
	return t, nil
}

func (m *mockRepo) List(ctx context.Context) ([]*domain_todo.Todo, error) {
	if m.listFn != nil {
		return m.listFn(ctx)
	}
	return []*domain_todo.Todo{}, nil
}

func (m *mockRepo) Delete(ctx context.Context, id int64) (bool, error) {
	if m.deleteFn != nil {
		return m.deleteFn(ctx, id)
	}
	return true, nil
}

func (m *mockRepo) Update(ctx context.Context, t *domain_todo.Todo) (*domain_todo.Todo, error) {
	if m.updateFn != nil {
		return m.updateFn(ctx, t)
	}
	return t, nil
}

func TestUsecase_Create_Success(t *testing.T) {
	t.Parallel()

	repo := &mockRepo{
		createFn: func(ctx context.Context, td *domain_todo.Todo) (*domain_todo.Todo, error) {
			// 疑似的にIDを付与する
			td.ID = 1
			return td, nil
		},
	}

	uc := New(repo, zap.NewNop())

	got, err := uc.Create(context.Background(), "テストタイトル")
	if err != nil {
		t.Fatalf("Create returned error: %v", err)
	}

	if got.ID != 1 {
		t.Errorf("expected ID=1, got %d", got.ID)
	}
	if got.Title != "テストタイトル" {
		t.Errorf("expected Title=%q, got %q", "テストタイトル", got.Title)
	}
	if got.Done {
		t.Errorf("expected Done=false, got true")
	}
}

func TestUsecase_Create_EmptyTitle(t *testing.T) {
	t.Parallel()

	repo := &mockRepo{}
	uc := New(repo, zap.NewNop())

	_, err := uc.Create(context.Background(), "")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if err != ErrEmptyTitle {
		t.Errorf("expected ErrEmptyTitle, got %v", err)
	}
}

func TestUsecase_List_Success(t *testing.T) {
	t.Parallel()

	repo := &mockRepo{
		listFn: func(ctx context.Context) ([]*domain_todo.Todo, error) {
			return []*domain_todo.Todo{
				{ID: 1, Title: "A", Done: false},
				{ID: 2, Title: "B", Done: true},
			}, nil
		},
	}

	uc := New(repo, zap.NewNop())

	list, err := uc.List(context.Background())
	if err != nil {
		t.Fatalf("List returned error: %v", err)
	}

	if len(list) != 2 {
		t.Fatalf("expected 2 todos, got %d", len(list))
	}
	if list[0].Title != "A" || list[1].Title != "B" {
		t.Errorf("unexpected titles: %#v", list)
	}
}

func TestUsecase_Delete_Success(t *testing.T) {
	t.Parallel()

	repo := &mockRepo{
		deleteFn: func(ctx context.Context, id int64) (bool, error) {
			if id != 1 {
				t.Errorf("expected id=1, got %d", id)
			}
			return true, nil
		},
	}

	uc := New(repo, zap.NewNop())

	if err := uc.Delete(context.Background(), 1); err != nil {
		t.Fatalf("Delete returned error: %v", err)
	}
}

func TestUsecase_Delete_InvalidID(t *testing.T) {
	t.Parallel()

	repo := &mockRepo{}
	uc := New(repo, zap.NewNop())

	err := uc.Delete(context.Background(), 0)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if err != ErrInvalidID {
		t.Errorf("expected ErrInvalidID, got %v", err)
	}
}

func TestUsecase_Delete_NotFound(t *testing.T) {
	t.Parallel()

	repo := &mockRepo{
		deleteFn: func(ctx context.Context, id int64) (bool, error) {
			return false, nil // 削除対象なし
		},
	}
	uc := New(repo, zap.NewNop())

	err := uc.Delete(context.Background(), 123)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if err != ErrNotFound {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}

func TestUsecase_Update_Success(t *testing.T) {
	t.Parallel()

	repo := &mockRepo{
		updateFn: func(ctx context.Context, td *domain_todo.Todo) (*domain_todo.Todo, error) {
			if td.ID != 3 {
				t.Errorf("expected id=3, got %d", td.ID)
			}
			return td, nil
		},
	}

	uc := New(repo, zap.NewNop())

	got, err := uc.Update(context.Background(), 3, "更新タイトル", true)
	if err != nil {
		t.Fatalf("Update returned error: %v", err)
	}

	if got.ID != 3 || got.Title != "更新タイトル" || !got.Done {
		t.Errorf("unexpected updated todo: %#v", got)
	}
}
