# -*- coding: utf-8 -*-
from aliyunsdkcore.client import AcsClient
from aliyunsdkcore.request import CommonRequest
from aliyunsdkecs.request.v20140526 import StartInstancesRequest, StopInstancesRequest, DescribeInstancesRequest
from datetime import datetime
import json
import sys
import logging
import urllib.parse
import urllib.request
# pip install aliyun-python-sdk-core aliyun-python-sdk-ecs && bash run.sh


# ================== 1. 配置日志 ==================
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    stream=sys.stdout
)
logger = logging.getLogger(__name__)

# ================== 2. 配置阿里云凭证和ECS实例信息 ==================
ACCESS_KEY_ID = ''      # 您的AccessKey ID
ACCESS_KEY_SECRET = ''   # 您的AccessKey Secret

# 多实例配置（可按需继续添加）
ECS_INSTANCES = [
    {
        "region_id": "",       # 区域ID
        "instance_id": "",     # ECS实例ID
        "traffic_threshold_gb": 195,        # 流量阈值(GB)
        "enable_schedule_control": True,    # 是否启用定时开关机
        "schedule_start": "8:00",           # 开机时间
        "schedule_stop": "0:00",            # 关机时间
    },
]

# Bark 通知配置
BARK_ENDPOINT = ""
BARK_GROUP = "DevOps"

# ================== 3. 工具函数 ==================
def parse_time_to_minutes(time_str, exit_on_error=True):
    """将 'H:M' 字符串转为分钟数"""
    try:
        hour_str, minute_str = time_str.strip().split(":")
        hour = int(hour_str)
        minute = int(minute_str)
        if not (0 <= hour < 24 and 0 <= minute < 60):
            raise ValueError
        return hour * 60 + minute
    except (ValueError, AttributeError):
        msg = f"无效的时间配置: {time_str}，格式需为 HH:MM 且在 00:00-23:59 范围内"
        if exit_on_error:
            logger.error(msg)
            sys.exit(1)
        raise ValueError(msg)

def parse_bool(value):
    """解析布尔配置，支持 bool/0/1/true/false/on/off/yes/no"""
    if isinstance(value, bool):
        return value
    if isinstance(value, int) and value in (0, 1):
        return bool(value)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "on", "yes", "y"}:
            return True
        if normalized in {"0", "false", "off", "no", "n"}:
            return False
    raise ValueError(f"无效布尔配置: {value}")

def send_bark_notification(action, context):
    """向 Bark 发送开关机通知"""
    if not BARK_ENDPOINT or not BARK_GROUP:
        # logger.warning("Bark 通知配置不完整，跳过通知发送。")
        return

    instance_id = context["instance_id"]
    region_id = context["region_id"]
    traffic_gb = context["traffic_gb"]
    threshold_gb = context["threshold_gb"]
    flow_type = context["flow_type"]
    body = (
        f"ECS实例 {instance_id}({region_id}) {action}完毕，"
        f"当前{flow_type}流量: {traffic_gb:.2f}/{threshold_gb} GB"
    )
    params = urllib.parse.urlencode({
        "group": BARK_GROUP,
        "title": region_id,
        "body": body
    })
    url = f"{BARK_ENDPOINT}?{params}"

    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            response.read()
        logger.info(f"Bark 通知已发送: {body}")
    except Exception as e:
        logger.error(f"Bark 通知发送失败: {e}")

# ================== 4. 初始化客户端 ==================
CLIENT_CACHE = {}

def get_client(region_id):
    if region_id in CLIENT_CACHE:
        return CLIENT_CACHE[region_id]

    try:
        client = AcsClient(ACCESS_KEY_ID, ACCESS_KEY_SECRET, region_id)
        CLIENT_CACHE[region_id] = client
        logger.info(f"AcsClient 初始化成功: {region_id}")
        return client
    except Exception as e:
        logger.error(f"AcsClient 初始化失败 ({region_id}): {e}")
        return None

