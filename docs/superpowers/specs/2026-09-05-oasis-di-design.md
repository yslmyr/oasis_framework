# Oasis IoC/DI 集成设计（自动注入 + 工厂生命周期 + mORMot2 桥接）

- **状态**：📋 设计定稿 **v3**（二轮对抗审查修订版），待实现
- **日期**：2026-09-05（v1 设计定稿并提交；同日对抗审查后出 v2）
- **目标 Delphi 版本**：10.4 Sydney 及以上（以 Delphi 13 Florence 编译验证）
- **参考**：本地 mORMot2 checkout（`D:\code\awesome-pascal\mormot2`，注意新版单元已由
  `mormot.svc.*` 更名 `mormot.soa.*`）；Cordis/Koishi 的 `inject` 声明语义；
  Spring4D（仅作可行性参考，Apache-2.0，零拷贝）
- **修订记录**：v1 = commit `ed1f19e`。v2 = commit `875d557`，依据一轮对抗审查
  （源码取证 + 5 轮 dcc32 编译证明，见附录 A）修订：`Has`/`DepsSatisfied`
  语义（F1）、注入实现锁定为已验证配方（F2）、桥所有权（F3）、Clear 改为
  fiber cleanup（F4，撤销 v1 的 `TPluginEntry.Plugin` 方案）、闭包捕获纪律
  （F5）、并发双检语义（F6）、mORMot 约束（F7）。v3 依据二轮对抗审查修订：
  **桥引用计数所有权**（N1——正向闭包「接收即接管」，反向接口赋值，两侧
  分写）、**工厂失败 × 消费者 fsFailed 失效模式与恢复路径文档化**（N2）、
  `Inject` 合并结果惰性缓存（N3）、同实例多挂约束（N4）、Supports 失配
  用例（N5）；新增证据 V9（清理顺序契约由 Effects 实现坐实）、V10（继承
  字段注入可行，rttiproof6）。

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
| 注入实现 | **已编译验证的配方**（附录 A.3）：`Supports(QI 换指针)` + `RTTI Offset` 引用计数写入；**TValue/SetValue 路径已裁决不可行**（附录 A.1），禁止裸拷贝接口指针（附录 A.2） |
| 依赖声明 | `TOasisPlugin.Inject` 基类实现自动合并：手动 `AddInject` ∪ `[Inject]` 字段 GUID——激活等待逻辑零改动 |
| 字段清理 | **Clear 注册为 fiber cleanup**（wrapper 闭包内、`AddDisposable` 之后、`Populate` 之前注册）——失败回滚/级联/Reload/Dispose 四条拆卸路径一次覆盖；**不新增 `TPluginEntry.Plugin` 字段**（v2 撤销 v1 方案） |
| 工厂语义 | `RegisterFactory` = **懒单例**（首次 `Get`/`Resolve` 构建、memoize，**依赖判定不构建**）；`RegisterTransient` = **每次 Get 新实例**；注册即触发 `OnServiceAdded` |
| Has 语义 | **`Has` 重定义为注册条目存在性检查**（含父链、绝不调用工厂）；**`THost.DepsSatisfied` 改用 `Has`**——现实现 `DepsSatisfied` 用 `Resolve`、`Has` 是 `Resolve` 别名（附录 A.8），不改则懒单例的「懒」在依赖判定时即被击穿 |
| 桥主通道 | `TInterfaceResolver.Resolve(PRttiInfo, out Obj)`——`TInterfaceResolverList` / `TInterfaceResolverInjected` / `TServiceContainer` 通吃 |
| 桥所有权 | `TMormotServicesPlugin.Create(..., AOwnsResolver: Boolean = False)`——独立 `TInterfaceResolverList` 传 True；`TRestServer.Services` 等外部所有场景保持 False |
| 桥引用计数 | mORMot `Resolve` 约定「返回已 `_AddRef` 一次、调用者接管」（附录 A.11）——正向闭包**接收即接管、原样返回**（`IInterface` 局部变量直收 untyped out，全程禁止接口/指针中转转换）；反向 `TOasisResolver` 用接口赋值写 untyped out，天然对齐；两侧**必须分写** |
| mORMot 许可边界 | 桥单元**只 uses、零拷贝**（mORMot2 为 MPL 1.1，Oasis 为 MIT）；桥不进默认构建，build.cmd 检测到本地 mormot2 才编译 |
| `Oasis.Mormot` 形态 | **纯单元、不做 .dpk**：mormot 大量单元级全局状态（TInterfaceFactory 注册表等），编进 BPL 与宿主静态链接并存会复制全局态；宿主静态链接进自身 |
| 单元依赖 | `Oasis.Inject` 只依赖 `Oasis.Types`/`Oasis.Services`/`Oasis.Errors`（`Populate` 收 `TObject`），**与 `Oasis.Context` 无循环**；`Oasis.Context` 在 implementation 段调用注入器 |

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

