-- ============================================================================
-- fish.lua — 鱼类扩展 for fcc
--
-- 纯lua + GPU实现: load时一次性登记 粒子类型/变体/FBX模型/贴图/GLSL注入,
-- 零常驻每帧逻辑。鱼行为(巡游/觅食/打斗/群游/追逐/躲避)由引擎鱼群shader
-- 驱动, 本脚本只负责数据bake与RPC提交。
--
-- 架构(动态类型注册, 零硬编码槽位/数量):
--   [type]  particle.register_type{name=鱼类扩展, behavior=6, variants=72} →
--           fcc动态分配 type id 与连续贴图槽段 base;
--           前N槽=鱼albedo, 后N槽=亮度自动生成法线贴图(同尺寸)
--   [var]   register_variant×N(每物种一条): 名字进UI下拉/i18n
--   [mesh]  set_mesh_fbx 一步直写: N项变体表(每物种独立FBX几何)
--   [tex]   set_texture_fbx 槽直传: 素材忠实像素零变换(无键控)
--   [anim]  摆尾/体波变形走鱼群VS(引擎统一); 胸鳍/腹鳍/丝/尾膜波动走
--           本扩展VS模板
--   [skin]  fs_fish_skin 模板注入: 原生UV直采本槽位贴图 + 水下氛围
--   [beh]   cs_fish_params 模板注入: 物种系数(巡航/怠速/转向/逃离/
--           群游开关) + 精确渲染全长 + 分离间距
--   [beh2]  cs_fish_behavior 模板注入: size还原(物理域换算)
--   [pick]  cs_variant_pick 模板注入: 随机模式容量加权抽取(群种满编)
--   [tank]  FS全屏发射器×每物种: emitPositionMode=5全屏发射盒, 永生,
--           出生/活动/行为完全由引擎生物网格+水域链决定; 视角零指定
--           (继承引擎鱼群域默认值, 面板可调)
--   [ui]    粒子面板类别"鱼类扩展"(N变体下拉); 发射器由面板/图片sidecar
--           配置驱动
--
-- GLSL注入与动态类型对接:
--   vs/cs 的 type 变量经 uBehaviorAlias 重映射(动态type→行为域6) ⇒
--   注入端 type==6u 守卫自动覆盖本类型; VS 的 meshInfo[ti] 用原始type
--   自有mesh命名空间; fvidx = texIdx - uTexBase[type](own-domain连续
--   槽段直通); 鱼渲染pass守卫=behaviorOf==6集合; cs_emit 出生/变体域
--   按 ptOrig 查 uTypeVariantCount[type]=NSPEC。
--
-- 出生门: register_type 只注册类型容量(槽位/面板/i18n),
-- register_variant×N 延后到 mesh/贴图/注入提交完成后
-- (variantDomainCount=0 ⇒ cs_emit拒生 ⇒ 数据就绪前零出生)。
--
-- GLSL注入正文外置 res/shaders/glsl/particle/inject/fish/*.glsl (git
-- 版本控制 + 编辑器GLSL高亮); 本脚本只做数据bake(物种表→const数组)
-- 与RPC提交; watchdog轮询模板内容变化自动重提交 = 改模板文件即时
-- 热重载, 无需改本脚本/重启。
-- ============================================================================

local M = {}

-- ─── 路径定位 ───────────────────────────────────────────────────────────────
local srcInfo = debug.getinfo(1, "S").source
local THIS_PATH = (srcInfo:sub(1, 1) == "@") and srcInfo:sub(2) or srcInfo
local function thisDir()
	return THIS_PATH:match("^(.*)[\\/]") or "."
end
local FBX_PATH = (thisDir() .. "/res/fish.fbx"):gsub("\\", "/")
local TEX_DIR = (thisDir() .. "/res"):gsub("\\", "/")
-- 日志前置(物种表加载期即需输出, 早于G状态块)
local function log(msg)
	print("[fishtank] " .. tostring(msg))
end
-- fish.dims.json: fish.fbx 的确定性描述文件(解析产物), 随仓库提交, 与素材
-- 同源版本化。有效性判据=fbx字节数(不含mtime: 克隆/检出mtime必漂移; 字节数
-- 跨机器恒定)。素材变更(字节数变)→重算改写→随新fbx一并提交。
local function dimsCachePath()
	return thisDir() .. "/res/fish.dims.json"
end
-- dims描述文件版本(格式变更时+1失效重生成)
local DIMS_CACHE_VER = 7 -- v7: 变体号=species.json数组序(缓存布局变, 强制重算)
-- v6: +pelvZ0/pelvZ1/pelvX/pelvY1腹鳍窗字段
-- v5: parts/anim显式1基数组(索引=变体+1)
-- v3: +fbx指纹/parts/anim/rt尺寸
-- v2: +modelIdx表(tex→fbx.model_list序号)

-- ─── 尺寸链(own-domain 动态槽段: aliasP ⇒ fsv 恒 9) ────────────────────────
-- 双通道分工:
--   物种标定(cm) → VS注入表 tankAnim row2.z = sizeK × cm (发射器无关,
--     per-particle生效, 发射器size乱写也不丢标定);
--   用户倍率    → 发射器 sizeOverride, VS按 size/10 乘入(10=1.0物种原大,
--     0.05..4.0钳), ±14%个体方差由VS内fract(seedN)承担(sizeVariance=0)。
-- VS链(vs_particle_mesh, type重映射6u后命中内置鱼sizeMul表, fsvS恒9):
--   sizeMul=(spScale[9]×1.75)/fullLenF[9]=(2.40×1.75)/0.799=5.257恒定;
--   screenScale=uScreenSize.y/1080;
--   可见全长(px, rt域) = 0.432 × 5.257 × size × screenScale
-- 目标: 全长 = cm × (rtH/TANK_CM) — 分辨率无关的厘米比例
--   ⇒ size = cm×1080/(150×0.432×5.257) = cm×3.17 (rtH约掉)
-- 150cm=大型水族箱视感
local SPSCALE9 = 2.40
local TANK_CM = 150.0
local SIZE_DENOM = 0.432 * (SPSCALE9 * 1.75 / 0.799) -- 0.432×5.257=2.271
-- 显式传rtH(本区块位于 local G 声明之前, 禁闭包捕获G=全局nil陷阱);
-- rtH在公式中分子分母约掉(分辨率无关), 保留参数与链语义一致
local function sizeK(rtH)
	local sc = ((rtH and rtH > 0) and rtH or 1080) / 1080.0
	return (((rtH and rtH > 0) and rtH or 1080) / TANK_CM) / (SIZE_DENOM * sc)
end
-- 大小参数基准: 默认20, 调节范围0~100; 渲染链 size参数/10乘入,
-- 20默认=2.0×scale=1.0原大
local SIZE_BASE = 20.0
-- 观感档字段(数据驱动, species.json行内声明, 非代码白名单):
--   half=true 观感偏大种缩放减半(鲑鳟鲈类全体+鲣/金枪/白斑狗鱼/蓝火口/
--     银鲨/暹罗虎/七彩) — 消费: sizeOf发射器档 + halfH行为间距
--   big=true  巨鱼档(真实成体100-150cm+, 缸内自然标定≈满屏, 默认倍率压到
--     3×0.3; 其余默认10=1.0原大上限100) — 缺省时 cm>=100 自动判巨鱼
local function isBig(sp)
	if sp.big ~= nil then
		return sp.big
	end
	return (sp.cm or 30) >= 100
end
-- 旧默认档(渲染大小不变基准)
local function oldDefOf(sp)
	local base = isBig(sp) and 3.0 or 10.0
	return sp.half and base * 0.5 or base
end
-- 模型缩放比例: 大小参数默认20=旧档实际渲染大小; FISH_SCALE_MUL全物种
-- 同比例减半(渲染全长/物理域size折算/体长链/巡航速度同源, 大小参数链不动)
local FISH_SCALE_MUL = 0.5
local function scaleOf(sp)
	return oldDefOf(sp) / SIZE_BASE * FISH_SCALE_MUL
end
-- 巡航速度基准=体长/秒(BL/s), 单一物理量 — 绝对速度=BL/s×本鱼实际渲染
-- 全长(含个体方差/用户大小滑条/分辨率pxS)。物种个性由 SPECIES 行内
-- beh.blps 承载(单一源): 按生物学巡航速度标定(温带淡水/海水鱼稳态巡游
-- 0.5~2 BL/s; 顶级掠食者低幅大回环, 饵鱼高频小幅)。
-- BL/s=巡航期望速度, 不含逃离/冲刺(esc 倍率独立)。
-- lenOf(sp): 物种渲染全长基准(1080域px, 不含个体方差/用户滑条) — 与 VS
--   tankAnim aP2.z/CS LEN_CM/LEN_B 同一公式单一源。
local function lenOf(sp)
	return SIZE_DENOM * sizeK(1080) * sp.cm * scaleOf(sp)
end
-- cruiseOf(sp): 物种巡航速度(1080域px/s) = 行内BL/s × 渲染全长基准。
-- 消费点: speciesRows(tankBeh row0.x)/roleRows(visR/accel派生)/
-- skinRows(tankSkin row1.y envFS包络)/CRZ_B(威胁避让逃速)。
local function cruiseOf(sp)
	return (sp.beh.blps or 1.0) * lenOf(sp)
end
local function sizeOf(sp)
	-- 默认值统一20(渲染大小由scaleOf保持不变), 范围0~100(sizeMaxOf)
	return SIZE_BASE
end
local function sizeMaxOf(sp)
	-- 全物种统一0~100
	return 100.0
end

-- ─── 物种数据库(数据驱动: res/species.json + 推导层) ────────────────────────
-- 变体号 = species.json数组序(0..N-1自动分配); tex = 与fish.fbx/fish.dims.json
-- 的资产join键。新扩展/新鱼种 = 换fbx+贴图组(dims.json自动重生成) +
-- species.json加条目; 最小条目只需 {tex,cn,en,cm,role}, 其余字段全部按
-- 推导层(role模板×cm公式)补全, 行内同名字段逐个覆盖推导值。
-- 字段: cm=真实成体体长; role 0=普通群游 1=掠食 2=猎物 3=斗鱼 4=底栖觅食
--   5=领地 6=顶层掠食; beh=cs_fish_params 8参(blps巡航体长/秒 巡航=cruiseOf
--   =blps×渲染全长基准, seek转向刚度 turn航路扇区半角 leg航段周期 alt垂直带
--   zuse纵深幅度 bank转弯倾斜 flock群游); esc/post/escT=逃离倍率/后继(sprint
--   疾游|settle减速|dart急转zigzag)/周期s; anim(swimHz摆尾Hz sway摆幅 pect
--   胸鳍Hz soft鳍尾柔软度0..1 stiff前体刚性); eco(n推荐粒数 rate发射率
--   y/sx/sy/sz发射盒分数域); 标志 barb须 fil丝 bigTail半月尾 noIdle恒游
--   idle懒游占比0|0.3|0.8 half观感减半 big巨鱼档
-- (贴图=素材忠实直传(fbx.model_to_particle), 无键控无自动推导 — 顶点UV保持
--  fbx原始值(v tile域), FS注入端按查看器同公式采样)

-- 推导层①: role基准模板(全物种分布标定值)
local ROLE_TPL = {
	[0] = {
		blps = 1.50,
		seek = 450,
		turn = 0.52,
		leg = 3.1,
		alt = 0.09,
		zuse = 0.95,
		bank = 1.00,
		flock = 1,
		esc = 2.1,
		post = "settle",
		escT = 2.0,
		sway = 0.82,
		pect = 2.9,
		soft = 0.47,
		stiff = 0.55,
		y = 0.11,
	},
	[1] = {
		blps = 1.30,
		seek = 390,
		turn = 0.42,
		leg = 3.7,
		alt = -0.05,
		zuse = 0.95,
		bank = 0.95,
		flock = 0,
		esc = 2.2,
		post = "settle",
		escT = 2.2,
		sway = 0.84,
		pect = 2.3,
		soft = 0.45,
		stiff = 0.45,
		y = -0.05,
	},
	[2] = {
		blps = 2.30,
		seek = 490,
		turn = 0.61,
		leg = 2.5,
		alt = 0.16,
		zuse = 0.94,
		bank = 1.13,
		flock = 1,
		esc = 2.3,
		post = "dart",
		escT = 2.1,
		sway = 0.83,
		pect = 4.4,
		soft = 0.76,
		stiff = 0.61,
		y = 0.18,
	},
	[3] = {
		blps = 0.95,
		seek = 455,
		turn = 0.58,
		leg = 3.4,
		alt = 0.01,
		zuse = 0.56,
		bank = 1.02,
		flock = 0,
		esc = 2.0,
		post = "settle",
		escT = 2.0,
		sway = 1.08,
		pect = 3.2,
		soft = 0.80,
		stiff = 0.80,
		y = -0.02,
	},
	[4] = {
		blps = 0.73,
		seek = 280,
		turn = 0.41,
		leg = 6.0,
		alt = -0.33,
		zuse = 0.72,
		bank = 0.78,
		flock = 0,
		esc = 2.3,
		post = "settle",
		escT = 2.3,
		sway = 1.25,
		pect = 2.7,
		soft = 0.72,
		stiff = 0.85,
		y = -0.36,
	},
	[5] = {
		blps = 0.95,
		seek = 345,
		turn = 0.48,
		leg = 4.3,
		alt = -0.02,
		zuse = 0.68,
		bank = 0.97,
		flock = 0,
		esc = 2.1,
		post = "settle",
		escT = 2.3,
		sway = 1.05,
		pect = 2.7,
		soft = 0.73,
		stiff = 0.57,
		y = -0.02,
	},
	[6] = {
		blps = 1.00,
		seek = 400,
		turn = 0.40,
		leg = 3.2,
		alt = 0.25,
		zuse = 0.90,
		bank = 0.92,
		flock = 0,
		esc = 3.3,
		post = "sprint",
		escT = 3.1,
		sway = 0.74,
		pect = 2.2,
		soft = 0.32,
		stiff = 0.70,
		y = 0.22,
	},
}
-- 推导层②: cm体型公式 — 小鱼高频/高机动/大群体, 大鱼低频/独游
local function clampN(x, lo, hi)
	return math.min(math.max(x, lo), hi)
end
local function deriveSpecies(cm, role)
	local t = ROLE_TPL[role] or ROLE_TPL[0]
	local cmc = clampN(cm, 1, 500)
	local sizeF = (30.0 / cmc) ^ 0.15 -- 体型因子(小鱼>1大鱼<1)
	local n = clampN(math.floor(50.0 / cmc ^ 0.75 + 0.5), 1, 24)
	if role == 1 or role == 6 then
		n = clampN(n, 1, 3)
	end -- 掠食独游
	if role == 3 then
		n = clampN(n, 1, 4)
	end
	return {
		beh = {
			blps = clampN(t.blps * sizeF, 0.4, 4.5),
			seek = t.seek,
			turn = clampN(t.turn * sizeF ^ 0.5, 0.30, 0.70),
			leg = t.leg,
			alt = t.alt,
			zuse = t.zuse,
			bank = t.bank,
			flock = t.flock,
		},
		esc = t.esc,
		post = t.post,
		escT = t.escT,
		anim = {
			swimHz = clampN(9.0 * cmc ^ -0.42, 1.0, 5.0),
			sway = t.sway,
			pect = t.pect,
			soft = t.soft,
			stiff = t.stiff,
		},
		eco = {
			n = n,
			rate = clampN(n / 6.0, 0.2, 3.0),
			y = t.y,
			sx = clampN(0.55 + cm / 300.0, 0.55, 0.94),
			sy = clampN(0.35 + cm / 280.0, 0.35, 0.90),
			sz = clampN(0.25 + cm / 400.0, 0.25, 0.50),
		},
		idle = t.flock > 0.5 and 0.0 or (role == 4 and 0.8 or 0.3),
	}
end
-- 推导层③: json条目 → 完整物种行(缺省字段逐个用推导值补; noIdle强恒游)
local function fillSpecies(e, i)
	local cm = tonumber(e.cm) or 30.0
	local role = tonumber(e.role) or 0
	local d = deriveSpecies(cm, role)
	local sp = {
		variant = i - 1,
		tex = e.tex,
		cn = e.cn or e.tex,
		en = e.en or e.tex,
		cm = cm,
		role = role,
		beh = {},
		esc = e.esc or d.esc,
		post = e.post or d.post,
		escT = e.escT or d.escT,
		anim = {},
		eco = {},
		idle = (e.idle ~= nil) and e.idle or d.idle,
		noIdle = e.noIdle,
		half = e.half,
		big = e.big,
		barb = e.barb,
		fil = e.fil,
		bigTail = e.bigTail,
		tr = type(e.tr) == "table" and e.tr or nil,
	}
	for _, k in ipairs({ "blps", "seek", "turn", "leg", "alt", "zuse", "bank", "flock" }) do
		sp.beh[k] = (e.beh and e.beh[k] ~= nil) and e.beh[k] or d.beh[k]
	end
	for _, k in ipairs({ "swimHz", "sway", "pect", "soft", "stiff" }) do
		sp.anim[k] = (e.anim and e.anim[k] ~= nil) and e.anim[k] or d.anim[k]
	end
	for _, k in ipairs({ "n", "rate", "y", "sx", "sy", "sz" }) do
		sp.eco[k] = (e.eco and e.eco[k] ~= nil) and e.eco[k] or d.eco[k]
	end
	if sp.noIdle then
		sp.idle = 0.0
	end
	return sp
end

-- 加载器: res/species.json(vfs优先+io回退, 同dims.json读取模式) → SPECIES。
-- 容错: ①json坏/缺 → 回退fish.dims.json texDims键序全推导(cn=tex名,
--   cm=30/role=0), 扩展永不因数据文件问题死锁; ②条目缺tex跳过;
-- ③json物种与dims模型域不齐 → 告警按json走(缺模型槽走checkSlots
--   missing路径自愈, 多余模型不登记变体)。
local function loadSpeciesTable()
	local function readText(p)
		local s = fcc.read_file and fcc.read_file(p) or nil
		if not s then
			local f = io.open(p, "r")
			if f then
				s = f:read("*a")
				f:close()
			end
		end
		return s
	end
	local raw = readText(thisDir() .. "/res/species.json")
	local entries = nil
	if raw then
		local ok, arr = pcall(fcc.json_decode, raw)
		if ok and type(arr) == "table" and #arr > 0 then
			entries = arr
		else
			log("⚠species.json解析失败, 回退dims.json全推导")
		end
	else
		log("⚠species.json缺失, 回退dims.json全推导")
	end
	if not entries then
		entries = {}
		local dstr = readText(dimsCachePath())
		if dstr then
			local ok, d = pcall(fcc.json_decode, dstr)
			if ok and type(d) == "table" and type(d.texDims) == "table" then
				local names = {}
				for name in pairs(d.texDims) do
					names[#names + 1] = name
				end
				table.sort(names)
				for _, name in ipairs(names) do
					entries[#entries + 1] = { tex = name }
				end
			end
		end
		if #entries == 0 then
			log("⚠dims.json亦不可用 — 物种表为空, 待补species.json")
		end
	end
	local t = {}
	for i, e in ipairs(entries) do
		if type(e) == "table" and type(e.tex) == "string" then
			t[#t + 1] = fillSpecies(e, i)
		end
	end
	return t
end
local SPECIES = loadSpeciesTable()
local NSPEC = #SPECIES

-- 变体号 → 物种索引(注入端按变体号索引参数表 = 与发射器索引解耦)
local BYVAR = {}
for i, sp in ipairs(SPECIES) do
	BYVAR[sp.variant] = i
end
-- 参数表行数=变体域0..NSPEC-1(未用变体回退物种1); 容量=2×NSPEC(albedo+法线)
local NTAB = NSPEC

-- ─── i18n翻译注册(add_translation: lua宿主v14+; 旧exe缺API静默跳过) ──────────
-- UI全链路tr(): 类别名/物种名/panel label/tip按UI语言显示。zh_CN/en_US由
-- register_type/register_variant注册; 此处补 ja_JP/fr_FR/de_DE/es_ES — 物种
-- 名来自species.json tr字段(数据驱动, 缺失语言回退中文), 类别名/panel文案
-- 是本扩展固定文本。
local I18N_PANEL = {
	["鼠标吸引"] = {
		ja_JP = "マウス誘引",
		fr_FR = "Attraction souris",
		de_DE = "Maus-Anziehung",
		es_ES = "Atracción del ratón",
	},
	["尾摆幅度"] = {
		ja_JP = "尾びれ振幅",
		fr_FR = "Amplitude caudale",
		de_DE = "Schwanzamplitude",
		es_ES = "Amplitud de cola",
	},
	["游动速度"] = {
		ja_JP = "遊泳速度",
		fr_FR = "Vitesse de nage",
		de_DE = "Schwimmgeschwindigkeit",
		es_ES = "Velocidad de nado",
	},
	["正值吸引(鱼绕鼠标游聚), 负值驱散(半径×0.33). 绝对值=影响半径(图片半宽的倍数)"] = {
		ja_JP = "正の値で誘引(マウス周囲に集合), 負の値で散開(半径×0.33). 絶対値=影響半径(画像半幅の倍数)",
		fr_FR = "Positif: attire les poissons autour de la souris; négatif: disperse (rayon ×0.33). Valeur absolue = rayon d'influence (multiple de la demi-largeur)",
		de_DE = "Positiv: Anziehung (Fische sammeln sich um den Zeiger), negativ: Zerstreuung (Radius ×0.33). Betrag = Einflussradius (Vielfaches der halben Bildbreite)",
		es_ES = "Positivo: atrae (peces alrededor del ratón); negativo: dispersa (radio ×0.33). Valor absoluto = radio de influencia (múltiplo del medio ancho)",
	},
	["鱼尾/身体游动波幅度倍率: 0=定帧展示, 1.0=物种标定, 1.5=狂摆"] = {
		ja_JP = "尾びれ/体の遊泳波の振幅倍率: 0=静止, 1.0=種標準, 1.5=激しく",
		fr_FR = "Multiplicateur d'amplitude de l'onde: 0=figé, 1.0=calibrage espèce, 1.5=frénétique",
		de_DE = "Amplitudenfaktor der Schwimmwelle: 0=Standbild, 1.0=Artkalibrierung, 1.5=wild",
		es_ES = "Multiplicador de amplitud de onda: 0=inmóvil, 1.0=calibrado por especie, 1.5=enérgico",
	},
	["游速倍率: 0=悬停, 1.0=原速, 3.0=极速"] = {
		ja_JP = "遊泳速度倍率: 0=静止, 1.0=標準, 3.0=全速",
		fr_FR = "Multiplicateur de vitesse: 0=sur place, 1.0=normal, 3.0=éclair",
		de_DE = "Geschwindigkeitsfaktor: 0=schweben, 1.0=normal, 3.0=Sprint",
		es_ES = "Factor de velocidad: 0=quieto, 1.0=normal, 3.0=máximo",
	},
}
local function registerI18n()
	local addtr = fcc and fcc.add_translation
	if type(addtr) ~= "function" then
		return
	end
	local function reg(key, langs)
		for lang, name in pairs(langs) do
			addtr(lang, key, name)
		end
	end
	reg("鱼类扩展", {
		ja_JP = "魚類エクステンション",
		fr_FR = "Extension Poissons",
		de_DE = "Fisch-Erweiterung",
		es_ES = "Extensión de Peces",
	})
	for k, v in pairs(I18N_PANEL) do
		reg(k, v)
	end
	for _, sp in ipairs(SPECIES) do
		if sp.tr then
			reg(sp.cn, sp.tr)
		end
	end
	return true
end
local I18N_OK = registerI18n()

-- ─── 状态(跨热重载继承: _G.__FISHTANK) ──────────────────────────────────────
local G = _G.__FISHTANK or {}
G.enabled = G.enabled or false
G.resReady = G.resReady or false
G.type = G.type or nil -- 动态类型id(register_type 分配; 热重载继承)
G.base = G.base or nil -- 贴图槽段基址(同上)
G.emitterIds = G.emitterIds or {} -- 物种索引 → emitter id(FS高位标记)
G.foreignBaseline = G.foreignBaseline or {} -- 开缸时既有foreign发射器id集(让位豁免基线)
G.worldH = G.worldH or 1080
G.worldW = G.worldW or 1920
G.rtW = G.rtW or 1920
G.rtH = G.rtH or 1080
G.parts = G.parts or {} -- variant → parts[] (几何动画域)
G.anim = G.anim or {} -- variant → {tailZ, zMin, zMax, ...}
G.normIdx = G.normIdx or 0 -- 下一个待计算法线槽的变体号(0..35)
G.modelIdx = G.modelIdx or nil -- tex→model序号(dims描述文件)
G.shadersDone = G.shadersDone or false -- shader注入幂等守卫
G.resSubmitted = G.resSubmitted or false
-- 36变体登记完成标志 — register_type只注册类型容量(槽位/面板/i18n),
-- register_variant×N延后到registerResources成功后(variantDomainCount=0
-- ⇒ cs_emit出生门拒生 ⇒ 数据就绪前零出生)
G.variantsDone = G.variantsDone or false
-- G.texDims: 素材名→[w,h](applyOnce只查一次mesh_groups, 静态数据复用)
_G.__FISHTANK = G
-- 调试开关(FCC_FISHDBG=1) — 逐物种anim打印等诊断输出门控;
-- 应用阶段计时(os.clock=MSVCRT墙钟, 进程相对秒)
local DBG = os and os.getenv and os.getenv("FCC_FISHDBG") == "1" or false
local T0 = os.clock()
local function ts()
	return string.format("%.2fs", os.clock() - T0)
end

-- 热重载re-run(类型已注册=G.type非nil)时重置资源管线守卫 — applyOnce幂等
-- 重跑: 引擎m2p指纹未变槽位零开销跳过, 变更资产自动重解析重上传 ⇒ 贴图/
-- fbx热重载通路(本体侧extScan检测包内任意文件变化→重跑本脚本→此处接力)。
-- 注入守卫同步重置: 动画域(G.parts)可能随新mesh刷新 → 注入代码重提交
-- (内容寻址: 未变不触发重编译)。
if G.type then
	G.resReady, G.resSubmitted, G.shadersDone = false, false, false
	-- m2pOkOnce同步清: 收敛门"ok后纯slot_info轮询"会拦截m2p重提 —
	-- 热重载变更的贴图/fbx必须重新上传, 门必须重开
	G.m2pOkOnce, G.waitN = nil, 0
	-- anim命中态的fbx字节数复验 — re-run时texDims已驻G不再走盘描述文件
	-- 校验块, fbx热改后必须回重算路径(否则注入沿用旧anim=mesh错位)
	if G.animFromCache and fcc.file_stat then
		local st = fcc.file_stat(FBX_PATH)
		local s1 = st and math.floor(st.size or -1) or -1
		if not G.animFbxSig or s1 ~= G.animFbxSig[1] then
			G.animFromCache = nil
			G.anim, G.parts = {}, {}
			log("热重载re-run: fbx素材已变更, anim描述失效转重算")
		end
	end
	log("热重载re-run: 资源管线幂等重跑(变更贴图/fbx自动重上传)")
end

-- ============================================================================
-- 动态类型注册(零硬编码 — id/槽段由 fcc registry 分配)
-- ============================================================================
-- texDims: 贴图名→[w,h] (fbx.mesh_groups textures); atlas槽位=贴图原生
-- 分辨率禁止改变 — 逐槽声明, 布局一次成型零压扁零relayout
local function ensureType(texDims)
	-- tex_slot_dims: 每变体槽=[w,h]原生贴图尺寸(缺省回退256×256);
	-- tex_slot_w/h=段缺省值。布局消费前生效, 零缩放直传。
	-- 变体容量=NSPEC*2: 前N槽=鱼albedo, 后N槽(base+NSPEC+v)=按贴图亮度
	-- 自动计算的法线贴图(与albedo同尺寸, set_pixels上传; 鱼粒子texIdx只
	-- 落前N, 后N槽仅FS注入按需采样)。register_variant仍只登记N鱼变体
	-- → variantDomainCount=36(出生门/随机抽取/CS变体域全部不变)。
	-- texDims缺项=mesh_groups解析时部分贴图解码瞬时失败(缺名) — 兜底
	-- 256x256会让256x512素材槽声明错尺寸, 错位且收敛死循环; 缺项必须
	-- ①响亮日志②禁止写盘持久化坏数据(见saveAnimCache)
	local dims = {}
	local missing = {}
	for v = 0, NSPEC - 1 do
		local sp = SPECIES[BYVAR[v] or 1]
		local d = texDims and texDims[sp.tex]
		if d and d[1] > 0 and d[2] > 0 then
			dims[v + 1] = d
		else
			dims[v + 1] = { 256, 256 }
			missing[#missing + 1] = sp.tex
		end
		dims[NSPEC + v + 1] = dims[v + 1] -- 法线槽与albedo同尺寸
	end
	G.texDimsIncomplete = #missing > 0
	if G.texDimsIncomplete then
		log("⚠texDims缺项" .. #missing .. "个(解析瞬时失败?): " .. table.concat(missing, ","))
	end
	if G.type and G.base then
		-- 热重载继承的类型: 廉价校验registry仍持有(slot_info 查base, 纯CPU)
		local si = fcc.rpc("particle", "slot_info", { type = G.type, variant = 0 })
		if type(si) == "table" and si.slot and si.slot >= 0 then
			-- 槽位尺寸自愈: 用当前texDims幂等重声明(引擎侧尺寸变化自动
			-- 排队relayout), 无需unregister重注册(会清变体域); 签名门:
			-- applyOnce每0.25s重试都过此路径, dims未变时省RPC
			if texDims and not G.texDimsIncomplete then
				local dsig = {}
				for _, d in ipairs(dims) do
					dsig[#dsig + 1] = d[1] .. "x" .. d[2]
				end
				dsig = table.concat(dsig, ",")
				if G.declaredSig ~= dsig then
					local rd = fcc.rpc("particle", "declare_slot_dims", { type = G.type, dims = dims })
					G.declaredSig = dsig
					if DBG then
						log("槽尺寸自愈重声明: " .. tostring(rd and rd.declared))
					end
				end
			end
			return true
		end
		log("type " .. tostring(G.type) .. " invalid (unregistered?), re-register")
		G.type, G.base = nil, nil
		-- 类型失效重注册=registry全新(变体/mesh/贴图登记全清) — 资源就绪
		-- 标志同步作废, 让applyOnce重走全管线(资源幂等补传+变体重登记),
		-- 防止"resReady=true但变体域空"的死锁态
		G.resReady = false
		G.variantsDone = false
		G.m2pOkOnce = nil -- 新registry: m2p必须重新走(门重开)
		G.declaredSig = nil -- 新type: 槽声明签名重置
	end
	-- panel(通用面板参数声明API): 本类别自描述滑条(数据驱动UI, 核心零特判)
	local rt = fcc.rpc("particle", "register_type", {
		name = "鱼类扩展",
		name_en = "Fish Extension",
		behavior = 6,
		variants = NSPEC * 2,
		defaultsFrom = 6,
		tex_slot_w = 256,
		tex_slot_h = 256,
		tex_slot_dims = dims,
		-- 随机模式默认大小参数=20(模型缩放比例基准, 渲染大小不变) +
		-- 默认最大粒子数=60 + 光照水平/俯仰角=90/90 — 面板滑条初值/
		-- rpcMakeEmitter/恢复默认三源同源(TypeMeta countDefault/lightDefaults)
		size = SIZE_BASE,
		count = 60,
		light_roll = 90.0,
		light_pitch = 90.0,
		-- 通用defaults API(register_type defaults={字段=值}): 面板初值/
		-- 恢复默认/rpcMakeEmitter新建三源同源; 字段名=引擎映射表
		-- light_str→光照强度, env_ambient→环境光系数; normal_map默认0 —
		-- 面板新建/恢复默认/rpc新建鱼类发射器法线贴图全链默认关(法线槽
		-- 仍驻场atlas备用, 仅参数开启才采样)。
		-- 视角零声明 — 继承引擎鱼群行为域默认(behaviorOf==Snow,
		-- rpcMakeEmitter/applyTypeDefaults内置继承, 值随引擎单源演进)。
		defaults = { light_str = 1.5, env_ambient = 1.2, normal_map = 0 },
		-- 类别默认发射位置=0全图(main系统) — 面板选中鱼类扩展类别后
		-- 新发射器默认全图发射, 可经面板「发射位置」切换其它模式
		emit_mode = 0,
		-- fsExitDefaults(引擎通用API) — 面板「发射位置」从全屏(5)切到
		-- 非全屏(0~4)时, 引擎fsExit分支同帧把声明字段写入面板滑条
		-- (paramSize_等)+重建后发射器(e.sizeOverride等)双端。
		-- 大小: 非全屏10。一次性切换重置非持续强制(用户可再调)。
		-- 视角零声明 — 切换不触碰视角, 面板当前值(滑条)原样保留。
		-- 热重载不重注册(ensureType类型有效早退), 声明随重启生效。
		fsExitDefaults = {
			sizeOverride = 10.0,
			lightDirStr = 1.0,
			envAmbientCoef = 1.0,
		},
		-- fsEnterDefaults(引擎对称钩子, 镜像fsExitDefaults) — 「发射位置」
		-- 切入全屏(非5→5)时同帧置面板滑条+重建后发射器双端:
		-- sizeOverride=20(SIZE_BASE同源, FS暗底大粒子)+顶光1.5。
		-- 视角零声明 — 继承引擎鱼群域默认, 面板可调。
		fsEnterDefaults = { sizeOverride = 20.0, lightDirStr = 1.5 },
		panel = {
			{
				param = "vfxC",
				label = "鼠标吸引",
				min = -1.0,
				max = 1.0,
				default = -0.3,
				fmt = "%.2f",
				tip = "正值吸引(鱼绕鼠标游聚), 负值驱散(半径×0.33). 绝对值=影响半径(图片半宽的倍数)",
			},
			{
				param = "vfxB",
				label = "尾摆幅度",
				min = 0.0,
				max = 1.5,
				default = 1.0,
				fmt = "%.2f",
				tip = "鱼尾/身体游动波幅度倍率: 0=定帧展示, 1.0=物种标定, 1.5=狂摆",
			},
			{
				param = "vfxF",
				label = "游动速度",
				min = 0.0,
				max = 3.0,
				default = 1.0,
				fmt = "%.2f",
				tip = "游速倍率: 0=悬停, 1.0=原速, 3.0=极速",
			},
		},
	})
	if type(rt) == "table" and rt.ok == true and rt.type and rt.base then
		G.type, G.base = rt.type, rt.base
		G.normIdx = 0 -- 新注册=全新槽空间, 法线槽重走上传管线
		-- (上方热重载继承早退路径不重置: 引擎槽位常驻已上传)
		G.normProbeDone = nil -- 新槽空间重新探测
		log(
			"register_type ok: type="
				.. G.type
				.. " base="
				.. G.base
				.. " variants="
				.. tostring(rt.variants)
				.. " dims="
				.. tostring(rt.tex_slot_dims)
				.. " fsExit="
				.. tostring(rt.fsExitDefaultsCount)
		)
		-- 此处**不再**register_variant×N — register_type即触发sidecar
		-- "注册即复活"(killAll+按槽重发发射器), 若同时变体域=36,
		-- cs_emit立即开始出生而mesh/贴图/注入未落地 = 出生一批错误数据的
		-- 鱼。变体登记延后到registerResources成功后(registerVariants, 见
		-- 下), variantDomainCount=0期间出生门(cs_emit uTypeVariantCount<=0
		-- 拒生)恒关 ⇒ 数据就绪前零出生。槽位/贴图/面板不受影响:
		-- ensureSlots按varCapacity预排(register_type端), set_texture_fbx/
		-- set_mesh_fbx按capacity门控(非domain count)。
		return true
	end
	log("register_type fail: " .. tostring(rt and rt.error))
	return false
end

-- 出生门=数据就绪(mesh/贴图/注入**提交**完成) — 出生走当时在位的程序集
-- (稳态=base版, 随后注入版后台编译adopt无缝换装为正确体型/游姿); 注入版
-- 编译移出出鱼关键路径(改lua冷编译期间鱼先出, adopt落地即全群换装)。
-- injectGenSub/injectSubmitT保留(fishtank_gate诊断用)。

-- ── 变体元信息登记(出生门: 仅数据就绪后调用) ───────────────────────────────
-- 名字进UI下拉/i18n; 槽=base+variant按变体号对位;
-- count=该物种推荐最大粒子数(面板选物种时应用为粒数滑条; 随机模式硬上限
-- 走cs_variant_pick注入的CAPS表, 同源eco.n); size/sizeMax=巨鱼档(见
-- sizeOf/sizeMaxOf)。
-- 幂等: defineVariant重复注册同槽=覆盖重定义, 重试安全。
local function registerVariants()
	if not (G.type and G.base) then
		return false
	end
	local okAll = true
	for i, sp in ipairs(SPECIES) do
		local r = fcc.rpc("particle", "register_variant", {
			type = G.type,
			slot = G.base + sp.variant,
			id = sp.tex,
			cn = sp.cn,
			en = sp.en,
			count = sp.eco and sp.eco.n or nil,
			size = sizeOf(sp),
			sizeMax = sizeMaxOf(sp),
		})
		if not (type(r) == "table" and type(r.slot) == "number" and r.slot >= G.base) then
			okAll = false
			log("register_variant fail #" .. i .. " " .. sp.cn .. ": " .. tostring(r and r.error))
		end
	end
	return okAll
end

-- ============================================================================
-- 资源管线: 本体 fbx.model_to_particle 一步直通 —
--   网格: fbx.model_list 模型序号 → 变体号 一次 build+commit
--         (uvRaw: 顶点UV=fbx原始值唯一事实源, 零morph补偿零fsScale)
--   贴图: 接口自动直传atlas槽(素材原生分辨率零变换; 忠实像素无键控)
-- 本扩展零贴图折腾(无keys/无dilate/无uvTile声明)。
-- 幂等: 已上传且尺寸=素材原生的槽跳过, 只补缺失槽; 全N槽收敛才true。
-- ============================================================================
local FULL_LEN = 0.432

local function modelIndexByTex()
	if G.modelIdx then
		return G.modelIdx
	end
	-- 防御回退(dims缓存缺失时): fbx.model_list全量解析(常态路径不走此)
	local ml = fcc.rpc("fbx", "model_list", {
		path = FBX_PATH,
		tex_dirs = { TEX_DIR },
	})
	local map = {}
	if type(ml) == "table" and ml.ok then
		for _, m in ipairs(ml.models or {}) do
			map[m.tex] = m.model
		end
	end
	G.modelIdx = map
	return map
end

-- ── 收敛校验: 全部槽 uploaded 且 w/h=素材原生尺寸 ────────────────────────
-- 返回 true | false, why('wait'|'mismatch'), 首坏槽诊断串
-- 'wait'=贴图在pending队列等渲染帧flush推进, 纯等待态重提m2p无益, 不计入
-- 自愈计数; 'mismatch'(尺寸不符/slot_info无效)=真坏数据才该自愈。
local function checkSlots(texDims)
	for v = 0, NSPEC - 1 do
		local sp = SPECIES[BYVAR[v] or 1]
		local si = fcc.rpc("particle", "slot_info", { type = G.type, variant = v })
		local want = texDims and texDims[sp.tex] or nil
		local why = nil
		if type(si) ~= "table" then
			why = "mismatch"
		elseif not si.uploaded then
			why = "wait"
		elseif want and want[1] > 0 and want[2] > 0 and (si.w ~= want[1] or si.h ~= want[2]) then
			why = "mismatch"
		end
		if why then
			return false,
				why,
				string.format(
					"v=%d %s (slot=%s uploaded=%s w=%s h=%s want=%sx%s)",
					v,
					sp.cn,
					tostring(si and si.slot),
					tostring(si and si.uploaded),
					tostring(si and si.w),
					tostring(si and si.h),
					tostring(want and want[1]),
					tostring(want and want[2])
				)
		end
	end
	return true
end

local function submitResources(texDims, force)
	-- 收敛分类门: 本进程m2p已ok过 → 后续轮询纯slot_info(零m2p=零36×
	-- commitFbxVariants GL job, 防0.25s重试风暴); 'wait'由渲染循环推进
	-- (等待计数, 12s无进展才兜底重提一次); 'mismatch'才重新走全量m2p
	-- (槽尺寸重声明+relayout+补传)。
	-- force=true(运行期贴图自愈): 跳过门直接m2p — 检测的缺失槽是"曾上传
	-- 后被relayout清掉"的运行期事实, 必须立即补传(引擎幂等, 已收敛槽
	-- 零开销)。
	if G.m2pOkOnce and not force then
		local ok, why, diag = checkSlots(texDims)
		if ok then
			return true
		end
		if why == "wait" then
			G.waitN = (G.waitN or 0) + 1
			if G.waitN >= 48 then
				log("收敛等待" .. G.waitN .. "轮(12s)无进展, 重新m2p补传兜底: " .. diag)
				G.waitN = 0
				G.m2pOkOnce = nil
			else
				return false, "wait"
			end
		else
			G.waitN = 0
			G.m2pOkOnce = nil -- mismatch: 重新m2p(声明正确dims路径)
		end
	end
	-- items恒全量36提交:
	--   ①引擎逐模型指纹命中=零fbx解析+零mesh构建(miss自动加载scene);
	--   ②贴图同指纹同槽幂等跳过(引擎s_m2pUploaded);
	--   ③子集提交不可用: commitFbxVariants是整type替换语义, 子集提交会把
	--     已收敛槽mesh清掉。
	local map = (G.modelIdx and next(G.modelIdx)) and G.modelIdx or modelIndexByTex()
	local items = {}
	for v = 0, NSPEC - 1 do
		local sp = SPECIES[BYVAR[v] or 1]
		items[#items + 1] = { model = map[sp.tex], variant = v }
	end
	local r = fcc.rpc("fbx", "model_to_particle", {
		path = FBX_PATH,
		type = G.type,
		items = items,
		tex_dirs = { TEX_DIR }, -- miss路径自动解析scene+贴图指纹源
		yawQuarters = -1, -- (x,y,z)→(-z,y,x): FBX头-X→-Z游向
		-- fbx原生Y向本就与FS管线匹配(模型查看器/粒子双路一致), 不声明
		-- flipY(引擎参数保留, 通用能力)
		fitLength = FULL_LEN, -- 全长归一化
		max_tris = 0, -- 全量几何(抽样会把鱼身抽成镂空)
		anim = true,
	})
	-- mesh已commit即记录parts — ok=false仅贴图relayout挂起时(槽尺寸重
	-- 声明→relayout pending→该槽ok=false且无error, mesh先于贴图已提交),
	-- 下轮全量重提(引擎幂等, relayout完成即收敛)。
	if r and r.mesh and r.mesh.variants then
		for _, e in ipairs(r.mesh.variants) do
			G.parts[e.variant] = e.parts or {}
		end
	end
	G.resSubmitted = true
	if not r or r.ok ~= true then
		local err = tostring(r and r.error or "")
		G.lastM2P = err -- 诊断: 远程可查的失败原因
		log(
			"model_to_particle fail("
				.. #items
				.. " items): "
				.. err
				.. " (基础设施未就绪/贴图relayout挂起=等待路径, 下轮推进)"
		)
		-- 基础设施未就绪(GL init期)/relayout挂起='wait'等待;
		-- 真错误(贴图not found等)='mismatch'计入自愈
		if err ~= "" and not string.find(err, "not ready") and not string.find(err, "not active") then
			return false, "mismatch"
		end
		return false, "wait"
	end
	local c = (type(r.cache) == "table") and r.cache or {}
	log(
		"model_to_particle ok: "
			.. #items
			.. " models"
			.. (
				c.enabled
					and (" [cache: mesh " .. tostring(c.meshServed) .. "/" .. #items .. ", tex " .. tostring(
						c.texLoaded
					) .. "]")
				or " [cache off]"
			)
	)
	G.m2pOkOnce = true
	G.waitN = 0
	local ok, why, diag = checkSlots(texDims)
	if not ok then
		G.lastSlotBad = diag -- 诊断: 首个未收敛槽
		if not G.slotDiag then
			G.slotDiag = true
			log("槽收敛(" .. why .. ", 每窗一次): " .. diag)
		end
		return false, why
	end
	if G.slotDiag then
		log("槽收敛恢复: 全N槽就绪")
		G.slotDiag = nil
	end
	return true
end

-- ============================================================================
-- 动画域计算: 从 parts(几何AABB) 推导注入端所需阈值
-- ============================================================================
-- 部件分类(部件名不可靠(fbx节点名=乱码拼音) → 几何启发式):
--   身体 = 三角形数最多部件
--   尾鳍 = 非身体部件中 bb.zmax 最大者(体后最远) — 其 bb.zmin = 尾柄枢轴
--   眼睛 = 非身体小件, 吻端区, 侧位(|x心|显著) — 先于胸鳍识别并从胸鳍
--          候选排除(防拍动窗口盖住眼部)
--   鱼须 = 非身体小件触及吻端极前(zmin≤zMin+2%zSpan)且|x|窄(<0.6×bodyHalfW)
--          (金龙鱼嘴部短须: 纯柔性跟随嘴部)
--   胸鳍 = 非身体/非尾鳍/非眼/非须部件中 max|x| 最大且超过 bodyHalfW 者
--        (体前54%区限定防腹鳍误选)
local function computeAnim(variant)
	local parts = G.parts[variant] or {}
	if #parts == 0 then
		return nil
	end
	local sp = SPECIES[BYVAR[variant] or 1]
	local bodyIdx, bestTris = 1, -1
	for i, p in ipairs(parts) do
		if (p.count or 0) > bestTris then
			bestTris = p.count
			bodyIdx = i
		end
	end
	local zMin, zMax = 1e30, -1e30
	for _, p in ipairs(parts) do
		local bb = p.bb
		if bb then
			zMin = math.min(zMin, bb[3])
			zMax = math.max(zMax, bb[6])
		end
	end
	local zSpan = math.max(zMax - zMin, 1e-6)
	local bodyHalfW, bodyTopY, bodyBotY = 0.0, 0.0, 0.0
	if parts[bodyIdx].bb then
		local bb = parts[bodyIdx].bb
		bodyHalfW = math.max(math.abs(bb[1]), math.abs(bb[4]))
		bodyTopY = bb[5] -- 背侧轮廓(素材域背=+Y)
		bodyBotY = bb[2] -- 腹侧轮廓
	end
	local tailIdx, tailMaxZ = nil, -1e30
	for i, p in ipairs(parts) do
		if i ~= bodyIdx and p.bb then
			if p.bb[6] > tailMaxZ then
				tailMaxZ = p.bb[6]
				tailIdx = i
			end
		end
	end
	-- 逐部件几何分类(眼/须)
	-- 眼对打分制 — 36物种真眼特征: nv=192绝对主流, cz=吻端5~28%(长吻种
	-- 靠后), diag=3~14%zSpan, |cx|≈0.7~1.1半宽; 打分=nv192先验2.0+
	-- cz0.10先验1.2+|cx|1.0+diag0.07先验0.8; top2=与top1三元组匹配件
	-- (|Δcz|<4%zSpan+|Δnv|<15%+|Δdiag|<4%zSpan, 左右眼cz/nv/尺寸恒一致;
	-- 无匹配=单眼)。frontLim 0.32(蓝枪鱼cz0.284)。
	local eyeA, eyeB, barbA, barbB
	local eyeCand = {}
	local frontLim = zMin + zSpan * 0.32
	for i, p in ipairs(parts) do
		if i ~= bodyIdx and i ~= tailIdx and p.bb then
			local bb = p.bb
			local dx, dy, dz = bb[4] - bb[1], bb[5] - bb[2], bb[6] - bb[3]
			local diag = math.sqrt(dx * dx + dy * dy + dz * dz)
			local cx = (bb[1] + bb[4]) * 0.5
			local cz = (bb[3] + bb[6]) * 0.5
			local small = (p.count or 0) <= 1400 and diag < zSpan * 0.16
			-- 眼睛: 吻端区小件, 侧位(|x心|显著)
			if small and cz < frontLim and math.abs(cx) >= bodyHalfW * 0.15 then
				local nv = p.count or 0
				local czF = (cz - zMin) / zSpan
				local dgF = diag / zSpan
				local sc = 2.0 * math.exp(-((nv - 192) / 300) * ((nv - 192) / 300))
					+ 1.2 * math.exp(-((czF - 0.10) / 0.10) * ((czF - 0.10) / 0.10))
					+ math.min(math.abs(cx) / bodyHalfW, 1.05)
					+ 0.8 * math.exp(-((dgF - 0.07) / 0.06) * ((dgF - 0.07) / 0.06))
				eyeCand[#eyeCand + 1] = {
					i = i,
					cx = cx,
					cy = (bb[2] + bb[5]) * 0.5,
					cz = cz,
					nv = nv,
					czF = czF,
					dgF = dgF,
					sc = sc,
					r = math.max(dx, dy, dz) * 0.5,
				}
			end
			-- 鱼须: 触及吻端极前的窄小件(金龙鱼短须; 眼件侧位|x|大被排除)
			if
				small
				and bb[3] <= zMin + zSpan * 0.02
				and math.max(math.abs(bb[1]), math.abs(bb[4])) < bodyHalfW * 0.60
			then
				if not barbA then
					barbA = i
				else
					barbB = barbB or i
				end
			end
		end
	end
	-- 眼对: top1=最高分, top2=与top1三元组(nv,cz,diag)匹配件
	table.sort(eyeCand, function(a, b)
		return a.sc > b.sc
	end)
	if #eyeCand >= 1 then
		eyeA = eyeCand[1]
		for c = 2, #eyeCand do
			local q = eyeCand[c]
			if
				math.abs(q.czF - eyeA.czF) < 0.04
				and math.abs(q.nv - eyeA.nv) < math.max(eyeA.nv, 1) * 0.15
				and math.abs(q.dgF - eyeA.dgF) < 0.04
			then
				eyeB = q
				break
			end
		end
	end
	local eyeIdxSet, barbIdxSet = {}, {}
	if eyeA then
		eyeIdxSet[eyeA.i] = true
	end
	if eyeB then
		eyeIdxSet[eyeB.i] = true
	end
	if barbA then
		barbIdxSet[barbA] = true
	end
	if barbB then
		barbIdxSet[barbB] = true
	end
	-- 长腹丝对: 慈鲷/斗鱼腹鳍触须(神仙/七彩/红斗, sp.fil白名单) — 成对
	-- 长件: diag≥18%zSpan(丝长) + zmax<55%zSpan(体前半) + 两件nv差<15%
	-- + cz差<4%zSpan + cy差<8%zSpan(左右对称垂下)。识别后从胸鳍候选排除,
	-- 走VS⑥b专用慢扫路径。
	local filA, filB
	if sp.fil then
		local filCand = {}
		for i, p in ipairs(parts) do
			if i ~= bodyIdx and i ~= tailIdx and p.bb and not eyeIdxSet[i] and not barbIdxSet[i] then
				local bb = p.bb
				local dx, dy, dz = bb[4] - bb[1], bb[5] - bb[2], bb[6] - bb[3]
				local diag = math.sqrt(dx * dx + dy * dy + dz * dz)
				if diag >= zSpan * 0.18 and bb[6] < zMin + zSpan * 0.55 then
					filCand[#filCand + 1] = {
						i = i,
						nv = p.count or 0,
						cz = (bb[3] + bb[6]) * 0.5,
						cy = (bb[2] + bb[5]) * 0.5,
						diag = diag,
					}
				end
			end
		end
		table.sort(filCand, function(a, b)
			return a.diag > b.diag
		end)
		for c = 1, #filCand do
			if filA then
				break
			end
			for d = c + 1, #filCand do
				local x, y = filCand[c], filCand[d]
				if
					math.abs(x.nv - y.nv) < math.max(x.nv, y.nv, 1) * 0.15
					and math.abs(x.cz - y.cz) < zSpan * 0.04
					and math.abs(x.cy - y.cy) < zSpan * 0.08
				then
					filA, filB = x, y
					break
				end
			end
		end
	end
	local filIdxSet = {}
	if filA then
		filIdxSet[filA.i] = true
	end
	if filB then
		filIdxSet[filB.i] = true
	end
	-- 检出率日志(眼/须/丝诊断) — 置于丝识别之后(fil变量已就位);
	-- 36条×逐物种打印走插件print链(锁+console IO)在启动关键路径上,
	-- FCC_FISHDBG=1才输出(默认零开销, 需要时再开)。
	if DBG then
		log(
			string.format(
				"anim[%s] parts=%d eyeCand=%d eye=%s%s barb=%s%s fil=%s%s",
				sp.cn,
				#parts,
				#eyeCand,
				eyeA and eyeA.i or "-",
				eyeB and ("+" .. eyeB.i) or "",
				barbA and tostring(barbA) or "-",
				barbB and ("+" .. barbB) or "",
				filA and tostring(filA.i) or "-",
				filB and ("+" .. filB.i) or ""
			)
		)
	end
	local pectIdx, pectAbsX = nil, 0.0
	-- 胸鳍窗口体前54%: 36物种真胸鳍对(左右对称件, 外展max|x|=1.8~3.3×
	-- bodyHalfW)AABB后缘zmax=27~50.4%zSpan, 54%窗全覆盖+3.6pp余量;
	-- 后位腹鳍对(zmax≥54.8%或mx≤1.3hw)不误选, 多鳍入窗时取|x|最大者
	-- 恒为真胸鳍
	local pectFrontMax = zMin + zSpan * 0.54
	for i, p in ipairs(parts) do
		if i ~= bodyIdx and i ~= tailIdx and p.bb and not eyeIdxSet[i] and not barbIdxSet[i] and not filIdxSet[i] then
			if p.bb[6] < pectFrontMax then
				local mx = math.max(math.abs(p.bb[1]), math.abs(p.bb[4]))
				if mx > pectAbsX then
					pectAbsX = mx
					pectIdx = i
				end
			end
		end
	end
	if pectIdx and pectAbsX <= bodyHalfW * 1.05 then
		pectIdx = nil
	end
	-- 腹鳍对检测: 腹下成对中小鳍 — 判别不按z位置
	-- 先验(36物种实测腹鳍z位分化大: 胸鳍正下方~后方0.06跨度), 用四重几何
	-- 判别: ①腹位(中心y<腹缘+30%身高) ②内侧(外缘|mx|<0.85×pectX, 胸鳍
	-- 恒更外展) ③前位(zmax<68%zSpan, 排除臀鳍/尾) ④镜像对(cx异号+|cx|近+
	-- |cz|差<2.5%zSpan+|cy|差<2%zSpan), 多对时取diag最大; 排除体/尾/眼/
	-- 须/丝/胸鳍本尊。神仙/红斗/七彩的"腹鳍"=长腹丝(⑥b慢扫已承载)被
	-- filIdxSet正确排除(pelvOn=0防双重动画)。
	local pelvA, pelvB
	local pelvCand = {}
	local spanYv = math.max(bodyTopY - bodyBotY, 1e-4)
	for i, p in ipairs(parts) do
		if
			i ~= bodyIdx
			and i ~= tailIdx
			and p.bb
			and not eyeIdxSet[i]
			and not barbIdxSet[i]
			and not filIdxSet[i]
			and i ~= pectIdx
		then
			local bb = p.bb
			local dx, dy, dz = bb[4] - bb[1], bb[5] - bb[2], bb[6] - bb[3]
			local diag = math.sqrt(dx * dx + dy * dy + dz * dz)
			local cx = (bb[1] + bb[4]) * 0.5
			local cy = (bb[2] + bb[5]) * 0.5
			if
				cy < bodyBotY + 0.30 * spanYv
				and bb[6] < zMin + 0.68 * zSpan
				and diag >= 0.04 * zSpan
				and (not pectIdx or math.max(math.abs(bb[1]), math.abs(bb[4])) < pectAbsX * 0.85)
			then
				pelvCand[#pelvCand + 1] = { i = i, cx = cx, cy = cy, cz = (bb[3] + bb[6]) * 0.5, diag = diag }
			end
		end
	end
	table.sort(pelvCand, function(x, y)
		return x.diag > y.diag
	end)
	for c = 1, #pelvCand do
		if pelvA then
			break
		end
		for e = c + 1, #pelvCand do
			local x, y = pelvCand[c], pelvCand[e]
			if
				x.cx * y.cx < 0
				and math.abs(math.abs(x.cx) - math.abs(y.cx)) < math.max(
					0.008,
					0.25 * math.min(math.abs(x.cx), math.abs(y.cx))
				)
				and math.abs(x.cz - y.cz) < zSpan * 0.025
				and math.abs(x.cy - y.cy) < zSpan * 0.02
			then
				pelvA, pelvB = x, y
				break
			end
		end
	end
	local tailZ = zMin + zSpan * 0.62
	if tailIdx and parts[tailIdx].bb then
		tailZ = parts[tailIdx].bb[3] -- 尾鳍 z 下界 = 尾柄枢轴
	end
	local a = {
		tailZ = tailZ,
		zMin = zMin,
		zMax = zMax,
		zSpan = zSpan,
		bodyHalfW = bodyHalfW,
		bodyTopY = bodyTopY,
		bodyBotY = bodyBotY,
	}
	if eyeA then
		-- 双眼平均中心(左右对称) + 眼球半径(×1.6容差罩)
		local n = eyeB and 2 or 1
		a.eyeZ = (eyeA.cz + (eyeB and eyeB.cz or eyeA.cz)) / n
		a.eyeY = (eyeA.cy + (eyeB and eyeB.cy or eyeA.cy)) / n
		a.eyeX = math.max(math.abs(eyeA.cx), eyeB and math.abs(eyeB.cx) or 0)
		a.eyeR = math.max(eyeA.r, eyeB and eyeB.r or 0) * 1.6
		-- 眼件UV域(tex段表直接索引; rUT域: u=fract(中心),
		-- v=1-fract(中心)(FS采样行=1-fract(vUV.y)翻转), 半径=span/2)
		-- — FS瞳孔旋转的几何中心(贴图瞳孔转动唯一正解: 几何旋转顶点
		--   不动贴图, 瞳孔像素永不移动)
		local seg = G.segsByTex and G.segsByTex[sp.tex]
		if seg then
			local ga = seg.items[eyeA.i]
			local gb = eyeB and seg.items[eyeB.i] or ga
			if ga and gb and ga.u and gb.u and ga.v and gb.v then
				local u0 = math.min(ga.u[1], gb.u[1])
				local u1 = math.max(ga.u[2], gb.u[2])
				local v0 = math.min(ga.v[1], gb.v[1])
				local v1 = math.max(ga.v[2], gb.v[2])
				a.eyeU = (u0 + u1) * 0.5 % 1.0
				a.eyeV = 1.0 - ((v0 + v1) * 0.5 % 1.0)
				a.eyeRu = math.max((u1 - u0) * 0.5, 1e-3)
				a.eyeRv = math.max((v1 - v0) * 0.5, 1e-3)
			end
		end
	end
	if barbA and parts[barbA].bb then
		-- 须窗=须件实际AABB(zmax为界, 摆动窗覆盖整须+0.008平滑带)
		a.barbZ = parts[barbA].bb[6] -- barbZmax: 须件z上界
		a.barbY = parts[barbA].bb[5] -- 须根上界(吻背侧)
	end
	if pectIdx and parts[pectIdx].bb then
		local bb = parts[pectIdx].bb
		a.pectZ0, a.pectZ1 = bb[3], bb[6]
		a.pectX = pectAbsX
	end
	-- 丝窗输出: 两件AABB并集(z/y) + |x|外缘 — VS⑥b慢扫路径窗
	if filA and parts[filA.i].bb then
		local ba, bb2 = parts[filA.i].bb, filB and parts[filB.i].bb or nil
		a.filZ0 = math.min(ba[3], bb2 and bb2[3] or ba[3])
		a.filZ1 = math.max(ba[6], bb2 and bb2[6] or ba[6])
		a.filY0 = math.min(ba[2], bb2 and bb2[2] or ba[2])
		a.filY1 = math.max(ba[5], bb2 and bb2[5] or ba[5])
		a.filX = math.max(
			math.max(math.abs(ba[1]), math.abs(ba[4])),
			bb2 and math.max(math.abs(bb2[1]), math.abs(bb2[4])) or 0
		)
	end
	-- 腹鳍窗输出: 对并集AABB(z) + y上缘 + |x|外缘 — VS③b摆动窗
	if pelvA and parts[pelvA.i].bb then
		local ba, bb3 = parts[pelvA.i].bb, pelvB and parts[pelvB.i].bb or nil
		a.pelvZ0 = math.min(ba[3], bb3 and bb3[3] or ba[3])
		a.pelvZ1 = math.max(ba[6], bb3 and bb3[6] or ba[6])
		a.pelvY1 = math.max(ba[5], bb3 and bb3[5] or ba[5])
		a.pelvX = math.max(
			math.max(math.abs(ba[1]), math.abs(ba[4])),
			bb3 and math.max(math.abs(bb3[1]), math.abs(bb3[4])) or 0
		)
	end
	return a
end

-- ============================================================================
-- GPU注入: 4路GLSL(vs变形 / cs参数 / cs行为 / fs皮肤)
-- ============================================================================
-- 注入代码是**一次性**提交的静态 GLSL 字符串(登记后每帧由 GPU 执行)。
-- __TT__(动态type id) / __TB__(槽段base) / __NV__(变体数) 在构建时烘焙。

local function fnum(x)
	if x == math.floor(x) and math.abs(x) < 1e9 then
		return string.format("%d.0", x)
	end
	return string.format("%.6g", x)
end

local function declTable(name, rows)
	local n = #rows
	return string.format("const vec4 %s[%d] = vec4[%d](\n%s\n);\n", name, n, n, table.concat(rows, ",\n"))
end

-- ── 物种行为参数表行(索引 = 变体号, 每变体 2 项) ───────────────────────────
-- idle三档(物种行idle字段, species.json/推导层单一源): 0=恒游(鲨/鲣/枪鱼/
--   金枪/鲈鱼类+群游种, ram ventilation/巡游掠食语义) | 0.8=底层懒游种80%
--   时间idle(金龙鱼/兰寿/出目金/红斗/神仙/七彩/黑鱼/小丑鱼) | 0.3=其他30%。
local function speciesRows()
	local rows = {}
	for v = 0, NTAB - 1 do
		local sp = SPECIES[BYVAR[v] or 1]
		local b = sp.beh
		rows[#rows + 1] =
			string.format("vec4(%s,%s,%s,%s)", fnum(cruiseOf(sp)), fnum(b.seek), fnum(b.turn), fnum(b.leg))
		rows[#rows + 1] = string.format("vec4(%s,%s,%s,%s)", fnum(b.alt), fnum(b.zuse), fnum(b.bank), fnum(b.flock))
		-- row2=(swimHz,idlePct,half,0) — 物种尾摆频率经 fishHzF 通道直达CS
		-- 相位累加器; row2.y=idle时间占比(idle窗dI均值=idlePct·周期);
		-- row2.z=体型系数(观感偏大种half=0.5, 其余1.0) — 行为块群游间距/
		-- 碰撞域补偿(粒子size槽出生被引擎钳下限10不随发射器5缩, CS端len链
		-- 按此系数缩)。
		rows[#rows + 1] = string.format(
			"vec4(%s,%s,%s,0)",
			fnum(sp.anim.swimHz or 2.0),
			fnum(sp.idle or 0.3),
			fnum(sp.half and 0.5 or 1.0)
		)
	end
	return rows
end

-- ── 物种动画参数表行(每变体 8 项) ─────────────────────────────────────────
-- row0 = (swimHz, sway, pectHz, tailZ)      尾柄枢轴 z
-- row1 = (pectZ0, pectZ1, pectX, zMin)      胸鳍 z 窗口/半宽 + 吻端 z
-- row2 = (zMax, bodyHalfW, sizeK, soft)     尾端 z + 尺寸系数 + 柔软度
--        (0=金枪鱼/剑鱼新月刚尾 1=斗鱼/金鱼飘柔长鳍, VS_BODY按soft插值
--        波长/波幅分布/尾扫/胸鳍摆幅)
-- row3 = (eyeZ, eyeY, eyeAbsX, eyeR)        眼球中心/半径(eyeR=0=未检出)
-- row4 = (topY, botY, barbZ, barbOn)        背/腹轮廓y + 须窗口z(barbOn=0/1)
-- row5 = (bodyStiff, filOn, filZ0, filZ1)   前体刚性(0=鲨鱼全身波 1=金鱼身
--        刚尾摆; 行波门mix(1,smoothstep(pedT-0.28,pedT-0.06,tT),stiff))
--        + 丝动画开关与丝窗z(并集)
-- row6 = (filY0, filY1, filX, bigTail)      丝窗y与|x|外缘 + 半月尾全幅标志
-- row7 = (pelvZ0, pelvZ1, pelvX, pelvY1)    腹鳍摆动窗(腹鳍对AABB并集z
--        +y上缘+|x|外缘, VS③b; 无对哨兵pelvZ0=1e3/pelvY1=-1e3)
local function animRows()
	local rows = {}
	for v = 0, NTAB - 1 do
		local sp = SPECIES[BYVAR[v] or 1]
		local a = G.anim[sp.variant] or {}
		local an = sp.anim
		rows[#rows + 1] =
			string.format("vec4(%s,%s,%s,%s)", fnum(an.swimHz), fnum(an.sway), fnum(an.pect), fnum(a.tailZ or 0.30))
		rows[#rows + 1] = string.format(
			"vec4(%s,%s,%s,%s)",
			fnum(a.pectZ0 or 1e3),
			fnum(a.pectZ1 or 1e3),
			fnum(a.pectX or 0.0),
			fnum(a.zMin or -0.216)
		)
		rows[#rows + 1] = string.format(
			"vec4(%s,%s,%s,%s)",
			fnum(a.zMax or 0.216),
			fnum(a.bodyHalfW or 0.03),
			-- ×scaleOf=模型缩放比例 — 大小参数默认20时渲染=标定×scale×
			-- (20/10)=标定×(旧档/10)≡原渲染大小(不变)
			fnum(sizeK(1080) * sp.cm * scaleOf(sp)),
			fnum(an.soft or 0.5)
		)
		rows[#rows + 1] = string.format(
			"vec4(%s,%s,%s,%s)",
			fnum(a.eyeZ or 0.0),
			fnum(a.eyeY or 0.0),
			fnum(a.eyeX or 0.0),
			fnum(a.eyeR or 0.0)
		)
		-- barbOn=物种白名单(sp.barb), row4.z=barbZmax
		rows[#rows + 1] = string.format(
			"vec4(%s,%s,%s,%s)",
			fnum(a.bodyTopY or 0.05),
			fnum(a.bodyBotY or -0.05),
			fnum(a.barbZ or 0.0),
			fnum((sp.barb and a.barbZ) and 1.0 or 0.0)
		)
		-- row5=(bodyStiff前体刚性, filOn丝动画开关, filZ0, filZ1)
		-- row6=(filY0, filY1, filX, bigTail) — 丝窗=丝对AABB并集(VS⑥b慢扫)
		rows[#rows + 1] = string.format(
			"vec4(%s,%s,%s,%s)",
			fnum(an.stiff or 0.5),
			fnum((sp.fil and a.filZ0) and 1.0 or 0.0),
			fnum(a.filZ0 or 1e3),
			fnum(a.filZ1 or -1e3)
		)
		rows[#rows + 1] = string.format(
			"vec4(%s,%s,%s,%s)",
			fnum(a.filY0 or 1e3),
			fnum(a.filY1 or -1e3),
			fnum(a.filX or 0.0),
			fnum(sp.bigTail and 1.0 or 0.0)
		)
		-- row7=(pelvZ0, pelvZ1, pelvX, pelvY1) 腹鳍摆动窗=腹鳍对AABB并集
		-- (z)+y上缘+|x|外缘(VS③b); 无对时哨兵(pelvZ0=1e3/pelvY1=-1e3)
		rows[#rows + 1] = string.format(
			"vec4(%s,%s,%s,%s)",
			fnum(a.pelvZ0 or 1e3),
			fnum(a.pelvZ1 or -1e3),
			fnum(a.pelvX or 0.0),
			fnum(a.pelvY1 or -1e3)
		)
	end
	return rows
end

-- ── 行为角色表行(索引 = 变体号 0..35) ─────────────────────────────────────
-- vec4(role, spd, visR, accel): visR=掠食视距(px×screenScale) accel=追击
-- 加速度; role=纯整数角色(群游开关经tankBeh row1.w→flockF)
local function roleRows()
	local rows = {}
	for v = 0, NTAB - 1 do
		local sp = SPECIES[BYVAR[v] or 1]
		-- 派生域按巡航速度(cruiseOf, 1080域px/s)标定 — 掠食视距/追击
		-- 加速度与游速成正比
		local spd = cruiseOf(sp)
		rows[#rows + 1] = string.format(
			"vec4(%s,%s,%s,%s)",
			fnum(sp.role or 0),
			fnum(spd),
			fnum(560.0 + spd * 2.2),
			fnum(130.0 + spd * 0.55)
		)
	end
	return rows
end

-- ── 物种逃离参数表行(索引 = 变体号 0..35, CS_PARAMS_BODY消费) ────────────
-- (escK, post, escT, 0) — escK=逃离倍率×巡航 | post后继: 1=sprint疾游
--   2=settle平滑减速 3=dart急转zigzag | escT=后继周期s(个体×0.8~1.2)
local POST_CODE = { sprint = 1.0, settle = 2.0, dart = 3.0 }
local function escRows()
	local rows = {}
	for v = 0, NTAB - 1 do
		local sp = SPECIES[BYVAR[v] or 1]
		rows[#rows + 1] = string.format(
			"vec4(%s,%s,%s,0)",
			fnum(sp.esc or 1.5),
			fnum(POST_CODE[sp.post or "settle"] or 2.0),
			fnum(sp.escT or 2.0)
		)
	end
	return rows
end

-- ============================================================================
-- GLSL注入模板外置 — res/shaders/glsl/particle/inject/fish/
-- ============================================================================
-- 全部注入正文(vs_type_deform/fs_fish_skin/cs_fish_params/cs_fish_behavior/
-- cs_variant_pick)住引擎 shader 树(glsl/ RHI域): git版本控制+编辑器GLSL高亮
-- +与papers注入(inject/*.glsl)同址。本脚本职责=数据bake(物种表→const数组
-- →declTable拼模板头)+RPC提交(owner='fish'槽位)。
-- 加载链: 开发树物理路径(本目录退3级=repo根/res/shaders/...) → fcc vfs
-- (安装版fpk虚拟路径 res/shaders/..., fcc.read_file 自动回退)。
-- 模板热重载: 主watchdog(a0)每WD_PERIOD比对模板内容, 变化自动重bake+
-- 重提交(引擎侧pollEvents热重载管线后台重建adopt换装) — 改模板文件保存
-- 即生效, 无需重启/改本脚本。
-- 守卫/作用域/几何域等GLSL侧说明见各模板文件头注(vs_type_deform.glsl等)。
local FISH_TPL_SUB = "res/shaders/glsl/particle/inject/fish"
local FISH_TPL_NAMES = { "vs_type_deform", "fs_fish_skin", "cs_fish_params", "cs_fish_behavior", "cs_variant_pick" }
local function tplDirCands()
	local d = thisDir():gsub("\\", "/")
	return {
		d .. "/../../../" .. FISH_TPL_SUB, -- 开发树: build/Release/extensions/fish → repo
		FISH_TPL_SUB,
	} -- 安装版: fcc.read_file vfs 回退
end
local function fishTpl(name)
	for _, dir in ipairs(tplDirCands()) do
		local s = fcc.read_file(dir .. "/" .. name .. ".glsl")
		if s and s ~= "" then
			return s
		end
	end
	return nil
end

-- 占位符bake: __TT__=动态type id / __TB__=贴图槽段基 / __NV__=变体数 /
-- __NVM1__=变体数-1 / __CAPS__=各变体配额CSV(仅cs_variant_pick) /
-- __ZD2__=已废除兜底。模板文件头注有各占位符语义表。
local function bake(code)
	-- __ZD2__已废除(分辨率无关: 缸深改shader内读发射器sizeDir.z) — gsub
	-- 保留兜底(未来正文误引__ZD2__则按1920×1080标定展开, 不静默进GLSL)
	return (
		code:gsub("__TT__", tostring(G.type))
			:gsub("__TB__", tostring(G.base))
			:gsub("__NV__", tostring(NSPEC))
			:gsub("__NVM1__", tostring(NSPEC - 1))
			:gsub("__ZD2__", "540.0")
	)
end

local function bakeTpl(name)
	local t = fishTpl(name)
	if not t then
		log("注入模板缺失: " .. name .. ".glsl (" .. FISH_TPL_SUB .. "/)")
		return ""
	end
	return bake(t)
end

local function buildVS()
	local t = fishTpl("vs_type_deform")
	if not t then
		log("注入模板缺失: vs_type_deform.glsl (" .. FISH_TPL_SUB .. "/)")
		return ""
	end
	return declTable("tankAnim", animRows()) .. bake(t)
end

-- tankSkin表(FS per物种参数; 行=变体×3):
--   [0]=(soft, tailU, flowFin, flowAmp) — flowFin/flowAmp已无FS消费,
--       行保留仅维持表结构(变体×3)稳定
--   [1]=(swimHz, cruiseSpd, 0, 0) — cruiseSpd: envFS速度包络(③眼神光
--       idle门); swimHz已无FS消费(VS侧tankAnim同源参数承载摆频)
--   [2]=(eyeU, eyeV, eyeRu, eyeRv) 眼UV椭圆窗(rUT域; FS眼神光)
local function skinRows()
	local rows = {}
	for v = 0, NTAB - 1 do
		local sp = SPECIES[BYVAR[v] or 1]
		local soft = sp.anim.soft or 0.5
		-- 长须物种白名单强制开(神仙2/七彩35=长腹鳍丝特征物种)
		local longFin = (v == 2 or v == 35)
		local flowFin = (soft >= 0.62 or longFin) and 1.0 or 0.0
		-- v向波幅, 配合边缘衰减带0.045永不越行
		local flowAmp = 0.010 + 0.012 * soft
		rows[#rows + 1] = string.format("vec4(%s,0.58,%s,%s)", fnum(soft), fnum(flowFin), fnum(flowAmp))
		rows[#rows + 1] = string.format("vec4(%s,%s,0,0)", fnum(sp.anim.swimHz or 2.0), fnum(cruiseOf(sp)))
		local a = G.anim[v]
		rows[#rows + 1] = string.format(
			"vec4(%s,%s,%s,%s)",
			fnum(a and a.eyeU or 0.0),
			fnum(a and a.eyeV or 0.0),
			fnum(a and a.eyeRu or 0.0),
			fnum(a and a.eyeRv or 0.0)
		)
	end
	return rows
end

-- fs_fish_skin: 正文住 res/shaders/glsl/particle/inject/fish/
-- fs_fish_skin.glsl(守卫/占位符说明见模板头注); 本函数=
-- tankSkin数据表 + bake(模板)。
local function buildSkin()
	local t = fishTpl("fs_fish_skin")
	if not t then
		log("注入模板缺失: fs_fish_skin.glsl (" .. FISH_TPL_SUB .. "/)")
		return ""
	end
	return declTable("tankSkin", skinRows()) .. bake(t)
end

-- cs_fish_params: 正文住 res/shaders/glsl/particle/inject/fish/
-- cs_fish_params.glsl(守卫/占位符说明见模板头注)。

local function buildCSParams()
	-- SCALE_P模型缩放比例数组(参数20基准折算旧档语义 — CS_PARAMS_BODY
	-- size*=SCALE_P消费; 与tankAnim aP2.z的scaleOf同源)
	-- LEN_CM渲染全长基准数组(=SIZE_DENOM×sizeK(1080)×cm×scaleOf,
	-- 与VS tankAnim aP2.z同源标定) — CS_PARAMS_BODY fishBioLenF注入体消费
	-- (×个体方差×szLive/10×pxS=实际渲染全长, 生物网格槽位映射/体型悬殊
	-- 判定/分离半径统一体长)。
	-- 全表过bake(__TT__/__TB__/__ZD2__替换)
	local t = {}
	local lb = {}
	for v = 0, NTAB - 1 do
		local sp = SPECIES[BYVAR[v] or 1]
		t[#t + 1] = fnum(scaleOf(sp))
		lb[#lb + 1] = fnum(SIZE_DENOM * sizeK(1080) * sp.cm * scaleOf(sp))
	end
	local scaleArr = "const float SCALE_P["
		.. NTAB
		.. "] = float["
		.. NTAB
		.. "]("
		.. table.concat(t, ",")
		.. ");\n"
		.. "const float LEN_CM["
		.. NTAB
		.. "] = float["
		.. NTAB
		.. "]("
		.. table.concat(lb, ",")
		.. ");\n"
	-- 物种巡航基准=体长/秒(BL/s) — 绝对速度由 CS_PARAMS_BODY 乘本鱼实际
	-- 渲染全长(与 VS 同源链)得到, 使 sizeOverride 只改渲染尺寸不改相对
	-- 速度。单一源: 直接取 SPECIES 行内 beh.blps(cruiseOf 同源)。
	local bp = {}
	for v = 0, NTAB - 1 do
		bp[#bp + 1] = fnum((SPECIES[BYVAR[v] or 1].beh.blps or 1.0))
	end
	local blpsArr = "const float BLPS_P[" .. NTAB .. "] = float[" .. NTAB .. "](" .. table.concat(bp, ",") .. ");\n"
	return declTable("tankBeh", speciesRows())
		.. declTable("tankRole", roleRows())
		.. declTable("tankEsc", escRows())
		.. scaleArr
		.. blpsArr
		.. bakeTpl("cs_fish_params")
end

-- cs_fish_behavior: 正文住 res/shaders/glsl/particle/inject/fish/
-- cs_fish_behavior.glsl(扫描守卫/自身守卫说明见模板头注)。
local function buildCSBehavior()
	-- 行为力已挪cs_fish_params注入点 — 本注入体(EMA后)只剩钉头朝向/
	-- z钳/roll/size还原, 仅需SCALE_B数组(与SCALE_P同值, 独立声明防跨
	-- 注入体作用域依赖); tankRole/LEN_CM随params体声明。
	-- CRZ_B物种巡航表(威胁避让逃速下限0.5×巡航消费)。
	-- LEN_B渲染全长基准表(与params体LEN_CM同式同值=
	--   SIZE_DENOM×sizeK(1080)×cm×scaleOf) — behavior体直遍威胁扫描
	--   的体长源(跨注入体不共享声明, 同SCALE_B先例独立声明)。
	local s = {}
	local c = {}
	local lb = {}
	for v = 0, NTAB - 1 do
		local spB_ = SPECIES[BYVAR[v] or 1]
		s[#s + 1] = fnum(scaleOf(spB_))
		c[#c + 1] = fnum(cruiseOf(spB_))
		lb[#lb + 1] = fnum(SIZE_DENOM * sizeK(1080) * spB_.cm * scaleOf(spB_))
	end
	local scaleArr = "const float SCALE_B["
		.. NTAB
		.. "] = float["
		.. NTAB
		.. "]("
		.. table.concat(s, ",")
		.. ");\n"
		.. "const float CRZ_B["
		.. NTAB
		.. "] = float["
		.. NTAB
		.. "]("
		.. table.concat(c, ",")
		.. ");\n"
		.. "const float LEN_B["
		.. NTAB
		.. "] = float["
		.. NTAB
		.. "]("
		.. table.concat(lb, ",")
		.. ");\n"
	return scaleArr .. bakeTpl("cs_fish_behavior")
end

-- ── 随机模式容量加权抽取 ── cs_variant_pick注入(cs_emit随机变体分支标记
--    行处替换): 加权抽取语义与上限表CAPS(=register_variant count同源,
--    eco.n)说明见模板头注。锁定变体模式不经此注入(用户显式选择走粒数
--    滑条)。无状态扫描=天然免疫killAll/重建后的计数漂移。
--    正文模板外置 cs_variant_pick.glsl, 本函数只bake __CAPS__ 配额。
local function buildCSPick()
	if not (G.type and G.base) then
		return ""
	end
	local caps = {}
	for v = 0, NSPEC - 1 do
		local sp = SPECIES[BYVAR[v] or 1]
		caps[#caps + 1] = tostring(sp.eco and sp.eco.n or 4)
	end
	local t = fishTpl("cs_variant_pick")
	if not t then
		log("注入模板缺失: cs_variant_pick.glsl (" .. FISH_TPL_SUB .. "/)")
		return ""
	end
	return (bake(t):gsub("__CAPS__", table.concat(caps, ",")))
end

local INJECT_HOOKS = { "vs_type_deform", "cs_fish_params", "cs_fish_behavior", "fs_fish_skin", "cs_variant_pick" }

local function submitShaders()
	if not (G.type and G.base) then
		return false
	end
	-- 全部注入正文=外置模板bake(vs/fs/cs_* 函数见模板机制区);
	-- cs_variant_pick 的 bake 在 buildCSPick 内完成(含__CAPS__数据)。
	local items = {
		{ hook = "vs_type_deform", code = buildVS() },
		{ hook = "cs_fish_params", code = buildCSParams() },
		{ hook = "cs_fish_behavior", code = buildCSBehavior() },
		{ hook = "fs_fish_skin", code = buildSkin() },
		{ hook = "cs_variant_pick", code = buildCSPick() },
	}
	local okAll = true
	for _, it in ipairs(items) do
		-- 空code防御跳过: 空串=set_inject清除语义, 会与后续真实内容竞态出
		-- 双内容(缓存键分裂); buildCSPick在type未知时返回''。
		if it.code == nil or it.code == "" then
			okAll = false
			log("inject skip(空): " .. it.hook)
		else
			-- 属主槽位'fish' — 与papers(同hook的vs_type_deform)互不覆盖,
			-- 各自独立拼接(注入体按type守卫作用域, 并存语义安全)
			local r = fcc.rpc("shader", "set_inject", { hook = it.hook, code = it.code, id = "fish" })
			local ok = type(r) == "table" and r.ok == true
			if ok then
				-- 记录提交代数与时刻(诊断用, fishtank_gate消费) — 出生门
				-- 已不依赖注入adopt(见registerVariants注释)
				local gNew = tonumber(r.gen) or 0
				if gNew > (G.injectGenSub or 0) then
					G.injectSawInflight = nil -- 新代数=新编译周期, 清观察标记
				end
				G.injectGenSub = math.max(G.injectGenSub or 0, gNew)
				G.injectSubmitT = os.clock()
			else
				okAll = false
				G.lastInjectErr = it.hook .. ": " .. tostring(r and (r.error or "")) -- 诊断
				log("inject fail " .. it.hook .. ": " .. tostring(r and (r.error or "")))
			end
		end
	end
	G.lastInject = items -- 调试导出(见 fishtank_dump_inject)
	-- 记录模板文件快照(watchdog a0 模板热重载比对源)
	G.tplSnaps = {}
	for _, name in ipairs(FISH_TPL_NAMES) do
		local c = fishTpl(name)
		if c then
			G.tplSnaps[name] = c
		end
	end
	return okAll
end

-- ============================================================================
-- 发射器管理(FS全屏系统; 开关只动发射器 — 资源常驻登记)
-- ============================================================================
local function addEmitters()
	for i, sp in ipairs(SPECIES) do
		local eco = sp.eco
		local cfg = {
			system = "fs",
			type = G.type,
			textureIndex = sp.variant, -- 相对变体号(0..35; 上传端=base+v)
			-- emitPositionMode=5: FS全屏发射盒, 与内置鱼群全屏形态同款
			--   (particle_ui applyEmitterPoseFS): 出生=整屏盒+引擎水域重投链,
			--   活动域=引擎uBounds全图域, 扩展不再另设出生/活动限制。
			emitPositionMode = 5,
			emitRate = eco.rate,
			maxParticles = eco.n,
			-- 出生盒=整屏满幅居中(posY=0): 物种生态位不再由出生盒偏置,
			--   垂直分层由引擎wpZhabit按altF/zUseF习性承担。
			posX = 0,
			posY = 0,
			posZ = 0,
			-- sizeZ=200: 内置鱼群全mode标准出生薄带, 稳态水深分布
			--   由引擎航点z层+活动域钳决定。
			sizeX = G.rtW,
			sizeY = G.rtH,
			sizeZ = 200.0,
			shape_i = 1, -- Box(全屏盒)
			-- 视角零指定 — emitters.add走rpcMakeEmitter鱼行为域默认
			-- (引擎单源, 与面板/恢复默认同源), 面板滑条可再调
			lifeOverride = 30.0, -- 顶格=无限寿命(cs_emit 1e5)
			-- 物种cm标定在VS注入表(tankAnim row2.z=sizeK×cm, per-particle
			-- 不丢); 发射器sizeOverride=纯用户倍率(10=1.0物种原大, VS按
			-- size/10乘入并钳0.05..4.0)。sizeVariance=0 — ±14%成体自然
			-- 体型差已由VS内fract(seedN)承担, 此处再方差=双重方差
			sizeOverride = sizeOf(sp),
			sizeVariance = 0.0,
			vfxA = sp.anim.swimHz, -- 摆尾频率Hz(仅extraParams.z锁定时生效)
			vfxB = 1.0, -- 摆尾幅度倍率(1.0=物种标定, VS乘物种表)
			-- 正吸引在FS域影响半径=|vfxC|×图宽/2×2.0(FS半径倍率), 过大→
			-- 全屏鱼被圈进轨道环聚团; 默认-0.3轻排斥(与面板声明default同源,
			-- 半径×0.33局部避让), 吸引由面板"鼠标吸引"滑条正值开启
			vfxC = -0.3, -- 鼠标交互(负=轻排斥; 左键点击=散开)
			vfxF = 1.0, -- 游速倍率
			envAmbientCoef = 1.2, -- 水体漫射环境(默认1.2)
			lightDirStr = 1.5, -- 顶光强度(默认1.5)
			-- 光照水平/俯仰角默认90/90(与register_type声明同源)
			lightDirRoll = 90.0,
			lightDirPitch = 90.0,
			-- 各向异性=湿鱼鳞高光(面板路径applyAnisoDefaults只服务面板发射器;
			-- lua发射器需显式声明, rpcMakeEmitter已补anisoR/G/B/anisoStrength
			-- 字段通道)
			anisoR = 0.55,
			anisoG = 0.75,
			anisoB = 0.90,
			anisoStrength = 0.5,
			-- fish.fbx没有法线贴图数据, 法线贴图默认关闭(emitter结构默认
			-- true=程序化perlin伪细节, 显式关)
			normalMapEnabled = false,
			normalStrength = 0.3,
			breezeScale = 0.0,
			airwaveScale = 0.0,
			mouseAttract = -0.3, -- 负=轻排斥(移动避让/左键点击散开)
		}
		local r = fcc.rpc("particle", "emitters.add", cfg)
		if r and r.id and r.id >= 0 then
			G.emitterIds[i] = r.id
		else
			log("emitters.add fail #" .. i .. " " .. sp.cn .. ": " .. tostring(r and r.error))
		end
	end
	local n = 0
	for _ in pairs(G.emitterIds) do
		n = n + 1
	end
	log("emitters: " .. n .. "/" .. NSPEC)
	return n > 0
end

local function removeEmitters()
	for _, id in pairs(G.emitterIds) do
		fcc.rpc("particle", "emitters.remove", { id = id })
	end
	G.emitterIds = {}
end

-- ============================================================================
-- 法线贴图管线(贴图像素亮度自动计算法线贴图, 合并到atlas大纹理备用,
-- 开启法线贴图参数则启用):
--   ①fcc.decode_image读素材RGBA(原生分辨率) → ②亮度=高度场, Sobel梯度→
--   切线空间法线(RGB=n·0.5+0.5, A=255) → ③纯lua base64 → ④set_pixels直传
--   atlas法线槽(base+36+v, 与albedo同尺寸同布局) — 上传后常驻atlas=备用;
--   FS注入仅在发射器法线贴图参数开启(vEmNormal.x=normalMapEnabled)时采样。
--   逐变体on_update节流(0.15s/鱼, luajit下单变体~20-60ms, 启动暖机摊开)。
-- ============================================================================
local B64CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64encode(data)
	local out = {}
	local n = #data
	for i = 1, n - 2, 3 do
		local a, b, c = data:byte(i, i + 2)
		local v = a * 65536 + b * 256 + c
		local d1 = math.floor(v / 262144) % 64
		local d2 = math.floor(v / 4096) % 64
		local d3 = math.floor(v / 64) % 64
		local d4 = v % 64
		out[#out + 1] = B64CHARS:sub(d1 + 1, d1 + 1)
		out[#out + 1] = B64CHARS:sub(d2 + 1, d2 + 1)
		out[#out + 1] = B64CHARS:sub(d3 + 1, d3 + 1)
		out[#out + 1] = B64CHARS:sub(d4 + 1, d4 + 1)
	end
	local rem = n % 3
	if rem == 1 then
		local v = data:byte(n) * 65536
		local d1 = math.floor(v / 262144) % 64
		local d2 = math.floor(v / 4096) % 64
		out[#out + 1] = B64CHARS:sub(d1 + 1, d1 + 1)
		out[#out + 1] = B64CHARS:sub(d2 + 1, d2 + 1)
		out[#out + 1] = "=="
	elseif rem == 2 then
		local a, b = data:byte(n - 1, n)
		local v = a * 65536 + b * 256
		local d1 = math.floor(v / 262144) % 64
		local d2 = math.floor(v / 4096) % 64
		local d3 = math.floor(v / 64) % 64
		out[#out + 1] = B64CHARS:sub(d1 + 1, d1 + 1)
		out[#out + 1] = B64CHARS:sub(d2 + 1, d2 + 1)
		out[#out + 1] = B64CHARS:sub(d3 + 1, d3 + 1)
		out[#out + 1] = "="
	end
	return table.concat(out)
end

-- Sobel法线: 高度场H=亮度(0.299/0.587/0.114), 梯度→切线空间法线
-- STRENGTH=斜率增益(边界clamp采样无环绕缝)
local NORM_STRENGTH = 0.6
local function computeNormalMap(rgba, w, h)
	-- ①亮度场(索引表, 边界0填充防越界分支)
	local lum = {}
	local idx = 0
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local i = idx * 4 + 1
			local b0, b1, b2 = rgba:byte(i, i + 2)
			idx = idx + 1
			lum[idx] = 0.299 * b0 + 0.587 * b1 + 0.114 * b2
		end
	end
	-- ②Sobel→法线RGBA
	local out = {}
	local s = NORM_STRENGTH / 255.0
	for y = 0, h - 1 do
		local y0 = (y > 0) and (y - 1) or 0
		local y2 = (y < h - 1) and (y + 1) or (h - 1)
		local r0, r1, r2 = y0 * w, y * w, y2 * w
		for x = 0, w - 1 do
			local x0 = (x > 0) and (x - 1) or 0
			local x2 = (x < w - 1) and (x + 1) or (w - 1)
			local tl, tc_, tr = lum[r0 + x0 + 1], lum[r0 + x + 1], lum[r0 + x2 + 1]
			local ml, mr = lum[r1 + x0 + 1], lum[r1 + x2 + 1]
			local bl, bc, br = lum[r2 + x0 + 1], lum[r2 + x + 1], lum[r2 + x2 + 1]
			local gx = (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl)
			local gy = (bc + 2.0 * br + bl) - (tc_ + 2.0 * tr + tl) -- dy=图向下
			local nx = -gx * s -- bump: n=-dH/dx(贴图右)
			local ny = gy * s -- bump绿朝上: n.y_up=-dH/dy_up=+dH/dy_down
			-- (=+gy; FS端配+vBitangentVS=贴图上, 逐轴一致)
			local nz = 1.0
			local inv = 1.0 / math.sqrt(nx * nx + ny * ny + 1.0)
			out[#out + 1] = string.char(
				math.floor((nx * inv * 0.5 + 0.5) * 255.0 + 0.5),
				math.floor((ny * inv * 0.5 + 0.5) * 255.0 + 0.5),
				math.floor((nz * inv * 0.5 + 0.5) * 255.0 + 0.5),
				255
			)
		end
	end
	return table.concat(out)
end

-- 原生法线贴图探测(只有不存在原生法线贴图数据时才需要自动生成):
-- 依次探测与albedo同目录同词干的常见法线命名(<stem>_n/_N/_normal/-normal
-- /_nrm +png/jpg/jpeg), 命中即解码直传(不Sobel); 引擎fbx材质不暴露法线槽
-- (ufbx数据未出API), 同目录约定文件=通用探测手段。fish.fbx零贴图引用
-- 且res目录无法线文件 → 本素材走亮度生成路径。
local NATIVE_NORM_SUFS = { "_n", "_N", "_normal", "-normal", "_nrm" }
local function tryNativeNormalMap(tex)
	local stem = tex:gsub("%.[^.]+$", "") -- 去扩展名
	for _, suf in ipairs(NATIVE_NORM_SUFS) do
		for _, ext in ipairs({ ".png", ".jpg", ".jpeg" }) do
			local path = TEX_DIR .. "/" .. stem .. suf .. ext
			local f = io.open(path, "rb")
			if f then
				f:close()
				local rgba, w, h = fcc.decode_image(path, 0)
				if rgba and w and w > 0 and h and h > 0 then
					return rgba, w, h, path
				end
			end
		end
	end
	return nil
end

local function buildNormalSlot(v)
	local sp = SPECIES[BYVAR[v] or 1]
	-- ①原生法线贴图优先(存在→直传; 缺失→②亮度Sobel自动生成)
	local nm, dw, dh
	local nRGBA, nW, nH, nPath = tryNativeNormalMap(sp.tex)
	if nRGBA then
		nm, dw, dh = nRGBA, nW, nH
		log("法线槽v" .. v .. ": 原生法线贴图 " .. nPath)
	else
		local rgba, aw, ah = fcc.decode_image(TEX_DIR .. "/" .. sp.tex, 0)
		if not rgba or not aw or aw <= 0 or ah <= 0 then
			log("法线槽 decode fail: " .. sp.tex)
			return false
		end
		nm = computeNormalMap(rgba, aw, ah)
		dw, dh = aw, ah
	end
	local r = fcc.rpc("particle", "set_pixels", {
		type = G.type,
		variant = NSPEC + v,
		w = dw,
		h = dh,
		pixels_b64 = b64encode(nm),
	})
	if type(r) ~= "table" or r.ok ~= true then
		local err = tostring(r and r.error)
		-- 会话内继承的旧36容量类型: 法线槽越界 → 清场(发射器/粒子)并重置
		-- 注册状态, 下一轮applyOnce按72容量重注册
		if err:find("invalid type/variant", 1, true) then
			log("法线槽容量不足(旧类型36), 清场重注册(72槽)...")
			removeEmitters()
			fcc.rpc("particle", "kill_type", { type = G.type })
			G.type, G.base = nil, nil
			G.resReady, G.resSubmitted, G.shadersDone = false, false, false
			G.variantsDone = false
			G.normIdx = 0
			G.normProbeDone = nil -- 重新注册后重新探测
			return false
		end
		log("法线槽 set_pixels fail v" .. v .. ": " .. err)
		return false
	end
	return true
end

-- ============================================================================
-- 资源登记(load即登记 — 安装预生成/启动首编译时数据已就位)
-- ============================================================================
local function registerResources(texDims)
	-- 就绪探针=world_info(轻量; particle.info是全量类型+发射器dump的重
	-- 调用, 重试期1次/秒纯属浪费)
	local wi = fcc.rpc("particle", "world_info", {})
	if DBG then
		log("applyOnce#world_info @" .. ts())
	end
	if wi and wi.fs then
		local nrtW = wi.fs.rtW or G.rtW
		local nrtH = wi.fs.rtH or G.rtH
		local nwoW = wi.fs.worldW or G.worldW
		local nwoH = wi.fs.worldH or G.worldH
		-- 分辨率变化(改分辨率/多屏切换) → 仅更新rt域(发射器几何healing
		-- 用)。注入内容已分辨率无关(缸深改shader内读发射器sizeDir; sizeK
		-- 代数上恒定), 无需重提交 — 恒零churn。
		G.rtW, G.rtH, G.worldW, G.worldH = nrtW, nrtH, nwoW, nwoH
	end
	-- 2. mesh+贴图(fbx.model_to_particle 一步直通; 幂等逐槽跳过已收敛项,
	--    防重试风暴)
	local okS, whyS = submitResources(texDims)
	if not okS then
		return false, whyS or "resources fail"
	end
	if DBG then
		log("applyOnce#submitResources @" .. ts())
	end
	-- 3. 动画域(从 parts 推导)
	-- anim缓存命中时跳过重算+二次提交 — 首提交(applyOnce级)已用缓存anim
	-- =最终内容; 重算(m2p返回parts浮点与JSON往返缓存parts的低位差异)会
	-- 使注入内容漂移→setLuaInject gen++→particles组重建→adopt新程序首用
	-- JIT卡顿。fbxSig已验证未变=parts确定一致; 非命中路径(首跑/fbx热改/
	-- 自愈)保持两阶段提交。
	if not G.animFromCache then
		for _, sp in ipairs(SPECIES) do
			G.anim[sp.variant] = computeAnim(sp.variant)
		end
		if not submitShaders() then
			return false, "shaders fail"
		end
		G.shadersDone = true
	elseif not G.shadersDone then
		-- 缓存命中但首提交失败(引擎未就绪等): 同内容兜底重试一次
		G.shadersDone = submitShaders()
		if not G.shadersDone then
			return false, "shaders fail"
		end
	end
	if DBG then
		log("applyOnce#submitShaders @" .. ts())
	end
	-- 4. 释放fbx场景缓存(mesh已拷贝, 贴图已上传)
	fcc.rpc("fbx", "mesh_release", { path = FBX_PATH })
	G.resReady = true
	-- 5. mesh/贴图/注入全落地后开启出生门 — register_variant×N ⇒
	-- variantDomainCount=36 ⇒ cs_emit出生门开启, 此后出生的鱼全部携带
	-- 就绪数据(正确mesh+贴图+Shader)。部分失败(单条RPC失败)时守卫
	-- watchdog按0.25s节流重试(幂等覆盖)。
	G.variantsDone = registerVariants()
	if DBG then
		log("applyOnce#registerVariants @" .. ts())
	end
	if G.variantsDone then
		log("变体登记完成: 出生门开启(数据就绪, type=" .. tostring(G.type) .. ")")
	else
		log("变体登记部分失败, watchdog重试中...")
	end
	return true
end

-- ── fbx素材指纹: 纯字节数 — mtime不入判据(提交文件的克隆/检出mtime必
-- ── 漂移, 会使每个新克隆误判失效→重算→改写git跟踪的fish.dims.json);
-- ── 字节数跨机器恒定, 同尺寸异内容对10MB二进制资产实际不可构造。
local function fbxSig()
	if not fcc.file_stat then
		return nil
	end -- 旧exe无此API: 走首轮兜底注入
	local st = fcc.file_stat(FBX_PATH)
	if type(st) == "table" and st.size then
		return { math.floor(st.size) }
	end
	return nil
end

-- ── anim/parts缓存恢复: 命中时首提交注入=最终内容 ────────────────────────
-- 两阶段注入(兜底anim版→model_to_particle后真实AABB版)内容必不同:
-- ①每次启动worker init冷编译兜底版(引擎gl缓存恒miss) ②真实版落地触发
-- 热重载派发(JIT哑帧互踩)。缓存parts/anim后, load时G.anim即完整 →
-- 首提交=最终内容, registerResources内重提交=内容相同setLuaInject零操作
-- (注入代数不变→零派发)。
local function loadAnimCache(cdata)
	if type(cdata.fbx) ~= "table" or #cdata.fbx < 1 then
		return false
	end
	local sig = fbxSig()
	if not sig then
		return false
	end
	if math.floor(cdata.fbx[1] or -1) ~= sig[1] then
		log("fbx素材已变更(字节数不符), anim描述失效")
		return false
	end
	if type(cdata.parts) ~= "table" or type(cdata.anim) ~= "table" then
		return false
	end
	-- parts/anim=显式1基数组(索引=变体+1) — 0基键表经fcc.json_encode被
	-- 写成JSON数组(0基元素序), 解码回Lua装成1基索引=整体错位+1且丢变体
	-- 0。严格校验: 两数组必须恰NSPEC项且每anim项核心字段为数字 — 任一缺失/
	-- 坏项一律判缓存失效走重算(零静默错数据)。
	if #cdata.parts ~= NSPEC or #cdata.anim ~= NSPEC then
		return false
	end
	for v = 0, NSPEC - 1 do
		local a = cdata.anim[v + 1]
		if
			type(a) ~= "table"
			or type(a.tailZ) ~= "number"
			or type(a.zMin) ~= "number"
			or type(a.zMax) ~= "number"
			or type(a.zSpan) ~= "number"
		then
			return false
		end
	end
	for v = 0, NSPEC - 1 do
		local arr = cdata.parts[v + 1]
		if type(arr) == "table" and #arr > 0 then
			G.parts[v] = arr
		end
		G.anim[v] = cdata.anim[v + 1]
	end
	-- 命中即标记"缓存anim=最终真相" — registerResources跳过computeAnim
	-- 重算+二次提交。指纹挂G供热重载re-run复验(fbx热改→失效转重算)。
	G.animFromCache = true
	G.animFbxSig = sig
	-- rt尺寸不入缓存 — rt不影响注入内容(分辨率无关), 且窗口尺寸每次可能
	-- 不同(测试小窗/全屏/多屏), 存入会导致saveAnimCache判定"内容变化"→
	-- 写盘→extScan触发re-run(model_to_particle×N重传); rt域由
	-- registerResources的world_info每轮实时刷新, 缓存无需恢复。
	return true
end

-- ── fish.dims.json落盘: resReady后调用(全数据就绪) ──────────────────────────────
-- fish.dims.json=fish.fbx确定性描述文件, 随仓库提交; 素材真变更(字节数
-- 变)→此处重算改写→开发者随新fbx一并提交(生成代码工作流)。
-- 内容不变不写盘 — res/在extensions下被extScan递归监视, 盲写mtime必变=
-- 触发扩展重跑→applyOnce再写→无限重跑循环。读旧内容比对一致则跳过
-- (零写零触发); fbx指纹=纯字节数(跨机器恒定, 克隆不误触发重写)。
-- payload不含任何分辨率/窗口尺寸字段 — 同机器任意分辨率组合下内容恒定,
-- 不因切换窗口触发写盘。
local function saveAnimCache()
	-- texDims缺项(解析瞬时失败)时禁写盘 — 坏数据持久化=后续启动全部命中
	-- 坏缓存, 槽位错位收敛死循环。
	if G.texDimsIncomplete then
		log("⚠texDims缺项, 跳过缓存写盘(防坏数据持久化)")
		return
	end
	-- parts/anim写显式1基数组(索引=变体+1) — 0基键表经JSON编码器变数组/
	-- 解码器1基装回=错位+1丢变体0(见loadAnimCache)。任一变体anim缺核心
	-- 字段(计算异常)也禁写盘(防坏数据持久化, 与载入校验对称)。
	local partsArr, animArr = {}, {}
	for v = 0, NSPEC - 1 do
		local a = G.anim[v]
		if
			type(a) ~= "table"
			or type(a.tailZ) ~= "number"
			or type(a.zMin) ~= "number"
			or type(a.zMax) ~= "number"
			or type(a.zSpan) ~= "number"
		then
			log("⚠anim[" .. v .. "]缺核心字段, 跳过缓存写盘(防坏数据持久化)")
			return
		end
		partsArr[v + 1] = G.parts[v] or {}
		animArr[v + 1] = a
	end
	local payload = fcc.json_encode({
		ver = DIMS_CACHE_VER,
		fbx = fbxSig(),
		texDims = G.texDims,
		segsByTex = G.segsByTex,
		modelIdx = G.modelIdx,
		parts = partsArr,
		anim = animArr,
	})
	local cachePath = dimsCachePath()
	local cf = io.open(cachePath, "r")
	if cf then
		local old = cf:read("*a")
		cf:close()
		if old == payload then
			return
		end -- 内容未变: 零写盘(不触发extScan)
		-- 诊断: 内容漂移定位(排查每次启动重写→extScan连环re-run)
		if DBG then
			local n = math.min(#old, #payload)
			local d = 0
			while d < n and old:byte(d + 1) == payload:byte(d + 1) do
				d = d + 1
			end
			log(
				string.format(
					"anim缓存漂移: old=%d new=%d 首异@%d [%q|%q]",
					#old,
					#payload,
					d + 1,
					old:sub(d + 1, d + 48),
					payload:sub(d + 1, d + 48)
				)
			)
		end
	end
	local wf = io.open(cachePath, "w")
	if not wf then
		return
	end
	wf:write(payload)
	wf:close()
end

-- ── applyOnce(papers.lua 同款幂等登记; 未就绪false由on_update重试) ────────
local function applyOnce()
	if DBG then
		log("applyOnce#enter @" .. ts())
	end
	-- 1. 场景缓存先行(贴图原生尺寸数据在register_type前就位 → atlas布局
	--    一次成型, 零relayout零压扁)。
	--    fish.dims.json缓存texDims+segsByTex+modelIdx(静态数据)+parts/anim
	--    (缓存与分辨率/窗口完全无关) — 命中时跳过mesh_groups与model_list
	--    的fbx全量解析(省~1.4s启动)且首提交注入即最终内容; 素材(fbx指纹)
	--    变更自动失效。
	local animCacheHit = false
	-- ver+fbx指纹均匹配(挂G跨调用持久 — applyOnce每次重试都会重新进入本
	-- 函数, 局部标志会在"加载块被G.texDims跳过"的重试/re-run路径上丢失 →
	-- dims_cache重写循环复发)
	if G.cacheLoaded == nil then
		G.cacheLoaded = false
	end
	local cacheLoaded = G.cacheLoaded
	if not G.texDims and not G.skipDiskCache then
		-- 自愈门: G.skipDiskCache=真自愈轮(watchdog丢dims后置位)跳过盘缓存
		-- 读取强制重解析mesh_groups, 否则下轮cache命中把旧数据装回="丢弃
		-- dims"空转。
		local cachePath = dimsCachePath() -- res/fish.dims.json(描述文件, 随仓库提交)
		-- fcc.read_file 走 vfs(磁盘优先+fpk包回退) — res目录打包成res.fpk
		-- 后dims描述文件在包内, 纯io.open永远读不到; 旧exe无API时回退
		-- io.open。
		local cstr = fcc.read_file and fcc.read_file(cachePath) or nil
		if not cstr then
			local cf = io.open(cachePath, "r")
			if cf then
				cstr = cf:read("*a")
				cf:close()
			end
		end
		if cstr then
			local okC, cdata = pcall(fcc.json_decode, cstr)
			if
				okC
				and type(cdata) == "table"
				and cdata.ver == DIMS_CACHE_VER
				and type(cdata.texDims) == "table"
				and type(cdata.segsByTex) == "table"
				and type(cdata.modelIdx) == "table"
			then
				G.texDims = cdata.texDims
				G.segsByTex = cdata.segsByTex
				G.modelIdx = cdata.modelIdx
				animCacheHit = loadAnimCache(cdata)
				cacheLoaded = animCacheHit
				G.cacheLoaded = cacheLoaded
				log(
					"dims cache命中: 跳过fbx解析"
						.. (
							animCacheHit and " +anim/parts(首提交即最终内容)"
							or " (anim缓存缺/失效, 首轮走兜底注入)"
						)
				)
			end
		end
	end
	if not G.texDims then
		if DBG then
			log("applyOnce#fbx-parse @" .. ts())
		end
		local mg = fcc.rpc("fbx", "mesh_groups", { path = FBX_PATH, tex_dirs = { TEX_DIR } })
		if not (type(mg) == "table" and mg.groups) then
			return false, "mesh_groups fail: " .. tostring(mg and mg.error)
		end
		local texDims = {}
		local texName = {}
		for _, t in ipairs(mg.textures or {}) do
			if t.name then
				texDims[t.name] = { t.w or 0, t.h or 0 }
				texName[#texName + 1] = t.name
			end
		end
		G.texDims = texDims -- 收敛校验用(期望槽尺寸=素材原生尺寸)
		-- tex连续段表(与model_list同构分段: 无贴图mesh跳过不打断;
		-- 段内items顺序=meshes数组顺序=model_to_particle的parts顺序) —
		-- 眼件parts[i]直接索引段items[i]取UV域(瞳孔旋转的眼UV中心)
		local segsByTex = {}
		local curSeg = nil
		-- tex→model序号表(fbx.model_list同构: 无贴图mesh透明跳过, 贴图名
		-- 变化即新run(runI递增), 同名后现覆盖=取最后run) — 命中dims缓存后
		-- submitResources零解析直达model_to_particle(引擎磁盘缓存指纹跳过
		-- 构建)。
		local modelIdx = {}
		local runTex, runI = nil, -1
		for _, g in ipairs(mg.groups or {}) do
			local tn = texName[(g.tex or -1) + 1] or ""
			if tn ~= "" then
				if not curSeg or curSeg.tex ~= tn then
					curSeg = { tex = tn, items = {} }
					segsByTex[tn] = curSeg
				end
				curSeg.items[#curSeg.items + 1] = g
				if tn ~= runTex then
					runI = runI + 1
					runTex = tn
				end
				modelIdx[tn] = runI
			end
		end
		G.segsByTex = segsByTex
		G.modelIdx = modelIdx
	end
	-- 2. type分配后立即提交注入(cs_variant_pick bake G.type, 必须在
	--    register_type之后; anim/parts由缓存就位=全部5路即最终内容)。确保
	--    在worker init读shader源(程序构建期)前落地 → init直编最终版; 若
	--    init已先读源, 引擎init末尾的injectGen对账会补跑reloadPrograms兜底。
	--    (首提交在ensureType之前是错误的: pick空串会清注入+与真实内容竞态
	--    → gen预热与运行期产出不同key=缓存永miss)
	if not ensureType(G.texDims) then
		return false
	end
	-- 无有效anim时跳过早提交 — 早提交的意义=worker init前落地最终注入
	-- (单key); animFromCache命中/anim已在G时内容=最终, 提交无害且必要;
	-- anim空(fbx刚失效/冷启动无fish.dims.json)时兜底默认值必被
	-- registerResources重算覆盖 → gen++两次+两次程序重建。跳过后由
	-- registerResources单次提交最终内容(冷启动无dims的罕见路径以init无
	-- 注入版+一次重建为代价, 权衡正确)。
	if not G.shadersDone and (G.animFromCache or next(G.anim)) then
		G.shadersDone = submitShaders()
	end
	if not G.resReady then
		local ok, err = registerResources(G.texDims)
		if not ok then
			return false, err
		end
		-- 3. 资源全就绪: anim/parts落盘(下进程命中→首提交即最终内容)
		-- 盘上已有有效缓存(ver+fbx指纹匹配)时**永不写盘** — json键序经
		-- decode/重算/encode往返不稳定, 盲比对必判"内容变化"→写盘→extScan
		-- re-run→re-run又写=每启动连环重跑36模型。cacheLoaded跨re-run持久:
		-- 首载命中后, 本进程任何applyOnce都不再写; 仅首载失效(fbx素材变更/
		-- ver升级)才重算+落盘一次。
		-- 自愈落盘: 真自愈(丢dims重解析)后的parts/anim是最新真相(旧缓存=
		-- 旧解析产物), 必须写盘覆盖 — 否则每次启动都重走"cache命中→自愈→
		-- 重解析"链=注入gen每run+1。
		if (not cacheLoaded) or G.selfHealed then
			saveAnimCache()
			G.selfHealed = false
		end
	end
	return true
end

local function enableTank()
	if not G.resReady then
		local ok, err = applyOnce()
		if not ok then
			log("enable aborted: " .. tostring(err) .. " (重试中, 稍后再开)")
			return
		end
	end
	-- 让位基线: ①显式清ecoYield(关再开即恢复生态群); ②开缸前基线快照 —
	-- 开缸前已存在的FS同类型发射器(图片sidecar槽位恢复/用户既有配置)是
	-- 既有选择, 与生态群共存; 让位只对**开缸后新增**的foreign发射器触发
	-- (真用户面板自建→退出)。
	G.ecoYield = nil
	do
		local ownIds = {}
		for _, id in pairs(G.emitterIds) do
			ownIds[id] = true
		end
		local base = {}
		local pinfo = fcc.rpc("particle", "info", {})
		if type(pinfo) == "table" and type(pinfo.emitters) == "table" then
			for _, e in ipairs(pinfo.emitters) do
				if
					type(e) == "table"
					and e.type == G.type
					and e.fs == true
					and type(e.id) == "number"
					and not ownIds[e.id]
				then
					base[e.id] = true
				end
			end
		end
		G.foreignBaseline = base
		local n = 0
		for _ in pairs(base) do
			n = n + 1
		end
		if n > 0 then
			log("开缸: 既有FS同类型发射器" .. n .. "路共存(基线快照, 不触发让位)")
		end
	end
	addEmitters()
	G.enabled = true
	log(
		"鱼类扩展 ON (type="
			.. G.type
			.. " base="
			.. G.base
			.. " "
			.. G.rtW
			.. "x"
			.. G.rtH
			.. " RT, 侧视, "
			.. NSPEC
			.. "种鱼)"
	)
end

local function disableTank()
	removeEmitters()
	fcc.rpc("particle", "kill_type", { type = G.type })
	G.enabled = false
	log("鱼类扩展 OFF (粒子清场; 类型/模型/贴图/注入保持登记)")
end

local function toggleTank()
	if G.enabled then
		disableTank()
	else
		enableTank()
	end
end

-- ============================================================================
-- 入口 + load即登记
-- ============================================================================
-- 无右键菜单 — 鱼缸作为面板粒子类别使用, 发射器由粒子面板/图片sidecar配置
-- 驱动; 本脚本只负责一次性登记 类型/变体/模型/贴图/注入。
-- 默认不开缸 — 无参数运行fcc.exe不得出现鱼缸; 调试/测试通过debug-server
-- /lua 调 fishtank_toggle() 动态启停。
math.randomseed((os.time() % 100000) + 1873)
local gen = (_G.__FISHTANK_GEN or 0) + 1 -- 代际号: 热重载后旧回调自杀
_G.__FISHTANK_GEN = gen

-- ============================================================================
-- 注入守护watchdog: 每hook注入槽按属主(id)独立拼接, 本扩展'fish'属主被
-- 覆盖(内容丢失/变更)即重提交全部5路。低频(0.1Hz)比对 shader info 注入
-- size: 任一hook size≠本扩展提交值即被覆盖 → 重提交。
-- ============================================================================
local WD_PERIOD = 10.0
local TEXCHECK_PERIOD = 60.0 -- 贴图收敛自检周期(36次slot_info, 低频)
local wdNext = 0.0
local texNext = 0.0

fcc.on_update(function(t)
	if _G.__FISHTANK_GEN ~= gen then
		return
	end
	-- 资源管线**永久重试** — 渲染暂停(窗口遮挡/最小化/离屏, fcc暂停帧
	-- 渲染)时t冻结, 一次性重试会饿死 ⇒ resReady永假 ⇒ 出生门永闭 ⇒ 无鱼。
	-- 主watchdog顶部永久重试(0.25s节流, applyOnce幂等只补缺失) — 渲染恢复
	-- (用户看缸)即续跑, 数据就绪才开出生门语义不变(变体登记仍在resReady
	-- 之后)。
	if not G.resReady then
		if t >= (G.resNextT or 0.0) then
			-- 0.25s节流: NSPEC变体mesh+贴图relayout收敛需多轮轮询(~7s收敛,
			-- slot_info轻量, 负载可控)
			G.resNextT = t + 0.25
			local okC, okR, whyR = pcall(applyOnce)
			G.lastApplyErr = okC and (tostring(okR) .. " / " .. tostring(whyR)) -- 诊断
				or ("EXC: " .. tostring(okR))
			if not okC then
				log("applyOnce异常: " .. tostring(okR))
			elseif okR ~= true then
				-- 失败分类: 'wait'(GL init期mesh library未就绪/贴图pending
				-- 等渲染帧flush)=正常等待, 重试即可, **不计入自愈计数**;
				-- 其他=真坏数据。
				if whyR == "wait" then
					G.resFailN = 0
				else
					-- 真坏数据自愈: 连续mismatch(槽位错位/解析缺项落盘的
					-- 坏缓存)超阈值 → 丢dims+禁读盘缓存(真重解析), 而非
					-- 无限幂等重试
					G.resFailN = (G.resFailN or 0) + 1
					if G.resFailN >= 12 then
						log(
							"⚠资源收敛连续失败"
								.. tostring(G.resFailN)
								.. "次, 丢弃dims数据强制重解析自愈"
						)
						G.resFailN = 0
						G.texDims, G.segsByTex, G.modelIdx = nil, nil, nil
						G.cacheLoaded = false
						G.skipDiskCache = true -- 自愈轮禁读盘(防旧数据装回)
						G.selfHealed = true -- 重解析产物落盘(下run直接命中)
						G.m2pOkOnce = nil -- 强制重走m2p
						G.animFromCache = nil -- parts将重取, anim必须重算
					end
				end
			else
				G.resFailN = 0
			end
		end
		return
	end
	-- 变体守卫: 登记部分失败时节流重试(幂等覆盖) — 未完成期间
	-- variantDomainCount<36, cs_emit随机域变体不足/出生门未全开, 禁走下方
	-- 场景守护(其patch语义假定全物种域就绪); 重试成功即继续
	if not G.variantsDone then
		if t >= (G.varNextT or 0.0) then
			G.varNextT = t + 0.25
			G.variantsDone = registerVariants()
			if G.variantsDone then
				log("变体重试完成: 出生门开启(type=" .. tostring(G.type) .. ")")
			end
		end
		if not G.variantsDone then
			return
		end
	end
	-- 法线槽驻场管线: 逐变体节流计算(亮度Sobel→法线槽base+36+v,
	-- 与albedo同布局同rUT映射), 全36完成后静止(atlas常驻=备用, FS注入按
	-- vEmNormal.x门控消费)。luajit下单变体~20-60ms, 启动暖机期0.15s/条摊开。
	-- atlas cache已含法线槽(build/install期gen pump生成) → 探测首槽
	-- (variant=NSPEC, 顺序写入语义首槽在即全在)已上传且尺寸=素材原生 →
	-- 整条管线跳过。
	if G.normIdx == 0 and not G.normProbeDone and G.type then
		G.normProbeDone = true
		local sp0 = SPECIES[BYVAR[0] or 1]
		local si = fcc.rpc("particle", "slot_info", { type = G.type, variant = NSPEC })
		local want = G.texDims and G.texDims[sp0.tex]
		if type(si) == "table" and si.uploaded and want and si.w == want[1] and si.h == want[2] then
			G.normIdx = NSPEC
			log("法线槽已就绪(atlas cache), 跳过重算管线")
		end
	end
	if G.normIdx < NSPEC then
		if t >= (G.normNextT or 0.0) then
			G.normNextT = t + 0.15
			local okN, rN = pcall(buildNormalSlot, G.normIdx)
			if not okN then
				log("法线槽异常v" .. G.normIdx .. ": " .. tostring(rN) .. " (管线终止)")
				G.normIdx = NSPEC
			elseif rN == true then
				G.normIdx = G.normIdx + 1
				if G.normIdx == NSPEC then
					log("法线槽36/36就绪(atlas常驻备用, 法线贴图参数开启即生效)")
				end
			elseif G.type then
				-- 持久失败(素材decode坏/RPC错): 跳过该变体防管线卡死;
				-- G.type=nil=容量不足清场重注册路径(buildNormalSlot内已自
				-- 归零), 不推进 — 下一帧applyOnce重注册后从0重来
				G.normIdx = G.normIdx + 1
			end
		end
	end
	if t < wdNext then
		return
	end
	wdNext = t + WD_PERIOD
	-- (a0) 模板热重载: 注入GLSL模板外置 res/shaders/glsl/particle/
	--     inject/fish/*.glsl — 比对模板文件内容(与submitShaders时快照),
	--     变化自动重bake+重提交注入(引擎侧pollEvents管线后台重建adopt)。
	--     改模板文件保存即生效, 无需重启/改本脚本。模板读失败(nil)不触发。
	if G.shadersDone and G.tplSnaps then
		local tplChg = false
		for _, name in ipairs(FISH_TPL_NAMES) do
			local c = fishTpl(name)
			if c ~= nil and c ~= G.tplSnaps[name] then
				G.tplSnaps[name] = c
				tplChg = true
			end
		end
		if tplChg then
			log("模板热重载: 注入GLSL模板变化, 重提交5路")
			submitShaders()
		end
	end
	-- (a) 注入守护: 守护只看本扩展'fish'属主槽 — papers等其余属主独立
	--     拼接, 不构成本扩展被覆盖; 属主size≠提交值即重提交5路
	local info = fcc.rpc("shader", "info", {})
	if type(info) == "table" and type(info.injects) == "table" then
		for _, it in ipairs(G.lastInject or {}) do
			local slot = info.injects[it.hook]
			local sz = type(slot) == "table" and type(slot.owners) == "table" and slot.owners.fish or nil
			if type(sz) ~= "number" or sz ~= #it.code then
				log(
					"注入守护: "
						.. it.hook
						.. " 被覆盖(size "
						.. tostring(sz)
						.. "≠"
						.. #it.code
						.. "), 重提交5路"
				)
				submitShaders()
				break
			end
		end
	end
	-- (a2) 贴图收敛自愈: atlas relayout/异常路径可能清slotUploaded
	--     (本体会幂等跳过无变化布局, 此处兜底真实重建后的回填) — 低频全槽
	--     校验, 任一缺失/尺寸不符即 submitResources 幂等补传(只补缺失槽)
	if t >= texNext then
		texNext = t + TEXCHECK_PERIOD
		local miss = false
		for v = 0, NSPEC - 1 do
			local sp = SPECIES[BYVAR[v] or 1]
			local si = fcc.rpc("particle", "slot_info", { type = G.type, variant = v })
			local bad = type(si) ~= "table" or not si.uploaded
			if not bad then
				local want = G.texDims and G.texDims[sp.tex]
				if want and want[1] > 0 and want[2] > 0 then
					bad = (si.w ~= want[1]) or (si.h ~= want[2])
				end
			end
			if bad then
				miss = true
			end
		end
		if miss then
			log("贴图自愈: 检测到槽位缺失/尺寸不符, 幂等补传...")
			submitResources(G.texDims, true)
		end
	end
	-- 发射器dump(守护消费)
	local pinfo = fcc.rpc("particle", "info", {})
	-- (b) 场景守护(用户参数至上): 守护只治**非法/坏档值**, 永不改写
	--     用户合法选择 — vfxF=0悬停/vfxC=+1吸引/viewAngle任意俯仰/暗色
	--     氛围都是用户权利。
	--     info.emitters = 主+FS合并表(id已含FS高位, emitters.update同语义)。
	--     守护门控: 缸关闭态下仅当存在本类型发射器(FS缸/主系统/面板全屏)
	--     才继续 — info是全量类型+发射器dump的重调用, 无目标时跳过省开销;
	--     G.enabled=false是FS缸开关, 面板发射器独立于缸开关。
	--     (pinfo由上方无条件dump, 此处复用)
	if type(pinfo) ~= "table" or type(pinfo.emitters) ~= "table" then
		return
	end
	if not G.enabled then
		local anyMain17 = false
		for _, e in ipairs(pinfo.emitters) do
			-- 面板全屏发射器(FS系统+mode5)也是守护对象
			if type(e) == "table" and e.type == G.type and type(e.id) == "number" and (not e.fs or e.mode == 5) then
				anyMain17 = true
				break
			end
		end
		if not anyMain17 then
			return
		end
	end
	-- 默认**不**自动开缸 — 普通运行fcc.exe不得强制出现鱼缸; 登记只注册
	-- 类型/模型/贴图/注入(面板可选类别), 发射器由用户面板/sidecar档驱动;
	-- 测试用debug-server动态fishtank_toggle()。
	local ownIds = {}
	for _, id in pairs(G.emitterIds) do
		ownIds[id] = true
	end
	local foreignFs = false
	G.lightDefaulted = G.lightDefaulted or {} -- 会话内光照默认已置位表
	-- 开缸前基线快照内的foreign=用户既有选择(与生态群共存), 只有**新增**
	-- foreign(开缸后用户面板自建)才触发让位(见enableTank快照)
	local baseFs = G.foreignBaseline or {}
	for _, e in ipairs(pinfo.emitters) do
		if type(e) == "table" and e.type == G.type and type(e.id) == "number" then
			if e.fs and not ownIds[e.id] and not baseFs[e.id] then
				foreignFs = true
			end
			local patch = nil
			-- 非法值才治(范围外/缺失); 范围内的任何用户值原样保留
			if type(e.vfxF) ~= "number" or e.vfxF < 0.0 or e.vfxF > 3.0 then
				patch = patch or {}
				patch.vfxF = 1.0
			end
			-- 视角零干预 — 任意俯仰都是用户权利(引擎shader鼠标视补偿/
			-- 出生盘原生支持任意视角), 默认值由引擎鱼群域单源继承。
			if type(e.vfxB) ~= "number" or e.vfxB < 0.0 or e.vfxB > 1.5 then
				patch = patch or {}
				patch.vfxB = 1.0
			end
			if type(e.vfxC) ~= "number" or e.vfxC < -1.0 or e.vfxC > 1.0 then
				patch = patch or {}
				patch.vfxC = -0.3
			end
			-- envAmbient非法值才治(<0或>2; 0=全黑是合法用户选择)
			-- **非全屏**模式默认值 — 会话内每个面板发射器**首次**进入守护
			-- 时置env=1.0/light=1.0(切非全屏=默认值语义); 之后**让位用户
			-- 滑条**。FS全屏缸保持env1.2(非法值照旧治), light/size不碰。
			if not e.fs then
				local ldN5 = G.lightDefaulted
				if not ldN5[e.id] then
					ldN5[e.id] = true
					patch = patch or {}
					patch.envAmbientCoef = 1.0
					patch.lightDirStr = 1.0
				elseif type(e.envAmbientCoef) ~= "number" or e.envAmbientCoef < 0.0 or e.envAmbientCoef > 2.0 then
					patch = patch or {}
					patch.envAmbientCoef = 1.0
				end
			elseif type(e.envAmbientCoef) ~= "number" or e.envAmbientCoef < 0.0 or e.envAmbientCoef > 2.0 then
				patch = patch or {}
				patch.envAmbientCoef = 1.2
			end
			-- sizeVariance残留(旧档cm×0.14值) — 个体方差由VS内fract(seedN)
			--   承担, 发射器方差恒0(面板无此滑条, 归零零误伤)
			if type(e.sizeVariance) ~= "number" or e.sizeVariance > 0.001 then
				patch = patch or {}
				patch.sizeVariance = 0.0
			end
			-- mode治愈收窄到非法值 — mode3(逆风侧)/mode4(generic/DiskXY=
			--   诱饵域)与mode1/2(图内带)都是用户合法发射位置选择, 不得治愈
			--   (mode3引擎链完整: cs_emit图内水域采样/cs_physics洄游块/
			--   inWaterF行进线探针, 鱼不重定向零诱饵需求)。
			-- FS发射器跳过mode补丁 — 面板slot发射器的mode5=用户"发射位置:
			--   全屏"配置本体(FS路由标记, 行为≈mode0); 补丁mode→0经
			--   emitters.update触发跨系统remove+re-add, 面板sync随即重建回
			--   mode5+重掷tex+参数回退面板遗留值 → 每5s重建死循环。
			if not e.fs and type(e.mode) ~= "number" then
				patch = patch or {}
				patch.emitPositionMode = 0
			end
			-- size全0=sidecar僵尸发射器(点发射=全堆屏心) → 补mode5标准
			-- 全屏盒(与addEmitters同源)
			if
				type(e.sizeX) ~= "number"
				or type(e.sizeY) ~= "number"
				or type(e.sizeZ) ~= "number"
				or e.sizeX + e.sizeY + e.sizeZ < 1.0
			then
				patch = patch or {}
				patch.emitPositionMode = 5
				patch.sizeX = G.rtW
				patch.sizeY = G.rtH
				patch.sizeZ = 200.0
				patch.posY = 0.0
			end
			-- tex非法(<-1或>35)=僵尸发射器残留 → 轮转物种变体;
			-- -1=随机模式合法值(随机模式+每物种CAPS上限=生态鱼缸本体)
			if type(e.tex) ~= "number" or e.tex < -1 or e.tex > 35 then
				patch = patch or {}
				patch.textureIndex = e.id % 36
			end
			-- 自有发射器mode治愈 — sidecar持久化的mode1/4发射器原地补丁到
			--   mode5全屏盒(与addEmitters同源, emitters.update原地补丁不
			--   重建, 存量鱼不重掷)。用户面板自建发射器(非ownIds)不受影响。
			--   视角零治愈 — 出生时已继承鱼群域默认, 用户值不回改。
			if ownIds[e.id] then
				if (type(e.mode) ~= "number" or math.abs(e.mode - 5) > 0.5)
					or (type(e.sizeX) ~= "number" or math.abs(e.sizeX - G.rtW) > 2.0)
					or (type(e.sizeY) ~= "number" or math.abs(e.sizeY - G.rtH) > 2.0)
				then
					patch = patch or {}
					patch.emitPositionMode = 5
					patch.posY = 0.0
					patch.sizeX = G.rtW
					patch.sizeY = G.rtH
					patch.sizeZ = 200.0
				end
			end
			if patch then
				patch.id = e.id
				local r = fcc.rpc("particle", "emitters.update", patch)
				log("场景守护 emitter " .. e.id .. ": " .. (r and r.ok and "ok" or tostring(r and r.error)))
			end
		end
	end
	-- 生态让位: 用户自建**FS全屏**本类型发射器(面板选种+发射位置=全屏)
	--   时, 扩展自动加的36路生态群退出(拆自身发射器, 不碰用户粒子) — 否则
	--   全屏群游淹没选种。
	--   仅FS让位: main系统小盒发射器=局部点缀(几条鱼), 与生态缸共存无冲突。
	--   一次性闩锁: fishtank_toggle 关再开即恢复生态群(重启进程默认无鱼)。
	if foreignFs and G.enabled and G.ecoYield ~= true then
		log("生态让位: 检测到用户自建鱼类FS发射器, 扩展生态群退出")
		G.ecoYield = true
		removeEmitters()
		-- 让位=缸事实已关(发射器拆除+鱼清场), 状态同步为关
		G.enabled = false
	end
end)

local ok, err = applyOnce()
if ok then
	log(
		"v5 loaded: 动态类型登记完成 (type="
			.. tostring(G.type)
			.. " base="
			.. tostring(G.base)
			.. " "
			.. NSPEC
			.. "物种, 出生门="
			.. (G.variantsDone and "开(数据就绪)" or "重试中")
			.. ")"
	)
else
	-- 重试移交主watchdog永久执行(0.25s节流, 渲染暂停免疫)
	log("粒子未就绪(" .. tostring(err) .. "), watchdog永久重试中...")
end

-- 调试入口(debug-server /lua 可直接调用)
fishtank_toggle = toggleTank
-- 调试: 物种体长标定表(LEN_CM=SIZE_DENOM×sizeK×cm×scaleOf, 与
-- CS注入表同源) — fish_dump行为分析与槽位映射核验用
fishtank_lens = function()
	local out = {}
	for v = 0, NSPEC - 1 do
		local sp = SPECIES[BYVAR[v] or 1]
		out[#out + 1] = {
			v = v,
			cn = sp.cn,
			cm = sp.cm,
			sc = scaleOf(sp),
			lenCm = SIZE_DENOM * sizeK(1080) * sp.cm * scaleOf(sp),
			flock = (sp.beh.flock or 0) > 0.5,
		}
	end
	return out
end
-- 调试: 重新提交shader注入(注入槽按属主独立拼接, 重提交即覆盖; 资源/
-- 变体登记不动, 仅5路GLSL重编译)
fishtank_resubmit = function()
	G.shadersDone = false
	local ok, err = submitShaders()
	G.shadersDone = ok
	return "resubmit=" .. tostring(ok) .. (err and (" err=" .. tostring(err)) or "")
end
-- 调试: 出生门/注入内部状态真值
fishtank_gate = function()
	local ok, r = pcall(function()
		return fcc.rpc("shader", "info")
	end)
	local i = (ok and type(r) == "table" and r.injects) or {}
	return string.format(
		"variantsDone=%s genSub=%s sawInflight=%s injGen=%s inflight=%s",
		tostring(G.variantsDone),
		tostring(G.injectGenSub),
		tostring(G.injectSawInflight),
		tostring(i.gen),
		tostring(i.inflightGen)
	)
end
fishtank_state = function()
	local n = 0
	for _ in pairs(G.emitterIds) do
		n = n + 1
	end
	local np = 0
	for _ in pairs(G.parts) do
		np = np + 1
	end
	return string.format(
		"enabled=%s resReady=%s type=%s base=%s emitters=%d/%d rt=%dx%d parts=%d",
		tostring(G.enabled),
		tostring(G.resReady),
		tostring(G.type),
		tostring(G.base),
		n,
		NSPEC,
		G.rtW,
		G.rtH,
		np
	)
end
fishtank_parts = function(variant)
	local p = G.parts[variant or 0] or {}
	local out = {}
	for i, x in ipairs(p) do
		out[#out + 1] = string.format(
			"#%d %s n=%d bb=[%.3f,%.3f,%.3f,%.3f,%.3f,%.3f]",
			i,
			x.name or "",
			x.count or 0,
			x.bb[1],
			x.bb[2],
			x.bb[3],
			x.bb[4],
			x.bb[5],
			x.bb[6]
		)
	end
	return table.concat(out, "\n")
end
fishtank_anim = function(variant)
	local a = G.anim[variant or 0]
	if not a then
		return "nil"
	end
	return string.format(
		"tailZ=%.4f zMin=%.4f zMax=%.4f zSpan=%.4f pectZ=[%s,%s] pectX=%s"
			.. " pelvZ=[%s,%s] pelvX=%s pelvY1=%s"
			.. " eye=[%s,%s,%s,r=%s] barbZ=%s topY=%.3f botY=%.3f",
		a.tailZ,
		a.zMin,
		a.zMax,
		a.zSpan,
		tostring(a.pectZ0),
		tostring(a.pectZ1),
		tostring(a.pectX),
		tostring(a.pelvZ0),
		tostring(a.pelvZ1),
		tostring(a.pelvX),
		tostring(a.pelvY1),
		tostring(a.eyeZ),
		tostring(a.eyeY),
		tostring(a.eyeX),
		tostring(a.eyeR),
		tostring(a.barbZ),
		a.bodyTopY or 0,
		a.bodyBotY or 0
	)
end

-- 调试: 把最近提交的注入 GLSL 导出到文件(核验生成代码/行号/字面量)
fishtank_dump_inject = function(dir)
	if type(io) ~= "table" or not io.open then
		return "no io lib"
	end
	local out = {}
	for _, it in ipairs(G.lastInject or {}) do
		local p = (dir or "D:/work/fish/temp") .. "/inj_" .. it.hook .. ".glsl"
		local f = io.open(p, "w")
		if not f then
			return "cannot write " .. p
		end
		f:write(it.code)
		f:close()
		local nl = 0
		for _ in it.code:gmatch("\n") do
			nl = nl + 1
		end
		out[#out + 1] = it.hook .. "=" .. #it.code .. "B/" .. nl .. "L"
	end
	return table.concat(out, " ")
end

return true
