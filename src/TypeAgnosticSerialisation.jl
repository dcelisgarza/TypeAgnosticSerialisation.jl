# TypeAgnosticSerialisation — type-tagged (de)serialisation of arbitrary Julia values.
#
# Goal: serialise a Julia value to a portable document (JSON, YAML, TOML, MessagePack)
# and reconstruct it later *without* knowing its type up front. The document carries
# enough type metadata to rebuild the exact
# concrete type tree.
#
# Design decisions (from the design conversation):
#
#   * Two reconstruction modes (they differ only on the DECODE side — encoding is
#     identical). Both encode the *full concrete type including its type parameters*
#     (recursively), because the exact `DataType` is needed either way:
#       - VALIDATED (`from_json`, the default): rebuild each struct through its own
#         constructor, so all `@argcheck` / inner-constructor validation runs. Requires
#         a constructor that accepts the fields — positional in declaration order (what
#         `@concrete` and Base types like `Day`/`TwicePrecision` use) or keyword by
#         field name.
#       - DIRECT (`from_json_direct`): build each struct with Julia's own `new` (via
#         `Expr(:new)` in a generated function). Works for *any* struct with no
#         constructor at all; `new` type-checks and converts each field against its
#         declared type (a mismatch throws — it can never corrupt memory), but runs no
#         user validation. Use it for JSON you produced and trust, or for types whose
#         constructor cannot be replayed from its fields.
#
#   * Why not `StructUtils`? `StructUtils.make` also reconstructs *through* the type's
#     constructor (verified: it runs the same `@argcheck`), so it is the VALIDATED mode,
#     not a third option — and it targets the parameterised type `T{params}(…)`, which
#     `@concrete`'s base-name constructors don't provide, so it fails here out of the
#     box. Plain `Base` reflection (calling `T.name.wrapper(…)`) handles that. The
#     `encode`/`decode` core is text-agnostic — swap the JSON layer freely.
#
#   * Type resolution is gated by a **module allowlist**. A `__type__` tag can only
#     name a type reachable from an allowed module; anything else errors. There is no
#     `eval` of strings from the JSON. `Base` and `Core` are always allowed (they hold
#     the primitives — `Float64`, `Symbol`, `Array`, `Dict`, ...); the caller adds the
#     modules that define their own types, e.g. `PortfolioOptimisers`, `StatsBase`.
#
# Layering:
#   encode(x, ctx)              :: value  -> plain tree (Dict/Vector/scalars) [no deps]
#   decode(tree, ctx)           :: tree   -> value                           [no deps]
#   to_<fmt>(x; modules)        :: value  -> String/bytes                    [extension]
#   from_<fmt>(data; modules)   :: data   -> value  (validated, default)     [extension]
#   from_<fmt>_direct(data; …)  :: data   -> value  (direct `new`, no valid.)[extension]
#
# The package itself carries only the tree. Each format (JSON, YAML, TOML, MessagePack)
# is a package extension in `ext/` that loads with its backend package; see formats.jl.
#
# Reserved tree keys: "__type__", "__value__" (tagged envelope); "type"/"value"
# (type-parameter wrappers); "union", "where"/"body", "typevar", "vararg"/"count"
# (non-DataType type descriptors); "size"/"data" (arrays); "pairs" (dicts);
# "names"/"values" (named tuples). A struct field literally named "__type__" would
# collide — documented limitation.

module TypeAgnosticSerialisation

export SerdeContext, encode, decode
export to_json, from_json, from_json_direct
export to_yaml, from_yaml, from_yaml_direct
export to_toml, from_toml, from_toml_direct
export to_msgpack, from_msgpack, from_msgpack_direct

# ---------------------------------------------------------------------------
# Context: the module allowlist for type resolution.
# ---------------------------------------------------------------------------

