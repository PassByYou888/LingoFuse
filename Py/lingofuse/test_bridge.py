#!/usr/bin/env python3
import requests
import json

url = "http://127.0.0.1:8081/exp"
payload = {"args": ["1+2*3"]}
print("Sending request:", json.dumps(payload, ensure_ascii=False).encode("utf-8"))
try:
    resp = requests.post(url, json=payload, timeout=5)
    print("Status code:", resp.status_code)
    print("Response content:", resp.text)
    if resp.status_code == 200:
        if resp.text:
            print("✅ Result:", resp.text)
        else:
            print("⚠️ Empty response (API may not exist or returned empty)")
    else:
        print("❌ HTTP error:", resp.status_code)
except Exception as e:
    print("Request exception:", e)