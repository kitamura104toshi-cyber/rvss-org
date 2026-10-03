# スプシ中心の新システム 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **この計画は会話のセッション内で直接実行する（executing-plans）。** CLAUDE.md の決まりで、日本語を含む Edge Function のデプロイを他のエージェントに任せない（エスケープが壊れて起動しなくなった実績がある）。

**Goal:** dev Supabase を本体とする新システムを作る。人が直すメンバー情報と報酬入力はスプシ（組織ブック・報酬ブック）が本体になり、アプリは表示とアサイン編集だけを受け持つ。

**Architecture:** スプシ → Supabase の取り込み（`org-sheets-pull`）と Supabase → スプシの写し（`org-sheets-push`）を Edge Function で作る。表とstateの変換は副作用のない TypeScript モジュールにまとめ、Node のテストで確かめる。Supabase への書き込みは SQL 関数 `apply_sheet_patch` で、担当項目だけを1回のUPDATEでマージする。アプリは今の `index.html` を別フォルダに複製して直す。

**Tech Stack:** Supabase（Postgres・Edge Functions／Deno・pg_net・pg_cron）、Google Sheets API v4（サービスアカウントJWT）、素のHTML/JS（ビルドなし）、Node 24（`node --test`、型は実行時に読み飛ばす）

**Spec:** `docs/superpowers/specs/2026-10-04-sheets-hub-design.md`（このリポジトリ）

## Global Constraints

- 本番には何も書かない：本番 Supabase `dbrwsrrfmpnvpzxcdupp` への操作は Task 1 の読み取り（`net.http_get`）だけ。本番 `index.html`・本番 Vercel・本番バックアップブック `1AvafMyWaCqQyXByPZboTESd9JFBrNuRIrrjXl47IM2s` に触らない
- 新システムの Supabase は dev：`vsqrgcsobweaupiabagu`
- 組織ブック：`1sNxLwO7TDVTyQkGMJlkCRvwinrVo6PV2YkNQ7SvQKEc`
- 報酬ブック：`1l6dlf4NG9V0u5z_MlPwIPUEEYeIBOwa8-ZhjeUdemBA`
- dev バックアップブック（生データ履歴）：`1j6rT…`（dev の `sheets-backup` に設定済みのID。変えない）
- 共有の取り込み元は読むだけ：募集フォーム回答 `1DcALjQGfuExjzCMC5BIQdQWu0g1wI_phovmTsWtka44`、契約 `1k23DRZ0ztRXmT_MMZhC2jWQ4redXcpiosVSZESlDm9s`、採用管理 `1WYReaAezfisxkZh5G1r70VLhMdU8qJwLAK7ytZ2PN70`
- 新アプリの置き場所：`C:\Users\mr171\claude\RVSS\組織管理v2\`（独立した git リポジトリ。リモートは付けない）
- 列は見出し名で引く（`normalizeHeader`／`findCol`）。列番号で決め打ちしない
- `memberOverrides[氏名]` を作り直さない。担当項目だけをマージする
- 改行は LF
- dev の Edge Function を呼ぶときは `execute_sql` の中で `net.http_post`、結果は `net._http_response` を id で引く（`curl` は通らない）。Authorization は dev の anon キー（`index.html` の `DEV_SUPABASE_ANON_KEY`）
- 写しタブの名前は末尾に「（自動）」を付ける

## ファイル構成（新リポジトリ `組織管理v2/`）

| ファイル | 役割 |
|---|---|
| `index.html` | 新アプリ。今の `index.html` の複製から直す |
| `.claude/launch.json`、`.claude/static-server.ps1` | ローカル配信（ポート 5174） |
| `sync/sheet-mapping.ts` | 編集タブ（メンバー・月次入力）と state の相互変換。副作用なし |
| `sync/sheet-mapping.test.ts` | 上のテスト |
| `sync/mirror-tables.ts` | 写しタブの表を state から作る。副作用なし |
| `sync/mirror-tables.test.ts` | 上のテスト |
| `sync/google.ts` | Sheets API と Supabase の呼び出し（Deno 用。テストしない） |
| `supabase/functions/org-sheets-pull/index.ts` | 取り込みの入口 |
| `supabase/functions/org-sheets-push/index.ts` | 写しと初回書き出しの入口 |
| `supabase/sql/apply_sheet_patch.sql` | SQL 関数 |
| `supabase/functions/sheets-intake-sync/index.ts` | dev の入会者取り込み（書き込み先を変えた版） |
| `supabase/functions/sheets-backup/index.ts` | dev の生データ履歴（一覧系を外した版） |
| `CLAUDE.md` | このリポジトリの扱い |

**Edge Function のデプロイ時**：`deploy_edge_function` に `index.ts` と `sheet-mapping.ts`・`mirror-tables.ts`・`google.ts` を**同じ階層のファイルとして**渡す。関数側の import は `./sheet-mapping.ts` の形にしておく。正本は `sync/` の方で、関数フォルダにはコピーを置かない。

---

### Task 1: dev の退避と、本番データの写し込み

**Files:** なし（SQL だけ）

**Interfaces:**
- Produces: dev `org_state` の `id='main'` が本番の写しになり、`id='backup-20261004-pre-v2'` に作業前の dev が残る。`compensation.exportSheets` と `compensation.exportShareTo` は消える

- [ ] **Step 1: 今の dev を退避する**（`execute_sql`、project `vsqrgcsobweaupiabagu`）

```sql
insert into org_state (id, data, updated_at)
select 'backup-20261004-pre-v2', data, now() from org_state where id = 'main'
on conflict (id) do nothing
returning id, length(data::text);
```

Expected: 1行返る（id が `backup-20261004-pre-v2`）。0行なら同名の退避が既にあるので、中身を確かめてから進む。

- [ ] **Step 2: 本番の行を dev から読みに行く**（読み取りだけ。本番の anon キーは本番 `index.html` の `PROD_SUPABASE_ANON_KEY`）

```sql
select net.http_get(
  url := 'https://dbrwsrrfmpnvpzxcdupp.supabase.co/rest/v1/org_state?id=eq.main&select=data,updated_at',
  headers := jsonb_build_object('apikey', '<PROD_SUPABASE_ANON_KEY>', 'Authorization', 'Bearer <PROD_SUPABASE_ANON_KEY>'),
  timeout_milliseconds := 30000) as id;
```

- [ ] **Step 3: 受け取った中身を確かめる**

```sql
select status_code, length(content), (content::jsonb->0->>'updated_at') prod_updated_at,
       jsonb_array_length(content::jsonb->0->'data'->'projects') projects
