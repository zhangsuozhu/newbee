import ctypes
import json
import os
from collections import defaultdict
from datetime import datetime, time

from django.db import connection

from apps.common.utils import check_port_is_open, IPUtils
from components.utils import sync_conn

cursor = connection.cursor()

DB_VERSION_MAPPING = {
    '1': '0X01',  # define DB_MYSQL_VERSION_NB_5_0         0X01
    '2': '0X02',  # define DB_MYSQL_VERSION_NB_5_1         0X02
    '3': '0X04',  # define DB_MYSQL_VERSION_NB_5_5         0X04
    '4': '0X08',  # define DB_MYSQL_VERSION_NB_5_6         0X08
    '5': '0X10',  # define DB_MYSQL_VERSION_NB_5_7         0X10
    '6': '0X20',  # define DB_MYSQL_VERSION_NB_8_0         0X20
    '7': '0X01',  # define DB_ORACLE_VERSION_NB_10_G       0X01
    '8': '0X02',  # define DB_ORACLE_VERSION_NB_11_G       0X02
    '9': '0X04',  # define DB_ORACLE_VERSION_NB_12_C       0X04
    '10': '0X08',  # define DB_ORACLE_VERSION_NB_18_C       0X08
    '11': '0X10',  # define DB_ORACLE_VERSION_NB_19_C       0X10
    '12': '0X01',  # define DB_SQLSERVER_VERSION_NB_2005    0X01
    '13': '0X02',  # define DB_SQLSERVER_VERSION_NB_2008    0X02
    '14': '0X04',  # define DB_SQLSERVER_VERSION_NB_2012    0X04
    '15': '0X08',  # define DB_SQLSERVER_VERSION_NB_2014    0X08
    '16': '0X10',  # define DB_SQLSERVER_VERSION_NB_2016    0X10
    '17': '0X28',  # define DB_SQLSERVER_VERSION_NB_2017    0X28
    '18': '0X40',  # define DB_SQLSERVER_VERSION_NB_2019    0X40
    '19': '0X01',  # define DB_KING_VERSION_NB_V8           0X01
    '20': '0X01',  # define DB_DAMENG_VERSION_NB_DM8        0X01
}
# PROTOCOL_TYPE_MAPPING 中 key 值是数据库中保存的，value 由引擎提供
PROTOCOL_TYPE_MAPPING = {
    1: 'ssh_switch',
    2: 'rdp_switch',
    3: 'vnc_switch',
    4: 'teamviewer_switch',
    5: 'sunlogin_switch',
    6: 'telnet_switch',
}


