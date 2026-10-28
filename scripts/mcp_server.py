#!/usr/bin/env python3
"""MCP stdio adapter for the local PhoneBridge app. Only JSON-RPC on stdout."""
import json
import sys
from phonebridge import request

SPECS = {
    "session_connect": ("通过蓝牙连接手机通话桥，建立并验证通话控制和音频端点；不拨号。", {}),
    "session_dial": ("通过蓝牙拨打 App 中限定的用户测试号码，不启动云端 AI；提交后须读取状态。", {}),
    "session_start_ai": ("在用户已在 App 配置密钥并允许云端音频与 API 费用后，拨打限定测试号码并启动实时 AI 通话；提交后须读取状态。", {}),
    "session_hangup": ("取消待拨号并结束本次整合会话拥有的电话，验证手机已空闲。", {}),
    "session_disconnect": ("先结束本次电话并停止音频，再释放本次蓝牙会话。", {}),
    "session_interrupt": ("打断本次 AI 回答并清空尚未播放的语音，保留通话。", {}),
    "status": ("读取实际免提连接、通话状态和音频状态；不会拨号。", {}),
    "devices": ("刷新已配对的蓝牙设备和音频设备。", {}),
    "connect": ("连接用户指定的已配对手机的 HFP 免提服务。", {"address": "string"}),
    "disconnect": ("断开当前手机免提服务。", {}),
    "dial": ("使用手机默认 SIM 拨打已获用户授权的号码；返回的是提交结果。", {"number": "string"}),
    "hangup": ("结束当前电话。", {}),
    "dtmf": ("向当前通话发送一个菜单按键。", {"key": "string"}),
    "audio_to_mac": ("请求将当前手机通话音频转到 Mac；需要读取状态验证。", {}),
    "takeover": ("立即停止电脑音频，并请求将当前蓝牙通话音频交回手机。", {}),
    "audio_start": ("在用户已授权音频输入后启用指定蓝牙设备；要求 HFP/SCO 已连接。", {"inputID": "integer", "outputID": "integer"}),
    "audio_stop": ("停止音频处理。", {}),
    "speak": ("把文本通过 Mac 本机语音合成送入当前电话。", {"text": "string"}),
    "stop_speech": ("立即停止和清空尚未播放的语音。", {}),
    "record_test": ("按用户要求保存最多十秒的通话输入测试片段，仅本机保存。", {}),
    "report": ("导出本机诊断报告。", {}),
}

def tools_list():
    return [{"name": "phonebridge_" + action, "description": description,
             "inputSchema": {"type": "object", "properties": {k: {"type": v} for k, v in fields.items()},
                             "required": list(fields), "additionalProperties": False},
             "annotations": {"readOnlyHint": action in ("status", "devices"),
                             "openWorldHint": action in ("dial", "hangup", "dtmf", "speak", "session_dial", "session_start_ai", "session_hangup", "session_disconnect")}}
            for action, (description, fields) in SPECS.items()]

def dispatch(message):
    method = message.get("method")
    if method == "initialize":
        return {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
                "serverInfo": {"name": "phonebridge", "version": "0.3.0"}}
    if method == "ping": return {}
    if method == "tools/list": return {"tools": tools_list()}
    if method == "tools/call":
        params = message.get("params", {})
        name = params.get("name", "")
        action = name.removeprefix("phonebridge_")
        if name != "phonebridge_" + action or action not in SPECS:
            raise ValueError("未知工具")
        arguments = params.get("arguments", {})
        fields = SPECS[action][1]
        if not isinstance(arguments, dict) or set(arguments) != set(fields):
            raise ValueError("工具参数不匹配")
        for key, kind in fields.items():
            if (kind == "string" and not isinstance(arguments[key], str)) or (kind == "integer" and type(arguments[key]) is not int):
                raise ValueError("工具参数类型不匹配")
        try:
            result = request({"action": action, **arguments})
            return {"content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False)}]}
        except Exception as exc:
            return {"isError": True, "content": [{"type": "text", "text": str(exc)}]}
    raise ValueError("未知方法")

def main():
    for line in sys.stdin:
        identifier = None
        try:
            message = json.loads(line)
            if "id" not in message: continue
            identifier = message["id"]
            response = {"jsonrpc": "2.0", "id": identifier, "result": dispatch(message)}
        except Exception as exc:
            response = {"jsonrpc": "2.0", "id": identifier, "error": {"code": -32602, "message": str(exc)}}
        print(json.dumps(response, ensure_ascii=False), flush=True)

if __name__ == "__main__": main()
