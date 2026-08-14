# Oasis 插件框架设计（Cordis 理念的 Delphi 实现）

- **状态**：草案待评审
- **日期**：2026-08-14
- **目标 Delphi 版本**：10.4 Sydney 及以上
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

## 11. 分阶段路线图

- **MVP（本期 + 首个实现计划）**：`Oasis.Core` 全部 + `Oasis.Hosting`（`TInProcPluginLoader` + `THost`）。同步事件、上下文树、可逆副作用、GUID 服务注册表、进程内插件。**交付即可跑的 demo。**
- **二期**：`Oasis.Otl`——把 `parallel`/异步 `serial` 接到 OTL，`IEventBus` 升级为异步可 await。
- **三期**：`Oasis.Bpl`——`IPluginLoader` 的 BPL 实现 + 导出函数 ABI 契约。
- **远期（reload）**：`Context.Reload`——销毁全部副作用 + 重新挂载。

---

## 12. 明确排除（YAGNI 留作后续评估）

- 跨语言插件（DLL + C ABI 导出）
- Spring4D 硬依赖（可选后续集成，不进 MVP）
- 字段级 `[Inject(GUID)]` 特性注入（二期增强）
- `Context.Reload` 热重载（远期）
- UI 线程 marshaling 桥（远期 `Oasis.UI`）
- 强类型 `On<TPayload>` 事件泛型变体（二期增强）

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
