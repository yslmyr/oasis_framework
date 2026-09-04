# Oasis IoC/DI 集成设计（自动注入 + 工厂生命周期 + mORMot2 桥接）

- **状态**：📋 设计定稿，待实现
- **日期**：2026-09-05
- **目标 Delphi 版本**：10.4 Sydney 及以上（以 Delphi 13 Florence 编译验证）
- **参考**：本地 mORMot2 checkout（`D:\code\awesome-pascal\mormot2`，注意新版单元已由
  `mormot.svc.*` 更名 `mormot.soa.*`）；Cordis/Koishi 的 `inject` 声明语义；
  Spring4D（仅作可行性参考，Apache-2.0，零拷贝）

---

## 1. 背景与目标

Oasis 已有「GUID 服务注册表 + `AddInject` 声明依赖 + 激活等待/级联去活」，但存在三个缺口：

1. **取服务是拉模式**——插件 `Apply` 里手写 `Ctx.Services.Get(GUID) as IIfc`，
   声明了依赖却拿不到自动填充，样板代码多；
2. **注册表只收实例**——无工厂注册、无懒单例、无 transient 语义，服务必须
   在注册前完全构建好；
3. **mORMot2 的 DI 能力无法参与**——`TInterfaceResolver*`（InjectStub /
   InjectResolver / InjectInstance / RegisterGlobal）与 `TServiceContainer`
   （`AddImplementation` + `sicSingle/sicShared/...` 生命周期 + 构造注入 +
   契约）自成一体，与 Oasis 的 fiber 生命周期、级联去活互不相通。

本期交付三件套（已确认范围）：

- **① 自动注入**（Core，零新依赖）：`[Inject]` 属性标注接口字段，宿主在
  激活时自动解析并填充，对标 Cordis `inject`；
- **② 工厂/生命周期**（Core，零新依赖）：`RegisterFactory`（懒单例）与
  `RegisterTransient`，生命周期归 fiber 管；
- **③ mORMot2 桥接**（可选单元 `Oasis.Mormot`）：双向桥，mORMot 容器作为
  服务源懒映射进 Oasis 注册表；Oasis 注册表亦可反向供 mORMot 解析。

**非目标（YAGNI，明确排除，留作后续）**：Effect Layer 式组合层、构造函数
注入、命名/限定符多实例、装饰器/拦截代理、Spring4D 依赖、Showroom 展示卡
片（另列后续）。

---

## 2. 已锁定的关键决策

| 维度 | 决策 |
|---|---|
| 分层 | **路线 1「三层递进」**：①②进 `Oasis.Core`（零依赖原语），③为可选单元 `Oasis.Mormot`（地位同 `Oasis.Otl` 之于 OTL，但不打成 .dpk，见 §6.4） |
| 注入机制 | **RTTI 自定义属性 `[Inject]` 标注接口字段**，GUID 取自字段声明类型（单一来源，不写两遍） |
| 依赖声明 | `TOasisPlugin.Inject` 基类实现自动合并：手动 `AddInject` ∪ `[Inject]` 字段 GUID——激活等待逻辑零改动 |
| 工厂语义 | `RegisterFactory` = **懒单例**（首次 Get 构建、memoize）；`RegisterTransient` = **每次 Get 新实例**；注册即触发 `OnServiceAdded` |
| 桥主通道 | `TInterfaceResolver.Resolve(PRttiInfo, out Obj)`——`TInterfaceResolverList` / `TInterfaceResolverInjected` / `TServiceContainer` 通吃 |
| mORMot 许可边界 | 桥单元**只 uses、零拷贝**（mORMot2 为 MPL 1.1，Oasis 为 MIT）；桥不进默认构建，build.cmd 检测到本地 mormot2 才编译 |
| `Oasis.Mormot` 形态 | **纯单元、不做 .dpk**：mormot 大量单元级全局状态（TInterfaceFactory 注册表等），编进 BPL 与宿主静态链接并存会复制全局态；宿主静态链接进自身 |
| 单元依赖 | `Oasis.Inject` 只依赖 `Oasis.Types`/`Oasis.Services`（`Populate` 收 `TObject`），**与 `Oasis.Context` 无循环**；`Oasis.Context` 在 implementation 段调用注入器 |

**路线取舍记录**（为什么不是另外两条）：

