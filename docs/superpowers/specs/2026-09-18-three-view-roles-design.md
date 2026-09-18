# 3ビュー（全メンバー／コアメン／管理者）と募集タブ拡充 — 設計

- 日付: 2026-09-18
- 対象: `index.html`（単一ファイルアプリ）, Edge Function `sheets-recruitment-sync`
- スコープ: A（ビュー基盤）と B（募集タブ拡充）。C（報酬算出）は本設計の対象外。

## 背景

現在このアプリの権限は「URL に `?key=<EDIT_KEY>` が付いているか」の 1 段だけで、付いていれば全編集可、付いていなければ全閲覧。全員が同じ 6 タブを見る。

ここに 3 段のビューを導入したい。

1. 全メンバー向け — 全員に開放
2. コアメン向け — 組織運営の中核メンバー
3. 管理者向け — 北村個人

あわせて、募集タブが抱える運用上の問題を解消する。募集フォームのシートを各 PJ の担当があまり更新しないため、進捗ステータスが実態とずれる。アプリ側から直接いじれるようにする。

## 決定事項（ユーザー確認済み）

| 論点 | 決定 |
|---|---|
| 認証方式 | ハイブリッド。閲覧系は URL キー。報酬データを扱う段階でメールログインを導入する |
| タブの振り分け | 積み上げ式。コアメンは「プロジェクト」タブも見る |
| 同期との競合 | アプリが勝つ。アプリで編集した値はシート同期で上書きされない |
| 報酬算出（C） | 本設計では扱わない。A・B を先に仕上げる |

## 現状の制約（重要）

- `EDIT_KEY` は `index.html` にベタ書きで、ソースを開けば読める。
- `org_state` テーブルは RLS 有効だが、anon ロールに SELECT / INSERT / UPDATE を全許可するポリシーが入っている。つまり anon キーを持つ誰でも全データを読み書きできる。

したがって **本設計で導入するロールは「UI 上の出し分け」であって、機密性の保証ではない**。個人のメアドなど、漏れて困る情報は現時点でも技術的には露出しうる。報酬額のように漏れが致命的なデータは、C の段階で別テーブル＋メールログイン＋RLS に隔離する。この前提を設計の外に持ち出さないこと。

---

## A. ビュー基盤

### ロールの決定

```js
const ROLE_KEYS = {
  admin: "kitamura-rvss-admin-2026",   // 既存 EDIT_KEY を流用
  core:  "rvss-core-2026",             // 新規発行
};
// ?key= の値がどれに一致するかでロールが決まる。一致しなければ member。
const ROLE = resolveRole(new URLSearchParams(location.search).get("key"));
```

- `ROLE` は `"member" | "core" | "admin"` の 3 値。
- 既存の `isEditMode` は `ROLE === "admin"` に置き換える。`applyMode()` / `body.view-mode` の仕組みはそのまま活かす。
- ロールバッジを h1 横に出す。member のときは非表示（今の挙動と同じ）。

URL は 3 通り。

```
/                     → member
/?key=<CORE_KEY>      → core
/?key=<ADMIN_KEY>     → admin
```

キーを localStorage に保存する機能は**作らない**。共用 PC でロールが残ると事故になるため、今と同じく URL のみで判定する。

### タブの出し分け

`BASE_TABS` の各要素に最小ロールを持たせ、`getTabs()` でフィルタする。

```js
const ROLE_RANK = { member: 0, core: 1, admin: 2 };
const BASE_TABS = [
  { id: "all",       label: "全メンバー",           minRole: "member" },
  { id: "recruit",   label: "プロジェクト募集状況", minRole: "member" },
  { id: "projects",  label: "プロジェクト",         minRole: "core" },
  { id: "community", label: "コミュニティ運営",     minRole: "core" },
  { id: "schools",   label: "スクール受講者",       minRole: "core" },
  { id: "paid",      label: "有償枠",               minRole: "core" },
];
```