from net._http_response where id = <Step 2 の id>;
```

Expected: `status_code=200`、長さ 100,000 前後、projects が 13 前後。

- [ ] **Step 4: dev の main を置き換え、本番の書き出し先を外す**

```sql
update org_state set
  data = (((select content::jsonb->0->'data' from net._http_response where id = <Step 2 の id>)
          #- '{compensation,exportSheets}') #- '{compensation,exportShareTo}'),
  updated_at = now()
where id = 'main'
returning jsonb_array_length(data->'projects') projects,
          data->'compensation' ? 'exportSheets' still_has_export;
```

Expected: projects が Step 3 と同じ、`still_has_export=false`。

- [ ] **Step 5: 本番に変化がないことを確かめる**（本番 project で読むだけ）

```sql
select updated_at from org_state where id = 'main';
```

Expected: Step 3 の `prod_updated_at` と同じ。

---

### Task 2: 新アプリの器を作る

**Files:**
- Create: `組織管理v2/index.html`（`メンバーアサイン表/index.html` の複製）
- Create: `組織管理v2/.claude/launch.json`、`組織管理v2/.claude/static-server.ps1`
- Create: `組織管理v2/CLAUDE.md`、`組織管理v2/.gitattributes`

**Interfaces:**
- Produces: `http://localhost:5174/` で新アプリが dev に接続して開く

- [ ] **Step 1: フォルダをセッションに追加し、複製する**

フォルダがセッション外なら `mcp__ccd_directory__request_directory` で `C:\Users\mr171\claude\RVSS\組織管理v2` を追加してから:

```bash
mkdir -p "/c/Users/mr171/claude/RVSS/組織管理v2/.claude"
cp "/c/Users/mr171/claude/RVSS/メンバーアサイン表/index.html" "/c/Users/mr171/claude/RVSS/組織管理v2/index.html"
cd "/c/Users/mr171/claude/RVSS/組織管理v2" && git init -q && git config core.autocrlf false
printf '* text=auto eol=lf\n' > .gitattributes
```

- [ ] **Step 2: 接続先を dev に固定する**

`index.html` の次の2行（`const SUPABASE_URL = IS_LOCAL_DEV ? …` と `const SUPABASE_ANON_KEY = IS_LOCAL_DEV ? …`）を置き換える:

```js
// 新システムは dev プロジェクトが本体。本番には接続しない。
const SUPABASE_URL = DEV_SUPABASE_URL;
const SUPABASE_ANON_KEY = DEV_SUPABASE_ANON_KEY;
```

`PROD_SUPABASE_URL` と `PROD_SUPABASE_ANON_KEY` の定義行、`IS_LOCAL_DEV` の定義行と上のコメントは削除する。`grep -n "PROD_SUPABASE\|IS_LOCAL_DEV" index.html` が0件になること。

- [ ] **Step 3: ローカル配信**

`.claude/static-server.ps1`（メンバーアサイン表のものを複製し、`5173` を `5174` に置き換える）。

`.claude/launch.json`:

```json
{
  "version": "0.0.1",
  "configurations": [
    {
      "name": "v2",
      "runtimeExecutable": "powershell",
      "runtimeArgs": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ".claude/static-server.ps1"],
      "port": 5174
    }
  ]
}
```

- [ ] **Step 4: CLAUDE.md を置く**

```markdown
# RVSS組織管理 v2（スプシ中心の新システム）

本番（`メンバーアサイン表/`）とは別のシステム。本番のデータ・関数・ブックには触らない。

- Supabase は dev `vsqrgcsobweaupiabagu` だけ。アプリも接続先を固定している
- 組織ブック `1sNxLwO7TDVTyQkGMJlkCRvwinrVo6PV2YkNQ7SvQKEc`／報酬ブック `1l6dlf4NG9V0u5z_MlPwIPUEEYeIBOwa8-ZhjeUdemBA`
- 募集フォーム・契約・採用管理のシートは本番と共有。読むだけで書かない
- 設計：`../メンバーアサイン表/docs/superpowers/specs/2026-10-04-sheets-hub-design.md`
- `index.html` は3000行以上ある。全文を読まず grep と範囲指定で読む
- テスト：`node --test sync/`
- Edge Function は `sync/` の共有ファイルと一緒に、同じ階層のファイルとしてデプロイする
- 日本語を含む関数のデプロイを他のエージェントに任せない
```

- [ ] **Step 5: 起動して確かめる**

`preview_start {name: "v2"}`（v2 の launch.json を使う）。`javascript_tool` で `SUPABASE_URL` が `https://vsqrgcsobweaupiabagu.supabase.co` であること、`state.projects.length` が Task 1 の projects と同じことを確かめる。

- [ ] **Step 6: Commit**

```bash
cd "/c/Users/mr171/claude/RVSS/組織管理v2" && git add -A && git commit -q -m "Start the spreadsheet-centred system from a copy of the current app"
```

---

### Task 3: 「メンバー」タブの変換

**Files:**
- Create: `組織管理v2/sync/sheet-mapping.ts`
- Test: `組織管理v2/sync/sheet-mapping.test.ts`

**Interfaces:**
- Produces（Task 4・6・8・10 が使う）:
  - `type Patch = { memberOverrides: Record<string, Record<string, unknown>>; compByMonth: Record<string, Record<string, Record<string, unknown>>>; addMembers: string[]; setDeleted: string[]; unsetDeleted: string[] }`
  - `emptyPatch(): Patch`
  - `isEmptyPatch(p: Patch): boolean`
  - `MEMBER_HEADERS: string[]`（見出し行。先頭は「氏名」「状態」）
  - `stateToMemberRows(state): string[][]`（見出し行を含む）
  - `memberRowsToPatch(rows: string[][], state): { patch: Patch; changes: string[]; warnings: string[] }`
  - `applyPatch(state, patch): state`（テストと検算用。SQL 関数と同じ結果を返す）
  - `normalizeHeader(s)`、`findCol(headers, candidates)`

- [ ] **Step 1: 失敗するテストを書く**

```ts
// sync/sheet-mapping.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { stateToMemberRows, memberRowsToPatch, applyPatch, isEmptyPatch, MEMBER_HEADERS } from "./sheet-mapping.ts";

const base = () => ({
  members: ["山田太郎", "鈴木花子"],
  deletedMembers: ["退会次郎"],
  memberOverrides: {
    "山田太郎": { area: "関西", university: "京都大学", outsourcingSigned: true, skillCategories: ["思考・企画系", "IT・テクノロジー系"], hoursByMonth: { "2026-09": { hours: 50 } } },
    "鈴木花子": { isBS: true, handoverNeeded: false },
    "佐藤﨑": { university: "" },
    "退会次郎": { area: "関東" },
  },
});

test("書き出した表をそのまま読み戻すと差分はゼロ", () => {
  const s = base();
  const rows = stateToMemberRows(s);
  assert.deepEqual(rows[0], MEMBER_HEADERS);
  const r = memberRowsToPatch(rows, s);
  assert.ok(isEmptyPatch(r.patch), JSON.stringify(r.changes));
  assert.deepEqual(r.warnings, []);
});

test("状態の列で在籍・BS・退会が決まる", () => {
  const s = base();
  const rows = stateToMemberRows(s);
  const name = rows[0].indexOf("氏名"), st = rows[0].indexOf("状態");
  for (const row of rows.slice(1)) {
    if (row[name] === "山田太郎") row[st] = "退会";
    if (row[name] === "退会次郎") row[st] = "在籍";
    if (row[name] === "鈴木花子") row[st] = "在籍";
  }
  const next = applyPatch(s, memberRowsToPatch(rows, s).patch);
  assert.ok(next.deletedMembers.includes("山田太郎"));
  assert.ok(!next.deletedMembers.includes("退会次郎"));
  assert.equal(next.memberOverrides["鈴木花子"].isBS, undefined);
});

test("値を消すとキーが消え、他の項目は残る", () => {
  const s = base();
  const rows = stateToMemberRows(s);
  const name = rows[0].indexOf("氏名"), area = rows[0].indexOf("エリア");
  for (const row of rows.slice(1)) if (row[name] === "山田太郎") row[area] = "";
  const next = applyPatch(s, memberRowsToPatch(rows, s).patch);
  assert.equal(next.memberOverrides["山田太郎"].area, undefined);
  assert.deepEqual(next.memberOverrides["山田太郎"].hoursByMonth, { "2026-09": { hours: 50 } });
  assert.equal(next.memberOverrides["山田太郎"].university, "京都大学");
});

test("新しい行は在籍メンバーとして足される", () => {
  const s = base();
  const rows = stateToMemberRows(s);
  const row = rows[0].map(() => "");
  row[rows[0].indexOf("氏名")] = "新人一郎";
  row[rows[0].indexOf("状態")] = "在籍";
  row[rows[0].indexOf("大学")] = "大阪大学";
  rows.push(row);
  const next = applyPatch(s, memberRowsToPatch(rows, s).patch);
  assert.ok(next.members.includes("新人一郎"));
  assert.equal(next.memberOverrides["新人一郎"].university, "大阪大学");
});

test("行が消えた人は退会にせず警告だけ出す", () => {
  const s = base();
  const rows = stateToMemberRows(s).filter(r => r[0] !== "山田太郎");
  const r = memberRowsToPatch(rows, s);
  assert.ok(isEmptyPatch(r.patch));
  assert.ok(r.warnings.some(w => w.includes("山田太郎")));
});

test("必須の見出しが無ければ例外", () => {
  const s = base();
  const rows = stateToMemberRows(s).map(r => r.slice(1)); // 氏名列を落とす
  assert.throws(() => memberRowsToPatch(rows, s), /氏名/);
});

test("見出しの順番を入れ替えても読める", () => {
  const s = base();
  const rows = stateToMemberRows(s).map(r => [...r].reverse());
  assert.ok(isEmptyPatch(memberRowsToPatch(rows, s).patch));
});

test("知らない状態の語は警告して状態を変えない", () => {
  const s = base();
  const rows = stateToMemberRows(s);
  const name = rows[0].indexOf("氏名"), st = rows[0].indexOf("状態");
  for (const row of rows.slice(1)) if (row[name] === "山田太郎") row[st] = "休み";
  const r = memberRowsToPatch(rows, s);
  assert.ok(isEmptyPatch(r.patch));
  assert.ok(r.warnings.some(w => w.includes("休み")));
});
```

- [ ] **Step 2: 失敗を確かめる**

Run: `cd "/c/Users/mr171/claude/RVSS/組織管理v2" && node --test sync/`
Expected: FAIL（`sheet-mapping.ts` が無い）

- [ ] **Step 3: 実装する**

```ts
// sync/sheet-mapping.ts
// 編集タブ（組織ブック「メンバー」・報酬ブック「月次入力」）と org_state の相互変換。
// 副作用を持たない。Edge Function（Deno）と node --test の両方から読む。

export type Patch = {
  memberOverrides: Record<string, Record<string, unknown>>;
  compByMonth: Record<string, Record<string, Record<string, unknown>>>;
  addMembers: string[];
  setDeleted: string[];
  unsetDeleted: string[];
};
export function emptyPatch(): Patch {
  return { memberOverrides: {}, compByMonth: {}, addMembers: [], setDeleted: [], unsetDeleted: [] };
}
export function isEmptyPatch(p: Patch): boolean {
  return Object.keys(p.memberOverrides).length === 0 && Object.keys(p.compByMonth).length === 0 &&
    p.addMembers.length === 0 && p.setDeleted.length === 0 && p.unsetDeleted.length === 0;
}

// 全角英数を半角に寄せ、空白と括弧を落として比べる（既存の取り込み関数と同じ規則）
export function normalizeHeader(s: unknown): string {
  return String(s ?? "")
    .replace(/[Ａ-Ｚａ-ｚ０-９]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 0xfee0))
    .replace(/[\s　]/g, "")
    .replace(/[（）()]/g, "")
    .toUpperCase();
}
export function findCol(headers: string[], candidates: string[]): number {
  const norm = headers.map(normalizeHeader);
  for (const c of candidates) {
    const i = norm.indexOf(normalizeHeader(c));
    if (i >= 0) return i;
  }
  return -1;
}

type Kind = "text" | "bool" | "tri" | "list" | "number" | "pjHours";
export type Col = { header: string; key: string; kind: Kind; t?: string; f?: string };

export const MEMBER_COLS: Col[] = [
  { header: "エリア", key: "area", kind: "text" },
  { header: "大学", key: "university", kind: "text" },
  { header: "入会日", key: "joinedAt", kind: "text" },
  { header: "関わり方", key: "recruitTrack", kind: "text" },
  { header: "紹介者", key: "referredBy", kind: "text" },
  { header: "メアド", key: "recruitEmail", kind: "text" },
  { header: "業務委託契約", key: "outsourcingSigned", kind: "bool", t: "締結済み", f: "未締結" },
  { header: "契約開始日", key: "contractStartDate", kind: "text" },
  { header: "契約状況", key: "contractStatus", kind: "text" },
  { header: "残り活動期間", key: "availableUntil", kind: "text" },
  { header: "残り活動期間メモ", key: "availableUntilNote", kind: "text" },
  { header: "継続意向", key: "tenureIntent", kind: "text" },
  { header: "引き継ぎ", key: "handoverNeeded", kind: "bool", t: "要", f: "" },
  { header: "ステータス", key: "status", kind: "text" },
  { header: "スキル分類", key: "skillCategories", kind: "list" },
];
export const MEMBER_HEADERS = ["氏名", "状態", ...MEMBER_COLS.map((c) => c.header)];

const TRUE_WORDS = ["○", "◯", "TRUE", "true", "はい"];
const FALSE_WORDS = ["×", "✕", "FALSE", "false", "いいえ"];

export function toCell(col: Col, v: unknown): string {
  switch (col.kind) {
    case "bool": return v === true ? col.t! : (col.f ?? "");
    case "tri": return v === true ? col.t! : v === false ? col.f! : "";
    case "list": return Array.isArray(v) ? v.join("、") : "";
    case "number": return typeof v === "number" && isFinite(v) ? String(v) : "";
    case "pjHours":
      return v && typeof v === "object"
        ? Object.entries(v as Record<string, number>).map(([k, h]) => `${k}:${h}`).join("、")
        : "";
    default: return v == null ? "" : String(v);
  }
}

// 読めない値は例外にせず undefined を返す（呼び出し側が警告にする）
export function fromCell(col: Col, raw: unknown): unknown {
  const s = String(raw ?? "").trim();
  switch (col.kind) {
    case "bool": return s !== "" && (s === col.t || TRUE_WORDS.includes(s));
    case "tri":
      if (!s) return null;
      if (s === col.t || TRUE_WORDS.includes(s)) return true;
      if (s === col.f || FALSE_WORDS.includes(s)) return false;
      return undefined;
    case "list": return s ? s.split(/[、,，]/).map((x) => x.trim()).filter(Boolean) : [];
    case "number": {
      if (!s) return null;
      const n = Number(s.replace(/[,，%％\s]/g, ""));
      return isFinite(n) ? n : undefined;
    }
    case "pjHours": {
      if (!s) return {};
      const o: Record<string, number> = {};
      for (const part of s.split(/[、,，]/)) {
        const m = part.trim().match(/^(.+?)[:：]\s*([\d.]+)$/);
        if (!m) return undefined;
        o[m[1].trim()] = Number(m[2]);
      }
      return o;
    }
    default: return s;
  }
}

// 「無い」「空文字」「false」「[]」を同じに扱って比べる
function normValue(col: Col, v: unknown): unknown {
  if (v === undefined || v === null) {
    return { bool: false, tri: null, list: [], number: null, pjHours: {}, text: "" }[col.kind];
  }
  if (col.kind === "text") return String(v);
  if (col.kind === "pjHours") {
    const o = v as Record<string, number>;
    return Object.fromEntries(Object.keys(o).sort().map((k) => [k, o[k]]));
  }
  return v;
}
export function sameValue(col: Col, a: unknown, b: unknown): boolean {
  return JSON.stringify(normValue(col, a)) === JSON.stringify(normValue(col, b));
}
// 空にする変更はキーを消す（null を送る）。アプリは「無い」を空として扱う。
function patchValue(col: Col, v: unknown): unknown {
  return sameValue(col, v, undefined) ? null : v;
}

const STATUS_WORDS = ["在籍", "BS", "退会"] as const;
type MemberStatus = typeof STATUS_WORDS[number];

function rosterOf(state: any): string[] {
  const names = new Set<string>();
  (state.members || []).forEach((n: string) => names.add(n));
  Object.keys(state.memberOverrides || {}).forEach((n) => names.add(n));
  (state.deletedMembers || []).forEach((n: string) => names.add(n));
  return Array.from(names);
}
function statusOf(state: any, name: string): MemberStatus {
  if ((state.deletedMembers || []).includes(name)) return "退会";
  if (((state.memberOverrides || {})[name] || {}).isBS) return "BS";
  return "在籍";
}

export function stateToMemberRows(state: any): string[][] {
  const order: Record<MemberStatus, number> = { "在籍": 0, "BS": 1, "退会": 2 };
  const names = rosterOf(state).sort((a, b) =>
    order[statusOf(state, a)] - order[statusOf(state, b)] || a.localeCompare(b, "ja"));
  const rows = names.map((n) => {
    const mi = (state.memberOverrides || {})[n] || {};
    return [n, statusOf(state, n), ...MEMBER_COLS.map((c) => toCell(c, mi[c.key]))];
  });
  return [MEMBER_HEADERS, ...rows];
}

export function memberRowsToPatch(rows: string[][], state: any) {
  const patch = emptyPatch();
  const changes: string[] = [];
  const warnings: string[] = [];
  const headers = (rows[0] || []).map((h) => String(h ?? ""));
  const nameCol = findCol(headers, ["氏名"]);
  const statusCol = findCol(headers, ["状態"]);
  if (nameCol < 0) throw new Error(`「メンバー」タブに「氏名」列がありません。見出し: ${headers.join(" | ")}`);
  if (statusCol < 0) throw new Error(`「メンバー」タブに「状態」列がありません。見出し: ${headers.join(" | ")}`);
  const cols = MEMBER_COLS.map((c) => ({ c, i: findCol(headers, [c.header]) }));
  cols.filter((x) => x.i < 0).forEach((x) => warnings.push(`「${x.c.header}」列が見つからないので読み飛ばしました`));

  const overrides = state.memberOverrides || {};
  const inMembers = new Set<string>(state.members || []);
  const deleted = new Set<string>(state.deletedMembers || []);
  const seen = new Set<string>();

  for (const row of rows.slice(1)) {
    const name = String(row[nameCol] ?? "").trim();
    if (!name) continue;
    if (seen.has(name)) { warnings.push(`「${name}」の行が2つあります。上の行だけを使いました`); continue; }
    seen.add(name);

    const st = String(row[statusCol] ?? "").trim() as MemberStatus;
    if (!STATUS_WORDS.includes(st)) {
      warnings.push(`「${name}」の状態「${st}」は在籍・BS・退会のどれでもないため、この行を読み飛ばしました`);
      continue;
    }
    const cur = overrides[name] || {};
    const isKnown = inMembers.has(name) || name in overrides || deleted.has(name);
    const fields: Record<string, unknown> = {};

    if (st === "退会" && !deleted.has(name)) { patch.setDeleted.push(name); changes.push(`${name}: 退会`); }
    if (st !== "退会" && deleted.has(name)) { patch.unsetDeleted.push(name); changes.push(`${name}: 退会を取り消し`); }
    if (st !== "退会" && !isKnown) { patch.addMembers.push(name); changes.push(`${name}: 新しいメンバー`); }
    if ((st === "BS") !== !!cur.isBS) fields.isBS = st === "BS" ? true : null;

    for (const { c, i } of cols) {
      if (i < 0) continue;
      const v = fromCell(c, row[i]);
      if (v === undefined) { warnings.push(`「${name}」の「${c.header}」を読めませんでした: ${row[i]}`); continue; }
      if (!sameValue(c, v, cur[c.key])) fields[c.key] = patchValue(c, v);
    }
    if (Object.keys(fields).length) {
      patch.memberOverrides[name] = fields;
      changes.push(`${name}: ${Object.keys(fields).join("・")}`);
    }
  }

  for (const n of rosterOf(state)) {
    if (!seen.has(n) && !deleted.has(n)) warnings.push(`「${n}」の行が「メンバー」タブにありません（退会扱いにはしていません）`);
  }
  return { patch, changes, warnings };
}

// SQL 関数 apply_sheet_patch と同じ結果を返す（テストと検算用）
export function applyPatch(state: any, p: Patch): any {
  const s = structuredClone(state);
  s.memberOverrides = s.memberOverrides || {};
  for (const [n, f] of Object.entries(p.memberOverrides)) {
    const o = { ...(s.memberOverrides[n] || {}) };
    for (const [k, v] of Object.entries(f)) { if (v === null) delete o[k]; else o[k] = v; }
    s.memberOverrides[n] = o;
  }
  s.compensation = s.compensation || {};
  s.compensation.members = s.compensation.members || {};
  for (const [n, months] of Object.entries(p.compByMonth)) {
    const m = { ...(s.compensation.members[n] || {}) };
    const byMonth = { ...(m.byMonth || {}) };
    for (const [month, f] of Object.entries(months)) {
      const o = { ...(byMonth[month] || {}) };
      for (const [k, v] of Object.entries(f)) { if (v === null) delete o[k]; else o[k] = v; }
      byMonth[month] = o;
    }
    m.byMonth = byMonth;
    s.compensation.members[n] = m;
  }
  s.members = [...(s.members || [])];
  for (const n of p.addMembers) if (!s.members.includes(n)) s.members.push(n);
  s.deletedMembers = (s.deletedMembers || []).filter((n: string) => !p.unsetDeleted.includes(n));
  for (const n of p.setDeleted) if (!s.deletedMembers.includes(n)) s.deletedMembers.push(n);
  return s;
}
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `node --test sync/`
Expected: 8 tests pass

- [ ] **Step 5: Commit**

```bash
git add sync/ && git commit -q -m "Map the member tab to and from the app state"
```

---

### Task 4: 「月次入力」タブの変換

**Files:**
- Modify: `組織管理v2/sync/sheet-mapping.ts`（末尾に追加）
- Test: `組織管理v2/sync/sheet-mapping.test.ts`（末尾に追加）

**Interfaces:**
- Consumes: Task 3 の `Patch`・`Col`・`toCell`・`fromCell`・`sameValue`・`findCol`・`applyPatch`
- Produces:
  - `MONTHLY_HEADERS: string[]`
  - `stateToMonthlyRows(state, months: string[]): string[][]`（直下の値を各月へ展開した表）
  - `monthlyRowsToPatch(rows: string[][], state): { patch: Patch; changes: string[]; warnings: string[] }`
  - `legacyPayInput(state, name, month)`（今の `payInfoOf` と同じ意味。検算用）
  - `monthlyPayInput(state, name, month)`（新システムの意味：`byMonth[month]` だけ）

- [ ] **Step 1: 失敗するテストを書く**

```ts
// sync/sheet-mapping.test.ts に追加
import { stateToMonthlyRows, monthlyRowsToPatch, legacyPayInput, monthlyPayInput, MONTHLY_HEADERS } from "./sheet-mapping.ts";

const comp = () => ({
  members: ["山田太郎"],
  memberOverrides: { "山田太郎": {} },
  compensation: { members: {
    "山田太郎": {
      score360: 3.5, attendanceRate: 91.7, referral: true, school: false, role: "広報PM",
      isManager: true, adjust: 5000, workNotes: { "2026-09": "広報" },
      byMonth: { "2026-09": { isManager: false, adjust: 0, assumedHours: 60, assumedProjectHours: { NoBorder: 30 }, assumedProjectHoursTotal: 30 },
                 "2026-10": { countAsProject: false } },
    },
  } },
});
const MONTHS = ["2026-08", "2026-09", "2026-10"];

test("月次入力：書き出した表の各月の値が今の報酬計算の値と同じ", () => {
  const s = comp();
  const rows = stateToMonthlyRows(s, MONTHS);
  assert.deepEqual(rows[0], MONTHLY_HEADERS);
  assert.equal(rows.length, 1 + 3);
  const next = applyPatch(s, monthlyRowsToPatch(rows, s).patch);
  // アプリは「無い」「false」「空文字」を同じに扱う。ただし countAsProject だけは
  // 未指定（無い）と「含めない」（false）を区別するので、そのまま比べる。
  const loose = (v: unknown) => (v === undefined || v === null || v === false || v === "" ? null : v);
  for (const m of MONTHS) {
    const want = legacyPayInput(s, "山田太郎", m);
    const got = monthlyPayInput(next, "山田太郎", m);
    for (const k of ["score360", "attendanceRate", "referral", "school", "role", "isManager", "adjust", "adjustNote",
                     "assumedHours", "assumedProjectHours", "assumedProjectHoursTotal"]) {
      assert.deepEqual(loose(got[k]), loose(want[k]), `${m} ${k}`);
    }
    assert.equal(got.countAsProject, want.countAsProject, `${m} countAsProject`);
  }
});

test("月次入力：一度取り込んだ後は差分ゼロ", () => {
  const s = comp();
  const rows = stateToMonthlyRows(s, MONTHS);
  const next = applyPatch(s, monthlyRowsToPatch(rows, s).patch);
  assert.ok(isEmptyPatch(monthlyRowsToPatch(rows, next).patch));
});

test("月次入力：直下のマネージャー認定は byMonth に明示が無い月へ広げない", () => {
  const s = comp();
  const rows = stateToMonthlyRows(s, MONTHS);
  const h = rows[0], i = h.indexOf("マネージャー"), m = h.indexOf("月");
  assert.equal(rows.find((r) => r[m] === "2026-08")![i], "");
});

test("月次入力：2026/09/01 のような日付表記も月として読む", () => {
  const s = comp();
  const rows = stateToMonthlyRows(s, ["2026-09"]);
  rows[1][rows[0].indexOf("月")] = "2026/09/01";
  const next = applyPatch(s, monthlyRowsToPatch(rows, s).patch);
  assert.equal(monthlyPayInput(next, "山田太郎", "2026-09").score360, 3.5);
});

test("月次入力：読めない数値は警告してその項目だけ飛ばす", () => {
  const s = comp();
  const rows = stateToMonthlyRows(s, ["2026-09"]);
  rows[1][rows[0].indexOf("360°")] = "よい";
  const r = monthlyRowsToPatch(rows, s);
  assert.ok(r.warnings.some((w) => w.includes("360°")));
  assert.equal(r.patch.compByMonth["山田太郎"]["2026-09"].score360, undefined);
});
```

- [ ] **Step 2: 失敗を確かめる**

Run: `node --test sync/`
Expected: FAIL（`stateToMonthlyRows` が export されていない）

- [ ] **Step 3: 実装する**（`sync/sheet-mapping.ts` の末尾に追加）

```ts
// ===== 報酬ブック「月次入力」 =====
// 今のアプリでは compensation.members[氏名] 直下の値が全部の月に効き、
// PAY_MONTHLY_FIELDS だけは byMonth に明示のある月だけ効く。
// 新システムでは byMonth だけを見る。書き出すときに直下の値を各月へ展開する。
export const PAY_MONTHLY_FIELDS = ["isManager", "adjust", "adjustNote", "countAsProject",
  "assumedHours", "assumedProjectHours", "assumedProjectHoursTotal"];
// 自動で入る値。月次入力の対象にしない
const PAY_AUTO_FIELDS = ["byMonth", "workNotes", "nextMonthHours", "nextProjectHours", "nextProjectHoursTotal"];

export const MONTHLY_COLS: Col[] = [
  { header: "360°", key: "score360", kind: "number" },
  { header: "出席率", key: "attendanceRate", kind: "number" },
  { header: "リファ", key: "referral", kind: "bool", t: "○", f: "" },
  { header: "スクール", key: "school", kind: "bool", t: "○", f: "" },
  { header: "マネージャー", key: "isManager", kind: "bool", t: "○", f: "" },
  { header: "調整額", key: "adjust", kind: "number" },
  { header: "調整メモ", key: "adjustNote", kind: "text" },
  { header: "役割", key: "role", kind: "text" },
  // 未指定（空）・含める（○）・含めない（×）の3通り
  { header: "案件数に含める", key: "countAsProject", kind: "tri", t: "○", f: "×" },
  { header: "想定稼働", key: "assumedHours", kind: "number" },
  { header: "想定PJ稼働", key: "assumedProjectHours", kind: "pjHours" },
  { header: "想定PJ稼働合計", key: "assumedProjectHoursTotal", kind: "number" },
];
export const MONTHLY_HEADERS = ["月", "氏名", ...MONTHLY_COLS.map((c) => c.header)];

function compOf(state: any, name: string): any {
  return ((state.compensation || {}).members || {})[name] || null;
}
export function legacyPayInput(state: any, name: string, month: string): Record<string, unknown> {
  const base = compOf(state, name);
  if (!base) return {};
  const carried: Record<string, unknown> = { ...base };
  for (const k of [...PAY_MONTHLY_FIELDS, ...PAY_AUTO_FIELDS]) delete carried[k];
  return { ...carried, ...((base.byMonth || {})[month] || {}) };
}
export function monthlyPayInput(state: any, name: string, month: string): Record<string, unknown> {
  const base = compOf(state, name);
  return base ? { ...((base.byMonth || {})[month] || {}) } : {};
}

export function stateToMonthlyRows(state: any, months: string[]): string[][] {
  const names = Object.keys((state.compensation || {}).members || {}).sort((a, b) => a.localeCompare(b, "ja"));
  const rows: string[][] = [];
  for (const m of [...months].sort()) {
    for (const n of names) {
      const v = legacyPayInput(state, n, m);
      rows.push([m, n, ...MONTHLY_COLS.map((c) => toCell(c, v[c.key]))]);
    }
  }
  return [MONTHLY_HEADERS, ...rows];
}

function readMonth(raw: unknown): string | null {
  const m = String(raw ?? "").trim().match(/^(\d{4})[-\/年](\d{1,2})/);
  return m ? `${m[1]}-${m[2].padStart(2, "0")}` : null;
}

export function monthlyRowsToPatch(rows: string[][], state: any) {
  const patch = emptyPatch();
  const changes: string[] = [];
  const warnings: string[] = [];
  const headers = (rows[0] || []).map((h) => String(h ?? ""));
  const monthCol = findCol(headers, ["月"]);
  const nameCol = findCol(headers, ["氏名"]);
  if (monthCol < 0) throw new Error(`「月次入力」タブに「月」列がありません。見出し: ${headers.join(" | ")}`);
  if (nameCol < 0) throw new Error(`「月次入力」タブに「氏名」列がありません。見出し: ${headers.join(" | ")}`);
  const cols = MONTHLY_COLS.map((c) => ({ c, i: findCol(headers, [c.header]) }));
  cols.filter((x) => x.i < 0).forEach((x) => warnings.push(`「${x.c.header}」列が見つからないので読み飛ばしました`));
  const seen = new Set<string>();

  for (const row of rows.slice(1)) {
    const name = String(row[nameCol] ?? "").trim();
    if (!name) continue;
    const month = readMonth(row[monthCol]);
    if (!month) { warnings.push(`「${name}」の行の月「${row[monthCol]}」を読めませんでした`); continue; }
    const key = `${month} ${name}`;
    if (seen.has(key)) { warnings.push(`${month}の「${name}」の行が2つあります。上の行だけを使いました`); continue; }
    seen.add(key);

    const cur = monthlyPayInput(state, name, month);
    const fields: Record<string, unknown> = {};
    for (const { c, i } of cols) {
      if (i < 0) continue;
      const v = fromCell(c, row[i]);
      if (v === undefined) { warnings.push(`${month}の「${name}」の「${c.header}」を読めませんでした: ${row[i]}`); continue; }
      if (!sameValue(c, v, cur[c.key])) fields[c.key] = patchValue(c, v);
    }
    if (Object.keys(fields).length) {
      (patch.compByMonth[name] ||= {})[month] = fields;
      changes.push(`${month} ${name}: ${Object.keys(fields).join("・")}`);
    }
  }
  return { patch, changes, warnings };
}
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `node --test sync/`
Expected: 13 tests pass

- [ ] **Step 5: Commit**

```bash
git add sync/ && git commit -q -m "Map the monthly pay inputs to and from the app state"
```

---

### Task 5: SQL 関数 `apply_sheet_patch`

**Files:**
- Create: `組織管理v2/supabase/sql/apply_sheet_patch.sql`

**Interfaces:**
- Consumes: Task 3 の `Patch` の形（JSON）
- Produces: `public.apply_sheet_patch(p jsonb) returns jsonb`。`p` は `{ "patch": Patch, "set": {トップレベルの置き換え}, "sync": {sheetSync へマージ}, "touch": boolean }`。`touch` が true のときだけ `updated_at` を進める。戻り値は `{ "updated_at": … }`。実行できるのは service_role だけ

- [ ] **Step 1: SQL を書く**

```sql
-- supabase/sql/apply_sheet_patch.sql
-- スプシ側の同期が org_state に書くときの唯一の入口。
-- 「全体を読んで全体を書く」をせず、渡された項目だけを1回のトランザクションでマージする。
-- 値が null の項目はキーごと消す。
create or replace function public.apply_sheet_patch(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  d jsonb;
  pt jsonb := coalesce(p->'patch', '{}'::jsonb);
  n text; f jsonb; m text; mf jsonb;
  cur jsonb; ts timestamptz;
begin
  select data into d from org_state where id = 'main' for update;
  if d is null then raise exception 'org_state main がありません'; end if;

  if d->'memberOverrides' is null then d := jsonb_set(d, '{memberOverrides}', '{}'); end if;
  for n, f in select key, value from jsonb_each(coalesce(pt->'memberOverrides', '{}')) loop
    cur := coalesce(d->'memberOverrides'->n, '{}'::jsonb) || f;
    select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into cur
      from jsonb_each(cur) where value <> 'null'::jsonb;
    d := jsonb_set(d, array['memberOverrides', n], cur);
  end loop;

  if d->'compensation' is null then d := jsonb_set(d, '{compensation}', '{}'); end if;
  if d->'compensation'->'members' is null then d := jsonb_set(d, '{compensation,members}', '{}'); end if;
  for n, f in select key, value from jsonb_each(coalesce(pt->'compByMonth', '{}')) loop
    if d->'compensation'->'members'->n is null then
      d := jsonb_set(d, array['compensation', 'members', n], '{}');
    end if;
    if d->'compensation'->'members'->n->'byMonth' is null then
      d := jsonb_set(d, array['compensation', 'members', n, 'byMonth'], '{}');
    end if;
    for m, mf in select key, value from jsonb_each(f) loop
      cur := coalesce(d->'compensation'->'members'->n->'byMonth'->m, '{}'::jsonb) || mf;
      select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into cur
        from jsonb_each(cur) where value <> 'null'::jsonb;
      d := jsonb_set(d, array['compensation', 'members', n, 'byMonth', m], cur);
    end loop;
  end loop;

  if jsonb_array_length(coalesce(pt->'addMembers', '[]')) > 0 then
    d := jsonb_set(d, '{members}', (
      select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select x from jsonb_array_elements_text(coalesce(d->'members', '[]')) x
        union select x from jsonb_array_elements_text(pt->'addMembers') x) t));
  end if;
  if jsonb_array_length(coalesce(pt->'setDeleted', '[]')) > 0
     or jsonb_array_length(coalesce(pt->'unsetDeleted', '[]')) > 0 then
    d := jsonb_set(d, '{deletedMembers}', (
      select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select x from jsonb_array_elements_text(coalesce(d->'deletedMembers', '[]')) x
        where not coalesce(pt->'unsetDeleted', '[]') ? x
        union select x from jsonb_array_elements_text(coalesce(pt->'setDeleted', '[]')) x) t));
  end if;

  for n, f in select key, value from jsonb_each(coalesce(p->'set', '{}')) loop
    d := jsonb_set(d, array[n], f);
  end loop;
  if p ? 'sync' then
    d := jsonb_set(d, '{sheetSync}', coalesce(d->'sheetSync', '{}'::jsonb) || (p->'sync'));
  end if;

  if coalesce((p->>'touch')::boolean, false) then
    update org_state set data = d, updated_at = now() where id = 'main' returning updated_at into ts;
  else
    update org_state set data = d where id = 'main' returning updated_at into ts;
  end if;
  return jsonb_build_object('updated_at', ts);
end;
$$;

revoke all on function public.apply_sheet_patch(jsonb) from public, anon, authenticated;
grant execute on function public.apply_sheet_patch(jsonb) to service_role;
```

- [ ] **Step 2: dev に入れる**

`apply_migration`（project `vsqrgcsobweaupiabagu`、name `apply_sheet_patch`、query は上のファイルの中身）。

- [ ] **Step 3: 退避用の行で動作を確かめる**

本体（main）を汚さないため、関数をコピーした一時関数で試すのではなく、トランザクションの中で実行して巻き戻す:

```sql
begin;
select public.apply_sheet_patch('{
  "patch": {
    "memberOverrides": {"井上貴雅": {"area": "テスト", "status": null}},
    "compByMonth": {"井上貴雅": {"2026-09": {"score360": 9.9}}},
    "addMembers": ["テスト新人"], "setDeleted": [], "unsetDeleted": []
  },
  "sync": {"pulledAt": "test"}, "touch": true}'::jsonb);
select data->'memberOverrides'->'井上貴雅'->>'area' area,
       data->'memberOverrides'->'井上貴雅' ? 'hoursByMonth' kept_hours,
       data->'compensation'->'members'->'井上貴雅'->'byMonth'->'2026-09'->>'score360' s360,
       data->'members' ? 'テスト新人' added,
       data->'sheetSync'->>'pulledAt' synced
from org_state where id = 'main';
rollback;
```

Expected: `area=テスト`、`kept_hours=true`、`s360=9.9`、`added=true`、`synced=test`。最後に `select data->'memberOverrides'->'井上貴雅'->>'area' from org_state where id='main'` が元の値に戻っていること。

- [ ] **Step 4: anon から呼べないことを確かめる**

```sql
select has_function_privilege('anon', 'public.apply_sheet_patch(jsonb)', 'execute') as anon_can;
```

Expected: `false`

- [ ] **Step 5: Commit**

```bash
git add supabase/sql && git commit -q -m "Merge sheet edits into the state in one statement"
```

---

### Task 6: Google と Supabase の呼び出し、`org-sheets-pull`

**Files:**
- Create: `組織管理v2/sync/google.ts`
- Create: `組織管理v2/supabase/functions/org-sheets-pull/index.ts`

**Interfaces:**
- Consumes: Task 3・4 の `memberRowsToPatch`・`monthlyRowsToPatch`・`emptyPatch`・`isEmptyPatch`、Task 5 の `apply_sheet_patch`
- Produces（Task 8・10 が使う）:
  - `ORG_BOOK`・`PAY_BOOK`（ブックID）
  - `sheetsToken(): Promise<string>`（書き込み可のスコープ）
  - `readTab(token, bookId, title): Promise<string[][]>`（表示どおりの文字列。タブが無ければ `[]`）
  - `tabIds(token, bookId): Promise<Record<string, number>>`
  - `ensureTab(token, bookId, title): Promise<number>`
  - `writeTab(token, bookId, title, rows, opts?: { userEntered?: boolean }): Promise<void>`（消して書く）
  - `appendRows(token, bookId, title, rows): Promise<void>`
  - `protectTab(token, bookId, sheetId, description): Promise<void>`（警告だけの保護。同じ説明の保護が既にあれば何もしない）
  - `loadState(): Promise<{ data: any; updated_at: string }>`
  - `applySheetPatch(body): Promise<{ updated_at: string }>`
  - HTTP：`POST /functions/v1/org-sheets-pull` に `{ dryRun?: boolean }`。返り値 `{ ok, dryRun, changes: string[], warnings: string[] }`

- [ ] **Step 1: `sync/google.ts` を書く**

```ts
// sync/google.ts
// Sheets API と Supabase（service role）の呼び出し。Edge Function（Deno）専用。
declare const Deno: any;

export const ORG_BOOK = "1sNxLwO7TDVTyQkGMJlkCRvwinrVo6PV2YkNQ7SvQKEc";
export const PAY_BOOK = "1l6dlf4NG9V0u5z_MlPwIPUEEYeIBOwa8-ZhjeUdemBA";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const svcHeaders = {
  apikey: SERVICE_ROLE_KEY,
  Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
  "Content-Type": "application/json",
};

export const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...CORS_HEADERS } });
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
const b64s = (s: string) => base64url(new TextEncoder().encode(s));

export async function sheetsToken(): Promise<string> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_vault_secret`, {
    method: "POST", headers: svcHeaders, body: JSON.stringify({ secret_name: "gcp_sheets_service_account" }),
  });
  if (!r.ok) throw new Error(`vault secret fetch failed: ${r.status} ${await r.text()}`);
  const sa = JSON.parse(await r.json());
  const pem = sa.private_key.replace("-----BEGIN PRIVATE KEY-----", "").replace("-----END PRIVATE KEY-----", "").replace(/\s+/g, "");
  const key = await crypto.subtle.importKey("pkcs8", Uint8Array.from(atob(pem), (c) => c.charCodeAt(0)).buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${b64s(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.${b64s(JSON.stringify({
    iss: sa.client_email, scope: "https://www.googleapis.com/auth/spreadsheets",
    aud: sa.token_uri, iat: now, exp: now + 3600,
  }))}`;
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  const res = await fetch(sa.token_uri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${unsigned}.${base64url(new Uint8Array(sig))}` }),
  });
  if (!res.ok) throw new Error(`Token request failed: ${res.status} ${await res.text()}`);
  return (await res.json()).access_token as string;
}

