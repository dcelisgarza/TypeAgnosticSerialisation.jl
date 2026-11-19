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
#   * A document can outlive a release of a package that changes a type. With
#     `repair = true` (a field of the context), the decode fills a missing field from the
#     keyword constructor, drops an extra key, and keeps the leading part of a parameter
#     list that does not fit. Without it, a missing field and a misfit list are errors.
#     A package can also declare a step for each breaking release (`migrations`, see
#     migrations.jl). The decode applies the declared steps with no `repair` keyword.
#
#   * Type resolution is gated by a **module allowlist**. A `__type__` tag can only
#     name a type defined in an allowed module; anything else errors. There is no
#     `eval` of strings from the JSON. Of `Base` and `Core`, only the plain data types
#     and containers resolve (`Float64`, `Symbol`, `Array`, `Dict`, ...) unless the
#     caller lists the module; the caller adds the modules that define their own types,
#     e.g. `PortfolioOptimisers`, `StatsBase`. A named function decodes only if the
#     caller lists it in `functions`, and a dict decodes only into `Dict`, `IdDict` or a
#     dict type that the caller lists in `dicts`.
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
# "names"/"values" (named tuples); "__meta__" (the version record beside the top-level
# envelope, see `encode`). A struct field literally named "__type__" would collide —
# documented limitation.

module TypeAgnosticSerialisation

export SerdeContext, encode, decode, VersionChangeError
export to_json, from_json, from_json_direct
export to_yaml, from_yaml, from_yaml_direct
export to_toml, from_toml, from_toml_direct
export to_msgpack, from_msgpack, from_msgpack_direct
export MigrationStep, RenameType, RenameField, AddField, RemoveField, Migration
export ParameterMigration, @migrations

# The steps that a package declares for each breaking release, and the plan of a decode.
include("migrations.jl")

# ---------------------------------------------------------------------------
# Context: the module allowlist for type resolution.
# ---------------------------------------------------------------------------