### 3.2 API 与实现规范（配方已验证，见附录 A）

```pascal
type
  { 标注在接口类型字段上；GUID 取自字段声明类型的 RTTI }
  InjectAttribute = class(TCustomAttribute);

  { 类型化拉取助手。必须是 record/class 静态方法：dpr 全局泛型函数不合法
    （E2530，附录 A.6）。接口不能有泛型方法，故独立成类型。 }
  TOasisDI = record
    class function Need<T>(const ARegistry: IServiceRegistry): T; static;
    class function TryNeed<T>(const ARegistry: IServiceRegistry;
      out AService: T): Boolean; static;
  end;

  { RTTI 扫描/填充/清空器（Populate 收 TObject，避免与 Oasis.Context 循环；
    IPlugin → TObject 用 `as TObject` 提取，已验证（附录 A.5）。 }
  TOasisInjector = class
  public
    class procedure Populate(APlugin: TObject;
      const ARegistry: IServiceRegistry); static;
    class procedure Clear(APlugin: TObject); static;
    class function  FieldGuids(APluginClass: TClass): TArray<TGUID>; static;
  end;
```

**`Populate` 的字段写入配方**（对每个 `[Inject]` 且接口类型的字段）：

```pascal
{ 1. QI 换出与字段类型对应的接口条目指针（绝不裸拷贝，见附录 A.2） }
if not Supports(LInst, LFieldGuid, LConv) then
  raise EOasisInjectError.CreateFmt(...);
{ 2. 引用计数 offset 写入（TRttiField.Offset 与真实布局一致，附录 A.7） }
PIInterface(PByte(APlugin) + LField.Offset)^ := LConv;
```

- **禁止** `TValue.From + TRttiField.SetValue`：运行时 EInvalidCast（附录 A.1）。
- **禁止**编译期重类型/裸指针拷贝（`IGreeter(IInterfaceVar)` 不做 QI，异接口
  vtable 条目指针进字段后调用即跳废地址，附录 A.2）。
- `Clear` 用同一 offset 路径写 nil（`_Release` 旧值）。
- **`Need<T>`** 实现：`GetTypeData(TypeInfo(T))` 取 GUID → `Registry.Get` →
  `SysUtils.Supports` 的 untyped out 完成类型化取回（已验证，附录 A.5）；
  取不到抛 `EOasisServiceNotFound`，`TryNeed` 返回 False。
- **`FieldGuids`** 按类缓存（首次扫描后存入类级字典；**初始化需加锁**——
  两个线程并发首次挂载不同插件类时无锁写入字典会竞态）。
  `TRttiType.GetFields` **含继承层级字段**（基类与派生类一次返回、offset 各自
  正确，已实测 rttiproof6，附录 A.10）——插件基类可声明公共 `[Inject]` 字段，
  扫描无需逐层遍历。

### 3.3 时序与故障语义（v2 重写：清理走 fiber cleanup）

`TContext.Plugin(APlugin)` 的 wrapper 闭包改造为（v1 仅 `AddDisposable` + `Apply`）：

