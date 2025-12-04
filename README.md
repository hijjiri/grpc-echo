いいですね、ここまで作り込んだので「**開発マニュアル兼チートシート README**」にしておくと、数ヶ月後に戻ってきてもすぐ思い出せます。

下に **そのまま README に貼れる形** でまとめました。
既存 README とマージするときは、重複しているところだけ削れば OK です。

---

````markdown
# grpc-echo

gRPC + Clean Architecture + MySQL + OpenTelemetry(Prometheus/Grafana, Jaeger) を使った Todo/Echo サービス。

- 小さいけれど、業務でそのまま雛形にできる構成を目指したサンプル
- 「ローカル直叩き」「docker-compose」「kind(Kubernetes)」の 3 パターンに対応
- ログ / メトリクス / ヘルスチェック までひと通り揃ったリハビリ用バックエンド

---

## 1. プロジェクト全体像

### 1-1. 開発環境・インフラ

- OS: WSL2 上の Ubuntu
- 言語: Go 1.24.10
- DB: MySQL
- コンテナ（docker-compose）:
  - `grpc-echo-server` (アプリ)
  - `grpc-mysql` (DB)
  - `grpc-jaeger` (トレーシング UI)
  - `grafana` (ダッシュボード)
- Kubernetes: kind クラスタ `grpc-echo`
  - `grpc-echo` / `mysql` / `prometheus` / `grafana` を k8s 上にデプロイ

> **ポイント**:  
> 「すべて Docker」で動かすことも、「ローカルで Go プロセスを直接実行」することも可能。  
> 自分の体調や作業内容に合わせてスタイルを選べる柔軟な構成。

---

### 1-2. アーキテクチャ（Clean Architecture）

ディレクトリ構成（主なもの）:

```text
api/          # proto から生成された gRPC コード
cmd/
  server/     # gRPC サーバのエントリポイント
  client/     # Echo 用 gRPC クライアント CLI
  todo_client/# Todo 用 gRPC クライアント CLI
internal/
  domain/
    todo/     # エンティティ・Repository インターフェース
  usecase/
    todo/     # ビジネスロジック（ユースケース）
  infrastructure/
    mysql/    # MySQL 実装の Repository
  interface/
    grpc/     # gRPC Handler, Interceptor
````

* `domain` … ビジネスルール（構造体・インターフェース）
* `usecase` … ユースケース（アプリケーションサービス）
* `infrastructure` … DB・外部サービスなど
* `interface` … gRPC ハンドラや Web API など UI/IF 担当

> **狙い**:
> 「DB を MySQL→PostgreSQL に変えたい」「gRPC → REST を追加したい」などの変更に強くするため、
> ビジネスロジックを `usecase` に閉じ込めている。

---

### 1-3. 開発者体験（DX）

* Makefile でよく使う操作をコマンド化

  * `make proto` … `protoc` のコード生成
  * `make run-server` … サーバ起動
  * `make run-todo` … Todo クライアント実行
  * `make test` … `go test ./...`
* `go test ./...` がクリーンに通る状態
* `internal/usecase/todo` にテーブルドリブンテストあり

---

## 2. 実行方法まとめ

### 2-1. docker-compose で開発する場合

> ⚠ Kubernetes(kind) とポートが被るので、**k8s と同時には起動しない**ように注意。

#### すべてのコンテナを起動

```bash
docker-compose up -d
```

#### Grafana だけ起動（必要なときだけ）

```bash
docker-compose up -d --no-deps grafana
```

---

### 2-2. kind(Kubernetes) で動かす場合

#### 1) アプリの Docker イメージをビルド

```bash
docker build -t grpc-echo:latest .
```

#### 2) kind クラスタにイメージをロード

```bash
kind load docker-image --name grpc-echo grpc-echo:latest
```

#### 3) Kubernetes マニフェストを反映

```bash
kubectl apply -f k8s/mysql.yaml
kubectl apply -f k8s/grpc-echo.yaml
kubectl apply -f k8s/prometheus.yaml
kubectl apply -f k8s/grafana.yaml
```

状態確認:

```bash
kubectl get pods,svc
```

#### 4) 新しいイメージで再起動したいとき

```bash
kubectl rollout restart deployment grpc-echo
```

---

### 2-3. ポートフォワード（ブラウザや CLI からアクセス）

```bash
# Grafana UI (http://localhost:3000)
kubectl port-forward svc/grafana 3000:3000

# Prometheus UI (http://localhost:9090)
kubectl port-forward svc/prometheus 9090:9090

# gRPC サーバ (クライアントから localhost:50051 で叩ける)
kubectl port-forward svc/grpc-echo 50051:50051