"""
    SerdeContext(modules; opaque = (), functions = (), dicts = (), validate = false, repair = false)
    SerdeContext(single_module::Module; opaque = (), functions = (), dicts = (), validate = false, repair = false)
    SerdeContext(; modules = (), opaque = (), functions = (), dicts = (), validate = false, repair = false)

The state threaded through every [`encode`](@ref)/[`decode`](@ref) call. It holds six
things:

  - `modules`: the **allowlist** used to resolve `__type__` tags back to concrete types. A
    tag may only name a type *defined* in one of these modules (or in a submodule of
    one); anything else errors. A single `Module` is accepted directly, or any iterable
    of modules. `Base` and `Core` are **not** trusted as a whole: unless listed, only
    their plain data types and containers resolve — the numbers, `String`, `Symbol`,
    `Char`, `Nothing`, `Missing`, `Array`, `Tuple`, `NamedTuple`, `Pair`, `Dict`,
    `IdDict`, the ranges, `Some`, `Val`, the type objects, and every abstract type.
    Listing `Base` or `Core` in `modules` trusts all of that module.
  - `functions`: the named functions that may decode. A value whose type is a singleton
    subtype of `Function` — a named function such as `sin`, or an anonymous function with
    no captures — decodes only if it is in this list, in both decode modes and from any
    module, listed or not. The default is empty: no function decodes.
  - `dicts`: the dict types, other than `Dict` and `IdDict`, that may decode. Name each
    by its type, such as `OrderedDict`; the name admits every parameterisation of it. The
    type must still be defined in a module of `modules`. The default is empty: a dict
    decodes only into `Dict` or `IdDict`.
  - `opaque`: a collection of types that are **not** serialised structurally. A value
    whose type is (a subtype of) one of these is replaced by a placeholder on encode and
    rebuilt with its no-argument constructor `T()` on decode. Use it for live, non-data
    objects (open files, solver models, …) you want to skip while still round-tripping the
    surrounding data.
  - `validate`: chooses the decode strategy. `true` rebuilds each struct through its own
    constructor (running all validation); `false` builds directly with Julia's `new`
    (no validation). See [`from_json`](@ref) and [`from_json_direct`](@ref).
  - `repair`: lets the decode repair a document that an older release of a package wrote,
    after a change of a type. The default is `false`. See *Repair* below.

# Repair

A struct of the document can differ from the struct type as the package now defines it.
With `repair = false`, a missing field and a parameter list that does not fit are errors
that name the difference. With `repair = true`, the decode repairs each difference below
and logs a warning:

  - A field that the type has and the document does not have. The decode calls the keyword
    constructor of the type with only the fields of the document, so a `Base.@kwdef`
    default fills the rest. If that call fails, the error names the missing fields. This
    repair needs the validated mode: `new` has no defaults.
  - A key of the document that is not a field of the type. The decode drops it, in both
    modes. With `repair = false`, the decode drops it with no warning.
  - A list of type parameters that does not fit the type, because a release added,
    removed or changed the bound of a parameter. The decode keeps the longest leading part
    of the list that still fits. If parameters remain free, the constructor of the type
    finds them from the fields, so this case needs the validated mode. A field whose
    declared type uses a free parameter must have a tagged value in the document.

A field rename is a missing field and an extra key together. The repair cannot see that
the two are the same field, so it fills the new field from its default and drops the old
value. The leading part of a parameter list is a match by position: a release that removes
or moves a parameter at the front shifts the others.

A dict decodes only into `Dict`, `IdDict` or a type of `dicts`, even when `Base` is listed:
the decode calls `T()` and `setindex!` with the keys and values of the document, and another
dict type (such as the type of `ENV`) can act on the system. Name in `dicts` only types
whose `setindex!` only stores data.

You rarely build one by hand — [`to_json`](@ref), [`from_json`](@ref) and
[`from_json_direct`](@ref) construct it for you from the same keyword arguments.

!!! warning

    The allowlists limit what a document can name. They do not make a document from an
    untrusted source safe to load: a listed type or function can still act on the field
    values that the document gives it. Load only documents that you wrote yourself.
"""
struct SerdeContext
    modules::Dict{String,Module}   # string(module) => Module; Base and Core always present
    plain_only::Vector{Module}     # Base/Core when the caller did not list them
    opaque::Vector{Any}            # types serialised as a placeholder, rebuilt via T()
    functions::Vector{Any}         # the singleton functions that may decode
    function_types::Dict{Tuple{String,String},DataType}  # (module, name) => typeof(f)
    dicts::Base.IdSet{Any}         # wrappers of the dict types that may decode
    validate::Bool                 # decode: true = via constructor; false = direct `new`
    repair::Bool                   # decode: repair a document after a change of a type
    # encode: the root modules of the types that the encoder described, keyed by name, for
    # the `"__meta__"` record. Only the private copy that the top-level `encode(v, ctx)`
    # makes holds a dict; a context that the caller builds holds `nothing`, so that a
    # context that many tasks share never changes.
    seen::Union{Nothing,Dict{String,Module}}
    # decode: the declared steps that apply to the document (see migrations.jl). Only the
    # private copy that the two-argument `decode(tree, ctx)` makes holds a plan.
    plan::Union{Nothing,_Plan}
end

# The positional form with `repair` and no `plan`.
function SerdeContext(
    modules,
    plain_only,
    opaque,
    functions,
    function_types,
    dicts::Base.IdSet{Any},
    validate,
    repair::Bool,
    seen,
)
    return SerdeContext(
        modules,
        plain_only,
        opaque,
        functions,
        function_types,
        dicts,
        validate,
        repair,
        seen,
        nothing,
    )
end

# The positional form of v0.4.0, which had no `repair` field.
function SerdeContext(
    modules,
    plain_only,
    opaque,
    functions,
    function_types,
    dicts::Base.IdSet{Any},
    validate,
    seen,
)
    return SerdeContext(
        modules,
        plain_only,
        opaque,
        functions,
        function_types,
        dicts,
        validate,
        false,
        seen,
    )
end

# The positional form of v0.3.1, which had no `seen` field.
function SerdeContext(
    modules,
    plain_only,
    opaque,
    functions,
    function_types,
    dicts::Base.IdSet{Any},
    validate,
)
    return SerdeContext(
        modules,
        plain_only,
        opaque,
        functions,
        function_types,
        dicts,
        validate,
        false,
        nothing,
    )
end

# The positional form of v0.3.0, which had no `dicts` field.
function SerdeContext(modules, plain_only, opaque, functions, function_types, validate)
    dicts = Base.IdSet{Any}(_PLAIN_DICTS)
    return SerdeContext(
        modules,
        plain_only,
        opaque,
        functions,
        function_types,
        dicts,
        validate,
    )
end

