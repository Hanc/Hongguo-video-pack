# 官网网页与播放 API

基址：`https://hongguoduanju.com`。普通页面为 GET HTML，主要业务数据来自页面中的 `window._ROUTER_DATA.loaderData`；部分页面含流式路由数据。解析页面数据，不执行抓到的任意 JavaScript。

## 接口目录

| 方法 | 路径 | 请求参数 | 数据入口/用途 | 状态 |
|---|---|---|---|---|
| GET | `/search/{keyword}` | 路径关键词，UTF-8 编码 | `search_` loader；`isSuccess`、`query`、`searchList`、`totalCount` | 首批实测有效；未取得网页后页 |
| GET | `/category/{category}` | `page` | 分类剧集与 `pagination` | 当前程序使用，支持真实分类后页 |
| GET | `/category` | `tab=1`、`sort_type=1`、可选 `page` | 其他程序旧分类入口 | 参考实现，不能替代当前分类契约 |
| GET | `/rank/{board}` | `page` | 排名、热度、更新时间、分页 | 当前程序使用，含流式数据解析 |
| GET | `/detail` | `series_id` | 剧集信息、`seriesSocialInfo.hot_score_data` 等统计 | 当前程序用于异步补充统计 |
| GET | `/player/{series_id}` | 剧集 ID | 播放页 loader 的完整剧集信息与分集 | 当前程序的详情回退入口 |
| POST | `/api/video/protected/play-info` | JSON：`series_id`、`item_id`、`definition` | 网页受保护音视频信息 | 已观测；访客曾取得 720P，1080P 请求被拒 |

当前榜单键：`hot-drama`、`hot-real-drama`、`hot-comic-drama`、`hot-ai-drama`。

当前分类键：`comic-drama`、`real-drama`、`ai-drama`。类别与标签不能相互冒充；保留来源排序与排名。

## 搜索首批

脱敏结构示例：

```json
{
  "loaderData": {
    "search_(keyword)/page": {
      "isSuccess": true,
      "query": "示例剧名",
      "totalCount": 100,
      "searchList": [
        {"video_data": {"series_id": "<series-id>", "series_title": "示例剧名"}}
      ]
    }
  }
}
```

在此前已测入口中，增加 `page=2` 或 `offset` 仍重复首批；不能据 `totalCount` 宣称用户已能浏览全部结果。默认搜索不得先扫描全分类片库，统计补充不得阻塞首批展示。用户主动启用的分类补充可在已获取数据上分页，但必须标为分类范围内检索。

## 列表与统计映射

- `series_id` → 稳定剧集 ID；`series_title` / `series_name` → 标题。
- `series_cover`、`series_intro`、`episode_cnt` → 封面、简介、分集总数。
- 同一剧集 `/detail?series_id=...` 的封面实测返回 JPEG，可用于补齐 App 搜索里的 HEIC 封面。先核对 `seriesDetail.series_id` 与请求 ID 一致，异步更新、最多 3 个并发，不能为了补图片阻塞首批结果。
- 热度、播放量、评分、收藏分别处理，不能将评分转成播放量，缺失统计不填造值。
- 列表预览视频不等于完整分集。进入工作台后重新读取完整分集。

## 受保护播放入口

官网脚本中确认实际路径为 `/api/video/protected/play-info`。历史研究文本中的 `/protected/play-info` 是简称，不能据此构造缺少前缀的真实 URL。

```json
{"series_id":"<series-id>","item_id":"<episode-id>","definition":"720p"}
```

脚本识别过 `502 / encrypted_resource_unavailable`，应作为错误处理线索，不能推断所有错误均为同一原因。返回受保护地址不等于完成下载、解密或音画验证。当前成品取流主路径是 App 批量 video model，见 [App 核心接口](app-core.md)。

## 代码与证据

- 当前实现：`lib/data/discovery_client.dart`、`lib/data/hongguo_client.dart`。
- 回归：`test/discovery_test.dart`、`test/provider_test.dart`。
- 历史调查与解码验证：`docs/stream-investigation.md`、`docs/acceptance.md`。
- 参考来源：guoguo-juku 的 `provider_hongguo_search.go`、`provider_rankings*.go`；livingroom 的 `ContentRepository.kt`；官网本地留存脚本。参考副本位于 `.local`，不随交付分发。
