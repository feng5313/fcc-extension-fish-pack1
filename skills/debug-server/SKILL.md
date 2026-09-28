---
name: debug-server
description: fcc 内置 HTTP 远程调试服务。启动 fcc --debug-server 后, 可通过 curl/HTTP 或 fcc.lua 脚本实时控制与查询运行中的 fcc.exe：调用所有模式所有UI功能(toggle_settings/粒子面板/编辑器工具/视频控制等82个action)、添加修改属性线框(地面/水面/天空/布料/挂饰/人脸/树林/草地)、添加粒子发射器与改参数、加载控制FBX模型动画、读写193个config配置、渲染帧截图。支持 fcc_cli.exe --lua "lua代码" 单命令直接执行lua(本地启动脚本/远程--host)。触发词: debug-server、fcc调试、远程控制fcc、UI自动化测试、线框自动化、粒子调试、fcc.action、fcc_cli --lua。
---

# fcc debug-server 调试技能

## 启动

```bat
:: 服务端(被调试方): 端口缺省 8620，用daemon工具运行避免阻塞流程！
fcc.exe <图片或目录> --debug-server [port] --no-exit

:: 客户端(跨机远程执行lua): 把代码发往远程 debug-server, 打印结果即退出
fcc.exe --host 192.168.1.5[:8620] --lua <lua代码字符串|script.lua>
fcc_cli.exe --host 127.0.0.1:8620 --lua "print('hi'); return fcc.env_get('app.version')"
```

- 自动测试须加 `--exit-sec 5`（5秒自动退出）；交互调试用 `--no-exit`。
- 绑定全部网卡，`--host` 可跨机访问；仅显式传 `--debug-server` 时启动。

## --lua 参数（本地启动脚本 / 远程执行）

`--lua <lua代码字符串|script.lua>` 先检测参数是否为**存在的文件路径**：
是文件→读入执行；非文件→**原样作为 lua 代码字符串**执行。

```bat
:: 1. 单命令直接运行lua代码串(无图=显示内嵌fcc.jpg) — 启动脚本语义
fcc_cli.exe --lua "print('hello'); return 6*7"

:: 2. 带图片: lua 作为启动脚本, 打印结果后查看器保持运行(不退出!)
fcc_cli.exe D:\pics\a.jpg --lua "fcc.show_toast('hi')"

:: 3. lua 文件(相对路径按调用者 cwd 解析 — fcc_cli 透传 FCC_CLI_CWD)
fcc_cli.exe --lua scripts\setup.lua

:: 4. 一次性求值后自动关闭窗口: 代码里调 fcc.exit()
fcc_cli.exe --lua "print(1+1); fcc.exit()"

:: 5. 远程操作 debug-server(纯客户端, 不开窗口, 打印远程结果即退出)
fcc_cli.exe --host 127.0.0.1:8620 --lua "return fcc.env_get('app.version')"
```

**退出语义（#1835 风主钦定）**：
- 本地 `--lua` = 启动脚本：lua 结果打印到 console 后**查看器保持运行**
  （命令行参数带图则显示该图，无图显示内嵌 fcc.jpg）。
- 主动退出：lua 代码调 `fcc.exit()`；或 `--exit-sec N` 定时退出；
  或直接关窗。`--host` 客户端模式纯求值、打印即退出（退出码：成功0/lua错误1/连接失败1）。
- 图片路径无效且带 `--lua`：回退内嵌图继续执行 lua（console 有提示）。

## HTTP 端点 (全部 JSON 带 CORS；响应 Connection: close)