function _dict_set(dicts)
    s = Base.IdSet{Any}(_PLAIN_DICTS)
    for D in dicts
        if !(D isa Type && D <: AbstractDict)
            error(
                "TypeAgnosticSerialisation: `dicts` holds $(repr(D)), which is not a " *
                "subtype of `AbstractDict`.",
            )
        end
        push!(s, _wrapper(D))
    end
    return s
end

function SerdeContext(
    mods;
    opaque = (),
    functions = (),
    dicts = (),
    validate::Bool = false,
    repair::Bool = false,
)
    listed = collect(Module, mods)
    d = Dict{String,Module}()
    for m in (Base, Core, listed...)
        d[string(m)] = m
    end
    plain_only = Module[m for m in (Base, Core) if !any(x -> x === m, listed)]
    fs = collect(Any, functions)
    ftypes = Dict{Tuple{String,String},DataType}()
    for f in fs
        F = typeof(f)
        if !(_is_function_type(F))
            error(
                "TypeAgnosticSerialisation: `functions` holds $(repr(f))::$(F), which is " *
                "not a named function (a singleton subtype of `Function`).",
            )
        end
        ftypes[(string(parentmodule(F)), string(nameof(F)))] = F
    end
    ds = _dict_set(dicts)
    return SerdeContext(
        d,
        plain_only,
        collect(Any, opaque),
        fs,
        ftypes,
        ds,
        validate,
        repair,
        nothing,
        nothing,
    )
end
# A single module is the common case; accept it without asking the caller to wrap it in a
# one-tuple (`modules = MyPkg` rather than `modules = (MyPkg,)`).
function SerdeContext(m::Module; kwargs...)
    return SerdeContext((m,); kwargs...)
end
function SerdeContext(; modules = (), kwargs...)
    return SerdeContext(modules; kwargs...)
end

# ---------------------------------------------------------------------------
# Decode gates. A document names the types that it holds, so each name that it uses
# must pass these checks before a value of that type is built.
# ---------------------------------------------------------------------------

# The type of a named function (`typeof(sin)`), or of an anonymous function with no
# captures: a singleton whose one value is the function.
function _is_function_type(@nospecialize(T))
    return T isa DataType && T <: Function && Base.issingletontype(T)
end

function _check_function(@nospecialize(F::DataType), ctx::SerdeContext)
    f = F.instance
    if !any(g -> g === f, ctx.functions)
        error(
            "TypeAgnosticSerialisation: the function $(parentmodule(F)).$(nameof(f)) is " *
            "not in the `functions` allowlist. Pass it via `functions = (…, $(nameof(f)), …)`.",
        )
    end
    return f
end

# The plain data types and containers of Base and Core: a value of one holds data only.
# Matched by the unparameterised wrapper.
const _PLAIN_TYPES = Base.IdSet{Any}(
    Any[
        Any,
        Nothing,
        Missing,
        Bool,
        Int8,
        Int16,
        Int32,
        Int64,
        Int128,
        UInt8,
        UInt16,
        UInt32,
        UInt64,
        UInt128,
        Float16,
        Float32,
        Float64,
        BigInt,
        BigFloat,
        Rational,
        Complex,
        Irrational,
        Char,
        String,
        Symbol,
        Array,
        Tuple,
        NamedTuple,
        Pair,
        Dict,
        IdDict,
        Some,
        Val,
        UnitRange,
        StepRange,
        StepRangeLen,
        LinRange,
        Base.OneTo,
        Base.TwicePrecision,
        DataType,
        UnionAll,
        Union,
        Core.TypeofBottom,
    ],
)

# The dict types that may decode. The decode calls `T()` and `setindex!` on the dict.
const _PLAIN_DICTS = Base.IdSet{Any}(Any[Dict, IdDict])

function _wrapper(@nospecialize(T))
    U = Base.unwrap_unionall(T)
    return U isa DataType ? U.name.wrapper : T
end

# An abstract type has no values of its own, so it is safe as a type parameter.
function _is_abstract(@nospecialize(T))
    U = Base.unwrap_unionall(T)
    return U isa DataType && isabstracttype(U)
end

_is_plain(@nospecialize(T)) = _wrapper(T) in _PLAIN_TYPES || _is_abstract(T)

