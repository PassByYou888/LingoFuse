# 第 0 章 引入与约束

## 0.1 最小引入

```cpp
#include "json.hpp"
using json = nlohmann::json;
```

- 只用单文件版 `single_include/nlohmann/json.hpp`。
- 不要 `#include <nlohmann/json.hpp>`（除非你保留了完整目录结构）。
- `json_fwd.hpp` 只用于前向声明，不能建对象、不能解析。

## 0.2 编译标准

- 最低 **C++11**。
- C++14/17/20/23 会启用额外功能：
  - C++14：透明比较器 `std::less<>`，`std::make_unique`
  - C++17：`std::string_view`、`std::optional`、`std::filesystem`、结构化绑定、`if constexpr`
  - C++20：三路比较 `<=>`
  - C++23：`std::string::contains` 等无关

## 0.3 类型别名

```cpp
using json         = nlohmann::json;          // ObjectType=std::map
using ordered_json = nlohmann::ordered_json;  // ObjectType=ordered_map，保持插入顺序
```

## 0.4 默认模板参数

| 参数 | 默认值 |
|---|---|
| ObjectType | `std::map` |
| ArrayType | `std::vector` |
| StringType | `std::string` |
| BooleanType | `bool` |
| NumberIntegerType | `std::int64_t` |
| NumberUnsignedType | `std::uint64_t` |
| NumberFloatType | `double` |
| AllocatorType | `std::allocator` |
| JSONSerializer | `adl_serializer` |
| BinaryType | `std::vector<std::uint8_t>` |
| CustomBaseClass | `void` |

## 0.5 内联命名空间与 ABI

`json.hpp` 展开后进入：

```cpp
namespace nlohmann {
inline namespace json_abi_v3_12_0 { /* ... */ }
}
```

含义：
- 你写 `nlohmann::json` 时通过内联命名空间自动解析。
- 不同版本的 `json.hpp` 的符号位于不同内联命名空间，**混用不同版本会在链接期 ODR 冲突**。
- **单文件版与多文件版不能混用**。

## 0.6 线程安全

- **只读**：多个线程并发读同一 `json` 对象通常安全。
- **写**：任何修改都必须由外部加锁。库本身无锁、无原子。
- **迭代器**在容器被修改后可能失效（`push_back` 到数组、修改 `ordered_json` 对象都会）。

---

# 第 1 章 类型系统

## 1.1 `value_t` 枚举

```cpp
enum class value_t : std::uint8_t {
    null,
    object,
    array,
    string,
    boolean,
    number_integer,   // 有符号
    number_unsigned,  // 无符号
    number_float,     // 浮点
    binary,           // 二进制
    discarded         // 解析/回调丢弃
};
```

## 1.2 内部存储

`basic_json` 用 union 存储值：

- 堆分配（指针）：object、array、string、binary
- 内联：boolean、number_integer、number_unsigned、number_float

**结果**：
- 空 `json` 对象大小约等于 `value_t` + 指针（实现相关，一般 16 字节）。
- 数字、布尔无需堆分配，快速。
- 字符串即使为空也会堆分配（除非是 `null`）。

## 1.3 类型查询

```cpp
j.is_null();
j.is_boolean();
j.is_number();            // 三种数字之一
j.is_number_integer();    // number_integer 或 number_unsigned
j.is_number_unsigned();
j.is_number_float();
j.is_string();
j.is_array();
j.is_object();
j.is_binary();
j.is_primitive();         // null | string | boolean | number | binary
j.is_structured();        // array | object
j.is_discarded();

j.type();                 // value_t
j.type_name();            // "null" / "boolean" / "number" / "string" / "array" / "object" / "binary" / "discarded"
```

注意：

- `is_number_integer()` **对无符号也返回 true**。要区分有符号/无符号用 `is_number_unsigned()`。
- `is_number()` 是 `is_number_integer() || is_number_float()` 的并集。

---

# 第 2 章 构造

## 2.1 从标量

```cpp
json j;                    // null
json j = nullptr;          // null
json j(true);              // boolean
json j(42);                // number_integer (int → int64_t)
json j(42u);               // number_unsigned (unsigned → uint64_t)
json j(42L);               // number_integer
json j(42UL);              // number_unsigned
json j(3.14);              // number_float (double)
json j(3.14f);             // number_float (float → double)
json j("hello");           // string（const char*）
json j(std::string("x"));  // string
```

规则：
- 有符号整型 → `number_integer`
- 无符号整型 → `number_unsigned`
- 浮点 → `number_float`（统一存为 `double`）
- `const char*` → `string`（按 `strlen` 截断，遇 `\0` 结束）
- `char` → `number_integer`（**不是** string！这是个坑）

## 2.2 从初始化列表

```cpp
json j = {};                          // 空对象 {}（注意不是数组）
json j = json::array();               // 空数组 []
json j = {1, 2, 3};                   // 数组 [1,2,3]
json j = {{"a", 1}, {"b", 2}};        // 对象 {"a":1,"b":2}
json j = {1, "x", true};              // 数组 [1,"x",true]
json j = {{"a", {1, 2}}};             // 对象 {"a":[1,2]}
json j = json::array({1, 2, 3});      // 强制数组
json j = json::object({{"a", 1}});    // 强制对象
```

**判定规则**：如果一个初始化列表的**每个元素**都是 2 元数组且第一元素是 string，则当作对象；否则当作数组。

歧义处理：

```cpp
json j = {{"a", 1}};                  // object {"a":1}
json j = json::array({{"a", 1}});     // array [["a",1]]
json j = {{1, 2}};                    // array [[1,2]]（因第一元素不是 string）
```

## 2.3 从容器

```cpp
std::vector<int> v = {1,2,3};
json j = v;                                    // array

std::map<std::string, int> m = {{"a",1}};
json j = m;                                    // object

std::unordered_map<std::string, int> um = {{"a",1}};
json j = um;                                   // object

std::set<int> s = {1,2,3};
json j = s;                                    // array

std::array<int, 3> a = {1,2,3};
json j = a;                                    // array

std::pair<std::string, int> p = {"a", 1};
json j = p;                                    // array ["a",1]

std::tuple<int, std::string> t = {1, "x"};
json j = t;                                    // array [1,"x"]

int carr[3] = {1,2,3};
json j = carr;                                 // array
```

注意：
- `std::pair` 序列化为 2 元素数组，**不是对象**。
- `std::tuple` 序列化为数组。
- `std::map` 的 key 必须是 string 类（否则序列化为数组的 `[key, value]` 对）。

## 2.4 显式类型构造

```cpp
json j = json::value_t::array;
json j = json::value_t::object;
json j(value_t::null);
```

## 2.5 从其它 `basic_json` 类型

```cpp
nlohmann::json         a = ...;
nlohmann::ordered_json b = a;    // 隐式转换（走序列化）
nlohmann::json         c = b;    // 同样
```

代价：**深拷贝**。

## 2.6 从迭代器

