# 红果取流验证记录

验证日期：2026-10-16（Asia/Shanghai）。

## 已实际验证

- 剧集：《持械入宋：第一季》，series_id `7671966197985856536`。
- 第一集 item/video ID：`7671977925326949400`。
- MiniReel 本地详情记录、官网和 App 详情返回的是同一组 ID。
- 旧 `video_model/v1` 加原参考仓库的简化签名：HTTP 200 空响应。
- 仅替换成 `multi_video_model/v1` 或只替换设备 ID：仍失败。
- 官网 `protected/play-info` 返回受保护的分离音视频，720P；1080P 请求被拒绝。
- 批量接口使用完整签名、正确请求体和当前版本参数后：HTTP 200，业务 Code 0。
- 用独立随机生成的访客设备标识复测同样成功；未使用 MiniReel 账号或登录凭证。
- fallback_api 的 video_list 返回 360、480、576、720、1080 档位。这次较低档标记为 bytevc2；不能视为已经验证可播放。
- 1080 档位的 bytevc1 实际媒体编码为 HEVC；第一集已完整导出 MP4，1080×1920、135.650998 秒、AAC 音频、11,085,046 字节。
- 对导出文件完整解码视频和音频成功，不只是读取 metadata 或观察播放器画质标注。

## 成功请求的结构

`POST /novel/player/multi_video_model/v1/`

请求使用 `mixed_video_id_map: {"1004": [videoId]}`，以及 `biz_param` 中的 `need_all_video_definition: true`、`video_platform: 1024` 等参数。

签名验证参考完整的 x-gorgon、x-helios、x-medusa 及相关请求头实现；当前应用里的简化签名不足以复现这条链路。参数需与版本和签名保持一致，不能只改 URL。

返回的 `data[videoId].video_model` 中读取 fallback_api，再读取其 `video_info.data.video_list`。资源地址需按 key_seed 解析，内容授权数据和编码兼容性也必须正确处理。只拿到 URL 不代表文件可以播放。

## 研究来源与代码边界

- 最初参考：digitalPartty/guoguo-juku。
- MiniReel 的已安装公开配置和程序中的接口字符串，用于定位差异；没有修改、注入或替换该进程。
- 补充参考：https://github.com/seanminjie-del/hongguoTV-livingroom ，提交 `76eeaa9b964359fe6ed3f4a2b6f79ffb11f35761`，`server/vendor/hongguo.cjs` 和 Kotlin core 中的取流、签名实现。
- 补充参考中算法源自 drpys，标注 GPL-3.0。完整签名与媒体适配现已并入正式应用，并保留来源、许可和 notices，见 `THIRD_PARTY_NOTICES.md`。原型与包含签名 / 临时地址的诊断记录仍留在被 Git 忽略的 `.local` 中，不随交付分发。

## 当前应用状态

Flutter Windows/Android 工程已初始化。Windows 构建及原生视频引擎生成、拼接、探测已验证。跨桌面/手机布局和分集选择已有测试。

新取流链路现已接入共享任务流程。Windows 打包程序完成前两集 1080P 下载、合并与完整解码；Android 完成正式签名 APK 构建以及原生签名联网测试。设备级安装、文件选择和后台行为尚待真机验收。当前记录与交付范围以 docs/acceptance.md 为准。

诊断文件位于 `.local/proof/`，签名响应、临时媒体地址和设备标识均不纳入 Git。

## 2026-10-19 搜索与后页验证

- PCAPdroid 对红果的 HTTPS 明文已验证可读。用户安装的 CA 为 DER，放入 Android 9 系统证书目录前须转换为 PEM；只验证文件存在不代表信任已加载。雷电只读系统镜像采用临时 bind mount，重启或撤销挂载即可恢复。
- 官方实际请求为 `GET https://api5-normal-sinfonlinec.fqnovel.com/reading/bookapi/search/tab/v`。关键词使用 UTF-8 百分号编码；Windows 终端错误解码曾造成误判。
- “重生”首批响应 `code=0 / SUCCESS`，从 `search_tabs` 选择 `tab_type=11`。综合页混合正式剧集、UGC 合集与排名容器，不能把所有卡片都当作可播放剧集。
- 已实测后页携带服务端返回的 `offset=6`、`passback` 和同一 `search_id`；返回 9 个正式剧集，与首批无 ID 重合，下一 `next_offset=16`。这些游标是会话数据，不可写成固定请求参数。
- 自研 JavaScript 签名生成的新请求，在已注册的本机访客身份下可以无 Cookie、无登录授权、无捕获 SDK 临时参数独立搜索。随机替换 `device_id` 或 `iid` 均仍得到 HTTP 200 空正文；省略或置零得到非零业务码。取流的随机身份策略不能照搬到搜索。
- `app_search_client.dart` 负责混合结果解析、真实游标、页缓存、去重、失败重试及过期/乱序保护；`signed_app_search.dart` 和两端签名桥提供可注入传输。本机支持目录的有效 `search-visitor.json` 可启用访客 App 搜索；没有本机配置仍使用明确标注的网页首批。身份不写入源码或安装包。
- 程序自己的 Dart 模块已联网连续取得两页：5 条与 9 条正式剧集，无重复，第二批 9 条带热度，返回首批使用页缓存。此验证使用 `.local` 的本机诊断身份，并不证明首次自动注册已完成。
- 首次身份初始化仍待解决：受控注册实验（普通压缩与 TTEncrypt 请求）未获得有效身份。相关第三方研究参考仅保存在 `.local`，没有新增 Python、JVM 或模拟器运行依赖到交付包。
- 原始 HAR、身份、请求签名、完整响应和注册实验均保留在 `.local/traffic-infra/`，不进入源码包或发行包。尚未重打包新发行版本。