# The type must be *defined* in an allowlisted module (or a submodule of one), not only be
# reachable by name through one: `using Base: Cmd` in a listed module must not make `Cmd`
# resolve. A type of Base or Core must be plain unless the caller listed that module. The
# walk stops at Base and Core, because `parentmodule(Base) === Main`.
function _check_type(@nospecialize(T), ctx::SerdeContext)
    owner = parentmodule(T)
    m = owner
    while true
        if m === Base || m === Core
            if any(x -> x === m, ctx.plain_only) && !_is_plain(T)
                error(
                    "TypeAgnosticSerialisation: $(owner).$(nameof(T)) is not a plain data " *
                    "type of $(m), so it resolves only if $(m) is in `modules`.",
                )
            end
            return T
        elseif any(x -> x === m, values(ctx.modules))
            return T
        end
        p = parentmodule(m)
        if p === m
            error(
                "TypeAgnosticSerialisation: $(nameof(T)) is defined in module $(owner), " *
                "which is not in the allowlist.",
            )
        end
        m = p
    end
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

# Record the root module of a type that the encoder describes, for the `"__meta__"` record.
function _record!(ctx::SerdeContext, m::Module)
    seen = ctx.seen
    if seen !== nothing
        r = Base.moduleroot(m)
        seen[string(r)] = r
    end
    return nothing
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
            _record!(ctx, parentmodule(T))
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
        _record!(ctx, parentmodule(T))
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
    return _resolve_named(_migrate_desc(desc, ctx.plan), ctx, env)
end

# A descriptor `{"name", "module", "params"}`, after the type steps of the plan.
function _resolve_named(desc, ctx::SerdeContext, env::Vector{TypeVar})
    if desc["name"] == "Bottom"
        return Union{}
    end
    # A listed function resolves by its own module and name, also when the module of the
    # function is not in `modules`.
    F = get(ctx.function_types, (string(desc["module"]), string(desc["name"])), nothing)
    if F !== nothing && isempty(desc["params"])
        return F
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
    if _is_function_type(base)
        _check_function(base, ctx)   # a listed function returned above, so this refuses
    end
    _check_type(base, ctx)
    params = Any[_resolve_param(p, ctx, env) for p in desc["params"]]
    if !isempty(params)
        return _apply_params(base, params, ctx)
    else
        # Zero params: a leaf DataType (Symbol, Int64, Nothing) or a bare UnionAll
        # (Newton, Vector) resolves to `base` as-is — `apply_type` would error on
        # leaves. The one exception is the empty tuple type, whose `getfield` result
        # is the *abstract* `Tuple`, not the concrete `Tuple{}`. (The abstract `Tuple`
        # is `Tuple{Vararg{Any}}`, so it always carries its Vararg parameter.)
        return base === Tuple ? Tuple{} : base
    end
end

# The encoder writes the parameters of a `DataType` only, so the list of the document is
# the complete list. A release that adds, removes or changes the bound of a parameter
# makes it misfit: `apply_type` fails, or gives a `UnionAll` in place of a `DataType`.
function _apply_params(@nospecialize(base), params::Vector{Any}, ctx::SerdeContext)
    T = try
        Core.apply_type(base, params...)
    catch
        nothing
    end
    T isa DataType && return T
    shown = "{$(join(params, ", "))}"
    misfit =
        "the document gives $(base) " *
        (isempty(params) ? "no parameters" : "the parameters $(shown)") *
        ", which do not fit its definition $(Base.unwrap_unionall(base))."
    if !ctx.repair
        error(
            "TypeAgnosticSerialisation: $(misfit) A release of the package can change the " *
            "parameters of a type after the document was written. Pass `repair = true` " *
            "to keep the leading parameters that fit.",
        )
    end
    R = _refit(base, params)
    rest =
        R isa UnionAll ? ", and the constructor finds the free parameters from the fields" :
        ""
    @warn(
        "TypeAgnosticSerialisation (repair): $(misfit) The decode uses $(R)$(rest).",
        maxlog = 1,
        _id = Symbol("refit ", base, shown),
    )
    return R
end

# The type of a tagged value. A value has a `DataType`, so a bare `UnionAll` such as
# `Circle` is an empty parameter list that does not fit: a release gave the type its first
# parameter. As a type parameter or as a type object, a bare `UnionAll` is correct, so
# `_resolve_type` does not check it.
function _value_type(desc, ctx::SerdeContext)
    haskey(desc, "name") || return _resolve_type(desc, ctx)
    d = _migrate_desc(desc, ctx.plan)   # the parameter list after the type steps
    T = _resolve_named(d, ctx, TypeVar[])
    if T isa UnionAll && isempty(d["params"])
        return _apply_params(T, Any[], ctx)
    end
    return T
end

