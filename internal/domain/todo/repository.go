package todo

import "context"

// 読み取り専用のリポジトリインターフェース。
// 「一覧表示」「詳細取得」など、状態を変更しない操作だけをまとめる。
type ReadRepository interface {
	List(ctx context.Context) ([]*Todo, error)
	// Get(ctx context.Context, id int64) (*Todo, error)
}

// 書き込み専用のリポジトリインターフェース。
// 「作成」「更新」「削除」など、DB の状態を変える操作をまとめる。
type WriteRepository interface {
	Create(ctx context.Context, t *Todo) (*Todo, error)
	Update(ctx context.Context, t *Todo) (*Todo, error)
	Delete(ctx context.Context, id int64) (bool, error)
}

type Repository interface {
	ReadRepository
	WriteRepository
}