async function sheets(token: string, bookId: string, path: string, init: RequestInit = {}) {
  const res = await fetch(`https://sheets.googleapis.com/v4/spreadsheets/${bookId}${path}`, {
    ...init, headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...(init.headers || {}) },
  });
  if (!res.ok) throw new Error(`Sheets API ${path} failed: ${res.status} ${await res.text()}`);
  return res.json();
}

export async function tabIds(token: string, bookId: string): Promise<Record<string, number>> {
  const meta = await sheets(token, bookId, "?fields=sheets.properties(title,sheetId)");
  return Object.fromEntries((meta.sheets || []).map((s: any) => [s.properties.title, s.properties.sheetId]));
}

export async function readTab(token: string, bookId: string, title: string): Promise<string[][]> {
  const ids = await tabIds(token, bookId);
  if (!(title in ids)) return [];
  const data = await sheets(token, bookId,
    `/values/${encodeURIComponent(`${title}!A1:BZ3000`)}?majorDimension=ROWS&valueRenderOption=FORMATTED_VALUE`);
  return (data.values || []).map((r: unknown[]) => r.map((v) => String(v ?? "")));
}

export async function ensureTab(token: string, bookId: string, title: string): Promise<number> {
  const ids = await tabIds(token, bookId);
  if (title in ids) return ids[title];
  const res = await sheets(token, bookId, ":batchUpdate", {
    method: "POST", body: JSON.stringify({ requests: [{ addSheet: { properties: { title } } }] }),
  });
  return res.replies[0].addSheet.properties.sheetId;
}

