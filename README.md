# Oasis Framework

一个用 Delphi/Object Pascal 实现的 Cordis 风格插件框架。

设计理念参考 [Cordis](https://github.com/cordiverse/cordis)（TypeScript 生态的插件框架）与
[DeepSeek Harness 的 Cordis Primer](https://deepseek-harness.github.io/deepseek-harness/reference/cordis-primer)。
'Everything is a plugin'：应用中的所有能力——服务、事件、工具、生命周期——都通过插件挂载到共享上下文（Context）中，
由运行时统一管理加载顺序、依赖关系与清理。

本仓库在 Delphi XE8（Studio 15.0，dcc32 v28.0）上实测编译并全部通过测试；代码兼容 Delphi 10.x/11.x。

---

## 一、Cordis 五大理念 → Oasis 的映射

| Cordis 理念 | Oasis 中的实现 |
|---|---|
| 插件是对象：函数 + inject + apply(ctx)，或 Service 子类 | IOasisPlugin 接口；TOasisPlugin（类形式）、TOasisService（服务形式，激活时按名字注册自己）、Ctx.Plugin('name', procedure(Ctx) ...)（函数形式） |
| 上下文是服务仓库：服务占用稳定的 ctx.<key>，消费者按键查找而非 import 具体实现 | Ctx.Provide('greeter', Service) / Ctx.Get('greeter') / Ctx.ServiceObject('greeter') as TGreeterService |
| 用 inject 声明依赖：加载顺序由服务依赖决定，而不是启动顺序 | InjectServices(['greeter'])；依赖未满足时插件停在 PENDING，服务出现后自动激活；服务消失时依赖方卸载，服务回归时自动重载（热替换） |
| 类型化事件通信：emit / waterfall / parallel / serial 等派发模式 | 五个派发方法 Emit / Bail / Serial / Parallel / Waterfall，扁平 namespace/action 事件命名 |
| 注册都是可逆的 effect：ctx.effect() / ctx.on() 保证卸载时按序回卷 | Ctx.Effect / Ctx.OnDispose / Ctx.On / 子插件挂载 / 服务注册全部绑定到所属 fiber，卸载时 LIFO 逆序执行清理 |

## 二、事件派发模式

| 模式 | 方法 | 语义 |
|---|---|---|
| emit | Ctx.Emit(name, args) | 同步广播，按注册顺序执行，返回值被忽略 |
| bail | Ctx.Bail(name, args) | 同步，第一个真值（非 nil / 非 False / 非空）返回值胜出并停止链 |
| serial | Ctx.Serial(name, args) | bail 的按序形式（Delphi 下同步实现，语义一致） |
| parallel | Ctx.Parallel(name, args) | 所有监听器在 TTask 工作线程上并发执行，等待全部完成（监听器必须线程安全，不得直接碰 VCL 控件） |
| waterfall | Ctx.Waterfall(name, args, Default) | around 中间件：监听器收到 (Args, Next)，调用 Next(...) 委托下游，不调用即短路（veto）；Default 是发射方提供的链尾默认值 |

约定：只观察/注解的 waterfall 监听器必须调用 Next；不调用就是有意的短路。事件沿 fork 链向上冒泡（子上下文先于父上下文派发）。

## 三、生命周期（fiber 状态机）

每个挂载的插件实例拥有一根 fiber：

    PENDING → LOADING → ACTIVE → UNLOADING → DISPOSED
                           ↘ FAILED（Apply 或配置校验抛异常）

- PENDING：已声明，但某个 InjectServices 依赖的服务尚不存在。
- FAILED：Apply 或配置校验抛异常；异常保存在 fiber.Error，已注册的 effect 会被回卷。
- 卸载顺序：OnUnload 通知 → 子插件（逆序）→ disposer（LIFO）→ 移除本 fiber 的事件监听。
- fiber.Dispose 幂等；根上下文 Dispose 会先回收子 fork，再逆序卸载所有插件，最后执行上下文级 effect。

## 四、配置校验（fail loud）

配置类继承 TOasisConfig，字段用 published 属性 + [OasisConfig(...)] 特性声明约束：

    type
      TServerConfig = class(TOasisConfig)
      strict private
        FPort: Integer;
      published
        [OasisConfig('TCP port to listen on', True, 1, 65535)]
        property Port: Integer read FPort write FPort;
      end;

      TServer = class(TOasisPlugin<TServerConfig>)
      protected
        procedure OnApply(const Ctx: IOasisContext); override;
      end;

TOasisPlugin<TConfig> 在 Apply 前自动执行校验；非法配置抛 EOasisConfigError，fiber 进入 FAILED 而不是带着坏配置运行一半。

## 五、快速上手

    type
      TGreeterService = class(TOasisService)   // 服务 = 插件，激活时按名注册自己
      public
        constructor Create(const AServiceName, APrefix: string); reintroduce;
        function Greet(const AWho: string): string;
      end;

      TGreeterConsumer = class(TOasisPlugin)   // 声明硬依赖，等待服务就绪
      public
        constructor Create;
      protected
        procedure OnApply(const Ctx: IOasisContext); override;
      end;

    constructor TGreeterConsumer.Create;
    begin
      inherited Create('greeter-consumer');
      InjectServices(['greeter']);              // 依赖，不是启动顺序
    end;

    procedure TGreeterConsumer.OnApply(const Ctx: IOasisContext);
    var
      G: TGreeterService;
    begin
      G := Ctx.ServiceObject('greeter') as TGreeterService;
      Writeln(G.Greet('Delphi'));
    end;

    var
      Root: IOasisContext;
    begin
      Root := TOasisContext.Create('app');
      Root.Plugin(TGreeterConsumer.Create);     // 先挂消费者也没关系：它停在 PENDING
      Root.Plugin(TGreeterService.Create('greeter', 'Hello'));  // 服务出现 → 消费者激活
      Root.Dispose;
    end.

完整示例见 examples/OasisDemo.dpr（覆盖 inject/PENDING、五种事件模式、effect 清理、服务热替换、配置校验、函数式插件、fork 作用域）。

## 六、目录结构

    oasis-framework/
    ├── OasisFramework.dpk        运行时包（IDE 打开后会自动生成 .dproj）
    ├── src/
    │   ├── Oasis.Core.pas        契约：IOasisContext / IOasisFiber / IOasisPlugin、事件回调类型、
    │   │                         TOasisArgs、fiber 状态机、异常与工具函数
    │   ├── Oasis.Config.pas      RTTI 配置校验：[OasisConfig] 特性 + TOasisConfig.Validate
    │   ├── Oasis.Plugin.pas      插件基类：TOasisPlugin / TOasisPlugin<TConfig> / TOasisService
    │   └── Oasis.Context.pas     运行时：TOasisContext（服务仓库、事件总线、fiber、fork、effect）
    ├── examples/
    │   ├── OasisDemo.dpr         全概念演示（30 项断言）
    │   └── DemoPlugins.pas       演示插件
    └── tests/
        ├── OasisSelfTest.dpr     行为自检（57 项断言）
        ├── TestPlugins.pas       测试插件夹具
        └── OasisTestHarness.pas  极简断言 harness（可按需替换为 DUnitX）

## 七、构建与运行

用任意版本 RAD Studio 的命令行（先运行 rsvars.bat 设置环境，或用 dcc32 完整路径）：

    :: 演示（在 examples 目录下）
    dcc32 -B OasisDemo.dpr
    OasisDemo.exe

    :: 自检（在 tests 目录下）
    dcc32 -B OasisSelfTest.dpr
    OasisSelfTest.exe          :: 期望 "57 passed, 0 failed"，失败时退出码 1

    :: 运行时包（在仓库根目录）
    dcc32 -B OasisFramework.dpk

单元通过 uses 中的 in '..\src\...' 子句挂进 dpr，IDE 中打开任一 dpr 即可在 Project Manager 中看到完整单元结构；
首次在 IDE 中编译会生成对应 .dproj。

## 八、与 Cordis 的语义差异（有意为之）

| 差异 | 说明 |
|---|---|
| serial / bail 均为同步 | Delphi 无 async/await；二者实现一致，保留两个名字以对齐 Cordis API |
| Parallel 只在当前上下文派发 | Cordis 中并行+冒泡的组合在 Delphi 线程模型下易产生竞态；已文档化 |
| 泛型服务查找挂在类上 | Delphi XE 不允许接口含参数化方法：接口提供 ServiceObject / ServiceInterface（返回 TObject / IInterface，调用处 as 转型），TOasisContext 类上另有 Service<T> / ServiceObject<T> 泛型重载 |
| OnUnload 钩子 | Cordis 只靠 effect；Oasis 额外提供卸载前通知（effect 仍是主要清理手段） |
| 配置来自代码 | 未内置 cordis.yml / JSON 加载器；TOasisPlugin<TConfig> 已留出注入点，文件加载器可作为扩展插件实现 |
| 监听器按 fiber 整体回收 | Ctx.On 注册随所属插件卸载时统一移除（等价于 Cordis 的 per-listener disposer） |

## 九、所有权与内存规则

- 上下文拥有插件实例：挂载（Ctx.Plugin）后不要再手动释放插件对象；接口引用计数负责最终回收（TOasisPlugin 基于 TInterfacedObject）。
- 插件拥有其配置对象（Config / ConfigObject），析构时释放；外部替换配置会先释放旧的。
- 被提供的服务：移除时若实现 IOasisDisposable 则调用 Dispose；对象实例本身由所属 fiber 的接口引用保持存活（fiber 卸载顺序保证：先卸载依赖方、再 dispose 实例、最后释放实例）。
- 必须调用 Dispose：context ↔ fiber 之间存在接口引用环，Dispose 是断环点（与所有 ARC 框架的约定一致）。
- Ctx.Effect 返回的 disposer 可手动提前调用（幂等，不会二次执行）。

## 十、线程安全说明

- 上下文本身不是线程安全的：挂载/提供/注册监听应在单一线程（通常是主线程）完成。
- Parallel 的监听器运行于 TTask 工作线程：不得直接访问 VCL/FMX 控件，UI 更新请用 TThread.Queue。
- Emit 在调用线程同步派发；事件负载 TOasisArgs 按值传递。

## 十一、扩展点

- 配置加载器：实现一个读取 JSON/YAML 并 Ctx.Plugin(...) 的插件，即可得到 cordis.yml 式配置（含 disabled / 覆盖层语义）。
- 声明合并的替代：Cordis 用 TypeScript declaration merging 给 ctx.greeter 加类型；Delphi 中对应做法是服务接口 + 强类型包装（见 ServiceObject('x') as TGreeterService）。
- 测试框架：OasisTestHarness 是零依赖极简实现；迁移到 DUnitX 只需把 Expect 包成断言。
- 运行时插件包（BPL）：OasisFramework.dpk 已是运行时包；动态加载 BPL 插件的注册器可基于 TOasisService 实现。

## 十二、已知限制

- 服务名/事件名大小写敏感（与 Cordis 一致，扁平命名空间；建议事件用 namespace/action，自定义服务加前缀避免与宿主冲突）。
- TOasisArgs 采用 TValue 松类型负载：换取与 Cordis 一致的灵活性，代价是编译期不检查事件签名（团队应把事件名与负载约定写成文档/常量）。
- 监听器派发期间修改监听器列表（On / 卸载）未加锁保护，属重入误用场景。

