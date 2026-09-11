# Bear runtime migration — 技术尽调 (PoC)

> 状态：**Phase 1 探索完成，建议进入设计阶段**。本分支不含生产代码改动，
> 只记录 PoC 结论 + 推荐实施方案。

## 核心结论

`holepunchto/bare-node-runtime` 是正确的兼容层入口 — 一个 `require('bare-node-runtime/global')`
就能在 bare runtime 内注入 `process`/`Buffer`/`global`/`__dirname` 等 Node globals，
让 Node-写的代码不需要改 import 就能跑。

**但 `require('fs')` 这种 builtin module 解析不会被 globals 接管**。bare 没有 Node 内置
模块表，需要走两条路之一：

1. **每个 Node builtin 装一个 `bare-*` 等价包**，并在调用方的 `package.json` 写
   `"imports": { "fs": "bare-fs", ... }`
2. **用 `npm:bare-node-fs` 别名**：`fs@npm:bare-node-fs` 让 `require('fs')` 自动
   解析到 `bare-fs`

这两条路都要求 **bundle.js 是一个 bare package**（有自己的 `package.json`）。
当前的 `dist/bundle.js` 是 esbuild 单文件 IIFE 输出，**没有 package.json**，
bare-module loader 看不到它的 imports map。

## PoC 数据（10 个上游包，bare runtime）

| 包 | require 状态 | 探针调用 | 备注 |
|---|---|---|---|
| crypto-js | ✅ | ✅ AES OK | 纯 JS, 无 Node builtin dep |
| xml2js | ❌ `require('events')` | – | 需要 bare-events |
| node-forge | ❌ `require('crypto')` | – | 需要 bare-crypto |
| safe-decode-uri-component | ❌ `require('fs')` (via `bindings`) | – | bindings.js 是 native bindings, 在 bare 下需要替换 |
| qrcode | ❌ `require('fs')` | – | 需要 bare-fs |
| axios | ❌ `require('util')` (via combined-stream) | – | 链式依赖，需要全套 bare-* |
| tunnel | ❌ `require('net')` | – | bare-net |
| pac-proxy-agent | ❌ `require('net')` | – | bare-net |
| music-metadata | ❌ PACKAGE_PATH_NOT_EXPORTED | – | v11 pure ESM, exports 不暴露 `.`, 需要 `module-sync` 条件 (跟之前 build.mjs 加的一样) |
| jsdom | ❌ UNSUPPORTED_ENGINE | – | requires Node ≥22.22, bare 假装自己是 20 → 拒。**且 bare 无 jsdom 等价物** |

## 上游 NCM 包对 bare 的兼容性评估

**可兼容（装 bare-* 包 + 路径写对）**：
- crypto-js, xml2js, node-forge, qrcode, safe-decode-uri-component, tunnel,
  pac-proxy-agent — 全部有 bare 等价物，纯 JS 包和原生 fs/net/crypto 重度用户
- axios — bare-http1 + bare-https 替换后能用

**有条件兼容**：
- music-metadata — 需要 bundle 加 `conditions: ['module-sync']`（之前已加），
  且需验证其 10 个 ESM 依赖都能跑（strtok3, file-type 等）

**blocker**：
- **jsdom** — bare 生态无等价物。NCM 的 jsdom 用法集中在 unblockmusic
  (`util/unblock.js`) 和 crypto (option.js 的随机浏览器 fingerprint)。
  需要：
  - 选项 A: 找一个轻量 DOM 实现（linkedom 是 DOM 但不模拟浏览器 API）
  - 选项 B: 重写 unblock/option.js 的 jsdom 使用处用 linkedom 或者直接拿掉
  - 选项 C: 排除 jsdom 依赖的 fn（unblock 系接口），接受功能损失
- **bindings**（node 原生模块加载）— `safe-decode-uri-component` 通过它加载 native addons
  → bare 没有 native addon 入口 → 这个包要换

### 真正试过的两条路径

#### 路径 1：`require('bare-node-runtime/global')`（globals 注入）

```js
require('bare-node-runtime/global')
console.log(typeof process, typeof Buffer, typeof __dirname)
// → 'object' 'function' 'string' ✓
```

✅ **globals 注入成功**。进程/Buffer/global/timers/structuredClone 全有。

❌ **不解决 builtin module**：`require('fs')` 仍报 `MODULE_NOT_FOUND`。
globals ≠ builtin modules。bare 没有内置 fs/path/... 表。

#### 路径 2：`bare-node-runtime/imports.json` 作为 import map 数据

```js
// in caller/package.json:
{
  "imports": {
    "fs": "bare-fs",
    "path": "bare-path",
    "events": "bare-events",
    ...
  }
}
```

**bare 行为（实测）**：
- caller 自己 `require('fs')` → 走 caller 的 imports map → ✓
- caller `require('xml2js')` → 加载成功
- xml2js 内部 `require('events')` → ❌ **失败**

**原因**：bare-module 看的是 `require` 所在文件的直接 caller 的 package.json（=xml2js 自己的），**不上溯**到我们 caller 的 imports map。这是 bare-module 的标准行为，**不**像 Node 某些场景会沿 require chain 累积 imports。

