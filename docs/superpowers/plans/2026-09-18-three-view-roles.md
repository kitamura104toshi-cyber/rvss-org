# 3ビュー（member / core / admin）と募集タブ拡充 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 全メンバー／コアメン／管理者の3ロールでタブと編集権限を出し分け、募集タブに募集要項・応募者名・アプリ側からの進捗ステータス編集を追加する。

**Architecture:** `index.html` は単一ファイル。URL の `?key=` から `ROLE`（`member`/`core`/`admin`）を決め、`BASE_TABS` の `minRole` でタブを絞り、関数ガードを2段にする。募集データはシート由来（`state.recruitment.rows`、同期のたび全置換）とアプリ由来（`state.recruitOverrides`、同期は触らない）の2層に分け、描画時に「override があればそれ、無ければシート値」で解決する。

**Tech Stack:** 素の HTML/CSS/JS（ビルドなし、CRLF 改行）、Supabase JS CDN クライアント、Supabase Edge Functions（Deno / TypeScript）、Google Sheets API v4。

**Spec:** `docs/superpowers/specs/2026-09-18-three-view-roles-design.md`（コミット `f1691d1`）

## Global Constraints

- `index.html` は **CRLF 改行**。エディタツールで編集し、改行コードを変えないこと。
- 自動テストは存在しない。検証は **dev（localhost → dev Supabase）でブラウザ実行**して行う。プレビューは `preview_start` の `static`（ポート 5173）を使う。`file://` で開くと本番 Supabase に繋がるので使わない。
- 本番 Supabase: `dbrwsrrfmpnvpzxcdupp` / dev Supabase: `vsqrgcsobweaupiabagu`。`IS_LOCAL_DEV`（hostname が localhost / 127.0.0.1）で自動切替。
- Edge Function は **必ず dev に先にデプロイして検証**してから本番へ。
- Edge Function をブラウザ以外から叩くときは `curl` ではなく `execute_sql` 経由の `net.http_post`（anon キーを Authorization と apikey の両方に入れる）を使い、`net._http_response` を request_id で読む。
- シートの列は **必ずヘッダー名で引く**（`findCol` / `normalizeHeader`）。列番号を使わない。
- ロールキー: admin = `kitamura-rvss-admin-2026`（既存）、core = `rvss-core-2026`（新規）。
- 応募学生の名前とメアドは、member では **CSS で隠すのではなく HTML を生成しない**。
- git のリモートは `origin`（OneDrive のローカルパス、古い）ではなく `https://github.com/kitamura104toshi-cyber/rvss-org.git` に直接 push する。

---

## File Structure

| ファイル | 役割 | 変更 |
|---|---|---|
| `index.html` | アプリ全体（状態・描画・操作） | 変更 |
| Edge Function `sheets-recruitment-sync` | 募集シート → `state.recruitment` | 変更（dev → prod） |
| `docs/superpowers/specs/2026-09-18-three-view-roles-design.md` | 設計 | 変更なし |

`index.html` は単一ファイル構成を維持する。分割はこの計画の範囲外。

---

### Task 1: ロール判定とタブの出し分け

**Files:**
- Modify: `index.html`（`EDIT_KEY` 定義 / `applyMode` / `updateModeBadge` / `BASE_TABS` / `getTabs` / `setTab` / `currentTab` 初期値 / CSS）

**Interfaces:**
- Consumes: なし
- Produces: `ROLE`（`"member" | "core" | "admin"`）, `roleAtLeast(minRole: string): boolean`, `isEditMode`（`ROLE === "admin"` のエイリアス、既存コードが参照し続ける）, `BASE_TABS` の各要素が `minRole` を持つ

- [ ] **Step 1: ロール判定に差し替える**

`index.html` の以下のブロック（`// ====== 編集モード判定（URLパラメータで切り替え） ======` から `const isEditMode = ...` まで）を丸ごと置き換える。

```js
// ====== ロール判定（URLパラメータで切り替え） ======
// 共有URL: /                     → member（2タブ・編集不可）
// コアメン: /?key=rvss-core-2026 → core（6タブ・募集の進捗ステータスだけ編集可）
// 管理者:   /?key=<ADMIN_KEY>    → admin（全タブ・全編集可）
// キーは index.html に含まれるので機密性の保証ではない。あくまでUI上の出し分けとして扱う。
const ROLE_KEYS = {
  admin: "kitamura-rvss-admin-2026",
  core:  "rvss-core-2026",
};
const ROLE_RANK = { member: 0, core: 1, admin: 2 };
function resolveRole(key) {
  if (key === ROLE_KEYS.admin) return "admin";
  if (key === ROLE_KEYS.core) return "core";
  return "member";
}
const ROLE = resolveRole(new URLSearchParams(location.search).get("key"));
function roleAtLeast(r) { return ROLE_RANK[ROLE] >= ROLE_RANK[r]; }
// 既存コードは isEditMode を参照し続けるので、admin のエイリアスとして残す
const isEditMode = ROLE === "admin";
```

- [ ] **Step 2: `applyMode` と `updateModeBadge` をロール対応にする**

`applyMode` の本体を置き換える。

