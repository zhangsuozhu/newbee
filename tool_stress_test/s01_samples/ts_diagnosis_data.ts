import type {
  KpiCard,
  HealthMatrixRow,
  SelfCheckCard,
  HaCheckRow,
  ProcessRow,
  TerminalOutput,
  CommandHelp,
  CaptureTask,
  CaptureNodeParam,
  TroubleshootCheckItem,
  TroubleshootScene,
  EvidenceItem,
} from "./diagnosis-types";

export const sysKpis: KpiCard[] = [
  { label: "CPU 使用率", value: "18%", status: "normal", icon: "cpu" },
  { label: "内存使用率", value: "42%", status: "normal", icon: "memory" },
  { label: "存储使用率", value: "36%", status: "normal", icon: "storage" },
  { label: "网卡异常数", value: "0", status: "normal", icon: "network" },
  { label: "进程异常数", value: "1", status: "warn", icon: "process" },
  { label: "风扇状态", value: "正常", status: "normal", icon: "fan" },
  { label: "电源状态", value: "正常", status: "normal", icon: "power" },
  { label: "温度状态", value: "正常", status: "normal", icon: "temp" },
];

export const healthMatrix: HealthMatrixRow[] = [
  {
    item: "主业务进程",
    all: true,
    nodes: {
      "A-NODE": true,
      "B-NODE": true,
      "C-NODE": { ok: false, warnCount: 5, total: 6 },
      "D-NODE": true,
    },
  },
  {
    item: "管理服务",
    all: true,
    nodes: { "A-NODE": true, "B-NODE": true, "C-NODE": true, "D-NODE": true },
  },
  {
    item: "审计服务",
    all: true,
    nodes: { "A-NODE": true, "B-NODE": true, "C-NODE": true, "D-NODE": true },
  },
  {
    item: "路由服务",
    all: true,
    nodes: { "A-NODE": true, "B-NODE": true, "C-NODE": true, "D-NODE": true },
  },
  {
    item: "接口状态",
    all: true,
    nodes: { "A-NODE": true, "B-NODE": true, "C-NODE": true, "D-NODE": true },
  },
  {
    item: "CPU/内存/磁盘",
    all: true,
    nodes: { "A-NODE": true, "B-NODE": true, "C-NODE": true, "D-NODE": true },
  },
  {
    item: "网卡/光模块",
    all: true,
    nodes: { "A-NODE": true, "B-NODE": true, "C-NODE": true, "D-NODE": true },
  },
  {
    item: "风扇/电源/温度",
    all: true,
    nodes: { "A-NODE": true, "B-NODE": true, "C-NODE": true, "D-NODE": true },
  },
  {
    item: "时间同步",
    all: true,
    nodes: { "A-NODE": true, "B-NODE": true, "C-NODE": true, "D-NODE": true },
  },
  {
    item: "路由表",
    all: true,
    nodes: { "A-NODE": true, "B-NODE": true, "C-NODE": true, "D-NODE": true },
  },
  {
    item: "源地址路由",
    all: true,
    nodes: { "A-NODE": true, "B-NODE": true, "C-NODE": true, "D-NODE": true },
  },
  {
    item: "IP/MAC 绑定",
    all: true,
    nodes: { "A-NODE": true, "B-NODE": true, "C-NODE": true, "D-NODE": true },
  },
];

export const selfCheckCards: SelfCheckCard[] = [
  { label: "CPU", status: "normal", detail: "18% · 8 核", sub: "● 正常", icon: "▣", pct: 18 },
  { label: "内存", status: "normal", detail: "42% · 32 GB", sub: "● 正常", icon: "▤", pct: 42 },
  { label: "风扇", status: "normal", detail: "4820 RPM", sub: "● 正常", icon: "✣" },
  { label: "主板", status: "normal", detail: "BIOS v2.3", sub: "● 正常", icon: "◈" },
  { label: "电源", status: "normal", detail: "1+1 冗余", sub: "● 正常", icon: "⏻" },
  { label: "温度", status: "normal", detail: "46.2 ℃", sub: "● 正常", icon: "♨", pct: 46 },
  { label: "网卡", status: "normal", detail: "4/4 正常", sub: "● 正常", icon: "▧" },
  { label: "光模块", status: "normal", detail: "收发功率正常", sub: "● 正常", icon: "▣" },
  { label: "磁盘", status: "normal", detail: "健康 100%", sub: "● 正常", icon: "◉", pct: 100 },
];

export const haChecks: HaCheckRow[] = [
  { item: "主备心跳口连通性", status: "normal" },
  { item: "备份心跳口可用性", status: "normal" },
  { item: "管理地址可达性", status: "normal" },
  { item: "WEB/SSH 管理监听地址", status: "normal" },
  { item: "静态IP/浮动IP/VIP/SNAT 地址冲突", status: "normal" },
];

