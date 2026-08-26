# Oasis 插件框架设计（Cordis 理念的 Delphi 实现）

- **状态**：✅ **已全部实现并发布**（v0.2.0）——MVP、二期（Otl）、三期（Bpl）、四期（Reload）及评估路线图全部特性均已交付；各阶段实现细化见 §13–§17。测试 42 项全绿，仓库 https://github.com/yslmyr/oasis_framework
- **日期**：2026-08-14（设计定稿与实现同日完成）
- **目标 Delphi 版本**：10.4 Sydney 及以上（实际以 Delphi 13 Florence 编译验证）
- **参考**：[Cordis](https://github.com/cordiverse/cordis)、[Cordis Primer](https://deepseek-harness.github.io/deepseek-harness/reference/cordis-primer)

---

## 1. 背景与目标

借鉴 Cordis（DeepSeek Harness 使用的插件框架）的设计理念，用 Delphi 实现一个插件框架 **Oasis**。Cordis 的核心思想是：

- **Context** 是服务的容器，且构成一棵上下文树；
- **Plugin** 是在上下文中运行、声明依赖、返回清理逻辑的模块；
- **注册即副作用、且可逆**——任何 `on()`/`effect()` 都有对应的 disposer，teardown 时自动逆序撤销；
- **Service** 按键查询，依赖注入由声明驱动而非手动编排启动序；
- **事件**支持 emit / parallel / serial / waterfall 四种分发；
- **生命周期**：mount →（reload）→ teardown，与上下文绑定。

**Oasis 的目标**：把上述思想以 Delphi 惯用法落地——用接口引用计数 + LIFO 销毁栈实现"可逆副作用"，用 GUID 接口注册表实现强类型服务，用 OmniThreadLibrary 实现异步事件分发，用可插拔加载器抽象实现"内核进程内、外部模块可动态加载"。

**非目标（YAGNI，明确排除）**：跨语言插件、UI 框架绑定、远程插件、Spring4D 硬依赖、声明合并式的编译期事件类型。

---

## 2. 已锁定的关键决策

| 维度 | 决策 |
|---|---|
| 加载模型 | **内核进程内 + 可插拔加载器**（`IPluginLoader` 抽象，首发 `TInProcPluginLoader`，三期 `TBplPluginLoader`） |
| 并发模型 | **OmniThreadLibrary** 作为异步主干（二期接入） |
| 服务索引 | **接口类型 + GUID 注册表**（强类型 DI） |
| 生命周期 | **挂载 + 销毁**（逆序副作用释放）；热重载（reload）留作远期 |
| Delphi 版本 | **10.4 Sydney+** |
| 总体方案 | **方案 A：分层 SPI，分阶段交付** |
| 命名 | **`Oasis.*` 单元 + 传统 `T`/`I` 类型前缀** |

---

## 3. Cordis → Delphi 映射

| Cordis (JS) | Oasis (Delphi) | 理由 |
|---|---|---|
| GC 自动回收 | 接口引用计数 + `IEffectScope` LIFO 销毁 | 无 GC，但接口 refcount + try/finally 契合"可逆副作用" |
| 动态属性 `ctx.tools` | `IServiceRegistry` 按 GUID 查询 `Ctx.Services.Get<ITools>` | 强类型、编译期安全 |
| Promise / async | OmniThreadLibrary `IOmniFuture` | 已选 OTL 作并发主干 |
| 声明合并做类型化事件 | `TEventKey`（字符串名）+ 开放数组 payload | Delphi 无声明合并 |
| 模块 `require` 动态加载 | `IPluginLoader`（in-proc 首发，BPL 三期） | 已选可插拔加载器 |
| `ctx.effect()`/`ctx.on()` 返回 disposer | `IEffectScope.Add(...)` + 自动逆序销毁 | 可逆副作用核心 |

---

## 4. 架构与包布局

```
┌─────────────────────────────────────────────────┐
│  应用层 (Demo / 宿主程序)                        │
└───────────────┬─────────────────────────────────┘
                │
┌───────────────▼─────────────────────────────────┐
│  Oasis.Hosting   (THost, IPluginLoader, 编目/编排)│
└──────┬───────────────────┬───────────────────────┘
       │                   │
┌──────▼───────┐   ┌───────▼────────┐
│  Oasis.Bpl   │   │  Oasis.Otl     │  ← 可选桥接包
│ (三期)        │   │ (二期)          │
└──────┬───────┘   └───────┬────────┘
       │                   │
       └────────┬──────────┘
                │
┌───────────────▼─────────────────────────────────┐
│  Oasis.Core  (IContext / Effects / Services /    │
│               Events / IPlugin)                  │
│  ← 零三方依赖, 可独立编译运行                      │
└─────────────────────────────────────────────────┘
```

**核心约束**：`Oasis.Core` 零三方依赖，可单独编译运行（同步事件即可工作）。`Oasis.Otl` 与 `Oasis.Bpl` 是 Core 之上的**可选**桥接包。没有它们，框架以纯进程内同步模式运行，保证 MVP 极简、依赖可选。

**依赖方向**：`Hosting → Core`；`Otl → Core`；`Bpl → Core`。

### 单元划分

| 包 | 单元 | 职责 |
|---|---|---|
| **Oasis.Core** | `Oasis.Types` | 共享类型：`TDisposer`、`TEffectFn`、handler 引用 |
| | `Oasis.Errors` | `EOasisError` 异常层级 |
| | `Oasis.Effects` | `IEffectScope` + `TEffectScope`（LIFO 销毁栈） |
| | `Oasis.Context` | `IContext` + `TContext`（上下文树、Fork、生命周期） |
| | `Oasis.Services` | `IServiceRegistry`（GUID 注册/查询/依赖声明） |
| | `Oasis.Events` | `IEventBus`：emit/serial/waterfall（同步）+ On 注册 |
| | `Oasis.Plugin` | `IPlugin`、`TPluginDescriptor` |
| **Oasis.Hosting** | `Oasis.Loader` | `IPluginLoader` 抽象 + `TInProcPluginLoader` |
| | `Oasis.Host` | `THost`：编目、依赖排序、挂载/销毁编排 |
| **Oasis.Otl**（二期） | `Oasis.OtlEvents` | OTL `IOmniFuture` 实现的 parallel/serial 异步分发 |
| **Oasis.Bpl**（三期） | `Oasis.BplLoader` | `TBplPluginLoader`：BPL 包加载与导出函数契约 |

---

## 5. 核心机制

### 5.1 上下文树（`Oasis.Context`）

```pascal
IContext = interface
  ['{...}']
  function  Parent: IContext;
  function  IsActive: Boolean;
  function  Fork: IContext;          // 子上下文（继承服务链，独立副作用作用域）
  procedure Dispose;                 // 销毁自身 + 全部后代

  function  Effects:  IEffectScope;
  function  Services: IServiceRegistry;
  function  Events:   IEventBus;

  procedure Plugin(const AApply: TProc<IContext>); overload;  // 闭包插件
  procedure Plugin(const APlugin: IPlugin);     overload;     // 类插件
  procedure Effect(const AEffect: TEffectFn);                 // Effects.Add 的便捷转发
end;
```

**语义：**

- **`Fork`** 创建子上下文，挂到父的 `FChildren`。子继承父的服务链（查询向上走），但拥有**独立的** `IEffectScope`、`IServiceRegistry` 本地表、`IEventBus` 订阅。
- **`Plugin(...)` = Fork + 在子上下文里跑**。每个插件天然隔离在自己的子上下文里——插件 A 的副作用与插件 B 互不干扰，销毁时各自独立释放。`THost` 挂载插件即调用 `RootContext.Plugin(...)`。
- **`Dispose` 顺序**（严格逆序，对应 Cordis teardown）：
  1. 若已销毁 → 直接返回（幂等）
  2. `FActive := False`
  3. 逆序销毁所有**子上下文**（LIFO：后挂的先销毁）
  4. 销毁自己的 `IEffectScope`（逆序调用每个 cleanup）
  5. 清空 `IServiceRegistry` 本地表（释放接口引用）
  6. 从父的 `FChildren` 摘除自己

```
        Root (THost 创建)
       /    |    \
     P1     P2    P3      ← 每个插件一个子上下文
    /  \           \
  P1a  P1b         P3a
  销毁: Root.Dispose → P3(→P3a) → P2 → P1(→P1b →P1a)，深度优先 + 兄弟逆序
```

- **线程模型**：上下文树按**单线程拥有**设计（典型在主线程或某 worker 线程内操作一棵树）。`IServiceRegistry` 与 `IEffectScope` 的**结构变更加锁**（`TCriticalSection`），使跨线程注册副作用安全。二期接入 OTL 后明确"事件分发的同步 vs 异步线程"边界。

### 5.2 可逆副作用（`Oasis.Effects`）

Cordis 的灵魂："注册是可逆的副作用"——任何 `on()`/`effect()` 都有对应的 disposer，teardown 时自动逆序撤销。

```pascal
type
  TDisposer = reference to procedure;            // 清理函数（无参无返回）
  TEffectFn = reference to function: TDisposer;  // 执行副作用，返回其清理函数

  IEffectScope = interface
    ['{...}']
    function  IsActive: Boolean;

    // Cordis 风格：跑 AEffect，把它返回的 disposer 压栈
    function  Add(const AEffect: TEffectFn): TDisposer;

    // 已自行执行副作用，只登记清理函数
    function  AddCleanup(const ACleanup: TDisposer): TDisposer;

    // 登记 IInterface 生命周期对象（销毁时自动释放引用）
    procedure AddDisposable(const AObj: IInterface);

    procedure Dispose;   // 逆序 LIFO 调用全部 cleanup
  end;
```

**语义：**

- **LIFO 销毁栈**：`Add` 把 disposer 压栈，`Dispose` 从栈顶逆序弹出执行——保证"后注册的先撤销"，依赖序正确（如先取消订阅再关连接）。
- **`Add` 返回 disposer**：调用方可**提前手动销毁**该副作用（从栈移除并执行），不必等整体 teardown。
- **cleanup 抛异常不阻断**：某个 cleanup 抛异常时捕获、记录到 `EOasisDisposeError`（聚合全部失败项），**继续执行剩余 cleanup**——绝不让一个插件失败导致资源泄漏。`Dispose` 结束后若有聚合错误再 raise。
- **幂等**：重复 `Dispose` 安全。

用法对照 Cordis：

```pascal
// Cordis:  ctx.effect(() => { subscribe(); return () => unsubscribe(); })
// Oasis:
Ctx.Effect(
  function: TDisposer
  begin
    Tools.OnChange(Handler);
    Result := procedure begin Tools.OffChange(Handler); end;
  end);
```

### 5.3 服务注册表（`Oasis.Services`）

GUID 键 + 接口类型强类型查询。对应 Cordis 的 `ctx.tools` 动态属性。

```pascal
type
  EOasisServiceNotFound = class(EOasisError);

  IServiceRegistry = interface
    ['{...}']
    procedure Register<T: IInterface>(const AInstance: T); overload;
    procedure Register(const AGUID: TGUID; const AInstance: IInterface); overload;

    // 查询：先查本地表，未命中则沿 Parent 链向上（子覆盖父）
    function  Resolve<T: IInterface>(out AInstance: T): Boolean;
    function  Get<T: IInterface>: T;          // 缺失则 raise EOasisServiceNotFound
    function  Has(const AGUID: TGUID): Boolean;

    function  Require(const AGUID: TGUID): IServiceRegistry;  // 依赖声明，返回 Self 便于链式
  end;
```

**语义：**

- **父子链查询**：`Resolve` 本地表命中即返回；否则递归 `Parent.Services`。子上下文注册同名 GUID **覆盖**父的（shadowing）。
- **注册即作用域**：服务引用由本上下文表持有；上下文 `Dispose` 时清表自动释放。无需单独 cleanup（但服务需要自定义释放时可再 `Ctx.Effects.AddCleanup(...)`）。
- **依赖声明 + 自动激活**（对应 Cordis "加载顺序由服务依赖表达"）：
  - 插件 `IPlugin.Inject: TArray<TGUID>` 声明所需服务。
  - `THost` 挂载时先做**拓扑排序**（按 dep 关系定序）；无法满足的依赖，插件进入**待激活队列**。
  - 注册表每次 `Register` 后触发内部 `__service_added__` 事件 → 重扫待激活队列，依赖已齐则立即激活。复刻 Cordis "插件在依赖就绪时才启动"。
- **类型安全**：`Register<T: IInterface>`/`Get<T: IInterface>` 利用泛型约束，`T` 必须是接口；GUID 取自 `T`（约定每个服务接口带 `['{guid}']`）。

```pascal
type
  ITools = interface(IInterface)
    ['{...ITools GUID...}']
    procedure DoSomething;
  end;

// 插件消费
var Tools: ITools := Ctx.Services.Get<ITools>;
```

---

## 6. 事件、插件契约、加载器与 Host

### 6.1 事件系统（`Oasis.Events`）

```pascal
type
  TEventKey = type string;

  TEventHandler      = reference to procedure(const AArgs: array of const);
  TWaterfallNext     = reference to procedure(const AArgs: array of const);
  TWaterfallHandler  = reference to procedure(const AArgs: array of const;
                                             const ANext: TWaterfallNext);
  IEventBus = interface
    ['{...}']
    function On(const AKey: TEventKey; const AHandler: TEventHandler): TDisposer; overload;
    function OnWaterfall(const AKey: TEventKey;
                         const AHandler: TWaterfallHandler): TDisposer; overload;

    procedure Emit     (const AKey: TEventKey; const AArgs: array of const);
    procedure Serial   (const AKey: TEventKey; const AArgs: array of const);
    procedure Waterfall(const AKey: TEventKey; const AArgs: array of const);
    // Parallel → Oasis.Otl 二期
  end;
```

**语义：**

- **注册即作用域**：`On()` 内部把"退订"挂到 `Ctx.Effects`——上下文 Dispose 自动退订。返回的 `TDisposer` 允许**提前手动退订**（移出订阅表并执行）。对应 Cordis `ctx.on()` 可逆。
- **waterfall 短路**：监听器收 `(Args, Next)`；调 `Next(Args)` 推进下游，不调则链终止（"策略监听器拥有决策权"）。
- **监听器隔离（容错）**：emit/serial 中**单个监听器抛异常**被捕获、记录、**继续执行后续监听器**，分发结束后若有聚合错误再 raise `EOasisEventError`。waterfall 中监听器抛异常则**中止链**并聚合抛出。
- **类型化事件约定**：在共享单元声明事件键常量；payload 用 `array of const`（开放数组）；二期可加 `On<TPayload>` 强类型泛型变体。

```pascal
const EV_TOOLS_CHANGED: TEventKey = 'tools.changed';
```

### 6.2 并发与 OTL（`Oasis.Otl`，二期——此处只定契约）

`Oasis.Core` 的 `IEventBus` 是同步的、可独立工作。`Oasis.Otl` 在其上**扩展**，不重写注册：

```pascal
// Oasis.Otl 二期
type
  TAsyncEventHandler = reference to function(const AArgs: array of const): IOmniFuture;

  IAsyncEventBus = interface(IEventBus)   // 继承同步版，复用同一订阅表
    ['{...}']
    function OnAsync(const AKey: TEventKey;
                     const AHandler: TAsyncEventHandler): TDisposer;
    function Parallel(const AKey: TEventKey;
                      const AArgs: array of const): IOmniFuture;
    function SerialAsync(const AKey: TEventKey;
                         const AArgs: array of const): IOmniFuture;
  end;
```

**设计要点（保证 Core 不返工）：**

- **订阅表共享**：`IEventBus` 内部存储已为"可扩展多种 handler 类型"设计——二期加 `OnAsync` 时同一张表增加异步槽，不改 Core 接口。
- **能力探测**：应用用 `Supports(Ctx.Events, IAsyncEventBus)` 判断是否可用并行。
- **线程边界**：异步监听器在 OTL 线程池执行；结果回到调用线程是应用的职责（UI 上下文 marshaling 留作远期 `Oasis.UI` 桥）。MVP 文档明确"同步事件在派发线程执行"。

### 6.3 插件契约与创作（`Oasis.Plugin`）

```pascal
type
  IPlugin = interface
    ['{...}']
    function Name: string;
    function Inject: TArray<TGUID>;                 // 声明的服务依赖
    function Apply(const Ctx: IContext): TDisposer;  // 在子上下文里跑，返回可选顶层清理
  end;
```

**两种创作方式（对应 Cordis 的 function 插件与 class 插件）：**

```pascal
// (1) 类插件
type
  TToolsPlugin = class(TInterfacedObject, IPlugin)
    function Name: string;
    function Inject: TArray<TGUID>;   // Result := [];
    function Apply(const Ctx: IContext): TDisposer;
  end;

// (2) 闭包插件（无依赖、无元数据时最简洁）
Host.Mount(procedure(const C: IContext)
  begin
    C.Events.On(EV_APP_START,
      procedure(const A: array of const)
      begin Log('started') end);
  end);
```

**返回的 disposer 与 Effects 统一：** `Apply` 返回的顶层 disposer 由 `Plugin()` 实现自动 `Ctx.Effects.AddCleanup(...)`——**两套清理统一为一套 LIFO 销毁机制**，避免分裂。插件在 `Apply` 内部还能继续用 `Ctx.Effects.Add(...)` 注册细粒度副作用。

**依赖声明（MVP）**：仅支持 `Inject: TArray<TGUID>` 方法（显式）。字段级 `[Inject(GUID)]` 特性 + RTTI 自动注入（Spring4D 风格）作为二期增强。

```pascal
function TLoggerPlugin.Inject: TArray<TGUID>;
begin
  Result := TArray<TGUID>.Create(GUID_OF(IConfig));   // 声明依赖 IConfig
end;
```

### 6.4 加载器抽象与 Host（`Oasis.Hosting`）

```pascal
type
  TPluginFactory = reference to function: IPlugin;

  IPluginLoader = interface
    ['{...}']
    function   Kind: string;                                  // 'inproc' | 'bpl' | 'dll'
    function   Load(const ASource: string): TPluginFactory;   // 解析来源，返回构造工厂
    procedure  Unload(const AFactory: TPluginFactory);        // 释放模块资源
  end;

  TInProcPluginLoader = class(TInterfacedObject, IPluginLoader)
    procedure Register(const AName: string; AClass: TInterfacedClass);  // 启动期登记插件类
    // Load('Tools') → 构造 TToolsPlugin 实例的工厂
  end;
```

```pascal
type
  THost = class
    constructor Create;
    function  Root: IContext;
    procedure Use(const ALoader: IPluginLoader);
    procedure Mount(const APlugin: IPlugin); overload;
    procedure Mount(const ASource: string); overload;
    procedure Start;                                  // 依赖解析：拓扑排序 + 待激活队列 + 重扫
    procedure Shutdown;                               // Root.Dispose（全树逆序销毁）
  end;
```

**`THost.Start` 依赖激活流程：**

```
Start():
  1. 收集全部已挂载插件的 (Descriptor, Context)
  2. 按依赖（Inject 的 GUID）做拓扑排序 → 得到初始激活序
  3. 依序尝试激活：检查每个 Inject 的 GUID 在 Root 服务链是否可 Resolve
       ├─ 全部可解析 → 立即跑 Apply（注册其服务/副作用）
       └─ 有缺失     → 进入 PendingQueue
  4. 注册表每次 Register(GUID, ...) → 触发重扫 PendingQueue：
       重检每个待激活插件的依赖；齐了就激活，并可能连锁解锁下游
  5. 全部就绪 → EventBus 发 EV_HOST_STARTED
```

**生命周期事件**（挂在 Root 的 EventBus 上，插件可订阅）：`EV_HOST_STARTING` → `EV_HOST_STARTED` → `EV_HOST_STOPPING` → `EV_HOST_STOPPED`，外加任意时刻可触发的 `EV_HOST_PLUGIN_FAILED`（插件激活失败时上报，payload 含插件名 + 异常）。

```pascal
type
  THost = class
    // ...（同上）
    function FailedPlugins: TArray<string>;   // Start 后可检查失败插件名
  end;
```

**加载器路由约定**：`THost` 维护一个 `Kind → IPluginLoader` 表。`ASource` 采用 `'<kind>:<name>'` 形式（如 `'inproc:Tools'`、`'bpl:foo.bpl'`）。`Mount(ASource)` 按 `kind:` 前缀选 loader；无前缀时默认走第一个 `Use` 注册的 loader。每个 loader 的 `Kind` 字符串即此前缀（`'inproc'`/`'bpl'`/`'dll'`），未识别的 kind 抛 `EOasisLoaderError`。

**`Start` 对插件失败的处理（故障隔离）**：`Start` **绝不因单个插件失败而中止**——失败的插件逆序销毁其子上下文、记入 `THost.FailedPlugins`、经 `EV_HOST_PLUGIN_FAILED` 事件上报（payload 含插件名 + 异常），其余插件继续激活。`Start` 正常返回后，应用可检查 `FailedPlugins` 决定是否容错运行；需要 fail-fast 的应用订阅该事件自行抛出。

**MVP 加载器** = `TInProcPluginLoader`：插件是编译进主程序的类，启动期 `Register('Tools', TToolsPlugin)` 登记。`Load('Tools')` 返回构造工厂。**零动态加载，整个框架可独立跑通、可 demo**。三期 `TBplPluginLoader` 实现同一 `IPluginLoader` 契约，替换即获得真动态加载——上层 Host/Context 零改动。

---

## 7. 错误处理与故障隔离

### 7.1 异常层级

```pascal
EOasisError                  // 基类
  EOasisServiceNotFound      // Get<T> 缺失
  EOasisDependencyCycle      // 拓扑排序检测到环
  EOasisPluginActivateError  // 插件 Apply 抛异常（带插件名 + 内层异常）
  EOasisDisposeError         // 聚合的 cleanup 失败（带 TList<Exception>）
  EOasisEventError           // 聚合的监听器失败
  EOasisLoaderError          // 加载器解析/卸载失败
```

### 7.2 统一的故障隔离原则

> **销毁/分发绝不因首个错误中止——尽力完成全部清理后再抛聚合异常，最大化资源释放。**

| 场景 | 行为 |
|---|---|
| Effect cleanup 抛异常 | 捕获、记录、**继续其余 cleanup**，最后聚合抛 `EOasisDisposeError` |
| 事件监听器抛异常 | 捕获、记录、**继续后续监听器**，最后聚合抛 `EOasisEventError`；waterfall 则中止链 |
| 插件 `Apply` 抛异常 | **逆序销毁该插件子上下文**（回滚已注册副作用）、标记失败、**继续挂载其余插件**；失败经生命周期事件上报 |
| 子上下文销毁失败 | 记录、**继续销毁兄弟**，不让一个死插件拖垮整树 |
| 服务缺失 | `Get<T>` 抛 `EOasisServiceNotFound`；`Resolve<T>` 返回 `False` |

---

## 8. 工程结构

```
oasis-framework/
├── README.md
├── LICENSE
├── docs/superpowers/specs/2026-08-14-oasis-plugin-framework-design.md
├── src/
│   ├── Oasis.Core/                 ← MVP，零三方依赖
│   │   ├── Oasis.Core.dpk
│   │   ├── Oasis.Types.pas         (TDisposer / TEffectFn / handler 引用 / GUID 常量)
│   │   ├── Oasis.Errors.pas        (异常层级)
│   │   ├── Oasis.Effects.pas       (IEffectScope / TEffectScope)
│   │   ├── Oasis.Context.pas       (IContext / TContext)
│   │   ├── Oasis.Services.pas      (IServiceRegistry)
│   │   ├── Oasis.Events.pas        (IEventBus：emit/serial/waterfall)
│   │   └── Oasis.Plugin.pas        (IPlugin / TPluginDescriptor)
│   ├── Oasis.Hosting/              ← MVP
│   │   ├── Oasis.Hosting.dpk
│   │   ├── Oasis.Loader.pas        (IPluginLoader + TInProcPluginLoader)
│   │   └── Oasis.Host.pas          (THost)
│   ├── Oasis.Otl/                  ← 二期
│   │   ├── Oasis.Otl.dpk
│   │   └── Oasis.OtlEvents.pas     (IAsyncEventBus：parallel/serialAsync)
│   └── Oasis.Bpl/                  ← 三期
│       ├── Oasis.Bpl.dpk
│       └── Oasis.BplLoader.pas     (TBplPluginLoader)
├── tests/                          (DUnitX)
│   ├── Oasis.Tests.dpr
│   ├── Oasis.Effects.Tests.pas
│   ├── Oasis.Context.Tests.pas
│   ├── Oasis.Services.Tests.pas
│   ├── Oasis.Events.Tests.pas
│   └── Oasis.Hosting.Tests.pas
└── demos/
    └── ConsoleDemo/                ← MVP 可跑 demo
        ├── ConsoleDemo.dpr
        └── (3 个示例进程内插件：Config → Logger → App，含依赖链 + 事件)
```

- **包格式**：`Oasis.*.dpk`（runtime 包），消费者按需引用。Core 是其余包的唯一基础依赖。
- **测试框架**：DUnitX（10.4+ 自带）。
- **依赖方向**：`Hosting → Core`；`Otl → Core`；`Bpl → Core`。Core 测试无需 OTL。

---

## 9. MVP 验收标准

MVP = `Oasis.Core` + `Oasis.Hosting`（`TInProcPluginLoader` + `THost`）。全部满足即完成：

1. **上下文树**：`Fork` 建子；`Dispose` 逆序销毁自身+后代且幂等。
2. **副作用**：`Add`/`AddCleanup` LIFO；`Dispose` 逆序全跑；某个 cleanup 抛异常不阻断其余（聚合 `EOasisDisposeError`）；支持手动提前销毁。
3. **服务**：`Register<T>`/`Get<T>`/`Resolve<T>`；父子链查询；子覆盖父；缺失 `Get` 抛 `EOasisServiceNotFound`。
4. **依赖激活**：拓扑排序 + 待激活队列 + 注册触发重扫——依赖后挂载的插件自动激活。
5. **事件**：`On` 在上下文销毁时自动退订；`Emit`/`Serial`/`Waterfall` 可用；监听器隔离；waterfall 短路。
6. **插件创作**：类插件与闭包插件均可挂载；`Apply` 返回的 disposer 自动并入 Effects。
7. **Host**：`Start`/`Shutdown` 完整；生命周期事件依序触发；`Shutdown` 全树释放。
8. **Console demo 可运行**：3 个进程内插件（Config → Logger → App 依赖链）、事件通信、干净关闭。

---

## 10. 测试策略

- **每单元一组 DUnitX 测试**，重点覆盖**行为契约**而非实现：
  - 销毁顺序（断言后注册的 cleanup 先跑）
  - 故障隔离（注入会抛异常的 cleanup/监听器/插件 → 断言其余仍执行 + 正确聚合异常抛出）——每条隔离规则一个专测
  - 父子链 shadowing
  - 依赖激活时序（依赖后到场的插件何时被激活）
  - `Dispose` 幂等性
- **demo 兼作集成冒烟测试**。
- 二期 OTL 测试需引入 OTL；三期 BPL 测试需构造真实 `.bpl`。

---

## 11. 分阶段路线图（全部已完成）

- **MVP** ✅：`Oasis.Core` 全部 + `Oasis.Hosting`（`TInProcPluginLoader` + `THost`）。同步事件、上下文树、可逆副作用、GUID 服务注册表、进程内插件。交付即可跑的 demo。——已实现（§9 验收标准全部满足）
- **二期** ✅：`Oasis.Otl`——`Parallel`/`SerialAsync` 接入 OTL。——已实现，细化见 §13
- **三期** ✅：`Oasis.Bpl`——`IPluginLoader` 的 BPL 实现（工厂契约）。——已实现，细化见 §14
- **四期（原"远期 reload"）** ✅：`Context.Reload` + 单插件 `Reload(name)`/`Unload(name)`。——已实现，细化见 §15、§16
- **评估路线图** ✅：依赖失效级联、JSON 配置（含 env 分层/类型化）、UI marshaling 桥。——已实现，细化见 §16、§17

---

## 12. 明确排除（YAGNI）——截至 v0.2.0 的状态

- 跨语言插件（DLL + C ABI 导出）——**仍未做**（保留排除）
- Spring4D 硬依赖——**仍未做**（保留排除；框架保持零三方依赖）
- 字段级 `[Inject(GUID)]` 特性注入——**仍未做**（保留排除）
- ~~`Context.Reload` 热重载（远期）~~——**已实现**（§15/§16）
- ~~UI 线程 marshaling 桥（远期 `Oasis.UI`）~~——**已实现**（§17）
- 强类型 `On<TPayload>` 事件泛型变体——**仍未做**（保留排除）

---

## 13. 二期实现笔记（Phase 2 — `Oasis.Otl`，已实现）

二期按 §6.2 契约落地，遇到 OTL/Delphi 现实时做了如下细化（与 MVP 同样的"spec 遇现实"模式）：

| §6.2 契约 | 实际实现 | 原因 |
|---|---|---|
| `TAsyncEventHandler = reference to function(args): IOmniFuture` | `reference to procedure(args)` | OTL 的 `IOmniFuture<T>` 是**泛型**的；强制监听器返回 future 既难用又难组合。框架自己在 `MakeFuture` 里把每个监听器包进 `Parallel.Future<string>`，监听器只须是个普通过程。 |
| `Parallel / SerialAsync: IOmniFuture` | 返回 `Integer`（运行数），阻塞至全部完成 | OTL 无非泛型 `IOmniFuture`，且对 N 个 future 做 "join" 组合子不便。Parallel 用 fork-join（先并发 `Parallel.Future<string>` 全部启动，再逐个 `.Value` 等待）；并发性体现在**监听器并发执行**（这正是 Cordis parallel 的价值）。非阻塞 `IOmniFuture<Integer>` 变体留作后续。 |
| "订阅表共享" | `TAsyncEventBus` **继承** `TEventBus`（复用同步 On/Emit/Serial/Waterfall + token 自动退订），另加独立的异步监听器表 | 同步与异步监听器分属不同分发（Emit 只跑同步、Parallel 只跑异步），分表即可；继承避免重写同步逻辑（DRY）。 |
| `Supports(Ctx.Events, IAsyncEventBus)` | `TContext` 增加类级可插拔 `TEventBusFactory`（默认 nil → `TEventBus`，Core 零依赖不变）；`OasisRegisterAsyncEventBus` 安装 `TAsyncEventBus` 为默认 | Core 不能引用 OTL；用工厂钩子让上层（应用）在启动期一次性安装。安装后新建的 `TContext`（含 `Fork`）的事件总线即 `IAsyncEventBus`。 |

故障隔离与生命周期沿用同步总线：每个监听器在 future 内 try/except，异常以错误消息返回，Parallel 汇总后抛 `EOasisEventError`；`OnAsync` 用 token 自动退订，注册产生 bus↔owner-scope 引用环，由 `Dispose` 断开。验证：`tests/otl/Oasis.Otl.Tests.dpr` 6/6（含上下文集成）；`demos/OtlDemo` 5 监听器跑在 5 个不同工作线程，证明真实并发。

---

## 14. 三期实现笔记（Phase 3 — `Oasis.Bpl`，已实现）

三期按 §6.4 落地 `TBplPluginLoader`（同一 `IPluginLoader` 契约，`Kind='bpl'`，`Host.Mount('bpl:<path>')` 路由），上层 Host/Context 零改动。遇 Delphi/BPL 现实做了如下细化：

| §6.4 契约 / 设想 | 实际实现 | 原因 |
|---|---|---|
| BPL 用 `exports` 导出 `OasisCreatePlugin` | 改为 **`RegisterClassAlias` + `FindClass`** 工厂对象 | Delphi **包不支持 `exports` 子句**（编译报 E2029）。改用：插件包在 `initialization` 节用 `RegisterClassAlias(TMyFactory, OASIS_BPL_FACTORY_CLASS)` 注册一个 `TOasisPluginFactory`（`TInterfacedPersistent`——既被 `RegisterClass` 接受、又被接口引用计数管理）；宿主 `LoadPackage` 后 `FindClass(...)` 取到、用 `Supports(.., IOasisPluginFactory)` 拿到工厂接口。这依赖**宿主与 BPL 共享 `rtl.bpl` 的全局类表**——所以宿主 EXE 必须用 `-LUrtl` 编译。 |
| 接口跨边界 | 宿主与 BPL **各自静态含一份 `Oasis.Context`**，但 `IPlugin`/`IContext` 按 GUID + vtable 派发（同源编译→vtable 布局一致），跨边界安全。 | 避免把 Oasis.Core 也做成运行期包（部署更重）。 |
| `Unload` 释放模块 | `TBplPluginLoader.Destroy` **不调用 `UnloadPackage`**（仅释放工厂闭包）；BPL 随进程退出回收。`Unload(factory)` 保留给显式卸载。 | 运行期 `UnloadPackage` 很脆弱：插件/工厂对象的析构仍引用 BPL 代码，卸载顺序不当会触发访问冲突（实测 runtime error 216）。进程退出回收是安全默认。 |

**宿主构建要求**：`dcc32 -LUrtl`（共享 rtl.bpl），运行期 `rtl.bpl` 须在 PATH。一个副作用：`-LUrtl` 下控制台 stdout 可能被静默丢弃，故 `BplDemo` 同时把结果写入 `bpldemo_out.txt`。

**验证**：`samples/BplPlugin/SamplePlugin.bpl`（注册 `IGreeting` 服务）；`demos/BplDemo` 加载它并解析服务 → `bpldemo_out.txt` 输出 `Hello from BPL, world` / `Pending: 0  Failed: 0`，进程退出码 0、无访问冲突。

---

## 15. 四期实现笔记（Phase 4 — `Context.Reload`，已实现）

原 spec 把 reload 列为"远期、评估中"。现按"销毁全部副作用 + 重新挂载"落地为**上下文级** `IContext.Reload`：

```
Reload():
  1. 快照全部已挂载插件的 (Apply, Returned, Fiber)
  2. 逆序销毁各 fiber（回卷其 Effects）
  3. 销毁上下文级 effect 作用域（同时移除所有事件监听——On() 的自动退订挂在这里）
  4. 重建上下文作用域，并 SetOwnerScope 把总线拥有者改指向新作用域
  5. 对每个插件重新跑 Apply（在新 fiber 上重新注册 effect/监听/服务）
```

**为支持 reload 做的改动：**
- `IEventBus.SetOwnerScope(scope)`（virtual）：reload 重建上下文作用域后，用它把总线拥有者改指向新作用域，使重新注册的监听挂到新作用域。`TAsyncEventBus` 覆写它以同时更新异步监听的 owner。
- `TContext` 用 `TPluginEntry(Apply, Returned, Fiber)` 列表替代原先的 fiber 列表，使 reload 能重新调用每个插件的挂载动作。

**细化与范围（文档化）：**
- **上下文级** reload（非单插件）。单插件级 reload 需要 fiber 可寻址（按名/句柄），留作后续。
- **服务**：重新 Apply 时 `AddOrSetValue` 覆盖旧实例；**不做依赖失效级联**（某插件撤回服务时不会自动停用其消费者）。完整级联（service-added/removed 事件驱动激活/停用）是更后续的工作。
- **children (Fork)**：reload 不递归子上下文。

**验证**：`Oasis.Context.Tests` 新增 `Reload_Re_Runs_And_Tears_Down_Effects_And_Listeners`——reload 后 Apply 计数翻倍、effect 被逆序清理、事件监听未被重复（emit 仅 +1）。MVP 26/26、OTL 6/6 全绿。

---

## 16. 评估路线图实现笔记（per-plugin reload / 依赖级联 / JSON 配置，已实现）

对四项评估特性按建议顺序推进：#1 → #2 → #4 已实现合并；#3（UI marshaling）按评估结论**暂缓**（无 GUI 目标场景）。

### #1 单插件级 Reload(name)

- 监听器归属修正：`MountUnderFreshFiber` 在 Apply 期间把事件总线 owner 指向该 fiber（`SetOwnerScope(fiber)`），结束后还原。销毁单个 fiber 即精确移除该插件的监听——单插件 unload/reload 从"只有全量销毁才正确"变为普遍正确。
- `TPluginEntry` 增加 `Name`；`IContext/TContext` 增加 `Reload(name): Boolean`（按名定位→销毁 fiber→重挂）与 `Unload(name): Boolean`（销毁并移除，不重挂）。

### #2 依赖失效级联

- `Oasis.Services`：`Unregister(GUID)`（触发 `OnServiceRemoved`）、`SetOwnerScope`、注册时向 owner scope 挂自动注销 cleanup——闭包捕获**注册时的实例**，`RemoveIfSame` 保证只移除仍是自己那一条（不误删后来者的覆盖）。
- `Oasis.Context`：Apply 期间服务注册表 owner 同样指向 fiber（与总线对称）；provider 卸载/重载自动注销其服务。
- `Oasis.Host`：`FActive` 跟踪已激活插件；`OnServiceRemoved` 把 Inject 了该 GUID 的已激活插件停用（`Unload`→其服务再注销→处理器重入形成更深层级联）并回挂 pending；依赖回归时经既有 rescan 自动再激活。停用路径在 teardown 期间有 `FStarted` 守卫。
- 级联测试：provider 卸载 → 消费者 cleanup 执行 + 回队 + 服务消失；provider 重挂 → 消费者自动再激活。

### #4 配置加载器（JSON，cordis.yml 式）

- `Oasis.Config`：`IOasisConfig`（`Disabled`/`Value`/`HasValue`）+ `TJsonConfigPlugin`。schema：`{"plugins":{"<name>":{"disabled":bool,"config":{k:v}}}}`。用 `System.JSON`（RTL，不引 YAML 三方依赖）；v1 值为字符串；缺文件在 Apply 抛 `EOasisConfigError`——在 Context 故障隔离下表现为"服务未注册 + 消费者停在 pending"（可见，不会带默认值静默运行，测试锁定该语义）。
- `THost.TryMount(plugin): Boolean`：注册了 `IOasisConfig` 且该插件 `disabled` 时返回 False 并跳过挂载（cordis.yml `disabled` 语义）。

### 验证汇总

MVP **32/32**（新增：Reload_By_Name×2、级联、配置×3）、OTL 6/6，0 泄漏。

### 剩余（未做，已评估）

- **#3 UI marshaling 桥**：暂缓。无 GUI 目标场景；实现成本低（本质 `TThread.Queue` 封装），需要时按 spec §6.2 线程边界一节建立 `Oasis.UI` 可选包即可。
- 配置分层/覆盖（base + 环境特定）、非字符串值绑定。

---

## 17. 收尾特性实现笔记（UI marshaling 桥 + 配置分层/类型化，已实现）

按用户指示把上节"剩余"两项落地（#3 不再暂缓）。

### #3 UI marshaling 桥（`Oasis.UI`）

- **`IUIInvoker`**（GUID `{9999...0009}`）：`Queue(TProc)`（异步，立即返回）/ `Sync(TProc)`（阻塞至完成）/ `MainThreadID`（创建时捕获的挂载线程 id）。
- **实现纯 RTL**：`TThread.Queue(nil, ...)` / `TThread.Synchronize(nil, ...)`——不引用 Vcl.Forms/FMX.Types，**同一包同时服务 VCL 与 FMX** 宿主；运行期要求主线程泵 `CheckSynchronize`（VCL/FMX 的 `Application.Run` 自带；控制台宿主需自行周期调用）。
- **`TUIInvokerPlugin`**：把 `IUIInvoker` 注册为服务，消费者照常 `Inject`。排队中的闭包由接口引用计数持有，teardown 时残留项内存安全。
- **验证**：`Oasis.UI.Tests`（主套件，无 OTL 依赖）——工作线程发起 `Queue`/`Sync`，断言闭包在挂载线程执行且 `Sync` 阻塞语义成立（主线程泵等待循环）。36/36。

### #4b 配置分层覆盖 + 类型化取值（`Oasis.Config` 扩展）

- **env 分层**：schema 增加 `"env": { "<name>": { "plugins": {...} } } }`；`TJsonConfigPlugin.Create(path, env)` 把该层**叠在** base 之上：`disabled` 显式覆盖（双向），`config` 键逐个覆盖，未提及的 base 键保留（cordis.yml 覆盖语义）。env 名不存在则抛 `EOasisConfigError`（fail loud）。加载失败路径补了 `LImpl` 释放（防泄漏）。
- **类型化读取**：`Int`/`Bool`/`Float`——存 JSON 文本、读时解析，缺失或不可解析回退默认值（`Bool` 对 `true/false` 大小写不敏感）。
- **验证**：`Env_Layer_Overrides_Base_Without_Erasing_It`（覆盖/保留/env-only 插件/无 env 时 base 完整）、`Typed_Readers_Int_Bool_Float_With_Fallbacks`（命中/缺失/不可解析 × 三类型）。36/36。

### 验证汇总

主套件 **36/36**（新增 UI×2 + 配置×2），OTL 6/6，0 泄漏；`build.cmd` 纳入 `Oasis.UI.dpk` 一键构建 ALL GREEN。

---

## 18. VCL 宿主 Demo（Windows 应用插件管理系统，已实现）

针对"demo 全是控制台、框架作为 Windows app 插件管理系统的能力没有体现"的反馈，补 GUI 落点：

**`demos/VclHostDemo`（HostApp.exe）**——插件管理器主窗口：
- 左：插件列表（名称/状态 active|PENDING|FAILED）；右：插件贡献的 Tab 页；底部：事件日志
- 工具栏：Add Settings / Add Clock / Add Greet / Load BPL... / Reload selected / Unload selected

**展示的框架能力（UI 可视化）：**
1. **插件贡献 UI**：宿主只注册 `IViewHost` 服务（增删 Tab）；插件 `Apply` 中 `ViewHost.Add(self)` + `Effects.AddCleanup(Remove)` —— "可逆副作用"作用于 UI：卸载/级联/重载时插件 Tab 自动消失与回归。
2. **依赖级联可视化**：卸载 Settings → Greet 列表变 PENDING、其 Tab 消失；重挂 → 自动复活。
3. **`IUIInvoker` marshaling**：Clock 插件后台线程经 `Queue` 刷新 UI；闭包捕获 refcounted label-sink（接口），卸载后仍在队列中的更新是安全 no-op（防 dangling 控件）。
4. **BPL 动态加载带 UI**：`samples/VclBplPlugin`（requires rtl/vcl/Oasis.Core）运行期从磁盘加载，给活着的 Windows 应用加一个 Tab。
5. **单插件 Reload/Unload**：选中列表项按钮操作。

**`/selftest` 无头端到端验证**（写 `vclhost_selftest.txt`，exit 0）：
`views:4 → after-unload:pending=1,views=2 → after-remount:pending=0,views=4`。

**实现要点（Delphi/VCL 现实）：**
- 匿名方法不能赋给 `TNotifyEvent`（OnCliick/OnChange）→ 用小类 override（`TPrefixEdit.Change`、`TGreetView.GreetClick`）。
- 宿主 `-LUrtl -LUvcl`（共享 rtl370/vcl370 运行时包）；运行期 PATH 需 `rtl370.bpl`/`vcl370.bpl`/`Oasis.Core.bpl`（或复制到 exe 旁）。
- 缺 `Oasis.Core.bpl` 时二次异常会触发 VCL 模态错误框（无头环境即挂起）→ selftest 包 try/except 兜底写 `EXCEPTION:` 后退出。
- `build.cmd` 纳入宿主与 VCL BPL 插件构建，ALL GREEN。

---

## 19. 性能改造笔记（借鉴 mORMot2 模式，已实现）

针对三大热路径（事件分发 / 服务查询 / 副作用栈），借鉴 mORMot2 的并发基础设施模式（**自研实现**，保持 MIT；未复制其 MPL 源码）：

### 实现

1. **`Oasis.Spin`（新单元）**：`TOasisSpinLock`（互斥自旋，`TInterlocked.CompareExchange` + `SwitchToThread` 让步，4 字节）与 `TOasisRWSpinLock`（多读单写，位 0=写、高位=读计数）。对应 mORMot2 的 `TLightLock`/`TRWLightLock` 思路；仅适用于"几个 CPU 周期"的临界区，非重入。
2. **事件总线（`Oasis.Events` / `Oasis.OtlEvents`）**：监听器改为**按事件键的不可变动态数组**（copy-on-write）。分发（Emit/Waterfall/Parallel）在短自旋锁下**拷出数组引用**（动态数组赋值=原子引用计数递增，零分配），随后**无锁遍历**——局部引用保证快照存活。注册/退订仅在变更时重建该键数组。锁从 `TCriticalSection`（内核对象）换成 `TOasisSpinLock`（用户态）。
3. **服务注册表（`Oasis.Services`）**：读多写少（每次 `Get`/`Inject` 解析 vs 挂载期注册）——`Resolve`/`Has` 走 `TOasisRWSpinLock` **读锁（并发不互斥）**；`Register`/`Unregister`/setter 走写锁。
4. **副作用栈（`Oasis.Effects`）**：`TCriticalSection` → `TOasisSpinLock`（临界区仅 push/pop/claim 几条指令；用户 cleanup 依然在**锁外**执行）。

### 微基准（`tests/OasisBench.dpr`，2M ops，同机同 flag `-$O+`）

| 路径 | 改造前（main） | 改造后 | 提升 |
|---|---|---|---|
| Emit（1 监听器） | 2.55M ops/s | **9.3M ops/s** | **3.6×** |
| Emit（0 监听器） | 13.9M ops/s | 12.2M ops/s | 持平（本就无分配，剩字符串哈希查字典） |
| Resolve（命中） | 16.0M ops/s | **17.2M ops/s** | +8% |
| On（分散键 ×200k） | 2.25M ops/s | 1.06M ops/s | **回归 ~2×**（见权衡） |

### 权衡（文档化）

- **同一键上海量追加是 O(n²)**：copy-on-write 每次追加重建数组。插件框架实际场景每键监听器是个位数（分发热路径），该权衡正确；若未来需要海量同键注册，可加"批量提交"API。
- **Waterfall 每次调用有一次小分配**（args 拷入 `TArray<TVarRec>`，开放数组不可被闭包捕获——Delphi 语言限制，重构为类方法递归 + 堆状态对象后引入）。
- 顺手修复：`On`/`OnWaterfall` 退订闭包此前捕获裸 `Self`（潜伏 use-after-free），改为捕获 `IEventBus` 接口引用（与 `OnAsync` 既有模式一致，环由 `Dispose` 断开）。

---

## 20. 补齐三项未实现功能（bail / 强类型事件 / fiber 状态机，已实现）

对照 Cordis 完整版审计出的 3 个缺口，全部落地：

### #1 `bail` 派发模式（Cordis 完整版第五种模式）

- `Oasis.Types`：`TBailHandler = reference to function(args): TValue` + `OasisIsTruthy`（Cordis 真值语义：非空、非 False、非 nil 对象/接口）。
- `IEventBus.OnBail(event, handler)` + `Bail(event, args): TValue`：按注册顺序跑 bail 监听器，**首个真值返回胜出并停止链**；全假返回 `TValue.Empty`；沿 fork 链冒泡。复用不可变监听数组（lkBail 槽位）与 token 自动退订。

### #2 强类型 `On<TPayload>`（spec §12 原排除项）

- 总线新增 `OnValue(event, TValueHandler)` / `EmitValue(event, TValue)`（TValue 载荷槽位，lkValue）。
- `Oasis.TypedEvents` 单元：`TOasisEvent<TPayload>` 泛型记录——`Subscribe(bus, TProc<TPayload>)` / `Emit(bus, TPayload)`，在 API 边界做 TValue 装箱/拆箱，**两端编译期类型安全**（Delphi 接口不能有泛型方法，故为记录包装而非接口方法）。监听器隔离/自动退订/冒泡全部继承自底层总线。支持 TValue 可承载的一切（int/float/string/enum/record/class/interface）。

### #3 fiber 状态机显式暴露

- `Oasis.Types`：`TFiberState = (fsPending, fsLoading, fsActive, fsUnloading, fsFailed, fsDisposed)`。
- `TContext.PluginState(name)`：`TPluginEntry` 增加 `State` 字段；挂载前登记（fsLoading）→ 成功 fsActive / 失败 **fsFailed（条目保留、Fiber=nil，可查询）**；Dispose/Unload 期间 fsUnloading；未挂载/已移除 → fsDisposed；Reload 重挂后回到 fsActive。
- `THost.PluginState(name)`：跨两层——依赖未满足的插件是 Host 级 **fsPending**（待激活队列），其余委托 root context。
- 附带行为变更：失败插件的条目不再丢弃（此前 PluginState 无从查询失败者）；Context.Dispose 跳过已回滚的 nil fiber。

### 验证

主套件 **44/44**（新增 8 项：bail×3 —— 真值胜出停止链 / 全假返回 Empty / 冒泡；typed×2 —— record 载荷往返 / 作用域销毁自动退订；states×3 —— active→failed→disposed 全程 / Host pending / reload 回 active），OTL 6/6，`build.cmd` ALL GREEN。

---

## 21. Waterfall 委托返回后祖先帧复跑（真 Bug，已修复）

`demos/VclShowroom`（Cordis 架构优势展示间）的无头自检用调用计数器量化各派发模式语义，捕获到一个测试套件此前未曾覆盖的真实缺陷：

**现象**：三段中间件 `m1→Next→m2(否决)` 时，监听器执行次数为 `[1,2,0]` —— m2 被跑了两次。

**根因**（`Oasis.Events.TEventBus.WaterfallRun`）：短路保护 `if not LCalledNext then Exit` 只覆盖"本帧的监听器没有调用 Next"。当本帧监听器**委托**了 Next（递归进子帧处理后续链路）后正常返回，父帧会继续推进自己的 while 循环，把自己之后的所有中间件再从头跑一遍——每层祖先帧重复一次。

**修复**：`TEventBus.WaterfallRun` 中，凡 waterfall 监听器执行完毕一律 `Exit`：要么它调用了 Next（剩余链路已在子帧递归完毕），要么它否决（链就此截止）。两种合法语义下的结果不变；仅消除病态复跑。验证：主套件 44/44、OTL 6/6 不回归；Showroom 自检计数断言 `[1,1,0]`。

