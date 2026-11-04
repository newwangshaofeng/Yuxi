-- ============================================================================
-- 矿产资源规划智能体 · 业务数据库结构
-- 引擎: PostgreSQL 14+ / PostGIS 3.x
-- 坐标系: CGCS2000 经纬度 EPSG:4490（入库统一）；面积按 EPSG:4547 计算后落列
-- 面积单位: km² ； 储量单位: 随 reserve_unit 字段 ； 金额单位: 万元
--
-- 【设计依据】DZ/T 0226-2020《矿产资源规划数据库标准》成果数据实测结构
--   · 规划附表库 C1_341800_0_2020.mdb → 5 张规划指标/规则表
--       KSKCGM 最低开采规模 / KSZRZB 矿山准入标准 / DZXKSBLZB 大中型矿山比例
--       XKCDJXZZYLZB 规划期新增资源量 / LSKYZB 历史遗留矿山治理
--   · 空间成果库 C1_341800_T_2020.mdb → 7 个要素类
--       KANCHQZD 重点勘查区 / KANCHQK 勘查规划区块 / KAICQZD 重点开采区
--       KAICQK 开采规划区块 / KAICQST 砂石土集中开采区 / JMDDZ 乡级行政区面 / XZQ 行政区面
--   · 现状附表（横版专题附表、规划专题研究报告附表）→ 储量、矿区、开发利用、矿山、
--     探矿权、采矿权 6 类现状数据
--
-- 【设计定位】只建业务存储表，不含任何函数、视图、触发器、ETL 与暂存表。
--   共 25 张表：
--     dim_*       5   数据字典（期次、行政区、矿种、通用字典、要素代码）
--     fact_*      8   现状数据（矿区、储量、矿区矿产、开发利用、矿山、矿山矿产、探矿权、采矿权）
--     plan_*     11   规划成果（空间分区 5 + 属性表 6）
--     map_*       1   空间图层（图层目录、服务信息与管控边界，一张表）
--
-- 【无函数、无视图后的三条补偿设计】
--   ① 坐标解析不调函数：几何由入库脚本解析后直接写入 geom 列；解析失败允许 geom 为
--      NULL，不阻断整批（源表坐标格式混存，强约束会卡死入库）。
--   ② 面积只存一列：area_km2 取源报表填报值，与已发布规划文本一致，作为对外口径。
--      几何面积不落列，需要时按 ST_Area(ST_Transform(geom, 4547)) / 1000000 现算，
--      避免派生列在几何修正后失去同步、库内出现两个互相矛盾的面积。
--   ③ 规划五表不建统一视图：五表共有列严格同名（period_id / zone_code / zone_name /
--      admin_regions / area_km2 / main_minerals / geom），智能体需要
--      全景时按固定列序写 UNION ALL 即可，列名不用猜。
--
-- 【入库顺利性的设计约定】—— 决定一张表能不能装下源数据
--   1. 源自报表的业务字段一律 VARCHAR，不加 CHECK/ENUM。异体写法先入库，靠 dim_dict
--      事后比对出清单，不因一个错别字让整批回滚。
--   2. 受控的结构性字段（period_type / period_role / status / data_status）用 CHECK，
--      值由系统控制。
--   3. 唯一键涉及的所有列均 NOT NULL 或给默认值。PG 中 NULL 不等于 NULL，唯一约束对
--      NULL 不生效，重跑即翻倍 —— 这是最常见的入库事故。
--   4. 数值统一 NUMERIC，不用 FLOAT/DOUBLE，避免浮点漂移导致对账不平。
--   5. 主键一律带 period_id：同一实体在两个期次各存一行，代理键在期内唯一，不带期次则第二期入库直接撞键。
--   6. 主键不取源编号，一律用系统生成的随机字符串代理键（详见下条【主键约定】）。
--   7. 每张表写 COMMENT ON TABLE，说明源表来源与口径，供 Text-to-SQL 与入库脚本直接读。
--
-- 【主键约定】—— 全库只有两种主键，按表性质二分，不再有第三种
--   ① 代理键（随机字符串）：现状数据层 fact_* 与规划成果层 plan_* 全部使用。
--      格式「前缀-16位大写十六进制」，如 MN-9C4A7F13B8E24D6A，由列 DEFAULT 表达式生成；
--      gen_random_uuid() 是 PostgreSQL 13+ 内置函数，不装 pgcrypto 扩展，也不是自建函数对象。
--      取 64 位随机量，百万行量级碰撞概率约 10^-8，主键约束兜底。
--      前缀：OF 矿区 / MN 矿山 / ER 探矿权 / MR 采矿权 / ZN 空间区块 / ID 明细与属性表行。
--   ② 编码键（受控编码）：维表 dim_* 与图层目录 map_layer。
--      期次名、行政区划码、矿种代码、要素代码、图层编码均来自国家标准或库内定义，
--      本身即唯一业务标识，不存在缺失与待补问题；随机化只会让业务人员与 Text-to-SQL 失去可读锚点。
--
--   【为什么主键不用源编号】源报表的编号是人工填报值，存在三类硬伤，任何一种都会让主键失效：
--     · 缺失：矿区 6/226 行、矿山 17/149 行编号为空（已确认非合并单元格），当主键则这些行永远入不了库，
--       其下的矿产明细还会连带失败；
--     · 跨轮次复用：同一编号在十四五与十五五指向不同对象，必须靠 period_id 区分；
--     · 待补与变更：业主要求后续补充缺失编号，若主键即编号，补编号等于改主键，外键级联与历史引用全部失效。
--   因此源编号统一降级为普通列 *_code，可为空，补充到位后用 UPDATE 回填，主键与引用关系不受影响。
--   对 *_code 建部分唯一索引（WHERE *_code IS NOT NULL），保证补一个不撞一个，同一期内不重复。
--
--   跨期同一实体如何关联：mine_id / ore_field_id / right_id 是实体级代理键，同一实体在各期共用同一个值
--   （入库脚本按 名称 + 行政区 + 矿种 或 许可证号 判同后复用），故主键 (period_id, mine_id) 仍支持
--   「同一矿山两期对比」。源编号缺失且名称发生变更时无法判定为同一实体，脚本会生成新键，
--   该情形列入第 9 章遗留问题，由业主补编号后人工并档。
--
--   关系表 fact_mine_mineral 不另生成代理键，直接用外键组合做主键，避免一条关系两套标识。
--
-- 【执行】本文件为完整基线，单次顺序执行即可建库；重复执行前须清空目标 schema。
--   执行后的表清单核对见文末注释。
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;      -- 名称模糊检索（矿区名/矿山名/区块名）


-- ============================================================================
-- 第一层  数据字典 dim_*
--   只放「编码—名称」对照：期次、行政区、矿种、值域、要素代码。
--   本层不含任何量值，也不含随期次变动的实体。
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 期次：规划轮次 × 时段角色（base 基期 / plan 目标期）
--   period_id 用中文业务名做主键，业务人员与报表直接用；
--   period_code 是英文码，代码分支/日志/接口参数一律走它
--   轮次信息（cycle_code / cycle_name）内置于本表，不另建轮次表
-- ---------------------------------------------------------------------------
CREATE TABLE dim_period (
  period_id     VARCHAR(16) PRIMARY KEY,             -- 十四五基期 / 十四五规划 / 十五五基期 / 十五五规划
  period_code   VARCHAR(16) NOT NULL UNIQUE,         -- FYP14_BASE / FYP14_PLAN …
  period_label  VARCHAR(64) NOT NULL,                -- 十四五基期（2020年现状）
  period_type   VARCHAR(8)  NOT NULL CHECK (period_type IN ('status','plan')),
  period_role   VARCHAR(8)  NOT NULL CHECK (period_role IN ('base','plan')),
  cycle_code    VARCHAR(16) NOT NULL,                -- FYP14
  cycle_name    VARCHAR(32) NOT NULL,                -- 十四五
  start_year    SMALLINT,
  end_year      SMALLINT,
  remark        TEXT,
  created_at    TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (cycle_code, period_role)
);
COMMENT ON TABLE dim_period IS
  '期次字典，全库跨期对比的主轴。所有现状数据表与规划表都挂 period_id，智能体做同比/执行偏差靠它。'
  '注意：2025 在十四五是目标年、在十五五是基期年，两行数据语义不同，不可合并。';
COMMENT ON COLUMN dim_period.period_id   IS '中文主键，供业务人员与报表直接使用';
COMMENT ON COLUMN dim_period.period_code IS '英文码，代码与接口参数使用，禁止在代码里用中文字面量判断';
COMMENT ON COLUMN dim_period.period_role IS 'base 基期现状单年快照 / plan 目标期多年区间';

