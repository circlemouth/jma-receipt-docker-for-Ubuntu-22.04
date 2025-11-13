# 日医標準レセプトソフト (WebORCA) on Ubuntu 22.04

本リポジトリは、日医標準レセプトソフト (ORCA) の Web 版を Ubuntu 22.04 LTS ベースの Docker イメージで動かし、PostgreSQL と組み合わせてローカル/オンプレで再現できるようにしたものです。公式インストールドキュメントの手順（apt-line 追加、`jma-receipt-weborca` パッケージ導入、`weborca-install`、スキーマチェック、ormaster パスワード設定）をコンテナに閉じ込めて再現性を高めています。

## 特徴
- ORCA 用 apt リポジトリと鍵を自動登録し、Ubuntu 22.04 イメージに WebORCA を導入
- PostgreSQL 10 コンテナと compose 連携し、既定では UTF-8 で初期化（EUC-JP が必要なら環境変数を変更して再初期化）
- 起動スクリプトで `jma-setup`、スキーマチェック、ormaster パスワード設定を自動化
- ボリュームマウントで ORCA 側フラグや PostgreSQL データを永続化

※ PUSH 通知コンポーネント（`jma-receipt-pusher` など）は含めていません。既存の通知基盤と連携したい場合は別途追加してください。

## リポジトリ構成

| パス | 役割 |
| --- | --- |
| `Dockerfile` | Ubuntu 22.04 ベースで ORCA apt-line を追加し、`jma-receipt-weborca` をインストールするレシピ。 |
| `start-weborca.sh` | コンテナのエントリポイント。DB 待機→`db.conf` 生成→`jma-setup`→任意のスキーマチェック→ormaster パスワード設定→WebORCA 起動までを一括実行。 |
| `docker-compose.yml` | WebORCA (`orca`) と PostgreSQL (`db`) の 2 サービス構成。環境変数（UTF-8 チューニング）とボリューム定義を同梱。 |
| `README.md` | 使い方とトラブルシューティング。 |
| `.dockerignore` | ビルドコンテキストから不要ファイルを除外。 |

## 前提条件
- Docker Engine 24 以降 & Docker Compose v2
- 約 25GB 以上の空き容量（ORCA パッケージと PostgreSQL データを含む）
- ホストのタイムゾーンは任意ですが、コンテナは既定で `Asia/Tokyo`

## 使い方

### すぐに試す（一時利用）
```bash
git clone https://github.com/<your-account>/jma-receipt-docker-for-Ubuntu-22.04.git
cd jma-receipt-docker-for-Ubuntu-22.04
ORMASTER_PASS='ormaster' docker compose up -d
```
`docker compose logs -f orca` で `Starting WebORCA middleware` が表示されたら `http://localhost:8000/` へアクセスし、ORCAMO クライアント (monsiaj 等) からは `http://localhost:8000/rpc` に接続します。`ORMASTER_PASS` を指定しない場合は、自動設定をスキップし `/opt/jma/weborca/app/bin/passwd_store.sh` を手動で実行してください。

#### WebUI の初期認証情報
- ユーザー名: `ormaster`
- パスワード: `ORMASTER_PASS` で渡した値（このサブモジュールを OpenDolphin WebClient リポジトリから利用する場合は `docker-compose.yml` が `change_me` を設定済み）

`docker compose up -d` 実行後に Web ブラウザで `http://localhost:8000/` を開き、上記の組み合わせでログインしてください。`ORMASTER_PASS` の値を変更した場合は再起動後に新しいパスワードが反映されます。

### データを保持したい場合
Compose ファイルには既に永続ボリュームを定義済みです。
```bash
# 既定値を調整したい場合
$EDITOR docker-compose.yml
# その後、起動
docker compose up -d
```
`orca_state` ボリュームに ORCA 側の状態フラグ、`pg_data` に PostgreSQL データが残ります。停止しても再利用可能です。

## コンテナ構成
- `orca` サービス: リポジトリの Dockerfile からビルド。ポート 8000 をホストに公開し、エントリポイントで DB 接続待機や初期設定を実施。
- `db` サービス: `postgres:10` (Debian ベース)。既定で `POSTGRES_INITDB_ARGS="--encoding=UTF8 --locale=C"` とし、EUC_JP ↔ EUC_JIS_2004 変換が存在せずに WebORCA が起動できなくなる問題を回避しています。どうしても EUC-JP が必要な場合は Compose の `POSTGRES_INITDB_ARGS` と `ORCA_DB_ENCODING` を揃えて書き換えてからボリュームを再初期化してください。

