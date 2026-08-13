# 布局 JSON 与 Agent 整理工作流

机器可读的 QLaunchpad 布局文档（`kind = qlaunchpad.layout`，`schemaVersion = 1`）以及同一可执行文件上的 headless CLI。JSON Schema 见同目录 [layout.schema.json](layout.schema.json)。本文档放在 `engineering/`，不要放进 `docs/`（官网构建会清空该目录）。

权威存储仍是偏好三键（`launchpadItemOrder` / `launchpadFolders` / `hiddenAppIdentifiers`）。JSON 是派生视图。导出**不会**写入 `customApplicationSourcePaths`、热键或其它设置；扫描额外根只从目标偏好域读取。

## 调用方式

可执行文件名是 **QLaunchpad**，包在 `.app` 里：

| 构建 | 包 | 二进制 |
| --- | --- | --- |
| Debug / Dev | `QLaunch Dev.app` | `QLaunch Dev.app/Contents/MacOS/QLaunchpad` |
| Release | `QLaunch.app` | `QLaunch.app/Contents/MacOS/QLaunchpad` |

优先用 bun 脚本（只 spawn 上述打包二进制，**永远不** `swift run`、不 `open -a`、不把 argv 送给已运行的 GUI）：

```sh
bun run layout:export -- --out /tmp/qlaunch-layout.json
# 编辑该文件
bun run layout:import -- --in /tmp/qlaunch-layout.json --dry-run --strict
bun run layout:import -- --in /tmp/qlaunch-layout.json --merge --strict
bun run layout:validate -- --in /tmp/qlaunch-layout.json
```

`scripts/layout.ts` 查找顺序（先到先用）：正在运行的 Dev 包 → 正在运行的 Release 包 → `build/DerivedData/Build/Products/Debug/QLaunch Dev.app` → `build/DerivedData/Build/Products/Release/QLaunch.app` → `/Applications/QLaunch.app`。**正在运行的二进制只有路径落在仓库根下才采用**（`isUnderRoot`）；`/Applications/QLaunch.app` 在跑也会被跳过，然后落到 DerivedData / `/Applications` 的存在性检查。找不到时先 `bun run dev`。

直接调用打包二进制（路径按本机产物替换）：

```sh
"build/DerivedData/Build/Products/Debug/QLaunch Dev.app/Contents/MacOS/QLaunchpad" \
  export --out /tmp/qlaunch-layout.json

"build/DerivedData/Build/Products/Release/QLaunch.app/Contents/MacOS/QLaunchpad" \
  import --in /tmp/qlaunch-layout.json --dry-run --strict
```

从打包 `.app` 启动时，偏好域就是该包的 `CFBundleIdentifier`（Release `com.qzrzz.qlaunchpad`，Dev `com.qzrzz.qlaunchpad.dev`）。裸 `swift run QLaunchpad …` **没有**这些 bundle id，会被拒绝，必须显式 `--domain` / `--dev` / `--app`。不要把它当作默认入口。

## Schema 字段

[layout.schema.json](layout.schema.json) 是编辑器 / Agent 的契约（含 `additionalProperties: false`）。`bun run layout:validate` 与 `import` 走的是 Swift：`LaunchpadLayoutDocument` Codable + `LaunchpadLayoutImporter.validate`（`kind` / 版本 / 上限 / 文档内 ID 不变量，**不**扫描磁盘）。未知键（包括误加的 `customApplicationSourcePaths`）会被 Codable 忽略，不会被 CLI 拒绝；schema 比 CLI 更严。Swift 类型见 `Sources/QLaunchpadCore/LaunchpadLayout.swift`。规范 JSON 由 `JSONEncoder` `[.sortedKeys, .prettyPrinted]` + ISO-8601 产出；编码器锁定的完整文档是 [Tests/QLaunchpadCoreTests/Fixtures/canonical-layout.json](../Tests/QLaunchpadCoreTests/Fixtures/canonical-layout.json)。