| 路线 | 否决理由 |
|---|---|
| 全部塞进 `Oasis.Mormot` 桥 | 自动注入/工厂本质是注册表的自然延伸，零依赖可做；绑死 mormot 则不用的用户白丢能力 |
| Core 只做注入，生命周期全委托 mormot `sic*` | 语义分裂：无 mormot 时无工厂能力，桥反而更厚 |

---

## 3. Core 原语①：自动注入 — 新单元 `src/Oasis.Core/Oasis.Inject.pas`

### 3.1 用户视角

```pascal
uses Oasis.Inject;

type
  TConsumerPlugin = class(TOasisPlugin)
  strict private
    [Inject] FGreeting: IGreeting;      // 声明即依赖：激活等待 + 自动填充
    [Inject] FCfg: IOasisConfig;        // 支持 multiple
  public
    constructor Create;
    procedure Apply(const Ctx: IContext); override;
  end;

constructor TConsumerPlugin.Create;
begin
  inherited Create('consumer');
  // 无需 AddInject(IGreeting) —— 字段即声明
end;

procedure TConsumerPlugin.Apply(const Ctx: IContext);
begin
  Writeln(FGreeting.Greet('Delphi'));   // 直接用，不 Get、不 as
  Ctx.Events.On('app/ping', procedure(const A: array of const)
    begin Writeln(FGreeting.Greet('world')) end);
end;
```

### 3.2 API

```pascal
type
  { 标注在接口类型字段上；GUID 取自字段声明类型的 RTTI }
  InjectAttribute = class(TCustomAttribute);

  { 类型化拉取助手（接口不能有泛型方法，故为独立泛型函数）——
    服务于闭包式插件与不愿用字段注入的场合 }
  TOasisDI = record
    class function Need<T>(const ARegistry: IServiceRegistry): T; static;
    class function TryNeed<T>(const ARegistry: IServiceRegistry;
      out AService: T): Boolean; static;
  end;

  { RTTI 扫描/填充/清空器（Populate 接收 TObject，避免与 Oasis.Context 循环） }
  TOasisInjector = class
  public
    class procedure Populate(APlugin: TObject;
      const ARegistry: IServiceRegistry); static;
    class procedure Clear(APlugin: TObject); static;
    class function  FieldGuids(APluginClass: TClass): TArray<TGUID>; static;
  end;
```

- **`Need<T>`** 实现：`GetTypeData(TypeInfo(T))` 取 GUID → `Registry.Get` →
  以 `SysUtils.Supports` 的 **untyped `out` 参数**完成免 `as` 类型化取回
  （Spring4D `ServiceLocator` 同款手法）；取不到抛 `EOasisServiceNotFound`，
  `TryNeed` 返回 False。
- **`FieldGuids`** 按类缓存（首次扫描后存入类级字典，只读并发安全）。

### 3.3 时序与故障语义

| 时机 | 行为 |
|---|---|
| 声明收集 | `TOasisPlugin.Inject` 基类改为：`AddInject` 手动 GUID ∪ `TOasisInjector.FieldGuids(ClassType)`（虚方法重载点保留，子类仍可加逻辑） |
| 填充 | `TContext.MountUnderFreshFiber` 在调用 `APlugin.Apply` **之前**执行 `Populate`（宿主已判定依赖可解析，此处必成功；工厂抛异常除外） |
| 注入失败 | 走现有 Apply 故障隔离：fsFailed + fiber 回滚 + `EV_HOST_PLUGIN_FAILED` |
| 级联去活 | 依赖消失 → 宿主 `Unload(consumer)` → fiber 拆卸后 `Clear` 把 `[Inject]` 字段置 nil（防止持有旧实例） |
| 重新激活 | 再次 `Populate`（幂等；注入前先清空同字段） |
| 闭包插件 | `Plugin(name, TProc<IContext>)` 无插件对象，跳过填充；用 `TOasisDI.Need<T>` |

### 3.4 前提与约束

- 插件类需保留**字段级扩展 RTTI**（Delphi 默认即含私有字段）；用 `{$RTTI}`
  剥离过的类会静默失去注入能力——文档警示。
- `[Inject]` 字段必须是**带 GUID 的接口类型**；否则 `Populate` 抛
  `EOasisInjectError`（新异常类，归 `Oasis.Errors`）。
