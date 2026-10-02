# RVSS組織管理

`index.html` 1枚だけのアプリ。ビルド工程なし。Supabase JS は CDN から読む。

## このファイルの扱い

3300行・163KBある。**全文を読むと会話の枠を1回で大きく消費するので、原則読まない。**

- 場所を探す: `grep -n` で当たりをつける
- 読む: `sed -n '1200,1260p'` のように必要な範囲だけ
- 直す: 1〜2箇所なら Edit、複数箇所の同じ置換なら Node のパッチスクリプト

**改行は LF。** `core.autocrlf=true` なので作業ツリーでCRLFに見えることがあるが、リポジトリはLF。パッチスクリプトでCRLFを混ぜないこと。

## デプロイ

```
git push https://github.com/kitamura104toshi-cyber/rvss-org.git main
```

`origin` は OneDrive の古いリポジトリを指している。使わない。
push すると Vercel が https://rvss-org-zeta.vercel.app/ へ反映する。

## Supabase

| | project ref |
|---|---|
| 本番 | `dbrwsrrfmpnvpzxcdupp` |
| 開発 | `vsqrgcsobweaupiabagu` |

`IS_LOCAL_DEV`（hostname が localhost / 127.0.0.1）で切り替わる。
**本番データに触る前に開発側で確かめる。**

状態は `org_state` テーブルの1行（id='main'、jsonb の `data`）。
RLS は有効だが anon に SELECT/INSERT/UPDATE を全部許している。
**つまり権限はUI上の区別でしかなく、秘匿の保証ではない。**
見せたくない情報は「CSSで隠す」ではなく**HTMLを生成しない**こと。
`.core-only` は、見えてしまっても害がないものにだけ使う。

## Edge Functions

- デプロイは `deploy_edge_function`
- **`curl` は通らない。** 呼ぶときは `execute_sql` の中で `net.http_post`、結果は `net._http_response` を id で引く
- **日本語やコードを含む関数のデプロイを他のエージェントに任せない。** エスケープが壊れて起動しなくなった実績がある（改行が `\n` になる、引用符が `\"` になる）

## スプレッドシート連携

Google Sheets API v4。サービスアカウントの JWT（RS256 / `crypto.subtle`）で認証。
鍵は Vault の `gcp_sheets_service_account`。
bot は `sheets-backup-bot@rvss-sheets-backup.iam.gserviceaccount.com`。

**列は必ず見出し名で引く（`findCol` / `normalizeHeader`）。列番号で決め打ちしない。**
月によって列が増減するため、位置指定はすぐずれる。

## 権限

`?key=` で決まる3段階。`member` → `core` → `admin`。
`isEditMode` は admin のみ。`pushToSupabase()` は core 以上。
`state = load()` は読み込み失敗時に埋め込みの初期データへ落ちるため、
`cloudLoaded` が立つまで保存させない（古い状態で上書きする事故を防ぐ）。

## 稼働時間（Notion連携）

Notion「AI管理表」の `先月の稼働時間` / `今月の稼働時間` は数式で、
**UTCの月替わりで切り替わる。** 日本時間の1日0時〜9時のあいだは、
Notionの「今月」がまだ日本時間の先月を指している。
月初の取り込みは日本時間 1日 1:00／1:15／1:30。UTCでは前月末日の16:00なので、
cron は日付 `28-31` で仕掛け、日本時間が1日のときだけ実行するよう中で見ている。
この時刻だとUTCはまだ前月なので、確定分はNotionの**「今月」**から取る。
どちらから取るかは SQL 関数 `archive_workload_hours_auto()` が判断する。

取り込んだ確定分は `memberOverrides[氏名].hoursByMonth["YYYY-MM"]` に月ごとで持つ。
平らな `lastMonthHours` は「最後に取った月」の値でしかないので、
報酬タブは `hoursByMonth[表示中の月]` だけを見る。
月へ紐付ける処理は SQL 関数 `archive_workload_hours(月, 'last'|'current')`。
アプリの「Notionから稼働・業務内容を取得」ボタンもこれを呼ぶ。

**`memberOverrides[氏名]` を作り直さないこと。** Notion取得ぶん・契約状況・スキル分類など、
編集フォームに無い項目が消える。必ず既存オブジェクトを spread して上書きする。

## 報酬の月ごとの値

`compensation.members[氏名]` 直下に置いた値は全部の月に効いてしまう。
`PAY_MONTHLY_FIELDS`（`isManager` / `adjust` / `adjustNote` / `countAsProject`）は
`byMonth["YYYY-MM"]` に明示のある月だけ有効。
7月に付いたマネージャー認定や8月だけの手動調整が毎月出ていたのを直したもの。

**稼働40時間以上は絶対の条件。** 360°評価などの加算がいくらあっても、
これを満たさない月は支給しない。

「稼働時間だけ取り直す」ボタンは稼働時間と按分だけを入れ替える。
360°評価・出席率・手動調整・業務内容には触らない。

プロジェクト関与の人数（按分の人数比率）は、その月の確定分にプロジェクト稼働が
あるかどうかだけで決める。平らな `projectHoursTotal` やアプリ上の所属を
フォールバックに使うと、前月に数時間関わっただけの人が関与者として残る。

予想月を先に組むときは `byMonth["YYYY-MM"]` に `assumedHours` /
`assumedProjectHours` / `assumedProjectHoursTotal` を置く。置いた月は
どのモードでもこの前提で計算し、有償枠だけを並べる（`payMonthIsAssumed`）。
経過日数で引き伸ばす予想（`payForecastFactor`）はこれが無い月のための経路。

## 開発環境で作業するとき

`index.html` は1枚だけで、**dev用のファイルは無い。** 接続先は開いたURLで決まる。
`.claude/launch.json` の `static` を起動して `localhost:5173` を開くと開発 Supabase。
Vercel（rvss-org-zeta）は本番。devから本番へ反映される仕組みは無く、2つは完全に別。

2026-10-03 に以下を実施済み。

- 開発側の `org_state` を本番のスナップショットで入れ替えた（それまでのdevは9月中旬の状態）
- 入れ替え前のdevは `org_state` の `id='backup-20261003-pre-refresh'` に退避してある
- **開発側の cron 4本は全部停止**（`cron.alter_job(jobid, active := false)`。定義は残している）

止めた理由は `recruitment-sync-5h`。5時間ごとに募集フォームからプロジェクトの
メンター／学生を書き戻すので、devでアサインをいじると上書きされる。
**devで作業するあいだは止めたままにする。**

開発側の Edge Functions は本番より古い（`notion-workload-sync` v6 など）。
devで同期系を動かすなら、先に本番と同じものを入れること。

バックアップの書き出し先は本番とdevで別ブック（本番 `1Avaf…` / dev `1j6rT…`）。
devの作業で本番のブックは汚れない。読み取り元のシート（募集フォーム・契約・intake）は共有。
