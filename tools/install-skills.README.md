# install-skills

把 `ai-dev-kit/skills/` 下的 skill 安装到目标 agent 的发现目录，让 Claude / Codex / Cursor / Gemini 都原生 discover 这些 skill。

## 调用约定

**两个独立脚本，按平台挑：**

| 平台 | 脚本 | 实现 |
|---|---|---|
| Linux / macOS | `install-skills.sh` | POSIX `ln -s` |
| Windows | `install-skills.ps1` | `mklink /J`（directory junction，免 admin） |

```sh
# POSIX 例
./install-skills.sh claude    # → <workspace>/.claude/skills/
./install-skills.sh codex     # → <workspace>/.codex/skills/
./install-skills.sh cursor    # → <workspace>/.cursor/skills/
./install-skills.sh gemini    # → <workspace>/.gemini/skills/
./install-skills.sh all       # 四个都装
```

```powershell
# Windows 例
.\install-skills.ps1 codex
.\install-skills.ps1 all
```

**调用方（ai-dev-kit 的上层安装工具）负责按平台选脚本**。脚本本身不互相 delegate——`install-skills.sh` 在 Windows 上拒绝运行并提示用 ps1（因为 MSYS `ln -s` 会静默 fallback 到 copy，破坏源跟随语义）。脚本不面向终端用户。

## 机制

每个 skill 目录在目标位置创建一个**目录 junction / symlink** 指回 `ai-dev-kit/skills/<skill-name>/`。
源更新（升级 ai-dev-kit 后）→ junction 自动指向新内容，无需重跑。

`mklink /J` (Windows) 和 `ln -s` (POSIX) 都无需管理员权限、静默执行。

如果链接创建失败（如 FAT32 卷、跨网络盘），自动 fallback 到 `cp -r` 硬拷贝。

## 关于 `skill-creator`

`skill-creator` 与其它 skill 一样放在 `skills/skill-creator/`，由 install-skills 统一安装到所有 agent 的 discovery 目录。虽然它的 eval/benchmark 脚本依赖 `claude -p`（只在 Claude Code 下可用），SKILL.md 本身的写法指导跨 agent 通用。

## 退出码

| code | 含义 |
|---|---|
| 0 | 成功（含 fallback 到 copy） |
| 1 | 用法错误 / 源目录不存在 |
| 2 | 内部安全检查触发（target 与 source 冲突 / 空 tool 名）—— 拒绝执行避免破坏 source |
| 3 | sh 在 Windows 上被调用 —— 拒绝执行，调用方应改用 ps1 |

## 重新安装

直接重跑，目标目录被先删后建（junction 用 `rmdir`，不跟随链接）。幂等。

## 大小写

`./install-skills.sh CODEX` 等价于 `./install-skills.sh codex`（sh 和 ps1 都会自动小写规范化）。生成的目录 always 是小写 `.codex/`、`.cursor/` 等。
