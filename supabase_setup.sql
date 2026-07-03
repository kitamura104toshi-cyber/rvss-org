-- RVSS 組織管理アプリ用テーブル
-- 既存のFirestore構造（org/main ドキュメント1件に全データをJSONで保持）をそのまま踏襲

create table if not exists org_state (
  id text primary key,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

-- Realtime（他端末への即時反映）を有効化
alter publication supabase_realtime add table org_state;

-- RLS有効化
alter table org_state enable row level security;

-- 既存のFirebase版と同じ信頼モデル（閲覧・編集はURLの?keyパラメータのみで
-- クライアント側制御。サーバー側の読み書き制限はなし）を踏襲
create policy "org_state_select_anon" on org_state
  for select using (true);

create policy "org_state_insert_anon" on org_state
  for insert with check (true);

create policy "org_state_update_anon" on org_state
  for update using (true);