"""
    SerdeContext(modules; opaque = (), validate = false)
    SerdeContext(single_module::Module; opaque = (), validate = false)
    SerdeContext(; modules = (), opaque = (), validate = false)

The state threaded through every [`encode`](@ref)/[`decode`](@ref) call. It holds three
things:

  - `modules`: the **allowlist** used to resolve `__type__` tags back to concrete types. A
    tag may only name a type reachable from one of these modules; anything else errors.
    `Base` and `Core` are always added automatically (they hold the primitives —
    `Float64`, `Symbol`, `Array`, `Dict`, …), so you only pass the modules that define
    *your own* types. A single `Module` is accepted directly, or any iterable of modules.
  - `opaque`: a collection of types that are **not** serialised structurally. A value
    whose type is (a subtype of) one of these is replaced by a placeholder on encode and
    rebuilt with its no-argument constructor `T()` on decode. Use it for live, non-data
    objects (open files, solver models, …) you want to skip while still round-tripping the
    surrounding data.
  - `validate`: chooses the decode strategy. `true` rebuilds each struct through its own
    constructor (running all validation); `false` builds directly with Julia's `new`
    (no validation). See [`from_json`](@ref) and [`from_json_direct`](@ref).

You rarely build one by hand — [`to_json`](@ref), [`from_json`](@ref) and
[`from_json_direct`](@ref) construct it for you from the same keyword arguments.
"""
struct SerdeContext
    modules::Dict{String,Module}   # string(module) => Module
    opaque::Vector{Any}            # types serialised as a placeholder, rebuilt via T()
    validate::Bool                 # decode: true = via constructor; false = direct `new`
end

function SerdeContext(mods; opaque = (), validate::Bool = false)
    d = Dict{String,Module}()
    for m in (Base, Core, mods...)
        d[string(m)] = m
    end
    return SerdeContext(d, collect(Any, opaque), validate)
end
# A single module is the common case; accept it without asking the caller to wrap it in a
# one-tuple (`modules = MyPkg` rather than `modules = (MyPkg,)`).
function SerdeContext(m::Module; opaque = (), validate::Bool = false)
    return SerdeContext((m,); opaque = opaque, validate = validate)
end
function SerdeContext(; modules = (), opaque = (), validate::Bool = false)
    return SerdeContext(modules; opaque = opaque, validate = validate)
end

# A type marked opaque (or a subtype of one) is not serialised structurally; it is
# replaced by a placeholder and rebuilt with its no-argument constructor on decode.
# Use this for live, non-data objects (e.g. `JuMP.Model`) that you want to skip while
# still round-tripping the surrounding data — the reconstructed value is a fresh `T()`.
_is_opaque(@nospecialize(T), ctx::SerdeContext) = any(OT -> T <: OT, ctx.opaque)

function _construct_opaque(@nospecialize(T))
    try
        return T()
    catch
        error(
            "TypeAgnosticSerialisation: opaque type $(T) has no no-argument constructor; " *
            "it cannot be rebuilt on decode.",
        )
    end
end

# ---------------------------------------------------------------------------
# Type descriptors: serialise a type (with parameters) to a plain tree, and resolve one
# back — through the allowlist only.
#
# A descriptor is one of these dicts:
#
#   {"name", "module", "params"}          a DataType, or a bare UnionAll wrapper (`Vector`)
#   {"union": [desc, …]}                  a Union (`Union{Missing,Float64}`)
#   {"where": {var,lb,ub}, "body": desc}  a general UnionAll (`Vector{<:Real}`)
#   {"typevar": name}                     a variable bound by an enclosing "where"
#   {"vararg": desc, "count": param}      a `Vararg{T,N}` (no "count" for `Vararg{T}`)
#
# The non-DataType forms let an array (or a dict, or any type parameter) carry an
# abstract element type that is not a plain abstract DataType: `Vector{Vector}`,
# `Vector{Union{Nothing,Int}}`, `Vector{Vector{<:Real}}`, `Vector{Tuple}`, ….
#
# `env` is the stack of TypeVars bound by the enclosing "where" descriptors, innermost
# last. A "typevar" reference resolves to the innermost binding with that name.
# ---------------------------------------------------------------------------