# メトリクスエンドポイント (http://localhost:9464/metrics)
kubectl port-forward svc/grpc-echo 9464:9464
```

---

### 2-4. MySQL に入る

```bash
# Pod 名を確認
kubectl get pods -l app=mysql

# 例: mysql-59f5bdb4c6-8tx6k に接続
kubectl exec -it mysql-59f5bdb4c6-8tx6k -- bash

# コンテナ内で
mysql -u root -proot
```

---

## 3. 観測性（Observability）と「いつ何を使うか」

このプロジェクトでは、次の 4 つを使ってサービスの状態を観測できるようにしている。

1. **ログ (zap)**
2. **メトリクス (OpenTelemetry → Prometheus → Grafana)**
3. **トレース (OpenTelemetry → Jaeger)**
4. **ヘルスチェック (gRPC Health)**

### 3-1. ざっくり使い分け

| やりたいこと                          | 使うもの                |
| ------------------------------- | ------------------- |
| バグ調査・例外の詳細を知りたい                 | **ログ**              |
| 1秒あたりのリクエスト数、Todo 作成回数などを見たい    | **メトリクス + Grafana** |
| あるリクエストが内部でどの処理にどれだけ時間を使ったか知りたい | **トレース + Jaeger**   |
| 「今サービスが動いているか？」を機械的にチェック        | **ヘルスチェック**         |

> 新しい機能を実装するときの目安:
>
> * **ビジネス的に重要なイベント** → カウンタ/メトリクスを増やす
> * **デバッグしたくなりそうな箇所** → ログを増やす
> * **処理が重くなりそう / 外部サービスを呼ぶ** → トレースで可視化
> * **他サービスや LB が監視する** → Health エンドポイントに反映

---

## 4. ログ（zap）― どこで・どう使うか

### 4-1. 仕組み

* `cmd/server/main.go` で `zap.NewProduction()` を使って JSON ログを出力
* gRPC の Unary Interceptor で全リクエストの

  * メソッド名
  * 所要時間
  * エラーの有無
    を共通ログとして残す
* Usecase / Repository 内では `zap.Logger` を受け取って補足情報を出す

### 4-2. 典型的な使い方（todo usecase）

```go
type usecase struct {
    repo   domain_todo.Repository
    logger *zap.Logger
}

func (u *usecase) Create(ctx context.Context, title string) (*domain_todo.Todo, error) {
    if title == "" {
        u.logger.Warn("failed to create todo: empty title")
        return nil, ErrEmptyTitle
    }

    t := &domain_todo.Todo{Title: title, Done: false}
    created, err := u.repo.Create(ctx, t)
    if err != nil {
        u.logger.Error("failed to create todo in repo",
            zap.String("title", title),
            zap.Error(err),
        )
        return nil, err
    }

    u.logger.Info("todo created (usecase)",
        zap.Int64("id", created.ID),
        zap.String("title", created.Title),
    )
    return created, nil
}
```

### 4-3. いつログを書くかの指針

* **WARN**:

  * ユーザー入力など「期待しないけど起こりうる」ケース
    → `ErrEmptyTitle`, `ErrInvalidID` など
* **ERROR**:

  * DB エラー・外部サービスのエラーなど「システム的におかしい」ケース
* **INFO**:

  * 重要なビジネスイベント
    例: Todo 作成/更新/削除、サーバ起動、DB 接続成功 など

---

## 5. メトリクス（Prometheus/Grafana）― 何を計測しているか

### 5-1. 実装しているカスタムメトリクス

`internal/usecase/todo/usecase.go` で OpenTelemetry の Meter を使ってカウンタを発行。

```go
var (
    meter metric.Meter

    todoCreatedCounter metric.Int64Counter
    todoListCounter    metric.Int64Counter
)

func initMetrics() {
    meter = otel.Meter("github.com/hijjiri/grpc-echo/internal/usecase/todo")

    todoCreatedCounter, _ = meter.Int64Counter(
        "todo_created_total",
        metric.WithDescription("Number of todos created"),
    )

    todoListCounter, _ = meter.Int64Counter(
        "todo_list_total",
        metric.WithDescription("Number of times todos were listed"),
    )
}
```

カウンタの更新:

```go
func (u *usecase) Create(ctx context.Context, title string) (*domain_todo.Todo, error) {
    // ... 省略: バリデーション / Repository 呼び出し ...

    todoCreatedCounter.Add(ctx, 1,
        attribute.String("source", "grpc"),
    )
    return created, nil
}