```cpp
std::vector<int> v = {1,2,3};
json j(v.begin(), v.end());      // array

json::iterator it1 = j.begin();
json::iterator it2 = j.end();
json k(it1, it2);                // 复制区间
```

## 2.7 C++17 `std::optional`

```cpp
std::optional<int> o = 42;
json j = o;                      // 42

std::optional<int> empty;
json j = empty;                  // null

std::optional<int> x = j.get<std::optional<int>>();
```

## 2.8 C++17 `std::filesystem::path`

```cpp
std::filesystem::path p = "/tmp/a.json";
json j = p;                       // "/tmp/a.json"（字符串）
auto q = j.get<std::filesystem::path>();
```

需要 `JSON_HAS_FILESYSTEM` 或 `JSON_HAS_EXPERIMENTAL_FILESYSTEM` 为 1。

---

# 第 3 章 解析

## 3.1 静态 `parse`

```cpp
json j = json::parse(R"({"a":1})");
json j = json::parse(text);               // std::string
json j = json::parse(sv);                 // std::string_view (C++17)
json j = json::parse(s.c_str());          // const char*
json j = json::parse(begin_it, end_it);   // 迭代器区间
json j = json::parse(std::ifstream("a.json"));
json j = json::parse(stdin);              // istream&
json j = json::parse(FILE*);
```

## 3.2 `parse` 的参数

```cpp
json j = json::parse(
    input,
    callback,          // parser_callback_t，可为 nullptr
    allow_exceptions,  // 默认 true
    ignore_comments    // 默认 false
);
```

- `allow_exceptions=false` 时遇到错误返回 `discarded`，不抛。
- `ignore_comments=true` 时支持 `//` 与 `/* */` 注释（**非标准 JSON**）。

## 3.3 解析回调

```cpp
using parse_event_t = json::parse_event_t;
// object_start, object_end, array_start, array_end, key, value

json j = json::parse(text, [](int depth, json::parse_event_t event, json& parsed) {
    if (event == json::parse_event_t::key) {
        // parsed 是 key 的字符串
        if (parsed == "secret") return false;  // 丢弃该键及其值
    }
    if (event == json::parse_event_t::value) {
        // parsed 是即将写入的值
    }
    return true;  // 保留
});
```

注意事项：
- 回调返回 `false` 表示丢弃。
- `depth` 是嵌套深度（顶层容器为 0）。
- 返回 `false` 时被丢弃的值会从父容器中删除。

## 3.4 合法性校验（不抛异常）

```cpp
bool ok = json::accept(text);
bool ok = json::accept(text, /*ignore_comments=*/true);
```

## 3.5 解析异常

| ID | 含义 |
|---|---|
| `parse_error.101` | 语法错误（token 意外） |
| `parse_error.102` | 转义序列错误 |
| `parse_error.103` | UTF-8 编码错误 |
| `parse_error.104` | JSON Patch 顶层非数组 |
| `parse_error.105` | JSON Patch 结构错误 |
| `parse_error.106` | 数组下标以 0 开头 |
| `parse_error.107` | JSON Pointer 不是以 `/` 开头 |
| `parse_error.108` | JSON Pointer `~` 转义错误 |
| `parse_error.109` | 数组下标非数字 |
| `parse_error.110` | 输入提前结束 |
| `parse_error.111` | 流错误 |
| `parse_error.112` | 二进制格式字节错误 |
| `parse_error.113` | 二进制格式长度错误 |
| `parse_error.114` | BSON 不支持的类型 |
| `parse_error.115` | UBJSON 高精度数字错误 |

`parse_error` 字段：

```cpp
catch (const json::parse_error& e) {
    e.what();   // 文本描述（含行/列）
    e.id;       // 101 等
    e.byte;     // 错误位置字节索引（1-based）
}
```

## 3.6 解析 `istream` 不消费整个流

```cpp
std::ifstream in("ndjson");
std::string line;
while (std::getline(in, line)) {
    json j = json::parse(line);  // 每行独立解析
}
```

每次 `parse` 会停在当前文档结束处。这允许 NDJSON 逐行解析。

---

# 第 4 章 序列化

## 4.1 `dump`

```cpp
j.dump();                   // 紧凑
j.dump(2);                  // 缩进 2
j.dump(4, ' ');             // 缩进 4，用空格
j.dump(-1, ' ', true);      // 紧凑 + ensure_ascii
j.dump(-1, ' ', false, json::error_handler_t::replace);  // UTF-8 非法时替换
```

签名：

```cpp
string_t dump(
    int indent = -1,
    char indent_char = ' ',
    bool ensure_ascii = false,
    error_handler_t error_handler = error_handler_t::strict
) const;
```

- `indent < 0`：紧凑。
- `indent >= 0`：缩进。
- `ensure_ascii=true`：非 ASCII 转 `\uXXXX`。
- `error_handler`：`strict` / `replace` / `ignore`。

## 4.2 `to_string` / `operator<<`

```cpp
std::string s = nlohmann::to_string(j);   // 等价 j.dump()
std::cout << j;                           // 紧凑
std::cout << std::setw(4) << j;           // 缩进 4（借 width）
std::ofstream("out.json") << j.dump(2);
```

## 4.3 二进制序列化

```cpp
auto v = json::to_cbor(j);
auto v = json::to_msgpack(j);
auto v = json::to_ubjson(j);
auto v = json::to_ubjson(j, /*use_size=*/true, /*use_type=*/true);
auto v = json::to_bjdata(j);
auto v = json::to_bson(j);

json j = json::from_cbor(v);
json j = json::from_msgpack(v);
json j = json::from_ubjson(v);
json j = json::from_bjdata(v);
json j = json::from_bson(v);
```

`from_*` 参数：
- `strict`（默认 true）：末尾必须 EOF。
- `allow_exceptions`（默认 true）。

## 4.4 二进制类型

```cpp
using binary_t = nlohmann::byte_container_with_subtype<std::vector<std::uint8_t>>;

json j = json::binary({0x01, 0x02, 0x03});
json j = json::binary({0x01, 0x02}, 0x10);  // 带 subtype

j.is_binary();
j.get_binary();
j.get_binary().has_subtype();
j.get_binary().subtype();
j.get_binary().set_subtype(0x20);
j.get_binary().clear_subtype();
```

dump 二进制：

```json
{"bytes":[1,2,3],"subtype":null}
{"bytes":[1,2],"subtype":16}
```

## 4.5 流输出

```cpp
std::ostringstream oss;
oss << j;
```

## 4.6 不支持直接写入的格式

CBOR/MessagePack 等直接返回 `std::vector<std::uint8_t>`，写入文件：

```cpp
auto v = json::to_cbor(j);
std::ofstream("out.cbor", std::ios::binary).write(
    reinterpret_cast<const char*>(v.data()), v.size());
```

---

# 第 5 章 元素访问

## 5.1 `operator[]`

**非 const 版本**：

- object：键不存在时**插入 `null` 并返回引用**。
- array：索引越界时**扩展数组至该索引 + 1，中间填 `null`**。
- null：自动变成 object（string 参数）或 array（数字参数）。
- 其它类型：抛 `type_error.305`。

