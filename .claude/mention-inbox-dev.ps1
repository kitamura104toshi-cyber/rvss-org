$env:PATH += ";C:\Program Files\nodejs"
Set-Location "C:\Users\mr171\claude\アプリ\連絡・タスク整理アプリ"
# 環境変数は .env.local から自動読込されるため、ここでは設定しない
npx next dev -p 3100