```js
function applyMode() {
  document.body.classList.toggle("view-mode", !isEditMode);
  document.body.classList.toggle("core-mode", roleAtLeast("core"));
  updateModeBadge();
}
```

`updateModeBadge` の `if (isEditMode) { ... } else { ... }` の部分を置き換える。

```js
  if (ROLE === "admin") {
    badge.textContent = "管理者モード";
    badge.className = "mode-badge edit";
    badge.style.display = "";
  } else if (ROLE === "core") {
    badge.textContent = "コアメンバー";
    badge.className = "mode-badge view";
    badge.style.display = "";
  } else {
    badge.style.display = "none";
  }
```

- [ ] **Step 3: `.core-only` の CSS を足す**

`body.view-mode .editor-only { display: none !important; }` の直後の行に足す。

```css
  body:not(.core-mode) .core-only { display: none !important; }
```

- [ ] **Step 4: `BASE_TABS` に `minRole` を持たせ、順序を変える**

`let currentTab = "projects";` から `getTabs()` の終わりまでを置き換える。

```js
// 上位ロールは下位ロールのタブをすべて含む（積み上げ式）
const BASE_TABS = [
  { id: "all",       label: "全メンバー",           minRole: "member" },
  { id: "recruit",   label: "プロジェクト募集状況", minRole: "member" },
  { id: "projects",  label: "プロジェクト",         minRole: "core" },
  { id: "community", label: "コミュニティ運営",     minRole: "core" },
  { id: "schools",   label: "スクール受講者",       minRole: "core" },
  { id: "paid",      label: "有償枠",               minRole: "core" },
];
// core 以上は今までどおりプロジェクトタブから始める。member は先頭の全メンバー。
let currentTab = roleAtLeast("core") ? "projects" : "all";
function getTabs() {
  const base = BASE_TABS.filter(t => roleAtLeast(t.minRole));
  if (!roleAtLeast("core")) return base;
  return base.concat(state.customTabs.map(t => ({ id: t.id, label: t.label, custom: true, minRole: "core" })));
}
```

- [ ] **Step 5: `setTab` に見えないタブへのフォールバックを足す**

既存の `function setTab(id) { currentTab = id; render(); }` を置き換える。

```js
function setTab(id) {
  const tabs = getTabs();
  currentTab = tabs.some(t => t.id === id) ? id : ((tabs[0] || {}).id || "all");
  render();
}
```

- [ ] **Step 6: 構文チェック**

Run:
```bash
node -e "const h=require('fs').readFileSync('index.html','utf8');new Function(h.match(/<script>([\s\S]*)<\/script>/)[1]);console.log('JS parse OK')"
```
Expected: `JS parse OK`

- [ ] **Step 7: dev プレビューで3ロールを確認**

`preview_start` で `static` を起動し、次の3つの URL をそれぞれ開いて確認する。

| URL | 期待するタブ数 | 期待するバッジ |
|---|---|---|
| `http://localhost:5173/` | 2（全メンバー・プロジェクト募集状況） | 非表示 |
| `http://localhost:5173/?key=rvss-core-2026` | 6 | コアメンバー |
| `http://localhost:5173/?key=kitamura-rvss-admin-2026` | 6 | 管理者モード |

各ページで次を実行して確かめる。

```js
({
  role: ROLE,
  tabs: [...document.querySelectorAll('#tabs .tab')].map(t => t.textContent.trim()),
  badge: (document.getElementById('mode-badge') || {}).textContent,
})
```

member の URL で次を実行し、`"all"` に戻ること（`"projects"` にならないこと）を確認する。

```js
setTab('projects'); currentTab
```

コンソールエラーが 0 件であることも確認する。

- [ ] **Step 8: コミット**

```bash
git add index.html
git commit -m "Split access into member, core and admin roles"
```

---

### Task 2: 編集権限を2段にする

**Files:**
- Modify: `index.html`（末尾の `const EDIT_FNS = [...]` と `if (!isEditMode) { ... }` のブロック）

**Interfaces:**
- Consumes: `ROLE`, `roleAtLeast`（Task 1）
- Produces: `ADMIN_FNS: string[]`, `CORE_FNS: string[]`。Task 4 で追加する `setRecruitStatus` / `setRecruitWebTest` / `clearRecruitOverride` は `CORE_FNS` に先に名前だけ載せておく（ガードは `typeof window[fn] === "function"` を見るので、未定義でも安全）。

- [ ] **Step 1: ガードを2段に書き換える**

`const EDIT_FNS = [` から `}` （`if (!isEditMode) { ... }` の閉じ）までを丸ごと置き換える。`render();` より前に置くこと。

