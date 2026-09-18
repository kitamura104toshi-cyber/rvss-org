# SDD ledger — plan: docs/superpowers/plans/2026-09-18-three-view-roles.md

Spec: docs/superpowers/specs/2026-09-18-three-view-roles-design.md (read)
Branch: feature/three-view-roles (merge-base 673e08d)

Ruling: implement on a feature branch in the primary working directory rather than a
git worktree — the preview server (.claude/launch.json, port 5173) and the dev/prod
Supabase switch are bound to the primary working directory, so a worktree would break
browser verification. Cost if wrong: an extra merge step at the end; no data risk.

## Pre-flight scan

### Cross-task pairs (shared files / interfaces)

| Pair | Produces → Consumes | Finding |
|---|---|---|
| T1 → T2 | `ROLE`, `roleAtLeast`, `isEditMode` → guard block | Clean. Guard runs at end of script, after the const is initialised. |
| T1 → T4 | `roleAtLeast` → `recruitStatusControlHTML` | Clean. |
| T1 → T5 | `roleAtLeast` → applicant/detail gating | Clean. |
| T2 → T4 | `CORE_FNS` names listed before T4 defines the functions | Clean. Guard tests `typeof window[fn] === "function"`, so unknown names are skipped. |
| T3 → T5 | `row.summary/role/wanted/gains/feedback/workload/owner/note/studentNames/studentEmails` | Clean. T5 treats studentNames/studentEmails as arrays, T3 produces arrays. |
| T4 → T5 | `e.key`, `resolveRecruitStatus`, insertion point after `recruitOverrideNoteHTML` | Clean. |
| T1/T2/T4/T5 all modify index.html | sequential dispatch only | Clean — no parallel implementers. |
| T3 → T6, T1-T5 → T6 | deploy + verify | Clean. |

### Per-task self-consistency

| Task | Finding |
|---|---|
| T1 | Clean. `roleAtLeast` is a function declaration (hoisted); `ROLE` is defined ~line 669, `currentTab` ~line 862. Tab reorder does not affect `renderContent()`'s dispatch. |
| T2 | Clean. `ADMIN_FNS` list is byte-identical to the existing `EDIT_FNS` list. |
| T3 | Clean. All added columns are optional; only `事業名` stays required. |
| T4 | **Finding: attribute quoting.** The plan embeds `'${escapeHtml(e.key)}'` inside double-quoted `onchange`/`onclick` attributes. `escapeHtml` maps `'` → `&#39;`, which the browser decodes back to `'` inside the attribute, breaking the JS string if a key contains an apostrophe. `normalizeProjectKey` maps `’` → `'`, so such a key is reachable. |
| T5 | Same attribute-quoting finding for `e.key` and for member names in `goToMemberCard`. `buildMemberMap()` is called per card; n is small, acceptable. |
| T6 | Clean. |

Ruling: add a helper next to `escapeHtml` and use it for every JS argument embedded in an
HTML attribute in Tasks 4 and 5, replacing `'${escapeHtml(x)}'` with `${jsArg(x)}`:

```js
// 属性内に JS の引数として埋め込む。キーや名前に ' や " が含まれても壊れない。
function jsArg(s) { return escapeHtml(JSON.stringify(String(s))); }
```

`JSON.stringify` supplies the quotes; `escapeHtml` then makes them attribute-safe, and the
browser decodes them back to valid JS. Cost if wrong: none — it is strictly safer than the
plan's literal quoting, and the plan's own text is what would break.

Ruling: `buildMemberMap()` stays inside `recruitApplicantsHTML` rather than being hoisted.
Cost if wrong: a few extra map builds per render on a page with ~10 cards; negligible.

## Progress