| 端点 | 说明 |
|---|---|
| `GET /health` | 存活/版本/exeDir/uptime |
| `GET /actions` | 全部可调用UI动作清单(内置77+插件, 含desc/category) |
| `POST /action/<name>` | **同步触发**UI动作(主线程执行完才返回, 测试友好) |
| `GET /env?prefix=` / `GET /env/<name>` | Env 全量/单字段读取 |
| `POST /env/<name>` body=JSON值 | 写字段(热改, 同设置面板路径) |
| `POST /lua?timeout=ms` body=lua代码 | 异步执行lua → `{ok, output}`(print+返回值) |
| `POST /rpc/<domain>/<op>` body=JSON参数 | 通用RPC(GET亦可用于只读查询) |
| `GET\|POST /restart` | **#1873 重启进程**: 默认按原命令行重启; `?args=`或body `{"args":...}` 换新参数。2s延迟后start新实例+旧进程正常清理退出(workdir保留; 响应`{ok,restarting,delay_s,workdir,launch}`) |
| `GET /screenshot?x=&y=&w=&h=[&fmt=bmp]` | 渲染帧区域抓取PNG或指定格式(缺省=图片显示区) |
| `GET\|POST /fs_screenshot?x=&y=&w=&h=[&fmt=bmp]` | 全屏粒子(FS)层区域抓取(#1873) |
| `GET\|POST /model_render?src=...` | **#1877 单模型渲染PNG直出**(GET query或POST JSON body; 参数同`model.render`, 见下) |

## RPC 域

| domain | op | 要点 |
|---|---|---|
| `app` | info / exit / screenshot / i18n | exit=安全异步退出(置shouldExit走正常清理) |
| `env` | get/set/list/dump | `config.*` 193字段全热改; 字段名=JSON桥扁平化(**config.cloth.enabled**, 非camelCase); `viewer.*` `app.*` 只读 |
| `ui` | actions / trigger / trigger_sync | **所有模式所有UI功能**: trigger异步(下一帧), trigger_sync同步(默认500ms超时)。动作=键盘keybind action, 与真实按键完全同路径 |
| `overlay` | kinds/list/add/remove/clear/set_kind/set_inverted/set_points/set_physics | **属性线框**; points=归一化坐标`[[x,y]...]`(0,1²左上原点); kind接受int或`"cloth"/"water"/"sky"/"ground"/"prop"/"ornament"/"face"/"forest"/"grass"`; rect=true→4角点矩形; 修改自动触发布料rebuild |
| `particle` | info/select_type/select_variant/emitters.add/remove/clear/set_params/set_pixels/set_mesh/ensure_slots/kill_type/world_info/mesh_info | 粒子系统owner线程路由已内置; #1873 新增 world_info(RT+世界像素域)/mesh_info(mesh元数据快照) |
| `fbx` | load/unload/info/pause/speed/loop/seek/anim/orbit/auto_rotate/mesh_snapshot/mesh_groups/mesh_verts/mesh_release | load=加入列表并显示; viewer类op走mainThreadSync主线程执行; **#1873 mesh组3op=独立场景不碰viewer**: `mesh_groups{path[,tex_dirs]}` worker线程解析(~1s)+缓存→成员清单`[{name,node,nverts,tris,tex,u:[min,max],v:[min,max],uvXf}]`+textures`[{name,w,h}]`; `mesh_verts{path,idx[,max_tris]}`→单成员b64顶点流(8float/顶点 xyz+uv+normal, geometryToWorld后); `mesh_release{path}`释放缓存。贴图搜索已内置: exe/res\\textures+fbxDir/textures+fbxDir/../textures(tile域UV自动规范化v-=1, uvXf网格跳过) |
| `model` | fbx_load/fbx_list/fbx_model/fbx_anim/render/buf_release/fbx_release | **#1877 模型浏览/渲染域**(独立场景缓存, 与fbx.mesh_groups共用): 详见下方"model域详解(#1877)" |

## lua API (POST /lua、--lua 或 --host)

```lua
-- UI动作(所有模式所有UI功能)
fcc.action('toggle_particle_panel')            -- 异步触发
fcc.action_sync('toggle_settings', 1000)       -- 同步(执行完才返回)
local acts = fcc.actions()                     -- {{name=,desc=,category=},...}

-- 通用RPC直通(所有域)
fcc.rpc('overlay','add',{kind='cloth',rect=true,
        points={{0.3,0.3},{0.7,0.3},{0.7,0.7},{0.3,0.7}}})
fcc.rpc('particle','emitters.add',{type=0,rate=30,max=200})
fcc.rpc('fbx','load',{path='D:/x/model.fbx'})

-- Env 参数读写
fcc.env_set('config.cloth.enabled', false)
local v = fcc.env_get('viewer.scale')

-- 主动安全退出 fcc(#1835): 置 shouldExit 走正常清理(配置落盘/资源回收)
fcc.exit()

-- 其它: fcc.config_get/set, fcc.show_toast, fcc.viewer_*(), fcc.video_*(),
-- fcc.http_get/post, fcc.json_decode/encode, fcc.on_update(cb), fcc.draw_text...
```

## 典型工作流

```bat
:: 1. 列出全部UI动作
curl http://127.0.0.1:8621/actions

:: 2. 打开粒子面板(同步) → 截图确认
curl -X POST http://127.0.0.1:8621/action/toggle_particle_panel
curl http://127.0.0.1:8621/screenshot -o shot.png

:: 3. 加布料线框+查列表
curl -X POST http://127.0.0.1:8621/rpc/overlay/add ^
  -d "{\"kind\":\"cloth\",\"rect\":true,\"points\":[[0.3,0.3],[0.7,0.3],[0.7,0.7],[0.3,0.7]]}"
curl http://127.0.0.1:8621/rpc/overlay/list

:: 4. 单命令远程求值(fcc_cli 不开窗口, 结果即命令输出)
fcc_cli.exe --host 127.0.0.1:8621 --lua "print(#fcc.actions()); return 'ok'"

:: 5. #1873 重启进程(换端口/换参数) — 2s后新实例接管, curl会先收到ok再断连
curl "http://127.0.0.1:8620/restart?args=--debug-server+8621+--no-exit"

:: 6. #1873 fbx独立解析→粒子mesh(不弹查看器窗口)
curl -X POST http://127.0.0.1:8620/rpc/fbx/mesh_groups -d "{\"path\":\"res/models/fish.fbx\"}"
```

## model域详解 (#1877 模型浏览/渲染)

模型资产浏览/预览渲染 API。场景走**独立解析缓存**(与`fbx.mesh_groups`共用,
不碰查看器viewer); 渲染走 #1876 通用纯GPU管线(gpuscene, fbx与粒子模型同一
PBR着色观感)。**返回形态: 插件/lua(进程内)返回指针**(JSON整型`ptr`, LuaJIT
`ffi.cast`直读零拷贝; 缓冲registry LRU保留8个, `buf_release{id}`显式释放);
**远程HTTP加 `out:"b64"`** 返回base64/png_b64; `/model_render` HTTP端点直出
PNG图片。