| 字段 | 必需 | 说明 |
| --- | --- | --- |
| `kind` | 是 | 恒为 `qlaunchpad.layout` |
| `schemaVersion` | 是 | 正整数。v1 解码器只接受 `== 1`；缺字段或 `> 1` 拒绝 |
| `exportedAt` | 否 | ISO-8601 UTC。导入忽略 |
| `appVersion` | 否 | 导出时的 `CFBundleShortVersionString`。导入忽略 |
| `grid` | 否 | **只读快照**。含 `preset` / `columns` / `rows` / `pageCapacity`。Agent 按 `pageCapacity` 把根顺序切成页。导入 **不** 修改 `gridLayoutPreset` |
| `items` | 是 | 根网格从左到右、从上到下、跨页连续。与 `launchpadItemOrder` 同构 |
| `items[].type` | 是 | `"app"` 或 `"folder"` |
| `items[].id` | app 必需；folder 可选 | app = `AppInfo.id`；folder **省略** `id` 键则导入时生成 `folder-<UUID>`。出现但为空 / 空白的 id 会被 validate 拒绝 |
| `items[].name` | folder 必需 | **键必须存在**，缺键是 decode 错误（任意模式 exit 2）。键在但 trim 后为空：非 strict → `"文件夹"`；`--strict` → 失败 |
| `items[].apps` | folder 必需 | 文件夹内顺序，元素为 `AppInfo.id`。空数组的文件夹在 reconcile 时丢弃 |
| `hidden` | 否 | 三态：省略键 → 现网 hidden 减去认领的 id（隐式取消隐藏）；`[]` → 整表清空；非空数组 → 替换为解析成功的 id。**导出总是写出该键**（包括 `[]`） |
| `catalog` | 否 | 导出时写入当前扫描结果（含隐藏应用）。导入时 **不作为布局**，只参与解析步骤 3 |

**不要**在文档里写 `customApplicationSourcePaths`。没有这个字段；扫描额外根只从目标域偏好读取。

`LaunchpadLayoutItem.app` 只有 `{ "type": "app", "id" }`。`bundleIdentifier` / `path` 只存在于 `catalog[]`。Folder 的 JSON 键是 `apps`；磁盘 `AppFolder` 键仍是 `appIDs`。

应用主键是 `AppInfo.id`，不是显示名：

- 同一 `bundleIdentifier` 只有一份：`id == bundleIdentifier`
- 多份时，路径字典序最小的那份仍用裸 bundle id；其余为 `bundleIdentifier#standardizedPath`

不要用 `name` 当主键。副本 id 里的 `#` 与绝对路径必须原样复制。

### 示例

下面只说明字段形状。字节稳定、含 Preview 根项与 Foo 副本 catalog 的编码器锁定文档见 [canonical-layout.json](../Tests/QLaunchpadCoreTests/Fixtures/canonical-layout.json)（pretty + sortedKeys；路径写成 `\/`）。

```json
{
  "kind": "qlaunchpad.layout",
  "schemaVersion": 1,
  "items": [
    { "type": "app", "id": "com.apple.Safari" },
    {
      "type": "folder",
      "id": "folder-550e8400-e29b-41d4-a716-446655440000",
      "name": "开发",
      "apps": ["com.apple.dt.Xcode", "com.microsoft.VSCode"]
    }
  ],
  "hidden": ["com.apple.Chess"],
  "grid": { "preset": "6x4-128", "columns": 6, "rows": 4, "pageCapacity": 24 }
}
```

第一页 = `items[0 ..< grid.pageCapacity]`。不要假设 24：`4x2-256` → 8，`5x4-128` → 20，默认 `6x4-128` → 24，`7x5-128` → 35。

## 导出语义

从「当前已 reconcile 的状态」生成文档，而不是直接 dump 原始偏好。

| 字段 | 来源 |
| --- | --- |
| `catalog` | 本次扫描的全部 `AppInfo`（含 hidden） |
| `items` | 根网格：app → `{ type, id }`；folder → `{ type, id, name, apps }` |
| `hidden` | 现网 hidden 排序后的数组；**总是写出该键**（空集也是 `[]`，不会省略） |
| `grid` | **目标偏好域**的 `gridLayoutPreset`；缺省 / 无法识别 → `6x4-128` |

CLI 标志：

- `--no-catalog`：省略 `catalog`。解析步骤 3 不可用；1 / 2 / 4 仍在。
- `--no-paths`：仍导出 `catalog`，但去掉每条 `path`。分享或提交到公共仓库时使用。默认 **带 path**（副本 `id` 本身就嵌着路径）。
- `--pretty` / `--compact`：互斥。写文件默认 pretty + sortedKeys。stdout 且 TTY → pretty；管道 → compact。`--compact` 仍 sortedKeys。
- 无 `--out` → stdout。`--out -` 显式 stdout。