```cpp
json j;
j["a"] = 1;              // null → object
j["b"]["c"] = 2;         // 嵌套自动创建
j["arr"][2] = 5;         // arr 是 array（若之前非数组会抛）
```

**const 版本**：

- object：`find` 找不到时行为是**未定义**（内部断言，Release 下可能返回空引用/崩溃）。
- array：越界未定义。

**结论**：只读场景**绝不要**用 `operator[]`，用 `at()` / `value()` / `contains()` / `find()`。

## 5.2 `at`

```cpp
j.at("key");     // 键不存在抛 out_of_range.403
j.at(0);         // 越界抛 out_of_range.401
```

签名变体：

```cpp
reference at(size_type idx);
const_reference at(size_type idx) const;
reference at(const typename object_t::key_type& key);
template<class KeyType> reference at(KeyType&& key);  // 透明比较，能传 string_view
```

## 5.3 `value`

```cpp
int v = j.value("port", 8080);
std::string s = j.value("name", std::string("unknown"));
```

签名：

```cpp
template<class ValueType>
ValueType value(const key_type& key, const ValueType& default_value) const;
```

语义：
- 键不存在：返回 `default_value`。
- 键存在，类型能转换：返回转换后的值。
- 键存在，类型不匹配：抛 `type_error.302`（**不返回默认值**）。

## 5.4 `get<T>()`

```cpp
int n = j.get<int>();
std::string s = j.get<std::string>();
std::vector<int> v = j.get<std::vector<int>>();
std::map<std::string, int> m = j.get<std::map<std::string, int>>();

auto ptr = j.get<json::object_t*>();             // 返回内部指针
auto ref = j.get_ref<const std::string&>();      // 引用
```

内部优先级：
1. 默认构造 + `from_json`
2. 非默认构造 `from_json`
3. 不同 `basic_json` 之间转换
4. 同类型直接返回
5. 指针类型返回内部指针

类型不匹配：`type_error.302`。

**C++17** 支持 `std::optional`：

```cpp
auto o = j.get<std::optional<int>>();  // 若为 null 返回 nullopt
```

## 5.5 `get_to`

```cpp
int n;         j.at("age").get_to(n);
std::string s; j.at("name").get_to(s);
```

类型不匹配抛 `type_error.302`。

## 5.6 `get_ref`

```cpp
const std::string& s = j.at("name").get_ref<const std::string&>();
std::string& s = j["name"].get_ref<std::string&>();
const auto& obj = j.get_ref<const json::object_t&>();
const auto& arr = j.get_ref<const json::array_t&>();
```

引用返回，零拷贝。类型不匹配抛 `type_error.303`。

## 5.7 `get_ptr`

```cpp
const std::string* sp = j.get_ptr<const std::string*>();
std::string* sp = j.get_ptr<std::string*>();
const json::object_t* op = j.get_ptr<const json::object_t*>();
```

类型不匹配返回 `nullptr`（不抛）。

## 5.8 `front` / `back`

```cpp
j.front();   // *begin()
j.back();    // *(--end())
```

对空数组/对象**未定义**。对 primitive 相当于 `*j`。

## 5.9 迭代器访问

```cpp
auto it = j.begin();
*it;         // json&
it.key();    // 仅对象有效，返回 const string&
it.value();  // 等价 *it
```

---

# 第 6 章 迭代器（重要）

## 6.1 类别

`basic_json::iterator` 是 **BidirectionalIterator**，**不是 RandomAccessIterator**。

后果：
- **不能用** `it + n`、`it - n`、`it[n]`、`it1 < it2`（对象迭代器不支持 `<`）。
- 数组和 primitive 迭代器**支持** `<`、`++`、`--`、`std::next`、`std::advance`。
- **对象迭代器不支持** `<`，不支持加减，只能 `++/--`。

正确移动：

```cpp
auto it = j.begin();
std::advance(it, 3);          // 数组和 primitive 可用
auto it2 = std::next(j.begin(), 2);  // 同上
```

对象迭代器只能逐步 `++/--`。

## 6.2 各类型的迭代行为

| 类型 | begin() | end() | 解引用 |
|---|---|---|---|
| null | == end() | == begin() | 抛 invalid_iterator |
| object | 首键 | 尾后 | json&（value） |
| array | 首元素 | 尾后 | json& |
| string | 自身 | 尾后 | json&（自身） |
| boolean | 自身 | 尾后 | json&（自身） |
| number_* | 自身 | 尾后 | json&（自身） |
| binary | 自身 | 尾后 | json&（自身） |
| discarded | 自身 | 尾后 | json&（自身） |

## 6.3 结构化绑定

```cpp
for (auto& [key, value] : j.items()) {
    // key 是 const string&（对象）或 string（数组下标字符串）
    // value 是 json&
}

// 或使用 value() / key()
for (auto& el : j.items()) {
    std::cout << el.key() << " : " << el.value() << "\n";
}
```

`items()` 对数组的 `key()` 返回**字符串形式的下标**（`"0"`, `"1"`, ...）。

## 6.4 `rbegin` / `rend`

```cpp
for (auto it = j.rbegin(); it != j.rend(); ++it) { }
```

## 6.5 `iterator_wrapper`（已废弃）

```cpp
for (auto& el : json::iterator_wrapper(j)) { }  // 用 items() 替代
```

## 6.6 迭代器失效

- 数组 `push_back` / `insert` / `erase`：可能使迭代器失效（类似 `std::vector`）。
- 对象（`std::map`）：插入/删除其它键不影响已存在的迭代器。
- `ordered_json`：内部是 `std::vector`，插入/删除会失效。
- **任何修改都不安全于正在遍历的迭代**（除非使用 `erase` 的返回值）。

## 6.7 `erase` 与迭代

```cpp
for (auto it = j.begin(); it != j.end(); ) {
    if (should_delete(*it)) {
        it = j.erase(it);    // erase 返回下一个迭代器
    } else {
        ++it;
    }
}
```

---

# 第 7 章 查找、包含、计数

```cpp
j.contains("key");              // bool
j.contains(json_pointer);       // 支持 JSON Pointer
j.count("key");                 // 0 或 1
j.find("key");                  // iterator，找不到 == end()
```

C++14 及以后支持透明查找：

```cpp
j.find(std::string_view("key"));
j.contains(std::string_view("key"));
```

要求 `object_comparator_t` 是透明的（默认 `std::less<>`，C++14+）。

---

# 第 8 章 修改

## 8.1 数组

```cpp
j.push_back(1);
j.push_back(json(2));
j.push_back(std::move(some_json));
j.emplace_back(3);
j += 4;
j.insert(j.begin(), 0);
j.insert(j.begin(), 3, 0);
j.insert(j.begin(), {1,2,3});
j.insert(j.begin(), other.begin(), other.end());
j.erase(0);
j.erase(j.begin());
j.erase(j.begin(), j.end());
j.clear();
j.pop_back();     // 无此方法，用 erase(j.size()-1) 或 erase(j.end()-1)
```