# ================== 5. 查询当前流量 ==================
def is_domestic_region(region_id):
    # 境内流量规则: cn-* 且不包含 cn-hongkong/cn-taiwan
    if not region_id:
        return False
    region_id = region_id.lower()
    if not region_id.startswith("cn-"):
        return False
    return region_id not in {"cn-hongkong", "cn-taiwan"}

def get_traffic_summary_gb(client):
    request = CommonRequest()
    request.set_domain('cdt.aliyuncs.com')
    request.set_version('2021-08-13')
    request.set_action_name('ListCdtInternetTraffic')
    request.set_method('POST')

    try:
        response = client.do_action_with_exception(request)
        response_json = json.loads(response.decode('utf-8'))

        traffic_details = response_json.get('TrafficDetails', [])
        domestic_bytes = 0
        overseas_bytes = 0

        for detail in traffic_details:
            traffic_bytes = detail.get("Traffic", 0) or 0
            business_region_id = detail.get("BusinessRegionId")

            if is_domestic_region(business_region_id):
                domestic_bytes += traffic_bytes
            else:
                overseas_bytes += traffic_bytes

        domestic_gb = domestic_bytes / (1024 ** 3) # 境内流量
        overseas_gb = overseas_bytes / (1024 ** 3) # 境外流量
        logger.info(f"当前CDT流量统计: 境内 {domestic_gb:.2f} GB, 境外 {overseas_gb:.2f} GB")
        return domestic_gb, overseas_gb
    except Exception as e:
        logger.error(f"获取CDT流量失败: {e}")
        sys.exit(1)

def get_region_traffic_gb(region_id, domestic_gb, overseas_gb):
    if is_domestic_region(region_id):
        return domestic_gb, "境内"
    return overseas_gb, "境外"

# ================== 6. 查询ECS实例状态 ==================
def get_ecs_status(client, instance_id):
    try:
        request = DescribeInstancesRequest.DescribeInstancesRequest()
        request.set_InstanceIds([instance_id])
        response = client.do_action_with_exception(request)
        response_json = json.loads(response.decode('utf-8'))

        instances = response_json.get("Instances", {}).get("Instance", [])
        if not instances:
            logger.error(f"未找到ECS实例信息: {instance_id}")
            return None

        status = instances[0].get("Status")
        return status
    except Exception as e:
        logger.error(f"获取ECS实例状态失败: {e}")
        return None

# ================== 7. 启动ECS实例 ==================
def ecs_start(client, instance_id):
    status = get_ecs_status(client, instance_id)
    if status == "Running":
        logger.info(f"保持启动 {instance_id} - {status}")
        return False

    try:
        request = StartInstancesRequest.StartInstancesRequest()
        request.set_InstanceIds([instance_id])
        request.set_accept_format('json')

        response = client.do_action_with_exception(request)
        logger.info(f"ECS启动响应: {response.decode('utf-8')}")
        return True
    except Exception as e:
        logger.error(f"启动ECS实例失败: {e}")
        return False

# ================== 8. 停止ECS实例 ==================
def ecs_stop(client, instance_id):
    status = get_ecs_status(client, instance_id)
    if status == "Stopped":
        logger.info(f"保持停止 {instance_id} - {status}")
        return False

    try:
        request = StopInstancesRequest.StopInstancesRequest()
        request.set_InstanceIds([instance_id])
        request.set_ForceStop(False)
        request.set_accept_format('json')

        response = client.do_action_with_exception(request)
        logger.info(f"ECS停止响应: {response.decode('utf-8')}")
        return True
    except Exception as e:
        logger.error(f"停止ECS实例失败: {e}")
        return False

# ================== 9. 定时窗口判断 ==================
def is_within_schedule(now_dt, enable_schedule_control, schedule_start, schedule_stop):
    """根据配置判断当前时间是否在计划运行窗口"""
    if not enable_schedule_control:
        return True

    start_minutes = parse_time_to_minutes(schedule_start)
    stop_minutes = parse_time_to_minutes(schedule_stop)
    current_minutes = now_dt.hour * 60 + now_dt.minute

    if start_minutes == stop_minutes:
        return True

    if stop_minutes < start_minutes:
        return current_minutes >= start_minutes or current_minutes < stop_minutes

    return start_minutes <= current_minutes < stop_minutes