### ops (fcc.rpc('model', op, args) 或 POST /rpc/model/<op>)

| op | args | 返回要点 |
|---|---|---|
| `fbx_load` | `{path[,tex_dirs]}` | 解析+缓存+全量清单(幂等): `stats{meshes,nodes,bones,materials,textures,anims,tris,verts}` `meshes[{idx,name,node,material,skinned,weighted,nverts,tris,bounds,u,v}]` `anims[{idx,name,duration,fps,frames}]` `materials[{idx,base_color,roughness,texture}]` `textures[{idx,name,w,h,has_alpha}]` |
| `fbx_list` | `{path}` | 同上(未缓存自动加载) |
| `fbx_model` | `{path,mesh[,max_tris][,verts=true][,out]}` | 单模型: meta+`material`(base_color/roughness/texture)+贴图+世界空间bind pose顶点流(8f/顶点: x,y,z,u,v,nx,ny,nz; geometryToWorld已乘)。ptr形态: `verts{ptr,size,nverts,id,fmt="f32x8"}`+`texture_data{ptr,w,h,fmt="rgba8",lifetime="scene_cache"}`(⚠场景缓存释放后失效); b64形态: `verts_b64`+`texture_png_b64` |
| `fbx_anim` | `{path,anim[,stride=1][,out]}` | 单动画: meta+`animated_nodes[{node,name,parent,bind_t,bind_q,bind_s}]`(任意帧local TRS≠bind的节点)+`meshes[{idx,name,why=skinned|node}]`(受影响模型)+关键帧流`keys{ptr,floats,frames,nodes,stride,fmt="f32x10"}`(每帧×每动画节点10f: txyz qxqyqzqw sxyz; `frame_t`=各帧秒) |
| `render` | 见下 | 渲染单模型 → ptr形态`fb{ptr,size,w,h,id,fmt="rgba8_premul"}` / b64形态`png_b64` / `path_out`写PNG文件 |
| `buf_release` | `{id}` | 释放指针缓冲 |
| `fbx_release` | `{path}` | 释放场景缓存 |

### render 参数 (GET /model_render 同名query参数; POST body=JSON)

