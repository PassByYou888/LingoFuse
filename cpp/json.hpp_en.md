# Chapter 0 Introduction and constraints

> Chinese version: [json.hpp.md](json.hpp.md)

## 0.1 The minimal include

```cpp
#include "json.hpp"
using json = nlohmann::json;
```

- Use the single-file build `single_include/nlohmann/json.hpp` only.
- Do not `#include <nlohmann/json.hpp>` (unless you kept the full directory structure).
- `json_fwd.hpp` is for forward declarations only; you cannot construct objects or parse with it.

## 0.2 Compilation standard

- The minimum is **C++11**.
- C++14/17/20/23 enable extra features:
  - C++14: transparent comparators `std::less<>`, `std::make_unique`
  - C++17: `std::string_view`, `std::optional`, `std::filesystem`, structured bindings, `if constexpr`
  - C++20: three-way comparison `<=>`
  - C++23: `std::string::contains` and other unrelated features

## 0.3 Type aliases

```cpp
using json         = nlohmann::json;          // ObjectType=std::map
using ordered_json = nlohmann::ordered_json;  // ObjectType=ordered_map, keeps insertion order
```

## 0.4 Default template arguments

| Parameter | Default |
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

## 0.5 Inline namespace and ABI

After expansion, `json.hpp` lands in:

```cpp
namespace nlohmann {
inline namespace json_abi_v3_12_0 { /* ... */ }
}
```

What that means:
- When you write `nlohmann::json`, it resolves automatically through the inline namespace.
- Different versions of `json.hpp` place their symbols in different inline namespaces; **mixing versions causes an ODR conflict at link time**.
- **The single-file build and the multi-file build must not be mixed**.

## 0.6 Thread safety

- **Read-only**: several threads concurrently reading the same `json` object is usually safe.
- **Write**: any modification must be locked externally. The library itself has no locks and no atomics.
- **Iterators** may be invalidated after the container is modified (`push_back` on an array, or modifying an `ordered_json` object, both do this).

---

# Chapter 1 The type system

## 1.1 The `value_t` enum

```cpp
enum class value_t : std::uint8_t {
    null,
    object,
    array,
    string,
    boolean,
    number_integer,   // signed
    number_unsigned,  // unsigned
    number_float,     // floating point
    binary,           // binary
    discarded         // dropped by parsing / a callback
};
```

## 1.2 Internal storage

`basic_json` stores its value in a union:

- Heap-allocated (pointer): object, array, string, binary
- Inline: boolean, number_integer, number_unsigned, number_float

**Consequences**:
- An empty `json` object is roughly the size of `value_t` + a pointer (implementation-dependent, usually 16 bytes).
- Numbers and booleans need no heap allocation, so they are fast.
- A string is heap-allocated even when empty (unless it is `null`).

## 1.3 Type queries

```cpp
j.is_null();
j.is_boolean();
j.is_number();            // any of the three number kinds
j.is_number_integer();    // number_integer or number_unsigned
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

Notes:

- `is_number_integer()` **also returns true for unsigned values**. To tell signed from unsigned, use `is_number_unsigned()`.
- `is_number()` is the union of `is_number_integer() || is_number_float()`.

---

# Chapter 2 Construction

## 2.1 From scalars

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
json j("hello");           // string (const char*)
json j(std::string("x"));  // string
```

Rules:
- Signed integer types → `number_integer`
- Unsigned integer types → `number_unsigned`
- Floating point → `number_float` (always stored as `double`)
- `const char*` → `string` (truncated at `strlen`, ends at `\0`)
- `char` → `number_integer` (**not** a string! This is a trap)

## 2.2 From an initializer list

```cpp
json j = {};                          // empty object {} (note: not an array)
json j = json::array();               // empty array []
json j = {1, 2, 3};                   // array [1,2,3]
json j = {{"a", 1}, {"b", 2}};        // object {"a":1,"b":2}
json j = {1, "x", true};              // array [1,"x",true]
json j = {{"a", {1, 2}}};             // object {"a":[1,2]}
json j = json::array({1, 2, 3});      // force an array
json j = json::object({{"a", 1}});    // force an object
```

**The rule**: if **every** element of an initializer list is a 2-element array whose first element is a string, it is treated as an object; otherwise as an array.

Disambiguation:

```cpp
json j = {{"a", 1}};                  // object {"a":1}
json j = json::array({{"a", 1}});     // array [["a",1]]
json j = {{1, 2}};                    // array [[1,2]] (the first element is not a string)
```

## 2.3 From containers

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

Notes:
- `std::pair` serialises to a 2-element array, **not an object**.
- `std::tuple` serialises to an array.
- The key of `std::map` must be a string-like type (otherwise it serialises to an array of `[key, value]` pairs).

## 2.4 Explicit type construction

```cpp
json j = json::value_t::array;
json j = json::value_t::object;
json j(value_t::null);
```

## 2.5 From another `basic_json` type

```cpp
nlohmann::json         a = ...;
nlohmann::ordered_json b = a;    // implicit conversion (goes through serialisation)
nlohmann::json         c = b;    // likewise
```

The cost: a **deep copy**.

## 2.6 From iterators

```cpp
std::vector<int> v = {1,2,3};
json j(v.begin(), v.end());      // array

json::iterator it1 = j.begin();
json::iterator it2 = j.end();
json k(it1, it2);                // copy the range
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
json j = p;                       // "/tmp/a.json" (a string)
auto q = j.get<std::filesystem::path>();
```

Requires `JSON_HAS_FILESYSTEM` or `JSON_HAS_EXPERIMENTAL_FILESYSTEM` to be 1.

---

# Chapter 3 Parsing

## 3.1 The static `parse`

```cpp
json j = json::parse(R"({"a":1})");
json j = json::parse(text);               // std::string
json j = json::parse(sv);                 // std::string_view (C++17)
json j = json::parse(s.c_str());          // const char*
json j = json::parse(begin_it, end_it);   // iterator range
json j = json::parse(std::ifstream("a.json"));
json j = json::parse(stdin);              // istream&
json j = json::parse(FILE*);
```