- BPL 插件同样适用（RTTI 随插件编译，注册表查找跨 BPL 无碍）。

---

## 4. Core 原语②：工厂/生命周期 — 扩展 `Oasis.Services.pas`

### 4.1 API（`IServiceRegistry` 新增两方法）

```pascal
procedure RegisterFactory(const AGUID: TGUID; AFactory: TFunc<IInterface>);
procedure RegisterTransient(const AGUID: TGUID; AFactory: TFunc<IInterface>);
```

### 4.2 语义

| | `RegisterFactory`（懒单例） | `RegisterTransient` |
|---|---|---|
| 首次 `Get`/`Resolve` | 调工厂、memoize、后续返回同实例 | 每次调用都新建 |
| `Has` / 激活等待 | **注册即 True**（`OnServiceAdded` 在注册时触发，pending 消费者照常激活，不等真实构建） | 同左 |
| 工厂抛异常 | `EOasisServiceFactoryError`（新异常类，归 `Oasis.Errors`）；懒单例不 memoize 失败结果，下次重试 | 同左 |
| fiber 归属 | owner 卸载 → 注销注册 + 释放 memo 实例 + 释放工厂闭包 | owner 卸载 → 仅注销注册（实例生命周期 = 消费者引用计数） |
| 覆盖注册 | `AddOrSetValue` 语义与 `Register` 一致 | 同左 |

### 4.3 实现要点

- 内部条目模型：`TServiceEntry = record Kind: (skInstance, skLazySingleton,
  skTransient); Instance: IInterface; Factory: TFunc<IInterface>; end`，
  `FMap: TDictionary<TGUID, TServiceEntry>`（现 `Register` 收敛为 skInstance）。
- **锁纪律**：懒单例按「读锁查 → 无锁调工厂 → 写锁 memoize」双检执行；
  **工厂闭包绝不在持锁状态下调用**（工厂内部可能再 `Resolve` 同一注册表，
  RWLock 升级会死锁）。递归解析同一 GUID（工厂依赖自己）→ 检测活动构建集合，
  抛 `EOasisServiceFactoryError('circular')`。
- fiber 清理沿用 `AddCleanup` 机制：`RemoveIfSame` 语义按「注册条目」比较；
  懒单例尚未构建时清理只摘条目。

### 4.4 兼容性（破坏性变更，显式记录）

- `IServiceRegistry` 增加方法 → 二进制布局变化，**接口 GUID 更新**；
  唯一实现 `TServiceRegistry` 在 Core 内同步更新。
- 既有 BPL 插件（`samples/BplPlugin` 等）需重编；`build.cmd` 全量重编已覆盖。
- 源码级调用方（`Register`/`Get`/`Resolve`/`Has`）零改动。

---

## 5. mORMot2 桥 — 新单元 `src/Oasis.Mormot/Oasis.Mormot.pas`

### 5.1 许可声明（写进单元头注释）

- 本单元为 Oasis（MIT）原始代码，**仅 `uses` mORMot2 单元，零拷贝**
  （mORMot2 为 MPL 1.1；链接依赖合法，MPL 义务随 mORMot2 自身分发由使用
  者承担）。
- 严禁从 mORMot2 拷贝实现进 Oasis 仓库（既定红线，见项目记忆）。

### 5.2 正向桥：mORMot 容器 → Oasis 服务源

```pascal
uses mormot.core.interfaces{, mormot.soa.core 若用 TServiceContainer};

type
  TMormotServicesPlugin = class(TOasisPlugin)
  public
    constructor Create(AResolver: TInterfaceResolver;
      const AInterfaces: array of PRttiInfo);
    procedure Apply(const Ctx: IContext); override;
  end;

// 用法（独立 DI，零 REST 依赖）：
LList := TInterfaceResolverList.Create;
LList.Add(TypeInfo(ICalc), TCalcImpl.Create);        // 共享实例
LList.Add(TypeInfo(IClock), TClockImpl);             // 每次解析新建
Host.Mount(TMormotServicesPlugin.Create(
  LList, [TypeInfo(ICalc), TypeInfo(IClock)]));
Host.Mount(TCalcConsumer.Create);                    // [Inject] FCalc: ICalc;

// 用法（SOA 容器，宿主已有 TRestServer）：
Host.Mount(TMormotServicesPlugin.Create(
  TRestServer.Services, [TypeInfo(ICalc)]));
```