INSERT INTO dim_period
  (period_id, period_code, period_label, period_type, period_role,
   cycle_code, cycle_name, start_year, end_year, remark) VALUES
  ('十四五基期','FYP14_BASE','十四五基期（2020年现状）','status','base','FYP14','十四五',2020,2020,
   '本轮规划现状基准年，单年快照'),
  ('十四五规划','FYP14_PLAN','十四五规划（2021—2025年）','plan','plan','FYP14','十四五',2021,2025,
   '本轮规划目标期'),
  ('十五五基期','FYP15_BASE','十五五基期（2025年现状）','status','base','FYP15','十五五',2025,2025,
   '2025年底实际达成值，与十四五规划目标相减即规划执行偏差'),
  ('十五五规划','FYP15_PLAN','十五五规划（2026—2030年）','plan','plan','FYP15','十五五',2026,2030,
   '下一轮规划目标期')
ON CONFLICT (period_id) DO NOTHING;


-- ---------------------------------------------------------------------------
-- 行政区（自引用上级）
-- ---------------------------------------------------------------------------
CREATE TABLE dim_admin_region (
  region_code   VARCHAR(12) PRIMARY KEY,
  region_name   VARCHAR(64) NOT NULL,
  parent_code   VARCHAR(12) REFERENCES dim_admin_region(region_code),
  region_level  SMALLINT,                            -- 1省 2市 3县 4乡
  ysdm          VARCHAR(16),                         -- 要素代码：乡级行政区 1000310106
  data_year     SMALLINT,                            -- 数据年份 YYSJ
  geom          geometry(MultiPolygon, 4490),
  remark        TEXT,
  created_at    TIMESTAMP NOT NULL DEFAULT now()
);
COMMENT ON TABLE dim_admin_region IS
  '行政区字典。存市本级与下属县市区 7 条（源 XZQ 图层，XZQHDM / XZQHMC 两列有值），'
  'parent_code 自引用成树，供按行政区分组统计。'
  '乡级行政区面 94 条不入本表：源 JMDDZ 图层只有居民地名称、没有区划代码，'
  '硬造代码会破坏「代码取自标准、不自造」的口径，故登记为 map_layer 的基础地理图层，边界随服务取用。';
COMMENT ON COLUMN dim_admin_region.ysdm     IS '来源图层的要素代码，用于回溯到标准成果库';
COMMENT ON COLUMN dim_admin_region.data_year IS '来源图层的数据年份 YYSJ';
CREATE INDEX idx_region_geom  ON dim_admin_region USING GIST(geom);
CREATE INDEX idx_region_parent ON dim_admin_region(parent_code);


-- ---------------------------------------------------------------------------
-- 矿种
-- ---------------------------------------------------------------------------
CREATE TABLE dim_mineral (
  mineral_id        VARCHAR(32) PRIMARY KEY,
  mineral_code      VARCHAR(16),                     -- 国家标准矿产代码 KCDM：32006 铜 / 32014 钨 / 63701 普通萤石 / 11009 石煤
  mineral_name      VARCHAR(64) NOT NULL,
  mineral_category  VARCHAR(16),                     -- 能源矿产/金属矿产/非金属矿产/水气矿产
  is_key_mineral    BOOLEAN NOT NULL DEFAULT FALSE,  -- 是否战略性/重点矿种
  default_unit      VARCHAR(32),
  remark            TEXT,
  created_at        TIMESTAMP NOT NULL DEFAULT now()
);
COMMENT ON TABLE dim_mineral IS
  '矿种字典。mineral_code 存 DZ/T 0226-2020 标准矿产代码，与上级系统及其他县市库对接的唯一凭据；'
  'mineral_id 是库内代理键。两者并存：库内关联用 mineral_id，对外交换用 mineral_code。';
COMMENT ON COLUMN dim_mineral.mineral_code IS
  '国家标准矿产代码。可空：源表未给代码时先按名称入库，后补代码，不阻断入库。';
CREATE UNIQUE INDEX ux_mineral_name ON dim_mineral(mineral_name);
CREATE UNIQUE INDEX ux_mineral_code ON dim_mineral(mineral_code) WHERE mineral_code IS NOT NULL;


-- ---------------------------------------------------------------------------
-- 通用字典
--   业务表按 dict_type 逻辑引用（无物理外键）：一个字段一套取值，加值不改表结构
--   dict_type 一律与业务表字段同名，智能体拿到字段名可直接查本表，不用猜别名
-- ---------------------------------------------------------------------------
CREATE TABLE dim_dict (
  dict_type   VARCHAR(32) NOT NULL,   -- mineral_category / ore_field_scale / mining_scale
                                      -- / explore_degree / utilization_status / mineral_combo
                                      -- / mining_method / data_status / security_level
  dict_code   VARCHAR(32) NOT NULL,
  dict_name   VARCHAR(64) NOT NULL,
  sort_order  SMALLINT,
  ext         TEXT,
  PRIMARY KEY (dict_type, dict_code)
);
COMMENT ON TABLE dim_dict IS
  '通用字典与值域登记表。dict_type 与业务表字段名一一对应，智能体生成 SQL 前先查本表确认取值，避免猜枚举。'
  '入库脚本按 dict_type 比对源表用词，不匹配的进异常清单人工确认后补字典，不阻断入库。'
  '本期登记 9 类；economic_type（经济类型）、unit（计量单位）随源表取值离散、无需约束，暂不登记，需要时按同名规则增补。';

INSERT INTO dim_dict (dict_type, dict_code, dict_name, sort_order) VALUES
  ('mineral_category','能源矿产','能源矿产',1),
  ('mineral_category','金属矿产','金属矿产',2),
  ('mineral_category','非金属矿产','非金属矿产',3),
  ('mineral_category','水气矿产','水气矿产',4),
  ('ore_field_scale','大型','大型',1),
  ('ore_field_scale','中型','中型',2),
  ('ore_field_scale','小型','小型',3),
  ('ore_field_scale','小矿','小矿',4),
  ('ore_field_scale','零星','零星',5),
  ('mining_scale','大型','大型',1),
  ('mining_scale','中型','中型',2),
  ('mining_scale','小型','小型',3),
  ('explore_degree','预查','预查',1),
  ('explore_degree','普查','普查',2),
  ('explore_degree','详查','详查',3),
  ('explore_degree','勘探','勘探',4),
  ('utilization_status','未利用','未利用',1),
  ('utilization_status','正在开采','正在开采',2),
  ('utilization_status','停采','停采',3),
  ('utilization_status','闭坑','闭坑',4),
  ('mineral_combo','主要矿产','主要矿产',1),
  ('mineral_combo','共生矿产','共生矿产',2),
  ('mineral_combo','伴生矿产','伴生矿产',3),
  ('mining_method','露天开采','露天开采',1),
  ('mining_method','地下开采','地下开采',2),
  ('mining_method','露天与地下联合','露天与地下联合',3),
  ('data_status','现状','现状',1),
  ('data_status','规划','规划',2),
  ('data_status','管控','管控',3),
  ('data_status','基础地理','基础地理',4),
  ('security_level','公开','公开',1),
  ('security_level','内部','内部',2),
  ('security_level','受限','受限',3),
  ('security_level','涉密','涉密',4)
ON CONFLICT DO NOTHING;


-- ---------------------------------------------------------------------------
-- 要素代码字典（YSDM）
--   DZ/T 0226-2020 用 10 位要素代码标识每一类标准表/图层，是跨库对接的第一道凭据。
--   本表把「代码 → 标准对象 → 本库表名」一次讲清，智能体不必猜表。
-- ---------------------------------------------------------------------------
CREATE TABLE dim_ysdm (
  ysdm         VARCHAR(16) PRIMARY KEY,              -- 要素代码
  std_object   VARCHAR(64) NOT NULL,                 -- 标准对象名（拼音缩写）
  cn_name      VARCHAR(64) NOT NULL,                 -- 中文名
  table_name   VARCHAR(64),                          -- 本库对应表
  geometry_type VARCHAR(16) NOT NULL,                -- 多部件面、点或属性表
  period_type  VARCHAR(8) NOT NULL DEFAULT 'plan' CHECK (period_type IN ('status','plan')),
  remark       TEXT
);
COMMENT ON TABLE dim_ysdm IS
  '要素代码字典。代码取自 DZ/T 0226-2020 标准成果库实测值，非自造。'
  '用途：① 智能体按语义找表；② 与其他县市库、上级汇总库对接时按代码对齐；③ 判断某表能否做空间分析（geometry_type）。';