## 3.2 The arguments of `parse`

```cpp
json j = json::parse(
    input,
    callback,          // parser_callback_t, may be nullptr
    allow_exceptions,  // default true
    ignore_comments    // default false
);
```

- With `allow_exceptions=false`, an error returns `discarded` instead of throwing.
- With `ignore_comments=true`, `//` and `/* */` comments are accepted (**non-standard JSON**).

## 3.3 The parse callback

```cpp
using parse_event_t = json::parse_event_t;
// object_start, object_end, array_start, array_end, key, value

json j = json::parse(text, [](int depth, json::parse_event_t event, json& parsed) {
    if (event == json::parse_event_t::key) {
        // parsed is the key string
        if (parsed == "secret") return false;  // drop this key and its value
    }
    if (event == json::parse_event_t::value) {
        // parsed is the value about to be written
    }
    return true;  // keep
});
```

Notes:
- Returning `false` from the callback means drop.
- `depth` is the nesting depth (the top-level container is 0).
- A value dropped by returning `false` is removed from its parent container.

## 3.4 Validity checking (no exceptions)

```cpp
bool ok = json::accept(text);
bool ok = json::accept(text, /*ignore_comments=*/true);
```

## 3.5 Parse exceptions

| ID | Meaning |
|---|---|
| `parse_error.101` | syntax error (unexpected token) |
| `parse_error.102` | bad escape sequence |
| `parse_error.103` | bad UTF-8 encoding |
| `parse_error.104` | JSON Patch top level is not an array |
| `parse_error.105` | JSON Patch structural error |
| `parse_error.106` | array index starts with 0 |
| `parse_error.107` | JSON Pointer does not start with `/` |
| `parse_error.108` | JSON Pointer `~` escape error |
| `parse_error.109` | array index is not a number |
| `parse_error.110` | input ends prematurely |
| `parse_error.111` | stream error |
| `parse_error.112` | bad binary-format byte |
| `parse_error.113` | bad binary-format length |
| `parse_error.114` | BSON type not supported |
| `parse_error.115` | UBJSON high-precision number error |

Fields of `parse_error`:

```cpp
catch (const json::parse_error& e) {
    e.what();   // textual description (including line/column)
    e.id;       // 101, etc.
    e.byte;     // byte index of the error position (1-based)
}
```

## 3.6 Parsing an `istream` does not consume the whole stream

```cpp
std::ifstream in("ndjson");
std::string line;
while (std::getline(in, line)) {
    json j = json::parse(line);  // parse each line independently
}
```

Each `parse` stops at the end of the current document. This allows line-by-line NDJSON parsing.

---

# Chapter 4 Serialisation

## 4.1 `dump`

```cpp
j.dump();                   // compact
j.dump(2);                  // indent by 2
j.dump(4, ' ');             // indent by 4, with spaces
j.dump(-1, ' ', true);      // compact + ensure_ascii
j.dump(-1, ' ', false, json::error_handler_t::replace);  // replace invalid UTF-8
```

The signature:

```cpp
string_t dump(
    int indent = -1,
    char indent_char = ' ',
    bool ensure_ascii = false,
    error_handler_t error_handler = error_handler_t::strict
) const;
```

- `indent < 0`: compact.
- `indent >= 0`: indented.
- `ensure_ascii=true`: non-ASCII becomes `\uXXXX`.
- `error_handler`: `strict` / `replace` / `ignore`.

## 4.2 `to_string` / `operator<<`

```cpp
std::string s = nlohmann::to_string(j);   // equivalent to j.dump()
std::cout << j;                           // compact
std::cout << std::setw(4) << j;           // indent by 4 (via width)
std::ofstream("out.json") << j.dump(2);
```

## 4.3 Binary serialisation

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

Arguments of `from_*`:
- `strict` (default true): the input must end at EOF.
- `allow_exceptions` (default true).

## 4.4 The binary type

```cpp
using binary_t = nlohmann::byte_container_with_subtype<std::vector<std::uint8_t>>;

json j = json::binary({0x01, 0x02, 0x03});
json j = json::binary({0x01, 0x02}, 0x10);  // with a subtype

j.is_binary();
j.get_binary();
j.get_binary().has_subtype();
j.get_binary().subtype();
j.get_binary().set_subtype(0x20);
j.get_binary().clear_subtype();
```

Dumping binary:

```json
{"bytes":[1,2,3],"subtype":null}
{"bytes":[1,2],"subtype":16}
```

## 4.5 Stream output

```cpp
std::ostringstream oss;
oss << j;
```

## 4.6 Formats that cannot be written directly

CBOR/MessagePack and the like return a `std::vector<std::uint8_t>` directly; to write a file:

```cpp
auto v = json::to_cbor(j);
std::ofstream("out.cbor", std::ios::binary).write(
    reinterpret_cast<const char*>(v.data()), v.size());
```

---

# Chapter 5 Element access

## 5.1 `operator[]`

**The non-const version**:

- object: if the key does not exist, **inserts `null` and returns a reference**.
- array: if the index is out of range, **extends the array to index + 1 with `null` in between**.
- null: automatically becomes an object (string argument) or an array (numeric argument).
- any other type: throws `type_error.305`.

```cpp
json j;
j["a"] = 1;              // null → object
j["b"]["c"] = 2;         // nesting created automatically
j["arr"][2] = 5;         // arr is an array (throws if it was not one before)
```

**The const version**:

- object: when `find` fails the behaviour is **undefined** (an internal assertion; in Release it may return an empty reference or crash).
- array: out of range is undefined.

**Conclusion**: in read-only scenarios **never** use `operator[]`; use `at()` / `value()` / `contains()` / `find()`.

## 5.2 `at`

```cpp
j.at("key");     // throws out_of_range.403 if the key is absent
j.at(0);         // throws out_of_range.401 if out of range
```

Signature variants:

