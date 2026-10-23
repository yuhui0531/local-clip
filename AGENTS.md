# Working instructions

- Reply in Chinese. Do not send optional commentary.
- Follow `/Users/ronny/.codex/RTK.md` for shell commands.
- By default, run only tests without desktop side effects. After a change, use
  `rtk proxy bash macos-app/scripts/test.sh --filter <relevant-suite>` for focused
  validation. Run the full quiet suite for shared infrastructure changes or before release.
- Popup/window tests and desktop interaction (including app activation, opening
  System Settings, real target-app paste/drag, or launching the installed app)
  require an explicit user request. A general request to implement, test, review,
  or release does not authorize these actions.
- Never set `LOCALCLIP_INTERACTIVE_TESTS=1` without that explicit request.
  Interactive tests require this flag in addition to any existing specialist flags;
  `--filter` alone must not enable them. Keep new desktop tests gated the same way.
- Pure calculations, temporary databases, fake system clients, private pasteboards,
  and windows that stay hidden can run by default. Report skipped interactive
  coverage separately from passing tests. Do not change production Accessibility
  behavior to make tests quiet.

## Agent skills

### Issue tracker

Issue 以本地 Markdown 形式放在 `.scratch/<feature>/` 下。See `docs/agents/issue-tracker.md`.

### Triage labels

使用默认五个角色标签（needs-triage / needs-info / ready-for-agent / ready-for-human / wontfix），记录为 issue 文件里的 `Status:` 行。See `docs/agents/triage-labels.md`.

### Domain docs

single-context：根目录 `GLOSSARY.md` + `docs/adr/`。See `docs/agents/domain.md`.