- `Apply` 内：对每个 `PRttiInfo` 取 GUID → `Ctx.Services.RegisterFactory(
  GUID, 解析闭包)`——**复用 §4 懒单例**，首次解析才穿透到 mORMot，
  `sic*` 生命周期完全由 mORMot 容器自管（桥不复制语义）。
- 解析闭包：`AResolver.Resolve(PRttiInfo, LObj)`（`TInterfaceResolver`
  公开方法，三类 resolver 通吃）；返回 False 抛 `EOasisServiceFactoryError`。
- 卸载即级联：桥插件 fiber 拆卸 → 镜像注册全消 → `OnServiceRemoved` →
  Oasis 消费者去活——与现有级联机制零新增代码。
- `AInterfaces` 用 `PRttiInfo` 数组而非 GUID 数组：编译期 `TypeInfo(Ixxx)`
  强类型，且免 `TInterfaceFactory` 的 GUID→RTTI 注册查找依赖。

### 5.3 反向桥：Oasis 注册表 → mORMot 解析源

```pascal
type
  TOasisResolver = class(TInterfaceResolver)
  public
    constructor Create(const ARegistry: IServiceRegistry);
    function TryResolve(aInterface: PRttiInfo; out Obj): Boolean; override;
    function Implements(aInterface: PRttiInfo): Boolean; override;
  end;
```

- `TryResolve`：PRttiInfo 取 GUID → `ARegistry.Resolve(GUID, Obj)`；
  `Implements` → `ARegistry.Has(GUID)`。
- 用途：mORMot 侧 `TInjectableObject` 的 published 接口属性注入、
  `TInterfaceResolverInjected.InjectResolver([TOasisResolver])` 组合，
  让 mORMot DI 图能取到 Oasis fiber 注册的服务。

### 5.4 形态：纯单元、不做 .dpk（决策记录）

mORMot2 大量单元级全局状态（`TInterfaceFactory` 注册表、日志、CRT 全局），
编进 BPL 后与宿主静态链接的 mORMot 并存会得到两份全局态。桥以普通单元
提供，宿主**静态链接**；`src/Oasis.Mormot/` 目录 + `build.cmd` 条件编译
（检测 `mormot.core.interfaces.pas` 是否在本地路径，不在则打印 SKIP）。

---

## 6. 与现有机制的交互核对

| 机制 | 影响 |
|---|---|
| 激活等待（pending queue） | 工厂/桥注册即 `OnServiceAdded`——消费者激活不等真实构建，时序不变 |
| 级联去活 | lazy/transient 条目 `Unregister` 触发 `OnServiceRemoved`，与实例同规则 |
| `Reload(name)` / `Unload(name)` | 插件重挂时字段重填（Populate 先清后填，幂等）；`Clear` 在 fiber 拆卸后调用 |
| `Fork` / 子上下文 | 工厂条目经父链解析（与实例查找同路径），不复制、不预构建 |
| 事件/fiber/Spin | 不触碰 |
| `IOasisConfig` / `IUIInvoker` 等既有服务 | 均为实例注册（skInstance），行为不变 |

---

## 7. 测试计划

### 7.1 `tests/Oasis.DI.Tests.pas`（并入 `Oasis.Tests.dpr`，OTL-free、mormot-free）

1. `[Inject]` 字段在激活后被填充（可直接调用，不 Get）
2. 依赖未就绪时消费者保持 pending；provider 挂载后激活且字段已填
3. `TOasisPlugin.Inject` 合并：手动 `AddInject` ∪ 字段 GUID（混合声明）
4. 级联去活后字段为 nil；provider 回归后重填
5. `[Inject]` 标注非接口字段 / 无 GUID 接口 → `EOasisInjectError`
6. 闭包插件 + `TOasisDI.Need<T>` / `TryNeed<T>` 取回类型正确
7. `RegisterFactory` 懒单例：只构建一次、后续同实例（构建计数）
8. `RegisterFactory` 注册即 `Has=True` 且 pending 消费者激活
9. `RegisterTransient`：每次 `Get` 新实例（构建计数 ≥ 2）
10. 工厂抛异常 → `EOasisServiceFactoryError`；懒单例失败不 memoize，重试成功
11. 工厂递归自解析 → circular 错误（不死锁）
12. fiber 卸载：工厂条目注销、memo 实例与闭包释放（`ReportMemoryLeaksOnShutdown`）
13. 覆盖注册（同 GUID 二次 Register/Factory）为最新者，旧 cleanup 不误删新条目