```js
// admin だけが実行できる操作（メンバー・PJ・部署・スクール・有償枠の編集すべて）
const ADMIN_FNS = [
  "addProject","editProject","saveProject","deleteProject","addToProject","removeFromProject",
  "addPaidMember","removePaidMember",
  "addProjectGroup","deleteProjectGroup","renameProjectGroup","addProjectGroupMember",
  "removeProjectGroupMember",
  "addDept","renameDept","addDeptLead","removeDeptLead",
  "addGroup","deleteGroup","renameGroup","addGroupMember","removeGroupMember",
  "addSubGroup","deleteSubGroup","renameSubGroup","addSubGroupMember","removeSubGroupMember",
  "addSchool","deleteSchool","setSchoolLead","addSchoolStudent","removeSchoolStudent",
  "addMember","editMember","saveMemberEdit","deleteMember","restoreMember",
  "editSlotMember","saveSlotMember","reorderItem",
  "toggleNdaSigned","toggleOutsourcingSigned",
  "addCustomTab","deleteCustomTab",
  "resetData",
  "backupToSheets","syncRecruitment",
];
// core 以上が実行できる操作（募集の進捗ステータスまわりだけ）
const CORE_FNS = ["setRecruitStatus", "setRecruitWebTest", "clearRecruitOverride"];

const disableFns = (names) => names.forEach(fn => {
  if (typeof window[fn] === "function") {
    window[fn] = function () { /* このロールでは実行不可 */ };
  }
});
if (!roleAtLeast("admin")) disableFns(ADMIN_FNS);
if (!roleAtLeast("core")) disableFns(CORE_FNS);
```

- [ ] **Step 2: 構文チェック**

Run:
```bash
node -e "const h=require('fs').readFileSync('index.html','utf8');new Function(h.match(/<script>([\s\S]*)<\/script>/)[1]);console.log('JS parse OK')"
```
Expected: `JS parse OK`

- [ ] **Step 3: dev でガードを確認**

`http://localhost:5173/?key=rvss-core-2026` を開いて実行する。

```js
({
  adminBlocked: (function(){ const before = state.projects.length; addProject(); return state.projects.length === before; })(),
  coreFnsStillFunctions: CORE_FNS.every(f => typeof window[f] === "function" || window[f] === undefined),
})
```
Expected: `adminBlocked: true`

`http://localhost:5173/` （member）でも同じ `adminBlocked: true` になること。
`?key=kitamura-rvss-admin-2026` では `addProject()` がモーダルを開くこと（開いたら閉じる）。

- [ ] **Step 4: コミット**

```bash
git add index.html
git commit -m "Let core members run only the recruitment status actions"
```

---

### Task 3: 募集シートの読み取り列を増やす

**Files:**
- Modify: Edge Function `sheets-recruitment-sync`（dev `vsqrgcsobweaupiabagu` → prod `dbrwsrrfmpnvpzxcdupp`）

**Interfaces:**
- Consumes: なし
- Produces: `state.recruitment.rows[]` の各要素に次のフィールドが増える。Task 5 が参照する。

```ts
{
  // 既存
  rowNumber: number; timestamp: string; project: string; mentor: string;
  recruitStatusRaw: string; recruitStatus: string;
  webTestRaw: string; webTestStatus: string; webTestRequested: boolean;
  // 追加
  summary: string; role: string; wanted: string; gains: string;
  feedback: string; workload: string; owner: string; note: string;
  lineStatus: string;
  studentNames: string[]; studentEmails: string[];
}
```

- [ ] **Step 1: 現在のソースを取得する**

`get_edge_function`（project_id: `dbrwsrrfmpnvpzxcdupp`, function_slug: `sheets-recruitment-sync`）で `index.ts` の中身を取り出し、スクラッチパッドに保存する。これをベースに編集する。

- [ ] **Step 2: 列定義と行の組み立てを差し替える**

`fetchRecruitRows` の中の `const col = { ... };` を置き換える。

```ts
  const col = {
    timestamp: findCol(headers, ["Timestamp", "タイムスタンプ"]),
    project: findCol(headers, ["事業名（プロジェクト名）", "事業名", "プロジェクト名"]),
    mentor: findCol(headers, ["メンターのお名前と役職", "メンター"]),
    recruit: findCol(headers, ["学生募集状況"]),
    webTest: findCol(headers, ["WEBテスト実施状況", "WEBテスト"]),
    // ここから追加。見つからなくてもエラーにしない（表示用の付加情報のため）
    summary: findCol(headers, ["プロジェクト概要"]),
    role: findCol(headers, ["学生に担ってほしい役割"]),
    wanted: findCol(headers, ["求める人物像・スキル"]),
    gains: findCol(headers, ["学生が得られるスキル・経験"]),
    feedback: findCol(headers, ["フィードバック形式"]),
    workload: findCol(headers, ["稼働時間と期間"]),
    owner: findCol(headers, ["記入者（各PJのRVSS応募担当）", "記入者"]),
    note: findCol(headers, ["その他、アサイン担当への連絡事項"]),
    lineStatus: findCol(headers, ["募集ステータス（LINEグループ）"]),
    studentNames: findCol(headers, ["学生の名前"]),
    studentEmails: findCol(headers, ["学生のメアド"]),
  };
```

同じ `fetchRecruitRows` の中、`const pick = ...` の直後に分割ヘルパーを足す。

```ts
  // 「金島匠音, 柴田頼視」「改行区切り」どちらでも配列にする
  const pickList = (row: any[], idx: number) =>
    pick(row, idx).split(/[\n、,，]+/).map((s) => s.trim()).filter(Boolean);
```