class TCPConfigHandler(object):
    static_info = """
listen stats
    mode http
    #bind *:8080
    option httplog #启用日志记录HTTP请求，默认haproxy日志记录是不记录HTTP请求
    stats enable # 启用状态统计报告
    stats refresh 1s # 统计页面自动刷新时间
    stats hide-version # 隐藏统计页面上HAProxy的版本信息
    #stats show-node
    stats auth admin:Guoyu@657 # 设置统计页面用户名和密码设置
    stats uri  /haproxy?stats  #定义统计页面的URL，默认为/haproxy?stats
    stats admin if TRUE    #如果认证通过就做管理功能，可以管理后端的服务器
    stats realm “LOGIN”   #登陆页面提示信息
"""

    def __init__(self):
        self.static_content = self.get_static_content()
        self.flow_control_dict = {}
        self.flow_control_id_list = []
        self.template_dict = {}
        self.keyword_dict = {}
        self.connect_rate_dict = {}
        self.concurrency_dict = {}
        self.remote_access_dict = {}
        self.db_access_dict = {}
        self.time_limit_dict = {}
        self.occupied_ports = []
        self.id_port_dict = {}
        self.cert_path_dict = {}
        self.health_channel_id = 0

    @staticmethod
    def get_static_content():
        ha_flag = '0'
        if models.HostBackup.objects.filter(enable=True).exists():
            ha_flag = '1'
        static_content = f"""
global
    log         127.0.0.1 local0
    user        root
    group       root
    daemon
    maxconn     0
    ha_running_flag  {ha_flag}

defaults
    mode                    tcp
    log                     global
    option                  tcpka
    option                  dontlognull
    retries                 3
    timeout connect         5s
    # timeout client          5m
    # timeout server          5m
    # timeout check           5s
    log-format "client,%Td,%t,%ci:%cp,%ft,%fi:%fp,%bi:%bp,%si:%sp,%Tw/%Tc/%Tt,%B,%ts,%ac/%fc/%bc/%sc/%rc,%sq/%b,"""
        return static_content

    @staticmethod
    def get_usable_ports(num, port_list=None):
        rsp_data = []
        for port in range(1024, 65535):
            if port_list and port in port_list:
                continue
            # 如果未被系统占用则添加到列表中
            if check_port_is_open(port):
                rsp_data.append(port)
                num -= 1
                if num == 0:
                    return rsp_data

    def get_template_conf(self, channel_list):
        """应用数据控制"""
        self.template_dict.clear()
        queryset = APPDataControl.objects.filter(service_id__in=channel_list).values('service_id', 'direction')
        for headers_obj in queryset:
            direction_list = headers_obj.get('direction')
            backend_name = headers_obj.get('service_id')
            template_content = ""
            for direction in direction_list:
                if direction == 1:
                    template_content = template_content + f"    up_template_name {backend_name}-{direction} \n"
                elif direction == 2:
                    template_content = template_content + f"    down_template_name {backend_name}-{direction} \n"
            self.template_dict[backend_name] = template_content

    def get_keyword_conf(self, channel_list):
        """敏感字过滤"""
        self.keyword_dict.clear()
        queryset = KeywordFilterData.objects.filter(service_id__in=channel_list).values('service_id')
        for obj in queryset:
            service_id = obj.get('service_id')
            self.keyword_dict[service_id] = f"   keyword_name transfer_id_{service_id}\n "

    def get_concurrency_conf(self, channel_list):
        """并发控制"""
        self.concurrency_dict.clear()
        queryset = ConcurrencyControl.objects.filter(service_id__in=channel_list).values('service_id',
                                                                                         'concurrency_count')
        for obj in queryset:
            content = obj['concurrency_count']
            self.concurrency_dict[obj.get('service_id')] = f"    maxconn {content}\n "

    def get_connect_rate_conf(self, channel_list):
        """链接速率"""
        self.connect_rate_dict.clear()
        queryset = ConnectRateControl.objects.filter(service_id__in=channel_list).values('service_id',
                                                                                         'connection_count')
        for obj in queryset:
            self.connect_rate_dict[obj.get('service_id')] = f"    rate-limit sessions {obj.get('connection_count')}\n"

    @staticmethod
    def flow_conversion(flow_num):
        """流量控制数值转换"""
        # 引擎只支持 8G，产品经理要求页面上能填 10 G
        if flow_num > 8388608:
            flow_num = 8388608
        if flow_num > 8:
            flow_num = flow_num // 8  # 引擎开发要求转换进制, 小数点后的数字直接扔掉
        else:
            flow_num = 1  # 小于 8 时按最小值 1
        unit_index = 0
        while flow_num > 1024:
            flow_num = round(flow_num / 1024)
            unit_index += 1
        unit_list = ['k', 'm', 'g']  # 引擎最大8G
        unit = unit_list[unit_index]
        return flow_num, unit

    def get_flow_control_conf(self, id_list):
        """流量控制"""
        self.flow_control_dict.clear()
        data = FlowControl.objects.filter(service__in=id_list).values('service_id', 'id', 'direction', 'flow_up_limit',
                                                                      'flow_down_limit')
        for keyword_obj in data:
            up_name = f'flow_up_{keyword_obj.get("id")}'
            down_name = f'flow_down_{keyword_obj.get("id")}'
            up_max_flow = keyword_obj.get('flow_up_limit')
            down_max_flow = keyword_obj.get('flow_down_limit')
            self.flow_control_id_list.append(keyword_obj.get("id"))
            flow_control_conf_list = []
            direction = json.loads(keyword_obj['direction'])
            if 1 in direction:
                up_max_flow, up_unit = self.flow_conversion(up_max_flow)
                # 配置了上行，增加上行流量控制的配置
                flow_control_conf_list.extend([
                    f"    filter bwlim-in {up_name} default-limit {int(up_max_flow)}{up_unit} default-period 1s",
                    f"    tcp-request content set-bandwidth-limit {up_name}",
                ])
            else:
                flow_control_conf_list.extend([
                    f"    filter bwlim-in {up_name} default-limit 1G default-period 1s",
                    f"    tcp-request content set-bandwidth-limit {up_name}",
                ])
            if 2 in direction:
                down_max_flow, down_unit = self.flow_conversion(down_max_flow)
                # 配置了下行，增加下行流量控制的配置
                flow_control_conf_list.extend([
                    f"    filter bwlim-out {down_name} default-limit {int(down_max_flow)}{down_unit} default-period 1s",
                    f"    tcp-request content set-bandwidth-limit {down_name}",
                ])
            else:
                flow_control_conf_list.extend([
                    f"    filter bwlim-out {down_name} default-limit 1G default-period 1s",
                    f"    tcp-request content set-bandwidth-limit {down_name}",
                ])
            flow_control_conf = "\n".join(flow_control_conf_list)
            self.flow_control_dict[keyword_obj.get('service_id')] = flow_control_conf
        for ser_id in id_list:
            if ser_id in self.flow_control_dict:
                continue
            flow_control_str = f'    filter bwlim-in flow_up_{ser_id} default-limit 1G default-period 1s\n' \
                               f'    tcp-request content set-bandwidth-limit flow_up_{ser_id}\n    filter bwlim-out ' \
                               f'flow_down_{ser_id} default-limit 1G default-period 1s\n    tcp-request content ' \
                               f'set-bandwidth-limit flow_down_{ser_id}'

            self.flow_control_dict[ser_id] = flow_control_str

    def get_remote_access_conf(self, channel_list):
        """远程阻断控制"""
        self.remote_access_dict.clear()
        queryset = RemoteAccess.objects.filter(service_id__in=channel_list).values('service_id', 'protocol_type')
        for obj in queryset:
            result = ''
            protocol_type = obj['protocol_type']
            for protocol_type in protocol_type:
                protocol_type_str = PROTOCOL_TYPE_MAPPING.get(int(protocol_type))
                result += f"    {protocol_type_str} open\n"
                self.remote_access_dict[obj.get('service_id')] = result

    def get_db_access_conf(self, channel_list):
        """数据库访问控制"""
        self.db_access_dict.clear()
        queryset = DBAccessControl.objects.filter(service_id__in=channel_list).values('service_id', 'db_type',
                                                                                      'db_version')
        for obj in queryset:
            db_type = obj['db_type']
            if db_type == "tdsql":
                db_type = "mysql"
            result = None
            for version in obj['db_version']:
                version_hex_str = DB_VERSION_MAPPING.get(str(version))
                if result is None:
                    result = int(version_hex_str, 16)
                else:
                    result |= int(version_hex_str, 16)  # 引擎要求转换进制后，用逻辑或

                self.db_access_dict[obj.get('service_id')] = f"    {db_type} {result}\n"

    def get_cert_conf(self, channel_list):
        """证书配置"""
        self.cert_path_dict.clear()
        queryset = Certification.objects.filter(service_id__in=channel_list).values('id','service_id')
        for obj in queryset:
            server_file_path = os.path.join('/etc/certs_haproxy/', f'server_{str(obj.get("id"))}.pem')
            ca_file_path = os.path.join('/etc/certs_haproxy/', f'ca_{str(obj.get("id"))}.crt')
            self.cert_path_dict[obj.get('service_id')] = f" crt {server_file_path} ca-file {ca_file_path}"

    def get_time_limit_conf(self, channel_list):
        """时间段控制"""
        self.time_limit_dict.clear()
        queryset = TimeLimit.objects.filter(service_id__in=channel_list).defer('control_type', 'create_time',
                                                                               'update_time')
        for time_limit in queryset:
            now = datetime.now()
            # 先判断大时间范围
            if time_limit.big_period_type:
                if time_limit.big_period_type == 5:  # 自定义，有日期 + 时间范围
                    begin_date = time_limit.begin_day
                    end_date = time_limit.end_day
                elif time_limit.big_period_type == 1:  # 长期有效
                    begin_date = datetime.combine(now.date(), time(0, 0))
                    end_date = datetime.combine(now.date(), time(23, 59, 59))
                else:
                    # 一周、一月、一年，有日期 + 时间
                    begin_date = time_limit.origin_begin_day
                    end_date = time_limit.origin_end_day
                if now < begin_date or now > end_date:
                    self.time_limit_dict[time_limit.service_id] = "    channel-enable 0\n"
                    continue

            # 比较小周期
            if time_limit.small_period_type:
                # 用户设定了时段周期，需更新时、分、秒
                if time_limit.small_period_type == 3:  # 自定义时间
                    begin_time = time_limit.begin_hour
                    end_time = time_limit.end_hour
                else:
                    # 固定的上下午两个时间点
                    begin_time = time(8, 0)
                    end_time = time(18, 0)
                if time_limit.small_period_type in {1, 3}:
                    if now.time() < begin_time or now.time() > end_time:
                        self.time_limit_dict[time_limit.service_id] = "    channel-enable 0\n"
                        continue
                else:
                    if begin_time < now.time() < end_time:
                        self.time_limit_dict[time_limit.service_id] = "    channel-enable 0\n"
                        continue
            self.time_limit_dict[time_limit.service_id] = ""

    def get_engine_health_cfg(self):

        port = self.id_port_dict.get(self.health_channel_id)
        o_cfg = f'frontend {self.health_channel_id}\n' \
                  f'    bind 1.1.1.4:{port} namespace secif\n' \
                  f'    use_backend {self.health_channel_id}\n' \
                  f'backend {self.health_channel_id}\n' \
                  f'    balance     roundrobin\n' \
                  f'    server   {self.health_channel_id} 127.0.0.1:5555\n'

        a_cfg = f'frontend {self.health_channel_id}\n' \
                f'    bind 1.1.1.2:{port} namespace secif\n' \
                f'    use_backend {self.health_channel_id}\n' \
                f'backend {self.health_channel_id}\n' \
                f'    balance     roundrobin\n' \
                f'    server   {self.health_channel_id} 127.0.0.1:5555\n'

        i_cfg = f'frontend {self.health_channel_id}\n' \
                  f'    bind 127.0.0.1:5555\n' \
                  f'    default_backend {self.health_channel_id}\n' \
                  f'backend {self.health_channel_id}\n' \
                  f'    balance     roundrobin\n' \
                  f'    server   node1 1.1.1.4:{port} namespace secif\n'

        m_cfg = f'frontend {self.health_channel_id}\n' \
                f'    bind 127.0.0.1:5555\n' \
                f'    default_backend {self.health_channel_id}\n' \
                f'backend {self.health_channel_id}\n' \
                f'    balance     roundrobin\n' \
                f'    server   node1 1.1.1.2:{port} namespace secif\n'

        return i_cfg, o_cfg, m_cfg, a_cfg

    def get_cfg_content(self, obj, need_time_limit=True):
        """
        请求方 是i到o ,服务方 m到a
        """
        server_name = 'node1'
        # front_name = f'tcp_front{obj.id}'
        front_name = obj.id
        backend_name = obj.id
        server_port = self.id_port_dict.get(obj.id)
        # backend_name = f'tcp_back{obj.id}'
        if obj.direction == 1:
            node_ip = '1.1.1.4'
        else:
            node_ip = '1.1.1.2'
        template_str = self.template_dict.get(obj.id, '')
        keyword_str = self.keyword_dict.get(obj.id, '')
        concurrency_str = self.concurrency_dict.get(obj.id, '')  # 并发控制
        connect_rate_str = self.connect_rate_dict.get(obj.id, '')  # 链接速率
        remote_control_str = self.remote_access_dict.get(obj.id, '')  # 远程阻断控制
        db_access_str = self.db_access_dict.get(obj.id, '')  # 数据库访问控制
        flow_control_str = self.flow_control_dict.get(obj.id, '')
        if need_time_limit:  # 页面上操作后，普通下发的情况
            time_limit_str = self.time_limit_dict.get(obj.id, '')
        else:
            time_limit_str = ''  # 时间段控制脚本生成配置的情况，不用检测时间配置，脚本会负责检测K
        cert_str = self.cert_path_dict.get(obj.id, '')
        if cert_str:
            cert_conf_1 = f'mysql-ssl {node_ip}:{server_port}'
            cert_conf_2 = f'mysql-tcp {node_ip}:{server_port}'
            cert_str += ' verify required'
        else:
            cert_conf_1 = ''
            cert_conf_2 = ''
        if '.' in obj.outer_ip:
            outer_ip = '0.0.0.0'
        else:
            outer_ip = '[::]'
        i_m_data = f"frontend {front_name}\n" \
                   f"    bind {outer_ip}:{obj.outer_port} {cert_conf_1} {cert_str}\n" \
                   f"{time_limit_str}" \
                   f"{remote_control_str}" \
                   f"{db_access_str}" \
                   f"{concurrency_str}" \
                   f"{template_str}" \
                   f"{keyword_str}" \
                   f"{connect_rate_str}" \
                   f"    tcp-request connection reject if " \
                   "!{ src -f /opt/engine/conf/white/" \
                   f"{backend_name}.lst" \
                   " }\n" \
                   f"{flow_control_str}\n" \
                   f"    default_backend {backend_name}\n" \
                   f"backend {backend_name}\n" \
                   f"    balance     roundrobin\n" \
                   f"    server   {server_name} {node_ip}:{server_port} namespace secif {cert_conf_2}\n"

        o_a_data = f"frontend {front_name}\n" \
                   f"    bind {node_ip}:{server_port} namespace secif\n" \
                   f"    use_backend {backend_name}\n" \
                   f"backend {backend_name}\n" \
                   f"    balance     roundrobin\n" \
                   f"    server   {backend_name} {obj.inner_ip}:{obj.inner_port}\n"
        return i_m_data, o_a_data

    @staticmethod
    def add_cnf(target_string, file_name):
        file_path = os.path.join('/opt/engine/conf/haproxy/', file_name)
        # 读取文件内容
        with open(file_path, 'r', encoding='utf-8') as file:
            content = file.read()

            # 检查目标字符串是否存在于文件中
        if target_string not in content:
            # 如果不存在，则添加目标字符串并写回文件
            with open(file_path, 'a', encoding='utf-8') as file:
                file.write(target_string + '\n')
        else:
            print(f"The string '{target_string}' already exists in the file.")

    @staticmethod
    def remove_cnf(file_path, target_string):
        # 读取文件内容
        with open(file_path, 'r', encoding='utf-8') as file:
            lines = file.read()

        # 检查字符串是否存在于文件中，并构建不含该字符串的新内容
        if target_string in lines:
            new_lines = lines.replace(target_string, '')
            with open(file_path, 'w', encoding='utf-8') as file:
                file.writelines(new_lines)

    def get_port(self, channel_id_list):
        """
            获取通道可用的端口
        """
        redis_dict = {}
        port_list = []
        self.id_port_dict.clear()
        # 先从redis中获取已分配的端口
        redis_data = sync_conn.get('channel_id_port_dict')

        if redis_data:
            redis_dict = json.loads(redis_data)
            port_list = list(redis_dict.values())
        for _id in channel_id_list:
            if str(_id) in redis_dict and check_port_is_open(redis_dict[str(_id)]):
                self.id_port_dict[_id] = redis_dict[str(_id)]
            else:
                port = self.get_usable_ports(1, port_list)[0]
                self.id_port_dict[_id] = port
                port_list.append(port)
        sync_conn.set('channel_id_port_dict', json.dumps(self.id_port_dict))
        return self.id_port_dict

    def get_rule_data(self, need_time_limit=True):
        queryset = models.TransferChannel.objects.filter(enable=True)
        i_data = self.static_content + 'I"\n' + self.static_info
        o_data = self.static_content + 'O"\n' + self.static_info
        m_data = self.static_content + 'M"\n' + self.static_info
        a_data = self.static_content + 'A"\n' + self.static_info
        # usable_ports = self.get_usable_ports(num=queryset.count())
        # 获取开启通道的id列表，从而获取一次性拿出安全策略
        channel_id_list = list(queryset.values_list('id', flat=True))
        channel_id_list.append(self.health_channel_id)
        channel_id_list.sort()
        self.get_flow_control_conf(channel_id_list)
        self.get_concurrency_conf(channel_id_list)
        self.get_template_conf(channel_id_list)
        self.get_connect_rate_conf(channel_id_list)
        self.get_keyword_conf(channel_id_list)
        self.get_remote_access_conf(channel_id_list)
        self.get_db_access_conf(channel_id_list)
        self.get_time_limit_conf(channel_id_list)
        self.get_port(channel_id_list)
        self.get_cert_conf(channel_id_list)

        for obj in queryset:
            i_m_data, o_a_data = self.get_cfg_content(obj, need_time_limit)
            # 如果是请求方，发送I和O
            if obj.direction == 1:
                o_data += o_a_data
                i_data += i_m_data
            else:
                m_data += i_m_data
                a_data += o_a_data
        i_cfg, o_cfg, m_cfg, a_cfg = self.get_engine_health_cfg()
        o_data += o_cfg
        i_data += i_cfg
        m_data += m_cfg
        a_data += a_cfg
        # 获取白名单配置
        white = TCPConfigHandler().write_transfer_channel_white_file(channel_id_list)
        rsp_data = {'I': i_data, 'O': o_data, 'M': m_data, 'A': a_data, "white": white}
        return json.dumps(rsp_data)

    @staticmethod
    def write_transfer_channel_white_file(channel_id_list):
        wls = list(ApiWhitelist.objects.values("start_ip", "end_ip", "channel"))
        white_dict = {}
        for channel_id in channel_id_list:
            _cidr_list = []
            for wl_dict in wls:
                if channel_id not in wl_dict.get('channel'):
                    continue
                cidr_list = IPUtils().ip_to_cidr(wl_dict['start_ip'], wl_dict['end_ip'])
                _cidr_list.extend(cidr_list)
            white_dict[channel_id] = '\n'.join(_cidr_list)
        return json.dumps(white_dict)

    @staticmethod
    def write_transfer_channel_white_file11(channel_id_list):

        # 先加载so文件
        path = SO_FILE_PATH + 'libip_to_mask.so'
        lib = ctypes.CDLL(path)
        # 配置好函数以及对应参数和返回值
        get_addr_mask = lib.get_addr_mask
        get_addr_mask.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        get_addr_mask.restype = ctypes.c_char_p
        # transfer_id_list = models.TransferChannel.objects.filter(enable=True).values("id")
        wls = list(models.Whitelist.objects.values("start_ip", "end_ip", "ownership", "interface_id"))
        white_dict = {}
        for transfer_id in channel_id_list:
            # transfer_id = transfer_id_info.get("id", "")
            if not transfer_id:
                white_dict[transfer_id] = []
                continue
            search_criteria = {"id": transfer_id, "type": 2}
            # 以下条件查询已转化为 Python 条件匹配，减少访问数据库
            # white_dict[transfer_id] = models.Whitelist.objects.filter(
            #     Q(ownership=1) & Q(interface_id__contains=search_criteria)).values_list("start_ip", "end_ip")
            white_dict[transfer_id] = []
            new_result = []
            for wl_dict in wls:
                if wl_dict['ownership'] == 1:
                    for interface_dict in wl_dict['interface_id']:
                        if (interface_dict.get('id') == search_criteria['id']
                                and interface_dict.get('type') == search_criteria['type']):
                            new_result.append([wl_dict['start_ip'], wl_dict['end_ip']])
                    white_dict[transfer_id] = new_result
        # # 先判断路径是否存在
        # print(TRANSFER_CHANNEL_WHITE_PATH)
        # if os.path.exists(TRANSFER_CHANNEL_WHITE_PATH):
        #     # 存在则先清空目录
        #     shutil.rmtree(TRANSFER_CHANNEL_WHITE_PATH)
        # # 新建目录用来存放规则文件
        # os.mkdir(TRANSFER_CHANNEL_WHITE_PATH)
        # em1, em2 = EngineMessage(), EngineMessage()
        ipv4_send_dict = {}
        # em1.send(own='O', send_node='IM', msg_type='rule')
        for k, v in white_dict.items():
            if not v:
                ipv4_send_dict[k] = "\n"
                continue
            # if any(item['type'] == 2 for item in interface_list):
            #     for interface in interface_list:
            #         if interface['type'] == 1:
            #             continue
            # file_name = str(interface["id"])+".lst"
            # with open(TRANSFER_CHANNEL_WHITE_PATH+f"{file_name}", "w+") as f:
            for ip_list in v:
                start_ip = ip_list[0]
                end_ip = ip_list[1]

                # ipv4处理
                if IPUtils().get_ip_version(start_ip) == 4:
                    result = get_addr_mask(start_ip.encode(), end_ip.encode())
                    ip_str = result.decode()
                    mask_list = ip_str.split(",")
                    # 将掩码组成dict格式
                    for mask in mask_list:
                        ipv4_send_dict[k] = ipv4_send_dict.get(k, "") + mask + "\n"
                elif IPUtils().get_ip_version(start_ip) == 6:
                    pass
        return json.dumps(ipv4_send_dict)
        # em2.file_name = "white"
        # em2.data = json.dumps(send_dict)
        # em2.send(own='O', send_node='IM', msg_type=em2.file_name)

    def get_template_data(self):
        template_list = APPDataControl.objects.filter(service__enable=True).values_list("service_id", "direction",
                                                                                        "content", 'offset',
                                                                                        'mode_type')
        res_data = []
        for template_obj in template_list:
            service_id = template_obj[0]
            direction_list = template_obj[1]
            content = template_obj[2]
            offset = template_obj[3]
            mode_type = template_obj[4]

            byte_length = 4
            if mode_type == 4:
                # 引擎需要字节数
                byte_content = content.encode('utf-8')
                byte_length = len(byte_content)
            # 存在多个方向 这里循环最多2次
            for direction in direction_list:
                template_dict = {
                    "name": str(service_id) + "-" + str(direction),
                    "type": mode_type,
                    "value": content,
                    "len": byte_length,
                    "offset": str(offset),
                    "direction": direction
                }
                res_data.append(template_dict)
        return json.dumps(res_data, ensure_ascii=False, indent=4)

    @staticmethod
    def get_payload_keyword_data():
        """
            关键字下发
            20250918 与瑞武确认后修改逻辑。旧版本仅下发开启通道的关键字，新版本下发所有关键字，因为当前支持热加载。
        """
        # 字典初始化
        value_dict = defaultdict(list)

        # 从数据库中获取数据
        keyword_list = KeywordFilterData.objects.values_list("id", "service_id", "content", 'status', "risk_level",
                                                             "alarm_class", "alarm_subclass", "rule_name")

        # 遍历数据并构建字典
        for id, service_id, content, status, risk_level, alarm_class, alarm_subclass, rule_name in keyword_list:
            value = {
                "id": id,
                "keywords": content,
                "flag": status,
                "rule_name": rule_name,
                "risk_level": risk_level,
                "alarm_class": alarm_class,
                "alarm_subclass": alarm_subclass
            }
            value_dict[service_id].append(value)  # defaultdict 自动处理键不存在的情况

        # 构建最终结果
        res_data = [
            {
                "name": f"transfer_id_{key}",
                "value": value,
                "referenced": [str(key)]
            }
            for key, value in value_dict.items()
        ]
        return json.dumps(res_data, ensure_ascii=False, indent=4)

    @staticmethod
    def get_cert_data():
        """
        获取证书内容及名称，并返回json格式数据
        """
        id_list = list(Certification.objects.filter(service__direction=1).values_list("id", flat=True))
        cert_list = Certification.objects.values_list("id", "cert_text", "ca_text")
        cert_data = []
        i_data = []
        m_data = []
        for cert_obj in cert_list:
            _crt_info = {
                'file_name': f"server_{cert_obj[0]}.pem",
                'content': cert_obj[1],
            }
            _ca_info = {
                'file_name': f"ca_{cert_obj[0]}.crt",
                'content': cert_obj[2],
            }
            if cert_obj[0] in id_list:
                i_data.extend([_crt_info, _ca_info])
            else:
                m_data.extend([_crt_info, _ca_info])
        res_data = {
            'data': {'I': i_data, 'M': m_data},
            'web_msg_type': 'mtlsCert'
        }
        return json.dumps(res_data, ensure_ascii=False, indent=4)

