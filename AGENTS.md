# AGENTS.md — 项目约定与工作流记忆

## GitHub 协作工作流（本仓库）

### 仓库拓扑
- `origin` = https://github.com/zhangsuozhu/newbee.git （主仓库，有写权限，admin=true）
- `liqian2026` = https://github.com/liqian2026/newbee.git （fork，**只读**：pull=true, push=false，推不上去，不用管）
- 本地凭证在 git credential store（用户名 zhangsuozhu），不落盘明文

### main 分支保护规则（origin）
- `required_approving_review_count = 1`：合并 PR 需要 1 个 approve
- `required_linear_history = true`：线性历史；仓库禁 merge commit（405），实际 merge 用 **squash**
- `enforce_admins = true`：admin 也不能绕过
- `required_conversation_resolution = true`
- `allow_force_pushes = false` / `allow_deletions = false`

### 死锁与解法（重要！单人维护必然会撞上）
**GitHub 硬规则：PR 作者不能 approve 自己的 PR**（API 返回 422 "Review Can not approve your own pull request"）。
当只有 zhangsuozhu 一个写权限账号时，PR 会卡在 `mergeable_state: "blocked"`（要求 1 approve 但无人能 approve）。

标准解法（已验证，PR #1 走通）：
1. PUT `/repos/zhangsuozhu/newbee/branches/main/protection`
   body 中 `required_pull_request_reviews.required_approving_review_count = 0`，
   其余字段保持原值（enforce_admins=true, required_linear_history=true, dismiss_stale_reviews=true, required_conversation_resolution=true, allow_force_pushes=false, allow_deletions=false)
2. 确认 PR `mergeable_state == "clean"` 后：
   PUT `/repos/zhangsuozhu/newbee/pulls/<n>/merge` body `{"merge_method":"squash"}`
   - 实测（PR #1/#2 都验证）：仓库禁 merge commit（405 "Merge commits are not allowed"）；
     多分支共用旧 commit 时 rebase 会失败（"can't be rebased"，因 head 含 base 已在 main 的 sha）；
     **squash 最稳**——净变更合成 1 个 commit，不与远端历史冲突
3. **务必立刻恢复**：再 PUT 一次 protection，把 review count 改回 1
   （保护机制是安全基线，恢复后才能防住未来误推）
4. 合并后 main 即更新，本地 `git pull` 拉取（远端 sha 可能与本地不同——squash/rebase 重写历史，属正常）

替代方案（未采用）：加第二个协作者账号用于 approve；或直接改规则长期为 0。

### 发布流程（push → PR）
1. `git push origin HEAD:feature-branch`（main 保护，直推必被拒）
2. API 创建 PR：POST `/repos/zhangsuozhu/newbee/pulls`
   `{title, head: feature-branch, base: "main", body}`
3. 按上面死锁解法合并

## 敏感数据红线
- `.gitignore` 已含 `/.newbee/` —— `~/.newbee/web/{cert,key}.pem`（HTTPS 私钥）、`auth.json`（登录 token）都在忽略区，**永不入 git**
- 提交前检查：`git ls-files | grep -iE 'auth\.json|cert\.pem|key\.pem'` 应为空
- diff 中不得出现密码/密钥/token 字面量（用占位符或从 credential store 取）
- git credential fill 可安全取凭证（只印长度/字段名，不打印值）

## WebUI 安全（HTTPS + 登录）
- `mix newbee web --https --host 0.0.0.0 --set-password` = 远程安全访问
- 本地回环免认证；远程强制 Bearer token（`auth.login` 拿 token，验证码防暴破）
- HTTPS 自签 RSA 2048 证书，首启自动生成于 `~/.newbee/web/`，私钥 chmod 600
- 浏览器首访自签证书有警告；要绿锁用 `--certfile/--keyfile` 挂 CA 证书或反代