`depends_on` はシンプルに定義しているため、`orca` 側で `pg_isready` を繰り返し実行して DB が立ち上がるまで待機します。

## 環境変数一覧（`orca` サービス）

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `TZ` | `Asia/Tokyo` | コンテナのタイムゾーン。PostgreSQL でも共有。 |
| `ORCA_DB_HOST` | `db` | PostgreSQL ホスト名。 |
| `ORCA_DB_PORT` | `5432` | PostgreSQL ポート。 |
| `ORCA_DB_NAME` | `orca` | 接続先 DB 名。 |
| `ORCA_DB_USER` | `orca` | WebORCA 用 DB ユーザ。 |
| `ORCA_DB_PASS` | `orca_password` | 同上のパスワード。 |
| `ORCA_DB_ENCODING` | `UTF-8` | `db.conf` に書き込むエンコーディング。EUC-JP が必要なら `docker-compose.yml` の `ORCA_DB_ENCODING` と `POSTGRES_INITDB_ARGS` を両方変更し、`pg_data`/`orca_state` を削除してから再起動。 |
| `ORCA_DB_WAIT_SECONDS` | `300` | DB 接続待ちのタイムアウト秒数。 |
| `RUN_SCHEMA_CHECK` | `"false"` | `true` にすると初回起動で `jma-receipt-dbscmchk.sh` をダウンロードして実行。 |
| `ORMASTER_PASS` | _(空)_ | ormaster ユーザの初期パスワード。空なら自動設定を行わない。 |

## 永続ボリューム
- `orca_state` → `/var/lib/orca`: `jma-setup`・スキーマチェック・パスワード設定済みかどうかのフラグを保持。
- `pg_data` → `/var/lib/postgresql/data`: PostgreSQL のデータ一式。

必要に応じて `/opt/jma/weborca/log` 等を追加マウントすると、ログの収集や監視が容易になります。

## Route テンプレートとログ永続化

### `receipt_route.ini` テンプレート
- `example/receipt_route.ini` に WebORCA 22.04 で POST を開放するための最低限のルート定義を用意しました。`docker cp example/receipt_route.ini <container>:/opt/jma/weborca/app/etc/receipt_route.ini` で配置し、`chown orca:orca` → `chmod 640` を付与してから WebORCA を再起動してください。
- API グループの有効化判断・エビデンス保存フローは `../../../docs/server-modernization/phase2/operations/ORCA_CONNECTIVITY_VALIDATION.md` の Runbook §4.5 を参照してください（404/405 のトリアージや config dump の保存先も同節に記載）。

### ログ永続化 override
- `docker-compose.override.yml.example` に `/opt/jma/weborca/log` を `./orca-logs` へバインドするサンプルを追記しました。`cp docker-compose.override.yml{.example,}` → `mkdir -p orca-logs` → `docker compose up -d --force-recreate orca` の順で適用します。
- Runbook §4.5 のログ永続化手順では、ホスト側 `orca-logs/` 以下に保存されたファイルを `docs/server-modernization/phase2/operations/logs/<date>-orca-connectivity.md` から参照し、`artifacts/orca-connectivity/<RUN_ID>/` と紐付ける運用を想定しています。

## 運用タスク
### ormaster パスワードを再設定
```bash
docker compose exec orca rm /var/lib/orca/.ormaster_password_done
ORMASTER_PASS='new-secret' docker compose restart orca
```

### スキーマチェックを再実行
```bash
docker compose exec orca rm /var/lib/orca/.schema_checked
RUN_SCHEMA_CHECK=true docker compose restart orca
```

### `jma-setup` をやり直したい場合
```bash
docker compose exec orca rm /var/lib/orca/.jma_setup_done
docker compose restart orca
```

## トラブルシューティング
- `pg_isready` がタイムアウトする: `db` サービスのログを確認し、ホストのファイアウォールやリソース不足をチェック。必要なら `ORCA_DB_WAIT_SECONDS` を延長。
- `jma-setup` で認証エラー: `ORCA_DB_USER/ORCA_DB_PASS` が PostgreSQL 側と一致しているか、`postgres` ログにエラーがないか確認。
- ポート 8000 にアクセスできない: `docker compose logs -f orca` でエントリポイントの完了を確認し、`/var/log/jma-receipt-weborca/` を参照。

## カスタマイズのヒント
1. ビルドしたイメージをレジストリへプッシュして、CI/CD からデプロイする。
2. `start-weborca.sh` に施設固有のマスタ投入や PUSH 連携処理を追加する。
3. `postgres` イメージを別バージョンへ切り替える場合は、ORCA が推奨する互換性とエンコーディング設定を事前に確認する。
