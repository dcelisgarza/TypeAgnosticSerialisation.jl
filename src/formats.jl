# ---------------------------------------------------------------------------
# Text / binary layers.
#
# The core above lowers a value to a plain tree and back; it has no dependencies. Every
# concrete format is a pair of hooks implemented by a package extension (see `ext/`):
#
#   _render(::Val{fmt}, tree; kwargs...) :: tree -> String / bytes
#   _parse(::Val{fmt}, data)             :: String / bytes -> tree
#
# The public `to_<fmt>` / `from_<fmt>` / `from_<fmt>_direct` functions live here, so they
# are always defined and documented; until the backend package is loaded they fail with
# a message naming the package to load, rather than a bare `MethodError`.
# ---------------------------------------------------------------------------

# Format key => the package whose extension implements it.
const _BACKENDS = Dict{Symbol,String}(
    :json => "JSON",
    :yaml => "YAML",
    :toml => "TOML",
    :msgpack => "MsgPack",
)

function _missing_backend(F::Symbol)
    pkg = _BACKENDS[F]
    return error(
        "TypeAgnosticSerialisation: the $(F) format needs the $(pkg) package. " *
        "Load it first with `import $(pkg)` (or `using $(pkg)`).",
    )
end

# Fallbacks; each extension adds the more specific `Val{:fmt}` methods.
_render(::Val{F}, tree; kwargs...) where {F} = _missing_backend(F)
_parse(::Val{F}, data) where {F} = _missing_backend(F)

# `functions` gates the decode only. The encoder accepts it too, so that one set of keyword
# arguments can serve both directions.
function _serialise(fmt::Val, x; modules = (), opaque = (), functions = (), kwargs...)
    return _render(fmt, encode(x, SerdeContext(modules; opaque = opaque)); kwargs...)
end

function _deserialise(
    fmt::Val,
    data,
    validate::Bool;
    modules = (),
    opaque = (),
    functions = (),
)
    tree = _parse(fmt, data)
    ctx = SerdeContext(modules; opaque = opaque, functions = functions, validate = validate)
    return decode(tree, ctx)
end

# ---------------------------------------------------------------------------
# JSON  (extension: TypeAgnosticSerialisationJSONExt, needs `import JSON`)
# ---------------------------------------------------------------------------

"""
    to_json(value; modules = (), opaque = (), kwargs...) -> String

Serialise `value` to a JSON string that carries enough type metadata to rebuild the exact
concrete type later — without knowing the type up front. Equivalent to `encode` followed
by `JSON.json`; any extra `kwargs` (e.g. `pretty = 2`) are forwarded to `JSON.json`.

Needs the JSON package: load it with `import JSON` first.

`modules` is the allowlist recorded for the human reader's benefit and used when the
argument list is shared with the loaders — pass the module(s) that define your types (a
bare `Module` is fine). `opaque` lists types to skip structurally (see
[`SerdeContext`](@ref)); encoding a live, non-data value that is *not* marked opaque fails
loudly rather than emitting a broken artifact.

Read back with [`from_json`](@ref) (validated) or [`from_json_direct`](@ref).
"""
to_json(x; kwargs...) = _serialise(Val(:json), x; kwargs...)

"""
    from_json(str; modules = (), opaque = (), functions = ()) -> value

Read a JSON string produced by [`to_json`](@ref) back into a Julia value, **validated**:
every struct is rebuilt through its own constructor, so all inner-constructor /
`@argcheck` invariants run and a tampered or inconsistent document is refused. This is the
recommended, default loader.

It requires a constructor that can be replayed from the fields — positional in declaration
order, or keyword by field name. A type whose constructor cannot be replayed fails loudly;
mark it `opaque` or use [`from_json_direct`](@ref) for those. `modules` is the resolution
allowlist (a bare `Module` is accepted); only types defined in it — plus the plain data
types and containers of `Base`/`Core` — can be named. `functions` lists the named
functions that may decode; the default is empty, so no function decodes. See
[`SerdeContext`](@ref) for the exact rules.

The validation runs the constructors of the listed types on the values that the document
gives. It checks the invariants of your own data; it does **not** make a document from an
untrusted source safe to load. Load only documents that you wrote yourself.

Needs the JSON package: load it with `import JSON` first. See also
[`from_json_direct`](@ref) for the non-validating counterpart.
"""
from_json(str::AbstractString; kwargs...) = _deserialise(Val(:json), str, true; kwargs...)

"""
    from_json_direct(str; modules = (), opaque = (), functions = ()) -> value

Read a JSON string produced by [`to_json`](@ref) back into a Julia value, **directly**:
each struct is built field-by-field with Julia's own `new` (via `Expr(:new)`), bypassing
all constructors. This reconstructs *any* struct — even one with no usable constructor —
and is still type-safe (`new` type-checks and converts every field against its declared
type, so a mismatch throws and can never corrupt memory), but it runs **no** user
validation.

Use it for JSON you produced and trust, or for types whose constructor cannot be replayed
from its fields. When you want invariants enforced on load, use [`from_json`](@ref)
instead. `modules`/`opaque`/`functions` behave exactly as for [`from_json`](@ref).
"""
function from_json_direct(str::AbstractString; kwargs...)
    return _deserialise(Val(:json), str, false; kwargs...)
end

# ---------------------------------------------------------------------------
# YAML  (extension: TypeAgnosticSerialisationYAMLExt, needs `import YAML`)
# ---------------------------------------------------------------------------