## 8.2 对象

```cpp
j.emplace("a", 1);                    // 返回 pair<iterator, bool>
j.insert({"a", 1});                    // 若已存在不覆盖
j.insert({{"a",1}, {"b",2}});
j["a"] = 1;                            // 覆盖
j.push_back({"a", 1});                 // 仅 object 或 null
j.erase("a");                          // 返回删除数量
j.update(other);                       // 浅合并：other 的键覆盖
j.update(other, /*merge_objects=*/true); // 深合并：递归合并对象
```

## 8.3 数组/对象通用

```cpp
j.clear();
j.swap(other);
swap(j, other);                        // ADL
j = json::array();                     // 重置为空数组
j = json::object();
```

## 8.4 `update` 语义

```cpp
json a = {{"x", 1}, {"y", {{"z", 2}}}};
json b = {{"y", {{"w", 3}}}};

a.update(b);                     // {"x":1, "y":{"w":3}}    ← 整个 y 被替换
a.update(b, true);               // {"x":1, "y":{"z":2,"w":3}}  ← 递归合并
```

## 8.5 `erase` 返回类型

```cpp
size_type erase(const key_type&);        // object，删除数量
void erase(size_type);                    // array
iterator erase(iterator);                 // 返回下一个
iterator erase(iterator, iterator);       // 返回下一个
```

---

# 第 9 章 容量与大小

```cpp
j.empty();        // null/empty array/empty object 返回 true
j.size();         // null: 0, primitive: 1, container: 元素数
j.max_size();     // 容器最大容量
```

对 primitive 返回值 1，对 null 返回 0。

---

# 第 10 章 比较

## 10.1 同类型比较

```cpp
json a = 1, b = 2;
a == b;   // false
a <  b;   // true
a <= b;   // true
```

## 10.2 跨类型比较

类型序（`value_t`）：

```
null < boolean < number < object < array < string < binary
```

数字内部三种（integer/unsigned/float）互相比数值，其它情况按类型序。

```cpp
json(1) == json(1.0);          // true
json(1) == json(1u);            // true
json(0) == json(false);         // false（boolean ≠ number）
json(nullptr) == json(0);       // false
json("1") == json(1);           // false（string ≠ number）
```

## 10.3 与标量比较

```cpp
j == 42;
j == 3.14;
j == "hello";
j == true;
j == nullptr;
42 == j;      // 反向
```

## 10.4 NaN 与 discarded

- `json(std::nan("")) == json(std::nan(""))` → **false**。
- 任何涉及 NaN 的 `<`、`>` 都返回 false。
- 与 `discarded` 的比较默认是 ordered 的（`discarded` 小于所有），除非定义 `JSON_USE_LEGACY_DISCARDED_VALUE_COMPARISON=1`。

## 10.5 C++20 三路比较

```cpp
std::partial_ordering ord = j1 <=> j2;
ord == std::partial_ordering::less / equal / greater / unordered;
```

---

# 第 11 章 数字细节

## 11.1 存储类型

- `number_integer_t` = `std::int64_t`
- `number_unsigned_t` = `std::uint64_t`
- `number_float_t` = `double`

## 11.2 解析数字的规则

- 无非负号 → 尝试 `uint64_t`
- 有 `-` → 尝试 `int64_t`
- 有小数点或指数 → `double`
- 超出 `uint64_t`/`int64_t` 范围 → `double`
- 超出 `double` 范围（如 `1e400`）→ `parse_error.406` 或 `out_of_range.406`

## 11.3 dump 数字

- 整数：直接用内建整型转字符串。
- 浮点：Grisu2，保证 round-trip。
- `NaN` / `Inf` → `null`。

```cpp
json j = std::nan("");
j.dump();   // "null"
```

## 11.4 类型不匹配

```cpp
json j = 42;
j.get<std::string>();    // 抛 type_error.302
j.get<double>();         // OK，返回 42.0
j.get<uint64_t>();       // OK
```

数字的隐式转换走 `get_arithmetic_value`，做范围检查。

## 11.5 精度陷阱

```cpp
json j = 9007199254740993LL;   // 2^53 + 1
j.get<int64_t>() == 9007199254740993LL;   // true（整数正确）

json j = 0.1;
j.dump();   // "0.1"

json j = 1e-7;
j.dump();   // "1e-07"
```

**不要用 `double` 存放需要精确的整数**（超过 2^53 会丢）。

## 11.6 大整数建议

超过 `uint64_t` 范围的数只能用 `double`，会丢精度。需要更高精度时：
- 存为字符串。
- 使用外部大数库。

---

# 第 12 章 字符串与 UTF-8

## 12.1 内部编码

`std::string` 直接存放 **UTF-8 字节**。库不做宽字符互转。

## 12.2 输入编码

- 字符串字面量、`std::string`：按字节传入，不校验。
- `std::wstring` / `std::u16string` / `std::u32string`：通过 `input_adapter` 走 `wide_string_input_adapter`，自动转为 UTF-8。仅支持解析输入，不支持输出宽字符。

```cpp
std::wstring ws = L"hello 世界";
json j = json::parse(ws);   // 自动转 UTF-8
```

## 12.3 解析时的 UTF-8 校验

- 字符串内嵌 `\uXXXX` 与代理对会解码为 UTF-8。
- 非法 UTF-8 字节抛 `parse_error.102/103/113`。
- 字符串中的控制字符必须转义。

## 12.4 dump 时的 UTF-8 处理

`error_handler_t`：

| 值 | 行为 |
|---|---|
| `strict` | 抛 `type_error.316`（默认） |
| `replace` | 非法字节替换为 U+FFFD（`\uFFFD` 或 `\xEF\xBF\xBD`） |
| `ignore` | 忽略非法字节 |

`ensure_ascii=true` 时，非 ASCII 一律转 `\uXXXX`（含代理对）。

## 12.5 `get<std::string>()` 返回

返回**原始 UTF-8 字节**。`size()` 是字节数，不是字符数。

```cpp
json j = "中文";
std::string s = j.get<std::string>();
s.size();   // 6（UTF-8 每汉字 3 字节）
```

## 12.6 `\0` 嵌入

`std::string` 可含 `\0`，dump 时会转义为 `\u0000`。`const char*` 构造会被 `strlen` 截断。

```cpp
json j = std::string("a\0b", 3);   // 3 字节字符串
j.dump();                          // "\"a\\u0000b\""
```

## 12.7 BOM

解析时若存在 `EF BB BF`（UTF-8 BOM）会被跳过。UTF-16/UTF-32 BOM 由 `wide_string_input_adapter` 处理。

---

# 第 13 章 拷贝与移动（重点）

## 13.1 拷贝构造

```cpp
json a = {{"x", 1}};
json b = a;              // 深拷贝
b["x"] = 2;              // a 不变
```

深拷贝整个树。大对象代价高。

## 13.2 移动构造

