package todo

import (
	"context"
	"sync"

	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"
)

type TodoServer struct {
	todov1.UnimplementedTodoServiceServer

	mu     sync.Mutex
	todos  map[int64]*todov1.Todo
	nextID int64
}

func NewTodoServer() *TodoServer {
	return &TodoServer{
		todos:  make(map[int64]*todov1.Todo),
		nextID: 1,
	}
}

func (s *TodoServer) CreateTodo(ctx context.Context, req *todov1.CreateTodoRequest) (*todov1.Todo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	id := s.nextID
	s.nextID++

	todo := &todov1.Todo{
		Id:    id,
		Title: req.GetTitle(),
		Done:  false,
	}

	s.todos[id] = todo

	return todo, nil
}

func (s *TodoServer) ListTodos(ctx context.Context, req *todov1.ListTodosRequest) (*todov1.ListTodosResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	res := &todov1.ListTodosResponse{}

	for _, t := range s.todos {
		// map の順番は保証されないが、今回は気にしない
		res.Todos = append(res.Todos, t)
	}

	return res, nil
}

func (s *TodoServer) DeleteTodo(ctx context.Context, req *todov1.DeleteTodoRequest) (*todov1.DeleteTodoResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	_, exists := s.todos[req.GetId()]
	if !exists {
		// 存在しなくても false で返すだけ（エラーにはしない）
		return &todov1.DeleteTodoResponse{Ok: false}, nil
	}

	delete(s.todos, req.GetId())

	return &todov1.DeleteTodoResponse{Ok: true}, nil
}