INSERT INTO dim_ysdm (ysdm, std_object, cn_name, table_name, geometry_type, period_type, remark) VALUES
  ('3003010610','KANCHQZD','重点勘查区','plan_key_explore_zone','MultiPolygon','plan','7 条'),
  ('3003010710','KANCHQK','勘查规划区块','plan_explore_block','MultiPolygon','plan','12 条'),
  ('3003020410','KAICQZD','重点开采区','plan_key_mining_zone','MultiPolygon','plan','5 条'),
  ('3003020710','KAICQK','开采规划区块','plan_mining_block','MultiPolygon','plan','60 条'),
  ('3003021110','KAICQST','砂石土集中开采区','plan_sandstone_zone','MultiPolygon','plan','16 条'),
  ('3003060110','KSKCGM','矿山最低开采规模','plan_min_mining_scale','Table','plan','19 条，属性表'),
  ('3003060210','XKCDJXZZYLZB','规划期新增资源量','plan_new_reserve','Table','plan','4 条，属性表'),
  ('3003060220','DZXKSBLZB','大中型矿山比例规划指标','plan_large_medium_ratio','Table','plan','5 条，属性表'),
  ('3003060230','LSKYZB','历史遗留矿山治理','plan_legacy_mine','Table','plan','1 条，属性表'),
  ('3003060310','KSZRZB','矿山准入标准','plan_mining_access_rule','Table','plan','1 条，属性表'),
  ('1000310106','JMDDZ','乡级行政区','map_layer','MultiPolygon','status','94 条，基础地理，无区划代码')
ON CONFLICT (ysdm) DO NOTHING;

COMMENT ON COLUMN dim_ysdm.period_type IS
  '期次类型，取值与 dim_period.period_type 一致（status 现状 / plan 规划）。'
  '原设计多一个 base 值，与期次表对不上，已去掉：基期本质就是现状。';