## 导入算法

`--merge` 与 `--replace` **互斥**。缺省 **`--merge`**。只有用户明确说「只要这些图标可见」时才传 `--replace`。`--strict` 正交：只决定「无法解析 / 空 folder 名」时失败还是降级，**不**改变 leftover 是追加还是隐藏。

解析器对每一个引用的 id（根 `items`、folder `apps`、`hidden`）按下列顺序对齐到当前扫描结果。Catalog **绝不**把应用加入网格。

1. 精确匹配 `id`（含 `bundle#path` 副本形式）。
2. 从 id 自身按第一个 `#` 切开，用 `bundleIdentifier + standardizedPath` 匹配。
3. 用同一个 raw id 查 `catalog[]`；若条目含 `bundleIdentifier` + `path`，按标准化路径匹配扫描结果。
4. 该 bundle 在本机只剩一份：取 `#` 前的 bundle 段，或整个 raw id 当 bundle id。
5. 仍失败 → `skippedUnknown`，不写入顺序 / 文件夹 / hidden。

### 单一有序步骤（`LaunchpadLayoutImporter.apply`）

1. `validate(document)`：`kind` / `schemaVersion` / 体积与数量上限 / 重复 id / 嵌套 folder / `items ∩ hidden`。失败 → CLI exit 2。
2. 按上面 1→4 解析每一个引用 id。
3. `--strict`：`skippedUnknown` 非空或任一 **已解码** folder name trim 后为空 → 失败。非 strict：跳过未知 id；键在但空 name → `"文件夹"`。缺 `name` 键在解码阶段已失败，到不了这一步。
4. 用已解析 id 组装 `proposedFolders` / `proposedOrder`。省略 folder `id` 键 → `folder-<UUID>`。出现但为空 / 空白的 id 已在步骤 1 拒绝。若 folder id 与某个 **已扫描** app id 碰撞 → `duplicateID`（这步才对照磁盘，`validate` 看不到）。
5. `claimedIDs` = 根顺序与文件夹里的应用 id。
6. **hidden 三态**（认领优先于「省略则保留」）。导出总是写出 `hidden`，所以「省略键」只在 Agent **删掉该键** 时发生：
   - 省略 `hidden` 键 → `hiddenBaseline = currentHidden − claimedIDs`，`unhiddenByClaim = currentHidden ∩ claimedIDs`（**隐式取消隐藏**）。
   - `hidden: []`（键在、数组空）→ 整表替换为空，现网 hidden 全部取消（`--replace` 仍会把 leftover 藏起来）。
   - `hidden` 为非空数组 → `hiddenBaseline` = 解析成功的 id 整表替换；`items ∩ hidden` 已在步骤 1 拒绝。
7. `leftoverIDs` = 扫描结果中既不在 `claimedIDs`、也不在 `hiddenBaseline` 的 id（排序：`name` `localizedCaseInsensitiveCompare`，再 `path`）。
   - `--merge`（默认）：`finalHidden = hiddenBaseline`；leftover 在 reconcile 时追加到根末尾。
   - `--replace`：先 `finalHidden = hiddenBaseline ∪ leftoverIDs`，再 **一次** reconcile，leftover 不可见。
8. 一次 `LaunchpadLayoutReconciler.reconcile`。空文件夹丢弃；未出现在顺序里的 folder 插在 leftover apps **之前**。
9. 非 `--dry-run`：与磁盘不同才写三键；导入前把当前布局写成单槽备份（fail-open）。写成功后发 `DistributedNotificationCenter` 通知（`object` = 域；`userInfo` 仅诊断：`source` / `schemaVersion`）。**通知里没有布局文档**；已运行 GUI 用 CFPreferences 重读本域后热更新。