export const processRows: ProcessRow[] = [
  {
    name: "API代理",
    nodes: {
      "A-NODE": { status: "running", cpu: "12%", mem: "18%", threads: 128, queue: 23, lastRestart: "2025-05-22 08:14:32", errors: 0 },
      "B-NODE": { status: "running", cpu: "14%", mem: "20%", threads: 132, queue: 25, lastRestart: "2025-05-22 08:14:33", errors: 0 },
    },
  },
  {
    name: "数据库代理",
    nodes: {
      "A-NODE": { status: "running", cpu: "14%", mem: "24%", threads: 150, queue: 28, lastRestart: "2025-05-22 08:14:34", errors: 0 },
      "B-NODE": { status: "running", cpu: "15%", mem: "26%", threads: 156, queue: 31, lastRestart: "2025-05-22 08:14:35", errors: 0 },
    },
  },
  {
    name: "文件缓存",
    nodes: {
      "C-NODE": { status: "running", cpu: "22%", mem: "33%", threads: 184, queue: 42, lastRestart: "2025-05-22 08:14:40", errors: 1 },
    },
  },
  {
    name: "消息通道",
    nodes: {
      "D-NODE": { status: "running", cpu: "9%", mem: "14%", threads: 96, queue: 17, lastRestart: "2025-05-22 08:14:28", errors: 0 },
    },
  },
  {
    name: "审计服务",
    nodes: {
      "A-NODE": { status: "running", cpu: "8%", mem: "20%", threads: 112, queue: 19, lastRestart: "2025-05-22 08:14:31", errors: 0 },
      "B-NODE": { status: "running", cpu: "7%", mem: "19%", threads: 108, queue: 16, lastRestart: "2025-05-22 08:14:30", errors: 0 },
    },
  },
  {
    name: "管理服务",
    nodes: {
      "A-NODE": { status: "running", cpu: "6%", mem: "16%", threads: 88, queue: 13, lastRestart: "2025-05-22 08:14:27", errors: 0 },
      "B-NODE": { status: "running", cpu: "5%", mem: "14%", threads: 82, queue: 11, lastRestart: "2025-05-22 08:14:26", errors: 0 },
    },
  },
  {
    name: "证书服务",
    nodes: {
      "D-NODE": { status: "running", cpu: "5%", mem: "12%", threads: 64, queue: 8, lastRestart: "2025-05-22 08:14:26", errors: 0 },
    },
  },
];

export const terminalOutputs: TerminalOutput[] = [
  {
    node: "A-NODE",
    lines: [
      "[A-NODE]$ ping -c 4 10.10.10.1",
      "PING 10.10.10.1 56(84) bytes of data.",
      "64 bytes from 10.10.10.1: time=1.11 ms",
      "64 bytes from 10.10.10.1: time=1.09 ms",
      "64 bytes from 10.10.10.1: time=1.08 ms",
      "64 bytes from 10.10.10.1: time=1.12 ms",
      "",
      "4 packets transmitted, 4 received, 0% packet loss",
      "[A-NODE]$",
    ],
  },
  {
    node: "B-NODE",
    lines: [
      "[B-NODE]$ ping -c 4 10.10.10.1",
      "64 bytes from 10.10.10.1: time=6.47 ms",
      "64 bytes from 10.10.10.1: time=6.62 ms",
      "64 bytes from 10.10.10.1: time=7.03 ms",
      "64 bytes from 10.10.10.1: time=6.81 ms",
      "",
      "4 packets transmitted, 4 received, 0% packet loss",
      "[B-NODE]$",
    ],
  },
  {
    node: "C-NODE",
    lines: [
      "[C-NODE]$ ping -c 4 10.10.10.1",
      "64 bytes from 10.10.10.1: time=88.21 ms",
      "64 bytes from 10.10.10.1: time=92.35 ms",
      "64 bytes from 10.10.10.1: time=86.74 ms",
      "64 bytes from 10.10.10.1: time=90.61 ms",
      "",
      "4 packets transmitted, 4 received, 0% packet loss",
      "[C-NODE]$",
    ],
  },
  {
    node: "D-NODE",
    lines: [
      "[D-NODE]$ ping -c 4 10.10.10.1",
      "64 bytes from 10.10.10.1: time=5.12 ms",
      "Request timeout for icmp_seq=2",
      "64 bytes from 10.10.10.1: time=5.27 ms",
      "Request timeout for icmp_seq=4",
      "",
      "4 packets transmitted, 2 received, 50% packet loss",
      "[D-NODE]$",
    ],
  },
];