```cpp
json a = {{"x", 1}};
json b = std::move(a);   // a 变成 null
```

移动是 O(1)（指针转移）。

## 13.3 拷贝赋值 / 移动赋值

```cpp
a = b;                   // 深拷贝
a = std::move(b);        // b 变成 null
```

## 13.4 容器操作中的拷贝

```cpp
j.push_back(big_json);            // 拷贝
j.push_back(std::move(big_json)); // 移动
j.emplace_back(args...);          // 原地构造（若参数能直接构造 json）
j.insert(j.begin(), big);         // 拷贝
```

**循环中添加元素时优先移动**：

```cpp
for (auto& item : items) {
    result.push_back(std::move(item));  // 若 item 可弃
}
```

## 13.5 迭代器返回引用

`*it` 返回 `json&`，赋值给 `json` 会拷贝：

```cpp
json copy = *it;                // 拷贝
json& ref = *it;                // 引用
const json& cref = *it;         // const 引用
```

---

# 第 14 章 自定义类型序列化

## 14.1 ADL `to_json` / `from_json`

```cpp
namespace my {
struct Person { std::string name; int age; };

void to_json(nlohmann::json& j, const Person& p) {
    j = nlohmann::json{{"name", p.name}, {"age", p.age}};
}

void from_json(const nlohmann::json& j, Person& p) {
    j.at("name").get_to(p.name);
    j.at("age").get_to(p.age);
}
}

my::Person p{"Alice", 30};
nlohmann::json j = p;
my::Person p2 = j.get<my::Person>();
```

规则：
- 函数必须在类型所在的命名空间（通过 ADL 找到）或 `nlohmann` 命名空间。
- 声明顺序要在使用之前。
- 模板类型需特化 `adl_serializer` 或提供 ADL 函数。

## 14.2 `adl_serializer` 特化

```cpp
template <typename T>
struct adl_serializer<std::optional<T>> {
    static void to_json(json& j, const std::optional<T>& opt) {
        if (opt) j = *opt;
        else    j = nullptr;
    }
    static void from_json(const json& j, std::optional<T>& opt) {
        if (j.is_null()) opt = std::nullopt;
        else             opt = j.get<T>();
    }
};
```

## 14.3 宏方式

```cpp
struct Person {
    std::string name;
    int age;
    NLOHMANN_DEFINE_TYPE_INTRUSIVE(Person, name, age)
};

struct Point { int x, y; };
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(Point, x, y)
```

| 宏 | 用途 |
|---|---|
| `NLOHMANN_DEFINE_TYPE_INTRUSIVE(Type, ...)` | 类内，双向 |
| `NLOHMANN_DEFINE_TYPE_INTRUSIVE_WITH_DEFAULT(Type, ...)` | 缺字段用默认值 |
| `NLOHMANN_DEFINE_TYPE_INTRUSIVE_ONLY_SERIALIZE(Type, ...)` | 只序列化 |
| `NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(Type, ...)` | 类外，双向 |
| `NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE_WITH_DEFAULT(Type, ...)` | 缺字段用默认值 |
| `NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE_ONLY_SERIALIZE(Type, ...)` | 只序列化 |
| `NLOHMANN_DEFINE_DERIVED_TYPE_INTRUSIVE(Type, BaseType, ...)` | 含基类 |
| `NLOHMANN_DEFINE_DERIVED_TYPE_NON_INTRUSIVE(Type, BaseType, ...)` | 含基类 |

宏展开后是用 `j[#field]` 与 `j.at(#field).get_to(field)`。

- `_WITH_DEFAULT` 用 `j.value(field, default_obj.field)`，缺字段不抛。
- `_ONLY_SERIALIZE` 只提供 `to_json`。

## 14.4 嵌套自定义类型

```cpp
struct Address { std::string city; };
struct User { std::string name; Address addr; };

NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(Address, city)
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(User, name, addr)
```

## 14.5 枚举

```cpp
enum class Color { Red, Green, Blue };

NLOHMANN_JSON_SERIALIZE_ENUM(Color, {
    {Color::Red,   "red"},
    {Color::Green, "green"},
    {Color::Blue,  "blue"},
})
```

- 未匹配值时用列表第一个（`Red`）。
- 不加宏时枚举按整数序列化。
- 禁用：`JSON_DISABLE_ENUM_SERIALIZATION=1`。

## 14.6 C++17 `std::optional`

内建支持：

```cpp
std::optional<int> o = 42;
json j = o;                          // 42
o = j.get<std::optional<int>>();     // 42

std::optional<int> e = std::nullopt;
json j = e;                          // null
e = j.get<std::optional<int>>();     // nullopt
```

## 14.7 `std::variant`（不内建）

`std::variant` 不内建。需自行提供 `to_json` / `from_json`，通过 `std::visit`。

## 14.8 `std::filesystem::path`

内建支持（C++17）。见 2.8。

## 14.9 智能指针（不内建）

`std::shared_ptr` / `std::unique_ptr` **不内建**。需自行提供：

```cpp
template <typename T>
void to_json(json& j, const std::shared_ptr<T>& p) {
    if (p) to_json(j, *p);
    else   j = nullptr;
}
```

---

# 第 15 章 异常

## 15.1 异常层次

```
nlohmann::json::exception
├── parse_error
├── invalid_iterator
├── type_error
├── out_of_range
└── other_error
```

**注意**：都不继承 `std::runtime_error`。只捕获 `json::exception` 即可。

## 15.2 常用 ID 表

| 异常 | ID | 含义 |
|---|---|---|
| parse_error | 101 | 语法错误 |
| parse_error | 102 | 转义序列错误 |
| parse_error | 103 | UTF-8 错误 |
| parse_error | 104/105 | JSON Patch 结构错误 |
| parse_error | 106 | 数组下标前导 0 |
| parse_error | 107/108 | JSON Pointer 错误 |
| parse_error | 109 | 数组下标非数字 |
| parse_error | 110 | 输入提前结束 |
| parse_error | 111 | 流错误 |
| parse_error | 112/113 | 二进制格式错误 |
| invalid_iterator | 201 | 迭代器不兼容 |
| invalid_iterator | 202/203/204 | 迭代器不匹配/越界 |
| invalid_iterator | 205 | primitive 迭代器越界 |
| invalid_iterator | 206 | 迭代器构造错误 |
| invalid_iterator | 207 | key() 用于非 object |
| invalid_iterator | 208 | operator[] 用于 object |
| invalid_iterator | 209 | 对象偏移 |
| invalid_iterator | 210/211 | 迭代器不匹配 |
| invalid_iterator | 212/213 | 迭代器比较 |
| invalid_iterator | 214 | 取值错误 |
| type_error | 301 | 类型推导失败 |
| type_error | 302 | get/at 类型不匹配 |
| type_error | 303 | get_ref 类型不匹配 |
| type_error | 304/305 | at/operator[] 类型错误 |
| type_error | 306 | value() 类型错误 |
| type_error | 307 | erase() 类型错误 |
| type_error | 308/309 | push_back/insert 类型错误 |
| type_error | 310 | swap 类型错误 |
| type_error | 311 | emplace 类型错误 |
| type_error | 312 | update 类型错误 |
| type_error | 313 | 无效 unflatten |
| type_error | 314/315 | unflatten 结构错误 |
| type_error | 316 | 非法 UTF-8（dump 时） |
| type_error | 317 | BSON 顶层非 object |
| out_of_range | 401 | 数组越界 |
| out_of_range | 402 | JSON Pointer 数组下标 `-` |
| out_of_range | 403 | 对象键不存在 |
| out_of_range | 404 | JSON Pointer 无法解析 |
| out_of_range | 405 | JSON Pointer 无父 |
| out_of_range | 406 | 数字溢出 |
| out_of_range | 408 | 容器过大 |
| out_of_range | 409 | BSON key 含 `\0` |
| out_of_range | 410 | 数组下标超 size_type |
| other_error | 501 | 其它 |
| other_error | 502 | 内部 |