| 情况 | `--merge`（默认） | `--replace` | `--strict`（可与二者之一组合） |
| --- | --- | --- | --- |
| JSON 中未知 / 已卸载 app | 跳过并报告 | 同左 | **失败** |
| 本机有、JSON 未提到的可见 app | **追加到根末尾** | **先并入 hidden**，reconcile 后不可见 | 不改变 leftover 策略 |
| JSON 未出现的旧 folder | 删除；未被认领的成员走 leftover | 同左 | 同左 |
| `hidden` 省略 | 现网 hidden **减去** 认领的 id；其余保留 | 同上，再 ∪ leftover | 不因隐式取消隐藏失败 |
| `hidden: []` | 整表清空 | 清空后再 ∪ leftover | 同左 |
| `hidden` 非空 | 整表替换为解析成功的 id | 该表 ∪ leftover | JSON hidden 里有未知 id → 失败 |
| `items` ∩ `hidden` | **拒绝** | **拒绝** | **拒绝** |
| 缺 folder `name` 键 | decode 失败（exit 2） | 同左 | 同左 |
| folder `name` 键在但 trim 后为空 | `"文件夹"` | 同左 | **失败** |
| 省略 folder `id` 键 | 生成 `folder-<UUID>` | 同左 | 允许 |
| folder `id` 出现但为空 / 空白 | validate 拒绝（exit 2） | 同左 | 同左 |

`--dry-run`：跑完校验与合并，打印报告，**不写**偏好、不备份、不发通知。

报告（stdout；`--dry-run` 另有 `wouldWriteDomain`）：

```
imported: 86 items (12 folders, 74 root apps)
resolved: 140 / 142 referenced ids
skippedUnknown: com.old.App, com.gone.Tool
appendedLeftover: com.apple.Freeform
hiddenReplaced: false
unhiddenByClaim: com.apple.Chess
newlyHiddenByReplace: (none)
wouldWriteDomain: com.qzrzz.qlaunchpad.dev
```

正式 import 前，`--dry-run --strict` 的 `skippedUnknown` **必须为空**。

## 校验不变量（`validate`，不扫描磁盘）

`bun run layout:validate` 只跑这一层。编造的 id **会通过**；未知 id 是 `import --strict` / `--dry-run` 的职责。不要只跑 `validate` 就宣布成功。

- `items` 中每个 `id` 至多一次（app 与 folder 共用一个 ID 空间）。
- 任一应用 id 不能同时出现在根 `items` 与某个 folder 的 `apps` 中。
- 任一应用 id 不能属于两个 folder。
- 任一应用 id 不能同时出现在 `items`（含 folder `apps`）与 `hidden`。
- Folder 的 `apps` 不得引用另一个 folder id（禁止嵌套）。
- 文档内部 ID 唯一：folder `id` 若存在，不得与同文件里的 app id / 其它 folder id / `apps` 成员碰撞。与**磁盘扫描结果**里某个 leftover app id 碰撞由 `import` 的 `apply` 在 resolve 之后拒绝，`validate` 看不到。
- 上限：JSON ≤ 5 MiB、`items` ≤ 10_000、folder 数 ≤ 2_000、单 folder 成员 ≤ 500、`name` ≤ 200 标量、catalog ≤ 10_000。
- `id` / folder `apps` / `hidden` / catalog 字符串必须非空（trim 后）且禁止 NUL。folder `name` 允许空白；空白名只在 `import --strict` 失败。

## CLI 形状

```text
QLaunchpad export   [--out <path>|-] [--pretty|--compact]
                    [--no-catalog] [--no-paths]
                    [--domain <bundle-id>] [--dev]
                    [--app <QLaunch.app>]

QLaunchpad import   [--in <path>|-] [--merge|--replace] [--strict] [--dry-run]
                    [--domain <bundle-id>] [--dev]
                    [--app <QLaunch.app>]

QLaunchpad validate [--in <path>|-]
QLaunchpad help
```

- `export` 无 `--out` → stdout。`import` / `validate` 无 `--in` → stdin。
- `--merge` 与 `--replace` 同时出现 → 用法错误（exit 1）。缺省 merge。
- 域解析：`--domain` → `--app` 读 `CFBundleIdentifier` → `--dev`（`com.qzrzz.qlaunchpad.dev`）→ 打包二进制自身的 bundle id → 否则 exit 1。**不得**静默写 Release 域。
- stderr 打印 `usingDomain: …`。人类诊断走 stderr；`--dry-run` 报告走 stdout。JSON 只出现在 export 的 stdout / `--out`。
- 退出码：`0` 成功；`1` 用法（含缺域）；`2` 校验 / strict；`3` IO；`4` 偏好域不可用。

导入前（非 `--dry-run` / `validate`）把当前布局写成单槽备份，失败只警告、不中止：

