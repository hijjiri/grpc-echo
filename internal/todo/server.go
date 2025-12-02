package todo

import (
	"context"
	"database/sql"

	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type TodoServer struct {
	todov1.UnimplementedTodoServiceServer

	db *sql.DB
}

func NewTodoServer(db *sql.DB) *TodoServer {
	return &TodoServer{
		db: db,
	}
}

func (s *TodoServer) CreateTodo(ctx context.Context, req *todov1.CreateTodoRequest) (*todov1.Todo, error) {
	title := req.GetTitle()
	if title == "" {
		return nil, status.Error(codes.InvalidArgument, "title must not be empty")
	}

	res, err := s.db.ExecContext(
		ctx,
		"INSERT INTO todos (title, done) VALUES (?, ?)",
		title,
		false,
	)
	if err != nil {
		return nil, status.Error(codes.Internal, "failed to insert todo")
	}

	id, err := res.LastInsertId()
	if err != nil {
		return nil, status.Error(codes.Internal, "failed to get last insert id")
	}

	return &todov1.Todo{
		Id:    id,
		Title: title,
		Done:  false,
	}, nil
}

func (s *TodoServer) ListTodos(ctx context.Context, req *todov1.ListTodosRequest) (*todov1.ListTodosResponse, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT id, title, done FROM todos ORDER BY id")
	if err != nil {
		return nil, status.Error(codes.Internal, "failed to query todos")
	}
	defer rows.Close()

	var todos []*todov1.Todo

	for rows.Next() {
		var (
			id    int64
			title string
			done  bool
		)
		if err := rows.Scan(&id, &title, &done); err != nil {
			return nil, status.Error(codes.Internal, "failed to scan todo")
		}
		todos = append(todos, &todov1.Todo{
			Id:    id,
			Title: title,
			Done:  done,
		})
	}

	if err := rows.Err(); err != nil {
		return nil, status.Error(codes.Internal, "rows error")
	}

	return &todov1.ListTodosResponse{
		Todos: todos,
	}, nil
}

func (s *TodoServer) DeleteTodo(ctx context.Context, req *todov1.DeleteTodoRequest) (*todov1.DeleteTodoResponse, error) {
	id := req.GetId()
	if id == 0 {
		return nil, status.Error(codes.InvalidArgument, "id must be non-zero")
	}

	res, err := s.db.ExecContext(ctx, "DELETE FROM todos WHERE id = ?", id)
	if err != nil {
		return nil, status.Error(codes.Internal, "failed to delete todo")
	}

	affected, err := res.RowsAffected()
	if err != nil {
		return nil, status.Error(codes.Internal, "failed to get rows affected")
	}

	if affected == 0 {
		return nil, status.Error(codes.NotFound, "todo not found")
	}

	return &todov1.DeleteTodoResponse{
		Ok: true,
	}, nil
}
