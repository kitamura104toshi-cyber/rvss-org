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

## 出席率

CSV（`attendance_payroll_YYYY-MM_開始_終了.csv`）を直近3ヶ月ぶんで渡される。
入れる先は `compensation.members[氏名].attendanceRate`、集計期間は
`compensation.attendancePeriod`（退会状況タブの注記がこれを出す）。

メンバー直下の値は「最新の集計」。**締めた月は `byMonth["YYYY-MM"].attendanceRate` に
焼き付けて固定する。** `attendanceRate` は `PAY_MONTHLY_FIELDS` に入れていないので、
固定していない月は直下の最新値が使われ、固定した月だけ当時の率で計算される。
`null` を入れれば「当時は未入力」（ペナルティあり）も再現できる。

**新しいCSVを入れる前に、締まった月を固定すること。** 入れ替えてから固定すると、
確定済みの月の金額が動く。2026-09 は確定ブック
（`1qrkqPe4cbg75ouBnSk9Hbiz_BfFbp8C05JZyDM0deyw` の報酬一覧）の
「土曜定例出席率」列から焼き付けてある。

報酬入力フォームは固定済みの月ではその月の値だけを直す（`payAttendancePinned`）。
固定していない月なら直下の最新値を直す。

CSVに載っていて報酬側に行が無い人は `attendanceRate` だけの行として足してよい。
報酬タブの顔ぶれは `buildMemberMap()` で決まるので、行が増えても人は増えない。

「稼働時間だけ取り直す」ボタンは稼働時間と按分だけを入れ替える。
360°評価・出席率・手動調整・業務内容には触らない。

プロジェクト関与の人数（按分の人数比率）は、その月の確定分にプロジェクト稼働が
あるかどうかだけで決める。平らな `projectHoursTotal` やアプリ上の所属を
フォールバックに使うと、前月に数時間関わっただけの人が関与者として残る。

予想月を先に組むときは `byMonth["YYYY-MM"]` に `assumedHours` /
`assumedProjectHours` / `assumedProjectHoursTotal` を置く。置いた月は
どのモードでもこの前提で計算し、有償枠だけを並べる（`payMonthIsAssumed`）。
経過日数で引き伸ばす予想（`payForecastFactor`）はこれが無い月のための経路。

## 過去月とスプレッドシートの数値

有償枠タブの月送り（‹ ›）は確定モードのときだけ効き、最大12ヶ月さかのぼれる（`payBack`）。
予想の2モードは当月・翌月そのものなので送れない。

**ブックの額面を正とする月は `compensation.bookRows["YYYY-MM"]` に取り込んで、そのまま出す。**
「スプシから取り込む」（`importPayBook`）が `sheets-read` で読み、`parsePayBook` が
見出し名で列を引く。その月は按分も書き出しも出さない（ブックを上書きしないため）。

2026-08 がこれ。支払い済みで、直しはスプシ側で進めている。
ブックは `1F6h9K-pEHRRAArELMx608BeCk6qcPiO4klyNC4-uJkY` の「8月報酬」タブ。
実際に支払ったときのブックは `compensation.paidSheets["2026-08"]` に残してある（差額用）。

**8月報酬タブの最終金額・出席率ペナルティは式ではなく直値。** 出席率を書き換えても追従しない。
最終金額 ＝ 稼働40h未満なら0、それ以外は 80000 ＋ 稼働ペナ ＋ 出席ペナ ＋ 360加算 ＋ スクール ＋ マネージャー報酬
（49行すべてで再現を確認済み）。合計行だけは SUM の式。

**9月分までの出席率の評価期間は4〜6月**（土曜13回）。直近3ヶ月ではない。
評価対象外の人は100%扱い＝ペナルティなしで、セルは空にする。

## 開発環境（dev）は新システムになった

**2026-10-04 から、dev の Supabase（`vsqrgcsobweaupiabagu`）は新しいスプシ中心のシステムの本体。**
本番の写しではない。コードは `../組織管理v2/`（別の git リポジトリ）にある。詳しくはそちらの CLAUDE.md。

- **本番の作業の確認に dev を使わない。** dev のデータも関数も本番とは別物になった
- dev の cron は動いている（5分ごとのスプシ同期を含む）。止めると新システムが止まる
- この `index.html` を localhost で開くと、今も dev に接続する。**dev のデータを編集しないこと**
  （新システムの名簿・報酬と食い違う）。本番の画面を見るなら rvss-org-zeta を開く
- 2026-10-04 に dev を本番の写しで入れ替えてから分岐させた。入れ替え前の dev は
  `org_state` の `id='backup-20261004-pre-v2'`、その前は `id='backup-20261003-pre-refresh'` に退避してある
- dev から本番へ書く経路は無い。共有している取り込み元のシート（募集フォーム・契約・採用管理）は
  新システムからは読むだけ

## 退会状況

在籍・入会の起点は参画日（`attrition.members[氏名].enrolledAt`）。社会人メンター（BS）は母集団から外す。

参画日の出どころは採用管理（`1WYReaAezfisxkZh5G1r70VLhMdU8qJwLAK7ytZ2PN70`）の
**育成連携シートのG列「入会日」**。候補者マスターは氏名の表記がゆれる
（例：育成連携「上坂茉子」＝候補者マスター「うえさかまこ」）ので、人数はG列で数える。
メンバー名簿メアド（`1k23DRZ0ztRXmT_MMZhC2jWQ4redXcpiosVSZESlDm9s`）には
行が無い人もいるため、名簿だけで数えると足りない。

**週は月曜はじまりの7日間。** 月をまたぐ週は、7日のうち4日以上が入っているほうの月に数える
（4日以上になるのは必ず片方だけなので、どこにも入らない週・二重に数える週は出ない）。
2026年10月なら 9/28〜10/4／10/5〜10/11／10/12〜10/18／10/19〜10/25／10/26〜11/1 の5週。

**月次は暦の月（1日〜月末）のまま**なので、週次の合計は月次と一致しない。
9/28入会の2名は9月の月次に入るが、週次では10月第1週に出る。

週カードは ‹ › で送る（`attritionWeek` / `moveAttritionWeek`）。既定は今日が入っている週。