```pascal
procedure TContext.Plugin(APlugin: IPlugin);
var
  LPlugin: IPlugin;
  LObj: TObject;
begin
  LPlugin := APlugin;
  LObj := LPlugin as TObject;         { 已验证（附录 A.5）；聚合实现不支持，文档注明 }
  MountUnderFreshFiber(APlugin.PluginName,
    procedure(C: IContext)
    begin
      C.Effects.AddDisposable(LPlugin);            { 注册序 1 → 执行序末：插件对象最后释放 }
      C.Effects.AddCleanup(procedure begin TOasisInjector.Clear(LObj) end);
        { 注册序 2 → 执行序倒数第二：用户 cleanup 之后、插件释放之前清空字段。
          清理顺序是本设计的契约：用户清理(仍可用字段) → Clear → 释放插件对象。
          契约已由实现坐实：AddDisposable 即 AddCleanup 包装、共用同一 LIFO 栈
          （Oasis.Effects.pas:154-157，附录 A.9） }
      TOasisInjector.Populate(LObj, C.Services);   { Apply 前填充；失败即抛 }
      LPlugin.Apply(C);
    end, nil);
end;
```

| 时机 | 行为 |
|---|---|
| 声明收集 | `TOasisPlugin.Inject` 基类改为：`AddInject` 手动 GUID ∪ `TOasisInjector.FieldGuids(ClassType)`（虚方法重载点保留，子类仍可加逻辑）。**合并结果在基类内惰性缓存**（v3/N3）——`DepsSatisfied` 每次 rescan（每次服务注册）对每个插件调 `Inject`，不缓存则 O(插件数×注册数) 次数组合并分配；`AddInject` 仅构造期调用，缓存无失效问题 |
| 填充 | wrapper 闭包内、`Apply` 之前（依赖判定已由 `DepsSatisfied`→`Has` 完成，不触发构建） |
| 注入失败 | `Populate` 抛 `EOasisInjectError` → 走现有 `MountUnderFreshFiber` 故障隔离（fsFailed + fiber 回滚 + `EV_HOST_PLUGIN_FAILED`）；**回滚 Dispose 会执行已注册的 Clear cleanup，已填字段全部清 nil** |
| 四条拆卸路径 | 失败回滚 / 级联去活（`Unload`）/ `Reload(name)` / `Reload`/`Dispose`——全部经由 `fiber.Dispose` 的 LIFO cleanup：**用户清理（仍可用字段）→ Clear → 释放插件对象**，一次注册全覆盖 |
| 重新激活 | 新 fiber、重新 `Populate`（幂等：offset 写入天然覆盖旧值） |
| 闭包插件 | `Plugin(name, TProc<IContext>)` 无插件对象，跳过填充；用 `TOasisDI.Need<T>` |

### 3.4 前提与约束

- 插件类需保留**字段级扩展 RTTI**（Delphi 默认即含 strict private 字段，
  已验证，附录 A.4）；用 `{$RTTI}` 剥离过的类会静默失去注入能力——文档警示。
- `[Inject]` 字段必须是**带 GUID 的接口类型**；否则 `Populate` 抛
  `EOasisInjectError`（新异常类，归 `Oasis.Errors`）。
- BPL 插件同样适用（RTTI 随插件编译，注册表查找跨 BPL 无碍）。
- **同一插件实例挂载多次（多名字/多 fiber）与字段注入不兼容**（v3/N4）：
  任一 fiber 卸载执行 Clear 会清掉**同一对象的同一批字段**，其余 fiber 的
  Apply 假设失效。文档约束：字段注入插件每实例至多挂载一次；需要多实例请
  多次 `Create`（框架现状本就不鼓励同实例重复挂载）。

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
| `Has` / 激活等待 | **注册即 True**；`Has` 为条目存在性检查（**绝不调工厂**，见 §4.3）；`OnServiceAdded` 注册时触发，pending 消费者照常激活，**依赖判定不构建** | 同左 |
| 工厂抛异常 | `EOasisServiceFactoryError`（新异常类，归 `Oasis.Errors`）；懒单例不 memoize 失败结果，下次重试 | 同左 |
| fiber 归属 | owner 卸载 → 注销注册 + 释放 memo 实例 + 释放工厂闭包 | owner 卸载 → 仅注销注册（实例生命周期 = 消费者引用计数） |
| 覆盖注册 | `AddOrSetValue` 语义与 `Register` 一致 | 同左 |

**transient × `[Inject]` 字段的语义**：`Populate` 每字段做一次 `Resolve`——
transient 服务在插件**每次 Apply（激活/重激活）获得一个新实例**并持有到该
fiber 拆卸；不是「字段每次访问都换」。文档明示。

