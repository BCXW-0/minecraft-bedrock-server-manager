# Minecraft Bedrock Server Manager

本项目统一命名为 Minecraft Bedrock Server Manager。桌面上的 Minecraft-Starter-Dev 是纯净开发区，原 Minecraft-Starter 是用户使用区。

开发区只维护四类入口：

- Update.cmd / Update.ps1：类似应用安装器或 winget。它先把开发区核心文件映射到用户区，再按需安装 Docker Desktop、BDS、FRP 和 package/ 的 Node 依赖。BDS 版本可自动选择，也可以用 -Version 1.26.51.1 指定；下载包、解压目录和安装收据全部写入用户区 .staging。使用 -SkipDependencies 可跳过 Node 依赖。
- Start.cmd / Start.ps1：启动 Docker Desktop，等待 Docker 就绪，然后启动已安装的 BDS。启动日志写入用户区的 BDS logs 目录。
- Admin.cmd / Admin.ps1：管理员维护入口。-Action Sync -Mode Preview 预览映射，-Action Sync -Mode Apply 执行映射，-Action Validate 检查开发区边界，-Action Status 查看 Docker 和运行时状态。后续管理能力在这里扩展。
- MANUAL.md：操作、配置和维护手册，随开发内容持续更新。

## 初次使用

1. 进入桌面的 Minecraft-Starter-Dev。
2. 双击 Update.cmd。脚本会在缺少 Docker 时调用 winget 安装 Docker Desktop，并在用户区下载 BDS 和 FRP。
3. 首次下载完成后，双击 Start.cmd。脚本会自动启动 Docker Desktop，然后启动 BDS。

自动版本检测失败时会回退到清单中的推荐稳定版本；也可以运行 Update.cmd -Version 1.26.51.1 -NonInteractive 指定版本。使用 Update.cmd -DryRun 可以只查看计划，不下载文件。

已有完整安装在不带 -Force 时直接复用。-Force 不覆盖或删除已有 BDS/FRP 版本目录；若需要重新安装，请先备份，再通过 -InstallRoot 指定新的空运行时目录。新目录安装不会自动迁移原世界或配置。

## 配置边界

用户专属配置位于 Minecraft-Starter\\.minecraft-manager\\config.json，开发区不保存 SSH 私钥、FRP token 或其他凭据。需要配置远程中转时，只在用户区配置文件中填写，并保持该文件不进入 Git。

## 开发和映射

开发时只编辑 Minecraft-Starter-Dev。Admin.ps1 维护允许同步的根文件和源码目录：deploy/、package/、TrueIPGetter-Release/。它按 SHA-256 校验复制结果，不删除用户区文件，因此世界、日志、下载包、BDS 二进制和依赖始终留在用户区。

旧中文入口和旧手册保存在用户区 .legacy-user-archive-20261014/；开发区旧文件保存在用户区 .legacy-dev-archive-20261014/，可作为回滚参考。

## 验证

PowerShell 验证命令：

    ./Admin.ps1 -Action Validate
    ./Admin.ps1 -Action Sync -Mode Preview
    ./Start.ps1 -ValidateOnly

Start -ValidateOnly 只检查 BDS 文件、配置文件和 Docker CLI 是否存在，不启动 Docker/BDS，也不验证 Docker 引擎是否已经就绪。

GitHub 关联仓库为 BCXW-0/minecraft-bedrock-server-manager。本地提交应使用已授权的 GitHub 身份；当前机器未登录 GitHub 时，不进行伪造作者或推送。