export async function writeTab(token: string, bookId: string, title: string, rows: string[][], opts: { userEntered?: boolean } = {}) {
  await ensureTab(token, bookId, title);
  await sheets(token, bookId, `/values/${encodeURIComponent(title)}:clear`, { method: "POST", body: "{}" });
  if (rows.length === 0) return;
  const mode = opts.userEntered ? "USER_ENTERED" : "RAW";
  await sheets(token, bookId, `/values/${encodeURIComponent(`${title}!A1`)}?valueInputOption=${mode}`, {
    method: "PUT", body: JSON.stringify({ values: rows }),
  });
}

export async function appendRows(token: string, bookId: string, title: string, rows: string[][]) {
  if (rows.length === 0) return;
  await sheets(token, bookId, `/values/${encodeURIComponent(`${title}!A1`)}:append?valueInputOption=RAW&insertDataOption=INSERT_ROWS`, {
    method: "POST", body: JSON.stringify({ values: rows }),
  });
}

export async function protectTab(token: string, bookId: string, sheetId: number, description: string) {
  const meta = await sheets(token, bookId, "?fields=sheets(properties.sheetId,protectedRanges(description))");
  const sheet = (meta.sheets || []).find((s: any) => s.properties.sheetId === sheetId);
  if ((sheet?.protectedRanges || []).some((p: any) => p.description === description)) return;
  await sheets(token, bookId, ":batchUpdate", {
    method: "POST",
    body: JSON.stringify({ requests: [
      { addProtectedRange: { protectedRange: { range: { sheetId }, description, warningOnly: true } } },
      { updateSheetProperties: { properties: { sheetId, gridProperties: { frozenRowCount: 1 } }, fields: "gridProperties.frozenRowCount" } },
    ] }),
  });
}