"""
    to_yaml(value; modules = (), opaque = ()) -> String

Serialise `value` to a YAML string. The document is the same plain tree that
[`to_json`](@ref) writes, so it carries the same type metadata; all strings are quoted, so
no string can be re-read as a number, boolean, date or `null`.

Needs the YAML package: load it with `import YAML` first. Read back with
[`from_yaml`](@ref) (validated) or [`from_yaml_direct`](@ref). `modules` and `opaque`
behave as for [`to_json`](@ref).
"""
to_yaml(x; kwargs...) = _serialise(Val(:yaml), x; kwargs...)

"""
    from_yaml(str; modules = (), opaque = (), functions = ()) -> value

Read a YAML string produced by [`to_yaml`](@ref) back into a Julia value, **validated**
(every struct is rebuilt through its own constructor) — the YAML counterpart of
[`from_json`](@ref).

A document that uses YAML anchors/aliases is refused: [`to_yaml`](@ref) never writes them,
and an alias lets a tiny document expand into an exponentially large tree. Needs the YAML
package: load it with `import YAML` first.
"""
from_yaml(str::AbstractString; kwargs...) = _deserialise(Val(:yaml), str, true; kwargs...)

"""
    from_yaml_direct(str; modules = (), opaque = (), functions = ()) -> value

Read a YAML string produced by [`to_yaml`](@ref) back into a Julia value, **directly**
(each struct is built with Julia's own `new`, no user validation) — the YAML counterpart of
[`from_json_direct`](@ref).
"""
function from_yaml_direct(str::AbstractString; kwargs...)
    return _deserialise(Val(:yaml), str, false; kwargs...)
end

# ---------------------------------------------------------------------------
# TOML  (extension: TypeAgnosticSerialisationTOMLExt, needs `import TOML`)
# ---------------------------------------------------------------------------

"""
    to_toml(value; modules = (), opaque = (), kwargs...) -> String

Serialise `value` to a TOML string. The top level is always the tagged
`{"__type__": …, "__value__": …}` envelope, so it is always a valid TOML table. Extra
`kwargs` (e.g. `sorted = true`) are forwarded to `TOML.print`.

Needs the TOML standard library: load it with `import TOML` first. Read back with
[`from_toml`](@ref) (validated) or [`from_toml_direct`](@ref). `modules` and `opaque`
behave as for [`to_json`](@ref).
"""
to_toml(x; kwargs...) = _serialise(Val(:toml), x; kwargs...)

"""
    from_toml(str; modules = (), opaque = (), functions = ()) -> value

Read a TOML string produced by [`to_toml`](@ref) back into a Julia value, **validated**
(every struct is rebuilt through its own constructor) — the TOML counterpart of
[`from_json`](@ref). Needs the TOML standard library: load it with `import TOML` first.
"""
from_toml(str::AbstractString; kwargs...) = _deserialise(Val(:toml), str, true; kwargs...)

"""
    from_toml_direct(str; modules = (), opaque = (), functions = ()) -> value

Read a TOML string produced by [`to_toml`](@ref) back into a Julia value, **directly**
(each struct is built with Julia's own `new`, no user validation) — the TOML counterpart of
[`from_json_direct`](@ref).
"""
function from_toml_direct(str::AbstractString; kwargs...)
    return _deserialise(Val(:toml), str, false; kwargs...)
end

# ---------------------------------------------------------------------------
# MessagePack  (extension: TypeAgnosticSerialisationMsgPackExt, needs `import MsgPack`)
# ---------------------------------------------------------------------------

"""
    to_msgpack(value; modules = (), opaque = ()) -> Vector{UInt8}

Serialise `value` to compact MessagePack bytes. The bytes hold the same plain tree that
[`to_json`](@ref) writes, so they carry the same type metadata. MessagePack has no 16-bit
float, so a `Float16` is stored as the (exactly equal) `Float32` and narrowed back on
decode.

Needs the MsgPack package: load it with `import MsgPack` first. Read back with
[`from_msgpack`](@ref) (validated) or [`from_msgpack_direct`](@ref). `modules` and `opaque`
behave as for [`to_json`](@ref).
"""
to_msgpack(x; kwargs...) = _serialise(Val(:msgpack), x; kwargs...)

"""
    from_msgpack(bytes; modules = (), opaque = (), functions = ()) -> value

Read MessagePack bytes produced by [`to_msgpack`](@ref) back into a Julia value,
**validated** (every struct is rebuilt through its own constructor) — the MessagePack
counterpart of [`from_json`](@ref). MessagePack extension values are never deserialised.
Needs the MsgPack package: load it with `import MsgPack` first.
"""
function from_msgpack(bytes::AbstractVector{UInt8}; kwargs...)
    return _deserialise(Val(:msgpack), bytes, true; kwargs...)
end

"""
    from_msgpack_direct(bytes; modules = (), opaque = (), functions = ()) -> value

Read MessagePack bytes produced by [`to_msgpack`](@ref) back into a Julia value,
**directly** (each struct is built with Julia's own `new`, no user validation) — the
MessagePack counterpart of [`from_json_direct`](@ref).
"""
function from_msgpack_direct(bytes::AbstractVector{UInt8}; kwargs...)
    return _deserialise(Val(:msgpack), bytes, false; kwargs...)
end