# The longest leading part of `params` that `base` accepts. With none, the bare `base`.
function _refit(@nospecialize(base), params::Vector{Any})
    for k = min(length(params), _count_vars(base)):-1:1
        T = try
            Core.apply_type(base, params[1:k]...)
        catch
            nothing
        end
        T === nothing || return T
    end
    return base
end

function _count_vars(@nospecialize(T))
    n = 0
    while T isa UnionAll
        n += 1
        T = T.body
    end
    return n
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
#     inner ctors and Base types), keyword-by-field-name as a fallback. If that
#     constructor re-derives different type parameters from the field values (e.g.
#     `Pair(1, "a")` for a `Pair{Int,Any}`), the value is rebuilt at the exact type.
#     Fails loudly on types whose constructor cannot be replayed from its fields.
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
    x = _construct_via_wrapper(T, fields)
    if typeof(x) === T
        return x
    end
    return _retype(T, x, fields, false)
end

# The constructor ran (so its validation passed on these very field values) but
# re-derived *different* type parameters from them: `Pair(1, "a")` is a
# `Pair{Int,String}`, not the `Pair{Int,Any}` that was encoded. Rebuild at the exact
# type — through the parameterised constructor, else by `convert`. `args` are the
# positional fields, or with `kw = true` the named tuple of the keyword call.
function _retype(@nospecialize(T::DataType), @nospecialize(x), args, kw::Bool)
    y = try
        kw ? T(; args...) : T(args...)
    catch
        try
            convert(T, x)
        catch
            nothing
        end
    end
    if typeof(y) === T
        return y
    end
    call = kw ? "$(T)(; $(join(keys(args), ", ")))" : "$(T)(fields...)"
    return error(
        "TypeAgnosticSerialisation (validate): the constructor of $(T) built a " *
        "$(typeof(x)) instead, and neither `$(call)` nor `convert($(T), …)` " *
        "gives the exact type. Mark the type opaque or use `from_json_direct`.",
    )
end

# `T` is a `DataType`, or the `UnionAll` of a repaired parameter list (`_refit`).
function _construct_via_wrapper(@nospecialize(T::Type), fields::Vector{Any})
    base = _wrapper(T)   # unparameterised type: its ctor rederives the parameters
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
                "constructor. Tried `$(nameof(base))(fields...)` → " *
                "$(sprint(showerror, e_pos)); and `$(nameof(base))(; $(flist)...)` → " *
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

The two-argument form also adds a `"__meta__"` key beside `"__type__"` and `"__value__"`.
It records the Julia version (`"julia"`) and, in `"packages"`, the UUID and the version of
each package that defines a type of the document, and of TypeAgnosticSerialisation itself.
A module that is not a package, such as `Main`, has no entry. [`decode`](@ref) reads the
record to warn when a package has a breaking version change after the encode. The
three-argument form writes no record.

Invert with [`decode`](@ref).