export async function loadState(): Promise<{ data: any; updated_at: string }> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/org_state?id=eq.main&select=data,updated_at`, { headers: svcHeaders });
  if (!r.ok) throw new Error(`org_state fetch failed: ${r.status} ${await r.text()}`);
  const row = (await r.json())[0];
  if (!row) throw new Error("org_state main がありません");
  return row;
}

export async function applySheetPatch(body: unknown): Promise<{ updated_at: string }> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/apply_sheet_patch`, {
    method: "POST", headers: svcHeaders, body: JSON.stringify({ p: body }),
  });
  if (!r.ok) throw new Error(`apply_sheet_patch failed: ${r.status} ${await r.text()}`);
  return r.json();
}
```

- [ ] **Step 2: `org-sheets-pull` を書く**

```ts
// supabase/functions/org-sheets-pull/index.ts
// 編集タブ（組織ブック「メンバー」・報酬ブック「月次入力」）を読み、変わった項目だけを org_state へマージする。
// dryRun: true なら書かずに、変わる予定の項目を返す。
import { CORS_HEADERS, json, ORG_BOOK, PAY_BOOK, sheetsToken, readTab, loadState, applySheetPatch } from "./google.ts";
import { memberRowsToPatch, monthlyRowsToPatch, isEmptyPatch } from "./sheet-mapping.ts";

declare const Deno: any;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  const body = await req.json().catch(() => ({}));
  const dryRun = body.dryRun === true;
  try {
    const token = await sheetsToken();
    const [memberRows, monthlyRows] = await Promise.all([
      readTab(token, ORG_BOOK, "メンバー"),
      readTab(token, PAY_BOOK, "月次入力"),
    ]);
    if (memberRows.length === 0) throw new Error("組織ブックに「メンバー」タブが無いか、空です");
    if (monthlyRows.length === 0) throw new Error("報酬ブックに「月次入力」タブが無いか、空です");

    const { data: state } = await loadState();
    const m = memberRowsToPatch(memberRows, state);
    const c = monthlyRowsToPatch(monthlyRows, state);
    const patch = { ...m.patch, compByMonth: c.patch.compByMonth };
    const changes = [...m.changes, ...c.changes];
    const warnings = [...m.warnings, ...c.warnings];

    if (dryRun) return json({ ok: true, dryRun, changes, warnings });

    await applySheetPatch({
      patch,
      touch: !isEmptyPatch(patch),
      sync: { pulledAt: new Date().toISOString(), pullError: null, pullWarnings: warnings, lastChanges: changes.slice(0, 50) },
    });
    return json({ ok: true, dryRun, changes, warnings });
  } catch (e) {
    const msg = String(e).replace(/^Error:\s*/, "");
    console.error(e);
    if (!dryRun) {
      await applySheetPatch({ sync: { pullError: msg, pullFailedAt: new Date().toISOString() } }).catch(() => {});
    }
    return json({ ok: false, error: msg }, 500);
  }
});
```

- [ ] **Step 3: 型を確かめる**

`node --test sync/` が引き続き通ること（`google.ts` はテストから読まない）。

- [ ] **Step 4: デプロイ**（自分で行う。他のエージェントに任せない）

`deploy_edge_function`：project `vsqrgcsobweaupiabagu`、name `org-sheets-pull`、`entrypoint_path: "index.ts"`、`verify_jwt: true`、files は
`index.ts`（`supabase/functions/org-sheets-pull/index.ts`）、`google.ts`（`sync/google.ts`）、`sheet-mapping.ts`（`sync/sheet-mapping.ts`）。

デプロイ後に `get_edge_function` で取り出し、日本語と改行が壊れていないこと（`\n` や `\"` がそのまま入っていないこと）を確かめる。

- [ ] **Step 5: タブがまだ無い状態で失敗することを確かめる**

```sql
select net.http_post(url := 'https://vsqrgcsobweaupiabagu.supabase.co/functions/v1/org-sheets-pull',
  headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer <DEV_SUPABASE_ANON_KEY>'),
  body := '{"dryRun": true}'::jsonb, timeout_milliseconds := 60000) as id;
-- 数秒後
select status_code, content from net._http_response where id = <id>;
```

Expected: `status_code=500`、`「メンバー」タブが無いか、空です`。dev の `org_state.updated_at` が変わっていないこと。

- [ ] **Step 6: Commit**

```bash
git add sync/google.ts supabase/functions/org-sheets-pull && git commit -q -m "Pull member and pay edits from the books"
```

---

### Task 7: 写しタブの表

**Files:**
- Create: `組織管理v2/sync/mirror-tables.ts`
- Test: `組織管理v2/sync/mirror-tables.test.ts`

**Interfaces:**
- Produces: `buildOrgMirrors(state): Record<string, string[][]>`（組織ブックのタブ名 → 表）、`buildPayMirrors(state): Record<string, string[][]>`（報酬ブック）。タブ名は
  `アサイン一覧（自動）`・`プロジェクト一覧（自動）`・`コミュニティ運営一覧（自動）`・`有償枠（自動）`・`エリア別一覧（自動）`・`プロフィール（自動）`・`稼働時間（自動）`・`NDA（自動）`、報酬は `業務内容（自動）`

- [ ] **Step 1: 失敗するテストを書く**

```ts
// sync/mirror-tables.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildOrgMirrors, buildPayMirrors } from "./mirror-tables.ts";

const s = {
  members: ["山田太郎", "鈴木花子", "BS三郎"],
  deletedMembers: ["退会次郎"],
  memberOverrides: {
    "山田太郎": { area: "関西", ndaSigned: true, hobby: "釣り", hoursByMonth: { "2026-09": { hours: 50, projectHoursTotal: 20, projectHours: { NoBorder: 20 } } } },
    "鈴木花子": { area: "関東" },
    "BS三郎": { isBS: true },
    "退会次郎": {},
  },
  projects: [{ name: "NoBorder", capacity: 3, mentors: [{ name: "先生", role: "" }],
    students: [{ name: "山田太郎", role: "PM" }], groups: [{ name: "分析", members: [{ name: "鈴木花子", role: "" }] }] }],
  departments: [{ name: "人事", lead: [{ name: "山田太郎", role: "統括" }], groups: [] }],
  schools: [{ name: "AI", tl: "鈴木花子", subTl: "", students: ["山田太郎"] }],
  paidGroups: [{ name: "組織運営専任", members: [{ name: "山田太郎", role: "" }] }],
  compensation: { members: { "山田太郎": { workNotes: { "2026-09": "広報" } } } },
};

test("組織ブックの写しタブがそろう", () => {
  const t = buildOrgMirrors(s);
  assert.deepEqual(Object.keys(t).sort(), ["NDA（自動）", "アサイン一覧（自動）", "エリア別一覧（自動）", "コミュニティ運営一覧（自動）",
    "プロジェクト一覧（自動）", "プロフィール（自動）", "有償枠（自動）", "稼働時間（自動）"].sort());
});

test("アサイン一覧は在籍者だけで、PJ・部署・スクールが並ぶ", () => {
  const rows = buildOrgMirrors(s)["アサイン一覧（自動）"];
  const yamada = rows.find((r) => r[0] === "山田太郎")!;
  assert.ok(yamada.includes("NoBorder（PM）"));
  assert.ok(yamada.includes("人事統括"));
  assert.ok(yamada.includes("AIスクール"));
  assert.ok(!rows.some((r) => r[0] === "退会次郎" || r[0] === "BS三郎"));
});

test("プロジェクト一覧はグループの人も学生として数える", () => {
  const rows = buildOrgMirrors(s)["プロジェクト一覧（自動）"];
  assert.deepEqual(rows[1].slice(0, 4), ["NoBorder", "3", "2", "1"]);
});

test("稼働時間は月×人", () => {
  const rows = buildOrgMirrors(s)["稼働時間（自動）"];
  assert.deepEqual(rows[1], ["2026-09", "山田太郎", "50", "20", "NoBorder:20"]);
});

test("業務内容は月×人", () => {
  assert.deepEqual(buildPayMirrors(s)["業務内容（自動）"][1], ["2026-09", "山田太郎", "広報"]);
});
```