- 順序は上の配列のとおり。member には「全メンバー」「プロジェクト募集状況」の 2 タブだけが出る。
- カスタムタブ（`state.customTabs`）は `minRole: "core"` 扱い。
- `currentTab` の初期値と `setTab()` は、見えないタブ ID が渡された場合に先頭タブへフォールバックする。URL 直打ちでタブ ID を指定されても、ロール外のタブは開けない。

### 編集権限

現在 `EDIT_FNS` に列挙した関数は view-mode で no-op にされている。これを 2 段にする。

```js
const ADMIN_FNS = [ ...現在の EDIT_FNS の全要素をそのまま ];
const CORE_FNS  = ["setRecruitStatus", "setRecruitWebTest", "clearRecruitOverride"]; // 新規追加する関数
```

- admin: `ADMIN_FNS` と `CORE_FNS` の両方が通る。
- core: `CORE_FNS` のみ通る。`ADMIN_FNS` は no-op。
- member: どちらも no-op。

CSS も 2 段にする。`.editor-only` は admin のみ表示（現状維持）。新設する `.core-only` は core と admin で表示。

**重要**: `.core-only` は CSS で隠すだけなので、DOM には残る。応募学生の名前とメアドは個人情報なので、**member では CSS ではなく描画時点で出力しない**（`if (roleAtLeast("core"))` で HTML 自体を組み立てない）。`.core-only` は「隠れても害の無いボタン類」にだけ使う。

| | member | core | admin |
|---|---|---|---|
| 閲覧タブ | 2 | 6 | 6（将来 +報酬） |
| 募集の進捗ステータス編集 | × | ○ | ○ |
| メンバー・PJ・部署・スクール・有償枠の編集 | × | × | ○ |
| 応募学生の名前 | × | ○ | ○ |
| 応募学生のメアド | × | ○ | ○ |

---

## B. 募集タブの拡充

### B-1. シート同期の読み取り列を増やす

`sheets-recruitment-sync` を更新する。既存の `findCol` / `normalizeHeader`（ヘッダー名での照合）をそのまま使い、**列番号は一切使わない**。以前 `sheets-contract-sync` が列挿入で壊れた件の再発防止。

追加する列と候補ヘッダー:

| フィールド | 候補ヘッダー |
|---|---|
| `summary` | `プロジェクト概要` |
| `role` | `学生に担ってほしい役割` |
| `wanted` | `求める人物像・スキル` |
| `gains` | `学生が得られるスキル・経験` |
| `feedback` | `フィードバック形式` |
| `workload` | `稼働時間と期間` |
| `owner` | `記入者（各PJのRVSS応募担当）`, `記入者` |
| `note` | `その他、アサイン担当への連絡事項` |
| `lineStatus` | `募集ステータス（LINEグループ）` |
| `studentNames` | `学生の名前` |
| `studentEmails` | `学生のメアド` |

- 既存の `timestamp` / `project` / `mentor` / `recruitStatus` / `webTestStatus` は変更しない。
- 追加列はいずれも**見つからなくてもエラーにしない**（空文字で続行）。事業名だけは従来どおり必須。追加列は表示用の付加情報であり、欠けても既存機能は動くため。
- `studentNames` / `studentEmails` は改行・読点・カンマで分割して配列にする。

### B-2. PJ 詳細の表示

募集カードにトグルを付け、開くと募集要項を表示する。member でも見える。

表示項目: 稼働時間と期間 / プロジェクト概要 / 学生に担ってほしい役割 / 求める人物像・スキル / 学生が得られるスキル・経験 / フィードバック形式 / メンター名と役職

`.core-only` にする項目: 記入者 / その他連絡事項 / 応募学生の名前 / 応募学生のメアド

空の項目は行ごと出さない。

### B-3. 応募者バイネーム

`recruitStatus` が `応募あり` / `PJ連携中` / `アサイン確定` のカードで、応募学生の名前をステータスバッジの隣に並べる。`.core-only`。

- 表示は名前のみ。メアドは詳細を開いたときだけ出す。
- アプリ内に同名のメンバーが居れば、名前をクリックでメンバーカードへ飛べるようにする（既存の name-link と同じ仕組み）。
- 募集枠ビュー・進捗ビューの両方に出す。