# Anything `_type_desc` can describe, i.e. what can sit in a parameter list as a type.
_is_typeish(@nospecialize(p)) = p isa Type || p isa TypeVar || p isa Core.TypeofVararg

# A type parameter is either type-like (Type, TypeVar, Vararg) or a bits value
# (Int, Symbol, Bool, ...).
function _param_desc(@nospecialize(p), ctx::SerdeContext, env::Vector{TypeVar} = TypeVar[])
    if _is_typeish(p)
        return Dict{String,Any}("type" => _type_desc(p, ctx, env))
    else
        # A value used as a type parameter; self-describe it fully.
        return Dict{String,Any}("value" => encode(p, Any, ctx))
    end
end

# A bare UnionAll wrapper (`Vector`, `Circle`) is the binding of its own name in its module.
function _is_bare_wrapper(@nospecialize(T::UnionAll))
    m, n = parentmodule(T), nameof(T)
    return isdefined(m, n) && getfield(m, n) === T
end

function _type_desc(@nospecialize(T), ctx::SerdeContext, env::Vector{TypeVar} = TypeVar[])
    if T === Union{}
        return Dict{String,Any}("name" => "Bottom", "module" => "Core", "params" => Any[])
    elseif T isa TypeVar
        # The innermost binding with this name must be this very TypeVar; otherwise the
        # variable is free, or an outer one shadowed by a namesake, and a name alone
        # cannot say which binding it refers to.
        idx = findlast(tv -> tv.name === T.name, env)
        if idx === nothing || env[idx] !== T
            error(
                "TypeAgnosticSerialisation: type variable $(T) is free or shadowed by an " *
                "inner variable of the same name; it cannot be serialised by name.",
            )
        end
        return Dict{String,Any}("typevar" => String(T.name))
    elseif T isa Core.TypeofVararg
        d = Dict{String,Any}("vararg" => _type_desc(isdefined(T, :T) ? T.T : Any, ctx, env))
        if isdefined(T, :N)
            d["count"] = _param_desc(T.N, ctx, env)
        end
        return d
    elseif T isa Union
        return Dict{String,Any}(
            "union" => Any[_type_desc(U, ctx, env) for U in Base.uniontypes(T)],
        )
    elseif T isa UnionAll
        if _is_bare_wrapper(T)
            # Compact, readable form; resolves back through the allowlist by name.
            return Dict{String,Any}(
                "name" => string(nameof(T)),
                "module" => string(parentmodule(T)),
                "params" => Any[],
            )
        end
        tv = T.var
        # The bounds are in the scope of the enclosing variables only, not of `tv`.
        var = Dict{String,Any}(
            "var" => String(tv.name),
            "lb" => _type_desc(tv.lb, ctx, env),
            "ub" => _type_desc(tv.ub, ctx, env),
        )
        push!(env, tv)
        try
            return Dict{String,Any}("where" => var, "body" => _type_desc(T.body, ctx, env))
        finally
            pop!(env)
        end
    elseif T isa DataType
        return Dict{String,Any}(
            "name" => string(nameof(T)),
            "module" => string(parentmodule(T)),
            "params" => Any[_param_desc(p, ctx, env) for p in T.parameters],
        )
    else
        error(
            "TypeAgnosticSerialisation: unsupported type parameter $(T)::$(typeof(T)). " *
            "Add a rule in _type_desc/_resolve_type if you need it.",
        )
    end
end

