// internal/todo/mysql_repository.go
package todo

import (
	"context"
	"database/sql"

	todov1 "github.com/hijjiri/grpc-echo/api/todo/v1"
)

type MySQLTodoRepository struct {
	db *sql.DB
}

func NewMySQLTodoRepository(db *sql.DB) *MySQLTodoRepository {
	return &MySQLTodoRepository{db: db}
}

func (r *MySQLTodoRepository) Create(ctx context.Context, title string) (*todov1.Todo, error) {
	res, err := r.db.ExecContext(
		ctx,
		"INSERT INTO todos (title, done) VALUES (?, ?)",
		title,
		false,
	)
	if err != nil {
		return nil, err
	}

	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}

	return &todov1.Todo{
		Id:    id,
		Title: title,
		Done:  false,
	}, nil
}

func (r *MySQLTodoRepository) List(ctx context.Context) ([]*todov1.Todo, error) {
	rows, err := r.db.QueryContext(ctx, "SELECT id, title, done FROM todos ORDER BY id")
	if err != nil {
		return nil, err
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
			return nil, err
		}
		todos = append(todos, &todov1.Todo{
			Id:    id,
			Title: title,
			Done:  done,
		})
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return todos, nil
}

func (r *MySQLTodoRepository) Delete(ctx context.Context, id int64) (bool, error) {
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