- [ ] **Step 2: 失敗を確かめる**

Run: `node --test sync/`
Expected: FAIL（`mirror-tables.ts` が無い）

- [ ] **Step 3: 実装する**（一覧3種は今の `sheets-backup`、エリア別は `sheets-area-list` の作り方をそのまま移したもの）

```ts
// sync/mirror-tables.ts
// 写しタブ（見るだけ）の表を state から作る。副作用なし。
const str = (v: unknown) => (v == null ? "" : String(v));
const variants = (n: string) => [n, n.replace(/﨑/g, "崎"), n.replace(/崎/g, "﨑")];
const byJa = (a: string, b: string) => a.localeCompare(b, "ja");

function info(state: any, name: string): any {
  const ov = state.memberOverrides || {};
  for (const k of variants(name)) if (ov[k]) return ov[k];
  return {};
}
const isDeleted = (state: any, n: string) => variants(n).some((k) => (state.deletedMembers || []).includes(k));
const isBS = (state: any, n: string) => !!info(state, n).isBS;
const skip = (state: any, n: string) => isBS(state, n) || isDeleted(state, n);
function activeNames(state: any): string[] {
  const names = new Set<string>(state.members || []);
  Object.keys(state.memberOverrides || {}).forEach((n) => names.add(n));
  return Array.from(names).filter((n) => !skip(state, n)).sort(byJa);
}

const PLAIN_ROLES = ["統括", "副統括", "代表", "補佐", "秘書", "TL", "副TL"];
function assignLabel(base: string, role: string): string {
  if (!role) return base;
  return PLAIN_ROLES.includes(role) ? base + role : `${base}（${role}）`;
}

function assignRows(state: any): string[][] {
  const map: Record<string, string[]> = {};
  const add = (n: string, label: string) => { if (!skip(state, n)) (map[n] ||= []).push(label); };
  activeNames(state).forEach((n) => (map[n] ||= []));
  (state.departments || []).forEach((d: any) => {
    (d.lead || []).forEach((m: any) => add(m.name, assignLabel(d.name, m.role)));
    (d.groups || []).forEach((g: any) => {
      (g.members || []).forEach((m: any) => add(m.name, assignLabel(g.name, m.role)));
      (g.subGroups || []).forEach((sg: any) => (sg.members || []).forEach((m: any) => add(m.name, assignLabel(sg.name, m.role))));
    });
  });
  (state.projects || []).forEach((p: any) => {
    (p.students || []).forEach((m: any) => add(m.name, assignLabel(p.name, m.role)));
    (p.groups || []).forEach((g: any) => (g.members || []).forEach((m: any) => add(m.name, assignLabel(`${p.name}/${g.name}`, m.role))));
  });
  (state.schools || []).forEach((s: any) => {
    const role: Record<string, string> = {};
    (s.students || []).forEach((n: string) => { role[n] = ""; });
    if (s.subTl) role[s.subTl] = "副TL";
    if (s.tl) role[s.tl] = "TL";
    Object.entries(role).forEach(([n, r]) => add(n, assignLabel(`${s.name}スクール`, r)));
  });
  const rows = Object.keys(map).sort(byJa).map((n) => {
    const st = info(state, n).status;
    return [st ? `${n}（${st}）` : n, ...Array.from(new Set(map[n]))];
  });
  const width = Math.max(2, ...rows.map((r) => r.length));
  return [["氏名", ...Array.from({ length: width - 1 }, (_, i) => `アサイン${i + 1}`)], ...rows];
}

function projectStudents(state: any, p: any): string[] {
  const byKey = new Map<string, string>();
  const add = (m: any) => {
    const n = m && m.name;
    if (!n || isBS(state, n)) return;
    const k = n.replace(/﨑/g, "崎");
    if (!byKey.has(k)) byKey.set(k, n);
  };
  (p.students || []).forEach(add);
  (p.groups || []).forEach((g: any) => (g.members || []).forEach(add));
  return Array.from(byKey.values());
}
function projectRows(state: any): string[][] {
  return [["プロジェクト", "定員", "参加人数", "空き", "メンター", "学生"],
    ...(state.projects || []).map((p: any) => {
      const st = projectStudents(state, p);
      const cap = typeof p.capacity === "number" && p.capacity > 0 ? p.capacity : st.length;
      return [p.name, str(cap), str(st.length), str(Math.max(0, cap - st.length)),
        (p.mentors || []).map((m: any) => m.name).join("、"), st.join("、")];
    })];
}
function deptRows(state: any): string[][] {
  const rows: string[][] = [["部署", "グループ", "サブグループ", "氏名", "役割"]];
  (state.departments || []).forEach((d: any) => {
    (d.lead || []).forEach((m: any) => rows.push([d.name, "（統括）", "", m.name, str(m.role)]));
    (d.groups || []).forEach((g: any) => {
      (g.members || []).forEach((m: any) => rows.push([d.name, g.name, "", m.name, str(m.role)]));
      (g.subGroups || []).forEach((sg: any) => (sg.members || []).forEach((m: any) => rows.push([d.name, g.name, sg.name, m.name, str(m.role)])));
    });
  });
  return rows;
}
function paidRows(state: any): string[][] {
  const rows: string[][] = [["枠", "氏名", "役割"]];
  (state.paidGroups || []).forEach((g: any) => (g.members || []).forEach((m: any) => rows.push([g.name, m.name, str(m.role)])));
  return rows;
}
const AREA_ORDER = ["関東", "関西", "中部", "東北", "北海道", "九州", "中国", "四国"];
function isPaid(state: any, n: string): boolean {
  const keys = variants(n);
  return (state.paidGroups || []).some((g: any) => (g.members || []).some((m: any) => keys.includes(m.name)));
}
function areaRows(state: any): string[][] {
  const rows: string[][] = [["エリア", "区分", "氏名"]];
  const active = activeNames(state);
  for (const area of AREA_ORDER) {
    const inArea = active.filter((n) => str(info(state, n).area) === area);
    if (!inArea.length) continue;
    const paid = inArea.filter((n) => isPaid(state, n));
    const unpaid = inArea.filter((n) => !isPaid(state, n));
    rows.push([`── ${area}（有償 ${paid.length}名 / 無償 ${unpaid.length}名 ／ 計 ${inArea.length}名）──`, "", ""]);
    paid.forEach((n) => rows.push([area, "有償", n]));
    unpaid.forEach((n) => rows.push([area, "無償", n]));
  }
  return rows;
}
function profileRows(state: any): string[][] {
  return [["氏名", "趣味", "経験", "スキル", "やりたいこと", "尊敬する人"],
    ...activeNames(state).map((n) => {
      const mi = info(state, n);
      return [n, str(mi.hobby), str(mi.experience), str(mi.skills), str(mi.wantToDo), str(mi.admires)];
    })];
}
function hoursRows(state: any): string[][] {
  const rows: string[][] = [["月", "氏名", "稼働時間", "PJ稼働合計", "PJ別"]];
  const recs: string[][] = [];
  for (const n of Object.keys(state.memberOverrides || {})) {
    const hb = (state.memberOverrides[n] || {}).hoursByMonth || {};
    for (const m of Object.keys(hb)) {
      const r = hb[m] || {};
      recs.push([m, n, str(r.hours), str(r.projectHoursTotal ?? ""),
        Object.entries(r.projectHours || {}).map(([k, h]) => `${k}:${h}`).join("、")]);
    }
  }
  recs.sort((a, b) => b[0].localeCompare(a[0]) || byJa(a[1], b[1]));
  return [...rows, ...recs];
}
function ndaRows(state: any): string[][] {
  return [["氏名", "NDA"], ...activeNames(state).map((n) => [n, info(state, n).ndaSigned ? "締結済み" : "未締結"])];
}
function workNoteRows(state: any): string[][] {
  const recs: string[][] = [];
  const members = ((state.compensation || {}).members) || {};
  for (const n of Object.keys(members)) {
    const notes = members[n].workNotes || {};
    for (const m of Object.keys(notes)) recs.push([m, n, str(notes[m])]);
  }
  recs.sort((a, b) => b[0].localeCompare(a[0]) || byJa(a[1], b[1]));
  return [["月", "氏名", "業務内容"], ...recs];
}

export function buildOrgMirrors(state: any): Record<string, string[][]> {
  return {
    "アサイン一覧（自動）": assignRows(state),
    "プロジェクト一覧（自動）": projectRows(state),
    "コミュニティ運営一覧（自動）": deptRows(state),
    "有償枠（自動）": paidRows(state),
    "エリア別一覧（自動）": areaRows(state),
    "プロフィール（自動）": profileRows(state),
    "稼働時間（自動）": hoursRows(state),
    "NDA（自動）": ndaRows(state),
  };
}
export function buildPayMirrors(state: any): Record<string, string[][]> {
  return { "業務内容（自動）": workNoteRows(state) };
}
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `node --test sync/`
Expected: 18 tests pass

- [ ] **Step 5: Commit**

```bash
git add sync/ && git commit -q -m "Build the read-only mirror tabs from the state"
```

---

### Task 8: `org-sheets-push`（写しと初回書き出し）

**Files:**
- Create: `組織管理v2/supabase/functions/org-sheets-push/index.ts`

**Interfaces:**
- Consumes: Task 6 の `google.ts` 一式、Task 3・4 の `stateToMemberRows`・`stateToMonthlyRows`、Task 7 の `buildOrgMirrors`・`buildPayMirrors`
- Produces: HTTP `POST /functions/v1/org-sheets-push` に `{ seed?: boolean, months?: string[], force?: boolean }`。
  通常は写しタブだけを書き直す（`org_state.updated_at` が前回と同じなら何もしない）。`seed: true` のときは編集タブ（メンバー・月次入力）と「募集」タブも書く。
  `sheetSync.pushedAt`・`sheetSync.pushedFor`（書き出した時点の updated_at）・`sheetSync.tabs`（`{ "org:メンバー": gid, … }`）を残す

- [ ] **Step 1: 書く**

```ts
// supabase/functions/org-sheets-push/index.ts
// Supabase → スプシ。写しタブ（…（自動））を消して書き直す。
// seed: true のときだけ、編集タブ（メンバー・月次入力）を今の state から作る（移行の1回だけ）。
import { CORS_HEADERS, json, ORG_BOOK, PAY_BOOK, sheetsToken, readTab, writeTab, ensureTab, protectTab, tabIds,
  loadState, applySheetPatch } from "./google.ts";
import { stateToMemberRows, stateToMonthlyRows } from "./sheet-mapping.ts";
import { buildOrgMirrors, buildPayMirrors } from "./mirror-tables.ts";

declare const Deno: any;

