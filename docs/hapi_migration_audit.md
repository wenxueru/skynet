# Hapi → Skynet 迁移范围

范围是 macOS 工作区与配对 Mac 的 iOS 客户端，不以完整复制 Hapi 为验收条件。
功能需在实际 provider 与运行环境验证，不能以入口存在作为完成依据。

- 保留发送队列、排序、Steer 和 App 运行期间的定时发送；不提供独立 Scratchlist。
- 不恢复 Share text、Copy message ID 等用户已取消的消息功能。
- iOS 通过加密 relay 操作已授权项目；执行和权限策略留在 Mac，实体设备验收另列。
- 外部 CLI 接管、常驻 Hub、云中继和后台移动推送不在当前实现范围。
- Codex/Claude/provider 的能力不同，不用 UI 入口代替真实能力与验证。
- 删除会话先删除 provider 数据，成功后移除本地记录；失败保留本地记录。
  移除项目只清理 Skynet 项目与缓存，不删除仓库或 provider 原始会话。
- 验证后的 App 直接替换并重启，不备份旧版。

历史迁移清单与 QA 记录仅在本地保留，不进入 Git。