`const entry = { ... };` に追加フィールドを差し込む（`_tsMs` の直前に置く）。

```ts
      summary: pick(row, col.summary),
      role: pick(row, col.role),
      wanted: pick(row, col.wanted),
      gains: pick(row, col.gains),
      feedback: pick(row, col.feedback),
      workload: pick(row, col.workload),
      owner: pick(row, col.owner),
      note: pick(row, col.note),
      lineStatus: pick(row, col.lineStatus),
      studentNames: pickList(row, col.studentNames),
      studentEmails: pickList(row, col.studentEmails),
```

- [ ] **Step 3: 冒頭コメントを実態に合わせる**

ファイル先頭の

```
// アプリへ取り込むのは「事業名・メンター・学生募集状況・WEBテスト実施状況」の4項目のみ。
```

を次に置き換える。

```
// アプリへ取り込むのは事業名・メンター・学生募集状況・WEBテスト実施状況に加え、
// 募集要項（概要・役割・求める人物像・得られるスキル・FB形式・稼働時間）と
// 応募学生の名前／メアド。列は必ずヘッダー名で引き、列番号は使わない。
```

- [ ] **Step 4: dev にデプロイする**

`deploy_edge_function`（project_id: `vsqrgcsobweaupiabagu`, name: `sheets-recruitment-sync`, entrypoint_path: `index.ts`, verify_jwt: `true`）。

日本語は `\uXXXX` エスケープで送る。エスケープ版はスクラッチパッドで生成する。

```bash
node -e "const fs=require('fs');const p=process.argv[1];const s=fs.readFileSync(p,'utf8');fs.writeFileSync(p+'.esc',s.replace(/[^\x00-\x7F]/g,c=>'\\\\u'+c.charCodeAt(0).toString(16).padStart(4,'0')));console.log('ok')" <スクラッチパッドのts>
```

- [ ] **Step 5: dev で同期を実行して結果を見る**

`execute_sql`（project_id: `vsqrgcsobweaupiabagu`）で叩く。`<DEV_ANON_KEY>` は `index.html` の `DEV_SUPABASE_ANON_KEY` の値。

```sql
select net.http_post(
  url := 'https://vsqrgcsobweaupiabagu.supabase.co/functions/v1/sheets-recruitment-sync',
  headers := jsonb_build_object(
    'Authorization', 'Bearer <DEV_ANON_KEY>',
    'apikey', '<DEV_ANON_KEY>',
    'Content-Type', 'application/json'),
  body := '{}'::jsonb,
  timeout_milliseconds := 60000
) as request_id;
```

返った id で結果を読む。

```sql
select status_code, left(content, 800) as content, error_msg from net._http_response where id = <request_id>;
```
Expected: `status_code: 200`, `ok: true`

- [ ] **Step 6: 追加フィールドが入ったことを確認する**

`execute_sql`（project_id: `vsqrgcsobweaupiabagu`）:

```sql
select r->>'project' as project,
       left(r->>'summary', 40) as summary,
       r->'studentNames' as student_names,
       r->>'workload' as workload
from org_state, jsonb_array_elements(data->'recruitment'->'rows') r
where id='main';
```
Expected: `AX＋` の行に `summary` が入り、`student_names` が `["金島匠音"]` になっていること。`CFO室` の行の `student_names` が `["柴田　頼視"]`（全角スペース込み）になっていること。

- [ ] **Step 7: 本番にデプロイして同期する**

Step 4 と同じ内容を project_id `dbrwsrrfmpnvpzxcdupp` にデプロイし、Step 5 と同じ手順で本番 URL（`https://dbrwsrrfmpnvpzxcdupp.supabase.co/functions/v1/sheets-recruitment-sync`）と本番 anon キーを使って1回実行する。Step 6 と同じ確認を本番で行う。

- [ ] **Step 8: コミット**

Edge Function はリポジトリに入っていないため、記録だけ残す。

```bash
git commit --allow-empty -m "Read the recruitment form's detail columns in the sync function"
```

---

### Task 4: アプリ側から進捗ステータスを編集する

**Files:**
- Modify: `index.html`（`ensureFields` / `buildRecruitEntries` / `renderRecruitCardStudent` / `renderRecruitCardProgress` / 操作関数の追加）

**Interfaces:**
- Consumes: `roleAtLeast`（Task 1）, `CORE_FNS`（Task 2）, `normalizeProjectKey`（既存）, `save()` / `render()`（既存）
- Produces:
  - `state.recruitOverrides: Record<string, { recruitStatus?: string; webTestStatus?: string; updatedAt: string }>`
  - `recruitKeyOf(e): string` — エントリから override のキーを返す
  - `resolveRecruitStatus(e): string` / `resolveWebTestStatus(e): string`
  - `hasRecruitOverride(e): boolean` / `recruitOverrideAt(e): string`
  - `setRecruitStatus(key, value)` / `setRecruitWebTest(key, value)` / `clearRecruitOverride(key)`
  - `buildRecruitEntries()` の返す各要素に `key`（override キー）が増える

- [ ] **Step 1: `ensureFields` に初期化を足す**

