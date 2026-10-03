# Canva自己紹介の取り込み手順

週1回の定期実行（Claudeのスケジュール実行）がこの手順で動く。手で「Canvaから取り直して」と頼まれたときも同じ。

## 対象

| | |
|---|---|
| Canvaのデザイン | `RVstudents_自己紹介`（design_id `DAG5BsKRF_I`）。1ページ＝1人 |
| 書き込み先 | Supabase `org_state`（id='main'）の `data.memberOverrides[氏名]` |
| 記録 | `data.canvaSync`（最後に取り込んだ日時・突き合わせ結果） |

接続先の project ref は CLAUDE.md の表を見る。**本番に書く前に dev で確かめる**のは他の作業と同じ。

## 名簿はアプリが基準

基準になるのはアプリの名簿だけ。`members` と `memberOverrides` のキーを合わせ、
`deletedMembers` にいる人と `isBS` の人は除く。

- Canvaにいてアプリにいない人：**メンバーを作らない。** `canvaSync.notInApp` に名前を残すだけ
  （退会済みの人は `notInAppDeleted` に分ける）
- アプリにいてCanvaにいない人：`canvaSync.missingInCanva`
- Canvaにページはあるが中身が空の人：`canvaSync.emptyInCanva`

氏名の突き合わせは空白を除き、﨑／崎などの異体字をそろえてから比べる。
Canva側のふりがなや「けん」のような添え書きは無視する。

## Canvaの読み方（ここを間違えやすい）

`read-design` の `design_content` は、ページ内の文字を**レイアウトと関係ない順番**で返す。

- **ページの区切りは空行2つ（`\n\n\n`）。** 氏名がそのページの先頭にも末尾にも来る。
  前のページの末尾にある氏名を次のページのものと読み違えた実例がある（小林桜輔さんと久次米謙さん）
- 欄の見出し（趣味・アピール・大学…）と中身が離れて並ぶので、見出しの直後の文がその欄とは限らない
- **どの文がどの欄か判断できないページは、`thumbnails` でそのページの画像を見て決める。**
  推測で埋めない

迷ったら1ページずつ読む（`page_indices` を1つだけ渡す）。

## 欄の対応

| Canvaの欄 | アプリの項目 | 書き方 |
|---|---|---|
| 大学 | `university` | 大学名だけ。**アプリ側が空のときだけ入れる**（入会者シートの値を優先） |
| 趣味 | `hobby` | 原文のまま |
| アピール（見出し横の短い文） | `skills` | 名詞を「、」でつなぐ。40字程度まで |
| アピール（下の長い文） | `experience` | 1〜2文に要約。100字程度まで |
| REAL VALUE STUDENTSでは ＋ 将来の夢 | `wantToDo` | 「〜したい。将来は〜」の形にまとめる |
| 尊敬する人 | `admires` | 原文のまま |

要約は本文にある事実だけを使う。推測で補わない。

## 上書きのしかた

**Canvaを正とする。** ただし毎週文面を作り直すと言い回しが揺れるので、
既存の値がCanvaの内容を正しく表しているなら書き換えない。

- Canvaに中身があり、アプリが空欄 → 入れる
- 両方に中身があり、**内容が食い違う**（Canvaが更新された・前回の取り込みが誤っていた）→ Canvaで書き直す
- 言い回しが違うだけで内容が同じ → 触らない
- Canvaが空欄 → アプリの値を残す

`canvaSync.designUpdatedAt` がデザインの `updated_at` と同じなら、Canvaは前回から変わっていない。
その場合は名簿の突き合わせだけをやり直し、プロフィールの書き換えは省いてよい。

## 書き込み

`memberOverrides[氏名]` は**作り直さない。** 既存のオブジェクトに、変える項目だけをマージする
（稼働時間・契約状況・スキル分類など、編集フォームに無い項目が消えるため）。

```sql
-- u.j = {"氏名": {"hobby": "...", ...}, ...}  変える人と項目だけ
update org_state s set data = jsonb_set(
  jsonb_set(s.data, '{memberOverrides}',
    (s.data->'memberOverrides') || (
      select jsonb_object_agg(k, coalesce(s.data->'memberOverrides'->k, '{}'::jsonb) || v)
      from jsonb_each(u.j) e(k, v))),
  '{canvaSync}', <下の形>)
from (select $j${...}$j$::jsonb as j) u
where s.id = 'main';
```

`university` はマージする前に「アプリ側が空か」を見ること（上の表）。

`canvaSync` の形：

```json
{
  "syncedAt": "<now()>",
  "designId": "DAG5BsKRF_I",
  "designTitle": "RVstudents_自己紹介",
  "designUpdatedAt": "<デザインの updated_at>",
  "pages": 79,
  "matched": 70,
  "updated": ["今回書き換えた人"],
  "missingInCanva": [],
  "emptyInCanva": [],
  "notInApp": [],
  "notInAppDeleted": []
}
```

書いたあとに、更新した人の `memberOverrides` で、プロフィール以外の項目
（`hoursByMonth`・`ndaSigned` など）が残っていることを確かめる。

## 報告

実行のたびに次を短く残す：書き換えた人と項目、`missingInCanva`／`notInApp` の増減、
判断に迷ってスキップしたページ。
