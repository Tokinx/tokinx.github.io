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
# pip install aliyun-python-sdk-core aliyun-python-sdk-ecs


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
REGION_ID = ''          # 区域ID
ECS_INSTANCE_ID = ''    # 您要控制的ECS实例ID

# 流量阈值 (GB)
TRAFFIC_THRESHOLD_GB = 195

# 定时开关机配置
ENABLE_SCHEDULE_CONTROL = True
SCHEDULE_START = "8:00"
SCHEDULE_STOP = "0:00"

# Bark 通知配置
BARK_ENDPOINT = ""
BARK_GROUP = "DevOps"

# ================== 3. 工具函数 ==================
def parse_time_to_minutes(time_str):
    """将 'H:M' 字符串转为分钟数，非法配置直接退出"""
    try:
        hour_str, minute_str = time_str.strip().split(":")
        hour = int(hour_str)
        minute = int(minute_str)
        if not (0 <= hour < 24 and 0 <= minute < 60):
            raise ValueError
        return hour * 60 + minute
    except (ValueError, AttributeError):
        logger.error(f"无效的时间配置: {time_str}，格式需为 HH:MM 且在 00:00-23:59 范围内")
        sys.exit(1)

def send_bark_notification(action, total_gb):
    """向 Bark 发送开关机通知"""
    if not BARK_ENDPOINT or not BARK_GROUP:
        # logger.warning("Bark 通知配置不完整，跳过通知发送。")
        return
    body = f"ECS 实例 {ECS_INSTANCE_ID} {action}完毕，剩余互联网流量: {total_gb:.2f}/{TRAFFIC_THRESHOLD_GB} GB"
    params = urllib.parse.urlencode({
        "group": BARK_GROUP,
        "title": REGION_ID,
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
try:
    client = AcsClient(ACCESS_KEY_ID, ACCESS_KEY_SECRET, REGION_ID)
    logger.info("AcsClient initialized successfully.")
except Exception as e:
    logger.error(f"Failed to initialize AcsClient: {e}")
    sys.exit(1)

# ================== 5. 查询当前总流量 ==================
def get_total_traffic_gb(client):
    request = CommonRequest()
    request.set_domain('cdt.aliyuncs.com')
    request.set_version('2021-08-13')
    request.set_action_name('ListCdtInternetTraffic')
    request.set_method('POST')

    try:
        response = client.do_action_with_exception(request)
        response_json = json.loads(response.decode('utf-8'))

        total_bytes = sum(d.get('Traffic', 0) for d in response_json.get('TrafficDetails', []))
        total_gb = total_bytes / (1024 ** 3)

        logger.info(f"当前总互联网流量: {total_gb:.2f} GB")
        return total_gb
    except Exception as e:
        logger.error(f"获取CDT流量失败: {e}")
        sys.exit(1)

# ================== 6. 查询ECS实例状态 ==================
def get_ecs_status(client, instance_id):
    try:
        request = DescribeInstancesRequest.DescribeInstancesRequest()
        request.set_InstanceIds([instance_id])
        response = client.do_action_with_exception(request)
        response_json = json.loads(response.decode('utf-8'))

        instances = response_json.get("Instances", {}).get("Instance", [])
        if not instances:
            logger.error("未找到该ECS实例信息。")
            return None

        status = instances[0].get("Status")
        logger.info(f"ECS实例 {instance_id} 当前状态: {status}")
        return status
    except Exception as e:
        logger.error(f"获取ECS实例状态失败: {e}")
        return None

# ================== 7. 启动ECS实例 ==================
def ecs_start(client, instance_id):
    status = get_ecs_status(client, instance_id)
    if status == "Running":
        logger.info(f"ECS实例 {instance_id} 已经是运行状态，无需启动。")
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
        logger.info(f"ECS实例 {instance_id} 已经是停止状态，无需再次停止。")
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
def is_within_schedule(now_dt):
    """根据配置判断当前时间是否在计划运行窗口"""
    if not ENABLE_SCHEDULE_CONTROL:
        return True

    start_minutes = parse_time_to_minutes(SCHEDULE_START)
    stop_minutes = parse_time_to_minutes(SCHEDULE_STOP)
    current_minutes = now_dt.hour * 60 + now_dt.minute

    if start_minutes == stop_minutes:
        return True

    if stop_minutes < start_minutes:
        return current_minutes >= start_minutes or current_minutes < stop_minutes

    return start_minutes <= current_minutes < stop_minutes

# ================== 10. 主流程 ==================
def main():
    total_gb = get_total_traffic_gb(client)

    if total_gb >= TRAFFIC_THRESHOLD_GB:
        logger.info(f"流量 {total_gb:.2f} GB ≥ 阈值 {TRAFFIC_THRESHOLD_GB} GB，立即关机")
        if ecs_stop(client, ECS_INSTANCE_ID):
            send_bark_notification("关机", total_gb)
        logger.info("脚本执行完毕。")
        return

    now_dt = datetime.now()
    if is_within_schedule(now_dt):
        logger.info(f"当前时间 {now_dt.strftime('%H:%M')} 保持运行")
        if ecs_start(client, ECS_INSTANCE_ID):
            send_bark_notification("开机", total_gb)
    else:
        logger.info(f"当前时间 {now_dt.strftime('%H:%M')} 保持关机")
        if ecs_stop(client, ECS_INSTANCE_ID):
            send_bark_notification("关机", total_gb)

    logger.info("脚本执行完毕。")

if __name__ == "__main__":
    main()