**工厂构建失败的消费者侧失效模式（v3/N2 文档化）**：构建被推迟到
`Populate`（依赖判定不构建），首次真实构建发生在 fiber 内。工厂抛
`EOasisServiceFactoryError` 时消费者回滚为 fsFailed——而
`THost.RescanPending` 的失败路径只记 `FailedPlugins`、**不 requeue**
（Host.pas:178-185），因此 provider 侧重挂/`Reload` 触发的 `OnServiceAdded`
**不会自动复活它**；唯一恢复路径是 `Reload(消费者名)` 或全量 `Reload`
（重跑 wrapper 闭包，工厂已修复则复活、字段重填）。§7.1-20/21 覆盖。

### 4.3 实现要点

- 内部条目模型：`TServiceEntry = record Kind: (skInstance, skLazySingleton,
  skTransient); Instance: IInterface; Factory: TFunc<IInterface>; end`，
  `FMap: TDictionary<TGUID, TServiceEntry>`（现 `Register` 收敛为 skInstance）。
- **`Has` 重定义**：读锁查本层条目存在性 → 未命中走 `FParent.Has(GUID)`；
  对 skInstance 行为与现状（=Resolve）完全等价，对工厂条目不触发构建。
  **`THost.DepsSatisfied` 改用 `Has`**（现用 `Resolve`，附录 A.8）——这是
  懒单例语义成立的前提，配套回归测试见 §7.1-11。
- **锁纪律**：懒单例按「读锁查 → 无锁调工厂 → 写锁 memoize」双检执行；
  **工厂闭包绝不在持锁状态下调用**（工厂内部可能再 `Resolve` 同一注册表，
  RWLock 升级会死锁）。递归解析同一 GUID（工厂依赖自己）→ 检测活动构建集合，
  抛 `EOasisServiceFactoryError('circular')`。
- **并发双检语义**：两线程同时首次解析同一懒单例，允许都调工厂，写锁
  memoize 以最后写入为准，败者实例由其局部接口引用计数自然释放。不强测
  并发用例，语义写进文档。
- **闭包捕获纪律**：工厂/清理闭包**禁止以 `IServiceRegistry` 接口形态捕获
  注册表**（注册表→条目→闭包→注册表 = 接口引用环，永不释放）；一律以类
  引用/裸对象捕获（现状 `Register` 的 `LReg: TServiceRegistry` 即此手法，
  附录 A.8）。桥的解析闭包同理。
- fiber 清理沿用 `AddCleanup` 机制：`RemoveIfSame` 语义按「注册条目」比较；
  懒单例尚未构建时清理只摘条目。

### 4.4 兼容性（破坏性变更，显式记录）

- `IServiceRegistry` 增加方法 + `Has` 语义微调 → 二进制布局变化，**接口
  GUID 更新**；唯一实现 `TServiceRegistry` 在 Core 内同步更新。
- 既有 BPL 插件（`samples/BplPlugin` 等）需重编；`build.cmd` 全量重编已
  覆盖；README 破坏性变更公告。
- 源码级调用方（`Register`/`Get`/`Resolve`）零改动；`Has` 对实例注册行为
  等价。

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
      const AInterfaces: array of PRttiInfo;
      AOwnsResolver: Boolean = False);          { v2：所有权显式化 }
    procedure Apply(const Ctx: IContext); override;
  end;

// 用法（独立 DI，零 REST 依赖；自建列表 → 桥负责释放）：
LList := TInterfaceResolverList.Create;
LList.Add(TypeInfo(ICalc), TCalcImpl.Create);   { 共享实例，归列表所有 }
LList.Add(TypeInfo(IClock), TClockImpl);        { 类注册：每次解析新建——
                                                  要求 TInterfacedObject 后代 + 无参构造（v2 注明） }
Host.Mount(TMormotServicesPlugin.Create(
  LList, [TypeInfo(ICalc), TypeInfo(IClock)], {AOwnsResolver=}True));