export const commandHelps: CommandHelp[] = [
  {
    name: "ping",
    example: "ping 10.10.10.1",
    description: "测试目标地址连通性",
    synopsis: "ping [选项] 目标主机",
    descriptionLong:
      "向目标主机发送 ICMP ECHO_REQUEST 报文，根据回包计算往返时延 (RTT) 与丢包率，判断目标是否可达以及链路质量。",
    options: [
      { flag: "-c", arg: "次数", desc: "指定发送报文的次数，到达后自动停止" },
      { flag: "-i", arg: "秒", desc: "两次发送之间的间隔，默认 1 秒" },
      { flag: "-s", arg: "字节", desc: "发送数据包大小（不含 8 字节 ICMP 头）" },
      { flag: "-W", arg: "秒", desc: "等待每个回包的超时时间" },
      { flag: "-w", arg: "秒", desc: "整体最大等待时间，到时无论是否完成都退出" },
      { flag: "-I", arg: "接口/源地址", desc: "指定发送接口或源 IP" },
      { flag: "-t", arg: "TTL", desc: "设置 IP 包的 TTL 上限" },
      { flag: "-M", arg: "do|want|dont", desc: "PMTU 探测策略，常用 do 禁止分片" },
      { flag: "-q", desc: "安静模式，仅在结束时输出统计" },
    ],
    examples: [
      { cmd: "ping -c 4 10.10.10.1", desc: "发送 4 个包后退出，常用于快速连通性确认" },
      { cmd: "ping -i 0.2 -c 50 10.10.10.1", desc: "高频探测，观察短时丢包" },
      { cmd: "ping -s 1472 -M do 10.10.10.1", desc: "PMTU 探测，定位巨帧/分片问题" },
      { cmd: "ping -I eth1 10.10.20.1", desc: "强制走 eth1 出方向，排查多路径" },
    ],
    notes: "退出码 0=有回包, 1=完全无回包, 2=其它错误。需要 CAP_NET_RAW 能力。",
  },
  {
    name: "traceroute",
    example: "traceroute 93.184.216.34",
    description: "追踪路由路径",
    synopsis: "traceroute [选项] 目标主机 [包长]",
    descriptionLong:
      "通过递增 TTL 触发沿途路由器返回 ICMP TIME_EXCEEDED，从而探测数据包所经过的每一跳网关，并给出每跳时延。",
    options: [
      { flag: "-I", desc: "使用 ICMP ECHO 探测，等价 ping 风格" },
      { flag: "-T", desc: "使用 TCP SYN 探测，绕过部分 UDP 屏蔽" },
      { flag: "-U", desc: "使用 UDP 探测（默认）" },
      { flag: "-n", desc: "不解析主机名，仅输出 IP" },
      { flag: "-m", arg: "跳数", desc: "最大跳数上限，默认 30" },
      { flag: "-q", arg: "次数", desc: "每跳发送的探测包数，默认 3" },
      { flag: "-w", arg: "秒", desc: "每跳等待回包超时" },
      { flag: "-p", arg: "端口", desc: "目标端口（UDP/TCP 模式）" },
      { flag: "-i", arg: "接口", desc: "指定发送接口" },
    ],
    examples: [
      { cmd: "traceroute -n -m 20 8.8.8.8", desc: "不解析名字、最多 20 跳" },
      { cmd: "traceroute -T -p 443 api.example.com", desc: "TCP/443 探测，绕开 UDP 黑洞" },
      { cmd: "traceroute -I 10.10.10.1", desc: "ICMP 模式，行为接近 Windows tracert" },
    ],
    notes: "中间跳显示为 * 通常表示该路由器静默或速率限制，不一定真的不通。",
  },
  {
    name: "dig",
    example: "dig www.example.com",
    description: "DNS 解析查询",
    synopsis: "dig [@服务器] [选项] 域名 [类型]",
    descriptionLong:
      "向指定 DNS 服务器发送查询并打印完整应答，可用于排查解析结果、TTL、权威/递归链路以及 DNSSEC 状态。",
    options: [
      { flag: "@server", desc: "指定要查询的 DNS 服务器，省略则用系统配置" },
      { flag: "+short", desc: "只输出答案记录，便于脚本解析" },
      { flag: "+trace", desc: "从根开始递归追踪解析过程" },
      { flag: "+norecurse", desc: "禁用递归，仅检查目标是否为权威" },
      { flag: "+tcp", desc: "强制走 TCP，适合大应答或 UDP 截断场景" },
      { flag: "+dnssec", desc: "请求并显示 DNSSEC 相关 RR" },
      { flag: "-x", arg: "IP", desc: "反向解析（PTR 查询）" },
      { flag: "-t", arg: "类型", desc: "记录类型：A/AAAA/MX/TXT/NS/SOA/CNAME 等" },
      { flag: "-p", arg: "端口", desc: "目标 DNS 端口，默认 53" },
    ],
    examples: [
      { cmd: "dig www.example.com +short", desc: "只看 A 记录结果" },
      { cmd: "dig @8.8.8.8 example.com MX", desc: "向 8.8.8.8 查询 MX 记录" },
      { cmd: "dig +trace example.com", desc: "从根域开始追踪解析链路" },
      { cmd: "dig -x 10.10.10.1", desc: "对 10.10.10.1 做反向解析" },
    ],
    notes: "status: NOERROR/NXDOMAIN/SERVFAIL 是排错首要观察点；TTL 反映缓存命中。",
  },
  {
    name: "curl",
    example: "curl -I https://api.example.com/health",
    description: "HTTP 请求测试",
    synopsis: "curl [选项] URL ...",
    descriptionLong:
      "构造并发送 HTTP/HTTPS 请求，输出响应内容、头部或时序，是 API 联调与 7 层故障定位的核心工具。",
    options: [
      { flag: "-I", desc: "只取响应头（HEAD），用于探活" },
      { flag: "-i", desc: "同时输出响应头和响应体" },
      { flag: "-X", arg: "方法", desc: "指定 HTTP 方法 GET/POST/PUT 等" },
      { flag: "-H", arg: "头", desc: "添加请求头，可多次使用" },
      { flag: "-d", arg: "数据", desc: "发送请求体；自动使用 POST" },
      { flag: "--data-binary", arg: "@文件", desc: "原样发送文件内容，不做转义" },
      { flag: "-o", arg: "文件", desc: "把响应写入文件" },
      { flag: "-L", desc: "跟随 3xx 重定向" },
      { flag: "-k", desc: "忽略 TLS 证书校验（仅排错用）" },
      { flag: "--resolve", arg: "host:port:ip", desc: "本地强制 DNS，验证后端实例" },
      { flag: "-w", arg: "格式", desc: '自定义输出，例如 "%{time_total}\\n"' },
      { flag: "--max-time", arg: "秒", desc: "整体超时上限" },
      { flag: "-v", desc: "详细模式，打印 TLS / 请求头 / 响应头" },
    ],
    examples: [
      { cmd: "curl -I https://api.example.com/health", desc: "探活，只看状态码与头" },
      {
        cmd: 'curl -X POST -H "Content-Type: application/json" -d \'{"a":1}\' https://api.example.com/v1/echo',
        desc: "发送 JSON POST",
      },
      {
        cmd: 'curl -w "DNS:%{time_namelookup} 连接:%{time_connect} TLS:%{time_appconnect} 首字节:%{time_starttransfer} 总:%{time_total}\\n" -o /dev/null -s https://api.example.com/',
        desc: "分段计时，定位慢请求阶段",
      },
      {
        cmd: "curl --resolve api.example.com:443:10.10.10.55 https://api.example.com/",
        desc: "绕开 DNS 直连指定后端实例",
      },
    ],
    notes: "退出码常见：6=DNS 失败, 7=连接失败, 28=超时, 35=TLS 握手失败, 60=证书校验失败。",
  },
  {
    name: "ip",
    example: "ip addr",
    description: "查看网络接口与地址",
    synopsis: "ip [选项] 对象 {命令} [参数]",
    descriptionLong:
      "iproute2 提供的统一网络管理工具，覆盖地址、链路、路由、邻居、隧道等对象，是排查 L2/L3 配置的首选。",
    options: [
      { flag: "addr show", arg: "[dev 接口]", desc: "列出接口及其 IP 地址" },
      { flag: "link show", desc: "查看接口链路状态、MAC、MTU" },
      { flag: "route show", arg: "[table 表]", desc: "查看路由表，可指定表号" },
      { flag: "route get", arg: "目标IP", desc: "查询访问目标 IP 实际选用的路由" },
      { flag: "neigh show", desc: "查看 ARP/邻居缓存" },
      { flag: "rule show", desc: "查看策略路由规则" },
      { flag: "-s", desc: "显示统计计数（丢包/错误/字节）" },
      { flag: "-br", desc: "简洁单行输出，便于眼快扫" },
      { flag: "-4 / -6", desc: "限定 IPv4 / IPv6" },
    ],
    examples: [
      { cmd: "ip -br addr", desc: "一行一个接口，快速看 IP 分配" },
      { cmd: "ip -s link show eth0", desc: "看 eth0 的丢包与错误统计" },
      { cmd: "ip route get 10.20.30.40", desc: "确认实际走哪条路由出方向" },
      { cmd: "ip neigh show dev eth0", desc: "查 eth0 上的 ARP 邻居" },
    ],
    notes: "只读查询无需 root；增删改 (add/del) 需要 CAP_NET_ADMIN。",
  },
];