```jldoctest
julia> ctx = SerdeContext();

julia> tree = encode((1, "two", :three), ctx);

julia> decode(tree, ctx)
(1, "two", :three)
```
"""
function encode(v, ctx::SerdeContext)
    # A private copy with a fresh recorder: the caller's context never changes.
    rec = SerdeContext(
        ctx.modules,
        ctx.plain_only,
        ctx.opaque,
        ctx.functions,
        ctx.function_types,
        ctx.dicts,
        ctx.validate,
        ctx.repair,
        Dict{String,Module}(),
        nothing,
    )
    tree = encode(v, Any, rec)
    tree["__meta__"] = _meta(rec.seen)
    return tree
end

# The `"__meta__"` record: the Julia version, and the UUID and version of each package
# whose types the document names. Base and Core have no UUID; `"julia"` covers them.
function _meta(seen::Dict{String,Module})
    pkgs = Dict{String,Any}()
    for m in (values(seen)..., @__MODULE__)
        id = Base.PkgId(m)
        id.uuid === nothing && continue
        entry = Dict{String,Any}("uuid" => string(id.uuid))
        v = pkgversion(m)
        v === nothing || (entry["version"] = string(v))
        pkgs[id.name] = entry
    end
    return Dict{String,Any}("julia" => string(VERSION), "packages" => pkgs)
end

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

The two-argument form reads the `"__meta__"` record that [`encode`](@ref) writes. If a
package of the record is loaded at a version that is not semver compatible with the
recorded one, or at an older version, it logs a warning and then decodes. A breaking
change can make the decode fail or give a different value. If the decode then fails, it
throws a [`VersionChangeError`](@ref), which holds the error of the decode and the version
changes. A tree with no record, from a version before v0.4.0, decodes with no check.

The two-argument form also applies the [`MigrationStep`](@ref)s that a package of the record
declares in [`TypeAgnosticSerialisation.migrations`](@ref): each step whose version is after
the recorded version and not after the loaded version, in version order. A package that
declares its steps gets no warning for a breaking version change. The three-argument form
applies no step.

A struct of the tree that lacks a field of its type, or a list of type parameters that does
not fit the type, is an error unless `ctx.repair` is `true`. Then the decode repairs it and
logs a warning. See *Repair* in [`SerdeContext`](@ref).

```jldoctest
julia> ctx = SerdeContext();

julia> decode(encode([1.0, 2.0, 3.0], ctx), ctx)
3-element Vector{Float64}:
 1.0
 2.0
 3.0
```
"""
function decode(tree, ctx::SerdeContext)
    meta = tree isa AbstractDict ? get(tree, "__meta__", nothing) : nothing
    changes = _VersionChange[]
    plan = nothing
    for (name, entry) in _record_pairs(meta)
        e = _record_entry(name, entry)
        e === nothing && continue
        steps = _declared_steps_cached(e.package, e.mod)
        plan = _add_steps(plan, meta, e, steps)
        c = _version_change(e)
        c === nothing && continue
        push!(changes, c)
        # A package that declares its steps states that they cover its changes.
        steps === nothing || continue
        @warn(
            "TypeAgnosticSerialisation: $(_change_text(c)). The decode can fail or give " *
            "a different value.",
            maxlog = 1,
            _id = Symbol(c.package, "@", c.recorded, "->", c.loaded),
        )
    end
    if plan !== nothing
        ctx = SerdeContext(
            ctx.modules,
            ctx.plain_only,
            ctx.opaque,
            ctx.functions,
            ctx.function_types,
            ctx.dicts,
            ctx.validate,
            ctx.repair,
            ctx.seen,
            plan,
        )
    end
    isempty(changes) && return decode(tree, Any, ctx)
    try
        return decode(tree, Any, ctx)
    catch e
        e isa InterruptException && rethrow()
        throw(VersionChangeError(e, changes))
    end
end

# A package of the record that is loaded at an incompatible or an older version.
const _VersionChange = @NamedTuple{
    package::String,
    uuid::Base.UUID,
    recorded::VersionNumber,
    loaded::VersionNumber,
    why::String,
}

function _change_text(c::_VersionChange)
    return "the document was written with $(c.package) v$(c.recorded), and " *
           "$(c.package) v$(c.loaded) is loaded, $(c.why)"
end

"""
    VersionChangeError(error, changes)

The error of a [`decode`](@ref) that failed on a document whose `"__meta__"` record shows a
version change. `error` is the error of the decode. `changes` lists each package of the
record that is loaded at a version that is not semver compatible with the recorded one, or
at an older version. Each entry is a named tuple `(; package, uuid, recorded, loaded, why)`,
where `why` is `"a breaking version change"` or `"an older version"`.

A decode throws this error only when the record shows such a change. With no change, the
error of the decode comes out unchanged. A change of a type in a breaking release, such as
a field that is added or renamed, is a frequent cause.

The example below sets the recorded version to 99.0.0, which is not semver compatible
with the loaded version, and breaks the payload. The loaded version and the source
location of the warning change from one run to the next, so the doctest filters them.

```jldoctest; filter = [r"(?<=TypeAgnosticSerialisation )v[^ ]+(?= is loaded)", r"└ @ .*"]
julia> ctx = SerdeContext();

julia> tree = encode(1.5, ctx);

julia> tree["__meta__"]["packages"]["TypeAgnosticSerialisation"]["version"] = "99.0.0";

julia> tree["__value__"] = "one and a half";

julia> err = try
           decode(tree, ctx)
       catch e
           e
       end;
┌ Warning: TypeAgnosticSerialisation: the document was written with TypeAgnosticSerialisation v99.0.0, and TypeAgnosticSerialisation v0.4.0 is loaded, a breaking version change. The decode can fail or give a different value.
└ @ TypeAgnosticSerialisation

julia> err isa VersionChangeError
true

julia> err.error isa ArgumentError
true

julia> only(err.changes).why
"a breaking version change"
```
"""
struct VersionChangeError <: Exception
    error::Any
    changes::Vector{_VersionChange}
end