### B-4. 進捗ステータスをアプリから編集

`state.recruitOverrides` を新設する。

```js
state.recruitOverrides = {
  "<normalizeProjectKey(事業名)>": {
    recruitStatus: "PJ連携中",      // 省略可
    webTestStatus: "実施済み",      // 省略可
    updatedAt: "2026-09-18T12:00:00.000Z",
  },
};
```

- 表示時は「override にキーがあればその値、無ければシート由来の値」。`buildRecruitEntries()` の中で解決する。
- `sheets-recruitment-sync` は `state.recruitment` しか書き換えない。`state.recruitOverrides` には触れないため、同期でアプリの編集が消えることはない。
- 同期側に変更は不要。この分離だけで「アプリが勝つ」が成立する。
- キーは `normalizeProjectKey` の結果。アプリ側でプロジェクト名を変えても、`recruitSourceKey` 経由で同じ行に紐づく点は既存ロジックと同じ扱いにする。

UI:

- ステータスバッジを core 以上でクリック可能にし、`RECRUIT_STATUS_ORDER` の 9 値から選ぶ。Webテスト状況も同様に 3 値＋なしから選ぶ。
- override が効いているカードには「アプリで更新」の小さな印と更新日時を出す。シートの値と違うことが一目で分かるようにする。
- 各カードに「シートの値に戻す」を置く。押すと該当キーの override を削除する。
- `ensureFields` で `state.recruitOverrides` を `{}` で初期化する。

---

## データフロー

```
Googleフォーム
   ↓ 回答
募集シート（1DcALjQGfuExjzCMC5BIQdQWu0g1wI_phovmTsWtka44）
   ↓ 5時間ごと / 手動同期（sheets-recruitment-sync）
state.recruitment.rows          ← シートが正。同期のたびに全置換
   ↓
buildRecruitEntries()  ←──  state.recruitOverrides  ← アプリが正。同期は触らない
   ↓
募集タブの描画（ロールで表示項目を出し分け）
```

## エラー処理

- 追加列が見つからない場合は空文字で続行する。同期全体は失敗させない。
- `state.recruitOverrides` にシートから消えた事業名のキーが残っても放置する（害がなく、事業名が戻れば再び効く）。掃除はしない。
- 不正な `?key=` は member にフォールバックする。エラー表示はしない。

## テスト

このプロジェクトには自動テストが無く、単一 HTML をブラウザで動かして確認する運用。以下を dev（localhost → dev Supabase）で確認してから本番へ出す。

1. 3 通りの URL でタブ数が 2 / 6 / 6 になること、ロールバッジが正しいこと
2. member のコンソールから `setTab("projects")` を呼んでも開けず、先頭タブに戻ること
3. member の DOM を検索して応募学生の名前・メアドが 1 件も出ないこと（CSS で隠れているだけではないこと）
4. core でメンバー編集ボタンが出ず、ステータス変更だけができること
5. ステータスを変更 → 手動同期を実行 → 変更が残っていること
6. 「シートの値に戻す」でシート値に戻ること
7. 詳細トグルで募集要項が出ること、空項目が行ごと消えること
8. コンソールエラーが無いこと

## 本設計で扱わないもの

- C（報酬算出）。計算式・360度評価データの置き場所・Zoom 連携が未定のため。
- シートへの書き戻し。「アプリが勝つ」を選んだため不要。
- メールログイン。C に着手する時点で導入する。
- `org_state` の RLS 見直し。C とセットで扱う。

## 既知の問題（シート側の対応が必要）

- 「Lアカデミア」の行は列がずれており、`求める人物像・スキル` 欄などに事業名・メンター名が入っている。PJ 詳細を member に公開すると、この崩れがそのまま見える。
- 「CFO室」の行は Timestamp と大半の列が空で、事業名・学生名（柴田頼視）だけが入っている。詳細表示は空欄だらけになる。