```cpp
reference at(size_type idx);
const_reference at(size_type idx) const;
reference at(const typename object_t::key_type& key);
template<class KeyType> reference at(KeyType&& key);  // transparent comparison, accepts string_view
```

## 5.3 `value`

```cpp
int v = j.value("port", 8080);
std::string s = j.value("name", std::string("unknown"));
```

Signature:

```cpp
template<class ValueType>
ValueType value(const key_type& key, const ValueType& default_value) const;
```

Semantics:
- Key absent: returns `default_value`.
- Key present and the type is convertible: returns the converted value.
- Key present and the type does not match: throws `type_error.302` (**it does not return the default**).

## 5.4 `get<T>()`

```cpp
int n = j.get<int>();
std::string s = j.get<std::string>();
std::vector<int> v = j.get<std::vector<int>>();
std::map<std::string, int> m = j.get<std::map<std::string, int>>();

auto ptr = j.get<json::object_t*>();             // returns an internal pointer
auto ref = j.get_ref<const std::string&>();      // a reference
```

Internal priority:
1. default construction + `from_json`
2. non-default construction `from_json`
3. conversion between different `basic_json` types
4. same type returned directly
5. pointer types return an internal pointer

Type mismatch: `type_error.302`.

**C++17** supports `std::optional`:

```cpp
auto o = j.get<std::optional<int>>();  // returns nullopt if the value is null
```

## 5.5 `get_to`

```cpp
int n;         j.at("age").get_to(n);
std::string s; j.at("name").get_to(s);
```

A type mismatch throws `type_error.302`.

## 5.6 `get_ref`

```cpp
const std::string& s = j.at("name").get_ref<const std::string&>();
std::string& s = j["name"].get_ref<std::string&>();
const auto& obj = j.get_ref<const json::object_t&>();
const auto& arr = j.get_ref<const json::array_t&>();
```

Returns a reference, zero copy. A type mismatch throws `type_error.303`.

## 5.7 `get_ptr`

```cpp
const std::string* sp = j.get_ptr<const std::string*>();
std::string* sp = j.get_ptr<std::string*>();
const json::object_t* op = j.get_ptr<const json::object_t*>();
```

A type mismatch returns `nullptr` (no throw).

## 5.8 `front` / `back`

```cpp
j.front();   // *begin()
j.back();    // *(--end())
```

**Undefined** for an empty array/object. For a primitive it is equivalent to `*j`.

## 5.9 Iterator access

```cpp
auto it = j.begin();
*it;         // json&
it.key();    // only valid for objects, returns const string&
it.value();  // equivalent to *it
```

---

# Chapter 6 Iterators (important)

## 6.1 Category

`basic_json::iterator` is a **BidirectionalIterator**, **not a RandomAccessIterator**.

Consequences:
- You **cannot** use `it + n`, `it - n`, `it[n]`, `it1 < it2` (object iterators do not support `<`).
- Array and primitive iterators **do support** `<`, `++`, `--`, `std::next`, `std::advance`.
- **Object iterators do not support** `<` or addition/subtraction; only `++/--`.

Correct advancement:

```cpp
auto it = j.begin();
std::advance(it, 3);          // works for arrays and primitives
auto it2 = std::next(j.begin(), 2);  // likewise
```

Object iterators can only be stepped with `++/--`.

## 6.2 Iteration behaviour by type

| Type | begin() | end() | Dereference |
|---|---|---|---|
| null | == end() | == begin() | throws invalid_iterator |
| object | first key | past-the-end | json& (the value) |
| array | first element | past-the-end | json& |
| string | itself | past-the-end | json& (itself) |
| boolean | itself | past-the-end | json& (itself) |
| number_* | itself | past-the-end | json& (itself) |
| binary | itself | past-the-end | json& (itself) |
| discarded | itself | past-the-end | json& (itself) |

## 6.3 Structured bindings

```cpp
for (auto& [key, value] : j.items()) {
    // key is const string& (object) or string (an array index as a string)
    // value is json&
}

// or use value() / key()
for (auto& el : j.items()) {
    std::cout << el.key() << " : " << el.value() << "\n";
}
```

For arrays, `items()` makes `key()` return **the index as a string** (`"0"`, `"1"`, ...).

## 6.4 `rbegin` / `rend`

```cpp
for (auto it = j.rbegin(); it != j.rend(); ++it) { }
```

## 6.5 `iterator_wrapper` (deprecated)

```cpp
for (auto& el : json::iterator_wrapper(j)) { }  // use items() instead
```

## 6.6 Iterator invalidation

- Array `push_back` / `insert` / `erase`: may invalidate iterators (like `std::vector`).
- Object (`std::map`): inserting/deleting other keys does not affect existing iterators.
- `ordered_json`: internally a `std::vector`, so insert/delete invalidates.
- **No modification is safe during an ongoing iteration** (unless you use the return value of `erase`).

## 6.7 `erase` and iteration

```cpp
for (auto it = j.begin(); it != j.end(); ) {
    if (should_delete(*it)) {
        it = j.erase(it);    // erase returns the next iterator
    } else {
        ++it;
    }
}
```

---

# Chapter 7 Lookup, containment, counting

```cpp
j.contains("key");              // bool
j.contains(json_pointer);       // supports JSON Pointer
j.count("key");                 // 0 or 1
j.find("key");                  // iterator, == end() when not found
```

C++14 and later support transparent lookup:

```cpp
j.find(std::string_view("key"));
j.contains(std::string_view("key"));
```

This requires `object_comparator_t` to be transparent (the default `std::less<>` on C++14+).

---

# Chapter 8 Modification

