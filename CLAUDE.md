# RVSS組織管理

`index.html` 1枚だけのアプリ。ビルド工程なし。Supabase JS は CDN から読む。

## このファイルの扱い

3300行・163KBある。**全文を読むと会話の枠を1回で大きく消費するので、原則読まない。**

- 場所を探す: `grep -n` で当たりをつける
- 読む: `sed -n '1200,1260p'` のように必要な範囲だけ
- 直す: 1〜2箇所なら Edit、複数箇所の同じ置換なら Node のパッチスクリプト

**改行は CRLF。** パッチスクリプトを書くときは壊さないこと。

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
