#pragma once
// Include boundary for the JSON library: other files include this header,
// never vendor/json.hpp directly.
#include "../vendor/json.hpp"

namespace fsqlmcp
{
    using Json = nlohmann::json;
    using OrderedJson = nlohmann::ordered_json;

    // JSON-Schema-ish primitive kinds used by ToolParam::type (tool_registry.h).
    enum class JsonType
    {
        String, Integer, Number, Boolean, Object, Array, Null
    };

    inline bool jsonTypeMatches( JsonType t, const Json& v )
    {
        switch( t )
        {
            case JsonType::String:  return v.is_string();
            case JsonType::Integer: return v.is_number_integer();
            case JsonType::Number:  return v.is_number();
            case JsonType::Boolean: return v.is_boolean();
            case JsonType::Object:  return v.is_object();
            case JsonType::Array:   return v.is_array();
            case JsonType::Null:    return v.is_null();
        }
        return false;
    }

    inline const char* jsonTypeName( JsonType t )
    {
        switch( t )
        {
            case JsonType::String:  return "string";
            case JsonType::Integer: return "integer";
            case JsonType::Number:  return "number";
            case JsonType::Boolean: return "boolean";
            case JsonType::Object:  return "object";
            case JsonType::Array:   return "array";
            case JsonType::Null:    return "null";
        }
        return "null";
    }
}