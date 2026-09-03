# 酒馆 Gemini 思维链修复

修复 **Sub2API 中转站的 Gemini 模型在 SillyTavern 里把思维链写进回复正文**的问题。

**症状**：用中转站的 Gemini 型号时，模型的思维链（`**My Thought Process**`、`**Comparing Numerical Values**`
之类的一大段自言自语）直接混在回复正文里，没有被酒馆折叠进思维块。

不是你配置错了，也不是酒馆的锅。

---

## 为什么会这样

Sub2API 在做协议转换时，把 Gemini 的思维分段**当成普通正文**拼进了回复。
同一个提示词打中转站的三条协议端点，实测：

| 端点 | 思维链落在哪 | 酒馆能不能识别 |
| --- | --- | --- |
| `POST /v1/chat/completions` | `delta.content` / `message.content`，**和正文同一个字段**，没有 `reasoning_content`、没有 `<think>` 标签、没有任何分隔标记 | ❌ |
| `POST /v1/messages`（Anthropic 协议） | 一个 `{"type":"text"}` 块，**不是** `{"type":"thinking"}` | ❌ |
| `POST /v1beta/models/<model>:generateContent`（Gemini 原生） | 独立 part，带 `"thought": true`；正文 part 另带 `thoughtSignature`，usage 里有 `thoughtsTokenCount` | ✅ |

**上游数据是完好的，是转换层把它拍平了。**

代码位置：`backend/internal/service/gemini_messages_compat_service.go` 的 `convertGeminiToClaudeMessage()`。
它遍历 Gemini 的 parts，只要 `text` 非空就追加成 `{"type":"text"}` 块，**没有判断 `part["thought"]`**。
而 Gemini 的思维 part 本身就是带 `text` 的 part，于是原样变成普通文本块，再经
`geminiResponseToChatCompletions()` 拼进 `content`。

请求里加 `thinking` / `reasoning_effort` 参数都改变不了这个结果（三种写法都试过）。

酒馆那边也没有可乘之机：`public/scripts/openai.js` 的 Custom 源只读
`delta.reasoning_content` / `delta.reasoning`，两个都没有；自动解析（Auto-Parse）
需要 `<think>` 之类的前后缀，正文里根本没有。

## 修法

让酒馆改走中转站的 **Gemini 原生端点**（`/v1beta`），思维链就是带 `thought: true` 的独立分段，
酒馆的 Google AI Studio 分支会把它收进 reasoning，正常折叠。

**挡路的只有一行代码**：酒馆拉取模型列表时按 `supportedGenerationMethods` 字段过滤，
而中转站不返回这个字段，于是所有 gemini 型号被滤光，下拉框里根本选不到
（直接改配置文件也没用，酒馆发现选中的型号不在列表里会重置成第一个）。

---

## 怎么用

1. 把整个文件夹拷到你电脑上任意位置；
2. **先完全关掉酒馆**（很重要，酒馆退出时会覆写自己的配置文件，不关的话改动会被冲掉）；
3. 双击 **`修复酒馆Gemini思维链.cmd`**；
4. 按提示粘贴你的中转站 API Key（`sk-` 开头）；
5. 看到绿色的 `[OK]` 跑完就行。

脚本会自己找你电脑上的酒馆，不用填路径。找不到的话看下面的「常见问题」。

跑完之后启动酒馆，**按一次 `Ctrl+F5` 强刷页面**（后端代码换了），
然后在右上角的「连接档案」里选 **`中转站 Gemini`**，点 Connect。
型号在下拉框**最底下的 `Other` 分组**里。

发一条消息试试：思维链应该进折叠块了，正文干净。

> **用别的中转站？** 脚本默认地址是 `https://api.sulianyan.com`，换一个加
> `-RelayUrl https://你的地址` 就行；也可以跑完之后直接在酒馆的
> 「反向代理」那一栏里改。只要对方是 Sub2API，路径结构都一样。

## 参数

都是可选的，双击时不用管。从命令行跑，或者在 `.cmd` 后面直接跟参数：

| 参数 | 作用 |
| --- | --- |
| `-Path "D:\xxx\SillyTavern"` | 直接指定酒馆目录，跳过自动查找 |
| `-DeepScan` | 自动找不到时，全盘深度扫描（慢一点） |
| `-All` | 找到多个酒馆时全部修，不再问你选哪个 |
| `-ApiKey sk-xxx` | 直接给 Key，不用交互式输入 |
| `-Model gemini-3.1-pro-high` | 换个型号（默认 `gemini-3.8-flash-high`） |
| `-RelayUrl https://xxx` | 换中转站地址 |
| `-PatchOnly` | 只打代码补丁，不动你的酒馆配置 |
| `-Revert` | **还原**，撤销本工具的改动 |
| `-WhatIf` | 只演练不落盘，看看它打算改什么 |

