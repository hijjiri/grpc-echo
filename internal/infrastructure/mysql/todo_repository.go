package mysql

import (
	"context"
	"database/sql"

	domain_todo "github.com/hijjiri/grpc-echo/internal/domain/todo"
)

type TodoRepository struct {
	db *sql.DB
}

func NewTodoRepository(db *sql.DB) *TodoRepository {
	return &TodoRepository{db: db}
}

// Create は domain の Todo を受け取り、DBにINSERTしてIDを付けて返す
func (r *TodoRepository) Create(ctx context.Context, t *domain_todo.Todo) (*domain_todo.Todo, error) {
	res, err := r.db.ExecContext(
		ctx,
		"INSERT INTO todos (title, done) VALUES (?, ?)",
		t.Title,
		t.Done,
	)
	if err != nil {
		return nil, err
	}

	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}

	t.ID = id
	return t, nil
}

// List は DB から全件取得し、domain の Todo スライスで返す
func (r *TodoRepository) List(ctx context.Context) ([]*domain_todo.Todo, error) {
	rows, err := r.db.QueryContext(ctx, "SELECT id, title, done FROM todos ORDER BY id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var todos []*domain_todo.Todo
	for rows.Next() {
		var t domain_todo.Todo
		if err := rows.Scan(&t.ID, &t.Title, &t.Done); err != nil {
			return nil, err
		}
		todos = append(todos, &t)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return todos, nil
}

// Delete は削除件数 > 0 なら true を返す
func (r *TodoRepository) Delete(ctx context.Context, id int64) (bool, error) {
	res, err := r.db.ExecContext(ctx, "DELETE FROM todos WHERE id = ?", id)
	if err != nil {
		return false, err
	}

	affected, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return affected > 0, nil
}