func (u *usecase) List(ctx context.Context) ([]*domain_todo.Todo, error) {
    list, err := u.repo.List(ctx)
    if err != nil {
        return nil, err
    }

    todoListCounter.Add(ctx, 1,
        attribute.String("source", "grpc"),
    )
    return list, nil
}
```

### 5-2. Prometheus 側の設定

`k8s/prometheus.yaml`:

```yaml
scrape_configs:
  - job_name: "grpc-echo"
    static_configs:
      - targets: ["grpc-echo:9464"]
```

→ `grpc-echo` Service の `:9464/metrics` からメトリクスを収集。

### 5-3. Grafana での使い方

1. `kubectl port-forward svc/grafana 3000:3000`
2. ブラウザで `http://localhost:3000` を開く
3. Data source `prometheus` の URL が `http://prometheus:9090` であることを確認
4. **Explore → Metric ドロップダウン** から

   * `todo_created_total`
   * `todo_list_total`
     を選択して `Run query`
5. よさそうなグラフになったら `Add to dashboard` からパネルとして保存

### 5-4. いつメトリクスを増やすか

* 「**ビジネス上の回数・頻度を知りたい**」とき

  * 例: Todo 作成回数、ログイン成功回数、外部 API コール回数
* 「**SLO を決めたい**」とき

  * 例: エラー率、p95 レイテンシ、1分あたりのリクエスト数
* 「**後から傾向を分析したくなりそう**」な処理

  * 例: バッチ処理の成功/失敗回数

> 逆に、「一度だけしか呼ばれない処理」「ユーザーにほとんど影響しない処理」はログだけで済ませてよいことが多い。

---

## 6. トレース（Jaeger）― どんなときに見るか

このプロジェクトでは：

* docker-compose で `grpc-jaeger` コンテナが動作
* OpenTelemetry gRPC Interceptor を通じて、

  * リクエスト開始〜終了までのスパン
  * DB アクセスなどの処理時間
    を Jaeger に送れる構成になっている

（細かいコードは割愛。`cmd/server/main.go` で TracerProvider を初期化し、
`otelgrpc.UnaryServerInterceptor` を gRPC サーバに噛ませているイメージ）

### 6-1. いつトレースを使うか

* 「**あるリクエストがどこで遅くなっているか**」を突き止めたいとき
* 「**マイクロサービス間の呼び出し**」を跨って、全体の流れを見たいとき
* ログとメトリクスだけでは「どの順番で何をしたか」が追いづらいとき

> 現段階では「入門レベルの Jaeger 連携」なので、
> 本格的にやりたくなったら span の属性（DB クエリ、ID など）を増やす。

---

## 7. ヘルスチェック（gRPC Health）

* gRPC Health Checking Protocol を実装済み
* 他サービスや LB から「生きているか？」を確認するために使う

利用例：

```bash
# サーバが localhost:50051 で動いている前提
grpcurl -plaintext localhost:50051 grpc.health.v1.Health/Check
```

Kubernetes の readinessProbe / livenessProbe にも流用できる。

---

## 8. 新しい機能を実装するときの「観測性チェックリスト」

何か機能を追加するときは、以下をざっと確認すると後悔しづらい。

1. **ログ**

   * エラー時は WARN/ERROR を出しているか？
   * 成功時に「何が起きたか」がわかる INFO ログがあるか？

2. **メトリクス**

   * ビジネス上重要なカウンタ（作成回数・処理件数など）はメトリクスにしているか？
   * レイテンシを監視したいエンドポイントは gRPC メトリクスでカバーできているか？

3. **トレース**

   * 外部サービスを叩く / 複数ステップに分かれる処理なら、トレースがあると後で楽か？

4. **ヘルス**

   * この機能が落ちたとき、Health エンドポイントで検知できるか？

---

## 9. 今後の拡張アイデア（メモ）

* gRPC-Gateway で REST API を追加
* GitHub Actions で

  * `go test ./...`
  * `go vet`
  * `golangci-lint run`
    を流す CI
* 認証/認可（ユーザー / JWT）を Todo に追加
* Kubernetes に readiness/liveness probe を追加して本番寄りに

---

この README は「後から見返した自分が迷子にならない」ことを目的にしています。
環境や手順を変えたら、**コマンドと「何のためのコマンドか」をセットで追記**していくと、
自分専用の運用マニュアルとしてかなり頼れる一冊になります。

```

--- 

こんな感じでどうでしょう。  
「ここもう少し詳しく」「このコードも README に載せておきたい」みたいなのがあれば、そのセクションだけ追加版を作ります。
::contentReference[oaicite:0]{index=0}
```
