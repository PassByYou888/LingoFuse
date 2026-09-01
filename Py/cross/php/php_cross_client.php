<?php
/**
 * PHP 客户端调用 Cross Bridge（兼容新 bridge.py）
 */
class CrossBridgeClient
{
    private string $baseUrl;

    public function __construct(string $baseUrl = 'http://127.0.0.1:8081')
    {
        $this->baseUrl = rtrim($baseUrl, '/');
    }

    /**
     * 调用远程 API
     * @param string $app     应用名称
     * @param string $api     API 名称
     * @param mixed  $body    请求体（将被 JSON 编码）
     * @param int    $timeout 超时（毫秒）
     * @return mixed
     * @throws Exception
     */
    public function call(string $app, string $api, $body, int $timeout = 2000)
    {
        $payload = json_encode($body);
        $url = $this->baseUrl . '/' . $app . '/' . $api;
        $ch = curl_init($url);
        curl_setopt($ch, CURLOPT_POST, true);
        curl_setopt($ch, CURLOPT_POSTFIELDS, $payload);
        curl_setopt($ch, CURLOPT_HTTPHEADER, ['Content-Type: application/json']);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_TIMEOUT, max(1, $timeout / 1000 + 1));
        $response = curl_exec($ch);
        $error = curl_error($ch);
        curl_close($ch);

        if ($response === false) {
            throw new Exception("cURL 错误: $error");
        }
        $data = json_decode($response, true);
        if (!is_array($data)) {
            throw new Exception("无效 JSON 响应: $response");
        }
        return $data;
    }
}

// 使用示例
try {
    $client = new CrossBridgeClient('http://127.0.0.1:8081');
    
    // 调用 add：发送 [10, 20]
    $sum = $client->call('cross_bridge', 'add', [10, 20]);
    echo "10 + 20 = " . ($sum['result'] ?? '未知') . "\n";

    // 调用 inv_seri：发送 {}
    $result = $client->call('cross_bridge', 'inv_seri', []);
    echo "inv_seri 结果: " . ($result['result'] ?? '') . "\n";

} catch (Exception $e) {
    echo "错误: " . $e->getMessage() . "\n";
}