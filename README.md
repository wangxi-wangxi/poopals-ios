# 噗噗搭子 · 0.2

SwiftUI 每日记录应用，以及可部署的账号与日历同步 API。

## 使用流程

游客直接打卡 → 本机日历 → 主动开启云备份 → Apple / 微信授权 → 确认导入 → 按账号同步。

- 本机打卡、角色选择、日历、提醒、JSON 导出。
- 后置登录、账号独立缓存、游客导入、版本冲突确认、退出与注销。
- 后端 FastAPI + SQLite，提供 Dockerfile；多实例部署前迁移数据库。
- 默认未配置云服务。真实登录与同步需要 HTTPS 后端和渠道资质。
- 微信 SDK 适配为条件编译，官方 SDK 尚未集成，相关分支尚未编译与真机验证。
- 双人邀请、共享日历、APNs 当前仅有设计与数据契约。

## 构建与测试

GitHub Actions 执行后端测试、记录/合并/账号隔离测试、iOS 编译与模拟器启动截图。Codemagic 提供 `ios-simulator` 工作流。

模拟器 `.app` 不是可安装到 iPhone 的签名 IPA。Apple / 微信真实授权、TestFlight 和上架尚未验收。

后端接入说明：`backend/部署与接入.txt`。
产品流程：`Release/产品流程与数据说明.txt`。
交付边界：`Release/0.2交付状态.txt`。

[账号与同步设计稿](https://www.figma.com/design/n1hRBGM7i5CEI1FfyOcb6G?node-id=86-138)