`if (!s.recruitment) s.recruitment = { syncedAt: "", rows: [] };` の直後に足す。

```js
  // アプリ側で上書きした募集ステータス。同期（sheets-recruitment-sync）はこの層に触らないので、
  // 5時間ごとの取り込みでアプリの編集が消えることはない。
  if (!s.recruitOverrides) s.recruitOverrides = {};
```

- [ ] **Step 2: エントリにキーを持たせ、解決関数を足す**

`buildRecruitEntries()` の中、`const entries = state.projects.map(p => { ... })` の `return` を置き換える。

```js
    return { key: srcKey || nameKey, name: p.name, project: p, row: row || null };
```

同じ関数の `latestByKey.forEach((r, key) => { ... })` の中身を置き換える。

```js
    if (!used.has(key)) entries.push({ key, name: r.project, project: null, row: r });
```

`rank` の定義を、override 後のステータスで並ぶように置き換える。

```js
  const rank = e => {
    const i = RECRUIT_STATUS_ORDER.indexOf(resolveRecruitStatus(e));
    return i < 0 ? RECRUIT_STATUS_ORDER.length : i;
  };
```

`buildRecruitEntries` の直前に解決関数を足す。

```js
// 表示するステータスは「アプリの上書きがあればそれ、無ければシート由来の値」。
function recruitOverrideOf(e) {
  return (state.recruitOverrides || {})[e.key] || null;
}
function resolveRecruitStatus(e) {
  const ov = recruitOverrideOf(e);
  if (ov && ov.recruitStatus) return ov.recruitStatus;
  return e.row ? e.row.recruitStatus : "未募集";
}
function resolveWebTestStatus(e) {
  const ov = recruitOverrideOf(e);
  if (ov && typeof ov.webTestStatus === "string") return ov.webTestStatus;
  return e.row ? e.row.webTestStatus : "";
}
function hasRecruitOverride(e) {
  const ov = recruitOverrideOf(e);
  return !!(ov && (ov.recruitStatus || typeof ov.webTestStatus === "string"));
}
function recruitOverrideAt(e) {
  const ov = recruitOverrideOf(e);
  if (!ov || !ov.updatedAt) return "";
  return new Date(ov.updatedAt).toLocaleString("ja-JP", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" });
}
```

- [ ] **Step 3: 操作関数を足す**

`function onRecruitViewChange(v) { ... }` の直後に足す。

```js
// core 以上が募集の進捗ステータスを直接いじるための操作。
// シート側を更新しない運用になっているため、アプリの値を正とする。
function setRecruitOverrideField(key, field, value) {
  if (!key) return;
  if (!state.recruitOverrides) state.recruitOverrides = {};
  const cur = state.recruitOverrides[key] || {};
  state.recruitOverrides[key] = { ...cur, [field]: value, updatedAt: new Date().toISOString() };
  save(); render();
}
function setRecruitStatus(key, value) { setRecruitOverrideField(key, "recruitStatus", value); }
function setRecruitWebTest(key, value) { setRecruitOverrideField(key, "webTestStatus", value); }
function clearRecruitOverride(key) {
  if (!key || !state.recruitOverrides) return;
  delete state.recruitOverrides[key];
  save(); render();
}
```

- [ ] **Step 4: カードにステータス編集 UI を足す**

`recruitMentor(e)` の直後に、両方のカードから使う共通パーツを足す。

```js
// core 以上には <select> を出し、member にはバッジだけを出す。
function recruitStatusControlHTML(e) {
  const status = resolveRecruitStatus(e);
  if (!roleAtLeast("core")) return recruitStatusTagHTML(status);
  const opts = RECRUIT_STATUS_ORDER.map(s =>
    `<option value="${escapeHtml(s)}"${s === status ? " selected" : ""}>${escapeHtml(s)}</option>`).join("");
  return `<select class="recruit-select" style="${recruitStatusStyle(status)}" onchange="setRecruitStatus('${escapeHtml(e.key)}', this.value)">${opts}</select>`;
}
const WEBTEST_CHOICES = ["", "発行依頼中", "実施中", "実施済み"];
function recruitWebTestControlHTML(e) {
  const v = resolveWebTestStatus(e);
  if (!roleAtLeast("core")) {
    return v
      ? `<span class="tag" style="${WEBTEST_STATUS_STYLE[v] || "background:#f0eee7;color:#6b6b6b"}">${escapeHtml(v)}</span>`
      : `<span class="tag" style="background:#f0eee7;color:#6b6b6b">なし</span>`;
  }
  const opts = WEBTEST_CHOICES.map(s =>
    `<option value="${escapeHtml(s)}"${s === v ? " selected" : ""}>${s ? escapeHtml(s) : "なし"}</option>`).join("");
  return `<select class="recruit-select" style="${WEBTEST_STATUS_STYLE[v] || "background:#f0eee7;color:#6b6b6b"}" onchange="setRecruitWebTest('${escapeHtml(e.key)}', this.value)">${opts}</select>`;
}
// アプリで上書きされていることを示す印と、シートの値に戻すボタン
function recruitOverrideNoteHTML(e) {
  if (!hasRecruitOverride(e)) return "";
  const at = recruitOverrideAt(e);
  return `<div style="margin-top:8px;font-size:11px;color:var(--muted);display:flex;align-items:center;gap:6px;flex-wrap:wrap">
    <span class="tag" style="background:var(--blue);color:var(--blue-text);font-size:11px">アプリで更新${at ? " " + escapeHtml(at) : ""}</span>
    <span class="core-only" style="cursor:pointer;text-decoration:underline" onclick="clearRecruitOverride('${escapeHtml(e.key)}')">シートの値に戻す</span>
  </div>`;
}
```

CSS に `.recruit-select` を足す（`.mode-badge` の定義の直前あたり）。

```css
  .recruit-select {
    border: none; border-radius: 999px; padding: 4px 10px;
    font-size: 12px; font-weight: 600; cursor: pointer; font-family: inherit;
  }
