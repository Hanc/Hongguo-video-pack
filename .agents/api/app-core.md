# App 核心 API

核对日期：2026-10-19。App 包名 `com.phoenix.read`，当前抓包版本 `7.3.9.32 / 73932`，App 标识 `aid=8662`、`app_name=novelread`。历史取流使用的版本参数与签名环境不同，不能统一替换后声称仍可用。

## 网关与鉴权边界

| 用途 | 已观测/使用的网关 | 边界 |
|---|---|---|
| 实测搜索 | `api5-normal-sinfonlinec.fqnovel.com` | 已取得有效搜索及后页；程序新签名可用 |
| 当前详情/取流 | `api5-normal-sinfonlineb.fqnovel.com` | 当前适配主路径 |
| 旧搜索实验 | `api5-normal-sinfonlinea.fqnovel.com` 及 b 网关 | 曾 HTTP 200 空正文，不代表搜索本身不支持分页 |

所有请求使用 HTTPS。设备/安装身份是访客身份，不等于账号登录。实测搜索移除 Cookie、登录授权及捕获 SDK 临时字段后仍可成功，但随机替换 `device_id` 或 `iid` 会返回空正文；省略或置零曾返回业务码 `100103`。因此不能把取流中可用的随机身份策略视为搜索身份初始化方案。

签名头的**名称**：`x-khronos`、`x-ladon`、`x-argus`、`x-gorgon`、`x-helios`、`x-medusa`。附带 `x-ss-req-ticket`、SDK/版本相关头；POST 请求可使用 `x-ss-stub` 表示正文摘要。每次请求按实际 query、正文、时间重新生成；签名值不写入文档。

## 1. 搜索与真实分页

`GET /reading/bookapi/search/tab/v`

无尾斜杠是本次成功观测的形式；历史带尾斜杠实验的空响应不能证明两者永远等价或永远不同。

| 字段 | 位置/类型 | 用途与实测值 |
|---|---|---|
| `query` | query/string | 搜索词，UTF-8 百分号编码 |
| `tab_type` | query/int 字符串 | 本次综合页为 `11`；不能靠数字猜标签名 |
| `count` | query/int 字符串 | 本次官方请求为 `0`，不是“结果条数应为零” |
| `offset` | query/int 字符串 | 首批 0，后续取上一响应 `next_offset` |
| `search_id` | query/string | 后页沿用服务端搜索会话 |
| `passback` | query/string | 后页原样传回服务端游标，不在客户端自行递增 |
| `bookshelf_search_plan` | query/string | 观测为 `4` |
| `user_is_login` | query/string | 本次免登录为 `0` |
| `search_source` | query/string | 观测为 `1` |
| `device_id`、`iid` | query/string | 有效访客设备/安装身份；本机保存，不提供共享常量 |
| App/系统信息 | query/string | `aid`、`app_name`、版本、平台、语言、分辨率等，需与签名环境相容 |
| 时效字段 | query/string | `_rticket`、签名时钟等，按请求生成 |

官方请求还含推荐/上次消费上下文、`use_lynx`、分类标签、设备运行状态等。没有证据说明所有字段都必需；不要直接把整份抓包 query 固化进产品。

成功响应的结构示例（全部身份与会话值为占位符）：

```json
{
  "code": 0,
  "message": "SUCCESS",
  "selected_tab_idx": 0,
  "search_tabs": [{
    "tab_type": 11,
    "title": "综合",
    "query": "示例剧名",
    "data": [{
      "show_type": 369,
      "video_data": [{
        "vid": "<preview-id>",
        "series_id": "<series-id>",
        "title": "示例剧名",
        "episode_cnt": 80,
        "show_rec_text": true,
        "rec_text": "123万热度",
        "show_play_cnt": true,
        "play_cnt": 12345,
        "video_detail": {
          "series_id_str": "<series-id>",
          "series_title": "示例剧名",
          "episode_cnt": 80,
          "series_cover": "<cover-url>",
          "series_intro": "示例简介"
        }
      }]
    }],
    "has_more": true,
    "next_offset": 6,
    "passback": "<cursor>",
    "search_id": "<search-session>"
  }]
}
```

根字段还观测到 `server_ab_params`、`log_id`。每个 tab 可含 `plan_id`、`search_target_channel`、`search_scene`、`client_template`、`selector`，不是统一的数据数组。

### 混合卡片解析

- `show_type=369` 的样本包含正式 `series_id` 与 `video_detail`；以剧集 ID 去重，不能以预览 `vid` 作剧集 ID。
- `show_type=532` 的样本为 UGC 合集，只有 `album_info.album_id`；当前正式剧集解析器跳过。
- `show_type=611` 的样本含字符串 `lynx_data` 和排名容器；当前解析器不把容器当一个剧集。
- `video_detail.series_id_str` 优先于数值字段，避免把大整数经不支持的数值类型转换后丢精度。
- `rec_text` 只有明确含“热度”才归热度，`play_cnt` 与展示开关共同处理；评分、点赞、收藏不得混用。
- 搜索 `series_cover` 可能是签名 HEIC 图片，HTTP 200 不代表 Flutter Windows 可解码；改变后缀为 JPEG/WebP 已实测返回 403。当前按同一 `series_id` 异步查询官网 `/detail` 的 `seriesDetail.series_cover`，已取得 JPEG，保留原签名 URL，不自行拼接或改写格式参数。

