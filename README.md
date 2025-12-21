# grpc-echo

gRPC / REST(gRPC-Gateway) / React フロントエンド / MySQL / OpenTelemetry (Prometheus, Grafana, Tempo) を使った Todo/Echo サービス。

- 小さいけれど、業務のミニマム構成を意識した学習プロジェクト
- gRPC + Clean Architecture をベースに、Kubernetes(kind) 上で動作
- ログ / メトリクス / トレース / JWT 認証 / 永続ボリューム(PV) まで一通り体験できる構成

---

## 1. 全体像

### 1-1. 主なコンポーネント

- **バックエンド (Go)**
  - gRPC サーバ (`cmd/server`)
  - REST Gateway (`cmd/http_gateway`) … gRPC-Gateway で `:50051` → `:8081` に HTTP 変換
  - JWT ヘルパー (`cmd/jwt_gen`) … `AUTH_SECRET` から JWT を発行
- **フロントエンド**
  - Vite + React (TypeScript) … `frontend/`
  - REST API (`/v1/todos`) を呼ぶ Todo 画面
- **インフラ / ミドルウェア (Kubernetes 上)**
  - `mysql` … Todo を保存、PV + PVC で永続化
  - `grpc-echo` … gRPC アプリ (メトリクスも公開)
  - `otel-collector` … OTLP 受信・各種エクスポート
  - `prometheus` … メトリクス収集
  - `grafana` … ダッシュボード
  - `tempo` … トレースストレージ (Jaeger ではなく Tempo を利用)

### 1-2. 主なディレクトリ構成 (Clean Architecture ベース)

```text
api/
  echo/v1/       # Echo proto から生成された gRPC コード
  todo/v1/       # Todo proto から生成された gRPC / Gateway コード
cmd/
  server/        # gRPC サーバ エントリポイント
  http_gateway/  # gRPC-Gateway (REST ←→ gRPC)
  jwt_gen/       # JWT 発行 CLI
frontend/        # Vite + React のフロントエンド
internal/
  auth/          # JWT 検証ロジック
  domain/
    todo/        # Todo エンティティ / Repository インターフェース
  usecase/
    todo/        # Todo ユースケース
    echo/        # Echo ユースケース
  infrastructure/
    mysql/       # Todo Repository の MySQL 実装
  interface/
    grpc/        # gRPC Handler, Interceptor (Logging, Auth)
k8s/
  mysql.yaml         # MySQL Deployment + Service + PVC
  grpc-echo.yaml     # gRPC サーバ Deployment + Service
  otel-collector.yaml
  prometheus.yaml
  grafana.yaml
  tempo.yaml
  
### 全体像を一度絵にすると…

          (k8s 内)                                (開発者が見る場所)
────────────────────────────────────────────────────────────────────────
         +-------------+
         |  grpc-echo  |
         |  (app pod)  |
         +------+------+-------------------+
          | gRPC :50051                    |
          | /metrics :9464 (HTTP)          |
          | OTLP :4317 (traces)            |
          |                                |
   (gRPC) |                          (HTTP)| (OTLP)
          v                                v
   +-------------+                  +-------------+
   | http-gateway|                  | otel-collector |
   +------+------+                  +------+------+
                                     | OTLP gRPC
                                     v
                                +-----------+
                                |  Tempo    |
                                +-----------+

   +-------------+        +---------------------+
   | Prometheus  | <----- | scrape grpc-echo:9464|
   +------+------+        +---------------------+
          ^
          |
          |
   +------+------+
   |   Grafana   |
   +-------------+