function _lookup_module(modname::AbstractString, ctx::SerdeContext)
    if haskey(ctx.modules, modname)
        return ctx.modules[modname]
    end
    # Allow nested modules (e.g. "Base.MPFR", "Base.GMP") whose root is allowlisted:
    # trusting a module implies trusting the submodules it ships with.
    parts = split(modname, '.')
    if length(parts) > 1 && haskey(ctx.modules, parts[1])
        m = ctx.modules[parts[1]]
        for p in parts[2:end]
            sym = Symbol(p)
            if !(isdefined(m, sym) && getfield(m, sym) isa Module)
                error(
                    "TypeAgnosticSerialisation: module $(modname) is not in the allowlist.",
                )
            end
            m = getfield(m, sym)
        end
        return m
    end
    return error(
        "TypeAgnosticSerialisation: module $(modname) is not in the allowlist. " *
        "Pass it via SerdeContext(modules = (…, $(modname), …)).",
    )
end

function _resolve_param(p, ctx::SerdeContext, env::Vector{TypeVar} = TypeVar[])
    if haskey(p, "type")
        return _resolve_type(p["type"], ctx, env)
    else
        return decode(p["value"], Any, ctx)
    end
end

function _resolve_type(desc, ctx::SerdeContext, env::Vector{TypeVar} = TypeVar[])
    if haskey(desc, "typevar")
        name = Symbol(desc["typevar"])
        idx = findlast(tv -> tv.name === name, env)
        if idx === nothing
            error("TypeAgnosticSerialisation: type variable $(name) is not bound.")
        end
        return env[idx]
    elseif haskey(desc, "vararg")
        T = _resolve_type(desc["vararg"], ctx, env)
        if haskey(desc, "count")
            return Vararg{T,_resolve_param(desc["count"], ctx, env)}
        else
            return Vararg{T}
        end
    elseif haskey(desc, "union")
        return Union{Any[_resolve_type(d, ctx, env) for d in desc["union"]]...}
    elseif haskey(desc, "where")
        var = desc["where"]
        lb = _resolve_type(var["lb"], ctx, env)
        ub = _resolve_type(var["ub"], ctx, env)
        tv = TypeVar(Symbol(var["var"]), lb, ub)
        push!(env, tv)
        body = try
            _resolve_type(desc["body"], ctx, env)
        finally
            pop!(env)
        end
        return UnionAll(tv, body)
    end
    if desc["name"] == "Bottom"
        return Union{}
    end
    mod = _lookup_module(desc["module"], ctx)
    sym = Symbol(desc["name"])
    if !(isdefined(mod, sym))
        error(
            "TypeAgnosticSerialisation: $(desc["module"]).$(desc["name"]) is not defined.",
        )
    end
    base = getfield(mod, sym)
    if !(base isa Type)
        error("TypeAgnosticSerialisation: $(desc["module"]).$(desc["name"]) is not a type.")
    end
    params = Any[_resolve_param(p, ctx, env) for p in desc["params"]]
    if !isempty(params)
        return Core.apply_type(base, params...)
    else
        # Zero params: a leaf DataType (Symbol, Int64, Nothing) or a bare UnionAll
        # (Newton, Vector) resolves to `base` as-is — `apply_type` would error on
        # leaves. The one exception is the empty tuple type, whose `getfield` result
        # is the *abstract* `Tuple`, not the concrete `Tuple{}`. (The abstract `Tuple`
        # is `Tuple{Vararg{Any}}`, so it always carries its Vararg parameter.)
        return base === Tuple ? Tuple{} : base
    end
end

# ---------------------------------------------------------------------------
# Struct reconstruction — two strategies (selected by `ctx.validate`).
#
#   * _newbuild (DIRECT): build the struct field-by-field with Julia's own `new`, via
#     `Expr(:new)` in a generated function — the same primitive a constructor's
#     `new(...)` compiles to. Works for *any* struct with no constructor required. `new`
#     type-checks and converts each field against its declared type (a mismatch throws,
#     never corrupts memory), but runs no user validation. Not memory-unsafe — just
#     unvalidated.
#
#   * _construct_safe (VALIDATED): call the type's own constructor so all validation
#     runs — positional in declaration order first (the canonical form for `@concrete`
#     inner ctors and Base types), keyword-by-field-name as a fallback. Fails loudly on
#     types whose constructor cannot be replayed from its fields.
# ---------------------------------------------------------------------------