Task 1: reviewer raised 2 "cannot verify from diff" items (browser run, dev-DB wiring). I reproduced both myself on localhost:5173: SUPABASE_URL=vsqrgcsobwea (dev), member role=2 tabs/badge hidden/setTab("projects")->"all", core=6 tabs/"コアメンバー", admin=6 tabs/"管理者モード"/isEditMode=true/105 editor-only nodes, 0 console errors. Both items resolved, not gaps.
Task 1: minor (deferred): admin/core badge now explicitly sets style.display="" (inherited from the brief snippet, not an implementer choice).
Task 1: minor (deferred): setTab() invalid-id fallback lands on "all" for every role, while the initial currentTab for core/admin is "projects".
Task 1: complete (commits 673e08d..aee9325, review clean)
Task 2: reviewer raised 2 "cannot verify" items. I reproduced both: GitHub main still at f355b85 and the feature branch has no remote ref (nothing pushed); core role has addProject/toggleNdaSigned replaced by the no-op and the 3 CORE_FNS still undefined, admin has them intact. Also diffed the name lists directly (git show aee9325:index.html EDIT_FNS vs current ADMIN_FNS): 47 vs 47, IDENTICAL. Reviewer said "31 names" — miscount, harmless; the sets match.
Task 2: complete (commits aee9325..403b431, review clean)
Ruling: move Task 3 Step 7 (deploying the changed sheets-recruitment-sync to PRODUCTION) out of Task 3 and into Task 6, alongside the front-end release. Shipping a changed prod sync before the UI that consumes it gains nothing and puts prod recruitment data behind an unverified function. Task 3 is now dev-only. Cost if wrong: none — the same deploy happens, just later and next to the code that needs it.
Ruling: the production Edge Function deploy and the git push stay in the controller session, not a subagent. They are side effects outside this branch. Cost if wrong: none.
Task 3: reviewer confirmed deployed dev source == recruitment-sync.ts byte-for-byte (all 11 Japanese header candidates intact, no mojibake), prod still version 1 with the old 4-field col object, new columns all optional, full-width space preserved in 柴田　頼視.
Ruling: the reviewer's Important finding (Lアカデミア row has the project name in `wanted` and mentor text in `feedback`) is NOT a code defect. I read the raw form sheet earlier this session: that row's columns are shifted at the source. It is already recorded in the spec under 既知の問題. No fix here; surface it to the user instead. Cost if wrong: the app renders one messy card until the sheet is corrected.
Ruling: AX＋ returning studentNames [] is correct behaviour, not a regression. The sheet holds two AX＋ submissions and the pre-existing latest-timestamp dedup picks the 7/13 one, whose applicant cell is empty and whose status is 応募待ち. Out of scope to change. Cost if wrong: an applicant recorded on a superseded submission is not shown; surface to the user.
Task 3: minor (deferred): a read-only diagnostic function `debug-sheet-dump` is left deployed on DEV only (absent from prod). No delete_edge_function tool is available in this environment; needs manual removal from the Supabase dashboard.
Task 3: minor (deferred): pickList multi-name splitting is untested against live data — no current sheet row has more than one applicant name.
Task 3: complete (commit 725cb57, dev-only; review clean)
Task 4: reviewer raised the live-browser item as unverifiable. I reproduced the whole round trip myself on dev: as core, set REAL VALUE CONFERENCE 2026 to PJ連携中 (sheet value 応募待ち), ran the real sync (request 369, 200, ok:true, 7 rows) and the override was still PJ連携中 in the DB while the sheet row stayed 応募待ち; after reload it resolved to PJ連携中; clearRecruitOverride restored 応募待ち and left recruitOverrides {}. As member: 0 .recruit-select nodes and all three mutators no-op. This is the plan's central behaviour and it holds.
Ruling: accept the implementer's out-of-brief fix to pushToSupabase() (gate widened from admin-only to roleAtLeast("core")). Without it the core role could set an override but never persist it — a genuine gap in my spec, which said core may edit but never said how the edit is saved. The reviewer enumerated all 45 save() call sites and confirmed every other save-triggering function is in ADMIN_FNS and no-opped for core, so core can still only persist recruitOverrides through the UI. Real security posture is unchanged: the spec already records that anon holds full UPDATE on org_state regardless of role. Cost if wrong: a core user who opens devtools can write the whole state blob — which they could already do with the anon key directly.
Task 4: minor (deferred): setRecruitOverrideField (the shared helper) is not in CORE_FNS; unreachable today, but a future refactor calling it directly would bypass the role gate.
Task 4: minor (deferred): the jsArg apostrophe path is verified by inspection only — no current project key contains an apostrophe.
Task 4: minor (deferred): commit 95e7ccc carries "Co-Authored-By: Claude Sonnet 5" (the subagent's own model) instead of the session attribution line. Not worth rewriting history.
Task 4: complete (commits 725cb57..95e7ccc, review clean)
Task 5: reviewer flagged screenshots and the one-applicant data limit as unverifiable. I reproduced the privacy check myself as member on dev, in BOTH views and with every detail block force-opened via openRecruitKeys: nameLeaks [] and emailLeaks [] against the real values (柴田　頼視 / chaitianlaishi717@gmail.com), 0 .recruit-select, 6 briefs still readable. As core: applicant chip renders as a goToMemberCard link despite the full-width space, the email stays hidden until the detail is opened, two cards stay open independently, 15 selects. Screenshot checked — layout clean.
Task 5: complete (commits 95e7ccc..19bcd29, review clean)

## Final whole-branch review (opus)

Verdict: NOT ready to merge. I confirmed the three blocking findings in the source myself:
- #1 Critical: state = load() falls back to the baked-in INITIAL; the cloud fetch is async and returns early on error; pushToSupabase() has no "cloud loaded" guard. Pre-branch only admin could push, so the blast radius was one person; Task 4 handed the same window to every core member on the exact control they are told to use.
- #2 Critical: exportJSON() (index.html:840) serialises the whole state including recruitment.rows, and its button (index.html:353) carries no role class. A member can download every applicant name and email. Task 5 Step 4 only scanned #content.innerHTML so it could not catch this. This is the code failing the boundary the spec claims, not the accepted "keys are readable" caveat.
- #5 Medium: renderRecruitCardProgress renders recruitStatusControlHTML twice when recruitStepIndex < 0 (most prod cards) — once in body, once in the infoRow. My plan specified both; my defect.
Ruling: fix #1, #2, #5 and #6 in one fix wave. #3 (applyRemote replaces rather than merges, so concurrent edits can be lost) is pre-existing and architectural — out of scope for this branch, surface to the user instead. #7 (six free-text sheet columns now public) and #8 (lineStatus synced but never rendered) stay deferred. Cost if wrong: #3 remains a live risk for concurrent editing.
Ruling: on #6 (card re-sorts out from under the user when a status is picked) keep sorting on the RESOLVED status — that is the correct semantics and what the user asked for ("常に募集中と再募集中が上位に来るように"). Mitigate only by preserving scroll position across the re-render. Cost if wrong: the card still moves after a change, which is arguably the right feedback.
Ruling: follow the reviewer on sequencing — deploy the prod Edge Function and run one manual sync BEFORE pushing index.html, so no one sees empty 募集要項 toggles. Cost if wrong: none.

## Task 6 (release)

Observation: prod paidGroups changed from 28 to 27 during this session (updated_at 2026-09-18 06:22 UTC) — 萬年歩乃伽 and ニコルズ瑠玖 removed, 池田和喜 added, 結城竜惺 moved from 移行期 to 専任. This is the user editing the live app, not corruption. Left untouched. Surface to the user so they know I saw it and did not change it.
Fresh prod backup taken before any release action: sheets-backup request 378, 200, ok:true, assignRows 64 — a full state snapshot is now in the 生データ履歴 sheet.
Ruling: amend the earlier "prod actions stay with the controller" ruling. The prod Edge Function deploy is delegated to a transcription-only subagent (read this exact local file, deploy verbatim, change nothing), because the escaped payload is 21KB and my own retyping of it is the larger risk. A SEPARATE read-only agent then diffs the deployed prod source against the local file, so the deploy is verified by something other than the thing that performed it. The judgment stayed with me; only the typing moved. Cost if wrong: a bad deploy of the sync function, caught by the independent diff before the front-end ships.
Dev reference: sheets-recruitment-sync v7, ezbr_sha256 b165c9ccef0445238e6df23dfc3efaf29d852331c770645a9ac08a79293c2647.
Task 6: PROD verified on https://rvss-org-zeta.vercel.app after merge 63a1a59. member = 2 tabs, 7 briefs readable, 0 name/email leaks with every detail force-opened, 0 selects. core = 6 tabs, コアメンバー badge, applicant chip shown, 15 selects, addProject no-op. admin = 6 tabs, 管理者モード, 112 editor-only nodes. cloudLoaded true on all three. Data intact: 71 members / 15 projects / 27 paid. Console clean.
Task 6: complete (merge 63a1a59 pushed to GitHub main; prod Edge Function version 2 verified identical to the reviewed source)
