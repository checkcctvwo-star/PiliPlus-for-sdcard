# Superpowers-ZH 技能规范与项目规则

本项目已安装并配置 superpowers-zh 技能框架（共 20 个 skills）。

## 核心规则

1. **收到任务时，先检查是否有匹配的 skill** — 哪怕只有 1% 的可能性也要检查。
2. **设计先于编码** — 收到功能需求时，先用 `brainstorming` skill 做需求分析。
3. **测试先于实现** — 写代码前先写测试（TDD）。
4. **验证先于完成** — 声称完成前必须运行验证命令并提供客观证据。

## 可用 Skills

所有 Skills 均位于 `.agents/skills/` 目录，每个 skill 均有独立的 `SKILL.md` 文件：

- **brainstorming**: 在任何创造性工作之前必须使用此技能——创建功能、构建组件、添加功能或修改行为。在实现之前先探索用户意图、需求和设计。
- **chinese-code-review**: 中文 review 沟通参考——话术模板、分级标注（必须修复/建议修改/仅供参考）、国内团队常见反模式应对。仅在显式调用时使用。
- **chinese-commit-conventions**: 中文 commit 与 changelog 配置参考——Conventional Commits 中文适配、commitlint/husky/commitizen 中文模板。
- **chinese-documentation**: 中文文档排版参考——中英文空格、全半角标点、术语保留、链接格式、中文文案排版指北约定。
- **chinese-git-workflow**: 国内 Git 平台配置参考——Gitee、Coding.net、极狐 GitLab、CNB 的 SSH/HTTPS/凭据/CI 接入差异与镜像同步配置。
- **dispatching-parallel-agents**: 当面对 2 个以上可以独立进行、无共享状态或顺序依赖的任务时使用。
- **executing-plans**: 当有一份书面实现计划需要在单独的会话中执行，并设有审查检查点时使用。
- **finishing-a-development-branch**: 当实现完成、所有测试通过、需要决定如何集成这份工作时使用。
- **mcp-builder**: 在构建 MCP 服务器或 MCP 工具时使用 —— 系统化的生产级 MCP 构建方法论。
- **receiving-code-review**: 收到代码审查反馈后、实施建议之前使用，尤其当反馈不明确或技术上有疑问时。
- **requesting-code-review**: 完成任务、实现重要功能或合并前使用，用于验证工作成果是否符合要求。
- **subagent-driven-development**: 当在当前会话中执行包含独立任务的实现计划时使用。
- **systematic-debugging**: 遇到任何 bug、测试失败或异常行为时使用，在提出修复方案之前执行。
- **test-driven-development**: 在实现任何功能或修复 bug 时使用，在编写实现代码之前。
- **using-git-worktrees**: 当需要开始与当前工作区隔离的功能开发，或在执行实现计划之前使用。
- **using-superpowers**: 在开始任何对话时使用——确立如何查找和使用技能。
- **verification-before-completion**: 在宣称工作完成、已修复或测试通过之前使用，必须运行验证命令并确认输出后才能声称成功。
- **workflow-runner**: 运行 agency-orchestrator YAML 工作流。
- **writing-plans**: 当有规格说明或需求用于多步骤任务时使用，在动手写代码之前。
- **writing-skills**: 当创建新技能、编辑现有技能或在部署前验证技能是否有效时使用。

## 工具适配与调用指引 (Antigravity CLI)

- **调用流程**：当任务匹配某个 skill 时，使用 `view_file` 读取对应的 `.agents/skills/<skill-name>/SKILL.md` 并遵循其流程。
- **分派子智能体**：调用 `invoke_subagent`，根据任务类型指定 `TypeName`（全能编码用 `self`，只读调研用 `research`）。
- **任务跟踪**：通过 Task Artifact（`write_to_file` 配合 `ArtifactMetadata`）进行清单管理与状态跟踪。注意 `manage_task` 仅用于后台进程管理，不作为待办任务跟踪工具。