## 15.3 捕获示例

```cpp
try {
    json j = json::parse(text);
} catch (const json::parse_error& e) {
    std::cerr << "parse error at byte " << e.byte << ": " << e.what() << "\n";
} catch (const json::type_error& e) {
    std::cerr << "type error: " << e.what() << "\n";
} catch (const json::out_of_range& e) {
    std::cerr << "range error: " << e.what() << "\n";
} catch (const json::exception& e) {
    std::cerr << "json error " << e.id << ": " << e.what() << "\n";
}
```

## 15.4 禁用异常

定义 `JSON_NOEXCEPTION`：所有 `JSON_THROW` 变成 `std::abort()`。**不能再 catch**。

自定义抛出：

```cpp
#define JSON_THROW_USER(exception) throw MyException(exception)
```

---

# 第 16 章 JSON Pointer (RFC 6901)

## 16.1 字面量

```cpp
using namespace nlohmann::literals;
json& v = j["/a/b/0"_json_pointer];
```

## 16.2 构造

```cpp
json::json_pointer p("/a/b/0");
json::json_pointer p = "/a/b"_json_pointer;
```

## 16.3 转义

- `~0` 表示 `~`
- `~1` 表示 `/`

```cpp
json j = {{"a/b", 1}};
j["/a~1b"_json_pointer];   // 访问 "a/b"
```

## 16.4 访问

```cpp
j.at(ptr);              // 越界抛 out_of_range
j[ptr];                 // 非 const 不存在时创建
j.contains(ptr);        // bool
j.value(ptr, default);  // 带默认值
```

## 16.5 数组下标

- `"0"`：合法。
- `"01"`：非法（前导 0，抛 `parse_error.106`）。
- `"-"`：仅用于 patch 追加；`at` 抛 `out_of_range.402`。

## 16.6 常用成员

```cpp
json_pointer p = "/a/b"_json_pointer;
p.empty();                    // 是否根
p.back();                     // 最后一个 token
p.pop_back();                 // 移除最后
p.push_back("c");             // 追加
p.parent_pointer();           // 父指针
p.to_string();                // 转字符串
p /= "d";                     // 追加
p /= 2;                       // 追加数组下标
json_pointer q = p / "e";     // 新指针
```

## 16.7 flatten / unflatten

```cpp
json flat = j.flatten();       // 所有叶子变为 "/a/b": value
json orig = flat.unflatten();  // 还原
```

flatten 规则：
- 空对象/空数组被展平为 `null`。
- 对象键会转义（`~0` / `~1`）。

---

# 第 17 章 JSON Patch / Diff / Merge Patch

## 17.1 JSON Patch (RFC 6902)

```cpp
json patch = json::parse(R"([
    {"op":"add",    "path":"/a",    "value":1},
    {"op":"remove", "path":"/b"},
    {"op":"replace","path":"/c",    "value":2},
    {"op":"move",   "from":"/a",    "path":"/b"},
    {"op":"copy",   "from":"/a",    "path":"/c"},
    {"op":"test",   "path":"/a",    "value":1}
])");

j.patch_inplace(patch);        // 原地
json j2 = j.patch(patch);      // 副本
```

## 17.2 Diff (RFC 6902)

```cpp
json patch = json::diff(before, after);
json after2 = before.patch(patch);
```

- 数组 diff 的删除操作**逆序**生成，避免索引错位。
- 添加用 `/-` 追加。

## 17.3 Merge Patch (RFC 7396)

```cpp
json target = {{"a", 1}, {"b", {{"c", 2}}}};
json mp = {{"b", {{"c", 3}}}, {"d", 4}, {"a", nullptr}};
target.merge_patch(mp);
// 结果：{"b":{"c":3}, "d":4}   a 被 null 删除
```

语义：
- 顶层 patch 非 object：直接替换。
- patch 是 object：递归合并。
- 值为 `null`：删除对应键。

---

# 第 18 章 二进制格式

## 18.1 支持列表

| 格式 | 编码 | 解码 | 顶层限制 |
|---|---|---|---|
| CBOR | `to_cbor` | `from_cbor` | 无 |
| MessagePack | `to_msgpack` | `from_msgpack` | 无 |
| UBJSON | `to_ubjson` | `from_ubjson` | 无 |
| BJData | `to_bjdata` | `from_bjdata` | 无 |
| BSON | `to_bson` | `from_bson` | 顶层必须 object |

## 18.2 CBOR 标签

```cpp
json j = json::from_cbor(v, true, true, json::cbor_tag_handler_t::error);
// error: 遇 tag 抛异常
// ignore: 忽略 tag
// store: 存为 binary subtype
```

## 18.3 UBJSON 参数

```cpp
json::to_ubjson(j);                       // 无优化
json::to_ubjson(j, true);                 // use_size
json::to_ubjson(j, true, true);           // use_size + use_type
json::to_ubjson(j, true, true, true);     // 额外 add_prefix（内部使用）
```

## 18.4 BJData 版本

```cpp
json::to_bjdata(j, false, false, json::bjdata_version_t::draft2);
json::to_bjdata(j, false, false, json::bjdata_version_t::draft3);
```

## 18.5 BSON

- 顶层必须 object，否则 `type_error.317`。
- key 不能含 `\0`，否则 `out_of_range.409`。

## 18.6 二进制类型

见 4.4。

---

# 第 19 章 SAX 流式解析

## 19.1 用途

- 大文件，不想全量建树。
- 边解析边处理。

## 19.2 接口

```cpp
template<typename BasicJsonType>
struct json_sax {
    virtual bool null() = 0;
    virtual bool boolean(bool) = 0;
    virtual bool number_integer(number_integer_t) = 0;
    virtual bool number_unsigned(number_unsigned_t) = 0;
    virtual bool number_float(number_float_t, const string_t&) = 0;
    virtual bool string(string_t&) = 0;
    virtual bool binary(binary_t&) = 0;
    virtual bool start_object(std::size_t elements) = 0;
    virtual bool key(string_t&) = 0;
    virtual bool end_object() = 0;
    virtual bool start_array(std::size_t elements) = 0;
    virtual bool end_array() = 0;
    virtual bool parse_error(std::size_t position,
                             const std::string& last_token,
                             const detail::exception& ex) = 0;
};
```