例子：

```
修复酒馆Gemini思维链.cmd -DeepScan
```

## 它到底改了什么

只动两个文件，**改之前都会自动备份**成 `xxx.before-gemini-thinking-<时间戳>.bak`：

**1. `src\endpoints\backends\chat-completions.js` —— 改一行**

```js
// 改前
?.filter(model => model.supportedGenerationMethods?.includes('generateContent'))
// 改后
?.filter(model => !Array.isArray(model.supportedGenerationMethods) || model.supportedGenerationMethods.includes('generateContent'))
```

字段缺失（中转站返回 `null`）时放行；Google 官方返回的是真数组，照旧过滤——两边都不破。

**2. `data\<用户>\settings.json` —— 加配置**

- 新增一条反代预设 `Sub2API Gemini`（地址 + 你的 Key）
- 数据源切到 Google AI Studio、型号设好、**打开 Show thoughts**
  （这个开关关着的话酒馆压根不会向中转站要思维链）
- 新增一条连接档案 `中转站 Gemini`

**你原有的连接档案和反代预设一个都不会动**，随时可以在下拉框里切回去。
Key 只写进你本机的 `settings.json`，不发往任何地方。

## 安全与幂等

- 改任何文件前先备份，`-Revert` 一键还原
- 重复运行安全：已经是目标状态就完全不动手，也不会堆积备份
- 版本对不上（匹配不到那行代码）就**拒绝修改并报错**，绝不硬改
- 酒馆正在运行时**拒绝写配置**（否则酒馆退出会把改动覆盖回去）
- 写完 `settings.json` 会重新解析校验，任何一项不对**自动回滚**

## 常见问题

**Q：脚本说「没找到 SillyTavern」**
加 `-DeepScan` 全盘扫，还不行就直接指定：
`修复酒馆Gemini思维链.cmd -Path "D:\你的路径\SillyTavern"`
（指的是含有 `server.js`、`public` 文件夹的那一层。）

**Q：脚本说「酒馆正在运行」**
完全关掉酒馆（黑窗口也要关）再跑。

**Q：脚本说「版本对不上，不动它」**
你的酒馆版本和本补丁验证过的版本差得比较远，脚本故意不硬改。请提个 issue 附上那几行提示。

**Q：下拉框里还是看不到中转站的型号**
① 页面按 `Ctrl+F5` 强刷；② 确认点过 Connect（型号列表是连上以后才拉的）；
③ 往下拉到最底下的 `Other` 分组。

**Q：思维链没出现，但正文也干净了**
说明已经走对端点了，只是这次模型没思考，或者 Show thoughts 没开。
换带 `-high` / `-medium` 后缀的 3.x 型号试试。`gemini-2.5-flash` 默认是不思考的。

**Q：酒馆更新之后又不行了**
酒馆升级会覆盖掉那行代码补丁。**重跑一次本脚本**即可。

## 边界

- 只管中转站的 **Gemini**。中转站的 Claude / GPT 型号走的是另一条协议，不受影响，也不需要它。
- 需要 Windows + PowerShell（系统自带）。
- 验证环境：SillyTavern 1.18.0 + Sub2API 0.2.0。代码补丁按正则匹配而非行号，
  相邻版本大概率也能打上；打不上会明确报错而不是改坏。
- **根子在中转站的转换层。** 哪天上游修好了 `convertGeminiToClaudeMessage()`，
  本补丁可以 `-Revert` 掉，直接用原来的 OpenAI 兼容接口就行。

---

## Summary (English)

Sub2API flattens Gemini's *thought* parts into ordinary assistant text, so SillyTavern has
no field to fold them into a reasoning block — the chain-of-thought summary leaks into the
message body.

Root cause is in `convertGeminiToClaudeMessage()`
(`backend/internal/service/gemini_messages_compat_service.go`): it appends any part with
non-empty `text` as a `{"type":"text"}` block **without checking `part["thought"]`**. Since a
Gemini thought part *is* a text-bearing part, it becomes a normal text block, and
`geminiResponseToChatCompletions()` then concatenates it into `content`. Neither
`thinking` nor `reasoning_effort` request parameters change this.

The relay's **native Gemini endpoint** (`/v1beta/models/<model>:generateContent`) is unaffected —
thought parts arrive correctly flagged with `"thought": true`, alongside `thoughtSignature`
and `thoughtsTokenCount`.

This script points SillyTavern at that native endpoint. The only blocker is one line in
SillyTavern's model-list filter, which drops every model when the upstream omits
`supportedGenerationMethods` (as Sub2API does). The patch lets a missing field through and
leaves Google's real arrays filtered as before.

## License

MIT