const RECRUIT_BOOK = "1DcALjQGfuExjzCMC5BIQdQWu0g1wI_phovmTsWtka44";
const PROTECT_NOTE = "自動で書き直すタブです。直してもアプリには反映されず、次の同期で上書きされます";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  const body = await req.json().catch(() => ({}));
  try {
    const { data: state, updated_at } = await loadState();
    const sync = state.sheetSync || {};
    if (!body.seed && sync.pushedFor === updated_at) return json({ ok: true, skipped: true });

    const token = await sheetsToken();

    if (body.seed) {
      const months: string[] = Array.isArray(body.months) ? body.months : [];
      if (months.length === 0) throw new Error("seed には months（例: [\"2026-08\",\"2026-09\",\"2026-10\"]）が必要です");
      for (const [book, title] of [[ORG_BOOK, "メンバー"], [PAY_BOOK, "月次入力"]] as const) {
        const existing = await readTab(token, book, title);
        if (existing.length > 1 && !body.force) throw new Error(`「${title}」タブにすでにデータがあります。上書きするなら force: true`);
      }
      await writeTab(token, ORG_BOOK, "メンバー", stateToMemberRows(state));
      await writeTab(token, PAY_BOOK, "月次入力", stateToMonthlyRows(state, months));
      await writeTab(token, ORG_BOOK, "募集", [[`=IMPORTRANGE("${RECRUIT_BOOK}", "A1:BZ2000")`]], { userEntered: true });
    }

    for (const [book, tables] of [[ORG_BOOK, buildOrgMirrors(state)], [PAY_BOOK, buildPayMirrors(state)]] as const) {
      for (const [title, rows] of Object.entries(tables)) {
        await writeTab(token, book, title, rows);
        await protectTab(token, book, await ensureTab(token, book, title), PROTECT_NOTE);
      }
    }

    const [orgIds, payIds] = await Promise.all([tabIds(token, ORG_BOOK), tabIds(token, PAY_BOOK)]);
    const tabs: Record<string, number> = {};
    for (const [t, id] of Object.entries(orgIds)) tabs[`org:${t}`] = id;
    for (const [t, id] of Object.entries(payIds)) tabs[`pay:${t}`] = id;
    await applySheetPatch({ sync: { pushedAt: new Date().toISOString(), pushedFor: updated_at, pushError: null, tabs } });
    return json({ ok: true, seeded: !!body.seed, pushedFor: updated_at });
  } catch (e) {
    const msg = String(e).replace(/^Error:\s*/, "");
    console.error(e);
    await applySheetPatch({ sync: { pushError: msg, pushFailedAt: new Date().toISOString() } }).catch(() => {});
    return json({ ok: false, error: msg }, 500);
  }
});
```

`applySheetPatch` は `touch` を付けないので `updated_at` は進まない。だから次の5分で `pushedFor === updated_at` になり、何もしない。

- [ ] **Step 2: デプロイ**（自分で行う）

`deploy_edge_function`：name `org-sheets-push`、files `index.ts`・`google.ts`・`sheet-mapping.ts`・`mirror-tables.ts`。デプロイ後に `get_edge_function` で日本語が壊れていないことを確かめる。

- [ ] **Step 3: 写しだけを書いて確かめる**（seed なし）

`net.http_post` で `{}` を送る。Expected: `ok: true`。`sheets-read`（dev）で組織ブックを読み、「アサイン一覧（自動）」など8タブ、報酬ブックに「業務内容（自動）」があること。2回目の呼び出しは `skipped: true`。

- [ ] **Step 4: Commit**

```bash
git add supabase/functions/org-sheets-push && git commit -q -m "Mirror the state into the books and seed the edit tabs once"
```

---

### Task 9: 移行（初回書き出し → 往復の確認 → 取り込み）

**Files:** なし

- [ ] **Step 1: 初回書き出し**

`org-sheets-push` に `{"seed": true, "months": ["2026-08", "2026-09", "2026-10"]}`。Expected: `seeded: true`。

- [ ] **Step 2: 「募集」タブの接続を許可してもらう**

北村さんに組織ブックの「募集」タブを開き、A1 の「アクセスを許可」を押してもらう（`IMPORTRANGE` の初回だけ必要）。

- [ ] **Step 3: 往復の確認（書かない）**

`org-sheets-pull` に `{"dryRun": true}`。Expected:
- メンバー由来の `changes` が0件
- 報酬由来の `changes` は「直下の値を byMonth に書き込む」ものだけ（`2026-08 氏名: score360・…` の形）。各項目の値が `legacyPayInput` と同じであることは Task 4 のテストで保証済み
- `warnings` が0件。出たら中身を読んで原因を直し、Step 1 からやり直す（`force: true`）

- [ ] **Step 4: 取り込む**

`org-sheets-pull` に `{}`。Expected: `ok: true`。

- [ ] **Step 5: 差分ゼロを確かめる**

もう一度 `{"dryRun": true}`。Expected: `changes` が0件、`warnings` が0件。**ここが0件にならなければ先へ進まない。**

- [ ] **Step 6: 本番に変化がないことを確かめる**

本番 project で `select updated_at from org_state where id='main'`。Task 1 Step 5 の値と同じ（本番側の運用で変わっている場合は、変化が本番の通常運用によるものかを `git log`／運用状況で確かめる）。

---

### Task 10: 入会者の取り込み先を「メンバー」タブにする

**Files:**
- Create: `組織管理v2/supabase/functions/sheets-intake-sync/index.ts`（dev にある今の版を `get_edge_function` で取り出して置き、以下を直す）

**Interfaces:**
- Consumes: Task 6 の `google.ts`（`sheetsToken`・`readTab`・`appendRows`・`loadState`・`applySheetPatch`・`ORG_BOOK`）、Task 3 の `findCol`・`MEMBER_HEADERS`
- Produces: 新しい入会者が「メンバー」タブの末尾に行として足される。`state.recruitIntake` は `apply_sheet_patch` の `set` で更新する。`org_state` 全体を書き戻す処理は無くなる

- [ ] **Step 1: 今の版を取り出して置く**

`get_edge_function`（dev、`sheets-intake-sync`）の `index.ts` をそのまま `supabase/functions/sheets-intake-sync/index.ts` に保存して commit（`git commit -m "Keep the current intake sync as the starting point"`）。

- [ ] **Step 2: 書き込み部分を置き換える**

残すもの：`INTAKE_SPREADSHEET_ID` と、入会者タブを見つけて行を読む `fetchIntakeRows`・`normalizeName`・`isAutoCreatable`・`extractUniversity`・`MAX_CREATE_PER_RUN`。

消すもの：自前の JWT／`sheetsFetch`（`google.ts` の `sheetsToken` と同じものに置き換える。読み取り元の取得は `readTab` ではなく今の `fetchIntakeRows` のまま使い、トークンだけ差し替える）、`collectExistingNames`、`org_state` を PATCH する部分。

`Deno.serve` の本体を次にする:

```ts
import { CORS_HEADERS, json, ORG_BOOK, sheetsToken, readTab, appendRows, loadState, applySheetPatch } from "./google.ts";
import { findCol, MEMBER_HEADERS } from "./sheet-mapping.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  try {
    const reqBody = await req.json().catch(() => ({}));
    const dryRun = reqBody.dryRun === true;
    const token = await sheetsToken();
    const { rows, sheetTitle } = await fetchIntakeRows(token);

    // 名簿の本体は組織ブック「メンバー」。ここにある氏名・メアドは作らない
    const memberRows = await readTab(token, ORG_BOOK, "メンバー");
    if (memberRows.length === 0) throw new Error("組織ブックの「メンバー」タブが空です");
    const h = memberRows[0];
    const ci = (name: string) => findCol(h, [name]);
    const existingNames = new Set(memberRows.slice(1).map((r) => normalizeName(r[ci("氏名")] || "")));
    const existingEmails = new Set(memberRows.slice(1).map((r) => String(r[ci("メアド")] || "").toLowerCase()).filter(Boolean));

    const { data: state } = await loadState();
    const seenEmails: Record<string, string> = { ...((state.recruitIntake || {}).emails || {}) };

    const fresh = rows.filter((r) => !seenEmails[r.email] && !existingEmails.has(r.email) && !existingNames.has(r.name));
    const creatable = fresh.filter((r) => isAutoCreatable(r.name));
    const needsReview = fresh.filter((r) => !isAutoCreatable(r.name)).map((r) => ({
      email: r.email, name: r.rawName, university: r.university, joinedAt: r.joinedAt, reason: "氏名の表記を確認してください",
    }));
    if (creatable.length > MAX_CREATE_PER_RUN) {
      return json({ ok: false, error: `1回の実行で${creatable.length}名を作成しようとしたため中断しました（上限${MAX_CREATE_PER_RUN}名）。取り込み元のタブ「${sheetTitle}」が正しいか確認してください`,
        wouldCreate: creatable.map((r) => r.rawName) }, 409);
    }

    // 見出しの位置に合わせて行を組む（列の並びは人が入れ替えてよい）
    const newRows = creatable.map((r) => {
      const row = h.map(() => "");
      const put = (header: string, v: string) => { const i = ci(header); if (i >= 0) row[i] = v; };
      put("氏名", r.name); put("状態", "在籍"); put("大学", r.university); put("入会日", r.joinedAt);
      put("関わり方", r.track); put("紹介者", r.referredBy); put("メアド", r.email);
      return row;
    });

    if (!dryRun) {
      await appendRows(token, ORG_BOOK, "メンバー", newRows);
      for (const r of rows) if (existingNames.has(r.name) || creatable.includes(r)) seenEmails[r.email] = r.name;
      await applySheetPatch({ set: { recruitIntake: {
        emails: seenEmails, needsReview, syncedAt: new Date().toISOString(), sheetTitle,
      } } });
    }
    return json({ ok: true, dryRun, sheetTitle, scanned: rows.length, created: creatable.map((r) => r.name), needsReview });
  } catch (e) {
    console.error(e);
    return json({ ok: false, error: String(e).replace(/^Error:\s*/, "") }, 500);
  }
});
```

`fetchIntakeRows(accessToken)` の中の `sheetsFetch` は、`INTAKE_SPREADSHEET_ID` を読むだけの小さな関数として残す（`google.ts` のトークンを渡す）。**入会者シートへの書き込みは一切しない。**

既存メンバーへの紹介者の反映（今の `referrerUpdated` の処理）は、紹介者の列が「メンバー」タブにあるのでやめる。

- [ ] **Step 3: デプロイして試し運転**

`deploy_edge_function`：name `sheets-intake-sync`、files `index.ts`・`google.ts`・`sheet-mapping.ts`。`{"dryRun": true}` を送る。Expected: `ok: true`、`created` は0件（Task 9 で今のメンバーが全員タブにいるため）。

- [ ] **Step 4: Commit**

```bash
git add supabase/functions/sheets-intake-sync && git commit -q -m "Add new joiners as rows on the member tab"
```

---

### Task 11: dev の生データ履歴を、一覧なしにする

**Files:**
- Create: `組織管理v2/supabase/functions/sheets-backup/index.ts`（dev の今の版を取り出して直す）

- [ ] **Step 1: 今の版を取り出して置き、commit**

- [ ] **Step 2: 一覧系の書き込みを外す**

`Deno.serve` 内で `writeRawSnapshot` だけを呼び、`buildMembersRows`・`buildProjectsRows`・`buildDeptsRows`・`buildAssignRows`・`clearAndWrite`・`formatSheets` の呼び出しと、使わなくなった関数を削除する。`ensureSheetsExist` の `wanted` は `[RAW_SHEET]` だけにする。`SPREADSHEET_ID` は dev 用ブック（`1j6rT…`）のまま変えない。

- [ ] **Step 3: デプロイして1回動かす**

Expected: `ok: true`、dev 用ブックの「生データ履歴」に1行増える。本番ブック `1Avaf…` に変化がないこと（`sheets-read` で本番ブックの行数を前後で比べる。読むだけ）。

- [ ] **Step 4: Commit**

```bash
git add supabase/functions/sheets-backup && git commit -q -m "Keep only the raw history in the dev backup book"
```

---

### Task 12: 新アプリの編集を切り替える

**Files:**
- Modify: `組織管理v2/index.html`

**Interfaces:**
- Consumes: `state.sheetSync.tabs`（Task 8）、`org-sheets-pull`（Task 6）、既存の `callEdgeFn(slug, body)`

- [ ] **Step 1: ブックへのリンクを作る関数を足す**（`callEdgeFn` の定義の直後）

```js
// ====== スプシ（新システムの本体） ======
const ORG_BOOK_ID = "1sNxLwO7TDVTyQkGMJlkCRvwinrVo6PV2YkNQ7SvQKEc";
const PAY_BOOK_ID = "1l6dlf4NG9V0u5z_MlPwIPUEEYeIBOwa8-ZhjeUdemBA";
function sheetTabUrl(book, title) {
  const id = book === "pay" ? PAY_BOOK_ID : ORG_BOOK_ID;
  const gid = ((state.sheetSync || {}).tabs || {})[`${book}:${title}`];
  return `https://docs.google.com/spreadsheets/d/${id}/edit${gid != null ? `#gid=${gid}` : ""}`;
}
function openSheetTab(book, title) { window.open(sheetTabUrl(book, title), "_blank", "noopener"); }

