using System;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace LingoFuse.Io;

// ============================================================================
// JsonPolicy — the single source of truth for JSON serialisation.
// ============================================================================
//
// The LingoFuse wire contract mandates two properties on every JSON
// payload that crosses a boundary:
//
//   1. Literal UTF-8 for non-ASCII characters.
//      The bytes on the wire must contain the raw UTF-8 sequence for
//      "你好" — not the escape sequence "\u4f60\u597d". This is what
//      "ensure_ascii = false" means in the Python toolchain, and it
//      must hold identically from C#.
//
//   2. Compact output.
//      No indentation, no trailing newline.
//
// System.Text.Json defaults to a conservative encoder that escapes every
// non-ASCII character. The encoder below relaxes that behaviour so the
// C# producer emits the same bytes the Pascal, C++ and Python producers
// emit.
//
// ----------------------------------------------------------------------------
// NULL HANDLING
// ----------------------------------------------------------------------------
// A null value is serialised as the four-byte JSON literal `null`, not
// as an exception and not as an empty string. This matches the
// behaviour of every other toolchain producer and allows a caller to
// invoke a no-argument remote API by passing `null`.
//
// ----------------------------------------------------------------------------
// {!!!!!  CROSS-LANGUAGE CONSISTENCY NOTES  !!!!!}
// ----------------------------------------------------------------------------
// Two areas where System.Text.Json's defaults differ from the other
// LingoFuse bindings, and the recommended mitigations.
//
// 1. PROPERTY NAMES
//
//    System.Text.Json uses the C# property name verbatim by default
//    (PascalCase, matching the C# naming convention). The other
//    LingoFuse bindings conventionally use snake_case for JSON keys.
//
//    This matters ONLY when a C# record or class is serialised and
//    sent to a peer that deserialises into a name-matched shape. The
//    wire contract itself is name-agnostic; the semantic mismatch is
//    in the payload schema, not in the transport.
//
//    Recommended mitigation:
//
//        Use [JsonPropertyName("snake_case_name")] on every property
//        of a type that will cross the wire, so the JSON keys match
//        what the other bindings produce and expect.
//
//        Example:
//            public sealed record InvSeriArgs(
//                [property: JsonPropertyName("b")]   byte   B,
//                [property: JsonPropertyName("w")]   ushort W,
//                [property: JsonPropertyName("c")]   uint   C,
//                [property: JsonPropertyName("u64")] ulong  U64,
//                [property: JsonPropertyName("s")]   string S,
//                [property: JsonPropertyName("f")]   float  F);
//
//    The library deliberately does NOT set a global naming policy,
//    because:
//        - a global policy would silently rename every existing C#
//          payload, breaking any peer that already expects PascalCase;
//        - a per-type attribute is explicit, reviewable, and stable.
//
//    An opt-in alternative is provided via `OptionsSnakeCase`, which
//    can be used by a caller that wants snake_case globally for its
//    own payloads.
//
// 2. NUMBER FORMATTING
//
//    System.Text.Json emits the shortest round-trippable representation
//    of a floating-point value:
//        - a whole-number double (1.0) serialises as `1`;
//        - an exponent value (1e-7) serialises as `1E-07`.
//
//    Python and C++ emit `1.0` and `1e-07` respectively. The differences
//    are cosmetic: the JSON specification treats the two forms as
//    equivalent, and every parser (including the ones in the other
//    bindings) reads them as the same numeric value.
//
//    The only case where the byte-level difference matters is a
//    golden-file comparison of raw JSON text. Cross-language tests
//    should compare numeric values after parsing, not bytes before
//    parsing.
//
// ----------------------------------------------------------------------------
// {!!!!!  INVALID UTF-8 IN A STRING VALUE  !!!!!}
// ----------------------------------------------------------------------------
// System.Text.Json with the encoder below throws on a string value that
// contains an unpaired surrogate (a UTF-16 code unit that cannot be
// encoded to UTF-8). This mirrors the strict behaviour of the Python
// `json.dumps` default and is the recommended behaviour for a producer:
// a payload containing a lone surrogate is a caller bug, and failing
// fast is better than silently emitting U+FFFD.
//
// The LingoFuse bridge (.NET-to-.NET or cross-language) is expected to
// consume valid UTF-8 JSON; invalid inputs are a producer error.
// ============================================================================

/// <summary>
/// Canonical JSON serialisation policy for the LingoFuse C# binding.
/// </summary>
public static class JsonPolicy
{
    /// <summary>
    /// Default serialiser options matching the toolchain-wide contract.
    /// Property names are emitted verbatim (PascalCase for C# types);
    /// use <see cref="JsonPropertyNameAttribute"/> to override per
    /// property when interoperating with peers that expect a different
    /// naming convention.
    /// </summary>
    public static readonly JsonSerializerOptions Options = CreateDefault();