### 已验证的分页链路

2026-10-19 13:04:53 的首批与 13:23:36 的后页使用同一搜索会话。后页请求 `offset=6`、`passback=5`，返回 9 个正式剧集，与首批无重复；后页 `next_offset=16`。这是本次会话的实测值，不是固定分页步长。

自研 Dart 模块加自研新签名已连续取得 5 条、9 条正式剧集，ID 无重合，返回上页使用缓存。测试使用本机已注册访客身份，不证明自动注册已完成。应用可从自己的支持目录读取 `search-visitor.json`（version 1，仅设备/安装标识）；配置存在且有效时启用 App 搜索，没有本机配置时仍走明确标注的网页首批。初始化文件不随安装包分发，不是共享内置身份。

异常：HTTP 非 200、200 空正文、非零业务码、标签/关键词不匹配、会话变化、游标不前进、重复结果均须明确失败，不能消费游标或伪造后页。`has_more` 不等于已知总页数。

代码：`lib/data/app_search_client.dart`、`signed_app_search.dart`、`request_signer.dart`、`assets/protocol/worker.cjs`、`signer.cjs` 及 Android `protocol/Signer.kt`。

## 2. 详情与完整分集

`POST /novel/player/video_detail/v1/`

```json
{"series_id":"<series-id>"}
```

当前程序读取 `data.video_data`，核对 `series_id_str / series_id` 与请求一致。分集在 `video_list`，读取 `vid`、`vid_index`，核对分集所属剧集并按序排序。详情失败可回退官网 `/player/{series_id}` 读取完整分集。不能以列表搜索里的预览条目替代完整列表。

代码：`HongguoClient.fetchDrama`、`parseAppDrama`、`parseWebDrama`。已接入当前程序；具体来源当时是否成功须看对应请求，回退成功不证明 App 详情请求也成功。

## 3. 批量取流与清晰度

`POST /novel/player/multi_video_model/v1/`

```json
{
  "biz_param": {
    "detail_page_version": 0,
    "device_level": 3,
    "disable_digg_stat": false,
    "need_all_video_definition": true,
    "need_mp4_align": false,
    "use_os_player": false,
    "use_server_dns": false,
    "video_platform": 1024
  },
  "mixed_video_id_map": {"1004":["<episode-id>"]}
}
```

已通过完整签名实测，业务 Code 0；独立随机访客身份对该取流链路曾有效，不可推导到搜索。`data[episodeId].video_model` 可能是 JSON 字符串或对象；从中读取 `fallback_api`，该字段也可能嵌套为对象、JSON 字符串或数组。

当前代码会校验媒体信息 URL 为 HTTPS 且位于已允许的来源域名。不要拼造固定媒体网关，不把失效临时 URL 当永久资源。

## 4. 动态媒体信息与实际媒体

`GET <video_model 返回的 fallback_api>`，完整路径由来源动态给出。

读取 `video_info.data.video_list`、`key_seed`、`video_duration`；`video_list` 可能为映射或列表，包含 `definition`、`vwidth`、`vheight`、`codec_type`、`main_url`、`spade_a` 等字段。

- 媒体地址按 `key_seed` 处理；`spade_a` 用于内容密钥派生，密钥与原始地址不写进文档。
- 已观测 360/480/576/720/1080 档位；低档出现 bytevc2，不代表已被引擎支持。当前过滤 bytevc2/bvc2。
- bytevc1 对应本次媒体中的 HEVC；清晰度优先依据实际宽高较小边，不能只信 UI 标签。
- Windows 已对前两集 1080P 下载、拼接、完整音视频解码验收；不能据此宣称所有剧集或自研 Android 全设备流程都已验收。

## 5. 已失败的旧取流入口

`POST /novel/player/video_model/v1/`：在 guoguo-juku 的 native media 实现中存在，本项目早期简化签名请求曾返回空正文。只更换成批量路径或只更换设备 ID 也曾失败；成功来自完整请求链路，不能恢复旧方案后宣称等价。

## 6. 首次访客注册

`POST https://log.snssdk.com/service/2/device_register/`

官方 APK 字符串确认此路径；本项目独立实验尚未取得有效 `device_id / install_id`。普通压缩 `tt-data=b`、TTEncrypt `tt-data=a` 的受控请求均返回 HTTP 200、设备/安装 ID 为 0，属于失败。

实验结构：正文含 `magic_tag=ss_app_log`、`header`、`_gen_time`；header 包括 App、系统、版本、语言、时区、首次初始化随机标识等。加密、签名、版本、App aid 与服务端注册条件仍需按真实首次请求核对。TTEncrypt 只是正文格式，不代表注册成功。

注册返回 ID 为 0 时禁止生成假身份替代，禁止内置抓包中单台设备的身份。该问题与是否账号登录是两件事，当前没有证据表明接账号登录能修复注册。