# Generated: `new(T, fields[1], …, fields[n])`. `T` here is the static parameter.
@generated function _new_impl(::Type{T}, fields) where {T}
    if !isconcretetype(T)
        return :(error("TypeAgnosticSerialisation: cannot build non-concrete type $(T)."))
    end
    return Expr(:new, :T, (:(fields[$i]) for i = 1:fieldcount(T))...)
end

function _newbuild(@nospecialize(T::DataType), fields::Vector{Any})
    n = fieldcount(T)
    if !(n == length(fields))
        error("TypeAgnosticSerialisation: $(T) expects $(n) fields, got $(length(fields)).")
    end
    return _new_impl(T, fields)
end

function _construct_safe(@nospecialize(T::DataType), fields::Vector{Any})
    base = T.name.wrapper   # unparameterised type: its ctor rederives the parameters
    # Positional in declaration order is the canonical constructor for `@concrete`
    # structs (its validating inner ctor) and for most Base types (Day, TwicePrecision,
    # Complex, Rational). Fall back to keyword-by-field-name for types that only expose
    # a `T(; field=…)` constructor. Both run the type's own validation.
    try
        return base(fields...)
    catch e_pos
        try
            return base(; (fieldname(T, i) => fields[i] for i = 1:fieldcount(T))...)
        catch e_kw
            flist = join(fieldnames(T), ", ")
            error(
                "TypeAgnosticSerialisation (validate): could not reconstruct $(T) through a " *
                "constructor. Tried `$(nameof(T))(fields...)` → " *
                "$(sprint(showerror, e_pos)); and `$(nameof(T))(; $(flist)...)` → " *
                "$(sprint(showerror, e_kw)). Mark the type opaque or use " *
                "`from_json_direct`.",
            )
        end
    end
end

# ---------------------------------------------------------------------------
# ENCODE: value -> plain tree.
#
# encode(v, H, ctx): H is the statically-known type hint (a field's declared type,
# or an array's eltype). If H is concrete, the reader can already infer the type, so
# we emit the bare structural payload. Otherwise we wrap it in a self-describing
# {"__type__": …, "__value__": …} envelope. Top level uses H = Any (always tagged).
# ---------------------------------------------------------------------------

"""
    encode(value, ctx::SerdeContext) -> plain tree
    encode(value, hint, ctx::SerdeContext) -> plain tree

Lower a Julia `value` to a **plain tree** — nested `Dict{String,Any}`, `Vector{Any}` and
scalars that any JSON/TOML/… layer can render. This is the dependency-free core of the
package; [`to_json`](@ref) is just `encode` followed by `JSON.json`.

`hint` is the statically-known type at this position (a field's declared type, an array's
element type, …). When the hint is already concrete the reader can infer the type, so the
bare structural payload is emitted; otherwise the value is wrapped in a self-describing
`{"__type__": …, "__value__": …}` envelope carrying the full concrete type (including type
parameters). The two-argument form uses `hint = Any`, so the top level is always tagged.

Invert with [`decode`](@ref).

```jldoctest
julia> ctx = SerdeContext();

julia> tree = encode((1, "two", :three), ctx);

julia> decode(tree, ctx)
(1, "two", :three)
```
"""
encode(v, ctx::SerdeContext) = encode(v, Any, ctx)

function encode(@nospecialize(v), @nospecialize(H), ctx::SerdeContext)
    T = typeof(v)
    body = _encode_plain(v, T, ctx)
    if isconcretetype(H)          # reader can infer T from the hint -> no tag needed
        return body
    else
        return Dict{String,Any}("__type__" => _type_desc(T, ctx), "__value__" => body)
    end
end