所以 `bare-node-runtime` 的真正用法：**每个依赖 Node builtin 的 npm 包自己装 bare-node-fs/bare-events/...**，或者**包自己的 package.json 写 imports map**。

**`bare-node-runtime/imports.json` 是给"知道自己在 bare 下跑"的包用的 import map 数据资源**，不是自动生效的魔药。

### bundle.js 的根本约束

bundle.js 是 esbuild 单文件 IIFE 输出（不是 bare package）。`require('fs')` 在 bundle 内部 —— caller chain 顶端是 bundle.js 自己 — 它**没有 package.json**，bare-module 找不到 imports map。

**两条出路**：

1. **bundle 拆包**：bundle.js → `bundle/index.js` + `bundle/package.json`（imports）
   + `bundle/node_modules/`（bare-* 依赖）。破坏单文件 deploy。

2. **bundle.js 顶部 inline shim**：bundle.js IIFE 最前面加一段 require 替换代码，
   拦截 builtin name 重定向到 bare-*。脆弱（依赖 bare 内部 API），但保留单文件。

**两条都做完工作量都差不多**。**推荐 (1)** —— 干净、可维护。

**桌面端 (Linux/macOS/Windows)**：当前 spawn 系统 `node` 进程跑 `dist/bundle.js`。
换 bare 不增加价值（bare 桌面端没有 node 跑得更好），且 bare 不是 npm-installed 系统包，
需要用户在系统装 `bare-runtime` binary（prebuild 下载）。

**真正值得换的**：Android (libnode.so FFI) + iOS (NodeMobile.xcframework) 的
embedded runtime 路径。

- bare 提供 `bare-runtime` npm 包，里面是 5 个平台的 prebuilt binary
- bare-android 是独立 repo: https://github.com/holepunchto/bare-android
- bare-ios 是独立 repo: https://github.com/holepunchto/bare-ios

要替换需要：
1. 重写 `native/android/node_bridge.cpp` → 链接 `libbare.so` 而不是 `libnode.so`，
   改用 `bare_setup`/`bare_load`/`bare_run` 而不是 `node::Start`
2. 重写 iOS plugin: NodeMobile.xcframework → Bare.xcframework（bare-ios 提供）
3. Dart 侧 `MobileNcmBridge` 的 FFI 签名变了要适配

## 推荐方案：分阶段、目标明确

### Phase A: 完成 desktop spawn bare 路径（本次不实施）

目的：验证 bare 能跑 439 个 NCM module fn 中除 jsdom/music-metadata 以外的部分。

实施步骤（具体不在本分支）：
1. 拆 bundle.js 单文件 → 改成 `dist/bundle/` 目录 + `package.json`（带 imports map）
2. 装 37 个 bare-* 包到 bridge 目录
3. bridge/package.json 加 full imports map (`fs` → `bare-fs`, `path` → `bare-path`, ...)
4. bundle.js 顶部加 `require('bare-node-runtime/global')`
5. `DesktopNcmBridge` 改 `node dist/bundle.js` → `bare dist/bundle/index.js`
6. 处理 jsdom block: 在 `generated_api.js` 把 unblock 系 fn 排除（如果必要）
7. 处理 music-metadata: 已在 build.mjs 加 `module-sync`，要验证

### Phase B: 替换 Android FFI runtime

1. 拿 `bare-runtime` prebuild（npm i 到 bridge） + 编译 `bare-android` 自定义 JNI
2. 重写 `native/android/node_bridge.cpp` — 改用 bare C API
3. 修改 Dart FFI binding (`mobile_bridge.dart` 的 dylib load)
4. CI 加 android-instrumented-test，跑通 1-2 个 module fn e2e

### Phase C: 替换 iOS xcframework

1. 拿 `bare-ios` xcframework
2. 改 Podfile + plugin 注册
3. iOS smoke test

## 本次提交

- 分支：`bear`（已推 origin）
- 内容：`/tmp/bear-poc/` 下的 PoC 脚本和结论（本目录 doc）
- **没动项目代码**

## 重新验证后修正

之前的 PoC 第一轮失败（所有 require 失败）的原因是测试入口没装齐 bare-* deps；
第二轮加了 caller 的 imports map 后：

- ✅ caller 直接 require fs/path/events 走 imports map 替换 bare-* OK
- ✅ 同包里的纯 JS 包（crypto-js）可加载
- ❌ nested require（xml2js 内部 require 'events'）**不走** caller 的 imports map
  → 这是 bare-module 的设计：只查 direct caller 的 package.json
- 🔄 `bare-node-runtime` 的真实用法是给每个包自己写 imports map，不是 wrapper
- 📝 bundle.js 单文件没有 package.json → 必须包化为 bare package（拆 bundle）

## 下一步建议

进入 Phase A，但先在 `/tmp/bear-poc` 做 sub-PoC 验证 jsdom 替代方案：
- unblock.js 实际怎么用 jsdom？能不能用 linkedom 替代？
- music-metadata 整套 ESM 依赖链在 bare 上是否完整？

确认这两点后，再决定 Phase A 的工作量是否值得投入。
