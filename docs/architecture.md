# 架构边界

## 平台与执行

- macOS 通过 LocalProcessBackend / SSHBackend 运行 CLI。
- iOS 不启动 CLI；通过 SkynetRelay 与 Mac 通信，离线保留发送队列。
  AppEnvironment.live 使用 NetworkSkynetRelay；未配对时不执行请求。
- SkynetMobile 共享移动端模型、配对凭据和有界 TLS RPC。Mac 的 MobileHostController
  只转发已授权项目的结构化操作；轮次 owner 由 AppModel 管理，审批由独立控制器管理。
  TLS-PSK / AES-GCM 保护传输，每个请求另校验可撤销设备令牌。会话快照按运行状态轮询，
  发送去重记录先持久化再执行；确认失败不自动重发。手机队列仅在当前界面生命周期保留。
  MobileSessionProjection 只做有界转录/元数据映射；MobileDispatchLedger 独立管理
  pending/accepted 持久化。控制器不承载转换细节，二者不接管授权或轮次状态机。
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

- AppModel：应用选择、轮次所有权、协调持久化结果和队列推进。
- SessionComposerStorage：会话级草稿/队列 JSON 与附件 blob，不发送或注册定时轮次。
- SessionPermissionController：唯一审批 continuation、owner 与代次；不取消 provider 轮次。
- SessionDiscoveryRegistry：发现身份、项目归属、历史升级与导入持久化，不扫描网络或选择 UI。
- SessionLibraryQuery：列表过滤/排序的纯投影，避免按项目反复扫描全部会话。
- ComposerImageImport：字节判格式和真正的格式转换，主 composer 与手机输入复用。
- SessionTranscriptController：缓存优先加载、分页游标和请求代次；旧请求不能覆盖新选择。
- SessionTurnExecutor：单轮准备、事件消费和子 agent 活动收尾；普通发送与定时发送
  保留不同完成/取消语义，任务所有权和成功后队列推进仍由 AppModel 控制。
- NetworkConnectivityMonitor：系统网络路径变化与定期 SSH 轻量探测，独立于历史扫描；
  不可达只更新状态/提示，不清除缓存，也不把网络可用等同于 provider 服务可用。

局部视图不接管执行生命周期；不同取消状态机不为复用而合并。