## 19.3 最小实现

```cpp
struct MySax : nlohmann::json_sax<json> {
    bool null() override { return true; }
    bool boolean(bool) override { return true; }
    bool number_integer(json::number_integer_t) override { return true; }
    bool number_unsigned(json::number_unsigned_t) override { return true; }
    bool number_float(json::number_float_t, const json::string_t&) override { return true; }
    bool string(json::string_t&) override { return true; }
    bool binary(json::binary_t&) override { return true; }
    bool start_object(std::size_t) override { return true; }
    bool key(json::string_t&) override { return true; }
    bool end_object() override { return true; }
    bool start_array(std::size_t) override { return true; }
    bool end_array() override { return true; }
    bool parse_error(std::size_t, const std::string&, const json::exception&) override { return false; }
};

MySax sax;
bool ok = json::sax_parse(text, &sax);
```

## 19.4 二进制 SAX

```cpp
json::sax_parse(v, &sax, json::input_format_t::cbor);
json::sax_parse(v, &sax, json::input_format_t::msgpack);
```

## 19.5 `unknown_size`

容器大小未知时 `start_object/start_array` 参数为 `detail::unknown_size()`（`size_t` 最大值）。

---

# 第 20 章 配置宏

| 宏 | 默认 | 作用 |
|---|---|---|
| `JSON_NOEXCEPTION` | 未定义 | 禁用异常，错误时 `abort` |
| `JSON_THROW_USER(ex)` | 未定义 | 自定义抛出 |
| `JSON_TRY_USER` | 未定义 | 自定义 try |
| `JSON_CATCH_USER` | 未定义 | 自定义 catch |
| `JSON_ASSERT(x)` | `assert(x)` | 自定义断言 |
| `JSON_DIAGNOSTICS` | 0 | 异常带 JSON 路径 |
| `JSON_DIAGNOSTIC_POSITIONS` | 0 | 异常带字节位置 |
| `JSON_USE_IMPLICIT_CONVERSIONS` | 1 | 0 时禁用隐式转换 |
| `JSON_DISABLE_ENUM_SERIALIZATION` | 0 | 1 时禁用枚举自动序列化 |
| `JSON_NO_IO` | 未定义 | 禁用 iostream 支持 |
| `JSON_USE_GLOBAL_UDLS` | 1 | 0 时不自动 using 字面量 |
| `JSON_SKIP_UNSUPPORTED_COMPILER_CHECK` | 未定义 | 跳过编译器版本检查 |
| `JSON_SKIP_LIBRARY_VERSION_CHECK` | 未定义 | 跳过版本检查 |
| `JSON_USE_LEGACY_DISCARDED_VALUE_COMPARISON` | 0 | 1 时启用旧版 discarded 比较 |
| `JSON_HAS_CPP_11/14/17/20/23` | 自动 | 手动覆盖语言标准检测 |

## 20.1 `JSON_USE_IMPLICIT_CONVERSIONS=0`

所有 `T x = j;` 编译失败，必须：

```cpp
T x = j.get<T>();
```

比较运算符 `j == 42` **不受影响**。

## 20.2 `JSON_DIAGNOSTICS=1`

异常信息会带路径：

```
[json.exception.type_error.302] (/server/port) type must be string, but is number
```

代价：
- 每个 `json` 多一个 `m_parent` 指针。
- 拷贝/移动要维护父指针。
- 内存开销增大。

## 20.3 `JSON_DIAGNOSTIC_POSITIONS=1`

异常信息还带字节位置：

```
[json.exception.type_error.302] (bytes 10-20) (/a/b) ...
```

代价同上，另加记录 start/end 位置。

---

# 第 21 章 元信息

```cpp
json m = json::meta();
// {
//   "copyright": "(C) 2013-2025 Niels Lohmann",
//   "name": "JSON for Modern C++",
//   "url": "https://github.com/nlohmann/json",
//   "version": {"string":"3.12.0","major":3,"minor":12,"patch":0},
//   "platform": "win32" | "linux" | "apple" | "unix" | "unknown",
//   "compiler": {"family":"msvc"|"gcc"|"clang"|..., "version":"...", "c++":"201703"}
// }
```

---

# 第 22 章 杂项

## 22.1 `std::hash`

```cpp
std::unordered_map<std::string, json> m;   // OK
std::unordered_set<json> s;                // OK
std::hash<json> h;
auto v = h(j);
```

`hash()` 区分 null、0、0u、false 等不同类型。

## 22.2 `to_string`

```cpp
std::string s = nlohmann::to_string(j);    // 等价 j.dump()
```

## 22.3 字面量

```cpp
using namespace nlohmann::literals;        // 默认已自动 using
json j = R"({"a":1})"_json;
auto p = "/a/b"_json_pointer;
```

禁用：`JSON_USE_GLOBAL_UDLS=0`。

## 22.4 `operator value_t`

```cpp
json::value_t t = j;    // 隐式转换到 value_t
switch (j) {
    case json::value_t::object: ...
}
```

## 22.5 派生类

```cpp
class MyJson : public nlohmann::json {
public:
    using nlohmann::json::json;
};
```

一般不建议继承，会踩很多坑。使用 `CustomBaseClass` 模板参数：

```cpp
struct MyBase { /* ... */ };
using my_json = nlohmann::basic_json<
    std::map, std::vector, std::string, bool, std::int64_t, std::uint64_t, double,
    std::allocator, nlohmann::adl_serializer, std::vector<std::uint8_t>, MyBase>;
```

## 22.6 不同 `basic_json` 之间的赋值

```cpp
nlohmann::json         a = ...;
nlohmann::ordered_json b = a;
nlohmann::json         c = b;
```

走序列化，**深拷贝**。

## 22.7 自定义分配器

```cpp
using my_json = nlohmann::basic_json<
    std::map, std::vector, std::string, bool, std::int64_t, std::uint64_t, double,
    MyAllocator>;
```

## 22.8 自定义字符串类型

```cpp
using my_json = nlohmann::basic_json<
    std::map, std::vector, MyString, bool, std::int64_t, std::uint64_t, double>;
```

`MyString` 需满足 string 接口。

---

# 第 23 章 常见陷阱清单

