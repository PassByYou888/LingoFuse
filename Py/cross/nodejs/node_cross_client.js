const http = require('http');

class CrossBridgeClient {
    constructor(baseUrl = 'http://127.0.0.1:8081') {
        this.baseUrl = baseUrl.replace(/\/+$/, '');
    }

    /**
     * 调用远程 API (显式指定 app 在路径中)
     * @param {string} app   应用名称
     * @param {string} api   API 名称
     * @param {any}    body  请求体（将被 JSON 序列化）
     * @param {number} timeout 超时（毫秒）
     * @returns {Promise<any>} 响应的 JSON 解析结果
     */
    call(app, api, body, timeout = 2000) {
        return new Promise((resolve, reject) => {
            const payload = JSON.stringify(body);
            const url = new URL(`${this.baseUrl}/${app}/${api}`);
            const options = {
                hostname: url.hostname,
                port: url.port || 80,
                path: url.pathname,
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Content-Length': Buffer.byteLength(payload)
                },
                timeout: timeout + 1000
            };
            const req = http.request(options, (res) => {
                let data = '';
                res.on('data', chunk => data += chunk);
                res.on('end', () => {
                    try {
                        const parsed = JSON.parse(data);
                        // 如果响应是 JSON，直接返回；否则返回原始字符串
                        resolve(parsed);
                    } catch (e) {
                        resolve(data); // 非 JSON 响应原样返回
                    }
                });
            });
            req.on('error', reject);
            req.on('timeout', () => {
                req.destroy();
                reject(new Error('Request timeout'));
            });
            req.write(payload);
            req.end();
        });
    }
}

// 使用示例
async function main() {
    const client = new CrossBridgeClient('http://127.0.0.1:8081');
    try {
        // 调用 add：发送 [10, 20]
        const sum = await client.call('cross_bridge', 'add', [10, 20]);
        console.log(`10 + 20 = ${sum.result}`); // 响应为 {"code":0,"result":30}

        // 调用 inv_seri：发送 {}
        const result = await client.call('cross_bridge', 'inv_seri', {});
        console.log(`inv_seri 结果: ${result.result}`);
    } catch (e) {
        console.error('错误:', e.message);
    }
}
main();