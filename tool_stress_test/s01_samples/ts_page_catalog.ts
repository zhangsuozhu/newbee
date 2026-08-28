import type { PageDefinition, HaWorkbenchPageDefinition } from "@/types";
import { configPages } from "./config-pages";

// HA工作台页面元数据
const adminHaPage: HaWorkbenchPageDefinition = {
  id: "high-availability-configuration",
  kind: "ha-workbench",
  title: "高可用配置",
  subtitle: "主备高可用 · L1/L2/L3分级健康检查",
  description: "HA 主备管理：支持代理/摆渡任务，L1链路/L2进程/L3业务三级检查，可配置触发切换及VIP漂移。",
  breadcrumbs: ["系统管理", "高可用配置"],
  tags: ["系统管理", "HA 工作台"],
  status: "运行正常",
  updatedAt: "2026-04-20 18:00 CST",
  actions: [],
  statusMetrics: [
    { label: "HA 组", value: "2", hint: "双机组已接管核心流量", riskLevel: "low" },
    { label: "心跳链路", value: "稳定", hint: "最近 24 小时无抖动", riskLevel: "low" },
    { label: "同步延迟", value: "12 ms", hint: "仍处于安全阈值内", riskLevel: "medium" }
  ],
  tabs: [
    { id: "basic", label: "基本设置", description: "HA 组、主备关系与接管范围。" },
    { id: "heartbeat", label: "健康检查", description: "L1/L2/L3 分级健康检查与仲裁配置。" },
    { id: "vip", label: "VIP管理", description: "内网/外网 VIP 漂移与 GARP 配置。" },
    { id: "policy", label: "切换策略", description: "自动/人工切换与防脑裂策略。" },
    { id: "sync", label: "数据同步", description: "配置、会话与状态同步对象。" },
    { id: "advanced", label: "高级配置", description: "文件摆渡任务高级设置与日志。" },
    { id: "monitor", label: "状态监控·评分", description: "实时健康评分与自动切换判据。" }
  ]
};