export const recentCommands = [
  "ping 10.10.10.1",
  "ip addr",
  "ip route",
  "dig www.example.com",
];

export const captureTasks: CaptureTask[] = [
  {
    id: "cap-001",
    name: "医保API抓包-0522",
    nodeCount: 2,
    status: "running",
    startTime: "2025-05-22 08:14",
    stopCondition: "A:10分钟/100MB；B:8分钟/80MB",
    resultFile: "处理中",
    resultSize: "-",
    nodes: [
      { node: "A-NODE", interface: "eth0", direction: "出向", protocol: "TCP", filter: "dst  10.10.10.20:443", size: "12.4 MB", duration: "00:03:42", fileName: "api-anode-0522.pcap" },
      { node: "B-NODE", interface: "eth1", direction: "双向", protocol: "TCP", filter: "src  10.10.10.20 -> dst  93.184.216.34:443", size: "9.7 MB", duration: "00:03:40", fileName: "api-bnode-0522.pcap" },
    ],
  },
  {
    id: "cap-002",
    name: "FTP抓包-0522",
    nodeCount: 1,
    status: "completed",
    startTime: "2025-05-22 07:40",
    stopCondition: "手动停止",
    resultFile: "1 个 pcap",
    resultSize: "-",
    nodes: [
      { node: "A-NODE", interface: "eth0", direction: "both", protocol: "TCP", filter: "port 21", size: "8.2 MB", duration: "05:12", fileName: "ftp-0522.pcap" },
    ],
  },
  {
    id: "cap-003",
    name: "数据库代理抓包-0522",
    nodeCount: 2,
    status: "running",
    startTime: "2025-05-22 08:31",
    stopCondition: "8分钟或80MB",
    resultFile: "处理中",
    resultSize: "-",
    nodes: [
      { node: "A-NODE", interface: "eth1", direction: "in", protocol: "TCP", filter: "dst 10.10.20.5:3306", size: "15.1 MB", duration: "08:00", fileName: "db-a-0522.pcap" },
      { node: "B-NODE", interface: "eth1", direction: "out", protocol: "TCP", filter: "src 10.10.20.5:3306", size: "14.8 MB", duration: "08:00", fileName: "db-b-0522.pcap" },
    ],
  },
  {
    id: "cap-004",
    name: "自定义抓包-0521",
    nodeCount: 1,
    status: "stopped",
    startTime: "2025-05-21 18:06",
    stopCondition: "文件大小 50MB",
    resultFile: "无",
    resultSize: "-",
    nodes: [
      { node: "C-NODE", interface: "eth0", direction: "both", protocol: "TCP", filter: "port 5672", size: "-", duration: "-", fileName: "custom-0521.pcap" },
    ],
  },
];

export const captureNodeParams: CaptureNodeParam[] = [
  { node: "A-NODE", interface: "eth0", direction: "both", protocol: "TCP", srcIp: "10.10.10.20", dstIp: "any", port: "443", fileName: "api-anode-0522.pcap" },
  { node: "B-NODE", interface: "eth0", direction: "both", protocol: "TCP", srcIp: "10.10.10.21", dstIp: "any", port: "443", fileName: "api-bnode-0522.pcap" },
];

export const troubleshootScenes: TroubleshootScene[] = [
  { id: "all", label: "全部业务", icon: "◎" },
  { id: "api", label: "API代理", icon: "⌘" },
  { id: "db", label: "数据库代理", icon: "◉" },
  { id: "ftp", label: "FTP文件摆渡", icon: "▣" },
  { id: "nfs", label: "NFS文件摆渡", icon: "▰" },
  { id: "mq", label: "消息队列代理", icon: "☷" },
];

export const step1Scenes = [
  "业务突然不通",
  "目标服务器不可达",
  "某服务响应很慢",
  "客户端返回403",
  "文件大量积压",
  "FTP无法读取目录",
  "代理性能不稳定",
  "全部网络中断",
  "服务器异常响应",
];

