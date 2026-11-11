# 云吞插件：Stirling-PDF

开发流程见[插件开发指南](https://github.com/wontonapp/wonton-docs/blob/main/develop.md)。

这个仓库把 [Stirling-PDF](https://stirling.com)（主体 MIT，`app/proprietary/`、`engine/` 等目录另有许可，见 [NOTICE](NOTICE)）
做成插件：60 多个 PDF 工具（合并、拆分、压缩、转换、OCR、签名、水印等），全部在本机处理，简体中文 OCR 开箱即用。应用自己的
登录系统整个关掉，网页始终在核心网关的登录后面，打开就能用；上游的匿名统计（PostHog/Scarf）已关闭。应用发的信（签名邀请、
把文件发到邮箱）会出现在收件人的「Wonton」私聊里，收件人限家里人，发外部邮箱会失败。文件只在处理时经过插件，不挂共享文件夹，
也不申请出网。

## 图标来源与许可

`icon.svg` 用 Stirling-PDF 官方标志，未改路径和颜色，仅加同色方底消除圆角透明；来源、版权、处理方式、上游许可结构和商标说明见 [NOTICE](NOTICE)。

## 先跑起来

```bash
scripts/dev.sh up
scripts/dev.sh install
```

`up` 在本机起一套云吞，打印它的地址，浏览器打开后用 `scripts/dev.sh token` 输出的用户令牌登录；`install` 先列出插件要的
权限，确认后装上，打印插件网页的地址。Chrome、Firefox 和 curl 把 `*.localhost` 直接解析到本机，不用改 hosts。

## 仓库里有什么

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 插件本身：compose 加上 `x-wonton` 清单 |
| `icon.svg` | 清单引用的图标 |
| `screenshots/` | 商店详情页里的截图 |
| `scripts/check.sh` | 检查插件包，规则和安装时一样 |
| `scripts/dev.sh` | 开发环境：起一套云吞，装、重装、卸载插件，看日志 |
| `scripts/smoke-probes.sh` | `scripts/dev.sh smoke` 对这个插件逐项的探测 |
| `scripts/publish.sh` | 发布一个版本：打 tag、推送；`images/` 里有自己构建的镜像时先构建、推送并按摘要写回 |
| `AGENTS.md` | 给人和 AI 编程代理的规则 |
| `LICENSE` | 插件包自己的许可证 |
| `NOTICE` | 图标等第三方素材的许可和声明 |
| `.wonton/` | 开发环境的设置、密钥和数据，不提交 |