const legacyPageCatalog: Record<string, PageDefinition> = {
  "global-overview": {
    "id": "global-overview",
    "title": "全局总览",
    "subtitle": "核心状态卡、拓扑简图、业务总量与安全审计趋势",
    "description": "核心状态卡、拓扑简图、业务总量与安全审计趋势",
    "breadcrumbs": [
      "首页驾驶舱",
      "全局总览",
    ],
    "tags": [
      "首页驾驶舱",
      "首页驾驶舱",
    ],
    "status": "运行正常 · 支持从业务卡片快速下钻到代理对象",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新全局数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "汇总展示核心状态、拓扑、业务分布与安全热区。",
      },
      {
        "label": "切换告警视图",
        "tone": "ghost",
        "intent": "warning",
      },
    ],
    "heroMetrics": [
      {
        "label": "整组健康",
        "value": "98.6%",
        "delta": "+0.4%",
        "tone": "positive",
        "sparkline": [
          90,
          91,
          92,
          94,
          95,
          96,
          97,
          98,
        ],
      },
      {
        "label": "高危告警",
        "value": "07",
        "delta": "-2",
        "tone": "warning",
        "sparkline": [
          18,
          16,
          14,
          13,
          11,
          10,
          9,
          7,
        ],
      },
      {
        "label": "今日审计事件",
        "value": "18,241",
        "delta": "+12%",
        "tone": "accent",
        "sparkline": [
          9,
          10,
          12,
          14,
          16,
          17,
          18,
          20,
        ],
      },
      {
        "label": "交换总量",
        "value": "28.4M",
        "delta": "+8%",
        "tone": "accent",
        "sparkline": [
          12,
          14,
          16,
          18,
          21,
          23,
          26,
          28,
        ],
      },
    ],
    "highlights": [
      "首页驾驶舱以跨模块指标为中心，所有业务卡片都能直接钻取到业务代理页面。",
      "将四节点拓扑、业务总量和安全趋势放在同一页，展示整体能力边界。",
      "安全态势热力图与审计时间线是风险发现到处置闭环的快速入口。",
    ],
    "sections": [
      {
        "layout": "three",
        "widgets": [
          {
            "type": "topology",
            "title": "四节点拓扑总览",
            "description": "展示当前承载路径、主备标识与链路方向。",
            "nodes": [
              {
                "id": "n1",
                "name": "接入节点 A",
                "role": "北向接入",
                "tone": "positive",
                "meta": "QPS 4.8k",
              },
              {
                "id": "n2",
                "name": "交换节点 B",
                "role": "重组缓冲",
                "tone": "positive",
                "meta": "堆积 18",
              },
              {
                "id": "n3",
                "name": "交付节点 C",
                "role": "南向交付",
                "tone": "positive",
                "meta": "延迟 12ms",
              },
              {
                "id": "n4",
                "name": "备份节点 D",
                "role": "HA 备用",
                "tone": "warning",
                "meta": "待切换",
              },
            ],
            "links": [
              {
                "from": "n1",
                "to": "n2",
                "label": "交换主链",
                "tone": "positive",
              },
              {
                "from": "n2",
                "to": "n3",
                "label": "交付主链",
                "tone": "positive",
              },
              {
                "from": "n2",
                "to": "n4",
                "label": "心跳同步",
                "tone": "warning",
              },
            ],
          },
          {
            "type": "bar-list",
            "title": "业务对象分布",
            "description": "按代理对象类型统计当前承载规模。",
            "items": [
              {
                "label": "API 代理",
                "value": 86,
                "max": 100,
                "tone": "accent",
                "meta": "32 个业务分组接入",
              },
              {
                "label": "文件传输",
                "value": 61,
                "max": 100,
                "tone": "positive",
                "meta": "14 条关键任务",
              },
              {
                "label": "数据库代理",
                "value": 43,
                "max": 100,
                "tone": "warning",
                "meta": "8 个高风险访问域",
              },
            ],
          },
          {
            "type": "heatmap",
            "title": "安全态势热力图",
            "description": "按业务分组和风险维度展示热度。",
            "xLabels": [
              "访问控制",
              "内容过滤",
              "TLS",
              "SQL 风险",
              "文件检查",
            ],
            "yLabels": [
              "医保",
              "政务共享",
              "公安接口",
              "财政核心",
            ],
            "values": [
              [
                88,
                56,
                42,
                14,
                22,
              ],
              [
                72,
                82,
                51,
                24,
                31,
              ],
              [
                40,
                33,
                77,
                21,
                12,
              ],
              [
                52,
                48,
                61,
                84,
                28,
              ],
            ],
          },
        ],
      },
      {
        "layout": "two",
        "widgets": [
          {
            "type": "table",
            "title": "关键业务概况",
            "description": "从首页直接观察核心业务对象的状态与分组归属。",
            "columns": [
              {
                "key": "name",
                "label": "业务对象",
              },
              {
                "key": "group",
                "label": "业务分组",
              },
              {
                "key": "traffic",
                "label": "今日量级",
              },
              {
                "key": "status",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "name": "电子病历上报 API",
                "group": "卫健委 / 医保",
                "traffic": "12.4M",
                "status": {
                  "text": "健康",
                  "tone": "positive",
                },
              },
              {
                "name": "政务归档文件交换",
                "group": "政务共享 / 文书",
                "traffic": "4,286",
                "status": {
                  "text": "观察中",
                  "tone": "warning",
                },
              },
              {
                "name": "财政核心账务查询",
                "group": "财政 / 核算中心",
                "traffic": "1.4M",
                "status": {
                  "text": "受控放行",
                  "tone": "accent",
                },
              },
            ],
          },
          {
            "type": "timeline",
            "title": "主备切换与故障趋势",
            "description": "近期主备演练与故障恢复耗时。",
            "events": [
              {
                "time": "09:12",
                "title": "周三例行演练",
                "detail": "切换耗时 9.2s，业务未中断。",
                "tone": "positive",
              },
              {
                "time": "13:45",
                "title": "北向链路抖动",
                "detail": "触发告警并自动恢复，排障证据已归档。",
                "tone": "warning",
              },
              {
                "time": "18:22",
                "title": "策略发布完成",
                "detail": "新规则覆盖 3 个业务分组，已同步备机。",
                "tone": "accent",
              },
            ],
          },
        ],
      },
    ],
  },
  "security-overview": {
    "id": "security-overview",
    "kind": "dashboard",
    "title": "安全总览",
    "subtitle": "实时安全态势、事件处置与风险分析",
    "description": "安全总览页面：实时安全态势感知、安全事件处置工作台、风险分析与业务安全保护价值评估",
    "breadcrumbs": [
      "首页驾驶舱",
      "安全总览"
    ],
    "tags": [
      "安全运营",
      "SOC",
      "态势感知"
    ],
    "status": "安全评分 87/100 · 2个紧急待处理",
    "updatedAt": "2026-05-14 20:00 CST",
    "actions": [
      {
        "label": "刷新安全数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "安全数据已刷新，所有指标和图表已更新至最新状态。"
      },
      {
        "label": "导出安全报告",
        "tone": "ghost",
        "intent": "export"
      }
    ],
    "heroMetrics": [
      {
        "label": "安全评分",
        "value": "87",
        "delta": "+3",
        "tone": "positive",
        "sparkline": [
          82,
          83,
          84,
          85,
          85,
          86,
          86,
          87
        ]
      },
      {
        "label": "待处理事件",
        "value": "12",
        "delta": "-5",
        "tone": "warning",
        "sparkline": [
          20,
          18,
          17,
          16,
          15,
          14,
          13,
          12
        ]
      },
      {
        "label": "今日拦截",
        "value": "286",
        "delta": "+42",
        "tone": "accent",
        "sparkline": [
          200,
          220,
          235,
          245,
          255,
          265,
          275,
          286
        ]
      },
      {
        "label": "合规通过率",
        "value": "94.2%",
        "delta": "+1.2%",
        "tone": "positive",
        "sparkline": [
          89,
          90,
          91,
          91,
          92,
          92,
          93,
          94.2
        ]
      }
    ],
    "highlights": [
      "安全总览整合告警、合规、威胁情报与业务安全四大维度，为安全管理员提供一站式态势感知与处置能力。",
      "总览 Tab 展示安全评分、风险热力图和告警趋势；处置 Tab 支持事件筛选、批量操作和快速状态变更。",
      "分析 Tab 提供攻击路径可视化、业务组安全覆盖率和策略保护效能分析，量化系统对业务的保护价值。"
    ],
    "sections": []
  },
  "audit-overview": {
    "id": "audit-overview",
    "title": "审计总览",
    "subtitle": "日志总量、管理员操作与配置变更态势",
    "description": "日志总量、管理员操作与配置变更态势",
    "breadcrumbs": [
      "首页驾驶舱",
      "审计总览",
    ],
    "tags": [
      "首页驾驶舱",
      "首页驾驶舱",
    ],
    "status": "运行正常 · 全部服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "今日日志",
        "value": "2.4M",
        "delta": "+8%",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "管理员操作",
        "value": "342",
        "delta": "+12%",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "配置变更",
        "value": "28",
        "delta": "-4",
        "tone": "positive",
        "sparkline": [
          69,
          62,
          58,
          54,
          49,
          41,
          38,
          32,
        ],
      },
      {
        "label": "高风险事件",
        "value": "07",
        "delta": "-2",
        "tone": "warning",
        "sparkline": [
          18,
          16,
          14,
          13,
          11,
          10,
          9,
          7,
        ],
      },
    ],
    "highlights": [
      "审计总览提供日志量、管理员操作与配置变更三个核心维度。",
      "高风险事件可直接跳转到专项审计页查看详情。",
      "支持按模块和风险级别快速筛选。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "heatmap",
            "title": "审计热度分布",
            "description": "按模块与时间窗口观察审计量级。",
            "xLabels": [
              "08:00",
              "10:00",
              "12:00",
              "14:00",
              "16:00",
              "18:00",
            ],
            "yLabels": [
              "API",
              "文件",
              "数据库",
              "管理操作",
            ],
            "values": [
              [
                22,
                34,
                48,
                65,
                72,
                58,
              ],
              [
                16,
                24,
                31,
                55,
                63,
                49,
              ],
              [
                12,
                18,
                22,
                39,
                46,
                40,
              ],
              [
                8,
                14,
                12,
                20,
                29,
                35,
              ],
            ],
          },
          {
            "type": "table",
            "title": "最近审计事件",
            "description": "审计字段与留痕能力。",
            "columns": [
              {
                "key": "time",
                "label": "时间",
              },
              {
                "key": "actor",
                "label": "操作主体",
              },
              {
                "key": "target",
                "label": "对象",
              },
              {
                "key": "result",
                "label": "结果",
              },
            ],
            "rows": [
              {
                "time": "14:18:03",
                "actor": "api_admin",
                "target": "电子病历上报",
                "result": {
                  "text": "发布成功",
                  "tone": "positive",
                },
              },
              {
                "time": "15:06:49",
                "actor": "sec_admin",
                "target": "SQL 风险模板",
                "result": {
                  "text": "需复核",
                  "tone": "warning",
                },
              },
              {
                "time": "18:32:17",
                "actor": "audit_admin",
                "target": "导出审计报表",
                "result": {
                  "text": "已留痕",
                  "tone": "accent",
                },
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "timeline",
            "title": "管理与配置变更时间线",
            "description": "重点突出管理员操作、配置变更与留痕。",
            "events": [
              {
                "time": "09:24",
                "title": "新增 API 路由",
                "detail": "新增至业务分组“卫健委 / 外联接口”。",
                "tone": "accent",
              },
              {
                "time": "11:10",
                "title": "文件模板更新",
                "detail": "补充压缩包炸弹检测规则。",
                "tone": "warning",
              },
              {
                "time": "17:42",
                "title": "数据库规则下发",
                "detail": "2 条高危 SQL 策略已发布并同步。",
                "tone": "positive",
              },
            ],
          },
        ],
      },
    ],
  },
  "business-grouping": {
    "id": "business-grouping",
    "title": "业务分组树",
    "subtitle": "树形分组管理，支持增删改查与拖拽排序",
    "description": "树形分组管理，支持增删改查与拖拽排序",
    "breadcrumbs": [
      "业务管理",
      "业务分组树",
    ],
    "tags": [
      "业务管理",
      "业务管理",
    ],
    "status": "运行正常 · 支持树形分组与拖拽排序",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "新建业务分组",
        "tone": "primary",
        "intent": "drawer",
        "payload": "分组名称、编码、负责人、继承策略与排序。",
      },
      {
        "label": "切换树形筛选",
        "tone": "ghost",
        "intent": "drawer",
        "payload": "支持按业务域、子系统、地区与对象类型筛选。",
      },
    ],
    "heroMetrics": [
      {
        "label": "分组数",
        "value": "32",
        "delta": "+4",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "对象数",
        "value": "326",
        "delta": "+18",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "未分组",
        "value": "18",
        "delta": "-6",
        "tone": "warning",
        "sparkline": [
          69,
          62,
          58,
          54,
          49,
          41,
          38,
          32,
        ],
      },
      {
        "label": "拖拽排序",
        "value": "已启用",
        "delta": "—",
        "tone": "positive",
        "sparkline": [
          50,
          50,
          50,
          50,
          50,
          50,
          50,
          50,
        ],
      },
    ],
    "highlights": [
      "业务分组树支持增删改查、拖拽排序和批量移动。",
      "每个分组可绑定安全域、责任人和审批流。",
      "未分组对象提醒帮助完善通道归属。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "tree",
            "title": "业务分组树",
            "description": "支持树形增删改查、拖拽排序和对象挂载。",
            "nodes": [
              {
                "label": "政务共享平台",
                "meta": "12 个子系统 / 48 个对象",
                "tags": [
                  "一级分组",
                  "跨域",
                ],
                "children": [
                  {
                    "label": "文件共享服务",
                    "meta": "14 个文件任务",
                  },
                  {
                    "label": "统一接口网关",
                    "meta": "18 个 API 服务",
                  },
                ],
              },
              {
                "label": "医保专网",
                "meta": "8 个子系统 / 61 个对象",
                "tags": [
                  "一级分组",
                  "高优先级",
                ],
                "children": [
                  {
                    "label": "电子病历",
                    "meta": "9 个 API 服务",
                  },
                  {
                    "label": "医保结算",
                    "meta": "6 个数据库代理",
                  },
                ],
              },
            ],
          },
          {
            "type": "table",
            "title": "分组管理清单",
            "description": "模拟右侧属性面板与拖拽排序后的结果。",
            "columns": [
              {
                "key": "name",
                "label": "分组名称",
              },
              {
                "key": "owner",
                "label": "负责人",
              },
              {
                "key": "objects",
                "label": "对象数",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "name": "政务共享平台",
                "owner": "张蕾",
                "objects": "48",
                "state": {
                  "text": "已发布",
                  "tone": "positive",
                },
              },
              {
                "name": "医保专网",
                "owner": "李晨",
                "objects": "61",
                "state": {
                  "text": "待调整排序",
                  "tone": "warning",
                },
              },
              {
                "name": "财政结算中心",
                "owner": "王岳",
                "objects": "27",
                "state": {
                  "text": "已继承模板",
                  "tone": "accent",
                },
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "timeline",
            "title": "最近变更记录",
            "description": "分组增删改、对象绑定与审批流。",
            "events": [
              {
                "time": "10:16",
                "title": "新增子分组",
                "detail": "政务共享平台下新增“证照共享”子组。",
                "tone": "accent",
              },
              {
                "time": "14:42",
                "title": "拖拽排序",
                "detail": "医保专网被调整至一级分组顶部。",
                "tone": "warning",
              },
              {
                "time": "18:09",
                "title": "对象挂载完成",
                "detail": "财政数据库代理 2 个对象已绑定。",
                "tone": "positive",
              },
            ],
          },
        ],
      },
    ],
  },
  "biz-topology": {
    "id": "biz-topology",
    "title": "业务拓扑视图",
    "subtitle": "S01 业务接入全景：源IP、后端服务器、数据库代理、FTP摆渡、Pod集群",
    "description": "S01 业务接入全景：源IP、后端服务器、数据库代理、FTP摆渡、Pod集群",
    "breadcrumbs": [
      "业务管理",
      "业务拓扑视图",
    ],
    "tags": [
      "业务管理",
      "业务拓扑",
    ],
    "status": "运行正常 · 业务对象已加载",
    "updatedAt": "2026-05-11 14:00 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "接入源IP",
        "value": "128",
        "delta": "+12",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "后端服务器",
        "value": "10",
        "delta": "—",
        "tone": "accent",
        "sparkline": [
          10,
          10,
          10,
          10,
          10,
          10,
          10,
          10,
        ],
      },
      {
        "label": "数据库代理",
        "value": "8库/50Pod",
        "delta": "+5Pod",
        "tone": "positive",
        "sparkline": [
          40,
          42,
          44,
          46,
          48,
          50,
          52,
          55,
        ],
      },
      {
        "label": "FTP摆渡任务",
        "value": "10",
        "delta": "+2",
        "tone": "positive",
        "sparkline": [
          6,
          7,
          7,
          8,
          8,
          9,
          9,
          10,
        ],
      },
    ],
    "highlights": [
      "业务拓扑以 S01 为中心，展示五大业务类别的接入关系。",
      "点击类别节点可下钻到右侧抽屉，查看该类别下的全部明细。",
      "连线箭头方向表示请求流向，红色链路可直接进入诊断。",
    ],
    "sections": [
      {
        "layout": "single",
        "widgets": [
          {
            "type": "business-topology-interactive",
            "title": "业务拓扑全景",
            "description": "点击节点查看类别明细。拖拽、缩放可调整视图。",
          },
        ],
      },
    ],
  },
  "business-topology": {
    "id": "business-topology",
    "title": "业务拓扑",
    "subtitle": "四节点拓扑全图、节点详情与辅助状态信息",
    "description": "四节点拓扑全图、节点详情与辅助状态信息",
    "breadcrumbs": [
      "系统运行",
      "业务拓扑",
    ],
    "tags": [
      "系统运行",
      "系统运行",
    ],
    "status": "运行正常 · 系统运行正常",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "整组健康",
        "value": "98.6%",
        "delta": "+0.4%",
        "tone": "positive",
        "sparkline": [
          90,
          91,
          92,
          94,
          95,
          96,
          97,
          98,
        ],
      },
      {
        "label": "当前主机",
        "value": "A组",
        "delta": "—",
        "tone": "accent",
        "sparkline": [
          50,
          50,
          50,
          50,
          50,
          50,
          50,
          50,
        ],
      },
      {
        "label": "当前备机",
        "value": "B组",
        "delta": "—",
        "tone": "neutral",
        "sparkline": [
          50,
          50,
          50,
          50,
          50,
          50,
          50,
          50,
        ],
      },
      {
        "label": "异常数",
        "value": "3",
        "delta": "-1",
        "tone": "warning",
        "sparkline": [
          69,
          62,
          58,
          54,
          49,
          41,
          38,
          32,
        ],
      },
    ],
    "highlights": [
      "业务拓扑页展示四节点串行部署的完整拓扑图。",
      "节点状态、链路方向和当前承载路径一目了然。",
      "辅助信息展示交换对象总量、正在处理量和重组积压量。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "topology",
            "title": "四节点拓扑全图",
            "description": "突出节点状态、链路健康与当前承载路径。",
            "nodes": [
              {
                "id": "n1",
                "name": "接入节点 A",
                "role": "北向接入",
                "tone": "positive",
                "meta": "QPS 4.8k",
              },
              {
                "id": "n2",
                "name": "交换节点 B",
                "role": "重组缓冲",
                "tone": "positive",
                "meta": "堆积 18",
              },
              {
                "id": "n3",
                "name": "交付节点 C",
                "role": "南向交付",
                "tone": "positive",
                "meta": "延迟 12ms",
              },
              {
                "id": "n4",
                "name": "备份节点 D",
                "role": "HA 备用",
                "tone": "warning",
                "meta": "待切换",
              },
            ],
            "links": [
              {
                "from": "n1",
                "to": "n2",
                "label": "交换主链",
                "tone": "positive",
              },
              {
                "from": "n2",
                "to": "n3",
                "label": "交付主链",
                "tone": "positive",
              },
              {
                "from": "n2",
                "to": "n4",
                "label": "心跳同步",
                "tone": "warning",
              },
            ],
          },
          {
            "type": "status-list",
            "title": "节点状态卡",
            "description": "面向设备视角查看整组健康和主备角色。",
            "items": [
              {
                "label": "当前主机",
                "value": "节点 A",
                "tone": "positive",
                "meta": "北向接入主承载",
              },
              {
                "label": "当前备机",
                "value": "节点 D",
                "tone": "warning",
                "meta": "心跳同步正常",
              },
              {
                "label": "当前异常数",
                "value": "12",
                "tone": "warning",
                "meta": "集中在文件与链路告警",
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "table",
            "title": "节点与辅助信息",
            "description": "从设备和对象两个角度补充拓扑信息。",
            "columns": [
              {
                "key": "node",
                "label": "节点",
              },
              {
                "key": "role",
                "label": "角色",
              },
              {
                "key": "objects",
                "label": "承载对象",
              },
              {
                "key": "health",
                "label": "健康度",
              },
            ],
            "rows": [
              {
                "node": "节点 A",
                "role": "接入主",
                "objects": "82",
                "health": {
                  "text": "正常",
                  "tone": "positive",
                },
              },
              {
                "node": "节点 B",
                "role": "交换主",
                "objects": "74",
                "health": {
                  "text": "正常",
                  "tone": "positive",
                },
              },
              {
                "node": "节点 C",
                "role": "交付主",
                "objects": "68",
                "health": {
                  "text": "轻微拥塞",
                  "tone": "warning",
                },
              },
              {
                "node": "节点 D",
                "role": "备用",
                "objects": "0",
                "health": {
                  "text": "待命",
                  "tone": "accent",
                },
              },
            ],
          },
        ],
      },
    ],
  },
  "link-status": {
    "id": "link-status",
    "title": "链路状态",
    "subtitle": "链路清单、指标详情与健康检查动作",
    "description": "链路清单、指标详情与健康检查动作",
    "breadcrumbs": [
      "系统运行",
      "链路状态",
    ],
    "tags": [
      "系统运行",
      "系统运行",
    ],
    "status": "运行正常 · 系统运行正常",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "链路总数",
        "value": "12",
        "delta": "0",
        "tone": "accent",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "正常",
        "value": "10",
        "delta": "0",
        "tone": "positive",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "告警",
        "value": "1",
        "delta": "0",
        "tone": "warning",
        "sparkline": [
          50,
          50,
          50,
          50,
          50,
          50,
          50,
          50,
        ],
      },
      {
        "label": "异常",
        "value": "1",
        "delta": "+1",
        "tone": "danger",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "链路状态页展示交换主链、心跳链路、管理链路和审计链路的实时指标。",
      "每条链路可执行健康检查、仿真切换和查看日志。",
      "带宽利用率和平均时延是链路健康的核心指标。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "table",
            "title": "链路清单",
            "description": "包括交换主链、心跳链路、管理配置链路与审计日志链路。",
            "columns": [
              {
                "key": "name",
                "label": "链路",
              },
              {
                "key": "bandwidth",
                "label": "带宽利用率",
              },
              {
                "key": "delay",
                "label": "平均时延",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "name": "交换主链",
                "bandwidth": "54%",
                "delay": "8ms",
                "state": {
                  "text": "健康",
                  "tone": "positive",
                },
              },
              {
                "name": "高可用心跳",
                "bandwidth": "12%",
                "delay": "2ms",
                "state": {
                  "text": "同步中",
                  "tone": "accent",
                },
              },
              {
                "name": "管理配置链路",
                "bandwidth": "18%",
                "delay": "6ms",
                "state": {
                  "text": "稳定",
                  "tone": "positive",
                },
              },
              {
                "name": "审计日志链路",
                "bandwidth": "66%",
                "delay": "14ms",
                "state": {
                  "text": "需观察",
                  "tone": "warning",
                },
              },
            ],
          },
          {
            "type": "line-chart",
            "title": "链路指标走势",
            "description": "重点看带宽、时延和错误数变化。",
            "labels": [
              "00",
              "03",
              "06",
              "09",
              "12",
              "15",
              "18",
              "21",
            ],
            "series": [
              {
                "name": "带宽利用率",
                "color": "#1858cc",
                "values": [
                  18,
                  22,
                  31,
                  44,
                  56,
                  62,
                  58,
                  54,
                ],
              },
              {
                "name": "平均时延",
                "color": "#d92d20",
                "values": [
                  20,
                  18,
                  16,
                  15,
                  14,
                  13,
                  12,
                  12,
                ],
              },
              {
                "name": "错误数",
                "color": "#f79009",
                "values": [
                  14,
                  12,
                  10,
                  9,
                  7,
                  6,
                  5,
                  4,
                ],
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "matrix",
            "title": "链路动作视图",
            "description": "健康检查、仿真切换和日志查看入口。",
            "columns": [
              "健康检查",
              "仿真切换",
              "查看日志",
            ],
            "rows": [
              {
                "label": "交换主链",
                "values": [
                  {
                    "text": "可执行",
                    "tone": "positive",
                  },
                  {
                    "text": "支持",
                    "tone": "accent",
                  },
                  {
                    "text": "实时",
                    "tone": "accent",
                  },
                ],
              },
              {
                "label": "高可用心跳",
                "values": [
                  {
                    "text": "可执行",
                    "tone": "positive",
                  },
                  {
                    "text": "受控",
                    "tone": "warning",
                  },
                  {
                    "text": "实时",
                    "tone": "accent",
                  },
                ],
              },
              {
                "label": "审计日志链路",
                "values": [
                  {
                    "text": "可执行",
                    "tone": "positive",
                  },
                  {
                    "text": "不建议",
                    "tone": "warning",
                  },
                  {
                    "text": "可追溯",
                    "tone": "positive",
                  },
                ],
              },
            ],
          },
        ],
      },
    ],
  },
  "high-availability-status": {
    "id": "high-availability-status",
    "title": "高可用状态",
    "subtitle": "主备状态、切换记录与手动切换",
    "description": "主备状态、心跳链路、配置同步与手动切换",
    "breadcrumbs": [
      "系统运行",
      "高可用状态",
    ],
    "tags": [
      "系统运行",
      "系统运行",
    ],
    "status": "运行正常 · 系统运行正常",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [],
    "heroMetrics": [],
    "highlights": [],
    "sections": [],
  },
  "performance-capacity": {
    "id": "performance-capacity",
    "title": "性能与容量",
    "subtitle": "CPU、内存、存储、网络与连接数趋势",
    "description": "CPU、内存、存储、网络与连接数趋势",
    "breadcrumbs": [
      "系统运行",
      "性能与容量",
    ],
    "tags": [
      "系统运行",
      "系统运行",
    ],
    "status": "运行正常 · 系统运行正常",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "CPU",
        "value": "42%",
        "delta": "-3%",
        "tone": "positive",
        "sparkline": [
          95,
          94,
          93,
          92,
          91,
          90,
          89,
          88,
        ],
      },
      {
        "label": "内存",
        "value": "67%",
        "delta": "+2%",
        "tone": "warning",
        "sparkline": [
          88,
          89,
          90,
          91,
          92,
          93,
          94,
          95,
        ],
      },
      {
        "label": "存储",
        "value": "38%",
        "delta": "+1%",
        "tone": "positive",
        "sparkline": [
          88,
          89,
          90,
          91,
          92,
          93,
          94,
          95,
        ],
      },
      {
        "label": "连接数",
        "value": "8,432",
        "delta": "+126",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "性能与容量页展示CPU、内存、存储、网络和连接数的实时趋势。",
      "资源水位超过阈值自动告警，支持自定义阈值。",
      "容量预测帮助提前规划扩容。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "line-chart",
            "title": "资源指标走势",
            "description": "综合展示 CPU、内存与连接数趋势。",
            "labels": [
              "00",
              "03",
              "06",
              "09",
              "12",
              "15",
              "18",
              "21",
            ],
            "series": [
              {
                "name": "CPU",
                "color": "#d92d20",
                "values": [
                  28,
                  34,
                  40,
                  47,
                  58,
                  62,
                  59,
                  54,
                ],
              },
              {
                "name": "内存",
                "color": "#1858cc",
                "values": [
                  48,
                  52,
                  54,
                  57,
                  60,
                  63,
                  66,
                  68,
                ],
              },
              {
                "name": "连接数",
                "color": "#12b76a",
                "values": [
                  12,
                  15,
                  18,
                  20,
                  22,
                  24,
                  26,
                  28,
                ],
              },
            ],
          },
          {
            "type": "bar-list",
            "title": "容量占用",
            "description": "从计算、存储和网络几个方面看容量。",
            "items": [
              {
                "label": "CPU",
                "value": 62,
                "max": 100,
                "tone": "accent",
                "meta": "峰值出现在 15:00",
              },
              {
                "label": "内存",
                "value": 68,
                "max": 100,
                "tone": "warning",
                "meta": "增长稳定",
              },
              {
                "label": "存储",
                "value": 54,
                "max": 100,
                "tone": "positive",
                "meta": "可用 3.6TB",
              },
              {
                "label": "网络吞吐",
                "value": 48,
                "max": 100,
                "tone": "accent",
                "meta": "峰值 3.8Gbps",
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "table",
            "title": "容量阈值与告警策略",
            "description": "资源阈值、扩容建议与清理策略。",
            "columns": [
              {
                "key": "item",
                "label": "资源项",
              },
              {
                "key": "threshold",
                "label": "阈值",
              },
              {
                "key": "current",
                "label": "当前值",
              },
              {
                "key": "advice",
                "label": "建议",
              },
            ],
            "rows": [
              {
                "item": "CPU",
                "threshold": "80%",
                "current": "62%",
                "advice": {
                  "text": "继续观察",
                  "tone": "positive",
                },
              },
              {
                "item": "内存",
                "threshold": "75%",
                "current": "68%",
                "advice": {
                  "text": "建议检查缓存池",
                  "tone": "warning",
                },
              },
              {
                "item": "存储",
                "threshold": "85%",
                "current": "54%",
                "advice": {
                  "text": "正常",
                  "tone": "positive",
                },
              },
            ],
          },
        ],
      },
    ],
  },
  "operation-diagnosis": {
    "id": "operation-diagnosis",
    "title": "运维诊断",
    "subtitle": "一键诊断、抓包、连通性探测与责任判断建议",
    "description": "一键诊断、抓包、连通性探测与责任判断建议",
    "breadcrumbs": [
      "系统运行",
      "运维诊断",
    ],
    "tags": [
      "系统运行",
      "系统运行",
    ],
    "status": "运行正常 · 系统运行正常",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "启动一键诊断",
        "tone": "primary",
        "intent": "diagnosis",
      },
      {
        "label": "导出证据包建议",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "诊断任务",
        "value": "3",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "抓包中",
        "value": "1",
        "delta": "0",
        "tone": "warning",
        "sparkline": [
          50,
          50,
          50,
          50,
          50,
          50,
          50,
          50,
        ],
      },
      {
        "label": "探测完成",
        "value": "12",
        "delta": "+4",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "证据包",
        "value": "2",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "运维诊断集一键诊断、抓包、连通性探测和DNS/端口/TLS检测于一体。",
      "一键诊断输出根因建议、责任判断和证据包。",
      "诊断结果可导出交付版和内部版。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "check-grid",
            "title": "一键诊断维度",
            "description": "把网络、设备、策略和目标系统的排查逻辑前置。",
            "items": [
              {
                "title": "网络问题",
                "summary": "检查链路、DNS、PMTU、端口开放。",
                "result": "通过 7/8 项",
                "tone": "positive",
              },
              {
                "title": "设备自身问题",
                "summary": "检查 CPU、内存、进程与配置一致性。",
                "result": "发现 1 项待复核",
                "tone": "warning",
              },
              {
                "title": "策略误拦截",
                "summary": "检查命中模板、阻断动作与白名单。",
                "result": "命中 2 条规则",
                "tone": "warning",
              },
              {
                "title": "目标系统问题",
                "summary": "检查目标可达、握手和业务响应。",
                "result": "高概率异常",
                "tone": "accent",
              },
            ],
          },
          {
            "type": "timeline",
            "title": "诊断过程时间线",
            "description": "展示一键诊断的过程和判责建议。",
            "events": [
              {
                "time": "19:20:03",
                "title": "定位对象",
                "detail": "锁定医保结算 API 对象与所属业务分组。",
                "tone": "accent",
              },
              {
                "time": "19:20:09",
                "title": "分段探测",
                "detail": "链路、TLS、目标服务、规则命中逐项执行。",
                "tone": "positive",
              },
              {
                "time": "19:20:24",
                "title": "生成建议",
                "detail": "建议先排查目标服务超时与后端连接池。",
                "tone": "warning",
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "table",
            "title": "最近诊断记录",
            "description": "判责、建议和证据导出能力。",
            "columns": [
              {
                "key": "target",
                "label": "诊断目标",
              },
              {
                "key": "dimension",
                "label": "维度",
              },
              {
                "key": "result",
                "label": "结论",
              },
              {
                "key": "owner",
                "label": "责任建议",
              },
            ],
            "rows": [
              {
                "target": "电子病历上报 API",
                "dimension": "TLS / 目标服务",
                "result": {
                  "text": "目标服务超时",
                  "tone": "warning",
                },
                "owner": "上游应用团队",
              },
              {
                "target": "政务归档文件任务",
                "dimension": "文件锁 / 静默时间",
                "result": {
                  "text": "等待完整文件",
                  "tone": "accent",
                },
                "owner": "业务侧确认",
              },
              {
                "target": "账务查询代理",
                "dimension": "SQL 风险规则",
                "result": {
                  "text": "模板命中放行",
                  "tone": "positive",
                },
                "owner": "无需处置",
              },
            ],
          },
        ],
      },
    ],
  },
  "api-services": {
    "id": "api-services",
    "title": "服务列表",
    "subtitle": "按业务分组筛选服务通道与运行对象",
    "description": "按业务分组筛选服务通道与运行对象",
    "breadcrumbs": [
      "业务代理",
      "API 代理",
      "服务列表",
    ],
    "tags": [
      "业务代理",
      "API 代理",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "服务数",
        "value": "86",
        "delta": "+7",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "路由数",
        "value": "214",
        "delta": "+16",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "调用方数",
        "value": "132",
        "delta": "+9",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "证书数",
        "value": "58",
        "delta": "+4",
        "tone": "warning",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "服务列表支持按业务分组筛选、树形导航和对象卡片快速钻取。",
      "一页串起服务通道、运行状态、证书和业务归属，展示管理颗粒度。",
      "列表行点击后可进入路由与目标服务或运行监控详情。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "tree",
            "title": "业务分组筛选树",
            "description": "从业务域到服务对象逐层过滤 API 服务。",
            "nodes": [
              {
                "label": "医保专网",
                "meta": "22 个 API 服务",
                "tags": [
                  "高优先级",
                  "生产",
                ],
                "children": [
                  {
                    "label": "电子病历上报",
                    "meta": "QPS 1,284",
                  },
                  {
                    "label": "医保结算查询",
                    "meta": "QPS 932",
                  },
                ],
              },
              {
                "label": "政务共享平台",
                "meta": "18 个 API 服务",
                "tags": [
                  "跨网",
                  "共享",
                ],
                "children": [
                  {
                    "label": "统一身份认证",
                    "meta": "QPS 318",
                  },
                  {
                    "label": "证照共享接口",
                    "meta": "QPS 246",
                  },
                ],
              },
            ],
          },
          {
            "type": "inventory",
            "title": "服务通道卡片",
            "description": "结合健康度、业务分组与协议类型展示。",
            "items": [
              {
                "title": "电子病历上报",
                "meta": "医保 / HTTPS / 双向 TLS",
                "tags": [
                  "健康",
                  "高频",
                ],
                "tone": "positive",
              },
              {
                "title": "统一身份认证",
                "meta": "政务共享 / HTTPS",
                "tags": [
                  "观察中",
                  "跨域",
                ],
                "tone": "warning",
              },
              {
                "title": "财政账务查询",
                "meta": "财政 / HTTP -> HTTPS",
                "tags": [
                  "限流开启",
                  "审计",
                ],
                "tone": "accent",
              },
            ],
          },
        ],
      },
      {
        "layout": "two",
        "widgets": [
          {
            "type": "table",
            "title": "服务列表",
            "description": "支持按业务分组、协议、证书状态和风险级别筛选。",
            "columns": [
              {
                "key": "name",
                "label": "服务名称",
              },
              {
                "key": "group",
                "label": "业务分组",
              },
              {
                "key": "listen",
                "label": "监听入口",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "name": "电子病历上报",
                "group": "医保 / 电子病历",
                "listen": "10.10.1.16:443",
                "state": {
                  "text": "健康",
                  "tone": "positive",
                },
              },
              {
                "name": "统一身份认证",
                "group": "政务共享 / 认证",
                "listen": "10.10.3.11:8443",
                "state": {
                  "text": "证书待更新",
                  "tone": "warning",
                },
              },
              {
                "name": "财政账务查询",
                "group": "财政 / 核算",
                "listen": "10.10.8.22:8080",
                "state": {
                  "text": "限流中",
                  "tone": "accent",
                },
              },
            ],
          },
          {
            "type": "line-chart",
            "title": "服务运行趋势",
            "description": "同时观察请求量、成功率和平均时延。",
            "labels": [
              "00",
              "03",
              "06",
              "09",
              "12",
              "15",
              "18",
              "21",
            ],
            "series": [
              {
                "name": "请求量",
                "color": "#1858cc",
                "values": [
                  320,
                  360,
                  410,
                  520,
                  680,
                  720,
                  640,
                  590,
                ],
              },
              {
                "name": "成功率",
                "color": "#12b76a",
                "values": [
                  92,
                  93,
                  94,
                  95,
                  96,
                  96,
                  95,
                  95,
                ],
              },
              {
                "name": "平均时延",
                "color": "#d92d20",
                "values": [
                  24,
                  22,
                  20,
                  19,
                  17,
                  18,
                  20,
                  21,
                ],
              },
            ],
          },
        ],
      },
    ],
  },
  "api-route": {
    "id": "api-route",
    "title": "路由与目标服务",
    "subtitle": "接入配置、目标池与路由策略统一管理",
    "description": "接入配置、目标池与路由策略统一管理",
    "breadcrumbs": [
      "业务代理",
      "API 代理",
      "路由与目标服务",
    ],
    "tags": [
      "业务代理",
      "API 代理",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "路由规则",
        "value": "214",
        "delta": "+16",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "目标服务池",
        "value": "68",
        "delta": "+4",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "精确匹配",
        "value": "86",
        "delta": "+6",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "前缀匹配",
        "value": "128",
        "delta": "+10",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "路由与目标服务页管理接入侧配置、目标池和路由策略。",
      "支持精确匹配、前缀匹配、SNI匹配和正则匹配。",
      "目标服务池支持健康检查、自动摘除和连接复用。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "form",
            "title": "接入与目标服务配置",
            "description": "接入侧、目标侧和健康检查统一视图。",
            "groups": [
              {
                "title": "接入侧配置",
                "fields": [
                  {
                    "label": "Host",
                    "value": "api.med.gov.cn",
                  },
                  {
                    "label": "Path",
                    "value": "/his/emr/v1/report",
                  },
                  {
                    "label": "Method",
                    "value": "POST",
                  },
                  {
                    "label": "监听端口",
                    "value": "443 / 8443",
                  },
                ],
              },
              {
                "title": "目标侧配置",
                "fields": [
                  {
                    "label": "目标服务",
                    "value": "his-emr-upstream",
                  },
                  {
                    "label": "地址池",
                    "value": "172.16.20.11 / .12",
                  },
                  {
                    "label": "健康检查",
                    "value": "/healthz",
                  },
                  {
                    "label": "会话保持",
                    "value": "Cookie + 300s",
                  },
                ],
              },
            ],
          },
          {
            "type": "table",
            "title": "路由策略清单",
            "description": "支持默认、精确、前缀和 SNI 匹配。",
            "columns": [
              {
                "key": "rule",
                "label": "规则",
              },
              {
                "key": "match",
                "label": "匹配条件",
              },
              {
                "key": "target",
                "label": "目标池",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "rule": "emr-report-exact",
                "match": "Host + Path 精确匹配",
                "target": "his-emr-upstream",
                "state": {
                  "text": "启用",
                  "tone": "positive",
                },
              },
              {
                "rule": "gov-open-prefix",
                "match": "前缀 /openapi/*",
                "target": "gateway-pool",
                "state": {
                  "text": "启用",
                  "tone": "positive",
                },
              },
              {
                "rule": "sni-fallback",
                "match": "SNI=files.gov.cn",
                "target": "file-route-pool",
                "state": {
                  "text": "待复核",
                  "tone": "warning",
                },
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "matrix",
            "title": "路由能力矩阵",
            "description": "匹配能力类型一览。",
            "columns": [
              "默认路由",
              "精确匹配",
              "前缀匹配",
            ],
            "rows": [
              {
                "label": "Host / Path",
                "values": [
                  {
                    "text": "支持",
                    "tone": "positive",
                  },
                  {
                    "text": "支持",
                    "tone": "positive",
                  },
                  {
                    "text": "支持",
                    "tone": "positive",
                  },
                ],
              },
              {
                "label": "Method / Header",
                "values": [
                  {
                    "text": "可扩展",
                    "tone": "accent",
                  },
                  {
                    "text": "支持",
                    "tone": "positive",
                  },
                  {
                    "text": "支持",
                    "tone": "accent",
                  },
                ],
              },
              {
                "label": "SNI",
                "values": [
                  {
                    "text": "不建议",
                    "tone": "warning",
                  },
                  {
                    "text": "支持",
                    "tone": "positive",
                  },
                  {
                    "text": "不适用",
                    "tone": "neutral",
                  },
                ],
              },
            ],
          },
        ],
      },
    ],
  },
  "api-protocol": {
    "id": "api-protocol",
    "title": "协议转换与监听",
    "subtitle": "HTTP/HTTPS 转换与多端口监听能力",
    "description": "HTTP/HTTPS 转换与多端口监听能力",
    "breadcrumbs": [
      "业务代理",
      "API 代理",
      "协议转换与监听",
    ],
    "tags": [
      "业务代理",
      "API 代理",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "监听端口",
        "value": "16",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "HTTP→HTTPS",
        "value": "24",
        "delta": "+3",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "HTTPS→HTTP",
        "value": "18",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "多端口服务",
        "value": "12",
        "delta": "+1",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "协议转换与监听页管理前后端协议组合和多端口监听。",
      "支持HTTP↔HTTPS双向转换，前端与后端协议独立配置。",
      "同一服务可配置多个监听端口和域名组合。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "matrix",
            "title": "协议转换模式",
            "description": "清晰展示 HTTP/HTTPS 前后端组合。",
            "columns": [
              "前端 HTTP",
              "前端 HTTPS",
              "安全提示",
            ],
            "rows": [
              {
                "label": "后端 HTTP",
                "values": [
                  {
                    "text": "支持",
                    "tone": "positive",
                  },
                  {
                    "text": "允许降密",
                    "tone": "warning",
                  },
                  {
                    "text": "需审计",
                    "tone": "warning",
                  },
                ],
              },
              {
                "label": "后端 HTTPS",
                "values": [
                  {
                    "text": "自动建连",
                    "tone": "positive",
                  },
                  {
                    "text": "双向 TLS",
                    "tone": "accent",
                  },
                  {
                    "text": "证书校验",
                    "tone": "positive",
                  },
                ],
              },
              {
                "label": "多端口监听",
                "values": [
                  {
                    "text": "支持",
                    "tone": "accent",
                  },
                  {
                    "text": "支持",
                    "tone": "accent",
                  },
                  {
                    "text": "按服务绑定",
                    "tone": "neutral",
                  },
                ],
              },
            ],
          },
          {
            "type": "form",
            "title": "监听与代理方式",
            "description": "多端口监听和七层透明代理配置。",
            "groups": [
              {
                "title": "监听能力",
                "fields": [
                  {
                    "label": "单服务多端口",
                    "value": "443 / 8443 / 9443",
                  },
                  {
                    "label": "多服务多端口",
                    "value": "支持",
                  },
                  {
                    "label": "端口与域名组合",
                    "value": "已启用",
                  },
                ],
              },
              {
                "title": "代理方式",
                "fields": [
                  {
                    "label": "七层透明代理",
                    "value": "默认开启",
                  },
                  {
                    "label": "TCP 打断重连",
                    "value": "强制",
                  },
                  {
                    "label": "完全透明包转发",
                    "value": "不支持",
                  },
                ],
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "table",
            "title": "协议与监听实例",
            "description": "具体到对象级的协议转换与监听配置。",
            "columns": [
              {
                "key": "service",
                "label": "服务",
              },
              {
                "key": "frontend",
                "label": "前端协议",
              },
              {
                "key": "backend",
                "label": "后端协议",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "service": "电子病历上报",
                "frontend": "HTTPS",
                "backend": "HTTPS",
                "state": {
                  "text": "双向 TLS",
                  "tone": "positive",
                },
              },
              {
                "service": "财政账务查询",
                "frontend": "HTTP",
                "backend": "HTTPS",
                "state": {
                  "text": "自动补 TLS",
                  "tone": "accent",
                },
              },
              {
                "service": "旧版身份接口",
                "frontend": "HTTPS",
                "backend": "HTTP",
                "state": {
                  "text": "降密提示",
                  "tone": "warning",
                },
              },
            ],
          },
        ],
      },
    ],
  },
  "api-certs": {
    "id": "api-certs",
    "title": "证书与 SNI",
    "subtitle": "服务端与客户端证书、SNI 路由、双向 TLS",
    "description": "服务端与客户端证书、SNI 路由、双向 TLS",
    "breadcrumbs": [
      "业务代理",
      "API 代理",
      "证书与 SNI",
    ],
    "tags": [
      "业务代理",
      "API 代理",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "服务端证书",
        "value": "34",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "客户端证书",
        "value": "18",
        "delta": "+1",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "CA证书",
        "value": "6",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "即将到期",
        "value": "3",
        "delta": "+1",
        "tone": "warning",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "证书与SNI页管理服务端证书、客户端证书、CA证书和SNI路由规则。",
      "证书到期预警和批量替换减少运维风险。",
      "双向TLS场景支持客户端证书校验和主题提取。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "inventory",
            "title": "证书对象",
            "description": "从对象卡片中展示证书类型、到期日和绑定服务。",
            "items": [
              {
                "title": "emr-server.crt",
                "meta": "服务端证书 / 2027-02-18",
                "tags": [
                  "医保",
                  "生产",
                ],
                "tone": "positive",
              },
              {
                "title": "gov-client.p12",
                "meta": "客户端证书 / 2026-08-09",
                "tags": [
                  "双向 TLS",
                  "共享",
                ],
                "tone": "accent",
              },
              {
                "title": "legacy-auth.crt",
                "meta": "服务端证书 / 2026-05-20",
                "tags": [
                  "待更新",
                  "告警",
                ],
                "tone": "warning",
              },
            ],
          },
          {
            "type": "table",
            "title": "证书与 SNI 绑定清单",
            "description": "把证书、服务、SNI 和替换计划放在一起。",
            "columns": [
              {
                "key": "cert",
                "label": "证书",
              },
              {
                "key": "service",
                "label": "绑定服务",
              },
              {
                "key": "sni",
                "label": "SNI",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "cert": "emr-server.crt",
                "service": "电子病历上报",
                "sni": "api.med.gov.cn",
                "state": {
                  "text": "正常",
                  "tone": "positive",
                },
              },
              {
                "cert": "gov-client.p12",
                "service": "统一身份认证",
                "sni": "auth.gov.cn",
                "state": {
                  "text": "双向 TLS",
                  "tone": "accent",
                },
              },
              {
                "cert": "legacy-auth.crt",
                "service": "旧版认证服务",
                "sni": "legacy.gov.cn",
                "state": {
                  "text": "30 天内到期",
                  "tone": "warning",
                },
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "timeline",
            "title": "证书替换与提醒",
            "description": "证书到期提醒、替换和审计留痕。",
            "events": [
              {
                "time": "2026-04-18",
                "title": "legacy-auth.crt 到期提醒",
                "detail": "提前 30 天通知系统管理员与安全管理员。",
                "tone": "warning",
              },
              {
                "time": "2026-04-20",
                "title": "gov-client.p12 轮换演练",
                "detail": "已验证客户端证书替换流程。",
                "tone": "accent",
              },
              {
                "time": "2026-04-23",
                "title": "emr-server.crt 自动同步",
                "detail": "证书对象已同步到备节点。",
                "tone": "positive",
              },
            ],
          },
        ],
      },
    ],
  },
  "api-auth": {
    "id": "api-auth",
    "title": "鉴权与调用方",
    "subtitle": "API Key、JWT、OAuth 与证书身份策略",
    "description": "API Key、JWT、OAuth 与证书身份策略",
    "breadcrumbs": [
      "业务代理",
      "API 代理",
      "鉴权与调用方",
    ],
    "tags": [
      "业务代理",
      "API 代理",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "调用方",
        "value": "132",
        "delta": "+9",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "API Key",
        "value": "56",
        "delta": "+4",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "JWT",
        "value": "38",
        "delta": "+3",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "OAuth2",
        "value": "22",
        "delta": "+2",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "鉴权与调用方页管理API Key、JWT、OAuth2/OIDC和客户端证书身份。",
      "访问控制支持来源IP、时间窗、业务对象和安全域组合条件。",
      "调用方画像展示访问频率、异常行为和风险等级。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "matrix",
            "title": "调用方身份类型",
            "description": "覆盖 API Key、JWT、OAuth2/OIDC 与客户端证书。",
            "columns": [
              "支持度",
              "安全等级",
              "典型场景",
            ],
            "rows": [
              {
                "label": "API Key",
                "values": [
                  {
                    "text": "高",
                    "tone": "positive",
                  },
                  {
                    "text": "中",
                    "tone": "warning",
                  },
                  {
                    "text": "开放接口",
                    "tone": "neutral",
                  },
                ],
              },
              {
                "label": "JWT",
                "values": [
                  {
                    "text": "高",
                    "tone": "positive",
                  },
                  {
                    "text": "中高",
                    "tone": "accent",
                  },
                  {
                    "text": "统一网关",
                    "tone": "neutral",
                  },
                ],
              },
              {
                "label": "客户端证书",
                "values": [
                  {
                    "text": "中",
                    "tone": "accent",
                  },
                  {
                    "text": "高",
                    "tone": "positive",
                  },
                  {
                    "text": "高安全专线",
                    "tone": "neutral",
                  },
                ],
              },
            ],
          },
          {
            "type": "form",
            "title": "访问控制条件",
            "description": "把来源 IP、时间窗、业务对象和安全域统一收口。",
            "groups": [
              {
                "title": "条件组合",
                "fields": [
                  {
                    "label": "来源 IP",
                    "value": "10.1.0.0/16 白名单",
                  },
                  {
                    "label": "时间窗",
                    "value": "工作日 08:00 - 20:00",
                  },
                  {
                    "label": "业务对象",
                    "value": "医保专网 / 电子病历",
                  },
                  {
                    "label": "安全域",
                    "value": "政务内网 -> 业务专网",
                  },
                ],
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "table",
            "title": "调用方策略清单",
            "description": "策略继承、例外放行和对象映射。",
            "columns": [
              {
                "key": "caller",
                "label": "调用方",
              },
              {
                "key": "auth",
                "label": "鉴权方式",
              },
              {
                "key": "scope",
                "label": "授权范围",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "caller": "医保前置网关",
                "auth": "客户端证书 + JWT",
                "scope": "电子病历 / 结算",
                "state": {
                  "text": "启用",
                  "tone": "positive",
                },
              },
              {
                "caller": "共享平台网关",
                "auth": "OAuth2/OIDC",
                "scope": "统一认证",
                "state": {
                  "text": "审批授权中",
                  "tone": "warning",
                },
              },
              {
                "caller": "外联测试账号",
                "auth": "API Key",
                "scope": "只读接口",
                "state": {
                  "text": "限流中",
                  "tone": "accent",
                },
              },
            ],
          },
        ],
      },
    ],
  },
  "api-content": {
    "id": "api-content",
    "title": "内容校验与过滤",
    "subtitle": "参数校验、敏感词过滤与模板联动",
    "description": "参数校验、敏感词过滤与模板联动",
    "breadcrumbs": [
      "业务代理",
      "API 代理",
      "内容校验与过滤",
    ],
    "tags": [
      "业务代理",
      "API 代理",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "校验规则",
        "value": "86",
        "delta": "+6",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "过滤规则",
        "value": "42",
        "delta": "+3",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "命中率",
        "value": "12.4%",
        "delta": "+0.8%",
        "tone": "accent",
        "sparkline": [
          88,
          89,
          90,
          91,
          92,
          93,
          94,
          95,
        ],
      },
      {
        "label": "阻断率",
        "value": "2.1%",
        "delta": "-0.3%",
        "tone": "positive",
        "sparkline": [
          95,
          94,
          93,
          92,
          91,
          90,
          89,
          88,
        ],
      },
    ],
    "highlights": [
      "内容校验与过滤页管理Header、Path、Query、Body Schema校验规则。",
      "内容过滤支持关键字和正则两种模式，可引用安全模板。",
      "异常参数阻断和多层编码递归解码保障API安全。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "matrix",
            "title": "请求校验链路",
            "description": "参数校验和内容过滤在同一配置面板中编排。",
            "columns": [
              "Header",
              "Path",
              "Query",
            ],
            "rows": [
              {
                "label": "Schema 校验",
                "values": [
                  {
                    "text": "必填",
                    "tone": "positive",
                  },
                  {
                    "text": "支持",
                    "tone": "positive",
                  },
                  {
                    "text": "支持",
                    "tone": "positive",
                  },
                ],
              },
              {
                "label": "关键字过滤",
                "values": [
                  {
                    "text": "支持",
                    "tone": "accent",
                  },
                  {
                    "text": "支持",
                    "tone": "accent",
                  },
                  {
                    "text": "支持",
                    "tone": "accent",
                  },
                ],
              },
              {
                "label": "正则过滤",
                "values": [
                  {
                    "text": "支持",
                    "tone": "warning",
                  },
                  {
                    "text": "支持",
                    "tone": "warning",
                  },
                  {
                    "text": "支持",
                    "tone": "warning",
                  },
                ],
              },
            ],
          },
          {
            "type": "form",
            "title": "安全模板引用",
            "description": "API 页面引用统一安全模板，避免重复定义。",
            "groups": [
              {
                "title": "当前绑定模板",
                "fields": [
                  {
                    "label": "API 安全模板",
                    "value": "医保外联 API 标准模板",
                  },
                  {
                    "label": "敏感字典",
                    "value": "身份证 / 手机号 / 病案号",
                  },
                  {
                    "label": "处置动作",
                    "value": "阻断并告警",
                  },
                ],
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "table",
            "title": "内容过滤规则清单",
            "description": "把参数校验、敏感词过滤和模板绑定结果一次讲清。",
            "columns": [
              {
                "key": "rule",
                "label": "规则",
              },
              {
                "key": "scope",
                "label": "生效范围",
              },
              {
                "key": "template",
                "label": "来源模板",
              },
              {
                "key": "result",
                "label": "处置动作",
              },
            ],
            "rows": [
              {
                "rule": "身份证号检测",
                "scope": "Body Schema",
                "template": "医保外联 API 标准模板",
                "result": {
                  "text": "阻断并告警",
                  "tone": "warning",
                },
              },
              {
                "rule": "Token 头校验",
                "scope": "Header",
                "template": "统一认证模板",
                "result": {
                  "text": "校验后放行",
                  "tone": "positive",
                },
              },
              {
                "rule": "异常 Query 长度",
                "scope": "Query",
                "template": "政务开放接口模板",
                "result": {
                  "text": "截断并留痕",
                  "tone": "accent",
                },
              },
            ],
          },
        ],
      },
    ],
  },
  "api-discovery": {
    "id": "api-discovery",
    "title": "自学习与通道发现",
    "subtitle": "影子 API 发现与一键生成规则",
    "description": "影子 API 发现与一键生成规则",
    "breadcrumbs": [
      "业务代理",
      "API 代理",
      "自学习与通道发现",
    ],
    "tags": [
      "业务代理",
      "API 代理",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "学习中",
        "value": "3",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "已发现API",
        "value": "428",
        "delta": "+36",
        "tone": "warning",
        "sparkline": [
          18,
          24,
          32,
          42,
          54,
          68,
          82,
          98,
        ],
      },
      {
        "label": "未备案API",
        "value": "36",
        "delta": "+4",
        "tone": "danger",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "已生成规则",
        "value": "12",
        "delta": "+3",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "自学习与通道发现页支持串行学习和日志导入学习两种模式。",
      "学习内容包括Host、Path、Method和Schema规则。",
      "未备案API发现和一键生成规则帮助快速纳管影子API。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "line-chart",
            "title": "自学习趋势",
            "description": "支持串行学习和日志导入学习。",
            "labels": [
              "周一",
              "周二",
              "周三",
              "周四",
              "周五",
              "周六",
              "周日",
            ],
            "series": [
              {
                "name": "学习路径数",
                "color": "#1858cc",
                "values": [
                  12,
                  15,
                  18,
                  21,
                  24,
                  29,
                  33,
                ],
              },
              {
                "name": "影子 API",
                "color": "#d92d20",
                "values": [
                  2,
                  3,
                  4,
                  5,
                  6,
                  8,
                  11,
                ],
              },
              {
                "name": "规则建议",
                "color": "#12b76a",
                "values": [
                  4,
                  6,
                  8,
                  11,
                  16,
                  24,
                  36,
                ],
              },
            ],
          },
          {
            "type": "timeline",
            "title": "学习过程",
            "description": "串行学习、日志导入和规则生成。",
            "events": [
              {
                "time": "09:16",
                "title": "接入日志导入",
                "detail": "导入 3.2M 条访问日志用于接口画像。",
                "tone": "accent",
              },
              {
                "time": "10:48",
                "title": "发现影子 API",
                "detail": "识别出 2 条未备案接口路径。",
                "tone": "warning",
              },
              {
                "time": "11:20",
                "title": "生成规则建议",
                "detail": "生成 Host / Path / Schema 候选规则。",
                "tone": "positive",
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "table",
            "title": "影子 API 与建议规则",
            "description": "一键盘点与规则生成。",
            "columns": [
              {
                "key": "path",
                "label": "路径",
              },
              {
                "key": "method",
                "label": "方法",
              },
              {
                "key": "risk",
                "label": "风险",
              },
              {
                "key": "advice",
                "label": "建议",
              },
            ],
            "rows": [
              {
                "path": "/his/emr/v1/tempUpload",
                "method": "POST",
                "risk": {
                  "text": "未备案",
                  "tone": "warning",
                },
                "advice": "生成内容校验与鉴权建议",
              },
              {
                "path": "/gov/openapi/token",
                "method": "GET",
                "risk": {
                  "text": "鉴权薄弱",
                  "tone": "warning",
                },
                "advice": "补充 OAuth2/OIDC",
              },
              {
                "path": "/finance/report/v2",
                "method": "POST",
                "risk": {
                  "text": "可纳管",
                  "tone": "positive",
                },
                "advice": "一键生成路由模板",
              },
            ],
          },
        ],
      },
    ],
  },
  "api-monitor": {
    "id": "api-monitor",
    "title": "运行监控",
    "subtitle": "QPS、时延、目标可达性与异常会话",
    "description": "QPS、时延、目标可达性与异常会话",
    "breadcrumbs": [
      "业务代理",
      "API 代理",
      "运行监控",
    ],
    "tags": [
      "业务代理",
      "API 代理",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "QPS",
        "value": "4.8k",
        "delta": "+0.6k",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "成功率",
        "value": "99.2%",
        "delta": "+0.1%",
        "tone": "positive",
        "sparkline": [
          88,
          89,
          90,
          91,
          92,
          93,
          94,
          95,
        ],
      },
      {
        "label": "平均时延",
        "value": "18ms",
        "delta": "-2ms",
        "tone": "positive",
        "sparkline": [
          69,
          62,
          58,
          54,
          49,
          41,
          38,
          32,
        ],
      },
      {
        "label": "异常会话",
        "value": "23",
        "delta": "-5",
        "tone": "warning",
        "sparkline": [
          69,
          62,
          58,
          54,
          49,
          41,
          38,
          32,
        ],
      },
    ],
    "highlights": [
      "API代理运行页展示服务运行状态、连接状态和目标可达性。",
      "QPS、成功率、时延和异常会话是运行监控的核心指标。",
      "握手异常和目标超时可直接触发连通性测试。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "line-chart",
            "title": "运行监控趋势",
            "description": "从 QPS、时延和异常会话三条线观察状态。",
            "labels": [
              "00",
              "03",
              "06",
              "09",
              "12",
              "15",
              "18",
              "21",
            ],
            "series": [
              {
                "name": "QPS",
                "color": "#1858cc",
                "values": [
                  180,
                  220,
                  260,
                  320,
                  420,
                  510,
                  488,
                  486,
                ],
              },
              {
                "name": "时延",
                "color": "#d92d20",
                "values": [
                  34,
                  31,
                  28,
                  24,
                  21,
                  19,
                  18,
                  18,
                ],
              },
              {
                "name": "异常会话",
                "color": "#f79009",
                "values": [
                  16,
                  14,
                  13,
                  12,
                  11,
                  10,
                  9,
                  8,
                ],
              },
            ],
          },
          {
            "type": "status-list",
            "title": "目标服务健康",
            "description": "展示后端节点可达性和连接状态。",
            "items": [
              {
                "label": "his-emr-upstream",
                "value": "可达",
                "tone": "positive",
                "meta": "2/2 节点健康",
              },
              {
                "label": "gateway-pool",
                "value": "可达",
                "tone": "positive",
                "meta": "自动摘除恢复开启",
              },
              {
                "label": "legacy-auth-pool",
                "value": "抖动",
                "tone": "warning",
                "meta": "后端握手失败 2 次",
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "table",
            "title": "异常会话与动作",
            "description": "用于展示握手异常、目标超时和连接测试能力。",
            "columns": [
              {
                "key": "session",
                "label": "会话",
              },
              {
                "key": "type",
                "label": "异常类型",
              },
              {
                "key": "target",
                "label": "目标服务",
              },
              {
                "key": "action",
                "label": "动作",
              },
            ],
            "rows": [
              {
                "session": "sess-21498",
                "type": "TLS 握手异常",
                "target": "legacy-auth-pool",
                "action": {
                  "text": "建议证书校验",
                  "tone": "warning",
                },
              },
              {
                "session": "sess-21542",
                "type": "目标超时",
                "target": "his-emr-upstream",
                "action": {
                  "text": "已自动重试",
                  "tone": "accent",
                },
              },
              {
                "session": "sess-21610",
                "type": "连接测试",
                "target": "gateway-pool",
                "action": {
                  "text": "通过",
                  "tone": "positive",
                },
              },
            ],
          },
        ],
      },
    ],
  },
  "file-resources": {
    "id": "file-resources",
    "title": "资源与连接测试",
    "subtitle": "FTP、SFTP、SMB、NFS 资源管理与测试",
    "description": "FTP、SFTP、SMB、NFS 资源管理与测试",
    "breadcrumbs": [
      "业务代理",
      "文件传输",
      "资源与连接测试",
    ],
    "tags": [
      "业务代理",
      "文件传输",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "文件资源",
        "value": "48",
        "delta": "+4",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "FTP",
        "value": "12",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "SFTP",
        "value": "18",
        "delta": "+2",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "SMB与NFS",
        "value": "18",
        "delta": "+2",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "资源与连接测试页管理FTP/FTPS/SFTP/SMB/NFS文件资源。",
      "每个资源包含主机、端口、目录、认证和编码配置。",
      "上线前可执行连通性、认证、目录权限和上传下载测试。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "inventory",
            "title": "资源对象",
            "description": "覆盖 FTP、FTPS、SFTP、SMB、NFS 等协议资源。",
            "items": [
              {
                "title": "医保 SFTP 源站",
                "meta": "sftp / utf-8 / key auth",
                "tags": [
                  "生产",
                  "跨域",
                ],
                "tone": "positive",
              },
              {
                "title": "政务归档 SMB",
                "meta": "smb / GB18030 / domain",
                "tags": [
                  "共享",
                  "中文文件名",
                ],
                "tone": "accent",
              },
              {
                "title": "财政 NFS 目标",
                "meta": "nfs4 / mount",
                "tags": [
                  "落地目录",
                  "备份",
                ],
                "tone": "warning",
              },
            ],
          },
          {
            "type": "matrix",
            "title": "连接测试矩阵",
            "description": "把连通性、认证、目录权限和上传下载测试一次展示。",
            "columns": [
              "连通性",
              "认证",
              "目录权限",
            ],
            "rows": [
              {
                "label": "医保 SFTP 源站",
                "values": [
                  {
                    "text": "通过",
                    "tone": "positive",
                  },
                  {
                    "text": "通过",
                    "tone": "positive",
                  },
                  {
                    "text": "通过",
                    "tone": "positive",
                  },
                ],
              },
              {
                "label": "政务归档 SMB",
                "values": [
                  {
                    "text": "通过",
                    "tone": "positive",
                  },
                  {
                    "text": "通过",
                    "tone": "positive",
                  },
                  {
                    "text": "待复核",
                    "tone": "warning",
                  },
                ],
              },
              {
                "label": "财政 NFS 目标",
                "values": [
                  {
                    "text": "通过",
                    "tone": "positive",
                  },
                  {
                    "text": "不适用",
                    "tone": "neutral",
                  },
                  {
                    "text": "通过",
                    "tone": "positive",
                  },
                ],
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "form",
            "title": "资源接入参数",
            "description": "协议、认证方式、路径和超时等资源字段。",
            "groups": [
              {
                "title": "基础参数",
                "fields": [
                  {
                    "label": "主机 / 端口",
                    "value": "172.16.30.10 : 22",
                  },
                  {
                    "label": "目录",
                    "value": "/data/inbound/medical",
                  },
                  {
                    "label": "认证方式",
                    "value": "私钥 + 口令",
                  },
                  {
                    "label": "连接超时",
                    "value": "15s / 重试 3 次",
                  },
                ],
              },
            ],
          },
        ],
      },
    ],
  },
  "file-tasks": {
    "id": "file-tasks",
    "title": "交换任务",
    "subtitle": "任务列表支持按业务分组筛选与周期配置",
    "description": "任务列表支持按业务分组筛选与周期配置",
    "breadcrumbs": [
      "业务代理",
      "文件传输",
      "交换任务",
    ],
    "tags": [
      "业务代理",
      "文件传输",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "任务数",
        "value": "24",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "运行中",
        "value": "18",
        "delta": "+1",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "已暂停",
        "value": "4",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "失败重试",
        "value": "2",
        "delta": "+1",
        "tone": "warning",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "交换任务页管理源资源到目标资源的文件交换任务。",
      "支持按业务分组筛选、批量启停和任务模板复制。",
      "任务支持扫描周期、重试次数和失败重试间隔配置。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "tree",
            "title": "业务分组与任务筛选",
            "description": "按业务分组查看文件交换任务。",
            "nodes": [
              {
                "label": "政务共享平台",
                "meta": "8 个文件任务",
                "tags": [
                  "归档",
                  "共享",
                ],
                "children": [
                  {
                    "label": "文书归档同步",
                    "meta": "每 5 分钟",
                  },
                  {
                    "label": "证照包投递",
                    "meta": "目录监听",
                  },
                ],
              },
              {
                "label": "医保专网",
                "meta": "4 个文件任务",
                "tags": [
                  "高优先级",
                ],
                "children": [
                  {
                    "label": "病历批量推送",
                    "meta": "定时轮询",
                  },
                  {
                    "label": "结算文件回传",
                    "meta": "到达触发",
                  },
                ],
              },
            ],
          },
          {
            "type": "table",
            "title": "交换任务",
            "description": "展示源资源、目标资源、周期和任务控制参数。",
            "columns": [
              {
                "key": "task",
                "label": "任务",
              },
              {
                "key": "source",
                "label": "源资源",
              },
              {
                "key": "target",
                "label": "目标资源",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "task": "病历批量推送",
                "source": "医保 SFTP 源站",
                "target": "卫健委 SMB 归档",
                "state": {
                  "text": "运行中",
                  "tone": "positive",
                },
              },
              {
                "task": "文书归档同步",
                "source": "政务归档 SMB",
                "target": "档案中心 NFS",
                "state": {
                  "text": "待人工确认",
                  "tone": "warning",
                },
              },
              {
                "task": "结算文件回传",
                "source": "财政 FTP",
                "target": "医保 SFTP",
                "state": {
                  "text": "重试中",
                  "tone": "accent",
                },
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "timeline",
            "title": "任务调度时间线",
            "description": "周期、监听、重试和人工处理链路。",
            "events": [
              {
                "time": "08:00",
                "title": "病历批量推送",
                "detail": "扫描新文件并建立传输队列。",
                "tone": "accent",
              },
              {
                "time": "10:18",
                "title": "文书归档同步",
                "detail": "目标端目录锁定，转入人工处理。",
                "tone": "warning",
              },
              {
                "time": "17:42",
                "title": "结算文件回传",
                "detail": "第 2 次重试后传输成功。",
                "tone": "positive",
              },
            ],
          },
        ],
      },
    ],
  },
  "file-rules": {
    "id": "file-rules",
    "title": "处理规则",
    "subtitle": "源端与目标端落地动作及异常处理",
    "description": "源端与目标端落地动作及异常处理",
    "breadcrumbs": [
      "业务代理",
      "文件传输",
      "处理规则",
    ],
    "tags": [
      "业务代理",
      "文件传输",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "源端规则",
        "value": "24",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "目标端规则",
        "value": "24",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "异常处理",
        "value": "12",
        "delta": "+1",
        "tone": "warning",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "冲突策略",
        "value": "6",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
    ],
    "highlights": [
      "处理规则页管理源端处理、目标端落地和异常处理策略。",
      "源端支持保留、删除、移动到备份目录等动作。",
      "目标端支持覆盖、跳过、冲突改名和按日期分目录。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "matrix",
            "title": "处理规则矩阵",
            "description": "同时展示源端处理、目标端落地和异常处理。",
            "columns": [
              "源端",
              "目标端",
              "异常处理",
            ],
            "rows": [
              {
                "label": "病历批量推送",
                "values": [
                  {
                    "text": "备份",
                    "tone": "positive",
                  },
                  {
                    "text": "原名落地",
                    "tone": "accent",
                  },
                  {
                    "text": "不完整等待",
                    "tone": "warning",
                  },
                ],
              },
              {
                "label": "文书归档同步",
                "values": [
                  {
                    "text": "删除原文件",
                    "tone": "warning",
                  },
                  {
                    "text": "按日期分目录",
                    "tone": "positive",
                  },
                  {
                    "text": "失败重试",
                    "tone": "accent",
                  },
                ],
              },
              {
                "label": "结算文件回传",
                "values": [
                  {
                    "text": "保留",
                    "tone": "positive",
                  },
                  {
                    "text": "冲突改名",
                    "tone": "accent",
                  },
                  {
                    "text": "告警升级",
                    "tone": "warning",
                  },
                ],
              },
            ],
          },
          {
            "type": "form",
            "title": "规则配置草图",
            "description": "源端、目标端和异常策略字段分组展示。",
            "groups": [
              {
                "title": "当前任务规则",
                "fields": [
                  {
                    "label": "源端处理",
                    "value": "移动到备份目录",
                  },
                  {
                    "label": "目标端处理",
                    "value": "按日期分目录",
                  },
                  {
                    "label": "重复文件",
                    "value": "跳过并留痕",
                  },
                  {
                    "label": "失败重试",
                    "value": "5 次 / 10 分钟间隔",
                  },
                ],
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "log-stream",
            "title": "异常处理日志",
            "description": "展示静默时间、文件锁和落地失败等异常。",
            "entries": [
              {
                "time": "11:03:18",
                "level": "WARN",
                "message": "文书归档同步检测到文件仍被占用，已等待 30 秒。",
                "tone": "warning",
              },
              {
                "time": "14:16:04",
                "level": "INFO",
                "message": "结算文件回传命中重复文件跳过策略。",
                "tone": "accent",
              },
              {
                "time": "17:22:36",
                "level": "INFO",
                "message": "病历批量推送源端备份完成。",
                "tone": "positive",
              },
            ],
          },
        ],
      },
    ],
  },
  "file-security": {
    "id": "file-security",
    "title": "安全控制",
    "subtitle": "文件类型、内容检查与安全模板引用",
    "description": "文件类型、内容检查与安全模板引用",
    "breadcrumbs": [
      "业务代理",
      "文件传输",
      "安全控制",
    ],
    "tags": [
      "业务代理",
      "文件传输",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "类型检查",
        "value": "18",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "内容检查",
        "value": "14",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "命令控制",
        "value": "8",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "命中率",
        "value": "8.6%",
        "delta": "+0.4%",
        "tone": "accent",
        "sparkline": [
          88,
          89,
          90,
          91,
          92,
          93,
          94,
          95,
        ],
      },
    ],
    "highlights": [
      "安全控制页管理文件类型检查、内容检查和受控FTP命令控制。",
      "类型检查覆盖扩展名、MIME类型和真实类型识别。",
      "内容检查支持关键字、正则和敏感字典，可引用安全模板。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "matrix",
            "title": "文件安全控制矩阵",
            "description": "把类型检查、内容检查和命令控制讲成统一能力。",
            "columns": [
              "类型检查",
              "内容检查",
              "命令控制",
            ],
            "rows": [
              {
                "label": "医保模板",
                "values": [
                  {
                    "text": "扩展名 + MIME",
                    "tone": "positive",
                  },
                  {
                    "text": "敏感词 + 正则",
                    "tone": "warning",
                  },
                  {
                    "text": "受控",
                    "tone": "accent",
                  },
                ],
              },
              {
                "label": "政务共享模板",
                "values": [
                  {
                    "text": "真实类型识别",
                    "tone": "positive",
                  },
                  {
                    "text": "关键字",
                    "tone": "accent",
                  },
                  {
                    "text": "受控",
                    "tone": "accent",
                  },
                ],
              },
              {
                "label": "归档模板",
                "values": [
                  {
                    "text": "压缩包检查",
                    "tone": "warning",
                  },
                  {
                    "text": "恶意内容检测",
                    "tone": "warning",
                  },
                  {
                    "text": "只读",
                    "tone": "positive",
                  },
                ],
              },
            ],
          },
          {
            "type": "table",
            "title": "安全模板引用",
            "description": "文件任务引用统一安全模板。",
            "columns": [
              {
                "key": "task",
                "label": "任务",
              },
              {
                "key": "template",
                "label": "模板",
              },
              {
                "key": "action",
                "label": "动作",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "task": "病历批量推送",
                "template": "文件传输安全模板 / 医保标准",
                "action": "阻断并告警",
                "state": {
                  "text": "启用",
                  "tone": "positive",
                },
              },
              {
                "task": "文书归档同步",
                "template": "文件传输安全模板 / 归档标准",
                "action": "检测后放行",
                "state": {
                  "text": "启用",
                  "tone": "positive",
                },
              },
              {
                "task": "结算文件回传",
                "template": "文件传输安全模板 / 金融外联",
                "action": "人工复核",
                "state": {
                  "text": "待审批",
                  "tone": "warning",
                },
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "log-stream",
            "title": "命中与阻断事件",
            "description": "突出文件类型和内容检查的审计留痕。",
            "entries": [
              {
                "time": "09:42:11",
                "level": "WARN",
                "message": "检测到可执行文件扩展名，任务“病历批量推送”已阻断。",
                "tone": "warning",
              },
              {
                "time": "14:08:56",
                "level": "INFO",
                "message": "政务共享任务命中关键字模板，已留痕后放行。",
                "tone": "accent",
              },
              {
                "time": "18:27:05",
                "level": "INFO",
                "message": "金融外联模板更新已同步到备节点。",
                "tone": "positive",
              },
            ],
          },
        ],
      },
    ],
  },
  "file-users": {
    "id": "file-users",
    "title": "内置服务与用户",
    "subtitle": "内置 FTP 用户、目录权限与账户管理",
    "description": "内置 FTP 用户、目录权限与账户管理",
    "breadcrumbs": [
      "业务代理",
      "文件传输",
      "内置服务与用户",
    ],
    "tags": [
      "业务代理",
      "文件传输",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "服务用户",
        "value": "36",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "活跃连接",
        "value": "128",
        "delta": "+8",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "锁定账号",
        "value": "2",
        "delta": "0",
        "tone": "warning",
        "sparkline": [
          50,
          50,
          50,
          50,
          50,
          50,
          50,
          50,
        ],
      },
      {
        "label": "目录权限",
        "value": "48",
        "delta": "+3",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "内置服务与用户页管理内置FTP/SFTP服务的用户和目录权限。",
      "支持账号锁定、密码重置和目录级读写执行权限控制。",
      "活跃连接监控帮助发现异常访问。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "table",
            "title": "内置服务与用户",
            "description": "内置 FTP/SFTP 服务、账户和目录权限管理。",
            "columns": [
              {
                "key": "user",
                "label": "账号",
              },
              {
                "key": "home",
                "label": "主目录",
              },
              {
                "key": "permission",
                "label": "权限",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "user": "ftp_medical_push",
                "home": "/ftp/medical/push",
                "permission": "读写",
                "state": {
                  "text": "启用",
                  "tone": "positive",
                },
              },
              {
                "user": "ftp_archive_sync",
                "home": "/ftp/archive/sync",
                "permission": "只写",
                "state": {
                  "text": "锁定中",
                  "tone": "warning",
                },
              },
              {
                "user": "ftp_finance_pull",
                "home": "/ftp/finance/pull",
                "permission": "只读",
                "state": {
                  "text": "启用",
                  "tone": "accent",
                },
              },
            ],
          },
          {
            "type": "form",
            "title": "目录权限与账户策略",
            "description": "内置服务、账户锁定和密码重置。",
            "groups": [
              {
                "title": "账户策略",
                "fields": [
                  {
                    "label": "密码周期",
                    "value": "90 天",
                  },
                  {
                    "label": "失败锁定",
                    "value": "5 次 / 30 分钟",
                  },
                  {
                    "label": "目录隔离",
                    "value": "按业务分组隔离",
                  },
                  {
                    "label": "重置方式",
                    "value": "管理员二次确认",
                  },
                ],
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "timeline",
            "title": "账户操作时间线",
            "description": "展示启停、锁定和密码重置留痕。",
            "events": [
              {
                "time": "08:46",
                "title": "ftp_medical_push 启用",
                "detail": "账户有效期延长 90 天。",
                "tone": "positive",
              },
              {
                "time": "11:32",
                "title": "ftp_archive_sync 锁定",
                "detail": "连续失败登录 5 次。",
                "tone": "warning",
              },
              {
                "time": "17:18",
                "title": "ftp_finance_pull 重置密码",
                "detail": "管理员双人复核后生效。",
                "tone": "accent",
              },
            ],
          },
        ],
      },
    ],
  },
  "file-monitor": {
    "id": "file-monitor",
    "title": "运行监控",
    "subtitle": "任务状态、速率与失败文件数趋势",
    "description": "任务状态、速率与失败文件数趋势",
    "breadcrumbs": [
      "业务代理",
      "文件传输",
      "运行监控",
    ],
    "tags": [
      "业务代理",
      "文件传输",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "文件数/秒",
        "value": "142",
        "delta": "+12",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "带宽",
        "value": "86MB/s",
        "delta": "+4",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "失败文件",
        "value": "7",
        "delta": "-2",
        "tone": "warning",
        "sparkline": [
          69,
          62,
          58,
          54,
          49,
          41,
          38,
          32,
        ],
      },
      {
        "label": "待人工",
        "value": "3",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
    ],
    "highlights": [
      "文件传输运行页展示任务运行状态、传输速率和失败文件。",
      "文件数/秒和带宽利用率是传输效率的核心指标。",
      "失败文件可直接查看失败原因并触发重试。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "line-chart",
            "title": "任务运行趋势",
            "description": "同时观察文件数/秒、带宽利用率和失败文件数。",
            "labels": [
              "00",
              "03",
              "06",
              "09",
              "12",
              "15",
              "18",
              "21",
            ],
            "series": [
              {
                "name": "文件数/秒",
                "color": "#1858cc",
                "values": [
                  12,
                  18,
                  21,
                  28,
                  36,
                  44,
                  41,
                  37,
                ],
              },
              {
                "name": "带宽利用率",
                "color": "#12b76a",
                "values": [
                  18,
                  24,
                  28,
                  35,
                  42,
                  48,
                  46,
                  43,
                ],
              },
              {
                "name": "失败文件数",
                "color": "#d92d20",
                "values": [
                  9,
                  8,
                  7,
                  6,
                  6,
                  5,
                  4,
                  4,
                ],
              },
            ],
          },
          {
            "type": "table",
            "title": "任务状态",
            "description": "按运行中、暂停、失败重试和待人工处理分类。",
            "columns": [
              {
                "key": "task",
                "label": "任务",
              },
              {
                "key": "speed",
                "label": "当前速率",
              },
              {
                "key": "failures",
                "label": "失败文件",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "task": "病历批量推送",
                "speed": "42 文件/秒",
                "failures": "0",
                "state": {
                  "text": "运行中",
                  "tone": "positive",
                },
              },
              {
                "task": "文书归档同步",
                "speed": "0",
                "failures": "3",
                "state": {
                  "text": "待人工处理",
                  "tone": "warning",
                },
              },
              {
                "task": "结算文件回传",
                "speed": "12 文件/秒",
                "failures": "1",
                "state": {
                  "text": "失败重试中",
                  "tone": "accent",
                },
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "log-stream",
            "title": "文件运行日志",
            "description": "突出任务状态、速率和失败数等监控信息。",
            "entries": [
              {
                "time": "09:18:02",
                "level": "INFO",
                "message": "病历批量推送吞吐提升至 42 文件/秒。",
                "tone": "positive",
              },
              {
                "time": "13:12:56",
                "level": "WARN",
                "message": "文书归档同步失败文件达到 3 个，进入人工处理。",
                "tone": "warning",
              },
              {
                "time": "18:05:28",
                "level": "INFO",
                "message": "结算文件回传第 2 次重试成功。",
                "tone": "accent",
              },
            ],
          },
        ],
      },
    ],
  },
  "db-resources": {
    "id": "db-resources",
    "title": "资源与入口",
    "subtitle": "MySQL、PG、Oracle、达梦等资源管理",
    "description": "MySQL、PG、Oracle、达梦等资源管理",
    "breadcrumbs": [
      "业务代理",
      "数据库代理",
      "资源与入口",
    ],
    "tags": [
      "业务代理",
      "数据库代理",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "数据库实例",
        "value": "28",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "MySQL",
        "value": "12",
        "delta": "0",
        "tone": "positive",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "PostgreSQL",
        "value": "8",
        "delta": "+1",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "国产库",
        "value": "8",
        "delta": "+1",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "资源与入口页管理MySQL、PostgreSQL、Oracle、达梦、人大金仓等数据库资源。",
      "每个实例配置监听地址、端口、代理入口和认证方式。",
      "MySQL支持双向证书认证，支持证书到期预警。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "inventory",
            "title": "数据库资源对象",
            "description": "覆盖 MySQL、PG、Oracle 和国产数据库资源。",
            "items": [
              {
                "title": "his_mysql_core",
                "meta": "MySQL / 双向证书",
                "tags": [
                  "医保",
                  "生产",
                ],
                "tone": "positive",
              },
              {
                "title": "finance_pg_report",
                "meta": "PostgreSQL / 用户映射",
                "tags": [
                  "财政",
                  "审计",
                ],
                "tone": "accent",
              },
              {
                "title": "archive_dm",
                "meta": "达梦 / 集群地址",
                "tags": [
                  "国产化",
                  "归档",
                ],
                "tone": "warning",
              },
            ],
          },
          {
            "type": "form",
            "title": "代理入口与监听",
            "description": "展示主机、端口、实例、代理入口与监听方式。",
            "groups": [
              {
                "title": "监听配置",
                "fields": [
                  {
                    "label": "监听地址",
                    "value": "10.20.1.18",
                  },
                  {
                    "label": "监听端口",
                    "value": "3306 / 5432",
                  },
                  {
                    "label": "工作时间窗",
                    "value": "07:00 - 21:00",
                  },
                  {
                    "label": "认证能力",
                    "value": "MySQL 双向证书认证",
                  },
                ],
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "table",
            "title": "数据库接入清单",
            "description": "对象、入口、认证和状态同屏展示。",
            "columns": [
              {
                "key": "resource",
                "label": "资源",
              },
              {
                "key": "type",
                "label": "类型",
              },
              {
                "key": "entry",
                "label": "代理入口",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "resource": "his_mysql_core",
                "type": "MySQL",
                "entry": "10.20.1.18:3306",
                "state": {
                  "text": "可用",
                  "tone": "positive",
                },
              },
              {
                "resource": "finance_pg_report",
                "type": "PostgreSQL",
                "entry": "10.20.3.11:5432",
                "state": {
                  "text": "可用",
                  "tone": "positive",
                },
              },
              {
                "resource": "archive_dm",
                "type": "达梦",
                "entry": "10.20.8.22:5236",
                "state": {
                  "text": "观察中",
                  "tone": "warning",
                },
              },
            ],
          },
        ],
      },
    ],
  },
  "db-access": {
    "id": "db-access",
    "title": "访问控制与 SQL 规则",
    "subtitle": "用户、表列权限与 SQL 风险规则",
    "description": "用户、表列权限与 SQL 风险规则",
    "breadcrumbs": [
      "业务代理",
      "数据库代理",
      "访问控制与 SQL 规则",
    ],
    "tags": [
      "业务代理",
      "数据库代理",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "访问规则",
        "value": "86",
        "delta": "+4",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "SQL风险规则",
        "value": "42",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "阻断率",
        "value": "1.8%",
        "delta": "-0.2%",
        "tone": "positive",
        "sparkline": [
          95,
          94,
          93,
          92,
          91,
          90,
          89,
          88,
        ],
      },
      {
        "label": "告警率",
        "value": "4.2%",
        "delta": "-0.3%",
        "tone": "accent",
        "sparkline": [
          95,
          94,
          93,
          92,
          91,
          90,
          89,
          88,
        ],
      },
    ],
    "highlights": [
      "访问控制与SQL规则页管理实例级、用户级、库表列级访问控制。",
      "SQL风险规则覆盖全表扫描、越权访问、高危DDL和注入特征。",
      "支持学习模式、告警模式和阻断模式切换。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "matrix",
            "title": "访问控制与 SQL 风险",
            "description": "覆盖实例、用户、表列权限和 SQL 风险规则。",
            "columns": [
              "放行",
              "阻断",
              "告警",
            ],
            "rows": [
              {
                "label": "DML 访问",
                "values": [
                  {
                    "text": "支持",
                    "tone": "positive",
                  },
                  {
                    "text": "支持",
                    "tone": "warning",
                  },
                  {
                    "text": "支持",
                    "tone": "accent",
                  },
                ],
              },
              {
                "label": "高危 DDL",
                "values": [
                  {
                    "text": "不建议",
                    "tone": "warning",
                  },
                  {
                    "text": "默认",
                    "tone": "positive",
                  },
                  {
                    "text": "支持",
                    "tone": "accent",
                  },
                ],
              },
              {
                "label": "越权访问",
                "values": [
                  {
                    "text": "不允许",
                    "tone": "warning",
                  },
                  {
                    "text": "默认",
                    "tone": "positive",
                  },
                  {
                    "text": "支持",
                    "tone": "accent",
                  },
                ],
              },
            ],
          },
          {
            "type": "table",
            "title": "SQL 风险规则",
            "description": "重点展示白名单、黑名单、正则和高危函数识别。",
            "columns": [
              {
                "key": "rule",
                "label": "规则",
              },
              {
                "key": "scope",
                "label": "范围",
              },
              {
                "key": "action",
                "label": "动作",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "rule": "DROP TABLE 阻断",
                "scope": "核心账务库",
                "action": "阻断",
                "state": {
                  "text": "启用",
                  "tone": "positive",
                },
              },
              {
                "rule": "大结果集告警",
                "scope": "查询类接口",
                "action": "告警",
                "state": {
                  "text": "启用",
                  "tone": "accent",
                },
              },
              {
                "rule": "共享账号异常时段",
                "scope": "全库",
                "action": "告警 + 审批",
                "state": {
                  "text": "启用",
                  "tone": "warning",
                },
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "log-stream",
            "title": "高风险 SQL 事件",
            "description": "识别与处置逻辑表格展示。",
            "entries": [
              {
                "time": "10:12:22",
                "level": "WARN",
                "message": "检测到 DROP TABLE 语句，已阻断并告警。",
                "tone": "warning",
              },
              {
                "time": "13:20:09",
                "level": "INFO",
                "message": "大结果集查询已转离线任务。",
                "tone": "accent",
              },
              {
                "time": "17:54:31",
                "level": "INFO",
                "message": "越权访问规则命中后被拒绝。",
                "tone": "positive",
              },
            ],
          },
        ],
      },
    ],
  },
  "db-governance": {
    "id": "db-governance",
    "title": "结果治理与会话审计",
    "subtitle": "脱敏、返回行限制与会话录制能力",
    "description": "脱敏、返回行限制与会话录制能力",
    "breadcrumbs": [
      "业务代理",
      "数据库代理",
      "结果治理与会话审计",
    ],
    "tags": [
      "业务代理",
      "数据库代理",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "脱敏规则",
        "value": "24",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "返回行限制",
        "value": "18",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "会话录制",
        "value": "已启用",
        "delta": "—",
        "tone": "positive",
        "sparkline": [
          50,
          50,
          50,
          50,
          50,
          50,
          50,
          50,
        ],
      },
      {
        "label": "慢SQL",
        "value": "12",
        "delta": "-3",
        "tone": "warning",
        "sparkline": [
          69,
          62,
          58,
          54,
          49,
          41,
          38,
          32,
        ],
      },
    ],
    "highlights": [
      "结果治理与会话审计页管理查询结果脱敏、返回行限制和会话录制。",
      "脱敏支持列级脱敏、字段替换和查询结果水印。",
      "会话录制支持回放、原始SQL审计和慢SQL审计。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "matrix",
            "title": "结果治理能力",
            "description": "把脱敏、返回行限制、导出审批和会话录制放在一页。",
            "columns": [
              "脱敏",
              "结果限制",
              "会话录制",
            ],
            "rows": [
              {
                "label": "账务查询",
                "values": [
                  {
                    "text": "手机号脱敏",
                    "tone": "accent",
                  },
                  {
                    "text": "5000 行",
                    "tone": "warning",
                  },
                  {
                    "text": "开启",
                    "tone": "positive",
                  },
                ],
              },
              {
                "label": "病例查询",
                "values": [
                  {
                    "text": "身份证脱敏",
                    "tone": "accent",
                  },
                  {
                    "text": "1000 行",
                    "tone": "warning",
                  },
                  {
                    "text": "开启",
                    "tone": "positive",
                  },
                ],
              },
              {
                "label": "报表导出",
                "values": [
                  {
                    "text": "字段级",
                    "tone": "positive",
                  },
                  {
                    "text": "审批后放行",
                    "tone": "warning",
                  },
                  {
                    "text": "开启",
                    "tone": "positive",
                  },
                ],
              },
            ],
          },
          {
            "type": "table",
            "title": "会话审计清单",
            "description": "展示原始 SQL、归一化 SQL 和结果审计留痕。",
            "columns": [
              {
                "key": "session",
                "label": "会话",
              },
              {
                "key": "user",
                "label": "账号",
              },
              {
                "key": "sql",
                "label": "SQL 摘要",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "session": "db-1091",
                "user": "app_his",
                "sql": "select * from medical_record",
                "state": {
                  "text": "已脱敏",
                  "tone": "accent",
                },
              },
              {
                "session": "db-1098",
                "user": "report_fin",
                "sql": "copy to export",
                "state": {
                  "text": "待审批",
                  "tone": "warning",
                },
              },
              {
                "session": "db-1106",
                "user": "ops_query",
                "sql": "select count(*)",
                "state": {
                  "text": "正常",
                  "tone": "positive",
                },
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "status-list",
            "title": "治理状态",
            "description": "突出大结果集限制、脱敏和审批状态。",
            "items": [
              {
                "label": "脱敏规则",
                "value": "14 条",
                "tone": "accent",
                "meta": "覆盖手机号 / 身份证 / 卡号",
              },
              {
                "label": "导出审批",
                "value": "2 单待审",
                "tone": "warning",
                "meta": "涉及核心账务数据",
              },
              {
                "label": "会话录制",
                "value": "开启",
                "tone": "positive",
                "meta": "录制成功率 99.8%",
              },
            ],
          },
        ],
      },
    ],
  },
  "db-sync": {
    "id": "db-sync",
    "title": "同步与映射",
    "subtitle": "源表目标表映射与全量增量同步",
    "description": "源表目标表映射与全量增量同步",
    "breadcrumbs": [
      "业务代理",
      "数据库代理",
      "同步与映射",
    ],
    "tags": [
      "业务代理",
      "数据库代理",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "同步服务",
        "value": "8",
        "delta": "0",
        "tone": "accent",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "同步任务",
        "value": "24",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "冲突数",
        "value": "3",
        "delta": "-1",
        "tone": "warning",
        "sparkline": [
          69,
          62,
          58,
          54,
          49,
          41,
          38,
          32,
        ],
      },
      {
        "label": "延迟",
        "value": "2.1s",
        "delta": "-0.4s",
        "tone": "positive",
        "sparkline": [
          69,
          62,
          58,
          54,
          49,
          41,
          38,
          32,
        ],
      },
    ],
    "highlights": [
      "同步与映射页管理源表目标表映射、全量/增量同步和字段映射。",
      "支持结构比对、字段变化检测和同步中断点恢复。",
      "冲突处理支持覆盖、跳过、改名和转待审。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "tree",
            "title": "同步对象与映射",
            "description": "从业务分组到源表目标表映射逐层查看。",
            "nodes": [
              {
                "label": "医保专网",
                "meta": "6 组映射 / 2 个同步任务",
                "tags": [
                  "全量 + 增量",
                ],
                "children": [
                  {
                    "label": "his.patient -> archive.patient",
                    "meta": "增量同步",
                  },
                  {
                    "label": "his.visit -> archive.visit",
                    "meta": "全量同步",
                  },
                ],
              },
              {
                "label": "财政结算中心",
                "meta": "3 组映射 / 1 个同步任务",
                "tags": [
                  "批量同步",
                ],
                "children": [
                  {
                    "label": "finance.bill -> report.bill",
                    "meta": "每日 22:00",
                  },
                ],
              },
            ],
          },
          {
            "type": "table",
            "title": "同步与映射清单",
            "description": "全量、增量、冲突和映射关系。",
            "columns": [
              {
                "key": "mapping",
                "label": "映射",
              },
              {
                "key": "mode",
                "label": "模式",
              },
              {
                "key": "lag",
                "label": "延迟",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "mapping": "his.patient -> archive.patient",
                "mode": "增量",
                "lag": "2.1s",
                "state": {
                  "text": "正常",
                  "tone": "positive",
                },
              },
              {
                "mapping": "his.visit -> archive.visit",
                "mode": "全量",
                "lag": "任务窗口内",
                "state": {
                  "text": "运行中",
                  "tone": "accent",
                },
              },
              {
                "mapping": "finance.bill -> report.bill",
                "mode": "批量",
                "lag": "待执行",
                "state": {
                  "text": "计划中",
                  "tone": "warning",
                },
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "timeline",
            "title": "同步时间线",
            "description": "强调开始结束时间、冲突数和结果。",
            "events": [
              {
                "time": "01:05",
                "title": "his.visit 全量同步启动",
                "detail": "预计 14 分钟完成。",
                "tone": "accent",
              },
              {
                "time": "01:19",
                "title": "his.visit 全量同步完成",
                "detail": "冲突 0，已生成审计记录。",
                "tone": "positive",
              },
              {
                "time": "22:00",
                "title": "finance.bill 批量任务计划",
                "detail": "等待维护窗口开始。",
                "tone": "warning",
              },
            ],
          },
        ],
      },
    ],
  },
  "db-monitor": {
    "id": "db-monitor",
    "title": "运行监控",
    "subtitle": "连接状态、活跃会话与慢 SQL 监控",
    "description": "连接状态、活跃会话与慢 SQL 监控",
    "breadcrumbs": [
      "业务代理",
      "数据库代理",
      "运行监控",
    ],
    "tags": [
      "业务代理",
      "数据库代理",
    ],
    "status": "运行正常 · 代理服务在线",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "活跃会话",
        "value": "186",
        "delta": "+12",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "SQL TPS",
        "value": "2.4k",
        "delta": "+0.2k",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "平均时延",
        "value": "8ms",
        "delta": "-1ms",
        "tone": "positive",
        "sparkline": [
          69,
          62,
          58,
          54,
          49,
          41,
          38,
          32,
        ],
      },
      {
        "label": "目标不可达",
        "value": "1",
        "delta": "0",
        "tone": "warning",
        "sparkline": [
          50,
          50,
          50,
          50,
          50,
          50,
          50,
          50,
        ],
      },
    ],
    "highlights": [
      "数据库运行页展示连接状态、活跃会话、SQL执行统计和目标可达性。",
      "活跃会话和SQL TPS是数据库代理运行的核心指标。",
      "目标不可达和慢SQL可直接触发诊断。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "line-chart",
            "title": "数据库运行趋势",
            "description": "观察活跃会话、目标可达性和慢 SQL 变化。",
            "labels": [
              "00",
              "03",
              "06",
              "09",
              "12",
              "15",
              "18",
              "21",
            ],
            "series": [
              {
                "name": "活跃会话",
                "color": "#1858cc",
                "values": [
                  52,
                  58,
                  61,
                  68,
                  74,
                  79,
                  72,
                  66,
                ],
              },
              {
                "name": "慢 SQL",
                "color": "#d92d20",
                "values": [
                  8,
                  7,
                  6,
                  6,
                  5,
                  4,
                  4,
                  3,
                ],
              },
              {
                "name": "目标可达性",
                "color": "#12b76a",
                "values": [
                  95,
                  96,
                  97,
                  97,
                  98,
                  99,
                  99,
                  99,
                ],
              },
            ],
          },
          {
            "type": "table",
            "title": "慢 SQL 与活跃会话",
            "description": "把连接状态、活跃会话和慢 SQL 聚合展示。",
            "columns": [
              {
                "key": "instance",
                "label": "实例",
              },
              {
                "key": "sessions",
                "label": "活跃会话",
              },
              {
                "key": "slow",
                "label": "慢 SQL",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "instance": "his_mysql_core",
                "sessions": "148",
                "slow": "2",
                "state": {
                  "text": "可用",
                  "tone": "positive",
                },
              },
              {
                "instance": "finance_pg_report",
                "sessions": "92",
                "slow": "1",
                "state": {
                  "text": "可用",
                  "tone": "positive",
                },
              },
              {
                "instance": "archive_dm",
                "sessions": "36",
                "slow": "4",
                "state": {
                  "text": "需观察",
                  "tone": "warning",
                },
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "log-stream",
            "title": "数据库运行日志",
            "description": "展示目标不可达、慢 SQL 和登录测试结果。",
            "entries": [
              {
                "time": "09:14:21",
                "level": "INFO",
                "message": "his_mysql_core 登录测试通过。",
                "tone": "positive",
              },
              {
                "time": "13:26:42",
                "level": "WARN",
                "message": "archive_dm 慢 SQL 达到 4 条，建议回放会话。",
                "tone": "warning",
              },
              {
                "time": "18:40:15",
                "level": "INFO",
                "message": "finance_pg_report 目标可达性恢复到 99%。",
                "tone": "accent",
              },
            ],
          },
        ],
      },
    ],
  },
  "security-api-template": {
    "id": "security-api-template",
    "title": "API 安全模板",
    "subtitle": "鉴权、限流、注入防护与内容过滤模板",
    "description": "鉴权、限流、注入防护与内容过滤模板",
    "breadcrumbs": [
      "安全策略",
      "安全模板",
      "API 安全模板",
    ],
    "tags": [
      "安全策略",
      "安全模板",
    ],
    "status": "运行正常 · 策略已生效",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "鉴权模板",
        "value": "12",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "限流模板",
        "value": "8",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "注入防护",
        "value": "6",
        "delta": "0",
        "tone": "positive",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "内容过滤",
        "value": "10",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "API安全模板页管理鉴权、限流、注入防护和内容过滤的可复用模板。",
      "模板被API服务引用后，修改模板可批量生效。",
      "限流支持固定窗口、漏桶和并发连接数三种模式。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "matrix",
            "title": "API 安全模板能力",
            "description": "把鉴权、限流、注入防护和内容过滤组合成模板。",
            "columns": [
              "鉴权",
              "限流",
              "内容过滤",
            ],
            "rows": [
              {
                "label": "医保标准模板",
                "values": [
                  {
                    "text": "JWT + 证书",
                    "tone": "positive",
                  },
                  {
                    "text": "峰值限流",
                    "tone": "accent",
                  },
                  {
                    "text": "敏感词过滤",
                    "tone": "warning",
                  },
                ],
              },
              {
                "label": "政务开放模板",
                "values": [
                  {
                    "text": "OAuth2",
                    "tone": "positive",
                  },
                  {
                    "text": "QPS 配额",
                    "tone": "accent",
                  },
                  {
                    "text": "Schema 校验",
                    "tone": "positive",
                  },
                ],
              },
              {
                "label": "测试外联模板",
                "values": [
                  {
                    "text": "API Key",
                    "tone": "warning",
                  },
                  {
                    "text": "连接限流",
                    "tone": "accent",
                  },
                  {
                    "text": "关键字过滤",
                    "tone": "warning",
                  },
                ],
              },
            ],
          },
          {
            "type": "table",
            "title": "模板清单",
            "description": "模板对象、引用范围和版本状态。",
            "columns": [
              {
                "key": "name",
                "label": "模板",
              },
              {
                "key": "scope",
                "label": "引用范围",
              },
              {
                "key": "version",
                "label": "版本",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "name": "医保标准模板",
                "scope": "9 个 API 服务",
                "version": "v6",
                "state": {
                  "text": "已发布",
                  "tone": "positive",
                },
              },
              {
                "name": "政务开放模板",
                "scope": "12 个 API 服务",
                "version": "v3",
                "state": {
                  "text": "已发布",
                  "tone": "positive",
                },
              },
              {
                "name": "测试外联模板",
                "scope": "3 个 API 服务",
                "version": "v2",
                "state": {
                  "text": "待审批",
                  "tone": "warning",
                },
              },
            ],
          },
        ],
      },
    ],
  },
  "security-file-template": {
    "id": "security-file-template",
    "title": "文件传输安全模板",
    "subtitle": "文件类型、内容检查与命令控制模板",
    "description": "文件类型、内容检查与命令控制模板",
    "breadcrumbs": [
      "安全策略",
      "安全模板",
      "文件传输安全模板",
    ],
    "tags": [
      "安全策略",
      "安全模板",
    ],
    "status": "运行正常 · 策略已生效",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "文件类型模板",
        "value": "6",
        "delta": "0",
        "tone": "accent",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "内容检查模板",
        "value": "8",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "命令控制模板",
        "value": "4",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "引用数",
        "value": "42",
        "delta": "+3",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "文件传输安全模板管理文件类型检查、内容检查和命令控制的可复用模板。",
      "模板被文件任务引用后，修改可批量生效。",
      "真实类型识别和恶意代码检测是高安全场景的关键能力。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "matrix",
            "title": "文件模板能力",
            "description": "组合文件类型、内容检查和命令控制。",
            "columns": [
              "类型检查",
              "内容检查",
              "命令控制",
            ],
            "rows": [
              {
                "label": "医保文件模板",
                "values": [
                  {
                    "text": "真实类型识别",
                    "tone": "positive",
                  },
                  {
                    "text": "敏感词 + 正则",
                    "tone": "warning",
                  },
                  {
                    "text": "严格限制",
                    "tone": "accent",
                  },
                ],
              },
              {
                "label": "归档模板",
                "values": [
                  {
                    "text": "压缩包检查",
                    "tone": "warning",
                  },
                  {
                    "text": "关键字",
                    "tone": "accent",
                  },
                  {
                    "text": "只读",
                    "tone": "positive",
                  },
                ],
              },
              {
                "label": "共享模板",
                "values": [
                  {
                    "text": "扩展名 + MIME",
                    "tone": "positive",
                  },
                  {
                    "text": "恶意内容检测",
                    "tone": "warning",
                  },
                  {
                    "text": "受控",
                    "tone": "accent",
                  },
                ],
              },
            ],
          },
          {
            "type": "timeline",
            "title": "模板发布历史",
            "description": "模板迭代、审批和生效。",
            "events": [
              {
                "time": "04-10",
                "title": "医保文件模板升级",
                "detail": "补充宏文档检查。",
                "tone": "accent",
              },
              {
                "time": "04-12",
                "title": "归档模板修订",
                "detail": "新增压缩层级限制。",
                "tone": "warning",
              },
              {
                "time": "04-15",
                "title": "共享模板发布",
                "detail": "同步到备节点成功。",
                "tone": "positive",
              },
            ],
          },
        ],
      },
    ],
  },
  "security-db-template": {
    "id": "security-db-template",
    "title": "数据库安全模板",
    "subtitle": "SQL 风险规则、脱敏与访问控制模板",
    "description": "SQL 风险规则、脱敏与访问控制模板",
    "breadcrumbs": [
      "安全策略",
      "安全模板",
      "数据库安全模板",
    ],
    "tags": [
      "安全策略",
      "安全模板",
    ],
    "status": "运行正常 · 策略已生效",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "SQL风险模板",
        "value": "8",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "脱敏模板",
        "value": "6",
        "delta": "0",
        "tone": "accent",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "访问控制模板",
        "value": "10",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "引用数",
        "value": "36",
        "delta": "+2",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "数据库安全模板管理SQL风险规则、脱敏和访问控制的可复用模板。",
      "模板被数据库代理入口引用后，修改可批量生效。",
      "支持学习模式、告警模式和阻断模式。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "matrix",
            "title": "数据库模板能力",
            "description": "把 SQL 风险、脱敏和访问控制模板化。",
            "columns": [
              "SQL 风险",
              "脱敏",
              "访问控制",
            ],
            "rows": [
              {
                "label": "核心账务模板",
                "values": [
                  {
                    "text": "高危 DDL 阻断",
                    "tone": "warning",
                  },
                  {
                    "text": "字段级脱敏",
                    "tone": "accent",
                  },
                  {
                    "text": "表列权限",
                    "tone": "positive",
                  },
                ],
              },
              {
                "label": "报表查询模板",
                "values": [
                  {
                    "text": "大结果集限制",
                    "tone": "accent",
                  },
                  {
                    "text": "手机号脱敏",
                    "tone": "positive",
                  },
                  {
                    "text": "只读",
                    "tone": "positive",
                  },
                ],
              },
              {
                "label": "共享查询模板",
                "values": [
                  {
                    "text": "白名单 SQL",
                    "tone": "positive",
                  },
                  {
                    "text": "可选",
                    "tone": "neutral",
                  },
                  {
                    "text": "审批授权",
                    "tone": "warning",
                  },
                ],
              },
            ],
          },
          {
            "type": "table",
            "title": "模板引用关系",
            "description": "讲清模板与数据库代理对象的绑定方式。",
            "columns": [
              {
                "key": "template",
                "label": "模板",
              },
              {
                "key": "proxy",
                "label": "代理对象",
              },
              {
                "key": "action",
                "label": "默认动作",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "template": "核心账务模板",
                "proxy": "账务查询代理",
                "action": "阻断高危 SQL",
                "state": {
                  "text": "启用",
                  "tone": "positive",
                },
              },
              {
                "template": "报表查询模板",
                "proxy": "统计报表代理",
                "action": "脱敏 + 限制行数",
                "state": {
                  "text": "启用",
                  "tone": "accent",
                },
              },
              {
                "template": "共享查询模板",
                "proxy": "共享查询代理",
                "action": "审批授权",
                "state": {
                  "text": "待调整",
                  "tone": "warning",
                },
              },
            ],
          },
        ],
      },
    ],
  },
  "security-allow-deny": {
    "id": "security-allow-deny",
    "title": "黑白名单",
    "subtitle": "IP、域名、账号、证书名单统一管理",
    "description": "IP、域名、账号、证书名单统一管理",
    "breadcrumbs": [
      "安全策略",
      "统一安全对象",
      "黑白名单",
    ],
    "tags": [
      "安全策略",
      "统一安全对象",
    ],
    "status": "运行正常 · 策略已生效",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "IP名单",
        "value": "18",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "域名名单",
        "value": "12",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "账号名单",
        "value": "8",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "证书名单",
        "value": "6",
        "delta": "+1",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "黑白名单页管理IP、域名、账号和证书四种名单对象。",
      "名单被策略规则引用，支持批量导入和有效期设置。",
      "名单变更自动触发引用策略的重新评估。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "table",
            "title": "黑白名单",
            "description": "统一管理 IP、域名、账号和证书名单。",
            "columns": [
              {
                "key": "name",
                "label": "名单对象",
              },
              {
                "key": "type",
                "label": "类型",
              },
              {
                "key": "scope",
                "label": "引用范围",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "name": "医保专网 IP 白名单",
                "type": "IP",
                "scope": "API / 文件",
                "state": {
                  "text": "启用",
                  "tone": "positive",
                },
              },
              {
                "name": "测试域名黑名单",
                "type": "域名",
                "scope": "API",
                "state": {
                  "text": "启用",
                  "tone": "warning",
                },
              },
              {
                "name": "归档证书白名单",
                "type": "证书",
                "scope": "文件 / 审计",
                "state": {
                  "text": "启用",
                  "tone": "accent",
                },
              },
            ],
          },
          {
            "type": "log-stream",
            "title": "引用与命中",
            "description": "展示名单对象在不同模块中的命中情况。",
            "entries": [
              {
                "time": "10:02:19",
                "level": "INFO",
                "message": "医保专网 IP 白名单命中电子病历上报。",
                "tone": "positive",
              },
              {
                "time": "12:44:03",
                "level": "WARN",
                "message": "测试域名黑名单阻断 1 次 API 调用。",
                "tone": "warning",
              },
              {
                "time": "16:11:28",
                "level": "INFO",
                "message": "归档证书白名单被文件模板引用。",
                "tone": "accent",
              },
            ],
          },
        ],
      },
    ],
  },
  "security-dictionaries": {
    "id": "security-dictionaries",
    "title": "敏感字典",
    "subtitle": "关键字、正则与文件检查规则模板",
    "description": "关键字、正则与文件检查规则模板",
    "breadcrumbs": [
      "安全策略",
      "统一安全对象",
      "敏感字典",
    ],
    "tags": [
      "安全策略",
      "统一安全对象",
    ],
    "status": "运行正常 · 策略已生效",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "关键字字典",
        "value": "14",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "正则模板",
        "value": "8",
        "delta": "0",
        "tone": "accent",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "敏感字段",
        "value": "6",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "文件检查",
        "value": "4",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
    ],
    "highlights": [
      "敏感字典页管理关键字字典、正则模板、敏感字段模板和文件检查模板。",
      "字典被内容过滤规则和内容检查规则引用。",
      "支持字典测试和命中预览。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "table",
            "title": "敏感字典与模板",
            "description": "集中维护关键字、正则和文件检查模板。",
            "columns": [
              {
                "key": "name",
                "label": "对象",
              },
              {
                "key": "kind",
                "label": "类型",
              },
              {
                "key": "refs",
                "label": "引用数",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "name": "身份证号检测",
                "kind": "正则模板",
                "refs": "12",
                "state": {
                  "text": "启用",
                  "tone": "positive",
                },
              },
              {
                "name": "病案号字典",
                "kind": "关键字字典",
                "refs": "9",
                "state": {
                  "text": "启用",
                  "tone": "accent",
                },
              },
              {
                "name": "可执行文件检查",
                "kind": "文件模板",
                "refs": "6",
                "state": {
                  "text": "待升级",
                  "tone": "warning",
                },
              },
            ],
          },
          {
            "type": "bar-list",
            "title": "引用热度",
            "description": "看哪些敏感对象被多个模板共用。",
            "items": [
              {
                "label": "身份证号检测",
                "value": 12,
                "max": 20,
                "tone": "accent",
                "meta": "API / DB 双引用",
              },
              {
                "label": "病案号字典",
                "value": 9,
                "max": 20,
                "tone": "positive",
                "meta": "API / 文件",
              },
              {
                "label": "可执行文件检查",
                "value": 6,
                "max": 20,
                "tone": "warning",
                "meta": "文件模板",
              },
            ],
          },
        ],
      },
    ],
  },
  "security-identities": {
    "id": "security-identities",
    "title": "调用方身份",
    "subtitle": "用户、应用、API Key 与证书身份对象",
    "description": "用户、应用、API Key 与证书身份对象",
    "breadcrumbs": [
      "安全策略",
      "统一安全对象",
      "调用方身份",
    ],
    "tags": [
      "安全策略",
      "统一安全对象",
    ],
    "status": "运行正常 · 策略已生效",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "用户",
        "value": "48",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "应用",
        "value": "36",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "API Key",
        "value": "56",
        "delta": "+4",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "证书",
        "value": "24",
        "delta": "+2",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "调用方身份页管理用户、应用、API Key和证书四种身份对象。",
      "身份对象被鉴权规则和访问控制规则引用。",
      "支持身份到期预警和批量启停。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "inventory",
            "title": "调用方身份对象",
            "description": "统一管理用户、应用、API Key 和证书身份。",
            "items": [
              {
                "title": "医保前置网关",
                "meta": "客户端证书 + JWT",
                "tags": [
                  "应用",
                  "高安全",
                ],
                "tone": "positive",
              },
              {
                "title": "共享平台网关",
                "meta": "OAuth2 / OIDC",
                "tags": [
                  "应用",
                  "统一认证",
                ],
                "tone": "accent",
              },
              {
                "title": "测试外联账号",
                "meta": "API Key",
                "tags": [
                  "账号",
                  "限流",
                ],
                "tone": "warning",
              },
            ],
          },
          {
            "type": "timeline",
            "title": "身份对象变更",
            "description": "展示新增、绑定和失效留痕。",
            "events": [
              {
                "time": "09:30",
                "title": "新增医保前置网关",
                "detail": "绑定电子病历与结算 API。",
                "tone": "positive",
              },
              {
                "time": "14:20",
                "title": "共享平台网关更新",
                "detail": "同步 OIDC 配置。",
                "tone": "accent",
              },
              {
                "time": "18:03",
                "title": "测试外联账号降级",
                "detail": "限流策略已收紧。",
                "tone": "warning",
              },
            ],
          },
        ],
      },
    ],
  },
  "security-trust": {
    "id": "security-trust",
    "title": "证书信任链",
    "subtitle": "根证书、中间证书与服务端证书链",
    "description": "根证书、中间证书与服务端证书链",
    "breadcrumbs": [
      "安全策略",
      "统一安全对象",
      "证书信任链",
    ],
    "tags": [
      "安全策略",
      "统一安全对象",
    ],
    "status": "运行正常 · 策略已生效",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "根证书",
        "value": "4",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "中间证书",
        "value": "8",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "服务端证书",
        "value": "34",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "客户端证书",
        "value": "18",
        "delta": "+1",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "证书信任链页管理根证书、中间证书、服务端证书和客户端证书。",
      "证书链完整性校验确保TLS握手安全。",
      "证书到期预警和批量替换减少运维风险。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "inventory",
            "title": "证书信任链对象",
            "description": "根证书、中间证书与服务端证书集中维护。",
            "items": [
              {
                "title": "Root-CA-GOV",
                "meta": "根证书 / 2032-09-20",
                "tags": [
                  "根证书",
                ],
                "tone": "positive",
              },
              {
                "title": "GOV-INT-01",
                "meta": "中间证书 / 2028-06-12",
                "tags": [
                  "中间证书",
                ],
                "tone": "accent",
              },
              {
                "title": "EMR-SERVER",
                "meta": "服务端证书 / 2027-02-18",
                "tags": [
                  "服务端",
                  "业务",
                ],
                "tone": "warning",
              },
            ],
          },
          {
            "type": "table",
            "title": "信任链状态",
            "description": "导入、绑定、到期提醒和替换。",
            "columns": [
              {
                "key": "object",
                "label": "对象",
              },
              {
                "key": "kind",
                "label": "类型",
              },
              {
                "key": "expiry",
                "label": "到期日",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "object": "Root-CA-GOV",
                "kind": "根证书",
                "expiry": "2032-09-20",
                "state": {
                  "text": "稳定",
                  "tone": "positive",
                },
              },
              {
                "object": "GOV-INT-01",
                "kind": "中间证书",
                "expiry": "2028-06-12",
                "state": {
                  "text": "正常",
                  "tone": "positive",
                },
              },
              {
                "object": "EMR-SERVER",
                "kind": "服务端证书",
                "expiry": "2027-02-18",
                "state": {
                  "text": "需关注",
                  "tone": "warning",
                },
              },
            ],
          },
        ],
      },
    ],
  },
  "log-search": {
    "id": "log-search",
    "title": "统一日志检索",
    "subtitle": "跨模块日志查询、聚合分析与导出",
    "description": "跨模块日志查询、聚合分析与导出",
    "breadcrumbs": [
      "审计中心",
      "统一日志检索",
    ],
    "tags": [
      "审计中心",
      "审计中心",
    ],
    "status": "运行正常 · 审计日志正常采集",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "今日日志",
        "value": "2.4M",
        "delta": "+8%",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "查询耗时",
        "value": "120ms",
        "delta": "-8ms",
        "tone": "positive",
        "sparkline": [
          69,
          62,
          58,
          54,
          49,
          41,
          38,
          32,
        ],
      },
      {
        "label": "导出任务",
        "value": "3",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "存储占用",
        "value": "67%",
        "delta": "+2%",
        "tone": "warning",
        "sparkline": [
          88,
          89,
          90,
          91,
          92,
          93,
          94,
          95,
        ],
      },
    ],
    "highlights": [
      "统一日志检索支持跨模块组合查询，按时间、来源、目标、业务对象和风险级别筛选。",
      "查询结果支持导出、脱敏导出和审批留痕。",
      "存储占用监控帮助规划归档策略。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "tree",
            "title": "业务分组检索条件",
            "description": "统一日志检索支持按业务分组筛选。",
            "nodes": [
              {
                "label": "医保专网",
                "meta": "API / 数据库 / 文件",
                "tags": [
                  "高优先级",
                ],
                "children": [
                  {
                    "label": "电子病历上报",
                    "meta": "API",
                  },
                  {
                    "label": "账务查询代理",
                    "meta": "数据库",
                  },
                ],
              },
              {
                "label": "政务共享平台",
                "meta": "API / 文件",
                "tags": [
                  "共享",
                ],
                "children": [
                  {
                    "label": "统一身份认证",
                    "meta": "API",
                  },
                  {
                    "label": "文书归档同步",
                    "meta": "文件",
                  },
                ],
              },
            ],
          },
          {
            "type": "form",
            "title": "检索条件",
            "description": "时间范围、协议类型、来源目标、风险级别统一组合。",
            "groups": [
              {
                "title": "检索过滤",
                "fields": [
                  {
                    "label": "时间范围",
                    "value": "今天 00:00 - 当前",
                  },
                  {
                    "label": "协议类型",
                    "value": "HTTPS / SFTP / MySQL",
                  },
                  {
                    "label": "业务对象",
                    "value": "医保专网 / 电子病历上报",
                  },
                  {
                    "label": "风险级别",
                    "value": "高 + 中",
                  },
                ],
              },
            ],
          },
        ],
      },
      {
        "layout": "single",
        "widgets": [
          {
            "type": "table",
            "title": "检索结果",
            "description": "展示请求摘要、返回摘要、命中策略与操作结果。",
            "columns": [
              {
                "key": "time",
                "label": "时间",
              },
              {
                "key": "object",
                "label": "业务对象",
              },
              {
                "key": "policy",
                "label": "命中策略",
              },
              {
                "key": "result",
                "label": "结果",
              },
            ],
            "rows": [
              {
                "time": "09:18:02",
                "object": "电子病历上报",
                "policy": "医保标准模板 / Header 校验",
                "result": {
                  "text": "放行",
                  "tone": "positive",
                },
              },
              {
                "time": "11:42:18",
                "object": "文书归档同步",
                "policy": "归档文件模板 / 内容检查",
                "result": {
                  "text": "阻断",
                  "tone": "warning",
                },
              },
              {
                "time": "17:05:31",
                "object": "账务查询代理",
                "policy": "核心账务模板 / 脱敏",
                "result": {
                  "text": "治理后放行",
                  "tone": "accent",
                },
              },
            ],
          },
        ],
      },
    ],
  },
  "audit-special": {
    "id": "audit-special",
    "title": "专项审计",
    "subtitle": "API、文件与数据库专项访问审计",
    "description": "API、文件与数据库专项访问审计",
    "breadcrumbs": [
      "审计中心",
      "专项审计",
    ],
    "tags": [
      "审计中心",
      "审计中心",
    ],
    "status": "运行正常 · 审计日志正常采集",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "API审计",
        "value": "1.2M",
        "delta": "+6%",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "文件审计",
        "value": "860K",
        "delta": "+4%",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "数据库审计",
        "value": "340K",
        "delta": "+2%",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "其他审计",
        "value": "28K",
        "delta": "+1%",
        "tone": "neutral",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "专项审计按API、文件、数据库、邮件、消息队列和同步任务分页签展示。",
      "API审计记录Host/Path/Method、状态码和TLS信息。",
      "文件审计记录文件名、路径、校验值和处理动作。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "matrix",
            "title": "专项审计覆盖",
            "description": "按 API、文件和数据库区分审计关注点。",
            "columns": [
              "API",
              "文件",
              "数据库",
            ],
            "rows": [
              {
                "label": "对象维度",
                "values": [
                  {
                    "text": "Host/Path/Method",
                    "tone": "accent",
                  },
                  {
                    "text": "文件名/路径",
                    "tone": "accent",
                  },
                  {
                    "text": "账号/数据库",
                    "tone": "accent",
                  },
                ],
              },
              {
                "label": "安全维度",
                "values": [
                  {
                    "text": "TLS / 状态码",
                    "tone": "positive",
                  },
                  {
                    "text": "校验值 / 动作",
                    "tone": "warning",
                  },
                  {
                    "text": "SQL / 返回行数",
                    "tone": "warning",
                  },
                ],
              },
              {
                "label": "可导出性",
                "values": [
                  {
                    "text": "支持",
                    "tone": "positive",
                  },
                  {
                    "text": "支持",
                    "tone": "positive",
                  },
                  {
                    "text": "支持",
                    "tone": "positive",
                  },
                ],
              },
            ],
          },
          {
            "type": "table",
            "title": "专项审计样例",
            "description": "用分页签方式查看多模块审计详情。",
            "columns": [
              {
                "key": "module",
                "label": "模块",
              },
              {
                "key": "target",
                "label": "对象",
              },
              {
                "key": "field",
                "label": "关键字段",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "module": "API",
                "target": "电子病历上报",
                "field": "Host/Path/Method",
                "state": {
                  "text": "可审计",
                  "tone": "positive",
                },
              },
              {
                "module": "文件",
                "target": "文书归档同步",
                "field": "文件名/校验值",
                "state": {
                  "text": "可审计",
                  "tone": "positive",
                },
              },
              {
                "module": "数据库",
                "target": "账务查询代理",
                "field": "SQL / 返回行数",
                "state": {
                  "text": "可审计",
                  "tone": "positive",
                },
              },
            ],
          },
        ],
      },
    ],
  },
  "administration-audit": {
    "id": "administration-audit",
    "title": "管理审计",
    "subtitle": "管理员操作、配置变更与切换处置审计",
    "description": "管理员操作、配置变更与切换处置审计",
    "breadcrumbs": [
      "审计中心",
      "管理审计",
    ],
    "tags": [
      "审计中心",
      "审计中心",
    ],
    "status": "运行正常 · 审计日志正常采集",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "管理员操作",
        "value": "342",
        "delta": "+12%",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "配置变更",
        "value": "28",
        "delta": "-4",
        "tone": "positive",
        "sparkline": [
          69,
          62,
          58,
          54,
          49,
          41,
          38,
          32,
        ],
      },
      {
        "label": "切换记录",
        "value": "4",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "审批记录",
        "value": "16",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "管理审计页记录管理员操作、配置变更和主备切换的完整审计链。",
      "配置变更记录前值后值，支持差异对比。",
      "审批记录与双人复核确保关键操作安全。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "timeline",
            "title": "管理员操作与配置变更",
            "description": "突出操作人、对象、前值后值和审批流。",
            "events": [
              {
                "time": "09:18",
                "title": "新增 API 路由",
                "detail": "操作人 api_admin，审批通过后生效。",
                "tone": "accent",
              },
              {
                "time": "13:26",
                "title": "修改文件模板",
                "detail": "安全管理员调整内容检查模板。",
                "tone": "warning",
              },
              {
                "time": "18:08",
                "title": "导出审计报告",
                "detail": "审计管理员已留痕。",
                "tone": "positive",
              },
            ],
          },
          {
            "type": "table",
            "title": "管理审计清单",
            "description": "管理端留痕和责任界面。",
            "columns": [
              {
                "key": "actor",
                "label": "操作人",
              },
              {
                "key": "source",
                "label": "来源 IP",
              },
              {
                "key": "object",
                "label": "对象",
              },
              {
                "key": "result",
                "label": "结果",
              },
            ],
            "rows": [
              {
                "actor": "api_admin",
                "source": "10.1.2.16",
                "object": "电子病历上报路由",
                "result": {
                  "text": "发布成功",
                  "tone": "positive",
                },
              },
              {
                "actor": "sec_admin",
                "source": "10.1.3.21",
                "object": "文件模板",
                "result": {
                  "text": "待审批",
                  "tone": "warning",
                },
              },
              {
                "actor": "audit_admin",
                "source": "10.1.8.11",
                "object": "专项审计报表",
                "result": {
                  "text": "导出完成",
                  "tone": "accent",
                },
              },
            ],
          },
        ],
      },
    ],
  },
  "users-permissions": {
    "id": "users-permissions",
    "title": "用户与权限",
    "subtitle": "用户、角色、菜单权限与对象范围权限",
    "description": "用户、角色、菜单权限与对象范围权限",
    "breadcrumbs": [
      "系统管理",
      "用户与权限",
    ],
    "tags": [
      "系统管理",
      "系统管理",
    ],
    "status": "运行正常 · 配置已生效",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "用户数",
        "value": "48",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "角色数",
        "value": "6",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "在线用户",
        "value": "12",
        "delta": "+1",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "锁定账号",
        "value": "1",
        "delta": "0",
        "tone": "warning",
        "sparkline": [
          50,
          50,
          50,
          50,
          50,
          50,
          50,
          50,
        ],
      },
    ],
    "highlights": [
      "用户与权限页管理用户、角色和权限，支持三权分立。",
      "角色包括超级管理员、系统管理员、安全管理员和审计管理员。",
      "权限控制到菜单级、页面级、按钮级和对象范围级。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "table",
            "title": "用户与角色",
            "description": "覆盖用户、角色、菜单权限和对象范围权限。",
            "columns": [
              {
                "key": "user",
                "label": "用户",
              },
              {
                "key": "role",
                "label": "角色",
              },
              {
                "key": "scope",
                "label": "对象范围",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "user": "super_admin",
                "role": "超级管理员",
                "scope": "全局",
                "state": {
                  "text": "启用",
                  "tone": "positive",
                },
              },
              {
                "user": "sec_admin",
                "role": "安全管理员",
                "scope": "安全策略 / API / 文件",
                "state": {
                  "text": "启用",
                  "tone": "accent",
                },
              },
              {
                "user": "audit_admin",
                "role": "审计管理员",
                "scope": "审计中心",
                "state": {
                  "text": "锁定待解",
                  "tone": "warning",
                },
              },
            ],
          },
          {
            "type": "matrix",
            "title": "权限矩阵",
            "description": "菜单权限、页面权限、按钮权限和对象范围分别管理。",
            "columns": [
              "菜单",
              "页面",
              "按钮",
            ],
            "rows": [
              {
                "label": "系统管理员",
                "values": [
                  {
                    "text": "全局",
                    "tone": "positive",
                  },
                  {
                    "text": "全局",
                    "tone": "positive",
                  },
                  {
                    "text": "受限",
                    "tone": "accent",
                  },
                ],
              },
              {
                "label": "安全管理员",
                "values": [
                  {
                    "text": "安全域",
                    "tone": "accent",
                  },
                  {
                    "text": "安全域",
                    "tone": "accent",
                  },
                  {
                    "text": "审批动作",
                    "tone": "warning",
                  },
                ],
              },
              {
                "label": "审计管理员",
                "values": [
                  {
                    "text": "审计域",
                    "tone": "positive",
                  },
                  {
                    "text": "审计域",
                    "tone": "positive",
                  },
                  {
                    "text": "导出",
                    "tone": "accent",
                  },
                ],
              },
            ],
          },
        ],
      },
    ],
  },
  "network-routing-management": {
    "id": "network-routing-management",
    "title": "网络配置",
    "subtitle": "四节点接口、地址、VLAN 与链路聚合",
    "description": "四节点接口、地址、VLAN 与链路聚合",
    "breadcrumbs": [
      "系统管理",
      "网络配置",
    ],
    "tags": [
      "系统管理",
      "系统管理",
    ],
    "status": "运行正常 · 配置已生效",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "物理接口",
        "value": "8",
        "delta": "0",
        "tone": "accent",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "管理口",
        "value": "4",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "VLAN",
        "value": "12",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "链路聚合",
        "value": "2",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
    ],
    "highlights": [
      "网络配置页管理四节点的接口、地址、VLAN和链路聚合。",
      "管理口、业务口、心跳口和同步口独立配置。",
      "支持IPv4/IPv6、静态路由和策略路由。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "topology",
            "title": "四节点接口视图",
            "description": "用节点化方式讲接口、地址、VLAN 和链路聚合。",
            "nodes": [
              {
                "id": "n1",
                "name": "接入节点 A",
                "role": "北向接入",
                "tone": "positive",
                "meta": "QPS 4.8k",
              },
              {
                "id": "n2",
                "name": "交换节点 B",
                "role": "重组缓冲",
                "tone": "positive",
                "meta": "堆积 18",
              },
              {
                "id": "n3",
                "name": "交付节点 C",
                "role": "南向交付",
                "tone": "positive",
                "meta": "延迟 12ms",
              },
              {
                "id": "n4",
                "name": "备份节点 D",
                "role": "HA 备用",
                "tone": "warning",
                "meta": "待切换",
              },
            ],
            "links": [
              {
                "from": "n1",
                "to": "n2",
                "label": "交换主链",
                "tone": "positive",
              },
              {
                "from": "n2",
                "to": "n3",
                "label": "交付主链",
                "tone": "positive",
              },
              {
                "from": "n2",
                "to": "n4",
                "label": "心跳同步",
                "tone": "warning",
              },
            ],
          },
          {
            "type": "form",
            "title": "网络配置",
            "description": "管理口、业务口、心跳口和同步口参数配置。",
            "groups": [
              {
                "title": "接口配置",
                "fields": [
                  {
                    "label": "管理口",
                    "value": "172.16.1.10 /24",
                  },
                  {
                    "label": "业务口",
                    "value": "10.10.1.10 /24",
                  },
                  {
                    "label": "VLAN",
                    "value": "100 / 120 / 150",
                  },
                  {
                    "label": "链路聚合",
                    "value": "LACP 开启",
                  },
                ],
              },
            ],
          },
        ],
      },
    ],
  },
  "admin-routing": {
    "id": "admin-routing",
    "title": "路由配置",
    "subtitle": "静态、默认与策略路由及路由测试",
    "description": "静态、默认与策略路由及路由测试",
    "breadcrumbs": [
      "系统管理",
      "路由配置",
    ],
    "tags": [
      "系统管理",
      "系统管理",
    ],
    "status": "运行正常 · 配置已生效",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "静态路由",
        "value": "24",
        "delta": "+2",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "默认路由",
        "value": "4",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "策略路由",
        "value": "8",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "路由测试",
        "value": "通过",
        "delta": "—",
        "tone": "positive",
        "sparkline": [
          50,
          50,
          50,
          50,
          50,
          50,
          50,
          50,
        ],
      },
    ],
    "highlights": [
      "路由配置页管理静态路由、默认路由和策略路由。",
      "路由测试验证路由可达性和源地址路由正确性。",
      "策略路由支持按源地址、目标地址和接口选择路径。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "table",
            "title": "路由配置",
            "description": "包括静态、默认、策略路由及测试结果。",
            "columns": [
              {
                "key": "route",
                "label": "路由",
              },
              {
                "key": "gateway",
                "label": "网关",
              },
              {
                "key": "policy",
                "label": "策略",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "route": "0.0.0.0/0",
                "gateway": "172.16.1.1",
                "policy": "默认",
                "state": {
                  "text": "生效中",
                  "tone": "positive",
                },
              },
              {
                "route": "10.20.0.0/16",
                "gateway": "10.10.2.1",
                "policy": "静态",
                "state": {
                  "text": "生效中",
                  "tone": "positive",
                },
              },
              {
                "route": "医保专网源地址路由",
                "gateway": "10.10.5.1",
                "policy": "策略",
                "state": {
                  "text": "测试中",
                  "tone": "warning",
                },
              },
            ],
          },
          {
            "type": "log-stream",
            "title": "路由测试",
            "description": "路由测试、源地址测试和路径追踪。",
            "entries": [
              {
                "time": "10:06:14",
                "level": "INFO",
                "message": "默认路由测试通过。",
                "tone": "positive",
              },
              {
                "time": "13:44:21",
                "level": "INFO",
                "message": "医保专网源地址路由匹配成功。",
                "tone": "accent",
              },
              {
                "time": "17:02:33",
                "level": "WARN",
                "message": "策略路由变更需要二次确认。",
                "tone": "warning",
              },
            ],
          },
        ],
      },
    ],
  },
  "storage-archiving": {
    "id": "storage-archiving",
    "title": "存储与归档",
    "subtitle": "日志文件存储、阈值、清理与归档策略",
    "description": "日志文件存储、阈值、清理与归档策略",
    "breadcrumbs": [
      "系统管理",
      "存储与归档",
    ],
    "tags": [
      "系统管理",
      "系统管理",
    ],
    "status": "运行正常 · 配置已生效",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "日志存储",
        "value": "67%",
        "delta": "+2%",
        "tone": "warning",
        "sparkline": [
          88,
          89,
          90,
          91,
          92,
          93,
          94,
          95,
        ],
      },
      {
        "label": "文件存储",
        "value": "42%",
        "delta": "+1%",
        "tone": "positive",
        "sparkline": [
          88,
          89,
          90,
          91,
          92,
          93,
          94,
          95,
        ],
      },
      {
        "label": "清理策略",
        "value": "6",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "外发配置",
        "value": "3",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
    ],
    "highlights": [
      "存储与归档页管理日志存储、文件存储、容量阈值和清理策略。",
      "支持热、温、冷数据分层存储。",
      "日志外发支持Syslog、SNMP和Kafka方式。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "bar-list",
            "title": "存储池占用",
            "description": "日志、文件、归档空间占用情况。",
            "items": [
              {
                "label": "日志存储",
                "value": 62,
                "max": 100,
                "tone": "accent",
                "meta": "保留 180 天",
              },
              {
                "label": "文件存储",
                "value": 48,
                "max": 100,
                "tone": "positive",
                "meta": "归档同步开启",
              },
              {
                "label": "归档空间",
                "value": 73,
                "max": 100,
                "tone": "warning",
                "meta": "建议扩容",
              },
            ],
          },
          {
            "type": "form",
            "title": "阈值与清理策略",
            "description": "容量阈值、清理策略和日志外发配置。",
            "groups": [
              {
                "title": "当前策略",
                "fields": [
                  {
                    "label": "日志阈值",
                    "value": "80%",
                  },
                  {
                    "label": "文件阈值",
                    "value": "75%",
                  },
                  {
                    "label": "清理策略",
                    "value": "按业务分组归档后清理",
                  },
                  {
                    "label": "日志外发",
                    "value": "Syslog + HTTPS",
                  },
                ],
              },
            ],
          },
        ],
      },
    ],
  },
  "certificates-keys": {
    "id": "certificates-keys",
    "title": "证书与密钥",
    "subtitle": "证书管理、密钥管理与 CA 管理",
    "description": "证书管理、密钥管理与 CA 管理",
    "breadcrumbs": [
      "系统管理",
      "证书与密钥",
    ],
    "tags": [
      "系统管理",
      "系统管理",
    ],
    "status": "运行正常 · 配置已生效",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "证书数",
        "value": "58",
        "delta": "+4",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "密钥数",
        "value": "12",
        "delta": "+1",
        "tone": "neutral",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "CA管理",
        "value": "4",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "NTP同步",
        "value": "正常",
        "delta": "—",
        "tone": "positive",
        "sparkline": [
          50,
          50,
          50,
          50,
          50,
          50,
          50,
          50,
        ],
      },
    ],
    "highlights": [
      "证书与密钥页管理平台证书、密钥对象和CA管理。",
      "支持证书导入、更新、吊销和到期预警。",
      "NTP时间同步确保日志时间戳和证书有效期判断准确。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "inventory",
            "title": "证书与密钥对象",
            "description": "统一查看证书、密钥和 CA 管理对象。",
            "items": [
              {
                "title": "Root-CA-GOV",
                "meta": "根证书",
                "tags": [
                  "CA",
                ],
                "tone": "positive",
              },
              {
                "title": "API-KEY-STORE",
                "meta": "密钥对象",
                "tags": [
                  "密钥",
                ],
                "tone": "accent",
              },
              {
                "title": "EMR-SERVER",
                "meta": "业务证书",
                "tags": [
                  "服务端",
                ],
                "tone": "warning",
              },
            ],
          },
          {
            "type": "timeline",
            "title": "证书与密钥变更",
            "description": "证书轮换、更新和失效提醒。",
            "events": [
              {
                "time": "04-12",
                "title": "更新中间证书",
                "detail": "GOV-INT-01 已替换。",
                "tone": "positive",
              },
              {
                "time": "04-15",
                "title": "导入业务证书",
                "detail": "EMR-SERVER 进入待绑定。",
                "tone": "accent",
              },
              {
                "time": "04-18",
                "title": "证书到期提醒",
                "detail": "legacy-auth 30 天内到期。",
                "tone": "warning",
              },
            ],
          },
        ],
      },
    ],
  },
  "upgrade-backup": {
    "id": "upgrade-backup",
    "title": "升级与备份",
    "subtitle": "升级包、配置备份、系统恢复与授权激活",
    "description": "升级包、配置备份、系统恢复与授权激活",
    "breadcrumbs": [
      "系统管理",
      "升级与备份",
    ],
    "tags": [
      "系统管理",
      "系统管理",
    ],
    "status": "运行正常 · 配置已生效",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "当前版本",
        "value": "v2.0.0",
        "delta": "—",
        "tone": "neutral",
        "sparkline": [
          50,
          50,
          50,
          50,
          50,
          50,
          50,
          50,
        ],
      },
      {
        "label": "升级包",
        "value": "1",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "配置备份",
        "value": "7",
        "delta": "+1",
        "tone": "positive",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "系统恢复",
        "value": "0",
        "delta": "0",
        "tone": "positive",
        "sparkline": [
          50,
          50,
          50,
          50,
          50,
          50,
          50,
          50,
        ],
      },
    ],
    "highlights": [
      "升级与备份页管理升级包、配置备份和系统恢复。",
      "升级前自动执行健康检查，升级失败支持回滚。",
      "配置备份支持手动和定时两种模式。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "timeline",
            "title": "升级与备份流程",
            "description": "展示升级包管理、配置备份和系统恢复。",
            "events": [
              {
                "time": "08:30",
                "title": "创建配置备份",
                "detail": "升级前自动生成基线。",
                "tone": "positive",
              },
              {
                "time": "09:10",
                "title": "上传升级包",
                "detail": "等待维护窗口执行。",
                "tone": "accent",
              },
              {
                "time": "09:40",
                "title": "健康检查",
                "detail": "滚动升级前执行设备自检。",
                "tone": "warning",
              },
            ],
          },
          {
            "type": "table",
            "title": "升级包与备份",
            "description": "升级、回滚和恢复的受控流程。",
            "columns": [
              {
                "key": "item",
                "label": "对象",
              },
              {
                "key": "version",
                "label": "版本",
              },
              {
                "key": "time",
                "label": "时间",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "item": "phoenix-v1.8.0",
                "version": "1.8.0",
                "time": "2026-04-18",
                "state": {
                  "text": "待执行",
                  "tone": "warning",
                },
              },
              {
                "item": "baseline-backup-0416",
                "version": "配置备份",
                "time": "2026-04-16",
                "state": {
                  "text": "可恢复",
                  "tone": "positive",
                },
              },
              {
                "item": "rollback-pack-0410",
                "version": "回滚包",
                "time": "2026-04-10",
                "state": {
                  "text": "可用",
                  "tone": "accent",
                },
              },
            ],
          },
        ],
      },
    ],
  },
  "time-notification": {
    "id": "time-notification",
    "title": "时间与通知",
    "subtitle": "NTP、日志外发与告警通知配置",
    "description": "NTP、日志外发与告警通知配置",
    "breadcrumbs": [
      "系统管理",
      "时间与通知",
    ],
    "tags": [
      "系统管理",
      "系统管理",
    ],
    "status": "运行正常 · 配置已生效",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "NTP服务器",
        "value": "2",
        "delta": "0",
        "tone": "neutral",
        "sparkline": [
          65,
          67,
          66,
          68,
          67,
          66,
          68,
          67,
        ],
      },
      {
        "label": "日志外发",
        "value": "3",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "告警通知",
        "value": "4",
        "delta": "+1",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "时区",
        "value": "CST",
        "delta": "—",
        "tone": "neutral",
        "sparkline": [
          50,
          50,
          50,
          50,
          50,
          50,
          50,
          50,
        ],
      },
    ],
    "highlights": [
      "时间与通知页管理NTP时间同步、日志外发和告警通知配置。",
      "日志外发支持Syslog、SNMP、FTP和Kafka方式。",
      "告警通知支持邮件、短信和Webhook。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "form",
            "title": "时间与通知配置",
            "description": "包括 NTP、日志外发和告警通知。",
            "groups": [
              {
                "title": "基础配置",
                "fields": [
                  {
                    "label": "NTP 服务",
                    "value": "ntp.gov.local / 10.1.0.20",
                  },
                  {
                    "label": "时区",
                    "value": "Asia/Shanghai",
                  },
                  {
                    "label": "日志外发",
                    "value": "Syslog + HTTPS",
                  },
                  {
                    "label": "告警通知",
                    "value": "邮件 + 短信网关预留",
                  },
                ],
              },
            ],
          },
          {
            "type": "status-list",
            "title": "同步状态",
            "description": "看时钟同步、外发通道和告警配置状态。",
            "items": [
              {
                "label": "NTP 同步",
                "value": "正常",
                "tone": "positive",
                "meta": "偏差 < 20ms",
              },
              {
                "label": "日志外发",
                "value": "已连接",
                "tone": "accent",
                "meta": "双通道",
              },
              {
                "label": "通知规则",
                "value": "3 条启用",
                "tone": "warning",
                "meta": "其中 1 条待审批",
              },
            ],
          },
        ],
      },
    ],
  },
  "license-management": {
    "id": "license-management",
    "title": "许可证管理",
    "subtitle": "授权激活、功能项查看与容量查看",
    "description": "授权激活、功能项查看与容量查看",
    "breadcrumbs": [
      "系统管理",
      "许可证管理",
    ],
    "tags": [
      "系统管理",
      "系统管理",
    ],
    "status": "运行正常 · 配置已生效",
    "updatedAt": "2026-04-16 20:10 CST",
    "actions": [
      {
        "label": "刷新数据",
        "tone": "secondary",
        "intent": "drawer",
        "payload": "数据已刷新。",
      },
      {
        "label": "导出报告",
        "tone": "ghost",
        "intent": "export",
      },
    ],
    "heroMetrics": [
      {
        "label": "授权状态",
        "value": "已激活",
        "delta": "—",
        "tone": "positive",
        "sparkline": [
          50,
          50,
          50,
          50,
          50,
          50,
          50,
          50,
        ],
      },
      {
        "label": "接口数",
        "value": "86/128",
        "delta": "—",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "文件任务",
        "value": "24/64",
        "delta": "—",
        "tone": "accent",
        "sparkline": [
          32,
          38,
          41,
          49,
          54,
          58,
          62,
          69,
        ],
      },
      {
        "label": "审计容量",
        "value": "6个月",
        "delta": "—",
        "tone": "positive",
        "sparkline": [
          50,
          50,
          50,
          50,
          50,
          50,
          50,
          50,
        ],
      },
    ],
    "highlights": [
      "许可证管理页展示授权状态、功能项和容量使用情况。",
      "容量项包括接口数、文件任务数、数据库实例数和审计容量。",
      "授权到期预警帮助及时续期。",
    ],
    "sections": [
      {
        "layout": "two",
        "widgets": [
          {
            "type": "bar-list",
            "title": "许可证容量",
            "description": "展示接口数、文件任务数和数据库实例数容量。",
            "items": [
              {
                "label": "接口数",
                "value": 86,
                "max": 120,
                "tone": "accent",
                "meta": "已用 86 / 120",
              },
              {
                "label": "文件任务数",
                "value": 18,
                "max": 40,
                "tone": "positive",
                "meta": "已用 18 / 40",
              },
              {
                "label": "数据库实例数",
                "value": 9,
                "max": 20,
                "tone": "warning",
                "meta": "已用 9 / 20",
              },
            ],
          },
          {
            "type": "table",
            "title": "许可证项",
            "description": "授权激活、功能项和容量边界管理。",
            "columns": [
              {
                "key": "item",
                "label": "能力项",
              },
              {
                "key": "licensed",
                "label": "授权数",
              },
              {
                "key": "used",
                "label": "已使用",
              },
              {
                "key": "state",
                "label": "状态",
              },
            ],
            "rows": [
              {
                "item": "API 服务",
                "licensed": "120",
                "used": "86",
                "state": {
                  "text": "充足",
                  "tone": "positive",
                },
              },
              {
                "item": "文件任务",
                "licensed": "40",
                "used": "18",
                "state": {
                  "text": "充足",
                  "tone": "positive",
                },
              },
              {
                "item": "数据库实例",
                "licensed": "20",
                "used": "9",
                "state": {
                  "text": "关注增长",
                  "tone": "warning",
                },
              },
            ],
          },
        ],
      },
    ],
  },
};