```

- [ ] **Step 5: 2つのカードを新しいパーツに繋ぎ替える**

`renderRecruitCardStudent` の先頭の `const status = r ? r.recruitStatus : "未募集";` を置き換える。

```js
  const status = resolveRecruitStatus(e);
```

同関数の `webTest` の定義を置き換える。

```js
  const webTestStatus = resolveWebTestStatus(e);
  const webTest = webTestStatus
    ? ` <span class="tag" style="background:#f5f3ed;color:#6b6b6b;border:1px solid #e5e3dc">Webテスト必須・${escapeHtml(webTestStatus)}</span>`
    : "";
```

同関数の最後のステータス行を置き換える。

```js
      <div style="display:flex;flex-wrap:wrap;gap:4px;align-items:center">
        ${recruitStatusControlHTML(e)}${webTest}
      </div>
      ${recruitOverrideNoteHTML(e)}
```

`renderRecruitCardProgress` の `const status = r ? r.recruitStatus : "未募集";` も同じく `resolveRecruitStatus(e)` に置き換える。`body` の `idx < 0` の分岐を置き換える。

```js
  const body = idx < 0
    ? `<div style="margin:12px 0">${recruitStatusControlHTML(e)}</div>`
    : `<div class="track">${RECRUIT_STEPS.map((s, i) => `
        <div class="step ${i <= idx ? "done" : ""} ${i === idx ? "current" : ""}">
          <div class="bar"></div><div class="lbl">${s}</div>
        </div>`).join("")}</div>`;
```

同関数の最後のブロックを置き換える（トラック表示のときもステータスを変えられるようにする）。

```js
      <div style="padding-top:8px;border-top:1px dashed var(--border)">
        ${infoRow("ステータス", recruitStatusControlHTML(e))}
        ${infoRow("メンター", escapeHtml(mentor))}
        ${infoRow("Webテスト", recruitWebTestControlHTML(e))}
      </div>
      ${recruitOverrideNoteHTML(e)}
```

- [ ] **Step 6: 構文チェック**

Run:
```bash
node -e "const h=require('fs').readFileSync('index.html','utf8');new Function(h.match(/<script>([\s\S]*)<\/script>/)[1]);console.log('JS parse OK')"
```
Expected: `JS parse OK`

- [ ] **Step 7: dev で上書きの挙動を確認**

`http://localhost:5173/?key=rvss-core-2026` の募集タブで実行する。

```js
setTab('recruit');
const e = buildRecruitEntries().find(x => x.name.includes('AX'));
const before = resolveRecruitStatus(e);
setRecruitStatus(e.key, 'PJ連携中');
const after = resolveRecruitStatus(buildRecruitEntries().find(x => x.key === e.key));
({ key: e.key, before, after, overrides: JSON.stringify(state.recruitOverrides) })
```
Expected: `after: "PJ連携中"`、`overrides` に該当キーが入っていること。

続けて dev の同期を実行する（Task 3 Step 5 と同じ SQL）。完了後にページをリロードして実行する。

```js
setTab('recruit');
const e = buildRecruitEntries().find(x => x.name.includes('AX'));
({ afterSync: resolveRecruitStatus(e), sheetValue: e.row && e.row.recruitStatus })
```
Expected: `afterSync: "PJ連携中"`（同期後も残っている）、`sheetValue` はシートの元の値のまま。

「シートの値に戻す」を押す代わりに次を実行して戻ることを確認する。

```js
const e = buildRecruitEntries().find(x => x.name.includes('AX'));
clearRecruitOverride(e.key);
resolveRecruitStatus(buildRecruitEntries().find(x => x.key === e.key))
```
Expected: シートの元の値に戻ること。

member の URL（`http://localhost:5173/`）で `document.querySelectorAll('.recruit-select').length` が `0` になることも確認する。

- [ ] **Step 8: コミット**

```bash
git add index.html
git commit -m "Let core members override the recruitment status in the app"
```

---

### Task 5: 募集要項の詳細表示と応募者バイネーム

**Files:**
- Modify: `index.html`（`renderRecruitCardStudent` / `renderRecruitCardProgress` / CSS / 開閉状態の保持）