// 用法（SOA 容器；容器归 REST server 所有 → 绝不接管释放）：
Host.Mount(TMormotServicesPlugin.Create(
  TRestServer.Services, [TypeInfo(ICalc)]));    { 默认 False }
```

**所有权规则（v2 新增）**：`AOwnsResolver=True` 时桥的析构释放容器（独立
`TInterfaceResolverList` 场景）；`False`（默认）时不释放（`TRestServer.Services`
等外部所有场景）。demo/测试按场景显式传值。

**引用计数所有权（v3/N1 新增）**：mORMot `TInterfaceResolver.Resolve` 的
约定是**返回值已 `_AddRef` 一次、调用者接管**（共享实例路径
`IInterface(Obj) := e^.Instance`，源码注释明言；类注册新建实例同语义，
附录 A.11）。因此：

- **正向桥解析闭包**：以 `LInst: IInterface` 局部变量**直收** `Resolve` 的
  untyped out 参数（这一次 `_AddRef` 即被接管），并**原样作为工厂结果返回**；
  注册表条目 memoize 工厂结果，条目销毁随接口引用释放——全链平衡。全程
  **禁止任何接口↔指针中转转换**（`IInterface(...)`/`Pointer(...)` 搬运是
  计数漂移之源，附录 A.2 同族陷阱）。
- **反向桥 `TOasisResolver.TryResolve`**：`IInterface(Obj) := <注册表取出的
  接口>`——untyped out 的接口赋值增一次计数并交给调用方，与 mORMot 约定
  天然对齐。两侧写法**不对称且都必须**，不得抽成共用转换助手。

- `Apply` 内：对每个 `PRttiInfo` 取 GUID → `Ctx.Services.RegisterFactory(
  GUID, 解析闭包)`——**复用 §4 懒单例**，首次解析才穿透到 mORMot，
  `sic*` 生命周期完全由 mORMot 容器自管（桥不复制语义）。
- 解析闭包：`AResolver.Resolve(PRttiInfo, LObj)`（`TInterfaceResolver`
  公开方法，三类 resolver 通吃）；返回 False 抛 `EOasisServiceFactoryError`。
  闭包捕获遵守 §4.3 捕获纪律（对象引用，不捕接口）。
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
| 激活等待（pending queue） | 工厂/桥注册即 `OnServiceAdded`；`DepsSatisfied` 改 `Has` 后**依赖判定不触发构建**（v2 关键变更，回归测试 §7.1-11） |
| 级联去活 | lazy/transient 条目 `Unregister` 触发 `OnServiceRemoved`，与实例同规则；消费者字段由 fiber cleanup 的 Clear 清 nil |
| `Reload(name)` / `Reload` / `Unload` | 复用 `entry.Apply` 存储闭包（附录 A.8 源码取证）→ wrapper 内 Populate/Clear 自动重跑，字段重填 |
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
5. **Apply 失败（fsFailed）后字段同样清 nil**（v2：fiber 回滚覆盖 Clear）
6. `[Inject]` 标注非接口字段 / 无 GUID 接口 → `EOasisInjectError`
7. 闭包插件 + `TOasisDI.Need<T>` / `TryNeed<T>` 取回类型正确
8. **`Need<T>` 错误路径**：未注册 → `EOasisServiceNotFound` / `TryNeed=False`
9. `RegisterFactory` 懒单例：只构建一次、后续同实例（构建计数）
10. `RegisterFactory` 注册即 `Has=True` 且 pending 消费者激活
11. **依赖判定不构建**（v2 F1 回归）：`DepsSatisfied` 通过后构建计数 = 0；
    `Populate` 才首次构建
12. `RegisterTransient`：每次 `Get` 新实例（构建计数 ≥ 2）
13. transient × `[Inject]` 字段：一次 Apply 持有同实例（语义明示项）
14. 工厂抛异常 → `EOasisServiceFactoryError`；懒单例失败不 memoize，重试成功
15. 工厂递归自解析 → circular 错误（不死锁）
16. **父/子上下文 shadowing**：子上下文覆盖工厂 GUID 后孙辈解析到子层实现，
    父层消费者不受影响
17. fiber 卸载：工厂条目注销、memo 实例与闭包释放（`ReportMemoryLeaksOnShutdown`）；
    **重激活（级联往返）后无引用泄漏**
18. 覆盖注册（同 GUID 二次 Register/Factory）为最新者，旧 cleanup 不误删新条目
19. **Supports 运行时失配**（v3/N5）：注册的实例不实现 `[Inject]` 字段接口 →
    `Populate` 抛 `EOasisInjectError` → 消费者 fsFailed（区别于用例 6 的
    声明期错误）
20. **工厂失败的消费者失效模式**（v3/N2）：懒工厂首次解析抛异常 → 消费者
    fsFailed 且字段清空；此后 provider 重挂（`OnServiceAdded` → rescan）
    **不自动复活**（不在 pending 队列）
21. **恢复路径**（v3/N2）：`Reload(消费者名)` 重跑 wrapper → 工厂已修复 →
    fsActive 复活、字段重填、构建计数递增成功

预期 **44 + 21 = 65** 项全绿（现有用例零改动）。

### 7.2 `tests/mormot/Oasis.Mormot.Tests.dpr`（独立 runner，仿 `tests/otl`）

1. `TInterfaceResolverList` 共享实例镜像 → Oasis 消费者 `[Inject]` 可用
2. transient 类注册（`Add(TypeInfo, 类)`）镜像 → 每次解析新实例
3. 桥插件 `Unload` → 镜像注册消失 → 消费者级联去活
4. `TOasisResolver` 反向：`TInterfaceResolverInjected.InjectResolver` 组合
   能解析到 Oasis fiber 注册的服务
5. 解析失败（resolver 无此接口）→ `EOasisServiceFactoryError`
6. 内存泄漏检查（`AOwnsResolver=True` 桥释放容器 / `=False` 不释放，
   两种取值各验一遍）
7. 引用计数回归（v3/N1）：共享实例镜像下连续解析 N 次（N≥3）零泄漏——
   「接收即接管」纪律的回归锚点

缺 mormot2 路径时 runner 构建脚本整体 SKIP（`build.cmd` 打印提示），
不算失败。

---

## 8. 交付物清单

| 项 | 内容 |
|---|---|
| `src/Oasis.Core/Oasis.Inject.pas` | InjectAttribute / TOasisInjector（配方按 §3.2）/ TOasisDI；并入 `Oasis.Core.dpk` |
| `src/Oasis.Core/Oasis.Services.pas` | 条目模型 + RegisterFactory/RegisterTransient + **`Has` 重定义**（条目存在性，不调工厂）；`IServiceRegistry` GUID 更新 |
| `src/Oasis.Core/Oasis.Context.pas` | **仅** wrapper 闭包改造（§3.3：AddDisposable → Clear-cleanup → Populate → Apply）；**无 TPluginEntry 结构变更**（v2 撤销 v1 方案）；implementation 段 uses Oasis.Inject |
| `src/Oasis.Hosting/Oasis.Host.pas` | **`DepsSatisfied` 改用 `Has`**（v2 新增交付物） |
| `src/Oasis.Core/Oasis.Plugin.pas` | `TOasisPlugin.Inject` 合并实现 |
| `src/Oasis.Core/Oasis.Errors.pas` | `EOasisInjectError`、`EOasisServiceFactoryError` |
| `src/Oasis.Mormot/Oasis.Mormot.pas` | TMormotServicesPlugin（含 `AOwnsResolver`）+ TOasisResolver（含许可头注释） |
| `tests/Oasis.DI.Tests.pas` | §7.1 用例，并入 Oasis.Tests.dpr |
| `tests/mormot/` | §7.2 独立 runner |
| `demos/MormotBridgeDemo/` | ConsoleDemo 风格：独立 resolver 镜像（Owns=True）+ 消费者 + 卸载级联 + 反向桥演示 |
| `build.cmd` | mormot 条件编译分支；README 增 DI 章节、Status 行与破坏性变更公告 |

---

## 9. 风险与缓解

| 风险 | 缓解 |
|---|---|
| ~~RTTI 写接口字段~~（**已裁决**） | TValue 路径死亡（附录 A.1）、裸拷贝陷阱（附录 A.2）、正确配方已验证（附录 A.3）——§3.2 已锁定实现规范，不再是开放风险 |
| 插件类被 `{$RTTI}` 剥离字段信息 → 注入静默失效 | `Populate` 对「类型无 GUID 的接口字段」报错；文档警示；扫描不到字段是合法情况（闭包插件同路径） |
| `IPlugin as TObject` 对聚合/委托实现失败 | 文档约束：Oasis 插件为普通类实现（非 TAggregatedObject 场景）；提取失败在 wrapper 闭包内即抛，走 fsFailed，不静默 |
| `IServiceRegistry` 破坏性变更 | 唯一实现在 Core；GUID 更新；BPL 插件随 build.cmd 全量重编；README 公告 |
| mORMot2 新旧单元名双轨（svc/soa） | 以本机新版 `mormot.soa.*` 为准；桥仅在 uses 处出现单元名，README 注明最低版本要求 |
| 懒单例工厂持锁调用 → 死锁 | §4.3 锁纪律 + 用例 15 覆盖 |
| 并发重复构建浪费 | 已定语义（§4.3 最后写入为准），非开放风险 |
| 工厂失败后消费者滞留 fsFailed | 已文档化（§4.2 失效模式 + §7.1-20/21 恢复路径），非开放风险 |
| 桥解析引用计数漂移 | 已立规（§5.2 引用计数所有权，两侧分写 + §7.2-7 回归），非开放风险 |

---

## 10. 后续（非本期）

- VclShowroom 增加「DI/桥接」展示卡片
- Effect Layer 式组合层（若将来有测试替换的强需求）
- 构造函数注入、命名实例、装饰器
- 桥的 SOA 高级特性透出（契约校验、服务方法级权限）

---

## 附录 A：对抗审查证据（2026-09-05，v2 的修订依据）

证明程序：`C:\Users\yslmy\AppData\Local\Temp\oasis-rttiproof\rttiproof1..6.dpr`
（dcc32 37.0 / Delphi 13 Florence 编译运行；实现期可搬入 `tests/` 作回归）。
源码取证基于 Oasis 当前 main（commit `29b1c54`）。

**死路（禁止）**：

1. **A.1** `TValue.From(IInterface变量) + TRttiField.SetValue` 到类型化接口
   字段 → 运行时 `EInvalidCast`（rttiproof2[A]）；字段未损坏、Free 安全，
   失败干净但不可行。
2. **A.2** **编译期重类型/裸拷贝陷阱**：`IGreeter(IInterfaceVar)` 不做 QI；
   `TInterfacedObject` 直接实现 IInterface 而子类另实现 IGreeter 时两接口是
   独立 vtable 条目，异接口指针进字段后：字段非 nil、指针比较全对，**调用
   方法跳地址 0x1**（rttiproof4 复现，含 layout ground-truth 扫描）。任何
   绕过 `Supports` 的拷贝都埋此雷。

**验证配方（可行，§3.2 采纳）**：

3. **A.3** `Supports(实例, 字段GUID) → PIInterface(PByte(插件)+Offset)^ := Conv`
   引用计数写入 + 同路径 nil 清空 → 填充/调用/清空/释放全通过、
   `ReportMemoryLeaksOnShutdown` 零泄漏（rttiproof5）。

**可行性事实**：

4. **A.4** `strict private` 接口字段 RTTI 可见、`GetTypeData(字段类型).Guid`
   可提取、`[Inject]` 自定义属性可检测（rttiproof1[1][2]）。
5. **A.5** `IInterface as TObject` 提取实现对象成功（rttiproof2[C]）；
   泛型 `Need<T>` 以 `SysUtils.Supports` untyped out 实现成功（rttiproof2[D]）。
6. **A.6** dpr 全局泛型函数非法（E2530，rttiproof1 首轮编译失败）——
   `TOasisDI = record` 静态方法设计由此固定。
7. **A.7** `TRttiField.Offset` 与真实实例布局一致（rttiproof4：rtti=12 与
   setter 赋值后内存扫描 true=12 吻合；类含隐藏字段 dword@8，不影响——
   一律以 RTTI Offset 为准）。

**源码取证**：

8. **A.8** `THost.DepsSatisfied` 用 `Resolve`（Oasis.Host.pas:141）；`Has`
   是 `Resolve` 别名（Oasis.Services.pas:179）；`Register` 以类引用捕获
   `LReg: TServiceRegistry` 规避接口环（Oasis.Services.pas:103）；
   `Reload` 全量/单名复用 `entry.Apply` 存储闭包（Oasis.Context.pas:445/479）；
   级联去活走 `FRoot.Unload → fiber.Dispose → cleanup LIFO`
   （Oasis.Host.pas:229-242）；`MountUnderFreshFiber` 失败分支 Dispose
   fiber 并保留 fsFailed 条目（Oasis.Context.pas:278-290）——§3.3 的
   fiber-cleanup 清理方案由此外推，四条拆卸路径共用同一 LIFO 机制。

---

## 附录 B：执行期勘误（2026-09-05，feat/di 实现与两轮任务评审裁决）

1. **B.1 §5.2 正向桥映射**：草图「复用 §4 懒单例（RegisterFactory）」错误——
   mORMot 类注册是**每次解析新建**，懒单例 memoize 会把「每次新」冻结成
   「永久一」，违反本节主导语义「sic* 生命周期完全由 mORMot 容器自管」。
   实现改为 `RegisterTransient`（每次 Get 穿透解析；共享实例路径每次返回
   同一实例，语义不变）。
2. **B.2 §5.3 反向桥赋值**：`IInterface(Obj) := LInst` 是附录 A.2 裸拷贝陷阱
   的镜像（IInterface 条目指针写入调用方具体接口槽位 → 方法调用 AV，
   实测复现）。实现改为 `QueryInterface` 透传（以请求接口的 GUID 换出正确
   vtable 条目，恰好一次 `_AddRef` 交调用方）。
3. **B.3 §7.1 计数**：44+21=65 为逻辑用例口径；实现展开为 30 个测试方法
   + Task 4 评审补 1 个父链回归用例 = 44+31 = **75**。mormot runner 8 用例。
4. **B.4 执行新知**：dcc32 37.0 下 `IInterface` 的 RTTI 自带 IUnknown GUID
   （无 GUID 测试接口须用户自声明）；Delphi 同作用域匿名方法共享 `$ActRec`
   （任何兄弟闭包捕接口形态注册表都会使存储闭包成环）；包编译 `-E` 不重
   定向 .bpl/.dcp（需 `-LE/-LN`）；`Resolve` 父链委托必须在 `LeaveRead` 之后
   （计划清单中的回归，评审捕获后修复）。
5. **B.5 §9 提取失败时机措辞**：风险表称 `IPlugin as TObject` 失败「在 wrapper
   闭包内抛」，实际（§3.3 草图与实现一致）提取发生在 `MountUnderFreshFiber`
   之前、异常从 `TContext.Plugin`/`THost.Mount` 直接抛出（不走 fsFailed）。
   实现与草图一致，风险表措辞以本条为准。

**二轮审查（v3 修订依据）新增证据**：

9. **A.9** 清理顺序契约坐实：`AddDisposable` 即 `AddCleanup` 包装
   （`AddCleanup(procedure begin AObj := nil; end)`，Oasis.Effects.pas:154-157），
   两者共用同一 `TStack<TEntry>`，`Dispose` 严格逆序弹出且不持锁执行用户
   清理（Oasis.Effects.pas:159-194）——§3.3「用户清理 → Clear → 插件释放」
   次序由实现保证，非假设。
10. **A.10** 继承字段注入可行（rttiproof6 编译运行全绿）：`GetFields` 一次
    返回全层级字段（基类 `FBaseGreeter` offset=12 / 派生类 `FDerivedGreeter`
    offset=16，`Field.Parent` 各自正确），offset 写入 + 两字段调用 + Free
    零泄漏。
11. **A.11** mORMot 引用计数约定（源码取证）：`TInterfaceResolverList.TryResolve`
    对共享实例执行 `IInterface(Obj) := e^.Instance`，注释明言
    "will increase the reference count of the shared instance"；类注册路径
    `ClassNewInstance + GetInterfaceFromEntry` 同为「一次计数交调用者」——
    §5.2 引用计数所有权规则（正向接收即接管 / 反向接口赋值）的事实基础。