/**
 * 统一生成轻量占位页，确保新增菜单在导航点击时有稳定落地页面。
 * 后续可按模块逐步替换为完整业务数据与交互组件。
 */
function createFeaturePage(params: {
  id: string;
  title: string;
  subtitle: string;
  description: string;
  breadcrumbs: string[];
  tags: string[];
  highlights: string[];
  metricLabel: string;
  metricValue: string;
  metricDelta: string;
}): PageDefinition {
  return {
    id: params.id,
    title: params.title,
    subtitle: params.subtitle,
    description: params.description,
    breadcrumbs: params.breadcrumbs,
    tags: params.tags,
    status: "规划功能 · 可用于联调与后续功能扩展",
    updatedAt: "2026-04-17 21:30 CST",
    actions: [
      {
        label: "查看功能说明",
        tone: "secondary",
        intent: "drawer",
        payload: params.description
      }
    ],
    heroMetrics: [
      {
        label: params.metricLabel,
        value: params.metricValue,
        delta: params.metricDelta,
        tone: "accent",
        sparkline: [60, 63, 65, 66, 68, 70, 72, 74]
      }
    ],
    highlights: params.highlights,
    sections: [
      {
        layout: "single",
        widgets: [
          {
            type: "bullet-list",
            title: `${params.title}功能点`,
            description: "根据 S01 Phoenix 管理控制台 V2.0 文档同步的功能项。",
            items: params.highlights.map((text) => ({ text }))
          }
        ]
      }
    ]
  };
}