**Interfaces:**
- Consumes: Task 3 が増やした `row.summary` ほか、`roleAtLeast`（Task 1）, `resolveRecruitStatus`（Task 4）, `goToMemberCard`（既存）, `buildMemberMap`（既存）
- Produces: `recruitDetailHTML(e): string`, `recruitApplicantsHTML(e): string`, `toggleRecruitDetail(key)`, `openRecruitKeys: Set<string>`

- [ ] **Step 1: 開閉状態と詳細ブロックを足す**

`recruitOverrideNoteHTML` の直後に足す。

```js
// 詳細は既定で閉じる。開いたカードだけ覚えておき、再描画しても開いたままにする。
const openRecruitKeys = new Set();
function toggleRecruitDetail(key) {
  if (openRecruitKeys.has(key)) openRecruitKeys.delete(key);
  else openRecruitKeys.add(key);
  const el = document.getElementById("content");
  if (el) el.innerHTML = renderRecruit();
}

// 応募している学生の名前。個人情報なので member では HTML を組み立てない。
const APPLICANT_STATUSES = ["応募あり", "PJ連携中", "アサイン確定", "アサイン済み"];
function recruitApplicantsHTML(e) {
  if (!roleAtLeast("core")) return "";
  const names = (e.row && e.row.studentNames) || [];
  if (names.length === 0) return "";
  if (!APPLICANT_STATUSES.includes(resolveRecruitStatus(e))) return "";
  const known = buildMemberMap();
  const chips = names.map(n => {
    const key = String(n).replace(/[\s　]/g, "");
    const hit = Object.keys(known).find(m => m.replace(/[\s　]/g, "") === key);
    return hit
      ? `<span class="tag name-link" style="background:var(--green);color:var(--green-text)" onclick="goToMemberCard('${escapeHtml(hit)}')">${escapeHtml(n)}</span>`
      : `<span class="tag" style="background:var(--green);color:var(--green-text)">${escapeHtml(n)}</span>`;
  }).join(" ");
  return `<div style="margin-top:8px;display:flex;flex-wrap:wrap;gap:4px;align-items:center">
    <span style="font-size:11px;color:var(--muted);margin-right:2px">応募</span>${chips}
  </div>`;
}

// 募集要項。member にも見せる項目と core 以上だけの項目を分ける。
function recruitDetailHTML(e) {
  const r = e.row;
  if (!r) return "";
  const open = openRecruitKeys.has(e.key);
  const rows = [
    ["稼働時間と期間", r.workload],
    ["プロジェクト概要", r.summary],
    ["担ってほしい役割", r.role],
    ["求める人物像・スキル", r.wanted],
    ["得られるスキル・経験", r.gains],
    ["フィードバック形式", r.feedback],
    ["メンター", r.mentor],
  ];
  if (roleAtLeast("core")) {
    rows.push(["記入者", r.owner]);
    rows.push(["連絡事項", r.note]);
    rows.push(["応募者メアド", ((r.studentEmails || []).join("、"))]);
  }
  const filled = rows.filter(([, v]) => v);
  if (filled.length === 0) return "";
  const body = open
    ? `<div class="recruit-detail">${filled.map(([k, v]) =>
        `<div class="section-label">${escapeHtml(k)}</div>
         <div class="recruit-detail-v">${escapeHtml(v)}</div>`).join("")}</div>`
    : "";
  return `<div style="margin-top:10px;padding-top:8px;border-top:1px dashed var(--border)">
    <span style="font-size:12px;color:var(--accent);cursor:pointer" onclick="toggleRecruitDetail('${escapeHtml(e.key)}')">${open ? "▲ 募集要項を閉じる" : "▼ 募集要項を見る"}</span>
    ${body}
  </div>`;
}
```

CSS に足す（`.recruit-select` の直後）。

```css
  .recruit-detail { margin-top: 8px; }
  .recruit-detail-v {
    font-size: 12px; line-height: 1.7; white-space: pre-wrap;
    margin-bottom: 10px; color: var(--text);
  }
```

- [ ] **Step 2: 2つのカードに差し込む**

`renderRecruitCardStudent` の `${recruitOverrideNoteHTML(e)}` の直後に足す。

```js
      ${recruitApplicantsHTML(e)}
      ${recruitDetailHTML(e)}
```

`renderRecruitCardProgress` の `${recruitOverrideNoteHTML(e)}` の直後にも同じ2行を足す。

- [ ] **Step 3: 構文チェック**

Run:
```bash
node -e "const h=require('fs').readFileSync('index.html','utf8');new Function(h.match(/<script>([\s\S]*)<\/script>/)[1]);console.log('JS parse OK')"
```
Expected: `JS parse OK`

- [ ] **Step 4: member で個人情報が DOM に出ないことを確認**

`http://localhost:5173/` を開いて実行する。

```js
setTab('recruit');
const names = (state.recruitment.rows || []).flatMap(r => r.studentNames || []);
const emails = (state.recruitment.rows || []).flatMap(r => r.studentEmails || []);
const html = document.getElementById('content').innerHTML;
({
  sampleNames: names, sampleEmails: emails,
  nameLeaks: names.filter(n => html.includes(n)),
  emailLeaks: emails.filter(x => html.includes(x)),
  selects: document.querySelectorAll('.recruit-select').length,
})
```
Expected: `nameLeaks: []`, `emailLeaks: []`, `selects: 0`。`sampleNames` は空でないこと（空なら Task 3 の同期が効いていないので先に直す）。