function Base.showerror(io::IO, e::VersionChangeError)
    print(io, "VersionChangeError: ")
    showerror(io, e.error)
    print(io, "\nThe version record of the document shows a change that can be the cause:")
    for c in e.changes
        print(io, "\n  - ", _change_text(c), ".")
    end
    return nothing
end

# The part of a version that a breaking change increments, by semver as Pkg reads it.
function _breaking_part(v::VersionNumber)
    v.major != 0 && return (v.major,)
    v.minor != 0 && return (0, v.minor)
    return (0, 0, v.patch)
end

# Parse a string of the record; any other value, such as a number, is malformed.
_tryparse_string(::Type{T}, s::AbstractString) where {T} = tryparse(T, s)
_tryparse_string(::Type, _) = nothing

# The packages of the record, as `name => entry` pairs. The record is data from the
# document: a malformed record or entry is skipped, never an error.
function _record_pairs(meta)
    pkgs = meta isa AbstractDict ? get(meta, "packages", nothing) : nothing
    return pkgs isa AbstractDict ? pkgs : ()
end

# An entry of the record for a package that is loaded, with its recorded and its loaded
# version; `nothing` for a malformed entry or a package that is not loaded.
function _record_entry(name, entry)
    (name isa AbstractString && entry isa AbstractDict) || return nothing
    uuid = _tryparse_string(Base.UUID, get(entry, "uuid", nothing))
    old = _tryparse_string(VersionNumber, get(entry, "version", nothing))
    (uuid === nothing || old === nothing) && return nothing
    package = String(name)
    m = get(Base.loaded_modules, Base.PkgId(uuid, package), nothing)
    m === nothing && return nothing
    new = pkgversion(m)
    new === nothing && return nothing
    return (; package, uuid, mod = m, recorded = old, loaded = new)
end

# The change of a loaded package, if it is loaded at an incompatible or an older version.
function _version_change(e)
    old, new = e.recorded, e.loaded
    if _breaking_part(old) != _breaking_part(new)
        why = "a breaking version change"
    elseif new < old
        why = "an older version"
    else
        return nothing
    end
    return _VersionChange((e.package, e.uuid, old, new, why))
end

function decode(tree, @nospecialize(H), ctx::SerdeContext)
    if tree isa AbstractDict && haskey(tree, "__type__")
        T = _value_type(tree["__type__"], ctx)
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
    elseif _is_function_type(T)
        # A named function: the type alone states the value, in both modes. It comes back
        # only if the caller listed it.
        return _check_function(T, ctx)
    elseif T <: Type
        # The value itself is a type; payload is a type reference.
        return _resolve_type(payload, ctx)
    elseif T isa UnionAll
        # A repaired parameter list (`_refit`) gives a `UnionAll` here. Any other
        # `UnionAll` names no value.
        ctx.repair ||
            error("TypeAgnosticSerialisation: don't know how to decode into type $(T).")
        return _decode_struct(payload, T, ctx)
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
        if !(_wrapper(T) in ctx.dicts)
            error(
                "TypeAgnosticSerialisation: the dict type $(T) is not in the allowlist; " *
                "a dict decodes only into `Dict`, `IdDict` or a type of `dicts`. Pass it " *
                "via `dicts = (…, $(nameof(_wrapper(T))), …)`.",
            )
        end
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
        return _decode_struct(payload, T, ctx)
    else
        error("TypeAgnosticSerialisation: don't know how to decode into type $(T).")
    end
end

# The value of `get` for a field that the document does not have.
struct _Absent end

# The fields of a struct of the document. A field that the type has and the document does
# not have, and a key that the type does not have, show a change of the type after the
# encode. `ctx.repair` chooses between an error and a repair; see `SerdeContext`.
function _decode_struct(payload, @nospecialize(T), ctx::SerdeContext)
    U = Base.unwrap_unionall(T)
    if !(U isa DataType && isstructtype(U))
        error("TypeAgnosticSerialisation: don't know how to decode into type $(T).")
    end
    if T isa UnionAll && !ctx.validate
        error(
            "TypeAgnosticSerialisation (repair): the type $(T) has free parameters, and " *
            "the direct mode builds a struct with `new`, which needs each parameter. " *
            "Load with the validated mode and `repair = true`, so that the constructor " *
            "finds them from the fields.",
        )
    end
    payload = _migrate_payload(payload, T, ctx.plan)   # the declared steps, before the fields
    n = fieldcount(T)
    fields = Vector{Any}(undef, n)
    absent = Int[]
    for i = 1:n
        v = get(payload, String(fieldname(T, i)), _Absent())
        if v isa _Absent
            (ctx.repair && ctx.validate) || _missing_fields_error(payload, T, ctx)
            push!(absent, i)
        else
            fields[i] = _decode_field(v, T, i, ctx)
        end
    end
    ctx.repair && _drop_extra_keys(payload, T)
    if !isempty(absent)
        return _construct_partial(T, fields, absent)
    elseif !ctx.validate
        return _newbuild(T, fields)
    elseif T isa DataType
        return _construct_safe(T, fields)
    else
        return _at_refit(T, _construct_via_wrapper(T, fields))
    end