```js
{
  src: "fbx"|"particle",       // fbx: path[,mesh=-1全部|>=0单网格][,anim=-1bind|>=0剪辑][,t=秒]
                                // particle: type(0..16)[,variant(0..15)]
  // 视角: yaw/pitch弧度(默认0.7/0.32), dist(<=0或缺省=自动取景宽高双拟合+1.18余量),
  //        fov度(默认40)
  // target: [x,y,z]数组(POST) 或 "x,y,z"字符串(GET query形态; #1877修复不再被静默忽略)
  // 光照(与fbx.pbr字段一致): light:[roll,pitch度]|"roll,pitch"|light_roll/light_pitch/light_str,
  //        env_ambient:[r,g,b]|"r,g,b", aniso_color同, env_ambient_coef, metallic, spec_scale,
  //        aniso_strength, normal_map, alpha_cutoff, ...
  // clear:[r,g,b(,a)]|"r,g,b(,a)"或clear_argb(默认黑不透明; a<255→RGBA PNG可透明合成)
  w: 512, h: 512,              // 8..2048
  out: "b64", fmt: "png",      // png输出(lua默认ptr)
  path_out: "D:/x.png"         // 写文件
}
```

注(#1877): 自动取景(dist缺省)按过滤后网格的**真实渲染包围**精确取景 — 与GPU
VS蒙皮逐项同构的CPU计算, 静态/动画/蒙皮场景均瞄得准(GET形态mesh=N单网格
渲染不再落空)。
注: `src="particle"` 要求粒子owner路由已激活(查看器粒子面板开过一次或先
`fcc.action_sync('toggle_particle_panel')`), 未激活时报
`particle owner route not active yet (retry)`。
注(#1877): model域场景缓存键=路径canonical归一 — 相对/绝对路径等价
(`fish.fbx` ≡ `D:/x/fish.fbx`, fbx_model/fbx_anim 不再因路径写法miss)。

### lua 指针直读示例 (LuaJIT ffi)

```lua
local ffi = require("ffi")
local r = fcc.rpc('model','render',{src='fbx', path='D:/models/fish.fbx', w=256, h=256})
-- r.fb.ptr = FB地址; r.fb.size = w*h*4 (rgba8预乘)
local px = ffi.cast("const uint8_t*", r.fb.ptr)
local v = fcc.rpc('model','fbx_model',{path='D:/models/fish.fbx', mesh=0, verts=false})
fcc.rpc('model','buf_release',{id=r.fb.id})   -- 用完释放(可选, LRU自动)
```

### 典型工作流

```bat
:: 浏览fbx模型资产
curl -X POST http://127.0.0.1:8620/rpc/model/fbx_load -d "{\"path\":\"D:/models/fish.fbx\"}"
curl -X POST http://127.0.0.1:8620/rpc/model/fbx_anim -d "{\"path\":\"D:/models/fish.fbx\",\"anim\":0}"

:: 渲染单模型PNG (fbx第3个mesh, 俯视, 光照右上)
curl "http://127.0.0.1:8620/model_render?src=fbx&path=D:/models/fish.fbx&mesh=3&pitch=1.2&light_roll=40&light_pitch=30" -o m.png

:: 渲染粒子系统模型 (锦鲤变体2)
curl "http://127.0.0.1:8620/model_render?src=particle&type=6&variant=2" -o fish.png
```

## 注意事项

- **线程模型**: HTTP线程→mainThreadSync/队列→主线程执行UI操作; 不会阻塞渲染; 主循环卡顿时 trigger_sync 超时报错不挂死。
- trigger/trigger_sync 的动作语义=按下其键盘绑定, 含编辑器模式过滤等全部行为; 编程调用不受 WantTextInput 打字保护限制。
- /lua 执行环境=LuaJIT worker线程, 可并发多任务(结果按 taskid 路由); `?timeout` 缺省15s上限120s。
- screenshot 只截 fcc 自渲染内容(非屏幕DC), 默认抓图片区域, 带 x/y/w/h 抓任意渲染区(像素=渲染分辨率)。#1839起默认返回PNG(RGB24), `?fmt=bmp`为兼容24bpp BMP; 编码在HTTP连接线程, 渲染线程仅做像素转储。
- 安全边界: 调试模式显式开启; `fcc.exit()` / `fcc.rpc('app','exit')` / `ui.trigger('exit')` / exit action 会真实退出程序。
- 相对路径 lua 文件: fcc_cli.exe 把子进程 cwd 固定为 exe 目录, 但会通过 `FCC_CLI_CWD` 环境变量透传调用者 cwd — 相对路径先按进程 cwd 探测、未命中按调用者 cwd 解析。
