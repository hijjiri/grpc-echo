package mysql

import (
	"context"
	"database/sql"

	domain_todo "github.com/hijjiri/grpc-echo/internal/domain/todo"

	"go.uber.org/zap"
)

type TodoRepository struct {
	db     *sql.DB
	logger *zap.Logger
}

func NewTodoRepository(db *sql.DB, logger *zap.Logger) *TodoRepository {
	return &TodoRepository{
		db:     db,
		logger: logger,
	}
}

// logger が nil の場合でも panic しないように helper を用意
func (r *TodoRepository) log() *zap.Logger {
	if r.logger != nil {
		return r.logger
	}
	return zap.NewNop()
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
		r.log().Error("failed to insert todo",
			zap.String("title", t.Title),
			zap.Bool("done", t.Done),
			zap.Error(err),
		)
		return nil, err
	}

	id, err := res.LastInsertId()
	if err != nil {
		r.log().Error("failed to get last insert id",
			zap.String("title", t.Title),
			zap.Error(err),
		)
		return nil, err
	}

	t.ID = id

	r.log().Info("todo created",
		zap.Int64("id", t.ID),
		zap.String("title", t.Title),
		zap.Bool("done", t.Done),
	)

	return t, nil
}

// List は DB から全件取得し、domain の Todo スライスで返す
func (r *TodoRepository) List(ctx context.Context) ([]*domain_todo.Todo, error) {
	rows, err := r.db.QueryContext(ctx, "SELECT id, title, done FROM todos ORDER BY id")
	if err != nil {
		r.log().Error("failed to query todos", zap.Error(err))
		return nil, err
	}
	defer rows.Close()

	var todos []*domain_todo.Todo
	for rows.Next() {
		var t domain_todo.Todo
		if err := rows.Scan(&t.ID, &t.Title, &t.Done); err != nil {
			r.log().Error("failed to scan todo row", zap.Error(err))
			return nil, err
		}
		todos = append(todos, &t)
	}
	if err := rows.Err(); err != nil {
		r.log().Error("rows error", zap.Error(err))
		return nil, err
	}

	r.log().Info("todos listed",
		zap.Int("count", len(todos)),
	)

	return todos, nil
}

// Delete は削除件数 > 0 なら true を返す
func (r *TodoRepository) Delete(ctx context.Context, id int64) (bool, error) {
	res, err := r.db.ExecContext(ctx, "DELETE FROM todos WHERE id = ?", id)
	if err != nil {
		r.log().Error("failed to delete todo",
			zap.Int64("id", id),
			zap.Error(err),
		)
		return false, err
	}

	affected, err := res.RowsAffected()
	if err != nil {
		r.log().Error("failed to get rows affected",
			zap.Int64("id", id),
			zap.Error(err),
		)
		return false, err
	}

	if affected == 0 {
		r.log().Info("todo delete: not found",
			zap.Int64("id", id),
		)
		return false, nil
	}

	r.log().Info("todo deleted",
		zap.Int64("id", id),
	)

	return true, nil
}

func (r *TodoRepository) Update(ctx context.Context, t *domain_todo.Todo) (*domain_todo.Todo, error) {
	res, err := r.db.ExecContext(
		ctx,
		"UPDATE todos SET title = ?, done = ? WHERE id = ?",
		t.Title,
		t.Done,
		t.ID,
	)
	if err != nil {
		r.log().Error("failed to update todo",
			zap.Int64("id", t.ID),
			zap.String("title", t.Title),
			zap.Bool("done", t.Done),
			zap.Error(err),
		)
		return nil, err
	}

	affected, err := res.RowsAffected()
	if err != nil {
		r.log().Error("failed to get rows affected on update",
			zap.Int64("id", t.ID),
			zap.Error(err),
		)
		return nil, err
	}

	if affected == 0 {
		r.log().Info("todo update: not found",
			zap.Int64("id", t.ID),
		)
		return nil, nil // Usecase 側で ErrNotFound に変換してもOK
	}

	r.log().Info("todo updated",
		zap.Int64("id", t.ID),
		zap.String("title", t.Title),
		zap.Bool("done", t.Done),
	)

	return t, nil
}
