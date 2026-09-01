#!/usr/bin/env python3
import requests
import json

url = "http://127.0.0.1:8081/exp"
payload = {"args": ["1+2*3"]}
print("发送请求:", json.dumps(payload))
try:
    resp = requests.post(url, json=payload, timeout=5)
    print("状态码:", resp.status_code)
    print("响应内容:", resp.text)
    if resp.status_code == 200:
        if resp.text:
            print("✅ 结果:", resp.text)
        else:
            print("⚠️ 空响应（可能 API 不存在或返回空）")
    else:
        print("❌ HTTP 错误:", resp.status_code)
except Exception as e:
    print("请求异常:", e)