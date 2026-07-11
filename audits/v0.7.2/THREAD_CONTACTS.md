# Audit Thread Contacts

## Commander

- Thread: `019f3276-2f5e-7ac2-81b3-9a8f311610a3`
- Role: schedule work, inspect diffs and focused verification, route independent review, and accept or reject results.

## Active Owners

| Thread | Ownership | Mode |
|---|---|---|
| `019f5082-b47f-7761-881c-5afb36da1e32` | Tauri source-binding repair | implementation |
| `019f507e-656b-7363-9876-6325703e2717` | Tauri source/status-tray audit | independent review |
| `019f5082-b8f6-7b30-87b1-66155797b03e` | Windows release atomic-boundary repair | implementation |
| `019f507e-68ba-7002-9d0f-72d413f6fe82` | Windows release independent review | independent review |
| `019f508c-f57c-7822-beea-82e917ece841` | Tauri tray status-panel reachability and positioning | implementation |
| `019f508e-b0df-7b83-97b6-59583adea93a` | Swift residual-finding reconciliation | independent review |
| `019f5092-79b4-76c3-bd26-e43ae68cfeef` | Swift chart gesture-to-navigation state repair | implementation |
| `019f5155-379a-7832-8e47-481462931988` | Swift status-only background CPU repair | implementation |

## Completion Callback

When a task reaches a real handoff point, call `codex_app__send_message_to_thread` for the Commander thread above. Send one compact message containing:

- `status`: completed, blocked, or review-ready;
- exact commit or uncommitted state;
- changed ownership scope;
- focused verification results;
- remaining risk or requested decision.

Do not send progress pings for ordinary work. The Commander reads a task manually only after a callback, an error, or an abnormal delay. Reviewers must callback independently after inspecting the exact implementation commit.

## Runtime Handoff Gate

- Before building a new App for manual/runtime verification, close the previous running instance owned by that platform lane.
- After the build, open only the new App and verify by full executable path that at most one Swift instance and one Tauri instance are running.
- Swift tasks may manage only the Swift App; Tauri tasks may manage only the Tauri App. Never stop, open, or replace the other lane's runtime.
