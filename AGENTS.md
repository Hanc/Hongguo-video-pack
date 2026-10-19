# Skill Tail (MUST EXECUTE - Every Response)
CRITICAL: At the END of EVERY response, you MUST:

1. Check if you used ANY skills from the available_skills list in this response
2. If skills were used, add this footer FIRST, THEN run the command:
   ```
   ---
   Skills Used: `skill-name1`, `skill-name2`
   ```
3. Run: `npx skill-tail record skill-name1 skill-name2`

If NO skills were used, do nothing.

User commands:
- "show skill stats" -> run `npx skill-tail report`
- "skill stats today" -> run `npx skill-tail report --today`
- "skill stats this week" -> run `npx skill-tail report --week`

# Skill Priority Rules (MUST FOLLOW)

When performing tasks in these domains, you MUST invoke the corresponding skill FIRST:

- **Vue.js tasks** (writing/editing .vue files, Vue components, Vue projects) -> MUST use `vue-best-practices` skill
- **Vite tasks** (vite config, build setup, Vite plugins) -> MUST use `vite` skill
- **UnoCSS tasks** (utility CSS, UnoCSS config) -> MUST use `unocss` skill
- **Pinia tasks** (state management, store files) -> MUST use `pinia-best-practices` skill
- **Vue Router tasks** (routing, navigation guards) -> MUST use `vue-router-best-practices` skill
- **VueUse tasks** (composables, VueUse integration) -> MUST use `vueuse-best-practices` skill
- **Nuxt tasks** (Nuxt framework, SSR, server routes) -> MUST use `nuxt` skill
- **Web UI review** (accessibility, design audit) -> MUST use `web-design-guidelines` skill
These skills contain domain-specific best practices that MUST be followed.

# Windows shell

- Use PowerShell 7 for Windows command execution: invoke `pwsh.exe -NoLogo -NoProfile -Command` rather than `powershell.exe`.
- Use Windows PowerShell 5.1 only when a task explicitly requires legacy Windows PowerShell compatibility.

# GitHub authentication

- For GitHub operations, prefer the authenticated GitHub CLI (`gh`) for GitHub API requests, Actions and workflow status, releases, pull requests, issues, and other GitHub-hosted metadata.
- Do not use anonymous GitHub REST API polling when `gh` can perform the operation. If `gh` is unavailable or not authenticated, report that clearly and ask the user to run `gh auth login` instead of falling back to repeated anonymous requests.
- Plain Git transport commands such as `git fetch`, `git pull`, and `git push` may continue to use the repository's configured Git credential helper.

# 项目规格入口

- 来源 API 文档总入口：`.agents/api/README.md`（网页、App 核心、其他抓包与参考程序，含验证状态）。

- 实施前必须阅读 `.agents/notes/active/` 与 `.agents/notes/prohibited/` 的相关文件。
- 项目整体契约：`.agents/notes/active/hongguo-studio.md`。
- 搜索与来源适配：`.agents/notes/active/search-and-source-integration.md`。
- 禁止重复的搜索方案：`.agents/notes/prohibited/search-fallbacks.md`。
- Windows 独立运行约束：`.agents/notes/prohibited/windows-jvm-dependency.md`。
- `proposed/` 只放未批准提案，不能当作实施要求；验收通过后才把对应规格移入 `implemented/`；被替代且仍需查阅的规格放入 `superseded/`。
- 产品要求和模块契约由规格维护；本文件保留跨任务规则与导航，不写聊天记录、任务队列或临时执行状态。
- 本项目是 Flutter / Dart。Vue、Vite 等技能优先级只在实际涉及对应技术时适用，不能凭关键词强行套用。
- `.local/` 内有发布签名材料；禁止整目录清理。不得把密钥、账号、签名请求、设备标识和原始抓包记录放进交付或源码包。
- 不得把“已安装”“ADB 已连通”“能看见 TLS 连接”表述为“已成功解密或接通搜索分页”。