# ================== 10. 主流程 ==================
def main():
    valid_instances = []
    for item in ECS_INSTANCES:
        region_id = str(item.get("region_id", "")).strip()
        instance_id = str(item.get("instance_id", "")).strip()
        traffic_threshold_gb = item.get("traffic_threshold_gb")
        raw_enable_schedule_control = item.get("enable_schedule_control", True)
        schedule_start = str(item.get("schedule_start", "8:00")).strip()
        schedule_stop = str(item.get("schedule_stop", "0:00")).strip()

        if not region_id or not instance_id:
            logger.warning(f"跳过无效实例配置: {item}")
            continue

        try:
            traffic_threshold_gb = float(traffic_threshold_gb)
            if traffic_threshold_gb < 0:
                raise ValueError
        except (TypeError, ValueError):
            logger.warning(f"跳过无效流量阈值配置: {item}")
            continue

        try:
            enable_schedule_control = parse_bool(raw_enable_schedule_control)
        except ValueError:
            logger.warning(f"跳过无效定时开关配置: {item}")
            continue

        try:
            parse_time_to_minutes(schedule_start, exit_on_error=False)
            parse_time_to_minutes(schedule_stop, exit_on_error=False)
        except ValueError:
            logger.warning(f"跳过无效定时时间配置: {item}")
            continue

        valid_instances.append({
            "region_id": region_id,
            "instance_id": instance_id,
            "traffic_threshold_gb": traffic_threshold_gb,
            "enable_schedule_control": enable_schedule_control,
            "schedule_start": schedule_start,
            "schedule_stop": schedule_stop,
        })

    if not valid_instances:
        logger.error("没有可执行的实例配置，请检查 ECS_INSTANCES。")
        sys.exit(1)

    cdt_region_id = valid_instances[0]["region_id"]
    cdt_client = get_client(cdt_region_id)
    if not cdt_client:
        sys.exit(1)

    domestic_gb, overseas_gb = get_traffic_summary_gb(cdt_client)
    now_dt = datetime.now()

    for cfg in valid_instances:
        region_id = cfg["region_id"]
        instance_id = cfg["instance_id"]
        traffic_threshold_gb = cfg["traffic_threshold_gb"]
        enable_schedule_control = cfg["enable_schedule_control"]
        schedule_start = cfg["schedule_start"]
        schedule_stop = cfg["schedule_stop"]
        client = get_client(region_id)
        if not client:
            continue

        within_schedule = is_within_schedule(
            now_dt,
            enable_schedule_control,
            schedule_start,
            schedule_stop
        )
        total_gb, flow_type = get_region_traffic_gb(region_id, domestic_gb, overseas_gb)
        action_context = {
            "instance_id": instance_id,
            "region_id": region_id,
            "traffic_gb": total_gb,
            "threshold_gb": traffic_threshold_gb,
            "flow_type": flow_type,
        }

        if total_gb >= traffic_threshold_gb:
            logger.info(
                f"{instance_id}({region_id}) {flow_type}流量 {total_gb:.2f} GB ≥ 阈值 {traffic_threshold_gb} GB，立即关机"
            )
            if ecs_stop(client, instance_id):
                send_bark_notification("关机", action_context)
            continue

        if within_schedule:
            logger.info(f"{instance_id}({region_id}) 当前时间 {now_dt.strftime('%H:%M')} 保持运行")
            if ecs_start(client, instance_id):
                send_bark_notification("开机", action_context)
        else:
            logger.info(f"{instance_id}({region_id}) 当前时间 {now_dt.strftime('%H:%M')} 保持关机")
            if ecs_stop(client, instance_id):
                send_bark_notification("关机", action_context)

if __name__ == "__main__":
    main()