export const step2Checks: TroubleshootCheckItem[] = [
  { id: "s2-1", label: "Ping/ICMP", checked: true, description: "测试目标地址基础连通性" },
  { id: "s2-2", label: "DNS解析", checked: true, description: "验证域名解析是否正常" },
  { id: "s2-3", label: "ARP检查", checked: false, description: "检查ARP表项与冲突" },
  { id: "s2-4", label: "抓包", checked: false, description: "在链路上抓取报文分析" },
  { id: "s2-5", label: "端口开放性", checked: true, description: "探测目标端口是否开放" },
  { id: "s2-6", label: "路由检查", checked: true, description: "检查路由表与策略路由" },
  { id: "s2-7", label: "连接数检查", checked: false, description: "检查当前连接数与限制" },
  { id: "s2-8", label: "TLS握手", checked: false, description: "验证TLS证书与握手过程" },
];

export const step3Checks: TroubleshootCheckItem[] = [
  { id: "s3-1", label: "代理进程存活", checked: true },
  { id: "s3-2", label: "CPU", checked: true },
  { id: "s3-3", label: "内存", checked: true },
  { id: "s3-4", label: "端口监听", checked: true },
  { id: "s3-5", label: "连接池", checked: false },
  { id: "s3-6", label: "线程/句柄", checked: false },
  { id: "s3-7", label: "I/O等待", checked: false },
  { id: "s3-8", label: "Netstat队列", checked: false },
  { id: "s3-9", label: "服务重启记录", checked: false },
];

export const step4Checks: TroubleshootCheckItem[] = [
  { id: "s4-1", label: "用户认证", checked: true },
  { id: "s4-2", label: "API Token/签名", checked: true },
  { id: "s4-3", label: "FTP目录访问", checked: false },
  { id: "s4-4", label: "ACL", checked: false },
  { id: "s4-5", label: "密码/密钥", checked: false },
  { id: "s4-6", label: "数据库账号权限", checked: false },
  { id: "s4-7", label: "NFS挂载权限", checked: false },
  { id: "s4-8", label: "证书有效期", checked: true },
];

export const step5Checks: TroubleshootCheckItem[] = [
  { id: "s5-1", label: "黑名单", checked: true },
  { id: "s5-2", label: "白名单", checked: true },
  { id: "s5-3", label: "关键词规则", checked: false },
  { id: "s5-4", label: "ACL策略", checked: true },
  { id: "s5-5", label: "防火墙/访问控制", checked: false },
  { id: "s5-6", label: "通道开关状态", checked: true },
];

export const step6Evidences: EvidenceItem[] = [
  { id: "e1", label: "抓包文件", checked: true },
  { id: "e2", label: "系统日志", checked: true },
  { id: "e3", label: "业务日志", checked: true },
  { id: "e4", label: "代理配置日志", checked: false },
  { id: "e5", label: "配置快照", checked: false },
  { id: "e6", label: "策略命中记录", checked: true },
  { id: "e7", label: "异常连接样本", checked: false },
  { id: "e8", label: "时间线摘要", checked: false },
];

export const step7Methods = [
  { id: "api", label: "API请求验证", icon: "🔌" },
  { id: "db", label: "数据库连接验证", icon: "🗄️" },
  { id: "ftp", label: "FTP列目录+下载校验", icon: "📁" },
  { id: "nfs", label: "NFS读写验证", icon: "📂" },
];

export const step8Conclusions = [
  { label: "安全策略误拦截", confidence: 42 },
  { label: "上游服务响应慢", confidence: 28 },
  { label: "连接数接近上限", confidence: 16 },
];

export const step8Recommendations = [
  "检查目标目录 ACL 与账号权限",
  "核对安全策略白名单",
  "修复后重试业务验证",
  "导出证据包提交复盘",
];

// === Troubleshoot Mock Data ===

import type {
  BizSceneOption,
  SceneTag,
  EvidenceItem as TEvidenceItem,
  CheckItem,
  PolicyHitRecord,
} from "./diagnosis-types";

export const bizSceneOptions: BizSceneOption[] = [
  { id: "ftp", label: "FTP 文件传输", icon: "📁", defaultPort: 21, defaultProtocol: "TCP" },
  { id: "sftp", label: "SFTP 安全传输", icon: "🔐", defaultPort: 22, defaultProtocol: "TCP" },
  { id: "web", label: "Web / API 代理", icon: "🌐", defaultPort: 443, defaultProtocol: "TCP" },
  { id: "database", label: "数据库代理", icon: "🗄️", defaultPort: 3306, defaultProtocol: "TCP" },
  { id: "mq", label: "消息队列代理", icon: "📨", defaultPort: 5672, defaultProtocol: "TCP" },
];

export const sceneTags: SceneTag[] = [
  { id: "timeout", label: "连接超时/拒绝", icon: "⏱️", bizTypes: ["ftp", "sftp", "web", "database", "mq"] },
  { id: "slow", label: "响应缓慢", icon: "🐢", bizTypes: ["ftp", "sftp", "web", "database", "mq"] },
  { id: "auth-fail", label: "认证失败", icon: "🔒", bizTypes: ["ftp", "sftp", "web", "database"] },
  { id: "transfer-break", label: "传输中断", icon: "✂️", bizTypes: ["ftp", "sftp", "mq"] },
  { id: "permission-denied", label: "权限不足", icon: "🚫", bizTypes: ["ftp", "sftp", "web", "database"] },
  { id: "dir-unreachable", label: "目录不可访问", icon: "📂", bizTypes: ["ftp", "sftp", "database"] },
  { id: "error-4xx-5xx", label: "返回 4xx/5xx", icon: "❌", bizTypes: ["web"] },
  { id: "ssl-fail", label: "SSL/TLS 握手失败", icon: "🔐", bizTypes: ["web"] },
  { id: "query-slow", label: "查询缓慢", icon: "🐌", bizTypes: ["database"] },
  { id: "write-fail", label: "写入失败", icon: "📝", bizTypes: ["database", "mq"] },
  { id: "lock-wait", label: "锁等待", icon: "🔏", bizTypes: ["database"] },
  { id: "pool-exhausted", label: "连接池耗尽", icon: "🏊", bizTypes: ["database", "mq"] },
  { id: "msg-backlog", label: "消息堆积", icon: "📚", bizTypes: ["mq"] },
  { id: "consume-delay", label: "消费延迟", icon: "⏳", bizTypes: ["mq"] },
  { id: "policy-block", label: "策略阻断", icon: "🛡️", bizTypes: ["ftp", "sftp", "web"] },
];