# Structural payload, assuming the reader will know the concrete type T.
function _encode_plain(@nospecialize(v), @nospecialize(T), ctx::SerdeContext)
    if _is_opaque(T, ctx)
        # A non-data value the caller chose to skip; the concrete type is recovered
        # from the hint/tag, so the placeholder itself is empty.
        return Dict{String,Any}("__opaque__" => true)
    elseif v isa Type
        # A value that *is* a type (e.g. a field holding `Newton`): serialise it as a
        # type reference and stop — never descend into DataType/UnionAll internals.
        return _type_desc(v, ctx)
    elseif T <: Base.Enum
        # `@enum` value: store the member name (stable across reordering, human
        # readable); reconstructed by matching against `instances(T)` on decode.
        return String(Symbol(v))
    elseif T === Bool
        # Must precede the Integer branch (Bool <: Integer) so a Bool emits a real JSON
        # boolean rather than being stringified through _encode_number.
        return v
    elseif T <: Integer || T <: AbstractFloat
        return _encode_number(v)
    elseif T <: AbstractString
        return String(v)
    elseif T === Symbol
        return String(v)
    elseif T <: AbstractChar
        return string(v)
    elseif T <: Array
        # Only genuine dense Arrays get the flat size+data payload. Other
        # AbstractArray subtypes (StatsBase weights, ranges, Adjoint, sparse, …) are
        # wrapper structs with extra fields, so they fall through to the struct
        # branch and reconstruct field-for-field.
        # `vec` flattens column-major; a bare comprehension would preserve the array
        # shape and defeat the reshape on decode.
        return Dict{String,Any}(
            "size" => collect(size(v)),
            "data" => Any[encode(el, eltype(T), ctx) for el in vec(v)],
        )
    elseif T <: AbstractDict
        return Dict{String,Any}(
            "pairs" => Any[
                Any[encode(k, keytype(T), ctx), encode(val, valtype(T), ctx)] for
                (k, val) in v
            ],
        )
    elseif T <: Tuple
        return Any[encode(v[i], fieldtype(T, i), ctx) for i = 1:fieldcount(T)]
    elseif T <: NamedTuple
        return Dict{String,Any}(
            "names" => Any[String(n) for n in fieldnames(T)],
            "values" =>
                Any[encode(getfield(v, i), fieldtype(T, i), ctx) for i = 1:fieldcount(T)],
        )
    elseif isstructtype(T)
        # Covers ordinary structs, singletons (0 fields -> {}), Nothing, Missing,
        # Rational, Complex, and any user @concrete struct.
        d = Dict{String,Any}()
        for i = 1:fieldcount(T)
            if !(isdefined(v, i))
                error(
                    "TypeAgnosticSerialisation: field $(fieldname(T, i)) of $(T) is undefined; " *
                    "#undef fields are not supported.",
                )
            end
            d[String(fieldname(T, i))] = encode(getfield(v, i), fieldtype(T, i), ctx)
        end
        return d
    else
        error("TypeAgnosticSerialisation: don't know how to encode a value of type $(T).")
    end
end

# JSON has one ambiguous number type; keep exactness by stringifying anything that
# is not safely representable as a bare JSON number.
function _encode_number(@nospecialize(v))
    if v isa AbstractFloat && !isfinite(v)
        return isnan(v) ? "__nan__" : (v > 0 ? "__inf__" : "__ninf__")
    elseif v isa Union{Int8,Int16,Int32,Int64,UInt8,UInt16,UInt32,Float16,Float32,Float64}
        return v
    else
        return string(v)   # BigInt, Int128, BigFloat, … -> parsed back on decode
    end
end

# ---------------------------------------------------------------------------
# DECODE: plain tree -> value. Mirror of encode; H is the same hint.
# ---------------------------------------------------------------------------