- [ ] **Step 5: core で応募者名と詳細が出ることを確認**

`http://localhost:5173/?key=rvss-core-2026` で実行する。

```js
setTab('recruit');
const e = buildRecruitEntries().find(x => (x.row && (x.row.studentNames || []).length > 0));
toggleRecruitDetail(e.key);
const html = document.getElementById('content').innerHTML;
({
  key: e.key, names: e.row.studentNames,
  namesShown: e.row.studentNames.every(n => html.includes(n)),
  detailShown: html.includes('募集要項を閉じる'),
})
```
Expected: `namesShown: true`, `detailShown: true`

進捗ビュー（`onRecruitViewChange('progress')`）でも同じ2点が成り立つこと。コンソールエラーが 0 件であること。

- [ ] **Step 6: スクリーンショットで見た目を確認**

3ロールそれぞれの募集タブでスクリーンショットを撮り、レイアウトが崩れていないことを目視する。

- [ ] **Step 7: コミット**

```bash
git add index.html
git commit -m "Show the recruitment brief and applicant names on the recruitment cards"
```

---

### Task 6: 本番反映と最終確認

**Files:**
- Modify: なし（デプロイのみ）

**Interfaces:**
- Consumes: Task 1〜5 のすべて
- Produces: 本番稼働

- [ ] **Step 1: 本番の org_state をバックアップする**

`execute_sql`（project_id: `dbrwsrrfmpnvpzxcdupp`）で `select data from org_state where id='main';` を実行し、結果をスクラッチパッドに保存する。

- [ ] **Step 2: push する**

```bash
git push https://github.com/kitamura104toshi-cyber/rvss-org.git main
```

- [ ] **Step 3: 本番で3ロールを確認する**

Vercel の反映を待ってから、次の3つを開いて Task 1 Step 7 と同じ確認をする。

- `https://rvss-org-zeta.vercel.app/`
- `https://rvss-org-zeta.vercel.app/?key=rvss-core-2026`
- `https://rvss-org-zeta.vercel.app/?key=kitamura-rvss-admin-2026`

- [ ] **Step 4: 本番で個人情報の漏れがないことを確認する**

`https://rvss-org-zeta.vercel.app/` で Task 5 Step 4 のスニペットを実行し、`nameLeaks: []` / `emailLeaks: []` であること。

- [ ] **Step 5: 本番でステータス上書きを1件試して戻す**

core の URL で1件だけステータスを変更し、`state.recruitOverrides` に入ることを確認したうえで `clearRecruitOverride` で元に戻す。本番データを残さないこと。

- [ ] **Step 6: ユーザーへ報告する**

コアメン用 URL（`?key=rvss-core-2026`）を伝える。あわせて、設計ドキュメントに記録したシート側の不備（Lアカデミア行の列ずれ、CFO室行の空欄）を再掲する。

---

## Self-Review

**Spec coverage**

| 設計ドキュメントの項目 | 対応タスク |
|---|---|
| ロールの決定（3値・URLキー・localStorage なし） | Task 1 Step 1 |
| タブの出し分け・順序・カスタムタブ・フォールバック | Task 1 Step 4, 5 |
| 編集権限の2段化（ADMIN_FNS / CORE_FNS） | Task 2 |
| `.core-only` は「隠れても害の無いもの」だけ | Task 1 Step 3、Task 4 Step 4（戻すボタン）、Task 5 Step 1（名前とメアドは描画時に除外） |
| B-1 シート読み取り列の追加（ヘッダー名照合・欠けても続行） | Task 3 |
| B-2 PJ 詳細の表示・空項目を出さない | Task 5 Step 1 |
| B-3 応募者バイネーム・メンバーカードへのリンク・両ビュー | Task 5 Step 1, 2, 5 |
| B-4 `state.recruitOverrides`・同期で消えない・戻すボタン | Task 4 |
| `ensureFields` の初期化 | Task 4 Step 1 |
| テスト項目 1〜8 | Task 1 Step 7 / Task 2 Step 3 / Task 4 Step 7 / Task 5 Step 4,5 / Task 6 |

C（報酬算出）、シートへの書き戻し、メールログイン、RLS 見直しは設計どおり対象外。

**Placeholder scan:** プレースホルダなし。`<DEV_ANON_KEY>` と `<request_id>` は実行時に値が確定する参照で、取得元を明記済み。

**Type consistency:** `e.key` は Task 4 Step 2 で導入し、Task 4・Task 5 の全関数がこの名前で参照する。`resolveRecruitStatus` / `resolveWebTestStatus` / `hasRecruitOverride` / `recruitOverrideAt` は Task 4 Step 2 で定義し、Task 4 Step 4,5 と Task 5 Step 1 で同名のまま使う。`studentNames` / `studentEmails` は Task 3 で配列として作り、Task 5 で配列として扱う。