export const defaultNetworkChecks: CheckItem[] = [
  { id: "ping", label: "Ping 连通性", checked: true },
  { id: "traceroute", label: "Traceroute 路由追踪", checked: true },
  { id: "dns", label: "DNS 解析测试", checked: true },
  { id: "tcp-connect", label: "TCP 端口连通", checked: true },
  { id: "tcp-handshake", label: "TCP 握手时延", checked: false },
  { id: "tls-handshake", label: "TLS/SSL 握手测试", checked: false },
  { id: "bandwidth", label: "带宽测试 (iperf)", checked: false },
  { id: "mtu", label: "路径 MTU 探测", checked: false },
];

export const defaultResourceChecks: CheckItem[] = [
  { id: "cpu", label: "CPU 使用率", checked: true, threshold: 80, unit: "%" },
  { id: "memory", label: "内存使用率", checked: true, threshold: 85, unit: "%" },
  { id: "load", label: "系统 Load", checked: true, threshold: 5.0, unit: "" },
  { id: "connections", label: "连接数", checked: true, threshold: 10000, unit: "" },
  { id: "send-q", label: "Send-Q 堆积", checked: false, threshold: 1000, unit: "" },
  { id: "recv-q", label: "Recv-Q 堆积", checked: false, threshold: 1000, unit: "" },
  { id: "thread-pool", label: "线程池占用", checked: true, threshold: 90, unit: "%" },
  { id: "fd", label: "文件句柄 FD", checked: false, threshold: 65535, unit: "" },
  { id: "disk-io", label: "磁盘 I/O 等待", checked: false, threshold: 20, unit: "%" },
  { id: "bandwidth-usage", label: "网络带宽使用", checked: false, threshold: 80, unit: "%" },
];

export const defaultPermissionChecks: CheckItem[] = [
  { id: "account-valid", label: "账号有效性验证", checked: true },
  { id: "credential", label: "密码/凭证正确性", checked: true },
  { id: "read-dir", label: "目标目录读权限", checked: true },
  { id: "write-dir", label: "目标目录写权限", checked: true },
  { id: "list-dir", label: "目录列表权限", checked: true },
  { id: "recursive", label: "子目录递归权限", checked: false },
  { id: "ip-whitelist", label: "IP 白名单检查", checked: true },
  { id: "time-window", label: "时间窗口限制检查", checked: false },
  { id: "conn-limit", label: "并发连接数限制", checked: false },
];

export const defaultEvidenceItems: TEvidenceItem[] = [
  { id: "pcap", label: "抓包文件 (PCAP)", checked: true },
  { id: "net-conn", label: "网络连接状态快照", checked: true },
  { id: "dns-record", label: "DNS 解析记录", checked: true },
  { id: "process", label: "代理进程状态", checked: true },
  { id: "resource-snapshot", label: "系统资源快照", checked: true },
  { id: "thread-dump", label: "线程/协程 Dump", checked: false },
  { id: "access-log", label: "应用访问日志", checked: true },
  { id: "auth-log", label: "认证/授权日志", checked: true },
  { id: "policy-log", label: "策略命中日志", checked: true },
  { id: "audit-log", label: "系统审计日志", checked: false },
  { id: "proxy-config", label: "代理配置文件", checked: true },
  { id: "policy-config", label: "策略规则配置", checked: true },
  { id: "route-config", label: "路由/转发规则", checked: true },
];

export const mockPolicyResults: PolicyHitRecord[] = [
  { time: "2025-05-19 10:23:41", ruleName: "KEYWORD-BLOCK-01", action: "拦截", object: "文件内容扫描", reason: "命中敏感关键词" },
  { time: "2025-05-19 10:15:22", ruleName: "ACL-FTP-READ", action: "拒绝", object: "目标目录", reason: "目录不在允许列表" },
  { time: "2025-05-19 09:58:10", ruleName: "BLACKLIST-IP-SET", action: "拦截", object: "源地址 10.10.10.23", reason: "命中黑名单" },
  { time: "2025-05-19 09:42:03", ruleName: "FW-OUTBOUND-DENY", action: "拒绝", object: "目的端口 21", reason: "出站策略限制" },
  { time: "2025-05-19 08:15:33", ruleName: "RATE-LIMIT-API", action: "限流", object: "API 接口", reason: "超过 QPS 阈值" },
];

export const mockVerifyMethods = [
  { id: "ping", label: "Ping 连通测试", icon: "📡" },
  { id: "port", label: "端口连通测试", icon: "🔌" },
  { id: "business", label: "业务请求模拟", icon: "🔄" },
  { id: "permission", label: "权限验证测试", icon: "🔑" },
  { id: "bandwidth", label: "带宽测试", icon: "📊" },
  { id: "stress", label: "并发压力测试", icon: "⚡" },
];

export const mockConclusionOthers = [
  { label: "ACL 策略阻断", confidence: 45 },
  { label: "账号凭证过期", confidence: 23 },
  { label: "网络时延异常", confidence: 12 },
  { label: "代理进程异常", confidence: 8 },
];