## 8.1 Arrays

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
j.pop_back();     // no such method; use erase(j.size()-1) or erase(j.end()-1)
```

## 8.2 Objects

```cpp
j.emplace("a", 1);                    // returns pair<iterator, bool>
j.insert({"a", 1});                    // does not overwrite if present
j.insert({{"a",1}, {"b",2}});
j["a"] = 1;                            // overwrites
j.push_back({"a", 1});                 // object or null only
j.erase("a");                          // returns the number removed
j.update(other);                       // shallow merge: other's keys overwrite
j.update(other, /*merge_objects=*/true); // deep merge: recursively merge objects
```

## 8.3 Common to arrays/objects

```cpp
j.clear();
j.swap(other);
swap(j, other);                        // ADL
j = json::array();                     // reset to an empty array
j = json::object();
```

## 8.4 The semantics of `update`

```cpp
json a = {{"x", 1}, {"y", {{"z", 2}}}};
json b = {{"y", {{"w", 3}}}};

a.update(b);                     // {"x":1, "y":{"w":3}}    ← the whole y is replaced
a.update(b, true);               // {"x":1, "y":{"z":2,"w":3}}  ← recursively merged
```

## 8.5 The return types of `erase`

```cpp
size_type erase(const key_type&);        // object, number removed
void erase(size_type);                    // array
iterator erase(iterator);                 // returns the next
iterator erase(iterator, iterator);       // returns the next
```

---

# Chapter 9 Capacity and size

```cpp
j.empty();        // true for null / an empty array / an empty object
j.size();         // null: 0, primitive: 1, container: element count
j.max_size();     // the container's maximum capacity
```

It returns 1 for a primitive and 0 for null.

---

# Chapter 10 Comparison

## 10.1 Comparison within the same type

```cpp
json a = 1, b = 2;
a == b;   // false
a <  b;   // true
a <= b;   // true
```

## 10.2 Cross-type comparison

The order of types (`value_t`):

```
null < boolean < number < object < array < string < binary
```

Within numbers, the three kinds (integer/unsigned/float) are compared by numeric value; everything else follows the type order.

```cpp
json(1) == json(1.0);          // true
json(1) == json(1u);            // true
json(0) == json(false);         // false (boolean ≠ number)
json(nullptr) == json(0);       // false
json("1") == json(1);           // false (string ≠ number)
```

## 10.3 Comparison with scalars

```cpp
j == 42;
j == 3.14;
j == "hello";
j == true;
j == nullptr;
42 == j;      // reversed
```

## 10.4 NaN and discarded

- `json(std::nan("")) == json(std::nan(""))` → **false**.
- Any `<` or `>` involving NaN returns false.
- Comparison with `discarded` is ordered by default (`discarded` is smaller than everything), unless `JSON_USE_LEGACY_DISCARDED_VALUE_COMPARISON=1` is defined.

## 10.5 C++20 three-way comparison

```cpp
std::partial_ordering ord = j1 <=> j2;
ord == std::partial_ordering::less / equal / greater / unordered;
```

---

# Chapter 11 Number details

## 11.1 Storage types

- `number_integer_t` = `std::int64_t`
- `number_unsigned_t` = `std::uint64_t`
- `number_float_t` = `double`

## 11.2 How numbers are parsed

- No sign → try `uint64_t`
- A `-` present → try `int64_t`
- A decimal point or exponent → `double`
- Out of `uint64_t`/`int64_t` range → `double`
- Out of `double` range (such as `1e400`) → `parse_error.406` or `out_of_range.406`

## 11.3 Dumping numbers

- Integers: converted using the built-in integer-to-string conversion.
- Floats: Grisu2, guaranteeing round-trip.
- `NaN` / `Inf` → `null`.

```cpp
json j = std::nan("");
j.dump();   // "null"
```

## 11.4 Type mismatches

```cpp
json j = 42;
j.get<std::string>();    // throws type_error.302
j.get<double>();         // OK, returns 42.0
j.get<uint64_t>();       // OK
```

Implicit number conversions go through `get_arithmetic_value`, which performs range checks.

## 11.5 Precision traps

```cpp
json j = 9007199254740993LL;   // 2^53 + 1
j.get<int64_t>() == 9007199254740993LL;   // true (integers are exact)

json j = 0.1;
j.dump();   // "0.1"

json j = 1e-7;
j.dump();   // "1e-07"
```

**Do not store integers that must be exact in a `double`** (beyond 2^53 they lose precision).

## 11.6 Advice for big integers

Numbers beyond the `uint64_t` range can only use `double`, which loses precision. When higher precision is needed:
- store them as strings.
- use an external arbitrary-precision library.

---

# Chapter 12 Strings and UTF-8

## 12.1 Internal encoding

`std::string` stores the **UTF-8 bytes** directly. The library does no wide-character conversion.

## 12.2 Input encoding

- String literals and `std::string`: passed in as bytes, not validated.
- `std::wstring` / `std::u16string` / `std::u32string`: go through `input_adapter` → `wide_string_input_adapter` and are converted to UTF-8 automatically. Only parsing input is supported; wide-character output is not.

```cpp
std::wstring ws = L"hello 世界";
json j = json::parse(ws);   // converted to UTF-8 automatically
```

## 12.3 UTF-8 validation while parsing

- `\uXXXX` escapes and surrogate pairs inside strings are decoded to UTF-8.
- Invalid UTF-8 bytes throw `parse_error.102/103/113`.
- Control characters in strings must be escaped.

## 12.4 UTF-8 handling when dumping

`error_handler_t`:

| Value | Behaviour |
|---|---|
| `strict` | throws `type_error.316` (the default) |
| `replace` | replaces invalid bytes with U+FFFD (`\uFFFD` or `\xEF\xBF\xBD`) |
| `ignore` | skips invalid bytes |

With `ensure_ascii=true`, everything non-ASCII becomes `\uXXXX` (surrogate pairs included).

## 12.5 What `get<std::string>()` returns

It returns the **raw UTF-8 bytes**. `size()` is the byte count, not the character count.

```cpp
json j = "中文";
std::string s = j.get<std::string>();
s.size();   // 6 (UTF-8 uses 3 bytes per Chinese character)
```

## 12.6 Embedded `\0`

A `std::string` may contain `\0`, which dump escapes as `\u0000`. Construction from `const char*` is truncated at `strlen`.

```cpp
json j = std::string("a\0b", 3);   // a 3-byte string
j.dump();                          // "\"a\\u0000b\""
```

## 12.7 BOM

When parsing, an `EF BB BF` (UTF-8 BOM) is skipped if present. UTF-16/UTF-32 BOMs are handled by `wide_string_input_adapter`.

---

# Chapter 13 Copy and move (important)

## 13.1 Copy construction

```cpp
json a = {{"x", 1}};
json b = a;              // deep copy
b["x"] = 2;              // a is unchanged
```

The whole tree is deep-copied. That is expensive for large objects.

## 13.2 Move construction

```cpp
json a = {{"x", 1}};
json b = std::move(a);   // a becomes null
```

A move is O(1) (a pointer transfer).

## 13.3 Copy assignment / move assignment

```cpp
a = b;                   // deep copy
a = std::move(b);        // b becomes null
```

## 13.4 Copies in container operations

```cpp
j.push_back(big_json);            // copy
j.push_back(std::move(big_json)); // move
j.emplace_back(args...);          // construct in place (if the arguments can construct a json directly)
j.insert(j.begin(), big);         // copy
```

**Prefer moving when adding elements in a loop**:

```cpp
for (auto& item : items) {
    result.push_back(std::move(item));  // if item is disposable
}
```

## 13.5 Iterators return references

`*it` returns `json&`; assigning it to a `json` copies:

```cpp
json copy = *it;                // copy
json& ref = *it;                // reference
const json& cref = *it;         // const reference
```

---

# Chapter 14 Serialising custom types

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

Rules:
- The functions must live in the namespace of the type (found via ADL) or in namespace `nlohmann`.
- Declare them before use.
- Template types need an `adl_serializer` specialisation or ADL functions.

## 14.2 Specialising `adl_serializer`

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

## 14.3 The macro approach

```cpp
struct Person {
    std::string name;
    int age;
    NLOHMANN_DEFINE_TYPE_INTRUSIVE(Person, name, age)
};