| 域 | 路径 |
| --- | --- |
| `com.qzrzz.qlaunchpad` | `~/Library/Application Support/QLaunch/layout.backup.json` |
| `com.qzrzz.qlaunchpad.dev` | `~/Library/Application Support/QLaunch Dev/layout.backup.json` |

恢复 = 再导入该 JSON。不要去清任何 icon cache。

分享布局时去掉本机路径：

```sh
bun run layout:export -- --out /tmp/qlaunch-layout.json --no-paths
```

不要把未脱敏（带 `/Users/<name>/…`）的 JSON 提交到公共仓库。

## Agent 工作流

1. `bun run layout:export -- --out /tmp/qlaunch-layout.json`
2. 只改 JSON：按用户意图重排 `items` / 一层 `folder` / 可选 `hidden`。保留 `catalog` 原样。不要改 Swift。
3. `bun run layout:import -- --in /tmp/qlaunch-layout.json --dry-run --strict`，确认 `skippedUnknown` 为空。
4. 默认再跑 `--merge --strict`。用户明确要求「只留这些图标」时才用 `--replace`。
5. 已运行的 GUI 应热更新；不要 `open -a`。

### 提示词模板

~~~~markdown
你正在整理 QLaunchpad 布局。只改 JSON，不要改 Swift。

## 调用方式（必须按此执行，不要发明）

可执行文件名是 QLaunchpad，包在 .app 里：
- Debug: `QLaunch Dev.app/Contents/MacOS/QLaunchpad`
- Release: `QLaunch.app/Contents/MacOS/QLaunchpad`

优先：

```sh
bun run layout:export -- --out /tmp/qlaunch-layout.json
# 编辑该文件
bun run layout:import -- --in /tmp/qlaunch-layout.json --dry-run --strict
bun run layout:import -- --in /tmp/qlaunch-layout.json --merge --strict
```

禁止：
- `open -a QLaunch` / `open -a "QLaunch Dev"`（LSUIElement + reopen 只会开关面板）
- 无 `--domain` / `--dev` / `--app` 的 `swift run QLaunchpad export|import`（会拒绝执行；若绕过域探测则可能写到 Release plist）
- 只跑 `validate` 就宣布成功（`validate` 不扫描磁盘，编造的 id 会通过）

`layout.ts` 会自己找打包二进制。若报「未找到」，先 `bun run dev`。

## JSON 规则

输入：一份 `kind = qlaunchpad.layout`、`schemaVersion = 1` 的文件。
- `catalog`：本机应用。用 `id` 引用，不要用 `name` 当主键。
- `items`：根网格从左到右、从上到下。页大小见 `grid.pageCapacity`（不要假设 24）。
- `hidden`：导出**总是写出该键**（包括 `[]`）。若你要改隐藏集，必须输出完整数组；`[]` 会清空现网 hidden。想走「省略则保留 + 认领即取消隐藏」必须**删掉该键**，不是留着导出来的数组。不要把仍想隐藏的应用放进 `items`。
- 文件夹只有一层。`type: "folder"` 的 `apps` 只能是 catalog 里的应用 id。
- 每个应用 id 在整个文件里只能出现一次（根、某个文件夹、或 hidden，三者互斥）。把已隐藏应用挪到网格：从 `hidden` 数组删掉它并写入 `items`，或省略 `hidden` 并把它写进 `items`（隐式取消隐藏）。
- 保留用户没提到的应用：留在原处，或追加到末尾。不要只为了「干净」塞进 hidden。
- 新文件夹可以省略 `id`。已有文件夹尽量保留原来的 `id`。
- 不要修改 `kind`、`schemaVersion`。`catalog` 原样保留。
- 写回同一路径。不要输出 Markdown 围栏，只要合法 JSON。
- `--dry-run --strict` 报告里 `skippedUnknown` 必须为空再正式 import。用户明确要求「只留这些图标」时才用 `--replace`。

用户意图：
<PASTE USER REQUEST>
~~~~

约束摘要：

- 禁止嵌套文件夹。
- 禁止发明 catalog 里没有的 id。
- 第一页 = `items[0 ..< grid.pageCapacity]`。
- 副本应用的 id 含 `#` 和绝对路径，必须原样复制。
- 禁止 `open -a`。禁止无域标志的裸 `swift run`。
- 必须先 `--dry-run --strict`。默认 `--merge`。仅在用户明确要求时使用 `--replace`。
