package mysql

import (
	"context"
	"database/sql"
	"fmt"

	domain_todo "github.com/hijjiri/grpc-echo/internal/domain/todo"
	"go.uber.org/zap"
)

// *sql.DB と *sql.Tx を同じように扱うための小さなインターフェース
type executor interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

type TodoRepository struct {
	db     *sql.DB
	logger *zap.Logger
}

func NewTodoRepository(db *sql.DB, logger *zap.Logger) *TodoRepository {
	if logger == nil {
		logger = zap.NewNop()
	}
	return &TodoRepository{
		db:     db,
		logger: logger,
	}
}

// ctx に Tx がぶら下がっていればそれを使い、なければ通常の *sql.DB を使う。
func (r *TodoRepository) getExecutor(ctx context.Context) executor {
	if tx, ok := TxFromContext(ctx); ok {
		return tx
	}
	return r.db
}

func (r *TodoRepository) Create(ctx context.Context, t *domain_todo.Todo) (*domain_todo.Todo, error) {
	exec := r.getExecutor(ctx)

	res, err := exec.ExecContext(ctx,
		`INSERT INTO todos (title, done) VALUES (?, ?)`,
		t.Title,
		t.Done,
	)
	if err != nil {
		r.logger.Error("failed to insert todo",
			zap.String("title", t.Title),
			zap.Bool("done", t.Done),
			zap.Error(err),
		)
		return nil, fmt.Errorf("insert todo: %w", err)
	}

	id, err := res.LastInsertId()
	if err != nil {
		r.logger.Error("failed to get last insert id", zap.Error(err))
		return nil, fmt.Errorf("get last insert id: %w", err)
	}

	t.ID = id

	r.logger.Info("todo created",
		zap.Int64("id", t.ID),
		zap.String("title", t.Title),
		zap.Bool("done", t.Done),
	)

	return t, nil
}

func (r *TodoRepository) List(ctx context.Context) ([]*domain_todo.Todo, error) {
	exec := r.getExecutor(ctx)

	var todos []*domain_todo.Todo

	err := doWithRetry(ctx, DefaultReadRetry, func() error {
		rows, err := exec.QueryContext(ctx,
			`SELECT id, title, done FROM todos ORDER BY id`,
		)
		if err != nil {
			// ここで返した err に対して retry 判定が走る
			r.logger.Warn("failed to query todos (will retry if retryable)",
				zap.Error(err),
			)
			return err
		}
		defer rows.Close()

		// retry ループの都合上、ここで毎回作り直す
		todos = todos[:0]

		for rows.Next() {
			var (
				t       domain_todo.Todo
				doneInt int
			)
			if err := rows.Scan(&t.ID, &t.Title, &doneInt); err != nil {
				r.logger.Error("failed to scan todo", zap.Error(err))
				return fmt.Errorf("scan todo: %w", err)
			}
			t.Done = doneInt == 1
			todos = append(todos, &t)
		}

		if err := rows.Err(); err != nil {
			r.logger.Error("rows error", zap.Error(err))
			return fmt.Errorf("rows error: %w", err)
		}

		return nil
	})
	if err != nil {
		// doWithRetry が最終的に返したエラーをそのまま包む
		r.logger.Error("failed to list todos",
			zap.Error(err),
		)
		return nil, fmt.Errorf("query todos: %w", err)
	}

	r.logger.Info("todos listed",
		zap.Int("count", len(todos)),
	)

	return todos, nil
}

func (r *TodoRepository) Update(ctx context.Context, t *domain_todo.Todo) (*domain_todo.Todo, error) {
	exec := r.getExecutor(ctx)

	res, err := exec.ExecContext(ctx,
		`UPDATE todos SET title = ?, done = ? WHERE id = ?`,
		t.Title,
		t.Done,
		t.ID,
	)
	if err != nil {
		r.logger.Error("failed to update todo",
			zap.Int64("id", t.ID),
			zap.String("title", t.Title),
			zap.Bool("done", t.Done),
			zap.Error(err),
		)
		return nil, fmt.Errorf("update todo: %w", err)
	}

	if n, err := res.RowsAffected(); err == nil {
		if n == 0 {
			r.logger.Warn("no todo updated", zap.Int64("id", t.ID))
		}
	} else {
		r.logger.Warn("failed to get rows affected (update)", zap.Error(err))
	}

	r.logger.Info("todo updated",
		zap.Int64("id", t.ID),
		zap.String("title", t.Title),
		zap.Bool("done", t.Done),
	)

	return t, nil
}

func (r *TodoRepository) Delete(ctx context.Context, id int64) (bool, error) {
	exec := r.getExecutor(ctx)

	res, err := exec.ExecContext(ctx,
		`DELETE FROM todos WHERE id = ?`,
		id,
	)
	if err != nil {
		r.logger.Error("failed to delete todo",
			zap.Int64("id", id),
			zap.Error(err),
		)
		return false, fmt.Errorf("delete todo: %w", err)
	}

	n, err := res.RowsAffected()
	if err != nil {
		r.logger.Warn("failed to get rows affected (delete)", zap.Error(err))
		return false, fmt.Errorf("rows affected (delete): %w", err)
	}

	if n == 0 {
		// 削除対象なし
		r.logger.Info("no todo deleted", zap.Int64("id", id))
		return false, nil
	}

	r.logger.Info("todo deleted", zap.Int64("id", id))
	return true, nil
}