end

function _decode_field(v, @nospecialize(T), i::Int, ctx::SerdeContext)
    H = fieldtype(T, i)
    if T isa UnionAll &&
       !isconcretetype(H) &&
       !(v isa AbstractDict && haskey(v, "__type__"))
        error(
            "TypeAgnosticSerialisation (repair): the declared type of the field " *
            "`$(fieldname(T, i))` of $(T) uses a free parameter, and the document holds its " *
            "value with no type tag. The repair cannot find the type of the value.",
        )
    end
    return decode(v, H, ctx)
end

# The keys that the document has and the type does not have.
function _extra_keys(payload, @nospecialize(T))
    names = fieldnames(T)
    return String[string(k) for k in keys(payload) if !(Symbol(k) in names)]
end

_names_text(names) = join(("`$(s)`" for s in names), ", ")

function _missing_fields_error(payload, @nospecialize(T), ctx::SerdeContext)
    absent = Symbol[s for s in fieldnames(T) if !haskey(payload, String(s))]
    extra = _extra_keys(payload, T)
    msg =
        "TypeAgnosticSerialisation: the document has no field $(_names_text(absent)) " *
        "for $(T)."
    if !isempty(extra)
        msg *=
            " It has the keys $(_names_text(extra)), which are no fields of $(T). A " *
            "renamed field gives such a pair."
    end
    if ctx.repair
        msg *=
            " The direct mode builds a struct with `new`, which has no default to fill a " *
            "field. Load with the validated mode and `repair = true`, so that the keyword " *
            "constructor fills it."
    else
        msg *=
            " A release of the package can add a field after the document was written. " *
            "Pass `repair = true` to fill it from a default of the keyword constructor."
    end
    return error(msg)
end

function _drop_extra_keys(payload, @nospecialize(T))
    extra = _extra_keys(payload, T)
    isempty(extra) && return nothing
    @warn(
        "TypeAgnosticSerialisation (repair): the document gives $(T) the keys " *
        "$(_names_text(extra)), which are no fields of it. The decode drops them.",
        maxlog = 1,
        _id = Symbol("drop ", _wrapper(T), " ", join(extra, ",")),
    )
    return nothing
end

# Validated mode with `repair = true`: the keyword constructor fills the absent fields.
function _construct_partial(@nospecialize(T), fields::Vector{Any}, absent::Vector{Int})
    present = [i for i = 1:fieldcount(T) if !(i in absent)]
    kw = NamedTuple{Tuple(fieldname(T, i) for i in present)}(Tuple(fields[present]))
    missing_names = _names_text(fieldname(T, i) for i in absent)
    base = _wrapper(T)
    x = try
        base(; kw...)
    catch e
        e isa InterruptException && rethrow()
        error(
            "TypeAgnosticSerialisation (repair): the document has no field " *
            "$(missing_names) for $(T), and the keyword constructor " *
            "`$(nameof(base))(; $(join(keys(kw), ", ")))` fails: " *
            "$(sprint(showerror, e)). Give the field a default, for example with " *
            "`Base.@kwdef`.",
        )
    end
    y = T isa DataType ? (typeof(x) === T ? x : _retype(T, x, kw, true)) : _at_refit(T, x)
    @warn(
        "TypeAgnosticSerialisation (repair): the document has no field $(missing_names) " *
        "for $(T). The keyword constructor fills it with its default.",
        maxlog = 1,
        _id = Symbol("fill ", base, " ", missing_names),
    )
    return y
end

# The constructor of a repaired parameter list finds the free parameters; the value must
# still be of the leading parameters that the document gives.
function _at_refit(@nospecialize(T::UnionAll), @nospecialize(x))
    x isa T && return x
    return error(
        "TypeAgnosticSerialisation (repair): the constructor of $(_wrapper(T)) built a " *
        "$(typeof(x)), which is not a $(T).",
    )
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