export const mockRecommendations = [
  "检查并调整目标目录权限，确认 biz_transfer_s01 对 /data/transfer/exports/inbound 有读写权限",
  "审查 ACL-FTP-READ 策略，确认该目录在白名单中",
  "验证账号状态，确认账号未被锁定或过期",
  "检查代理进程日志，查看是否有其他异常记录",
];

// === Biz Linkage Config ===

import type { BizLinkageConfig } from "./diagnosis-types";

export const bizLinkageMap: Record<string, BizLinkageConfig> = {
  web: {
    bizType: "web",
    networkTools: [
      { id: "curl", label: "CURL 请求测试", commandTemplate: "curl -s -o /dev/null -w \"%{http_code}\" http://{address}:{port}{path}", description: "发送 HTTP/HTTPS 请求验证接口响应" },
      { id: "openssl", label: "OpenSSL TLS 握手", commandTemplate: "openssl s_client -connect {address}:{port} </dev/null", description: "验证 TLS/SSL 证书与握手" },
      { id: "dig", label: "DNS 解析", commandTemplate: "dig +time=5 {domain}", description: "验证域名解析" },
      { id: "ping", label: "Ping 连通", commandTemplate: "ping -c 4 {address}", description: "测试目标地址基础连通性" },
      { id: "nc", label: "端口连通", commandTemplate: "nc -zv -w 5 {address} {port}", description: "探测目标端口是否开放" },
      { id: "traceroute", label: "路由追踪", commandTemplate: "traceroute -m 15 {address}", description: "追踪路由路径" },
    ],
    captureFilter: "dst port 80 or 443 or 8080",
    configuredInterfaces: [
      { name: "医保 API 网关", address: "10.10.20.100", port: 443, path: "/api/v1/health", description: "医保核心业务 API 网关" },
      { name: "文件交换 API", address: "10.10.20.101", port: 8080, path: "/transfer/status", description: "文件摆渡状态查询接口" },
      { name: "认证中心", address: "10.10.20.102", port: 443, path: "/oauth/token", description: "统一认证与授权服务" },
    ],
    forcedProcesses: ["nginx", "traefik", "apisix-proxy"],
    emphasisMetrics: ["connections", "thread-pool", "bandwidth-usage"],
    authMethods: ["Key/Secret", "OAuth2", "JWT", "Basic Auth", "mTLS"],
    permissionFocus: "API 认证方式、证书配置、IP 白名单与限流策略",
    policyTypes: ["blacklist", "whitelist", "keyword", "acl", "channel"],
    policyFocus: "Rate Limiting、请求体大小限制、关键词过滤、访问控制",
    verifyTools: [
      { id: "ping", label: "Ping 连通测试", icon: "📡" },
      { id: "port", label: "端口连通测试", icon: "🔌" },
      { id: "business", label: "HTTP 请求模拟", icon: "🔄" },
      { id: "permission", label: "API 权限验证", icon: "🔑" },
      { id: "bandwidth", label: "带宽测试", icon: "📊" },
      { id: "stress", label: "并发压力测试", icon: "⚡" },
    ],
    evidenceFocus: ["pcap", "net-conn", "access-log", "auth-log", "proxy-config", "policy-config", "route-config"],
    conclusionIndicators: ["HTTP 状态码分布", "TLS 握手结果", "策略命中记录", "响应时间趋势"],
  },
  ftp: {
    bizType: "ftp",
    networkTools: [
      { id: "ftp", label: "FTP 连接测试", commandTemplate: "ftp -n {address} {port}", description: "建立 FTP 连接并验证登录" },
      { id: "nc", label: "端口连通", commandTemplate: "nc -zv -w 5 {address} {port}", description: "探测 FTP 控制端口" },
      { id: "telnet", label: "Telnet 握手", commandTemplate: "telnet {address} {port}", description: "验证 FTP 服务 banner" },
      { id: "ping", label: "Ping 连通", commandTemplate: "ping -c 4 {address}", description: "测试目标地址基础连通性" },
    ],
    captureFilter: "port 21 or portrange 40000-50000",
    configuredInterfaces: [
      { name: "医保 FTP 通道", address: "10.10.20.50", port: 21, description: "医保文件交换 FTP 服务器" },
      { name: "财务 FTP 通道", address: "10.10.20.51", port: 21, description: "财务报账文件传输服务器" },
    ],
    forcedProcesses: ["ftp-proxy", "vsftpd", "pure-ftpd"],
    emphasisMetrics: ["send-q", "recv-q", "disk-io", "bandwidth-usage"],
    authMethods: ["用户名密码", "匿名访问"],
    permissionFocus: "目标目录读写权限、被动模式配置、匿名访问策略",
    policyTypes: ["blacklist", "whitelist", "acl", "channel"],
    policyFocus: "文件类型过滤、文件大小限制、访问控制",
    verifyTools: [
      { id: "ping", label: "Ping 连通测试", icon: "📡" },
      { id: "port", label: "端口连通测试", icon: "🔌" },
      { id: "business", label: "FTP 连接验证", icon: "📁" },
      { id: "permission", label: "目录权限验证", icon: "🔑" },
    ],
    evidenceFocus: ["pcap", "access-log", "proxy-config"],
    conclusionIndicators: ["FTP 响应码", "目录权限状态", "传输队列堆积", "策略命中记录"],
  },
  sftp: {
    bizType: "sftp",
    networkTools: [
      { id: "sftp", label: "SFTP 连接测试", commandTemplate: "sftp -o ConnectTimeout=5 {account}@{address}", description: "建立 SFTP 连接并验证" },
      { id: "ssh", label: "SSH 握手测试", commandTemplate: "ssh -o ConnectTimeout=5 -o BatchMode=yes {account}@{address} echo OK", description: "验证 SSH 握手与认证" },
      { id: "nc", label: "端口连通", commandTemplate: "nc -zv -w 5 {address} {port}", description: "探测 SSH 端口" },
      { id: "ping", label: "Ping 连通", commandTemplate: "ping -c 4 {address}", description: "测试目标地址基础连通性" },
    ],
    captureFilter: "port 22",
    configuredInterfaces: [
      { name: "医保 SFTP 通道", address: "10.10.20.60", port: 22, description: "医保安全文件传输服务器" },
      { name: "跨网 SFTP 通道", address: "10.10.20.61", port: 22, description: "跨网隔离区 SFTP 网关" },
    ],
    forcedProcesses: ["sftp-proxy", "sshd", "openssh-sftp-server"],
    emphasisMetrics: ["send-q", "recv-q", "disk-io", "bandwidth-usage"],
    authMethods: ["SSH 密钥", "用户名密码"],
    permissionFocus: "SSH 密钥认证、KnownHosts 配置、目标目录递归读写权限",
    policyTypes: ["blacklist", "whitelist", "keyword", "acl", "channel"],
    policyFocus: "文件内容扫描、敏感关键词过滤、访问控制",
    verifyTools: [
      { id: "ping", label: "Ping 连通测试", icon: "📡" },
      { id: "port", label: "端口连通测试", icon: "🔌" },
      { id: "business", label: "SFTP 连接验证", icon: "📁" },
      { id: "permission", label: "目录权限验证", icon: "🔑" },
    ],
    evidenceFocus: ["pcap", "access-log", "auth-log", "proxy-config"],
    conclusionIndicators: ["SSH 握手结果", "目录权限状态", "密钥认证状态", "策略命中记录"],
  },
  database: {
    bizType: "database",
    networkTools: [
      { id: "mysql", label: "MySQL 连接测试", commandTemplate: "mysql -h {address} -P {port} -u {account} -e \"SELECT 1\"", description: "验证数据库连接与简单查询" },
      { id: "nc", label: "端口连通", commandTemplate: "nc -zv -w 5 {address} {port}", description: "探测数据库端口" },
      { id: "ping", label: "Ping 连通", commandTemplate: "ping -c 4 {address}", description: "测试目标地址基础连通性" },
    ],
    captureFilter: "port 3306 or 5432 or 6379",
    configuredInterfaces: [
      { name: "医保核心库", address: "10.10.20.70", port: 3306, description: "医保业务主数据库" },
      { name: "审计库", address: "10.10.20.71", port: 3306, description: "审计日志数据库" },
      { name: "Redis 缓存", address: "10.10.20.72", port: 6379, description: "会话缓存 Redis" },
    ],
    forcedProcesses: ["db-proxy", "mysql-proxy", "redis-server"],
    emphasisMetrics: ["connections", "thread-pool", "send-q", "recv-q"],
    authMethods: ["用户名密码", "SSL 证书"],
    permissionFocus: "数据库账号权限、表级权限、Schema 访问权限",
    policyTypes: ["blacklist", "whitelist", "acl", "channel"],
    policyFocus: "SQL 注入检测、敏感操作拦截（DROP/DELETE）、访问控制",
    verifyTools: [
      { id: "ping", label: "Ping 连通测试", icon: "📡" },
      { id: "port", label: "端口连通测试", icon: "🔌" },
      { id: "business", label: "DB 连接验证", icon: "🗄️" },
      { id: "permission", label: "查询权限验证", icon: "🔑" },
    ],
    evidenceFocus: ["pcap", "net-conn", "access-log", "auth-log", "proxy-config"],
    conclusionIndicators: ["查询响应时间", "连接池使用率", "权限检查结果", "策略命中记录"],
  },
  mq: {
    bizType: "mq",
    networkTools: [
      { id: "rabbitmqadmin", label: "RabbitMQ 管理测试", commandTemplate: "rabbitmqadmin -H {address} -P {port} list queues", description: "验证 MQ 管理接口与队列状态" },
      { id: "nc", label: "端口连通", commandTemplate: "nc -zv -w 5 {address} {port}", description: "探测 MQ 端口" },
      { id: "ping", label: "Ping 连通", commandTemplate: "ping -c 4 {address}", description: "测试目标地址基础连通性" },
    ],
    captureFilter: "port 5672 or 9092",
    configuredInterfaces: [
      { name: "医保消息总线", address: "10.10.20.80", port: 5672, description: "医保业务消息队列" },
      { name: "Kafka 日志流", address: "10.10.20.81", port: 9092, description: "审计日志 Kafka 集群" },
    ],
    forcedProcesses: ["mq-proxy", "rabbitmq-server", "kafka-broker"],
    emphasisMetrics: ["connections", "send-q", "recv-q", "thread-pool"],
    authMethods: ["用户名密码", "OAuth2"],
    permissionFocus: "队列读写权限、虚拟主机权限、Exchange 绑定权限",
    policyTypes: ["blacklist", "whitelist", "keyword", "acl", "channel"],
    policyFocus: "消息内容过滤、消息大小限制、访问控制",
    verifyTools: [
      { id: "ping", label: "Ping 连通测试", icon: "📡" },
      { id: "port", label: "端口连通测试", icon: "🔌" },
      { id: "business", label: "消息收发验证", icon: "📨" },
      { id: "bandwidth", label: "带宽测试", icon: "📊" },
    ],
    evidenceFocus: ["pcap", "access-log", "proxy-config", "policy-config"],
    conclusionIndicators: ["消息堆积数", "消费延迟", "连接池使用率", "策略命中记录"],
  },
};
