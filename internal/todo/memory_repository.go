// internal/todo/memory_repository.go
package todo

import (
	"context"
	"sync"

	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"
)

type InMemoryTodoRepository struct {
	mu    sync.Mutex
	next  int64
	items map[int64]*todov1.Todo
}

func NewInMemoryTodoRepository() *InMemoryTodoRepository {
	return &InMemoryTodoRepository{
		next:  1,
		items: make(map[int64]*todov1.Todo),
	}
}

func (r *InMemoryTodoRepository) Create(ctx context.Context, title string) (*todov1.Todo, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	id := r.next
	r.next++

	t := &todov1.Todo{
		Id:    id,
		Title: title,
		Done:  false,
	}
	r.items[id] = t
	return t, nil
}

func (r *InMemoryTodoRepository) List(ctx context.Context) ([]*todov1.Todo, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	todos := make([]*todov1.Todo, 0, len(r.items))
	for _, t := range r.items {
		todos = append(todos, t)
	}
	return todos, nil
}

func (r *InMemoryTodoRepository) Delete(ctx context.Context, id int64) (bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if _, ok := r.items[id]; !ok {
		return false, nil
	}
	delete(r.items, id)
	return true, nil
}