-- ============================================================================
-- 第二层  现状数据 fact_*
--   统一约定：period_id NOT NULL；几何允许为空
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 矿区（现状实体，带期次：跨轮次矿区会新增 / 合并 / 注销）
-- ---------------------------------------------------------------------------
CREATE TABLE fact_ore_field (
  period_id       VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  ore_field_id    VARCHAR(24) NOT NULL DEFAULT ('OF-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
                                                     -- 代理键 OF-xxxxxxxxxxxxxxxx，跨期同一矿区复用同值
  ore_field_code  VARCHAR(32),                       -- 源表矿区编号，如 341802013；226 行中有 6 行为空，待业主补充
  ore_field_name  VARCHAR(128) NOT NULL,
  admin_region    VARCHAR(12) REFERENCES dim_admin_region(region_code),
  location_desc   TEXT,
  geom            geometry(MultiPolygon, 4490),
  created_at      TIMESTAMP NOT NULL DEFAULT now(),
  PRIMARY KEY (period_id, ore_field_id)
);
COMMENT ON TABLE fact_ore_field IS
  '矿区实体（源：附表2 矿区基础信息）。矿区编号可能跨轮次复用，故主键带期次。'
  'geom 可为空：源表仅部分矿区有坐标串，解析失败不阻断入库。'
  '主键 ore_field_id 是系统生成的代理键，与源编号无关：附表2 共 226 行，其中 6 行矿区内无编号，'
  '用代理键可先行入库，编号由业主补充后回填 ore_field_code，不改主键、不牵动矿区-矿产明细的外键。';
COMMENT ON COLUMN fact_ore_field.ore_field_id IS
  '代理键，格式 OF-加16位十六进制，由列默认值生成；同一矿区跨期沿用同一个值。';
COMMENT ON COLUMN fact_ore_field.ore_field_code IS
  '源表矿区编号原值，可为空，业主补充后回填。入库脚本按它去重与判同，再落到已生成的代理键上。';
CREATE UNIQUE INDEX ux_of_code ON fact_ore_field(period_id, ore_field_code)
  WHERE ore_field_code IS NOT NULL;
CREATE INDEX idx_of_geom  ON fact_ore_field USING GIST(geom);
CREATE INDEX idx_of_name  ON fact_ore_field USING GIN(ore_field_name gin_trgm_ops);


-- ---------------------------------------------------------------------------
-- 附表1  主要矿产资源储量表（按矿种汇总）
-- ---------------------------------------------------------------------------
CREATE TABLE fact_mineral_reserve (
  id                    VARCHAR(24) PRIMARY KEY DEFAULT ('ID-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
  period_id             VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  mineral_id            VARCHAR(32) NOT NULL REFERENCES dim_mineral(mineral_id),
  ore_field_total       INTEGER,                     -- 矿区总数
  scale_large           INTEGER,
  scale_medium          INTEGER,
  scale_small           INTEGER,
  scale_tiny            INTEGER,                     -- 小矿
  scale_scatter         INTEGER,                     -- 零星
  reserve_unit          VARCHAR(32),
  retained_reserves     NUMERIC(18,4),               -- 保有资源量
  cumulative_reserves   NUMERIC(18,4),               -- 累计查明资源量
  created_at            TIMESTAMP NOT NULL DEFAULT now(),
  updated_at            TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (period_id, mineral_id)
);
COMMENT ON TABLE fact_mineral_reserve IS
  '矿产资源储量表（源：现状附表1）。一矿种一行，支撑场景②储量变化与基期对比。'
  '矿种名称在源表中是行标题而非列，入库时须拆解为 mineral_id。';


-- ---------------------------------------------------------------------------
-- 附表2  矿区-矿产明细
--   源表一矿区多矿种，单元格内用「换行 + 斜杠」并行打包（220 个矿区编号 / 226 行），
--   入库必须拆行：一行 = 一个矿区的 + 一个矿种
-- ---------------------------------------------------------------------------
CREATE TABLE fact_ore_field_mineral (
  id                  VARCHAR(24) PRIMARY KEY DEFAULT ('ID-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
  period_id           VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  ore_field_id        VARCHAR(32) NOT NULL,
  mineral_id          VARCHAR(32) NOT NULL REFERENCES dim_mineral(mineral_id),
  mineral_combo       VARCHAR(16) NOT NULL DEFAULT '主要矿产',   -- 主要/共生/伴生矿产
  explore_degree      VARCHAR(16),                   -- 预查/普查/详查/勘探
  utilization_status  VARCHAR(16),                   -- 未利用/正在开采/停采/闭坑
  ore_field_scale     VARCHAR(16),                   -- 大型/中型/小型/小矿/零星
  grade_unit          VARCHAR(32),                   -- 组分及品位单位
  avg_grade           NUMERIC(18,4),                 -- 平均品位（可数值化时）
  avg_grade_raw       VARCHAR(64),                   -- 平均品位原值（区间、带符号时保留，勿丢）
  reserve_unit        VARCHAR(32),
  retained_reserves   NUMERIC(18,4),
  cumulative_reserves NUMERIC(18,4),
  created_at          TIMESTAMP NOT NULL DEFAULT now(),
  updated_at          TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (period_id, ore_field_id, mineral_id, mineral_combo),
  FOREIGN KEY (period_id, ore_field_id) REFERENCES fact_ore_field(period_id, ore_field_id)
);
COMMENT ON TABLE fact_ore_field_mineral IS
  '矿区-矿产明细（源：现状附表2）。多矿种已拆行，是本库粒度最细的储量数据表，智能体问「某矿区有哪些矿种」查这里。'
  'mineral_combo 默认「主要矿产」而非留空：留空会破坏唯一约束（NULL 不参与去重），重跑即翻倍。';
CREATE INDEX idx_ofm_orefield ON fact_ore_field_mineral(period_id, ore_field_id);
CREATE INDEX idx_ofm_mineral  ON fact_ore_field_mineral(period_id, mineral_id);


-- ---------------------------------------------------------------------------
-- 附表3  主要矿产开发利用现状
--   stat_year 预留年度序列：0 = 该期次汇总值；>0 = 具体年度值
-- ---------------------------------------------------------------------------
CREATE TABLE fact_mineral_develop (
  id                   VARCHAR(24) PRIMARY KEY DEFAULT ('ID-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
  period_id            VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  mineral_id           VARCHAR(32) NOT NULL REFERENCES dim_mineral(mineral_id),
  stat_year            SMALLINT NOT NULL DEFAULT 0,  -- 0=期次汇总；2020/2021…=年度值
  mine_count_large     INTEGER,
  mine_count_medium    INTEGER,
  mine_count_small     INTEGER,
  mine_count_total     INTEGER,
  output_unit          VARCHAR(32),
  output_large         NUMERIC(18,4),
  output_medium        NUMERIC(18,4),
  output_small         NUMERIC(18,4),
  output_total         NUMERIC(18,4),
  output_value_large   NUMERIC(18,4),
  output_value_medium  NUMERIC(18,4),
  output_value_small   NUMERIC(18,4),
  output_value_total   NUMERIC(18,4),
  created_at           TIMESTAMP NOT NULL DEFAULT now(),
  updated_at           TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (period_id, mineral_id, stat_year)
);
COMMENT ON TABLE fact_mineral_develop IS
  '矿产资源开发利用现状（源：现状附表3）。矿山数与产量/产值按大中小三档展开。'
  'stat_year=0 表示期次汇总值；填具体年份即形成年度时序，支撑场景③年开采总量趋势，无需新增表。';


-- ---------------------------------------------------------------------------
-- 附表4  主要矿山（主键带期次：同一矿山在两期都存在）
-- ---------------------------------------------------------------------------
CREATE TABLE fact_mine (
  period_id              VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  mine_id                VARCHAR(24) NOT NULL DEFAULT ('MN-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
                                                     -- 代理键 MN-xxxxxxxxxxxxxxxx，跨期同一矿山复用同值
  mine_code              VARCHAR(32),                -- 源表矿山编号，如 3418020078；149 行中有 17 行为空，待业主补充
  mine_name              VARCHAR(128) NOT NULL,
  mineral_id             VARCHAR(32) REFERENCES dim_mineral(mineral_id),  -- 主矿种，多矿种见明细表
  admin_region           VARCHAR(12) REFERENCES dim_admin_region(region_code),
  reserve_unit           VARCHAR(32),
  reserves               NUMERIC(18,4),
  develop_status         VARCHAR(16),
  mining_scale           VARCHAR(16),
  mining_method          VARCHAR(16),                -- 露天开采/地下开采
  output_unit            VARCHAR(32),
  design_capacity        NUMERIC(18,4),
  output                 NUMERIC(18,4),
  output_value           NUMERIC(18,4),
  mining_recovery_rate   NUMERIC(6,2),               -- 采矿回采率 %
  dressing_recovery_rate NUMERIC(6,2),               -- 选矿回收率 %
  comprehensive_value    NUMERIC(18,4),
  geom                   geometry(Point, 4490),
  created_at             TIMESTAMP NOT NULL DEFAULT now(),
  updated_at             TIMESTAMP NOT NULL DEFAULT now(),
  PRIMARY KEY (period_id, mine_id)
);
COMMENT ON TABLE fact_mine IS
  '主要矿山（源：现状附表4）。一矿一行，多矿种关系见 fact_mine_mineral。'
  'geom 为点要素（矿山位置），可为空。跨期对比同一 mine_id 即得矿山存续变化。'
  '主键 mine_id 是系统生成的代理键，与源编号无关：附表4 共 149 行，其中 17 行矿山编号为空（且非合并单元格），'
  '用代理键可先行入库，编号由业主补充后回填 mine_code，不改主键、不牵动矿山-矿种关系。';
COMMENT ON COLUMN fact_mine.mine_id IS
  '代理键，格式 MN-加16位十六进制，由列默认值生成；同一矿山跨期沿用同一个值。';
COMMENT ON COLUMN fact_mine.mine_code IS
  '源表矿山编号原值，可为空，业主补充后回填。入库脚本按它去重与判同，再落到已生成的代理键上。'
  '源表中该列形如 3418020078.0，入库前须去掉小数尾缀，否则带尾缀与不带尾缀会被当成两个矿山。';
CREATE UNIQUE INDEX ux_mine_code ON fact_mine(period_id, mine_code)
  WHERE mine_code IS NOT NULL;
CREATE INDEX idx_mine_geom ON fact_mine USING GIST(geom);
CREATE INDEX idx_mine_name ON fact_mine USING GIN(mine_name gin_trgm_ops);
CREATE INDEX idx_mine_mineral ON fact_mine(period_id, mineral_id);


-- ---------------------------------------------------------------------------
-- 附表4 派生  一矿多矿种关系
-- ---------------------------------------------------------------------------
CREATE TABLE fact_mine_mineral (
  period_id  VARCHAR(16) NOT NULL,
  mine_id    VARCHAR(32) NOT NULL,
  mineral_id VARCHAR(32) NOT NULL REFERENCES dim_mineral(mineral_id),
  mineral_combo VARCHAR(16) NOT NULL DEFAULT '主要矿产',
  PRIMARY KEY (period_id, mine_id, mineral_id),
  FOREIGN KEY (period_id, mine_id) REFERENCES fact_mine(period_id, mine_id) ON DELETE CASCADE
);
COMMENT ON TABLE fact_mine_mineral IS
  '矿山与矿种多对多（源：现状附表4 一矿多矿种拆解）。智能体问「同一矿山采几个矿种」查这里。'
  '源表一矿多矿种是拆行的，同一矿山若在某几行缺编号，须按矿山名称归并到同一 mine_id，'
  '否则会拆成多个「矿山」，多矿种统计随之翻倍。';


-- ---------------------------------------------------------------------------
-- 附表5  探矿权（主键带期次：许可证号跨期延续登记）
-- ---------------------------------------------------------------------------
CREATE TABLE fact_explore_right (
  period_id       VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  right_id        VARCHAR(24) NOT NULL DEFAULT ('ER-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
                                                     -- 代理键 ER-xxxxxxxxxxxxxxxx，跨期延续登记复用同值
  right_code      VARCHAR(64),                       -- 勘查许可证号（源表证号，可空，待补）
  holder          VARCHAR(128),                      -- 探矿权人
  project_name    VARCHAR(256),                      -- 项目名称
  explore_degree  VARCHAR(16),
  mineral_id      VARCHAR(32) REFERENCES dim_mineral(mineral_id),
  regist_area_km2 NUMERIC(12,4),
  map_sheet_no    VARCHAR(32),                       -- 图幅号
  valid_from      DATE,
  valid_to        DATE,
  right_status    VARCHAR(16),                       -- 有效/延续/注销/过期
  geom            geometry(MultiPolygon, 4490),
  created_at      TIMESTAMP NOT NULL DEFAULT now(),
  updated_at      TIMESTAMP NOT NULL DEFAULT now(),
  PRIMARY KEY (period_id, right_id)
);
COMMENT ON TABLE fact_explore_right IS
  '探矿权（源：现状附表5）。有效期在源表内以换行分隔（起～止），入库须拆为 valid_from / valid_to 两列。'
  '同一许可证号在两期都存在，故主键必须带 period_id，否则第二期入库直接主键冲突。'
  '主键 right_id 为代理键，许可证号存 right_code：证号会换发、会缺失，不适合做键；跨期对比按 right_code 或权利人加项目名称判同。'
  '某期证号缺失时，入库脚本按「探矿权人 + 项目名称 + 矿种」判同后复用同一 right_id，避免同一矿权被拆成两条。';
COMMENT ON COLUMN fact_explore_right.right_code IS
  '勘查许可证号源值，可为空，业主补充后回填；同一期内部分唯一，不承担主键职责。';
CREATE UNIQUE INDEX ux_er_code ON fact_explore_right(period_id, right_code)
  WHERE right_code IS NOT NULL;
CREATE INDEX idx_er_geom    ON fact_explore_right USING GIST(geom);
CREATE INDEX idx_er_mineral ON fact_explore_right(period_id, mineral_id);


-- ---------------------------------------------------------------------------
-- 附表6  采矿权
-- ---------------------------------------------------------------------------
CREATE TABLE fact_mining_right (
  period_id          VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  right_id           VARCHAR(24) NOT NULL DEFAULT ('MR-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
                                                     -- 代理键 MR-xxxxxxxxxxxxxxxx，跨期延续登记复用同值
  right_code         VARCHAR(64),                    -- 采矿许可证号（源表证号，可空，待补）
  holder             VARCHAR(128),
  mine_name          VARCHAR(128),
  economic_type      VARCHAR(32),                    -- 经济类型
  mineral_id         VARCHAR(32) REFERENCES dim_mineral(mineral_id),
  mining_method      VARCHAR(16),                    -- 露天/地下
  reserve_unit       VARCHAR(32),
  regist_reserves    NUMERIC(18,4),                  -- 登记储量
  production_scale   VARCHAR(16),                    -- 生产规模
  regist_area_km2    NUMERIC(12,4),
  valid_from         DATE,
  valid_to           DATE,
  right_status       VARCHAR(16),
  geom               geometry(MultiPolygon, 4490),
  created_at         TIMESTAMP NOT NULL DEFAULT now(),
  updated_at         TIMESTAMP NOT NULL DEFAULT now(),
  PRIMARY KEY (period_id, right_id)
);
COMMENT ON TABLE fact_mining_right IS
  '采矿权（源：现状附表6）。与探矿权结构相近但字段不同，保持分表：合并会让两类矿权的专有字段大量留空，智能体易误取。'
  '主键 right_id 为代理键，许可证号存 right_code；某期证号缺失时按「采矿权人 + 矿山名称」判同后复用同一 right_id。';
COMMENT ON COLUMN fact_mining_right.right_code IS
  '采矿许可证号源值，可为空，业主补充后回填；同一期内部分唯一，不承担主键职责。';
CREATE UNIQUE INDEX ux_mr_code ON fact_mining_right(period_id, right_code)
  WHERE right_code IS NOT NULL;
CREATE INDEX idx_mr_geom    ON fact_mining_right USING GIST(geom);
CREATE INDEX idx_mr_mineral ON fact_mining_right(period_id, mineral_id);


-- ============================================================================
-- 第三层  规划成果 plan_*
--
--   五张空间表共有列严格同名，便于按固定列序 UNION —— 这是无视图方案的关键约定：
--     period_id / zone_id / zone_code / zone_name / admin_regions / area_km2 /
--     main_minerals / geom
--   zone_id 为代理键（ZN- 前缀），zone_code 存源分区编号、可空待补：
--     规划成果编号在不同轮次由不同作业队伍编码，跨期可能重号、也可能补编，不宜做键。
--   area_km2 = 源报表填报面积（口径以此为准，与已发布规划文本一致）
--   几何面积按 ST_Area(ST_Transform(geom, 4547)) / 1000000 现算，
--   与填报值差异 >5% 的要素进人工确认清单；不用实算值覆盖填报值。
-- ============================================================================

-- 成果附表1  重点勘查区 KZ
CREATE TABLE plan_key_explore_zone (
  period_id             VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  zone_id               VARCHAR(24) NOT NULL DEFAULT ('ZN-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
                                                     -- 代理键 ZN-xxxxxxxxxxxxxxxx，跨期同一区块复用同值
  zone_code             VARCHAR(16),                 -- 分区编号 FQBH 源值，如 KZ34180000002，可空待补
  zone_name             VARCHAR(128) NOT NULL,       -- 分区名称 FQMC
  admin_regions         VARCHAR(256),                -- 所在行政区 SZXZQ
  area_km2              NUMERIC(12,4),               -- 分区面积 FQMJ
  main_mineral_codes    VARCHAR(256),                -- 主要矿产代码 ZYKCDM（可多值，逗号分隔）
  main_minerals         VARCHAR(256),                -- 主要矿产名称 ZYKCMC
  geom                  geometry(MultiPolygon, 4490),
  gdzb                  TEXT,                        -- 拐点坐标串 GDZB：法定几何表达，原样保留
  existing_rights_count INTEGER,                     -- 已设探矿权总数 YSTKQZS
  planned_rights_count  INTEGER,                     -- 拟设探矿权总数 NSTKQZS
  ghbzjb                VARCHAR(12),                 -- 规划编制级别 GHBZJB，宣城为 341800
  bsm                   BIGINT,                      -- 标识码 BSM
  ysdm                  VARCHAR(16) DEFAULT '3003010610',   -- 要素代码 YSDM
  remark                TEXT,
  created_at            TIMESTAMP NOT NULL DEFAULT now(),
  updated_at            TIMESTAMP NOT NULL DEFAULT now(),
  PRIMARY KEY (period_id, zone_id)
);
COMMENT ON TABLE plan_key_explore_zone IS
  '重点勘查区（标准图层 KANCHQZD，YSDM=3003010610，7 条 / 15 字段）。规划类空间分区，挂 period_id 可随轮次新增。'
  'zone_id 为代理键，zone_code 存源分区编号 FQBH，可空待补；两者不可互换。'
  'gdzb 存原始拐点坐标串：报批以坐标串为准，geom 仅供分析用，两者须同时入库。';
CREATE UNIQUE INDEX ux_pez_code ON plan_key_explore_zone(period_id, zone_code)
  WHERE zone_code IS NOT NULL;
CREATE INDEX idx_pez_geom ON plan_key_explore_zone USING GIST(geom);
CREATE INDEX idx_pez_name ON plan_key_explore_zone USING GIN(zone_name gin_trgm_ops);


-- 成果附表2  勘查规划区块 KQ
CREATE TABLE plan_explore_block (
  period_id        VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  zone_id          VARCHAR(24) NOT NULL DEFAULT ('ZN-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
                                                     -- 代理键 ZN-xxxxxxxxxxxxxxxx，跨期同一区块复用同值
  zone_code        VARCHAR(16),                      -- 区块编号 QKBH 源值，如 KQ34180000009，可空待补
  zone_name        VARCHAR(128) NOT NULL,            -- 区块名称 QKMC
  admin_regions    VARCHAR(256),                     -- 所在行政区
  area_km2         NUMERIC(12,4),                    -- 区块面积 QKMJ
  main_mineral_codes    VARCHAR(256),                   -- 矿种代码 KZDM
  main_minerals    VARCHAR(256),                     -- 矿种名称 KZMC
  other_mineral_codes VARCHAR(256),                  -- 其他矿种代码 QTKZDM
  other_minerals   VARCHAR(256),                     -- 其他矿种名称 QTKZMC
  geom             geometry(MultiPolygon, 4490),
  gdzb             TEXT,                             -- 拐点坐标串 GDZB
  current_degree   VARCHAR(16),                      -- 现状勘查程度 KCCD
  planned_stage    VARCHAR(16),                      -- 拟设勘查阶段 NSKCJD
  release_schedule VARCHAR(32),                      -- 投放时序 TFSX
  ghbzjb           VARCHAR(12),                      -- 规划编制级别 GHBZJB
  bsm              BIGINT,                           -- 标识码 BSM
  ysdm             VARCHAR(16) DEFAULT '3003010710', -- 要素代码 YSDM
  remark           TEXT,
  created_at       TIMESTAMP NOT NULL DEFAULT now(),
  updated_at       TIMESTAMP NOT NULL DEFAULT now(),
  PRIMARY KEY (period_id, zone_id)
);
COMMENT ON TABLE plan_explore_block IS
  '勘查规划区块（标准图层 KANCHQK，YSDM=3003010710，12 条 / 17 字段）。'
  'zone_id 为代理键，zone_code 存源区块编号 QKBH，可空待补。'
  '矿种分主矿种与其他矿种两组，不可只存主矿种 —— 源表有 QTKZDM 一列承载多矿种。';
CREATE UNIQUE INDEX ux_peb_code ON plan_explore_block(period_id, zone_code)
  WHERE zone_code IS NOT NULL;
CREATE INDEX idx_peb_geom ON plan_explore_block USING GIST(geom);
CREATE INDEX idx_peb_name ON plan_explore_block USING GIN(zone_name gin_trgm_ops);


-- 成果附表3  重点开采区 CZ
CREATE TABLE plan_key_mining_zone (
  period_id             VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  zone_id               VARCHAR(24) NOT NULL DEFAULT ('ZN-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
                                                     -- 代理键 ZN-xxxxxxxxxxxxxxxx，跨期同一区块复用同值
  zone_code             VARCHAR(16),                 -- 分区编号 FQBH 源值，如 CZ34180000004，可空待补
  zone_name             VARCHAR(128) NOT NULL,       -- 分区名称 FQMC
  admin_regions         VARCHAR(256),                -- 所在行政区 SZXZQ
  area_km2              NUMERIC(12,4),               -- 分区面积 FQMJ
  main_mineral_codes    VARCHAR(256),                -- 主要矿产代码 ZYKCDM
  main_minerals         VARCHAR(256),                -- 主要矿产名称 ZYKCMC
  geom                  geometry(MultiPolygon, 4490),
  gdzb                  TEXT,                        -- 拐点坐标串 GDZB
  reserve_unit          VARCHAR(32),                 -- 资源量单位 ZYLDW
  reserve_measured      NUMERIC(18,4),               -- 探明资源量 ZYKCTMZYL
  reserve_controlled    NUMERIC(18,4),               -- 控制资源量 ZYKCKZZYL
  reserve_inferred      NUMERIC(18,4),               -- 推断资源量 ZYKCTDZYL
  reserve_total         NUMERIC(18,4),               -- 资源量合计 ZYKCZYL
  reserves_raw          VARCHAR(256),                -- 多矿种资源量原值：一区多矿时上述四列无法单值化，原值留此
  existing_rights_count INTEGER,                     -- 已设采矿权总数 YSCKQZS
  planned_rights_count  INTEGER,                     -- 拟设采矿权总数 NSCKQZS
  ghbzjb                VARCHAR(12),                 -- 规划编制级别 GHBZJB
  bsm                   BIGINT,                      -- 标识码 BSM
  ysdm                  VARCHAR(16) DEFAULT '3003020410',  -- 要素代码 YSDM
  remark                TEXT,
  created_at            TIMESTAMP NOT NULL DEFAULT now(),
  updated_at            TIMESTAMP NOT NULL DEFAULT now(),
  PRIMARY KEY (period_id, zone_id)
);
COMMENT ON TABLE plan_key_mining_zone IS
  '重点开采区（标准图层 KAICQZD，YSDM=3003020410，5 条 / 19 字段）。'
  'zone_id 为代理键，zone_code 存源分区编号 FQBH，可空待补。'
  '资源量按探明/控制/推断/合计四级分列，不得只存合计 —— 三级资源量是储量分类管理的基本口径。'
  '一区多矿种时四级列留空、原值进 reserves_raw，智能体引用数值前须确认口径，不可把空值当 0。';
CREATE INDEX idx_pmz_geom ON plan_key_mining_zone USING GIST(geom);
CREATE INDEX idx_pmz_name ON plan_key_mining_zone USING GIN(zone_name gin_trgm_ops);


-- 成果附表4  砂石土集中开采区 CS
CREATE TABLE plan_sandstone_zone (
  period_id        VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  zone_id          VARCHAR(24) NOT NULL DEFAULT ('ZN-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
                                                     -- 代理键 ZN-xxxxxxxxxxxxxxxx，跨期同一区块复用同值
  zone_code        VARCHAR(16),                      -- 矿区编号 KCQBH 源值，如 CS34180000009，可空待补
  zone_name        VARCHAR(128) NOT NULL,            -- 矿区名称 KCQMC
  admin_regions    VARCHAR(256),                     -- 所在行政区 SZXZQ
  area_km2         NUMERIC(12,4),                    -- 矿区面积 KCQMJ
  main_mineral_codes    VARCHAR(256),                   -- 主要矿产代码 ZYKCDM
  main_minerals    VARCHAR(256),                     -- 主要矿产名称 ZYKCMC
  geom             geometry(MultiPolygon, 4490),
  gdzb             TEXT,                             -- 拐点坐标串 GDZB
  planned_rights_count INTEGER,                      -- 拟设采矿权总数 NSCKQZS
  min_mining_scale VARCHAR(128),                     -- 最低开采规模 ZDKCGM
  env_measures     TEXT,                             -- 环境保护与治理措施 HBYZLCS
  ghbzjb           VARCHAR(12),                      -- 规划编制级别 GHBZJB
  bsm              BIGINT,                           -- 标识码 BSM
  ysdm             VARCHAR(16) DEFAULT '3003021110', -- 要素代码 YSDM
  remark           TEXT,
  created_at       TIMESTAMP NOT NULL DEFAULT now(),
  updated_at       TIMESTAMP NOT NULL DEFAULT now(),
  PRIMARY KEY (period_id, zone_id)
);
COMMENT ON TABLE plan_sandstone_zone IS
  '砂石土集中开采区（标准图层 KAICQST，YSDM=3003021110，16 条 / 16 字段）。'
  'zone_id 为代理键，zone_code 存源矿区编号 KCQBH，可空待补。'
  '普通建筑材料用砂石土矿，管理口径与金属矿不同：最低开采规模、环保治理措施是本表专有约束，单独成表。';
CREATE UNIQUE INDEX ux_psz_code ON plan_sandstone_zone(period_id, zone_code)
  WHERE zone_code IS NOT NULL;
CREATE INDEX idx_psz_geom ON plan_sandstone_zone USING GIST(geom);
CREATE INDEX idx_psz_name ON plan_sandstone_zone USING GIN(zone_name gin_trgm_ops);


-- 成果附表5  开采规划区块 CQ
CREATE TABLE plan_mining_block (
  period_id          VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  zone_id            VARCHAR(24) NOT NULL DEFAULT ('ZN-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
                                                     -- 代理键 ZN-xxxxxxxxxxxxxxxx，跨期同一区块复用同值
  zone_code          VARCHAR(16),                    -- 区块编号 QKBH 源值，如 CQ34180000013，可空待补
  zone_name          VARCHAR(128) NOT NULL,          -- 区块名称 QKMC
  admin_regions      VARCHAR(256),                   -- 所在行政区
  area_km2           NUMERIC(12,4),                  -- 区块面积 QKMJ
  main_mineral_codes    VARCHAR(256),                   -- 矿种代码 KZDM
  main_minerals      VARCHAR(256),                   -- 矿种名称 KZMC
  comprehensive_use_codes VARCHAR(256),              -- 综合利用矿种代码 ZLKZKZDM
  comprehensive_use_minerals VARCHAR(256),           -- 综合利用矿种名称 ZLKZKZMC
  geom               geometry(MultiPolygon, 4490),
  gdzb               TEXT,                           -- 拐点坐标串 GDZB
  reserve_unit       VARCHAR(32),                    -- 资源量单位 ZYLDW
  reserve_measured   NUMERIC(18,4),                  -- 探明资源量 TMZYL
  reserve_controlled NUMERIC(18,4),                  -- 控制资源量 KZZYL
  reserve_inferred   NUMERIC(18,4),                  -- 推断资源量 TDZYL
  reserve_total      NUMERIC(18,4),                  -- 资源量合计 ZYL
  reserves_raw       VARCHAR(256),                   -- 多矿种资源量原值（无法单值化时）
  other_mineral_reserves_raw TEXT,                   -- 其他矿种四级资源量原值（QTKZJ* 四列合并留存）
  release_schedule   VARCHAR(32),                    -- 投放时序 TFSX
  ghbzjb             VARCHAR(12),                    -- 规划编制级别 GHBZJB
  bsm                BIGINT,                         -- 标识码 BSM
  ysdm               VARCHAR(16) DEFAULT '3003020710', -- 要素代码 YSDM
  remark             TEXT,
  created_at         TIMESTAMP NOT NULL DEFAULT now(),
  updated_at         TIMESTAMP NOT NULL DEFAULT now(),
  PRIMARY KEY (period_id, zone_id)
);
COMMENT ON TABLE plan_mining_block IS
  '开采规划区块（标准图层 KAICQK，YSDM=3003020710，60 条 / 24 字段）。矿业权投放的空间载体，'
  'zone_id 为代理键，zone_code 存源区块编号 QKBH，可空待补。'
  '合规审查时与三区三线叠加研判是否可投放。资源量与重点开采区一样按四级分列；'
  '本表另有「其他矿种」四列（QTKZJ*），源表以文本承载，合并存 other_mineral_reserves_raw，不强行拆行。';
CREATE UNIQUE INDEX ux_pmb_code ON plan_mining_block(period_id, zone_code)
  WHERE zone_code IS NOT NULL;
CREATE INDEX idx_pmb_geom ON plan_mining_block USING GIST(geom);
CREATE INDEX idx_pmb_name ON plan_mining_block USING GIN(zone_name gin_trgm_ops);


-- 成果附表6  最低开采规模（属性表，无几何，不参与空间分析）
CREATE TABLE plan_min_mining_scale (
  id           VARCHAR(24) PRIMARY KEY DEFAULT ('ID-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
  period_id    VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  mineral_id   VARCHAR(32) REFERENCES dim_mineral(mineral_id),
  mineral_code VARCHAR(16),                          -- 矿产代码 KCDM
  mineral_name VARCHAR(64) NOT NULL,                 -- 矿产名称 KCMC
  scale_unit   VARCHAR(32),                          -- 开采规模单位 KCGMDW，如 万吨/年
  min_large_medium NUMERIC(12,4),                    -- 大中型矿山最低开采规模 DXKSKCGM
  min_medium   NUMERIC(12,4),                        -- 中型矿山最低开采规模 ZXKSKCGM
  min_small    NUMERIC(12,4),                        -- 小型矿山最低开采规模 XXKSKCGM
  policy_note  TEXT,                                 -- 政策导向原文 BZ，如 鼓励开采，设计服务年限10年以上
  policy_type  VARCHAR(16),                          -- 由 policy_note 解析：鼓励/限制/禁止/无
  ghbzjb       VARCHAR(12),                          -- 规划编制级别 GHBZJB
  bsm          BIGINT,                               -- 标识码 BSM
  ysdm         VARCHAR(16) DEFAULT '3003060110',     -- 要素代码 YSDM
  remark       TEXT,
  created_at   TIMESTAMP NOT NULL DEFAULT now(),
  updated_at   TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (period_id, mineral_name)
);
COMMENT ON TABLE plan_min_mining_scale IS
  '最低开采规模（标准表 KSKCGM，YSDM=3003060110，19 条 / 11 字段）。非空间属性表，禁止进入空间分析链路。'
  '规模按大中型/中型/小型三档，注意「大中型」是独立一档而非大型与中型的合并值 —— 源表如此，不可自行拆分。'
  'policy_note 存源表 BZ 原文（含鼓励/限制开采导向），policy_type 是入库脚本解析结果，供智能体直接筛选。';


-- ---------------------------------------------------------------------------
-- 矿山准入标准（标准表 KSZRZB，YSDM=3003060310，1 条 / 11 字段）
--   源表限制矿种、禁止矿种为逗号分隔多值（11009,32014），拆到明细表，本表只存通用要求
-- ---------------------------------------------------------------------------
CREATE TABLE plan_mining_access_rule (
  id                        VARCHAR(24) PRIMARY KEY DEFAULT ('ID-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
  period_id                 VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  legal_requirement         TEXT,                    -- 法律法规要求 FLFGYQ
  mining_access_requirement TEXT,                    -- 采矿准入要求 CYZCYQ
  access_condition          TEXT,                    -- 准入条件 ZRTJ
  ghbzjb                    VARCHAR(12),             -- 规划编制级别 GHBZJB
  bsm                       BIGINT,                  -- 标识码 BSM
  ysdm                      VARCHAR(16) DEFAULT '3003060310',
  remark                    TEXT,
  created_at                TIMESTAMP NOT NULL DEFAULT now(),
  updated_at                TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (period_id)
);
COMMENT ON TABLE plan_mining_access_rule IS
  '矿山准入标准（标准表 KSZRZB）。一个规划期一条通用准入要求：法律法规依据、采矿准入要求、准入条件。'
  '限禁矿种不放本表，见 plan_mineral_restriction —— 源表用逗号分隔多值，必须拆行才能被智能体按矿种检索。';

-- ---------------------------------------------------------------------------
-- 限制/禁止开采矿种明细（由 KSZRZB 的 XZKZDM / JZKZDM 拆解）
-- ---------------------------------------------------------------------------
CREATE TABLE plan_mineral_restriction (
  id            VARCHAR(24) PRIMARY KEY DEFAULT ('ID-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
  period_id     VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  restrict_type VARCHAR(8) NOT NULL CHECK (restrict_type IN ('限制','禁止')),
  mineral_code  VARCHAR(16),                         -- 矿产代码，源表已给（11009 石煤 / 32014 钨矿 / 84412 砖瓦用粘土）
  mineral_name  VARCHAR(64) NOT NULL,
  basis         TEXT,                                -- 政策依据原文
  remark        TEXT,
  created_at    TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (period_id, restrict_type, mineral_name)
);
COMMENT ON TABLE plan_mineral_restriction IS
  '限制与禁止开采矿种（源：KSZRZB 的 XZKZDM / JZKZDM，逗号分隔多值拆行）。'
  '智能体回答「哪些矿种禁止新设采矿权」直接查本表，不必解析长文本。';
CREATE INDEX idx_pmr_type    ON plan_mineral_restriction(period_id, restrict_type);
CREATE INDEX idx_pmr_mineral ON plan_mineral_restriction(mineral_name);


-- ---------------------------------------------------------------------------
-- 大中型矿山比例规划指标（标准表 DZXKSBLZB，YSDM=3003060220，5 条 / 11 字段）
-- ---------------------------------------------------------------------------
CREATE TABLE plan_large_medium_ratio (
  id                  VARCHAR(24) PRIMARY KEY DEFAULT ('ID-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
  period_id           VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  mineral_id          VARCHAR(32) REFERENCES dim_mineral(mineral_id),
  mineral_code        VARCHAR(16),                   -- 矿产代码 KCDM
  mineral_name        VARCHAR(64) NOT NULL,          -- 矿产名称 KCMC
  large_medium_count  INTEGER,                       -- 大中型矿山数 DZXKSS
  large_medium_ratio  NUMERIC(6,2),                  -- 大中型矿山比例 % DZXKSBL
  mineral_total       NUMERIC(18,4),                 -- 矿产总量 KCZL
  total_unit          VARCHAR(32),                   -- 总量单位 KCZLDW
  ghbzjb              VARCHAR(12),
  bsm                 BIGINT,
  ysdm                VARCHAR(16) DEFAULT '3003060220',
  remark              TEXT,
  created_at          TIMESTAMP NOT NULL DEFAULT now(),
  updated_at          TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (period_id, mineral_name)
);
COMMENT ON TABLE plan_large_medium_ratio IS
  '大中型矿山比例规划指标（标准表 DZXKSBLZB）。结构化调整的核心考核指标，一个矿种一行。'
  '智能体可据此回答「规划期末铜矿大中型矿山比例目标」。';


-- ---------------------------------------------------------------------------
-- 规划期新增资源量（标准表 XKCDJXZZYLZB，YSDM=3003060210，4 条 / 13 字段）
-- ---------------------------------------------------------------------------
CREATE TABLE plan_new_reserve (
  id                       VARCHAR(24) PRIMARY KEY DEFAULT ('ID-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
  period_id                VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  mineral_id               VARCHAR(32) REFERENCES dim_mineral(mineral_id),
  mineral_code             VARCHAR(16),              -- 矿产代码 KCDM
  mineral_name             VARCHAR(64) NOT NULL,     -- 矿产名称 KCMC
  unit                     VARCHAR(32),              -- 资源量单位 ZYLDW，如 铅 吨 / WO3 吨
  new_measured             NUMERIC(18,4),            -- 新增探明资源量 XZTMZYL
  new_controlled           NUMERIC(18,4),            -- 新增控制资源量 XZKZZYL
  new_inferred             NUMERIC(18,4),            -- 新增推断资源量 XZTDZYL
  new_total                NUMERIC(18,4),            -- 新增资源量合计 XZZYL
  new_large_medium_deposits INTEGER,                 -- 新发现大中型矿产地数 XFXDZXKCD
  ghbzjb                   VARCHAR(12),
  bsm                      BIGINT,
  ysdm                     VARCHAR(16) DEFAULT '3003060210',
  remark                   TEXT,
  created_at               TIMESTAMP NOT NULL DEFAULT now(),
  updated_at               TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (period_id, mineral_name)
);
COMMENT ON TABLE plan_new_reserve IS
  '规划期新增资源量（标准表 XKCDJXZZYLZB）。按探明/控制/推断三级分列，是找矿突破的量化目标。'
  '注意单位随矿种变化（铅用吨、钨用 WO3 吨），引用数值前必须带 unit，不可跨矿种直接求和。';


-- ---------------------------------------------------------------------------
-- 历史遗留矿山治理（标准表 LSKYZB，YSDM=3003060230，1 条 / 9 字段）
-- ---------------------------------------------------------------------------
CREATE TABLE plan_legacy_mine (
  id                 VARCHAR(24) PRIMARY KEY DEFAULT ('ID-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16))),
  period_id          VARCHAR(16) NOT NULL REFERENCES dim_period(period_id),
  mine_count         INTEGER,                        -- 矿山数量 KSSL
  legacy_mine_count  INTEGER,                        -- 历史遗留矿山数量 LSKSSL
  legacy_mine_ratio  NUMERIC(6,2),                   -- 历史遗留矿山比例 % LSKSBL
  deposit_count      INTEGER,                        -- 矿产地（问题）数量 KCDCBSL，源表仅 1，口径待与标准核对
  ghbzjb             VARCHAR(12),
  bsm                BIGINT,
  ysdm               VARCHAR(16) DEFAULT '3003060230',
  remark             TEXT,
  created_at         TIMESTAMP NOT NULL DEFAULT now(),
  updated_at         TIMESTAMP NOT NULL DEFAULT now(),
  UNIQUE (period_id)
);
COMMENT ON TABLE plan_legacy_mine IS
  '历史遗留矿山治理任务（标准表 LSKYZB）。一个规划期一条：矿山总数、历史遗留矿山数与占比。'
  '源表面积/比例字段存在空值（LSKSSL 为 NULL），入库不得当 0 处理，空值语义是「未统计」而非「数量为零」。';


-- ============================================================================
-- 第四层  空间图层 map_layer
--   一张表同时承担两件事：
--     ① 图层目录与发布信息（智能体选层入口：现状还是规划、属哪一期、能否做空间分析）
--     ② 管控边界的落地存储（三区三线、自然保护地等，其要素不属于规划成果，单独成层）
--   图层与数据源的绑定、字段结构、样式由 MXD / MapX / GeoServer 发布端与 OGC 运行时提供，不入库
-- ============================================================================

CREATE TABLE map_layer (
  layer_code       VARCHAR(64) PRIMARY KEY,      -- 业务编码，如 PLAN_KEZ_FYP14 / CTRL_REDLINE
  layer_name       VARCHAR(128) NOT NULL,        -- 图层中文名，如 重点勘查区 / 生态保护红线
  data_status      VARCHAR(16) NOT NULL          -- 一级分类，与 dim_dict.data_status 取值一致
                   CHECK (data_status IN ('现状','规划','管控','基础地理')),
  plan_element     VARCHAR(64) NOT NULL,         -- 二级分类：重点勘查区 / 采矿权 / 生态保护红线…
  ysdm             VARCHAR(16) REFERENCES dim_ysdm(ysdm),  -- 要素代码，与标准成果库对接用
  period_id        VARCHAR(16) REFERENCES dim_period(period_id),  -- 规划与现状类必填，管控类为空
  period_label     VARCHAR(64),                  -- 期次中文，直接给智能体输出用
  geometry_type    VARCHAR(16) NOT NULL,         -- 多部件面、线或属性表
  srid             INTEGER NOT NULL DEFAULT 4490,
  feature_count    INTEGER,                      -- 图层要素数（入库时统计）
  geom             geometry(MultiPolygon, 4490), -- 管控类图层边界（多要素合并）；其余图层可空
  area_km2         NUMERIC(12,4),                -- 管控类图层填报或下发面积
  source           VARCHAR(128),                 -- 数据来源与版本，如 宣城市自然资源局2024
  effective_date   DATE,                         -- 该版边界生效日期
  service_endpoint TEXT,                              -- 服务根地址；服务未发布时可空
  service_types    VARCHAR(64),                      -- WMS,WFS,WMTS 逗号分隔
  ogc_layer_name   VARCHAR(128),                     -- OGC 服务内的图层名；未发布时可空
  style_ref        VARCHAR(128),
  min_zoom         SMALLINT,
  max_zoom         SMALLINT,
  security_level   VARCHAR(16) NOT NULL DEFAULT '内部'   -- 公开/内部/受限/涉密，与 dim_dict 一致
                   CHECK (security_level IN ('公开','内部','受限','涉密')),
  semantic_desc    TEXT,                          -- 图层语义描述，供向量或关键词选层
  keywords         TEXT[],
  status           VARCHAR(16) NOT NULL DEFAULT 'active'  -- 结构性命名字段，加值须改本约束
                   CHECK (status IN ('active','inactive')),
  last_update_time TIMESTAMP,
  created_at       TIMESTAMP NOT NULL DEFAULT now(),
  updated_at       TIMESTAMP NOT NULL DEFAULT now()
);
COMMENT ON TABLE map_layer IS
  '空间图层表，一张表管图层目录与管控边界。设计原则：只存 GIS 软件不掌握的业务语义与需要独立判据的管控几何，'
  '字段结构、图层范围、样式由 WFS DescribeFeatureType / GetCapabilities 运行时获取，不重复建模。'
  '四条硬规则：涉密图层不返回给智能体；geometry_type=Table 的图层禁止进入空间分析；规划与现状类必须有期次；管控类必须有 geom 与 effective_date。'
  'service_endpoint 与 ogc_layer_name 允许为空：服务是发布结果，常在图层登记之后才就绪，'
  '硬约束会让「图层已定、服务未发」这一常态无法入库。'
  '基础地理类图层不挂期次、不参与压占判定，只作底图与定位参照。';
COMMENT ON COLUMN map_layer.geom IS
  '管控类图层边界，多要素按类型合并为一个多部件面；规划与现状类要素的几何在各自业务表中，本列留空。';
CREATE INDEX idx_ml_geom    ON map_layer USING GIST(geom);
CREATE INDEX idx_ml_status  ON map_layer(data_status, plan_element);
CREATE INDEX idx_ml_period  ON map_layer(period_id);
CREATE INDEX idx_ml_name    ON map_layer USING GIN(layer_name gin_trgm_ops);
CREATE INDEX idx_ml_kw      ON map_layer USING GIN(keywords);

INSERT INTO map_layer
  (layer_code, layer_name, data_status, plan_element, ysdm, period_id, period_label,
   geometry_type, feature_count, geom, source, effective_date,
   service_endpoint, service_types, ogc_layer_name,
   security_level, semantic_desc, keywords, status, last_update_time) VALUES
  ('PLAN_KEZ_FYP14','重点勘查区','规划','重点勘查区','3003010610','十四五规划','十四五规划（2021—2025年）',
   'MultiPolygon',7,NULL,NULL,NULL,
   'http://gis-server/geoserver/wfs','WMS,WFS','plan:key_explore_zone',
   '内部','规划期内划定的重点勘查区域，用于探矿权投放的空间引导','{勘查区,重点勘查,探矿}','active',now()),
  ('PLAN_EB_FYP14','勘查规划区块','规划','勘查规划区块','3003010710','十四五规划','十四五规划（2021—2025年）',
   'MultiPolygon',12,NULL,NULL,NULL,
   'http://gis-server/geoserver/wfs','WMS,WFS','plan:explore_block',
   '内部','规划期内拟投放的勘查规划区块','{勘查区块,规划区块,投放}','active',now()),
  ('PLAN_KMZ_FYP14','重点开采区','规划','重点开采区','3003020410','十四五规划','十四五规划（2021—2025年）',
   'MultiPolygon',5,NULL,NULL,NULL,
   'http://gis-server/geoserver/wfs','WMS,WFS','plan:key_mining_zone',
   '内部','规划期内确定的重点开采区域','{开采区,重点开采,采矿}','active',now()),
  ('PLAN_SSZ_FYP14','砂石土集中开采区','规划','砂石土集中开采区','3003021110','十四五规划','十四五规划（2021—2025年）',
   'MultiPolygon',16,NULL,NULL,NULL,
   'http://gis-server/geoserver/wfs','WMS,WFS','plan:sandstone_zone',
   '内部','建筑用砂石土矿集中开采区域','{砂石,砂石土,集中开采区}','active',now()),
  ('PLAN_MB_FYP14','开采规划区块','规划','开采规划区块','3003020710','十四五规划','十四五规划（2021—2025年）',
   'MultiPolygon',60,NULL,NULL,NULL,
   'http://gis-server/geoserver/wfs','WMS,WFS','plan:mining_block',
   '内部','规划期内拟投放的采矿权空间载体','{开采区块,采矿权投放}','active',now()),
  ('PLAN_SCALE_FYP14','最低开采规模','规划','最低开采规模','3003060110','十四五规划','十四五规划（2021—2025年）',
   'Table',19,NULL,NULL,NULL,
   'http://gis-server/geoserver/wfs','WFS','plan:min_mining_scale',
   '内部','分矿种、分规模等级的最低开采规模要求，属性表不可空间分析','{最低开采规模,准入}','active',now()),
  ('STATUS_MINE_FYP14','主要矿山','现状','矿山',NULL,'十四五基期','十四五基期（2020年现状）',
   'Point',NULL,NULL,NULL,NULL,
   'http://gis-server/geoserver/wfs','WMS,WFS','status:mine',
   '内部','现有主要矿山位置与开采状态','{矿山,开采现状}','active',now()),
  ('STATUS_ER_FYP14','探矿权','现状','探矿权',NULL,'十四五基期','十四五基期（2020年现状）',
   'MultiPolygon',NULL,NULL,NULL,NULL,
   'http://gis-server/geoserver/wfs','WMS,WFS','status:explore_right',
   '受限','已设探矿权范围，涉及权利人信息','{探矿权,勘查许可证}','active',now()),
  ('STATUS_MR_FYP14','采矿权','现状','采矿权',NULL,'十四五基期','十四五基期（2020年现状）',
   'MultiPolygon',NULL,NULL,NULL,NULL,
   'http://gis-server/geoserver/wfs','WMS,WFS','status:mining_right',
   '受限','已设采矿权范围，涉及权利人信息','{采矿权,采矿许可证}','active',now()),
  ('CTRL_REDLINE','生态保护红线','管控','生态保护红线',NULL,NULL,NULL,
   'MultiPolygon',NULL,NULL,NULL,NULL,
   'http://gis-server/geoserver/wfs','WMS,WFS','ctrl:ecological_redline',
   '内部','生态保护红线管控边界，矿业权投放的刚性约束','{红线,生态保护,三区三线}','active',now()),
  ('CTRL_FARMLAND','永久基本农田','管控','永久基本农田',NULL,NULL,NULL,
   'MultiPolygon',NULL,NULL,NULL,NULL,
   'http://gis-server/geoserver/wfs','WMS,WFS','ctrl:permanent_farmland',
   '内部','永久基本农田保护范围','{基本农田,耕地,三区三线}','active',now()),
  ('CTRL_URBAN','城镇开发边界','管控','城镇开发边界',NULL,NULL,NULL,
   'MultiPolygon',NULL,NULL,NULL,NULL,
   'http://gis-server/geoserver/wfs','WMS,WFS','ctrl:urban_boundary',
   '内部','城镇开发边界范围','{城镇开发边界,三区三线}','active',now()),
  ('BASE_JMDDZ','乡级行政区面','基础地理','乡级行政区面','1000310106',NULL,NULL,
   'MultiPolygon',94,NULL,NULL,NULL,
   'http://gis-server/geoserver/wfs','WMS,WFS','base:town_polygon',
   '内部','乡镇居民地面，94 条，源 JMDDZ 图层只有名称没有区划代码，只提供边界不参与按区划统计','{乡镇,行政区面,基础地理}','active',now())
ON CONFLICT (layer_code) DO NOTHING;


-- ============================================================================
-- 尾部核对（人工执行，不是自检脚本）
--   表数应为 25：
--     dim_*      5   dim_period / dim_admin_region / dim_mineral / dim_dict / dim_ysdm
--     fact_*     8   fact_ore_field / fact_mineral_reserve / fact_ore_field_mineral
--                    fact_mineral_develop / fact_mine / fact_mine_mineral
--                    fact_explore_right / fact_mining_right
--     plan_*    11   空间 5：plan_key_explore_zone / plan_explore_block / plan_key_mining_zone
--                          plan_sandstone_zone / plan_mining_block
--                    属性 6：plan_min_mining_scale / plan_mining_access_rule /
--                          plan_mineral_restriction / plan_large_medium_ratio /
--                          plan_new_reserve / plan_legacy_mine
--     map_*      1   map_layer
--   查询：SELECT table_name FROM information_schema.tables
--         WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1;
--
--   与 DZ/T 0226-2020 标准成果库的对应关系（11 项标准对象全部落表）：
--     KANCHQZD→plan_key_explore_zone   KANCHQK→plan_explore_block
--     KAICQZD →plan_key_mining_zone    KAICQK →plan_mining_block
--     KAICQST →plan_sandstone_zone     JMDDZ  →dim_admin_region
--     KSKCGM  →plan_min_mining_scale   KSZRZB →plan_mining_access_rule
--                                       + plan_mineral_restriction（限禁矿种拆行）
--     DZXKSBLZB→plan_large_medium_ratio
--     XKCDJXZZYLZB→plan_new_reserve    LSKYZB →plan_legacy_mine
-- ============================================================================