1. **`const json&` 上 `operator[]` 访问不存在的键 → 未定义行为**。
2. **非 const `operator[]` 会插入键**。
3. **`value(key, default)` 只在键不存在时返回默认值**。
4. **`get<T>()` 类型不匹配抛异常**，不做宽松转换。
5. **整数超出 int64/uint64 退化为 double，丢精度**。
6. **`NaN`/`Inf` dump 为 `null`**。
7. **对象默认按键排序**（`std::map`）；要插入顺序用 `ordered_json`。
8. **迭代器是 Bidirectional 而非 RandomAccess**，`it + n` 不合法（除数组/primitive）。
9. **对象迭代器不支持 `<`**。
10. **修改容器使迭代器失效**。
11. **`json` 非线程安全**，只读并发安全。
12. **`parse` 默认 strict**，末尾不能有多余内容。
13. **`parse(istream)` 不消费整个流**。
14. **`dump` 默认不转义非 ASCII**。
15. **不能混用不同版本的 json.hpp**。
16. **不能混用单文件版与多文件版**。
17. **`operator[]` 数组下标越界会扩展数组并填 null**。
18. **`char` 类型构造 `json` 会变成 number**，不是 string。
19. **`json(std::string("a\0b", 3))` 可含 `\0`**，`const char*` 会截断。
20. **`pair` 序列化为数组**，不是对象。
21. **`optional<T>` 为 nullopt 时序列化为 `null`**。
22. **`get<std::vector<T>>()` 对 string 无效**（string 不是 array）。
23. **`json::diff` 数组删除是逆序**。
24. **`merge_patch` 中 `null` 表示删除**。
25. **`discarded` 与 `null` 不同**。
26. **`JSON_NOEXCEPTION` 下 `JSON_THROW` 变 `abort`**。
27. **`JSON_USE_IMPLICIT_CONVERSIONS=0` 后必须显式 `get<T>()`**。
28. **`json::iterator` 默认构造是未初始化**，大多数操作未定义。
29. **`begin() == end()` 对 null 成立**，null 视为空容器。
30. **primitive 类型可以迭代一次**，解引用返回自身。
31. **`erase` 返回下一个迭代器**，循环里用返回值继续。
32. **`std::string_view` 只在 C++17 起支持**。
33. **`std::filesystem::path` 只在 C++17 起支持**。
34. **`std::optional` 只在 C++17 起支持**。
35. **对象迭代器 `it.key()` 返回 `const string&`**，不能修改。
36. **`at` 与 `operator[]` 行为差异大**，只读优先 `at`。
37. **`value()` 的类型不匹配会抛 `type_error.302`**。
38. **`flatten()` 后空对象/空数组变成 `null`**。
39. **`unflatten()` 要求所有值都是 primitive**。
40. **BSON 顶层必须是 object**。

---

# 第 24 章 惯用片段速查

```cpp
// 安全读取
int port = j.value("port", 8080);
std::string host = j.value("host", std::string("localhost"));

// 可选字段
if (j.contains("timeout")) {
    int t = j["timeout"].get<int>();
}

// 遍历对象
for (auto& [k, v] : j.items()) {
    if (v.is_string() && k != "password") {
        std::cout << k << "=" << v.get<std::string>() << "\n";
    }
}

// 数组转 vector
auto nums = j["nums"].get<std::vector<int>>();

// 对象转 map
auto m = j.get<std::map<std::string, int>>();

// 读文件
std::ifstream in("config.json");
json cfg = json::parse(in);

// 写文件
std::ofstream("config.json") << cfg.dump(2);

// 安全读嵌套
int getPort(const json& cfg) {
    try {
        return cfg.at("server").at("port").get<int>();
    } catch (const json::exception&) {
        return 8080;
    }
}

// 遍历删除
for (auto it = j.begin(); it != j.end(); ) {
    if (should_remove(*it)) it = j.erase(it);
    else ++it;
}

// 深拷贝
json copy = original;                  // 深拷贝
json moved = std::move(original);      // 移动，原变 null

// 数组转对象 key
for (std::size_t i = 0; i < j.size(); ++i) {
    std::cout << i << " = " << j[i].dump() << "\n";
}

// 用 JSON Pointer
json& v = j["/a/b/0"_json_pointer];

// 异常路径（开启 JSON_DIAGNOSTICS=1 后）
try { j.at("x").get<std::string>(); }
catch (const json::exception& e) { std::cerr << e.what() << "\n"; }

// 自定义类型
void to_json(json& j, const MyType& v) { j = json{{"x", v.x}}; }
void from_json(const json& j, MyType& v) { j.at("x").get_to(v.x); }

// 字符串保真
json j = std::string("a\0b", 3);       // 含 \0
j.dump();                              // "a\u0000b"

// UTF-8 非法替换
j.dump(-1, ' ', false, json::error_handler_t::replace);

// 输出 ASCII-only
j.dump(2, ' ', true);

// 解析 NDJSON
std::ifstream in("data.ndjson");
std::string line;
while (std::getline(in, line)) {
    json j = json::parse(line);
}

// SAX 流式
struct MySax : nlohmann::json_sax<json> { /* ... */ };
MySax sax;
json::sax_parse(text, &sax);
```

---

# 第 25 章 版本与兼容

- 3.12.0 是本文对应版本。
- 版本宏：

```cpp
NLOHMANN_JSON_VERSION_MAJOR   // 3
NLOHMANN_JSON_VERSION_MINOR   // 12
NLOHMANN_JSON_VERSION_PATCH   // 0
```

- 混用不同版本：链接期 ODR 冲突。不同版本的符号位于不同内联命名空间（`json_abi_v3_12_0`）。
- 单文件版与多文件版不能混用。

---

# 第 26 章 快速决策表

| 需求 | 用法 |
|---|---|
| 解析字符串 | `json::parse(s)` |
| 解析文件 | `json::parse(std::ifstream(...))` |
| 解析流 | `json::parse(istream)` |
| 检查合法 | `json::accept(s)` |
| 序列化紧凑 | `j.dump()` |
| 序列化缩进 | `j.dump(2)` |
| 序列化 ASCII | `j.dump(2, ' ', true)` |
| 二进制 CBOR | `json::to_cbor(j)` / `json::from_cbor(v)` |
| 只读对象键 | `j.at("k")` / `j.value("k", d)` / `j.contains("k")` |
| 写入对象键 | `j["k"] = v` |
| 数组追加 | `j.push_back(v)` / `j.emplace_back(args)` |
| 数组访问 | `j[0]`（非 const）/ `j.at(0)`（const 安全） |
| 遍历对象 | `for (auto& [k,v] : j.items())` |
| 迭代删除 | `it = j.erase(it)` |
| 深拷贝 | `json copy = j` |
| 移动 | `json m = std::move(j)` |
| 自定义类型 | ADL `to_json/from_json` 或宏 |
| 枚举映射 | `NLOHMANN_JSON_SERIALIZE_ENUM` |
| 保持插入顺序 | `ordered_json` |
| 流式解析 | `json::sax_parse(text, &sax)` |
| JSON Pointer | `j["/a/b"_json_pointer]` |
| JSON Patch | `j.patch(patch)` / `json::diff(a, b)` |
| Merge Patch | `j.merge_patch(mp)` |
| 异常诊断 | 定义 `JSON_DIAGNOSTICS=1` |
| 禁用异常 | 定义 `JSON_NOEXCEPTION` |
| 禁隐式转换 | 定义 `JSON_USE_IMPLICIT_CONVERSIONS=0` |