    /// <summary>
    /// Opt-in serialiser options that apply a snake_case naming policy
    /// globally. Use this only when producing a payload that will be
    /// consumed exclusively by a peer that expects snake_case keys;
    /// the default <see cref="Options"/> is the correct choice for
    /// most cross-language work, because snake_case mapping is usually
    /// a per-property decision.
    /// </summary>
    /// <remarks>
    /// The underlying <see cref="JsonSerializerOptions"/> instance is
    /// separate from <see cref="Options"/>; caching and thread safety
    /// follow the same rules as any other options instance.
    /// </remarks>
    public static readonly JsonSerializerOptions OptionsSnakeCase =
        CreateSnakeCase();

    /// <summary>
    /// Serialises <paramref name="value"/> to a compact UTF-8 JSON
    /// string without ASCII escaping.
    /// </summary>
    /// <param name="value">
    /// The object to serialise. A <c>null</c> value produces the JSON
    /// literal <c>null</c>.
    /// </param>
    /// <returns>The compact JSON text.</returns>
    /// <exception cref="LingoFuseException">
    /// Thrown when serialisation fails.
    /// </exception>
    public static string Dumps(object? value)
    {
        try
        {
            return JsonSerializer.Serialize(value, Options);
        }
        catch (Exception ex) when (ex is not LingoFuseException)
        {
            string typeName = value?.GetType().FullName ?? "null";
            throw new LingoFuseException(
                $"JSON serialisation failed for type '{typeName}'.", ex);
        }
    }

    /// <summary>
    /// Deserialises a UTF-8 JSON string into an instance of
    /// <typeparamref name="T"/>.
    /// </summary>
    /// <exception cref="ArgumentNullException">
    /// Thrown when <paramref name="json"/> is null.
    /// </exception>
    /// <exception cref="LingoFuseException">
    /// Thrown when the payload is not valid JSON, or when it cannot be
    /// materialised as <typeparamref name="T"/>.
    /// </exception>
    public static T Loads<T>(string json)
    {
        if (json is null)
        {
            throw new ArgumentNullException(nameof(json));
        }

        try
        {
            T? result = JsonSerializer.Deserialize<T>(json, Options);
            if (result is null && default(T) is not null)
            {
                throw new LingoFuseException(
                    $"JSON payload deserialised to null but T={typeof(T).FullName} is non-nullable.");
            }
            return result!;
        }
        catch (JsonException ex)
        {
            throw new LingoFuseException(
                $"Invalid JSON payload: {ex.Message}", ex);
        }
    }

    /// <summary>
    /// Attempts to deserialise a UTF-8 JSON string without throwing on
    /// malformed input.
    /// </summary>
    /// <param name="json">
    /// The payload. A null or empty string yields false.
    /// </param>
    /// <param name="value">
    /// On success, receives the deserialised value. On failure, receives
    /// <c>default</c>.
    /// </param>
    /// <returns>true on success, false on malformed or empty input.</returns>
    public static bool TryLoads<T>(string? json, out T? value)
    {
        value = default;
        if (string.IsNullOrEmpty(json))
        {
            return false;
        }

        try
        {
            value = JsonSerializer.Deserialize<T>(json, Options);
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    /// <summary>
    /// Builds the default <see cref="JsonSerializerOptions"/> instance:
    /// compact output, literal UTF-8 for non-ASCII characters, no
    /// property name transformation.
    /// </summary>
    private static JsonSerializerOptions CreateDefault()
    {
        var options = new JsonSerializerOptions
        {
            WriteIndented = false,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
            PropertyNameCaseInsensitive = false,
            DefaultIgnoreCondition = JsonIgnoreCondition.Never,
            NumberHandling = JsonNumberHandling.Strict,
        };

        return options;
    }

    /// <summary>
    /// Builds the opt-in snake_case <see cref="JsonSerializerOptions"/>
    /// instance.
    /// </summary>
    /// <remarks>
    /// Uses <c>JsonNamingPolicy.SnakeCaseLower</c> when available
    /// (.NET 8+). Older runtimes fall back to a null naming policy, in
    /// which case <see cref="OptionsSnakeCase"/> behaves identically to
    /// <see cref="Options"/>. Callers that require snake_case on older
    /// runtimes should set <see cref="JsonPropertyNameAttribute"/>
    /// explicitly on each property.
    /// </remarks>
    private static JsonSerializerOptions CreateSnakeCase()
    {
        var options = CreateDefault();
        options.PropertyNamingPolicy = SnakeCaseLowerOrNull();
        return options;
    }

    /// <summary>
    /// Returns <c>JsonNamingPolicy.SnakeCaseLower</c> when the runtime
    /// provides it, and null otherwise.
    /// </summary>
    private static JsonNamingPolicy? SnakeCaseLowerOrNull()
    {
        try
        {
            // JsonNamingPolicy.SnakeCaseLower exists on .NET 8+.
            // Reflecting keeps the assembly loadable on older runtimes.
            var property = typeof(JsonNamingPolicy).GetProperty(
                "SnakeCaseLower",
                System.Reflection.BindingFlags.Public |
                System.Reflection.BindingFlags.Static);
            return property?.GetValue(null) as JsonNamingPolicy;
        }
        catch
        {
            return null;
        }
    }
}