# 架构边界

## 平台与执行

- macOS 通过 LocalProcessBackend / SSHBackend 运行 CLI。
- iOS 不启动 CLI；通过 SkynetRelay 与 Mac 通信，离线保留发送队列。
  默认未配对；生产部署需在 AppEnvironment.live() 注入认证 relay transport。
- provider 协议与执行地点独立。Codex、Claude 各有适配器；自定义 executable
  通过配置使用 Claude-Code-compatible 协议，不为每个品牌增加适配层。
- AgentSession 拥有一次会话的执行、事件归一化和转录持久化。

## Codex 职责

| 类型 | 职责 |
| --- | --- |
| CodexThreadArchive / Name / Delete / Fork | 线程操作；Archive/Delete 处理失败后的原生状态核对 |
| CodexModelDiscovery | 模型目录解码与分页 |
| CodexAppServerRPC | 共享一次性 RPC、顺序握手、取消、超时及有界脱敏诊断 |
| CodexAdapter / CodexAppServerBridge | 分别处理 exec / app-server 协议；Bridge 提供 JSONL 编码 |
| CodexEventParsing | 共享纯解析：usage、工具输出和子 agent 状态，不启动进程或写持久化 |
| CodexSideConversation | 独立临时连接、待响应请求与代次保护；不修改主会话 |

目录查询与线程操作共用 RPC，不互相依赖。主轮次、一次性 RPC 和 Side chat
只共享稳定协议规则，不合并不同的生命周期、所有权或取消状态机。

## macOS 会话界面

- SessionDetailView：标题、工具面板、审批呈现和页面组装。
- SessionComposerView：草稿保存/恢复、补全、附件、模型控制和提交队列入口。
  内容插槽保留模型浮层对整个会话的覆盖，不重建会话级组件来切换草稿。
- SessionTranscriptView：历史渲染、分页、可见锚点、目录跳转和跟随最新消息。
  引用通过回调交给输入框，不读取编辑器状态。
- ComposerCatalog：补全上下文和目录解析；回归直接编译实际文件。
- ProviderModelDiscovery：主输入框与 Side chat 共用目录查询，不依赖会话视图。

## 应用协调

- AppModel：选择、持久化入口、队列推进和审批所有权。
- SessionTranscriptController：缓存优先加载、分页游标和请求代次；旧请求不能覆盖新选择。
- SessionTurnExecutor：单轮准备、事件消费和子 agent 活动收尾；普通发送与定时发送
  保留不同完成/取消语义，任务所有权和成功后队列推进仍由 AppModel 控制。
- NetworkConnectivityMonitor：系统网络路径变化与定期 SSH 轻量探测，独立于历史扫描；
  不可达只更新状态/提示，不清除缓存，也不把网络可用等同于 provider 服务可用。

局部视图不接管执行生命周期；不同取消状态机不为复用而合并。