### 7.2 `tests/mormot/Oasis.Mormot.Tests.dpr`（独立 runner，仿 `tests/otl`）

1. `TInterfaceResolverList` 共享实例镜像 → Oasis 消费者 `[Inject]` 可用
2. transient 类注册（`Add(TypeInfo, 类)`）镜像 → 每次解析新实例
3. 桥插件 `Unload` → 镜像注册消失 → 消费者级联去活
4. `TOasisResolver` 反向：`TInterfaceResolverInjected.InjectResolver` 组合
   能解析到 Oasis fiber 注册的服务
5. 解析失败（resolver 无此接口）→ `EOasisServiceFactoryError`
6. 内存泄漏检查（mormot 容器由桥持有并释放）

缺 mormot2 路径时 runner 构建脚本整体 SKIP（`build.cmd` 打印提示），
不算失败。

---

## 8. 交付物清单

| 项 | 内容 |
|---|---|
| `src/Oasis.Core/Oasis.Inject.pas` | InjectAttribute / TOasisInjector / TOasisDI；并入 `Oasis.Core.dpk` |
| `src/Oasis.Core/Oasis.Services.pas` | 条目模型 + RegisterFactory/RegisterTransient；`IServiceRegistry` GUID 更新 |
| `src/Oasis.Core/Oasis.Context.pas` | `TPluginEntry` 增加 `Plugin: IPlugin` 字段（IPlugin 重载记录之，闭包重载为 nil）；填充在 `MountUnderFreshFiber` 调 Apply 前执行，fiber 拆卸路径对 `Entry.Plugin <> nil` 调 `Clear`（implementation 段 uses Oasis.Inject） |
| `src/Oasis.Core/Oasis.Plugin.pas` | `TOasisPlugin.Inject` 合并实现 |
| `src/Oasis.Core/Oasis.Errors.pas` | `EOasisInjectError`、`EOasisServiceFactoryError` |
| `src/Oasis.Mormot/Oasis.Mormot.pas` | TMormotServicesPlugin + TOasisResolver（含许可头注释） |
| `tests/Oasis.DI.Tests.pas` | §7.1 用例，并入 Oasis.Tests.dpr（预期 44+13 → 57 项全绿） |
| `tests/mormot/` | §7.2 独立 runner |
| `demos/MormotBridgeDemo/` | ConsoleDemo 风格：独立 resolver 镜像 + 消费者 + 卸载级联 + 反向桥演示 |
| `build.cmd` | mormot 条件编译分支；README 增 DI 章节与 Status 行 |

---

## 9. 风险与缓解

| 风险 | 缓解 |
|---|---|
| **RTTI 写接口字段**（`TRttiField.SetValue` 需要 TValue 与字段接口 TypeInfo 精确匹配） | Spring4D 与 mORMot 均解决过同题，可行性无虞；实现第一步先做编译验证（TDD 首测）；必要时自写 ~15 行 TValue 构造助手（**自研，不抄 MPL/Apache 代码**） |
| 插件类被 `{$RTTI}` 剥离字段信息 → 注入静默失效 | `Populate` 对「有 `[Inject]` 字段标记但类型无 GUID」报错；文档警示；扫描不到字段是合法情况（闭包插件同路径） |
| `IServiceRegistry` 破坏性变更 | 唯一实现在 Core；GUID 更新；BPL 插件随 build.cmd 全量重编 |
| mORMot2 新旧单元名双轨（svc/soa） | 以本机新版 `mormot.soa.*` 为准；桥仅在 uses 处出现单元名，写清最低版本要求（README 注明） |
| 懒单例工厂持锁调用 → 死锁 | §4.3 锁纪律 + 用例 11 覆盖 |
| mormot 全局态跨 BPL 复制 | §5.4 纯单元静态链接决策 |

---

## 10. 后续（非本期）

- VclShowroom 增加「DI/桥接」展示卡片
- Effect Layer 式组合层（若将来有测试替换的强需求）
- 构造函数注入、命名实例、装饰器
- 桥的 SOA 高级特性透出（契约校验、服务方法级权限）