struct Point { int x, y; };
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(Point, x, y)
```

| Macro | Purpose |
|---|---|
| `NLOHMANN_DEFINE_TYPE_INTRUSIVE(Type, ...)` | inside the class, both directions |
| `NLOHMANN_DEFINE_TYPE_INTRUSIVE_WITH_DEFAULT(Type, ...)` | missing fields fall back to defaults |
| `NLOHMANN_DEFINE_TYPE_INTRUSIVE_ONLY_SERIALIZE(Type, ...)` | serialise only |
| `NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(Type, ...)` | outside the class, both directions |
| `NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE_WITH_DEFAULT(Type, ...)` | missing fields fall back to defaults |
| `NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE_ONLY_SERIALIZE(Type, ...)` | serialise only |
| `NLOHMANN_DEFINE_DERIVED_TYPE_INTRUSIVE(Type, BaseType, ...)` | includes a base class |
| `NLOHMANN_DEFINE_DERIVED_TYPE_NON_INTRUSIVE(Type, BaseType, ...)` | includes a base class |

After expansion the macros use `j[#field]` and `j.at(#field).get_to(field)`.

- `_WITH_DEFAULT` uses `j.value(field, default_obj.field)`, so a missing field does not throw.
- `_ONLY_SERIALIZE` provides `to_json` only.

## 14.4 Nested custom types

```cpp
struct Address { std::string city; };
struct User { std::string name; Address addr; };

NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(Address, city)
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(User, name, addr)
```

## 14.5 Enums

```cpp
enum class Color { Red, Green, Blue };

NLOHMANN_JSON_SERIALIZE_ENUM(Color, {
    {Color::Red,   "red"},
    {Color::Green, "green"},
    {Color::Blue,  "blue"},
})
```

- An unmatched value falls back to the first entry (`Red`).
- Without the macro, enums serialise as integers.
- To disable: `JSON_DISABLE_ENUM_SERIALIZATION=1`.

## 14.6 C++17 `std::optional`

Built in:

```cpp
std::optional<int> o = 42;
json j = o;                          // 42
o = j.get<std::optional<int>>();     // 42

std::optional<int> e = std::nullopt;
json j = e;                          // null
e = j.get<std::optional<int>>();     // nullopt
```

## 14.7 `std::variant` (not built in)

`std::variant` is not built in. Provide your own `to_json` / `from_json` using `std::visit`.

## 14.8 `std::filesystem::path`

Built in (C++17). See 2.8.

## 14.9 Smart pointers (not built in)

`std::shared_ptr` / `std::unique_ptr` are **not built in**. Provide them yourself:

```cpp
template <typename T>
void to_json(json& j, const std::shared_ptr<T>& p) {
    if (p) to_json(j, *p);
    else   j = nullptr;
}
```

---

# Chapter 15 Exceptions

## 15.1 The exception hierarchy

```
nlohmann::json::exception
├── parse_error
├── invalid_iterator
├── type_error
├── out_of_range
└── other_error
```

**Note**: none of them derives from `std::runtime_error`. Catching `json::exception` is enough.

## 15.2 The common ID table

| Exception | ID | Meaning |
|---|---|---|
| parse_error | 101 | syntax error |
| parse_error | 102 | bad escape sequence |
| parse_error | 103 | UTF-8 error |
| parse_error | 104/105 | JSON Patch structural error |
| parse_error | 106 | leading 0 in an array index |
| parse_error | 107/108 | JSON Pointer error |
| parse_error | 109 | array index is not a number |
| parse_error | 110 | input ends prematurely |
| parse_error | 111 | stream error |
| parse_error | 112/113 | binary-format error |
| invalid_iterator | 201 | incompatible iterator |
| invalid_iterator | 202/203/204 | iterator mismatch / out of range |
| invalid_iterator | 205 | primitive iterator out of range |
| invalid_iterator | 206 | bad iterator construction |
| invalid_iterator | 207 | key() used on a non-object |
| invalid_iterator | 208 | operator[] used on an object |
| invalid_iterator | 209 | object offset |
| invalid_iterator | 210/211 | iterator mismatch |
| invalid_iterator | 212/213 | iterator comparison |
| invalid_iterator | 214 | bad value access |
| type_error | 301 | type deduction failed |
| type_error | 302 | get/at type mismatch |
| type_error | 303 | get_ref type mismatch |
| type_error | 304/305 | at/operator[] type error |
| type_error | 306 | value() type error |
| type_error | 307 | erase() type error |
| type_error | 308/309 | push_back/insert type error |
| type_error | 310 | swap type error |
| type_error | 311 | emplace type error |
| type_error | 312 | update type error |
| type_error | 313 | invalid unflatten |
| type_error | 314/315 | unflatten structural error |
| type_error | 316 | invalid UTF-8 (while dumping) |
| type_error | 317 | BSON top level is not an object |
| out_of_range | 401 | array index out of range |
| out_of_range | 402 | JSON Pointer array index `-` |
| out_of_range | 403 | object key not found |
| out_of_range | 404 | JSON Pointer cannot be resolved |
| out_of_range | 405 | JSON Pointer has no parent |
| out_of_range | 406 | number overflow |
| out_of_range | 408 | container too large |
| out_of_range | 409 | BSON key contains `\0` |
| out_of_range | 410 | array index exceeds size_type |
| other_error | 501 | other |
| other_error | 502 | internal |

## 15.3 A catch example

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

## 15.4 Disabling exceptions

Define `JSON_NOEXCEPTION`: every `JSON_THROW` becomes `std::abort()`. **You can no longer catch.**

Custom throwing:

```cpp
#define JSON_THROW_USER(exception) throw MyException(exception)
```

---

# Chapter 16 JSON Pointer (RFC 6901)

## 16.1 The literal

```cpp
using namespace nlohmann::literals;
json& v = j["/a/b/0"_json_pointer];
```

## 16.2 Construction

```cpp
json::json_pointer p("/a/b/0");
json::json_pointer p = "/a/b"_json_pointer;
```

## 16.3 Escaping

- `~0` means `~`
- `~1` means `/`

```cpp
json j = {{"a/b", 1}};
j["/a~1b"_json_pointer];   // accesses "a/b"
```

## 16.4 Access

```cpp
j.at(ptr);              // throws out_of_range when out of range
j[ptr];                 // non-const: creates when absent
j.contains(ptr);        // bool
j.value(ptr, default);  // with a default
```

## 16.5 Array indices

- `"0"`: valid.
- `"01"`: invalid (leading 0, throws `parse_error.106`).
- `"-"`: only used to append in patch; `at` throws `out_of_range.402`.

## 16.6 Common members

```cpp
json_pointer p = "/a/b"_json_pointer;
p.empty();                    // whether it is the root
p.back();                     // the last token
p.pop_back();                 // remove the last
p.push_back("c");             // append
p.parent_pointer();           // the parent pointer
p.to_string();                // to a string
p /= "d";                     // append
p /= 2;                       // append an array index
json_pointer q = p / "e";     // a new pointer
```

## 16.7 flatten / unflatten

```cpp
json flat = j.flatten();       // every leaf becomes "/a/b": value
json orig = flat.unflatten();  // restore
```

flatten rules:
- An empty object/array is flattened to `null`.
- Object keys are escaped (`~0` / `~1`).

---

# Chapter 17 JSON Patch / Diff / Merge Patch

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

j.patch_inplace(patch);        // in place
json j2 = j.patch(patch);      // a copy
```

## 17.2 Diff (RFC 6902)

```cpp
json patch = json::diff(before, after);
json after2 = before.patch(patch);
```

- The delete operations of an array diff are generated **in reverse order** to avoid index shifting.
- Additions use `/-` to append.

## 17.3 Merge Patch (RFC 7396)

```cpp
json target = {{"a", 1}, {"b", {{"c", 2}}}};
json mp = {{"b", {{"c", 3}}}, {"d", 4}, {"a", nullptr}};
target.merge_patch(mp);
// result: {"b":{"c":3}, "d":4}   a is removed by the null
```

Semantics:
- If the top-level patch is not an object: replace outright.
- If the patch is an object: merge recursively.
- A `null` value: delete the corresponding key.

---

# Chapter 18 Binary formats

## 18.1 The supported list

| Format | Encode | Decode | Top-level restriction |
|---|---|---|---|
| CBOR | `to_cbor` | `from_cbor` | none |
| MessagePack | `to_msgpack` | `from_msgpack` | none |
| UBJSON | `to_ubjson` | `from_ubjson` | none |
| BJData | `to_bjdata` | `from_bjdata` | none |
| BSON | `to_bson` | `from_bson` | the top level must be an object |

## 18.2 CBOR tags

```cpp
json j = json::from_cbor(v, true, true, json::cbor_tag_handler_t::error);
// error: throw when a tag is met
// ignore: ignore tags
// store: store as a binary subtype
```

## 18.3 UBJSON arguments

```cpp
json::to_ubjson(j);                       // no optimisation
json::to_ubjson(j, true);                 // use_size
json::to_ubjson(j, true, true);           // use_size + use_type
json::to_ubjson(j, true, true, true);     // plus add_prefix (internal use)
```

## 18.4 BJData versions

```cpp
json::to_bjdata(j, false, false, json::bjdata_version_t::draft2);
json::to_bjdata(j, false, false, json::bjdata_version_t::draft3);
```

## 18.5 BSON

- The top level must be an object, otherwise `type_error.317`.
- Keys must not contain `\0`, otherwise `out_of_range.409`.

## 18.6 The binary type

See 4.4.

---

# Chapter 19 SAX streaming parsing

## 19.1 Purpose

- Large files where you do not want to build the whole tree.
- Processing while parsing.

## 19.2 The interface

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

## 19.3 A minimal implementation

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

## 19.4 Binary SAX

```cpp
json::sax_parse(v, &sax, json::input_format_t::cbor);
json::sax_parse(v, &sax, json::input_format_t::msgpack);
```

## 19.5 `unknown_size`

When the container size is unknown, the `start_object/start_array` argument is `detail::unknown_size()` (the maximum `size_t` value).

---

# Chapter 20 Configuration macros

| Macro | Default | Effect |
|---|---|---|
| `JSON_NOEXCEPTION` | undefined | disables exceptions; errors call `abort` |
| `JSON_THROW_USER(ex)` | undefined | custom throwing |
| `JSON_TRY_USER` | undefined | custom try |
| `JSON_CATCH_USER` | undefined | custom catch |
| `JSON_ASSERT(x)` | `assert(x)` | custom assertion |
| `JSON_DIAGNOSTICS` | 0 | exceptions carry the JSON path |
| `JSON_DIAGNOSTIC_POSITIONS` | 0 | exceptions carry byte positions |
| `JSON_USE_IMPLICIT_CONVERSIONS` | 1 | 0 disables implicit conversions |
| `JSON_DISABLE_ENUM_SERIALIZATION` | 0 | 1 disables automatic enum serialisation |
| `JSON_NO_IO` | undefined | disables iostream support |
| `JSON_USE_GLOBAL_UDLS` | 1 | 0 stops auto-`using` the literals |
| `JSON_SKIP_UNSUPPORTED_COMPILER_CHECK` | undefined | skip the compiler version check |
| `JSON_SKIP_LIBRARY_VERSION_CHECK` | undefined | skip the version check |
| `JSON_USE_LEGACY_DISCARDED_VALUE_COMPARISON` | 0 | 1 enables the legacy discarded comparison |
| `JSON_HAS_CPP_11/14/17/20/23` | automatic | manually override the language-standard detection |

## 20.1 `JSON_USE_IMPLICIT_CONVERSIONS=0`

Every `T x = j;` fails to compile; you must write:

```cpp
T x = j.get<T>();
```

The comparison operators `j == 42` are **unaffected**.

## 20.2 `JSON_DIAGNOSTICS=1`

Exception messages then carry the path:

```
[json.exception.type_error.302] (/server/port) type must be string, but is number
```

Costs:
- every `json` gains an `m_parent` pointer.
- copy/move must maintain the parent pointer.
- memory overhead grows.

## 20.3 `JSON_DIAGNOSTIC_POSITIONS=1`

Exception messages also carry byte positions:

```
[json.exception.type_error.302] (bytes 10-20) (/a/b) ...
```

The same costs as above, plus recording the start/end positions.

---

# Chapter 21 Metadata

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

# Chapter 22 Miscellaneous

## 22.1 `std::hash`

```cpp
std::unordered_map<std::string, json> m;   // OK
std::unordered_set<json> s;                // OK
std::hash<json> h;
auto v = h(j);
```

`hash()` distinguishes null, 0, 0u, false and other distinct types.

## 22.2 `to_string`

```cpp
std::string s = nlohmann::to_string(j);    // equivalent to j.dump()
```

## 22.3 Literals

```cpp
using namespace nlohmann::literals;        // already auto-`using`ed by default
json j = R"({"a":1})"_json;
auto p = "/a/b"_json_pointer;
```

To disable: `JSON_USE_GLOBAL_UDLS=0`.

## 22.4 `operator value_t`

```cpp
json::value_t t = j;    // implicit conversion to value_t
switch (j) {
    case json::value_t::object: ...
}
```

## 22.5 Derived classes

```cpp
class MyJson : public nlohmann::json {
public:
    using nlohmann::json::json;
};
```

Inheritance is generally not recommended; it runs into many traps. Use the `CustomBaseClass` template parameter instead:

```cpp
struct MyBase { /* ... */ };
using my_json = nlohmann::basic_json<
    std::map, std::vector, std::string, bool, std::int64_t, std::uint64_t, double,
    std::allocator, nlohmann::adl_serializer, std::vector<std::uint8_t>, MyBase>;
```

## 22.6 Assignment between different `basic_json` types

```cpp
nlohmann::json         a = ...;
nlohmann::ordered_json b = a;
nlohmann::json         c = b;
```

It goes through serialisation, so it is a **deep copy**.

## 22.7 Custom allocators

```cpp
using my_json = nlohmann::basic_json<
    std::map, std::vector, std::string, bool, std::int64_t, std::uint64_t, double,
    MyAllocator>;
```

## 22.8 Custom string types

```cpp
using my_json = nlohmann::basic_json<
    std::map, std::vector, MyString, bool, std::int64_t, std::uint64_t, double>;
```

`MyString` must satisfy the string interface.

---

# Chapter 23 The checklist of common traps

1. **`operator[]` on a `const json&` for a key that does not exist → undefined behaviour**.
2. **A non-const `operator[]` inserts the key**.
3. **`value(key, default)` returns the default only when the key is absent**.
4. **`get<T>()` throws on a type mismatch**; it does no loose conversion.
5. **An integer beyond int64/uint64 degrades to double and loses precision**.
6. **`NaN`/`Inf` dump as `null`**.
7. **Objects are sorted by key by default** (`std::map`); use `ordered_json` for insertion order.
8. **Iterators are Bidirectional, not RandomAccess**, so `it + n` is invalid (except for arrays/primitives).
9. **Object iterators do not support `<`**.
10. **Modifying a container invalidates iterators**.
11. **`json` is not thread-safe**; only concurrent read-only is safe.
12. **`parse` is strict by default**, so nothing may follow at the end.
13. **`parse(istream)` does not consume the whole stream**.
14. **`dump` does not escape non-ASCII by default**.
15. **Different versions of json.hpp must not be mixed**.
16. **The single-file and multi-file builds must not be mixed**.
17. **`operator[]` with an out-of-range array index extends the array with nulls**.
18. **Constructing a `json` from `char` makes a number**, not a string.
19. **`json(std::string("a\0b", 3))` may contain `\0`**, while `const char*` truncates.
20. **`pair` serialises to an array**, not an object.
21. **`optional<T>` serialises to `null` when it is nullopt**.
22. **`get<std::vector<T>>()` does not work on a string** (a string is not an array).
23. **`json::diff` generates array deletes in reverse order**.
24. **In `merge_patch`, `null` means delete**.
25. **`discarded` differs from `null`**.
26. **Under `JSON_NOEXCEPTION`, `JSON_THROW` becomes `abort`**.
27. **After `JSON_USE_IMPLICIT_CONVERSIONS=0` you must use explicit `get<T>()`**.
28. **A default-constructed `json::iterator` is uninitialised**, and most operations on it are undefined.
29. **`begin() == end()` holds for null**, since null counts as an empty container.
30. **A primitive can be iterated once**, and dereferencing returns itself.
31. **`erase` returns the next iterator**; continue with the return value in a loop.
32. **`std::string_view` is supported only from C++17**.
33. **`std::filesystem::path` is supported only from C++17**.
34. **`std::optional` is supported only from C++17**.
35. **An object iterator's `it.key()` returns `const string&`**, which cannot be modified.
36. **`at` and `operator[]` behave very differently**; prefer `at` for read-only access.
37. **A type mismatch in `value()` throws `type_error.302`**.
38. **After `flatten()`, an empty object/array becomes `null`**.
39. **`unflatten()` requires every value to be a primitive**.
40. **The BSON top level must be an object**.

---

# Chapter 24 A quick reference of idioms

```cpp
// safe reading
int port = j.value("port", 8080);
std::string host = j.value("host", std::string("localhost"));

// optional field
if (j.contains("timeout")) {
    int t = j["timeout"].get<int>();
}

// iterate an object
for (auto& [k, v] : j.items()) {
    if (v.is_string() && k != "password") {
        std::cout << k << "=" << v.get<std::string>() << "\n";
    }
}

// array to vector
auto nums = j["nums"].get<std::vector<int>>();

// object to map
auto m = j.get<std::map<std::string, int>>();

// read a file
std::ifstream in("config.json");
json cfg = json::parse(in);

// write a file
std::ofstream("config.json") << cfg.dump(2);

// safe nested read
int getPort(const json& cfg) {
    try {
        return cfg.at("server").at("port").get<int>();
    } catch (const json::exception&) {
        return 8080;
    }
}

// iterate and delete
for (auto it = j.begin(); it != j.end(); ) {
    if (should_remove(*it)) it = j.erase(it);
    else ++it;
}

// deep copy
json copy = original;                  // deep copy
json moved = std::move(original);      // move, the original becomes null

// array indices as keys
for (std::size_t i = 0; i < j.size(); ++i) {
    std::cout << i << " = " << j[i].dump() << "\n";
}

// with JSON Pointer
json& v = j["/a/b/0"_json_pointer];

// on the exception path (after enabling JSON_DIAGNOSTICS=1)
try { j.at("x").get<std::string>(); }
catch (const json::exception& e) { std::cerr << e.what() << "\n"; }

// custom type
void to_json(json& j, const MyType& v) { j = json{{"x", v.x}}; }
void from_json(const json& j, MyType& v) { j.at("x").get_to(v.x); }

// string fidelity
json j = std::string("a\0b", 3);       // contains \0
j.dump();                              // "a\u0000b"

// replace invalid UTF-8
j.dump(-1, ' ', false, json::error_handler_t::replace);

// ASCII-only output
j.dump(2, ' ', true);

// parse NDJSON
std::ifstream in("data.ndjson");
std::string line;
while (std::getline(in, line)) {
    json j = json::parse(line);
}

// SAX streaming
struct MySax : nlohmann::json_sax<json> { /* ... */ };
MySax sax;
json::sax_parse(text, &sax);
```

---

# Chapter 25 Version and compatibility

- 3.12.0 is the version this document corresponds to.
- Version macros:

```cpp
NLOHMANN_JSON_VERSION_MAJOR   // 3
NLOHMANN_JSON_VERSION_MINOR   // 12
NLOHMANN_JSON_VERSION_PATCH   // 0
```

- Mixing different versions: an ODR conflict at link time. Different versions place their symbols in different inline namespaces (`json_abi_v3_12_0`).
- The single-file and multi-file builds must not be mixed.

---

# Chapter 26 The quick decision table

| Need | How |
|---|---|
| parse a string | `json::parse(s)` |
| parse a file | `json::parse(std::ifstream(...))` |
| parse a stream | `json::parse(istream)` |
| check validity | `json::accept(s)` |
| serialise compact | `j.dump()` |
| serialise indented | `j.dump(2)` |
| serialise ASCII | `j.dump(2, ' ', true)` |
| binary CBOR | `json::to_cbor(j)` / `json::from_cbor(v)` |
| read an object key | `j.at("k")` / `j.value("k", d)` / `j.contains("k")` |
| write an object key | `j["k"] = v` |
| append to an array | `j.push_back(v)` / `j.emplace_back(args)` |
| access an array | `j[0]` (non-const) / `j.at(0)` (const-safe) |
| iterate an object | `for (auto& [k,v] : j.items())` |
| iterate and delete | `it = j.erase(it)` |
| deep copy | `json copy = j` |
| move | `json m = std::move(j)` |
| custom types | ADL `to_json/from_json` or the macros |
| enum mapping | `NLOHMANN_JSON_SERIALIZE_ENUM` |
| keep insertion order | `ordered_json` |
| streaming parse | `json::sax_parse(text, &sax)` |
| JSON Pointer | `j["/a/b"_json_pointer]` |
| JSON Patch | `j.patch(patch)` / `json::diff(a, b)` |
| Merge Patch | `j.merge_patch(mp)` |
| exception diagnostics | define `JSON_DIAGNOSTICS=1` |
| disable exceptions | define `JSON_NOEXCEPTION` |
| disable implicit conversion | define `JSON_USE_IMPLICIT_CONVERSIONS=0` |