const v2FeaturePages: Record<string, PageDefinition> = {
  "asset-overview": createFeaturePage({
    id: "asset-overview",
    title: "通道总览",
    subtitle: "全类型通道统计、风险分布与活跃度分析",
    description: "提供通道规模、风险暴露面和访问热度的统一视图。",
    breadcrumbs: ["通道配置", "通道总览"],
    tags: ["通道配置", "Dashboard"],
    highlights: [
      "全类型通道数量统计",
      "风险通道分布与暴露面展示",
      "通道活跃度与访问热度分析"
    ],
    metricLabel: "通道总数",
    metricValue: "2,846",
    metricDelta: "+6.2%"
  }),
  "api-channel": createFeaturePage({
    id: "api-channel",
    title: "API通道",
    subtitle: "API 清单、调用身份与风险识别",
    description: "聚焦 API通道管理、影子 API 发现与敏感接口分级。",
    breadcrumbs: ["通道配置", "API通道"],
    tags: ["通道配置", "API"],
    highlights: [
      "API 清单管理（Path / Method / 参数）",
      "调用方身份与访问频次识别",
      "影子 API、未备案 API 发现",
      "敏感 API 风险标记与分级"
    ],
    metricLabel: "API通道",
    metricValue: "1,092",
    metricDelta: "+4.9%"
  }),
  "database-channel": createFeaturePage({
    id: "database-channel",
    title: "数据库通道",
    subtitle: "库表字段治理、敏感识别与访问分析",
    description: "统一管理数据库实例、库表字段与访问风险。",
    breadcrumbs: ["通道配置", "数据库通道"],
    tags: ["通道配置", "数据库"],
    highlights: [
      "数据库实例/库/表/字段结构管理",
      "敏感字段自动标记",
      "访问关系与来源分析",
      "SQL 风险与慢查询统计"
    ],
    metricLabel: "数据库通道",
    metricValue: "783",
    metricDelta: "+3.1%"
  }),
  "file-transfer-channel": createFeaturePage({
    id: "file-transfer-channel",
    title: "文件摆渡通道",
    subtitle: "文件流转、敏感识别与异常访问追踪",
    description: "覆盖文件来源去向、生命周期流转与风险事件。",
    breadcrumbs: ["通道配置", "文件摆渡通道"],
    tags: ["通道配置", "文件"],
    highlights: [
      "文件来源/去向/类型/大小统一管理",
      "敏感文件自动识别与标记",
      "文件全生命周期流转路径可视化",
      "异常传输与越权访问记录"
    ],
    metricLabel: "文件摆渡通道",
    metricValue: "971",
    metricDelta: "+7.8%"
  }),
  "database-sync-channel": createFeaturePage({
    id: "database-sync-channel",
    title: "数据库同步通道",
    subtitle: "数据库同步任务配置、源库目标库管理与冲突处理策略",
    description: "统一管理数据库同步任务，支持源库目标库配置、同步模式与冲突处理策略。",
    breadcrumbs: ["通道配置", "数据库同步通道"],
    tags: ["通道配置", "数据库同步"],
    highlights: [
      "数据库同步任务管理（源库/目标库/同步模式）",
      "同步方向与冲突处理策略配置",
      "同步计划（cron 表达式）与调度管理",
      "任务状态监控与异常告警"
    ],
    metricLabel: "同步任务",
    metricValue: "10",
    metricDelta: "+0"
  }),
  "message-queue-channel": createFeaturePage({
    id: "message-queue-channel",
    title: "消息队列通道",
    subtitle: "消息队列实例接入配置、访问控制与消息保留策略",
    description: "统一管理消息队列实例接入配置，支持访问控制、消息大小限制与保留策略。",
    breadcrumbs: ["通道配置", "消息队列通道"],
    tags: ["通道配置", "消息队列"],
    highlights: [
      "消息队列实例管理（Kafka/RabbitMQ/RocketMQ/ActiveMQ）",
      "访问控制策略配置（ACL/TLS/SASL）",
      "消息大小限制与保留时长管理",
      "死信队列开关与异常监控"
    ],
    metricLabel: "队列实例",
    metricValue: "10",
    metricDelta: "+0"
  }),
  "asset-discovery": createFeaturePage({
    id: "asset-discovery",
    title: "通道发现",
    subtitle: "扫描任务与影子通道纳管",
    description: "通过流量学习发现未备案通道并支持一键纳管。",
    breadcrumbs: ["通道配置", "通道发现"],
    tags: ["通道配置", "发现"],
    highlights: [
      "流量自学习发现影子 API/未备案服务",
      "未备案访问行为检测与告警",
      "支持一键纳管与自动归档"
    ],
    metricLabel: "发现任务",
    metricValue: "26",
    metricDelta: "+2"
  }),
  "security-policy": createFeaturePage({
    id: "security-policy",
    title: "安全策略",
    subtitle: "策略全生命周期管理与发布回滚",
    description: "提供策略配置、灰度试运行、版本管理和影响分析。",
    breadcrumbs: ["策略中心", "安全策略"],
    tags: ["策略中心", "管理"],
    highlights: [
      "策略创建/启用/禁用/编辑/复制/删除",
      "按通道、标签、业务分组绑定",
      "优先级、执行顺序配置",
      "灰度发布、试运行、版本管理",
      "策略影响分析与回滚"
    ],
    metricLabel: "生效策略",
    metricValue: "214",
    metricDelta: "+11"
  }),
  "policy-orchestration": createFeaturePage({
    id: "policy-orchestration",
    title: "策略编排",
    subtitle: "可视化流程与执行路径仿真",
    description: "支持策略链拖拽编排、条件分支与模拟测试。",
    breadcrumbs: ["策略中心", "策略编排"],
    tags: ["策略中心", "编排"],
    highlights: [
      "拖拽式策略执行链编排",
      "条件分支、逻辑判断可视化",
      "多策略串行/并行组合",
      "执行路径仿真与请求模拟测试"
    ],
    metricLabel: "编排流程",
    metricValue: "58",
    metricDelta: "+5"
  }),
  "policy-template": createFeaturePage({
    id: "policy-template",
    title: "策略模板",
    subtitle: "多类型模板复用与一键引用",
    description: "聚合 API、文件、数据库策略模板并支持快速复用。",
    breadcrumbs: ["策略中心", "策略模板"],
    tags: ["策略中心", "模板"],
    highlights: [
      "API 安全模板：鉴权、限流、注入防护、内容过滤",
      "文件传输模板：类型检查、敏感内容、命令控制",
      "数据库模板：SQL 风险、脱敏、访问控制",
      "一键引用快速生成策略"
    ],
    metricLabel: "模板数量",
    metricValue: "129",
    metricDelta: "+9"
  }),
  "channel-management": createFeaturePage({
    id: "channel-management",
    title: "策略应用",
    subtitle: "通道视图下的策略关联与优先级",
    description: "以业务通道实例为中心查看已关联策略，支持绑定、启停与优先级调整。",
    breadcrumbs: ["策略中心", "策略应用"],
    tags: ["策略中心", "通道"],
    highlights: [
      "按 API、数据库、文件摆渡等通道类型浏览业务通道",
      "查看通道已关联的统一策略列表",
      "添加/移除策略关联，调整执行优先级",
      "跳转策略管理进行模块级配置"
    ],
    metricLabel: "业务通道",
    metricValue: "86",
    metricDelta: "+4"
  }),
  "security-object": createFeaturePage({
    id: "security-object",
    title: "安全对象",
    subtitle: "可复用安全对象与策略引用",
    description: "统一管理 IP 白名单池、敏感词库等安全对象，供策略 N:N 引用。",
    breadcrumbs: ["策略中心", "安全对象"],
    tags: ["策略中心", "对象"],
    highlights: [
      "IP 白名单池：多 IP/CIDR 条目维护",
      "敏感词库：关键词批量录入",
      "启用/禁用与搜索筛选",
      "查看被哪些策略引用"
    ],
    metricLabel: "安全对象",
    metricValue: "48",
    metricDelta: "+6"
  }),
  "policy-binding": createFeaturePage({
    id: "policy-binding",
    title: "策略绑定",
    subtitle: "通道与策略 N:N 绑定管理",
    description: "统一管理通道与策略的绑定关系，支持批量新建、启停与删除。",
    breadcrumbs: ["策略中心", "策略绑定"],
    tags: ["策略中心", "绑定"],
    highlights: [
      "按通道类型筛选可绑定的通道与策略",
      "一次绑定支持多个通道 + 多条策略",
      "启停开关与自动生成 N:N 关联"
    ],
    metricLabel: "绑定关系",
    metricValue: "—",
    metricDelta: "—"
  }),
  "audit-asset": createFeaturePage({
    id: "audit-asset",
    title: "通道视角",
    subtitle: "通道维度访问审计与风险回溯",
    description: "从通道维度查看访问者、命中策略与历史链路。",
    breadcrumbs: ["审计中心", "通道视角"],
    tags: ["审计中心", "通道视角"],
    highlights: [
      "查看单个通道：访问者、频次、时间",
      "命中策略、风险记录",
      "历史访问全链路追溯"
    ],
    metricLabel: "重点通道审计",
    metricValue: "96",
    metricDelta: "+7"
  }),
  "audit-policy": createFeaturePage({
    id: "audit-policy",
    title: "策略视角",
    subtitle: "策略效果分析与调优建议",
    description: "聚焦策略命中效果、误拦漏拦与优化方向。",
    breadcrumbs: ["审计中心", "策略视角"],
    tags: ["审计中心", "策略视角"],
    highlights: [
      "单策略命中、阻断、放行统计",
      "误拦/漏拦分析",
      "策略有效性评估与调优建议"
    ],
    metricLabel: "分析策略",
    metricValue: "84",
    metricDelta: "+6"
  }),
  "audit-trace": createFeaturePage({
    id: "audit-trace",
    title: "链路回溯",
    subtitle: "按 trace_id 的全生命周期追踪",
    description: "展示请求全链路执行时间线和关键命中信息。",
    breadcrumbs: ["审计中心", "链路回溯"],
    tags: ["审计中心", "链路回溯"],
    highlights: [
      "按 trace_id 追踪单次请求全生命周期",
      "策略执行路径时间线展示",
      "每步规则命中、动作、耗时详情",
      "快速定位失败/拦截根因"
    ],
    metricLabel: "可追踪请求",
    metricValue: "12,487",
    metricDelta: "+15.4%"
  }),
  "alert-log": createFeaturePage({
    id: "alert-log",
    title: "告警日志",
    subtitle: "策略命中、防火墙拦截与系统运行告警的统一检索",
    description: "覆盖 API/DB/文件/同步/MQ/系统六类告警来源,支持按等级/状态/业务组检索与处置追踪。",
    breadcrumbs: ["审计中心", "告警日志"],
    tags: ["审计中心", "告警日志"],
    highlights: [
      "六类告警 Tab 切换:API / DB / 文件 / DBSync / MQ / 系统",
      "按告警等级、处理状态、业务组多维筛选",
      "命中策略、规则、证据片段的告警详情抽屉",
      "标记已处理 / 一键忽略 / 转工单等处置动作"
    ],
    metricLabel: "今日告警",
    metricValue: "284",
    metricDelta: "+18"
  }),
  "ha-audit": createFeaturePage({
    id: "ha-audit",
    title: "HA审计",
    subtitle: "HA 主控、VIP 守护与 HA 代理运行审计事件统一检索",
    description: "读取高可用链路（HA 主控 / VIP 守护 / HA 代理）运行审计事件，支持按时间、来源、级别、节点与关键字检索。",
    breadcrumbs: ["审计中心", "HA审计"],
    tags: ["审计中心", "HA审计"],
    highlights: [
      "时间范围 / 来源 / 级别 / 节点 / 关键字多维筛选",
      "级别着色：信息 / 警告 / 错误 / 致命",
      "详情抽屉展示中文字段与格式化详情 JSON"
    ],
    metricLabel: "审计事件",
    metricValue: "—",
    metricDelta: "—"
  })
};

export const pageCatalog: Record<string, PageDefinition> = {
  ...legacyPageCatalog,
  ...v2FeaturePages,
  ...configPages,
  "high-availability-configuration": adminHaPage
};