"""
    decode(tree, ctx::SerdeContext) -> value
    decode(tree, hint, ctx::SerdeContext) -> value

Reconstruct a Julia value from a **plain tree** produced by [`encode`](@ref) — the exact
inverse. `hint` is the same statically-known type used on the encode side: a tagged
`{"__type__": …}` envelope carries its own type, while an untagged payload is decoded
against the (necessarily concrete) `hint`. The two-argument form uses `hint = Any`.

Every type named by a `__type__` tag must be reachable from the context's module
allowlist; there is no `eval` of strings from the tree. `ctx.validate` selects how structs
are rebuilt — through their constructor (validated) or via `new` (direct). See
[`SerdeContext`](@ref).

```jldoctest
julia> ctx = SerdeContext();

julia> decode(encode([1.0, 2.0, 3.0], ctx), ctx)
3-element Vector{Float64}:
 1.0
 2.0
 3.0
```
"""
decode(tree, ctx::SerdeContext) = decode(tree, Any, ctx)

function decode(tree, @nospecialize(H), ctx::SerdeContext)
    if tree isa AbstractDict && haskey(tree, "__type__")
        T = _resolve_type(tree["__type__"], ctx)
        return _decode_plain(tree["__value__"], T, ctx)
    else
        if !(isconcretetype(H))
            error(
                "TypeAgnosticSerialisation: expected a tagged value but got an untagged one with " *
                "abstract hint $(H).",
            )
        end
        return _decode_plain(tree, H, ctx)
    end
end

function _decode_plain(payload, @nospecialize(T), ctx::SerdeContext)
    if _is_opaque(T, ctx)
        return _construct_opaque(T)
    elseif T <: Type
        # The value itself is a type; payload is a type reference.
        return _resolve_type(payload, ctx)
    elseif T <: Base.Enum
        sym = Symbol(payload)
        idx = findfirst(e -> Symbol(e) == sym, instances(T))
        if idx === nothing
            error("TypeAgnosticSerialisation: $(sym) is not a member of $(T).")
        end
        return instances(T)[idx]
    elseif T === Bool
        # Mirror of the encode side: match Bool before the Integer branch.
        return convert(Bool, payload)
    elseif T <: Integer || T <: AbstractFloat
        return _decode_number(T, payload)
    elseif T <: AbstractString
        return convert(T, String(payload))
    elseif T === Symbol
        return Symbol(payload)
    elseif T <: AbstractChar
        return T(only(String(payload)))
    elseif T <: Array
        el = eltype(T)
        data = Any[decode(x, el, ctx) for x in payload["data"]]
        sz = Tuple(Int.(payload["size"]))
        flat = isempty(data) ? Array{el}(undef, 0) : convert(Vector{el}, data)
        return convert(T, reshape(flat, sz))
    elseif T <: AbstractDict
        K, V = keytype(T), valtype(T)
        d = T()
        for kv in payload["pairs"]
            d[decode(kv[1], K, ctx)] = decode(kv[2], V, ctx)
        end
        return d
    elseif T <: Tuple
        return convert(
            T,
            Tuple(decode(payload[i], fieldtype(T, i), ctx) for i = 1:fieldcount(T)),
        )
    elseif T <: NamedTuple
        vals = Tuple(
            decode(payload["values"][i], fieldtype(T, i), ctx) for i = 1:fieldcount(T)
        )
        return T(vals)
    elseif isstructtype(T)
        fields = Any[
            decode(payload[String(fieldname(T, i))], fieldtype(T, i), ctx) for
            i = 1:fieldcount(T)
        ]
        return ctx.validate ? _construct_safe(T, fields) : _newbuild(T, fields)
    else
        error("TypeAgnosticSerialisation: don't know how to decode into type $(T).")
    end
end

function _decode_number(@nospecialize(T), payload)
    if payload isa AbstractString
        if payload == "__nan__"
            return T(NaN)
        end
        if payload == "__inf__"
            return T(Inf)
        end
        if payload == "__ninf__"
            return T(-Inf)
        end
        return parse(T, payload)
    else
        return convert(T, payload)
    end
end

include("formats.jl")

end # module
