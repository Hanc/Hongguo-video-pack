# 其他抓包路径与其他程序中的接口

本页刻意区分“看到请求”“读到业务数据”和“参考源码存在”，避免将来源线索当作已接通接口。

## 本次官方 App 的其他观测

| 方法 | 路径/模板 | 已知用途/字段 | 验证边界 |
|---|---|---|---|
| GET | `/reading/bookapi/bookmall/tab/v` | 商城/首页标签 | 已读到 JSON 200；未整理全部业务字段 |
| GET | `/reading/bookapi/plan/v` | 页面计划配置 | 仅请求观测，不承诺所有记录有响应 |
| GET | `/reading/bookapi/plan/v:version/` | 带版本形式的计划配置 | 抓到 200 JSON；与无版本路径关系待确认 |
| GET | `/reading/bookapi/search/cue/v` | 搜索页提示 | 已观测请求，未核对全部响应 |
| 待确认 | `/reading/bookapi/search/suggest/v` | 联想建议 | 旧日志中出现；不能当成完整搜索结果接口 |
| POST | `/novel/player/multi_video_detail/preload/v1` | 批量预加载详情 | 已观测请求及载荷大小；不是完整详情成功证明 |
| POST | `/reading/distribution/book_pack_fields/inner_feed_detail/v1` | 信息流详情 | 已观测请求；响应全字段待核对 |
| POST | `/novel/commentapi/comment/list/{video_id}/v1` | 评论/可能的弹幕来源 | 抓包有请求；尾斜杠形式在参考源码出现 |
| POST | `/reading/ai_search/.../conversation_info/v` | AI 搜索会话信息 | 抓包列表中路径截断，只记录已知片段，禁止猜补完整路径 |
| 待确认 | `/reading/media/play/strategy/` | 播放策略 | 旧日志路径；没有完整请求/响应契约 |
| POST | `/pilvinen/v1/sseelfk/haku` | SDK 请求，`mssdk3-normal-lf.zijieapi.com` | 读到 200 小响应；不是搜索或设备注册成功证明 |
| POST | `/ri/report` | SDK 上报，同上网关 | 读到 200 响应；不要为业务搜索主动重放无关上报 |

图片/CDN 域名、DNS、TLS 建连及广告/分析域名只证明网络访问。它们不是独立业务 API 文档，也不证明明文已解密。`certificate unknown` 曾在部分图片连接出现，不应把所有连接统一定性为证书绑定。

## guoguo-juku 参考源码

来源：[digitalPartty/guoguo-juku](https://github.com/digitalPartty/guoguo-juku)。本地参考副本在 `.local/reference/guoguo-juku`；以下是源码发现，除核心文档注明的复验外均不算本项目已接通。

### 分类/推荐

`POST /reading/distribution/category/landpage/v/`

来源文件：`internal/app/provider_hongguo_catalog.go`、`provider_hongguo_recommendations.go`。

参考请求字段：`req_scene`、`offset`、`limit=18`、`req_type=only_content`、`need_selector_panel=false`、`client_req_type`、`session_id`、`filter_ids`、`select_items`。`select_items` 包括 `genre`、`sort`、`gender`、主题/角色/年代分类、上线时间、创作状态等数组。

参考类别：`short_play`、`comic_series`、`ai_series`。首次 `client_req_type=3`，后页参考实现取 2；以服务端返回为准，不能据源码替代实测。

参考响应：`data.video_data`、`data.has_more`、`data.next_offset`、`data.session_id`。参考程序检查游标前进、过滤已见 ID。不得把该分类扫描作为默认搜索的隐式后台工作。

### 评论/弹幕

`POST /novel/commentapi/comment/list/{video_id}/v1/`

来源：`ui_playback_danmaku.go`、`provider_hongguo_comment_sign.go`。存在特殊评论请求/签名逻辑；尚未整理并验证本项目完整载荷、时间轴语义及分页。不能把普通评论直接称为已可用弹幕。

### 第三方解析入口

`GET https://djapi.999888456.xyz/api/hongguo/play?id=<base64-json>`

来源：`provider_hongguo_playback.go`。参考 `id` 内容为 `content_type`、`series_id`、`vid`、`video_platform` 等；参考响应有 `parse`、`jx`、`key_urls[{name,src,kid,spade_a}]`。

该入口属于第三方服务，不是红果官方接口。本项目没有把它作为正式取流依赖；不能因为参考源码含兜底，就在产品里静默增加外部解析服务。

其他：`video_detail/v1/`、旧 `video_model/v1/` 与官网网页搜索/榜单已归入相应核心文档，不重复定义为新接口。

## livingroom / drpys 参考

来源：[seanminjie-del/hongguoTV-livingroom](https://github.com/seanminjie-del/hongguoTV-livingroom)，本项目研究记录的提交为 `76eeaa9b964359fe6ed3f4a2b6f79ffb11f35761`。

- `server/vendor/hongguo.cjs`：网页分类、搜索、App 搜索签名、批量 video model、媒体解析。
- Kotlin core `ContentRepository.kt`：搜索游标/缓存、网页回退、剧集详情与取流思路。
- 算法来源包含 drpys，GPL-3.0；项目已保留对应 notices。来源注释里“实测可用”只代表原作者描述，本项目必须独立验证。
- 本地旧研究稿还列出 `/novel/player/multi_video_detail/v1/`、`/novel/player/multi_video_model/preload/v1`，目前只有参考线索，未完成本项目请求/响应复验。

## MiniReel 观测边界

此前从已安装程序的公开配置、字符串及本地详情记录定位到与官网/App 一致的样例剧集与分集 ID，没有修改、注入或替换 MiniReel 进程。

没有取得其完整搜索请求，就不能声称 MiniReel 的第一页限制和官网重复页属于同一接口原因。没有证据的网关、参数、登录接口不补写为“MiniReel API”。

## 注册与 SDK 研究来源

本地独立注册实验借鉴 [zhangbaio/hongguo](https://github.com/zhangbaio/hongguo) 的研究结构，以及 [iqbalmh18/tiktok-signer](https://github.com/iqbalmh18/tiktok-signer) 的 MIT TTEncrypt 参考。它们是其他 App/版本或未完成研究，不能当作红果注册必然有效的证据。参考代码目前只在 `.local` 实验，没有进入产品依赖。

旧诊断中还出现 `/service/2/abtest_config/`、`/service/2/log_settings` 和社区前端模板 `/novel/dr/fe/drlynx_community_p0/forum/template.js`。这些分别属于配置/静态资源线索，不是已经验证的搜索、登录或下载接口。

## 维护与补全

新增抓包至少记录：时间、App 版本、host、method、完整 path、请求字段名称/语义、响应结构、业务码、游标及不同 ID 的证据。导出前脱敏；只有截断路径就保留截断说明。不得复制账号或设备身份、Cookie、签名值、CA 私钥、CENC 密钥、原始媒体 URL。