async function pullFromSheetsNow() {
  setStatus("⏳ スプシから反映中…");
  try {
    const r = await callEdgeFn("org-sheets-pull");
    setStatus(`✅ スプシから反映しました（変更 ${(r.changes || []).length}件${(r.warnings || []).length ? `・注意 ${r.warnings.length}件` : ""}）`, "#2f7d4a");
  } catch (e) {
    setStatus("❌ 反映に失敗: " + e.message, "#b73a4a");
  }
}
// 最後に同期した時刻とエラー。運営側の情報なので core 以上だけ作る。
function renderSheetSyncBar() {
  if (!roleAtLeast("core")) return "";
  const s = state.sheetSync || {};
  const t = (iso) => iso ? new Date(iso).toLocaleString("ja-JP", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" }) : "未実行";
  const warn = (s.pullWarnings || []);
  return `<div class="card" style="margin-bottom:12px;font-size:12px;display:flex;gap:12px;align-items:center;flex-wrap:wrap">
    <span>スプシから取り込み：${t(s.pulledAt)}</span>
    <span>スプシへ書き出し：${t(s.pushedAt)}</span>
    <button class="btn" onclick="pullFromSheetsNow()" style="font-size:12px;padding:4px 10px">今すぐ反映</button>
    <a href="${sheetTabUrl("org", "メンバー")}" target="_blank" rel="noopener">組織ブック</a>
    ${s.pullError ? `<span style="color:#b73a4a">取り込みエラー：${escapeHtml(s.pullError)}</span>` : ""}
    ${s.pushError ? `<span style="color:#b73a4a">書き出しエラー：${escapeHtml(s.pushError)}</span>` : ""}
    ${warn.length ? `<details><summary style="cursor:pointer">注意 ${warn.length}件</summary>${warn.map(w => `<div>${escapeHtml(w)}</div>`).join("")}</details>` : ""}
  </div>`;
}
```

`callEdgeFn` が失敗時に例外を投げ、成功時に JSON を返すことを確かめる（`sed -n` で `async function callEdgeFn` の本体を読む）。投げない作りなら、`r.ok === false` のとき `throw new Error(r.error)` を `pullFromSheetsNow` に足す。

- [ ] **Step 2: 同期バーを画面の先頭に出す**

`renderContent()` の最後（`else { const customTab … }` の閉じ括弧の後）に足す:

```js
  el.insertAdjacentHTML("afterbegin", renderSheetSyncBar());
```

- [ ] **Step 3: メンバーの編集をスプシへ回す**

次の4つの関数の本体を置き換える（`function addMember()`・`function deleteMember(name)`・`function restoreMember(name)`・`function editMember(name)`。中身は全部消す）:

```js
// メンバー情報の本体は組織ブック「メンバー」タブ。アプリでは直さない。
function addMember() { openSheetTab("org", "メンバー"); }
function deleteMember(name) { openSheetTab("org", "メンバー"); }
function restoreMember(name) { openSheetTab("org", "メンバー"); }
function editMember(name) { openSheetTab("org", "メンバー"); }
```

`saveMemberEdit` は呼ばれなくなるので削除する。`renderMemberCard` の「編集」ボタンの文言を「スプシで編集」にし、隣の退会ボタン（`deleteMember` を呼ぶもの）を削除する。全メンバータブのツールバーの「+ メンバーを追加」の文言を「スプシでメンバーを追加」にする。退会者の一覧の `onclick="restoreMember(…)"` と「クリックで復元」の文言を外し、ただの一覧にする。

- [ ] **Step 4: 報酬入力をスプシへ回し、月ごとの値だけを見る**

`editPayMember` の本体を `openSheetTab("pay", "月次入力");` だけにし、`savePayMember` を削除する。`payInfoOf` を置き換える:

```js
// 報酬の入力値は報酬ブック「月次入力」から byMonth["YYYY-MM"] に入る。月をまたいで効く値は持たない。
// workNotes などの自動で入る値だけはメンバー単位のまま。
const PAY_AUTO_FIELDS = ["workNotes", "nextMonthHours", "nextProjectHours", "nextProjectHoursTotal"];
function payInfoOf(name) {
  const m = ((state.compensation || {}).members) || {};
  let base = null;
  for (const k of [name, name.replace(/﨑/g, "崎"), name.replace(/崎/g, "﨑")]) if (m[k]) { base = m[k]; break; }
  if (!base) return {};
  const auto = {};
  for (const k of PAY_AUTO_FIELDS) if (k in base) auto[k] = base[k];
  return { ...auto, ...((base.byMonth || {})[payMonthKey()] || {}) };
}
```

`PAY_MONTHLY_FIELDS` を使っている箇所が他に無いか `grep -n PAY_MONTHLY_FIELDS index.html` で確かめ、`payInfoOf` の中だけで使っていたなら定義ごと削除する。報酬の表で「編集」に当たるボタンの文言を「スプシで編集」にする（`grep -n "editPayMember(" index.html` で場所を探す）。

- [ ] **Step 5: 募集の進捗を表示だけにする**

`recruitStatusControlHTML` と `recruitWebTestControlHTML` の `if (!roleAtLeast("core")) …` の分岐を外し、常にバッジだけを返す形にする（今の member 向けの返り値をそのまま使う）。`recruitOverrideNoteHTML` は常に `""` を返す。アプリでの上書き値を見ている関数（`grep -n "recruitOverrides" index.html` で探す。`hasRecruitOverride` などの取得関数）は `null` を返すようにし、`setRecruitOverrideField`・`setProvisionalCapacity`・`setRecruitStatus`・`setRecruitWebTest`・`clearRecruitOverride` と、それを呼んでいるボタンやリンクを削除する（`grep -n "setProvisionalCapacity(\|clearRecruitOverride(" index.html`）。募集タブのツールバーにある「募集フォームのシート」リンクは残す。

- [ ] **Step 6: 「1on1・移行状況」タブを外す**

タブ定義の配列から `{ id: "transition", … }` の行を削除し、`renderContent` の `else if (currentTab === "transition")` の分岐を削除する。`renderTransition`・`renderTransitionRow`・`addTransitionMember` など transition 用の関数は削除する（`grep -n "ransition" index.html` で残りを確かめる）。

- [ ] **Step 7: 動作を確かめる**（`preview_start {name:"v2"}`、`?key=` は admin のキー）

- 全メンバータブ：カードの「スプシで編集」で組織ブックの「メンバー」タブが開く。退会ボタンが無い
- 同期バーに取り込み・書き出しの時刻が出る。「今すぐ反映」で「変更 0件」
- 報酬タブ：2026-09 を表示し、Task 1 時点の本番アプリの同じ月と金額の合計が一致する（本番は rvss-org-zeta を開いて読むだけ。値は `javascript_tool` で表の合計を取る）
- 募集タブ：選択欄が無く、バッジだけ
- 「1on1・移行状況」タブが無い
- `read_console_messages` にエラーが無い
- `?key=` なし（member）で開くと同期バーが出ない

- [ ] **Step 8: Commit**

```bash
git add index.html && git commit -q -m "Edit members, pay and recruitment in the books instead of the app"
```

---

### Task 13: dev の定期実行を動かす

**Files:** なし（SQL）

- [ ] **Step 1: 今の dev の cron を確かめる**

```sql
select jobid, jobname, schedule, active from cron.job order by jobid;
```

Expected: 4本（`daily-sheets-backup`・`daily-sheets-contract-sync`・`monthly-notion-workload-sync`・`recruitment-sync-5h`）がすべて `active=false`。

- [ ] **Step 2: 止めていた4本を再開する**

```sql
select cron.alter_job(jobid, active := true) from cron.job
where jobname in ('daily-sheets-backup', 'daily-sheets-contract-sync', 'monthly-notion-workload-sync', 'recruitment-sync-5h');
```

- [ ] **Step 3: 本番にあって dev に無い定期実行を足す**（中身は本番の同名ジョブと同じ。URL と anon キーだけ dev に替える）

本番の `cron.job` から `monthly-workload-archive`・`monthly-notion-worklog-sync`・`intake-sync-daily` の `command` を読み（本番では読むだけ）、`dbrwsrrfmpnvpzxcdupp` を `vsqrgcsobweaupiabagu` に、Authorization の anon キーを dev のものに替えて `cron.schedule(jobname, schedule, command)` で dev に作る。`daily-sheets-area-list` は作らない（push に含めた）。

- [ ] **Step 4: pull と push を足す**

```sql
select cron.schedule('org-sheets-pull-5m', '*/5 * * * *', $$
  select net.http_post(
    url := 'https://vsqrgcsobweaupiabagu.supabase.co/functions/v1/org-sheets-pull',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer <DEV_SUPABASE_ANON_KEY>'),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
$$);
select cron.schedule('org-sheets-push-5m', '2-59/5 * * * *', $$
  select net.http_post(
    url := 'https://vsqrgcsobweaupiabagu.supabase.co/functions/v1/org-sheets-push',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer <DEV_SUPABASE_ANON_KEY>'),
    body := '{}'::jsonb, timeout_milliseconds := 120000);
$$);
```

push を2分ずらすのは、pull で入った変更をその回の push で写すため。

- [ ] **Step 5: 10分後に確かめる**

`select jobname, status, return_message, start_time from cron.job_run_details where start_time > now() - interval '15 minutes' order by start_time desc;` がすべて succeeded。`org_state.data->'sheetSync'` の `pulledAt`・`pushedAt` が10分以内、`pullError`・`pushError` が null。

---

### Task 14: 通しの確認と記録

**Files:**
- Modify: `組織管理v2/CLAUDE.md`
- Modify: `メンバーアサイン表/CLAUDE.md`（「開発環境で作業するとき」の節）

- [ ] **Step 1: 設計書の「確かめること」を順に確かめる**

1. 書き出し → 読み戻しで差分ゼロ（Task 9 Step 5 で確認済み。もう一度 dryRun）
2. 組織ブックで1人のエリアを変える → 「今すぐ反映」で新アプリに出る。戻してもう一度反映
3. 新アプリでアサインを1つ動かし、その直後に pull を手で呼ぶ → アサインが残っている。戻す
4. 「メンバー」タブの「状態」の見出しを一時的に「状態x」にする → pull が500で止まり、`sheetSync.pullError` に出る、`updated_at` が進まない。見出しを戻す
5. 「メンバー」タブで1人の行を一時的に切り取る → 退会にならず、警告に名前が出る。行を戻す
6. 共有の取り込み元シート（募集・契約・入会者）の最終更新が、作業の時間帯に新システム由来で変わっていない（`sheets-read` で読んで、行数と見出しが作業前と同じ）
7. 本番 `org_state.updated_at` と本番バックアップブックが、新システム由来で変化していない

- [ ] **Step 2: CLAUDE.md を更新する**

`組織管理v2/CLAUDE.md` に、同期の仕組み（pull 5分・push 5分＋2分ずらし・`apply_sheet_patch`・タブの決まり）と cron の一覧を足す。

`メンバーアサイン表/CLAUDE.md` の「開発環境で作業するとき」を書き換える：dev は新システム（`組織管理v2/`）の本体になったこと、dev の cron は動いていること、dev の `org_state` は本番の写しではなくなったこと、本番の作業で dev を検証に使わないこと。

- [ ] **Step 3: Commit**

```bash
cd "/c/Users/mr171/claude/RVSS/組織管理v2" && git add CLAUDE.md && git commit -q -m "Describe how the sync runs"
cd "/c/Users/mr171/claude/RVSS/メンバーアサイン表" && git add CLAUDE.md && git commit -q -m "Note that dev is now the new system, not a copy of production"
```

`メンバーアサイン表` 側は push しない（push すると本番 Vercel のビルドが走る。CLAUDE.md だけの変更でも同じ）。push するかは北村さんに確認する。
