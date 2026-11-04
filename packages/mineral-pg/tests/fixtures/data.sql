-- Synthetic data only; deliberately not representative of production quantities.
INSERT INTO dim_period(period_id, period_code, period_label, period_type, period_role, cycle_code, cycle_name)
VALUES ('测试未填年份','UNKNOWN_BASE','测试未填年份','status','base','TEST_UNKNOWN','测试异常');
INSERT INTO dim_mineral (mineral_id, mineral_code, mineral_name, is_key_mineral) VALUES
('M01', 'TEST01', '测试铁矿', true), ('M02', 'TEST02', '测试铜矿', true),
('M03', 'TEST03', '测试煤', false), ('M04', 'TEST04', '测试石灰岩', false),
('M05', 'TEST05', '测试金矿', false), ('M06', 'TEST06', '测试砂石', false),
('M07', 'TEST07', '测试零基数', false), ('M08', 'TEST08', '测试缺单位', false),
('M09', 'TEST09', '测试空白单位', false), ('M10', 'TEST10', '测试未填数值', false);

INSERT INTO fact_mineral_reserve(period_id, mineral_id, reserve_unit, retained_reserves, cumulative_reserves)
SELECT period_id, v.m, v.u, v.r, v.c FROM dim_period
JOIN (VALUES
('FYP14_BASE', 'M01', '万吨', 100.1000, 200.1000), ('FYP15_BASE', 'M01', '万吨', 125.1250, 210.1050),
('FYP14_BASE', 'M02', '吨', 50.0000, 70.0000), ('FYP15_BASE', 'M02', '万吨', 1.0000, 2.0000),
('FYP14_BASE', 'M03', '万吨', 10.0000, 20.0000),
('FYP15_BASE', 'M04', '万吨', 30.0000, 40.0000),
('FYP14_BASE', 'M05', '吨', NULL, 100.0000), ('FYP15_BASE', 'M05', '吨', 50.0000, 120.0000),
('FYP14_BASE', 'M06', '万吨', 99999999999999.9998, 0.0000),
('FYP15_BASE', 'M06', '万吨', 99999999999999.9999, 0.0000),
('FYP14_BASE', 'M07', '吨', 0.0000, 0.0000), ('FYP15_BASE', 'M07', '吨', 1.0000, 1.0000),
('FYP14_BASE', 'M08', NULL, 1.0000, 1.0000), ('FYP15_BASE', 'M08', NULL, 2.0000, 2.0000),
('FYP14_BASE', 'M09', ' ', 1.0000, 1.0000), ('FYP15_BASE', 'M09', ' ', 2.0000, 2.0000),
('FYP14_BASE', 'M10', '吨', NULL, NULL), ('FYP15_BASE', 'M10', '吨', NULL, NULL)
) AS v(p,m,u,r,c) ON period_code = v.p;

INSERT INTO fact_mine(period_id, mine_id, mine_code, mine_name, mineral_id, reserves, reserve_unit)
SELECT period_id, v.id, v.code, v.name, v.m, v.r, '万吨' FROM dim_period
JOIN (VALUES
('FYP14_BASE','MN-SAME',NULL,'测试不变','M01',10.1000), ('FYP15_BASE','MN-SAME',NULL,'测试不变','M01',10.1000),
('FYP14_BASE','MN-RENAME','OLD','测试旧名','M01',99999999999999.9998),
('FYP15_BASE','MN-RENAME','NEW','测试新名','M01',99999999999999.9999),
('FYP14_BASE','MN-GONE','GONE','测试缺失','M01',1.0000),
('FYP15_BASE','MN-ADDED','ADD','测试出现','M01',2.0000),
('FYP14_BASE','MN-SWITCH','SWITCH','测试主矿种改变','M01',3.0000),
('FYP15_BASE','MN-SWITCH','SWITCH','测试主矿种改变','M02',3.0000)
) AS v(p,id,code,name,m,r) ON period_code = v.p;

INSERT INTO fact_explore_right(period_id, right_id, right_code, holder, project_name, mineral_id, valid_from)
SELECT period_id, v.id, v.code, '测试权利人', '测试项目', 'M01', DATE '2019-01-01' FROM dim_period
JOIN (VALUES ('FYP14_BASE','ER-CONT','OLD-E'), ('FYP15_BASE','ER-CONT','NEW-E'),
('FYP14_BASE','ER-GONE',NULL), ('FYP15_BASE','ER-ADDED',NULL)) AS v(p,id,code) ON period_code=v.p;

INSERT INTO fact_mine_mineral(period_id, mine_id, mineral_id, mineral_combo)
SELECT period_id, mine_id, 'M02', '伴生矿产' FROM fact_mine WHERE mine_id='MN-SAME';

INSERT INTO fact_mining_right(period_id, right_id, right_code, holder, mine_name, mineral_id, regist_area_km2)
SELECT period_id, v.id, v.code, '测试权利人', '测试矿山', 'M01', 1.2345 FROM dim_period
JOIN (VALUES ('FYP14_BASE','MR-CONT','OLD-M'), ('FYP15_BASE','MR-CONT','NEW-M'),
('FYP14_BASE','MR-GONE',NULL), ('FYP15_BASE','MR-ADDED',NULL)) AS v(p,id,code) ON period_code=v.p;

INSERT INTO fact_mineral_develop(period_id,mineral_id,stat_year,output_unit,output_total,output_value_total)
SELECT period_id, v.m, v.y, v.u, v.o, 100.1000 FROM dim_period
JOIN (VALUES
('FYP15_BASE','M01',0,'万吨',999999.0000), ('FYP15_BASE','M01',2024,'万吨',10.1000),
('FYP15_BASE','M01',2025,'万吨',20.2000), ('FYP15_BASE','M02',2025,'吨',100.0001),
('FYP15_BASE','M03',2025,'万吨',NULL), ('FYP15_BASE','M04',2025,NULL,5.0000),
('FYP14_BASE','M01',2020,'万吨',1.1000), ('FYP14_BASE','M01',2024,'吨',123456.7890)
) AS v(p,m,y,u,o) ON period_code=v.p;
