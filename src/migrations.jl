# Migrations: the steps that a package declares for each breaking release of its types.
#
# A package declares its steps with `migrations(::Val{:Pkg})`, or with the `@migrations`
# macro that writes that method. The two-argument `decode` reads the `"__meta__"` record of
# the document. For each recorded package that is loaded, it keeps the steps whose version
# is after the recorded version and not after the loaded version, in version order. This
# plan goes into the context of the decode:
#
#   * The type steps (`RenameType`, `ParameterMigration`) change a type descriptor of the
#     tree, before `_resolve_type` looks up the name (`_migrate_desc`).
#   * The payload steps (`RenameField`, `AddField`, `RemoveField`, `Migration`) change the
#     payload of a struct, before `_decode_struct` reads its fields (`_migrate_payload`). A
#     parent is decoded before its children, so a step of a parent can change the shape of
#     a child payload.
#
# A step names a type by its path in the package, as of the release of the step: "Circle",
# or "Shapes.Circle" for a type of the submodule `Shapes`. At one version, the type renames
# come first, so a payload step of that version names the type by its new name.

"""
    MigrationStep

The supertype of a step that a package declares in [`TypeAgnosticSerialisation.migrations`](@ref).
Each step has a `version`: the release of the package that made the change. The decode
applies a step to a document that an earlier release wrote. The steps are:

  - [`RenameType`](@ref) and [`ParameterMigration`](@ref) change the type that the
    document names.
  - [`RenameField`](@ref), [`AddField`](@ref), [`RemoveField`](@ref) and
    [`Migration`](@ref) change the payload of a struct, before the decode reads its fields.

A step names a type by its path in the package, as of the release of the step: `"Circle"`
for a type of the package module, `"Shapes.Circle"` for a type of its submodule `Shapes`.
"""
abstract type MigrationStep end

function _step_name(x::Union{AbstractString,Symbol})
    s = String(x)
    isempty(s) &&
        throw(ArgumentError("TypeAgnosticSerialisation: a step names an empty name."))
    return s
end

"""
    RenameType(version::VersionNumber, from => to)

The release `version` renamed the type `from` to `to`. Both are paths in the package, so a
step can also move a type to another submodule of the package: `"Shapes.Circle" =>
"Circle"`. A step cannot move a type to another package.

```julia
RenameType(v"2.0.0", "OldCircle" => "Circle")
```
"""
struct RenameType <: MigrationStep
    version::VersionNumber
    from::String
    to::String
    function RenameType(version::VersionNumber, names::Pair)
        from, to = _step_name(names.first), _step_name(names.second)
        from == to && throw(
            ArgumentError(
                "TypeAgnosticSerialisation: `RenameType` renames $(from) to itself.",
            ),
        )
        return new(version, from, to)
    end
end

"""
    RenameField(version::VersionNumber, type, from => to)

The release `version` renamed the field `from` of the struct `type` to `to`. If the payload
has no key `from`, the step does nothing. If it has both keys, the decode fails.

```julia
RenameField(v"2.0.0", "Circle", "r" => "radius")
```
"""
struct RenameField <: MigrationStep
    version::VersionNumber
    type::String
    from::String
    to::String
    function RenameField(version::VersionNumber, type, names::Pair)
        from, to = _step_name(names.first), _step_name(names.second)
        from == to && throw(
            ArgumentError(
                "TypeAgnosticSerialisation: `RenameField` renames $(from) to itself.",
            ),
        )
        return new(version, _step_name(type), from, to)
    end
end

"""
    AddField(version::VersionNumber, type, name => value)

The release `version` added the field `name` to the struct `type`. The decode sets the key
`name` of the payload to `value`. Give `value` as it appears in a tree that
[`encode`](@ref) writes: a number, a string, or a tagged envelope for a field whose declared
type is not concrete.

```julia
AddField(v"2.0.0", "Circle", "colour" => "red")
```
"""
struct AddField <: MigrationStep
    version::VersionNumber
    type::String
    name::String
    value::Any
    function AddField(version::VersionNumber, type, field::Pair)
        return new(version, _step_name(type), _step_name(field.first), field.second)
    end
end

"""
    RemoveField(version::VersionNumber, type, name)

The release `version` removed the field `name` from the struct `type`. The decode deletes
the key `name` of the payload. With no step, the decode also drops the key, but with
`repair = true` it logs a warning.

```julia
RemoveField(v"2.0.0", "Circle", "border")
```
"""
struct RemoveField <: MigrationStep
    version::VersionNumber
    type::String
    name::String
    function RemoveField(version::VersionNumber, type, name)
        return new(version, _step_name(type), _step_name(name))
    end
end

"""
    Migration(f, version::VersionNumber, type)

The release `version` changed the struct `type` in a way that the other steps do not
state, such as a change of units. The decode calls `f(payload, meta)` and reads the fields
from the dict that `f` returns. `payload` is a copy of the payload of the struct, a dict of
the plain tree, so `f` can change it. `meta` is the `"__meta__"` record of the document;
`f` must not change it. `f` never sees a value of the old type, because that type no longer
exists.

```julia
Migration(v"3.0.0", "Scene") do payload, meta
    payload["scale"] = payload["scale"] / 100   # percent to fraction
    return payload
end
```
"""
struct Migration{F} <: MigrationStep
    f::F
    version::VersionNumber
    type::String
    function Migration(f, version::VersionNumber, type)
        return new{typeof(f)}(f, version, _step_name(type))
    end
end

"""
    ParameterMigration(f, version::VersionNumber, type)

The release `version` changed the type parameters of `type`, for example their order. The
decode calls `f(params)` with a copy of the list of parameter descriptors that the document
gives, and resolves the type with the list that `f` returns. Each descriptor is a dict
`{"type": descriptor}` for a type, or `{"value": tree}` for a value such as `3` or `:a`.

```julia
ParameterMigration(v"3.0.0", "Pair2") do params
    return reverse(params)   # Pair2{B,A} became Pair2{A,B}
end
```
"""
struct ParameterMigration{F} <: MigrationStep
    f::F
    version::VersionNumber
    type::String
    function ParameterMigration(f, version::VersionNumber, type)
        return new{typeof(f)}(f, version, _step_name(type))
    end
end

# At one version: the type renames, then the parameter changes, then the payload steps.
_step_order(::RenameType) = 0
_step_order(::ParameterMigration) = 1
_step_order(::MigrationStep) = 2

_is_payload_step(s::MigrationStep) = _step_order(s) == 2

"""
    TypeAgnosticSerialisation.migrations(::Val{name}) -> Tuple

The [`MigrationStep`](@ref)s that the package `name` declares, one or more for each release
that changed a type of the package. The fallback gives `()`. A package adds a method for its
own name, or uses [`@migrations`](@ref), which writes the method:

```julia
module MyPkg
using TypeAgnosticSerialisation
# ...
TypeAgnosticSerialisation.migrations(::Val{:MyPkg}) = (
    RenameType(v"2.0.0", "OldCircle" => "Circle"),
    RenameField(v"2.0.0", "Circle", "r" => "radius"),
    AddField(v"2.0.0", "Circle", "colour" => "red"),
)
end
```

The two-argument [`decode`](@ref) reads the `"__meta__"` record of the document. For each
package of the record that is loaded, it applies the steps whose version is after the
recorded version and not after the loaded version, in version order. The steps apply with
no `repair` keyword: the package declares them, so they are not a guess.

The decode uses the method only if the package that the record names by its UUID defines
it. A method for the name that another module defines is ignored with a warning. A package
that defines the method, even with no steps, states that it declares a step for each change
of its types: the decode then gives no warning for a breaking version change of the package.
A document from a version before v0.4.0 has no record, so no step applies to it.
"""
migrations(::Val) = ()

"""
    @migrations begin
        step
        ...
    end

Write the method [`TypeAgnosticSerialisation.migrations`](@ref) for the package that holds
the call, with one [`MigrationStep`](@ref) for each line of the block. The package is the root
module of the module of the call, so a call in a submodule declares the steps of the package.

```julia
module MyPkg
using TypeAgnosticSerialisation
# ...
@migrations begin
    RenameType(v"2.0.0", "OldCircle" => "Circle")
    RenameField(v"2.0.0", "Circle", "r" => "radius")
    Migration(v"3.0.0", "Scene") do payload, meta
        payload["scale"] = payload["scale"] / 100
        return payload
    end
end
end
```
"""
macro migrations(block)
    name = nameof(Base.moduleroot(__module__))
    steps = if block isa Expr && block.head === :block
        Any[x for x in block.args if !(x isa LineNumberNode)]
    else
        Any[block]
    end
    tuple = Expr(:tuple, steps...)
    return esc(:($(@__MODULE__).migrations(::$(Val){$(QuoteNode(name))}) = $tuple))
end

# The plan of one decode: for each package name, the loaded module and its steps in order.
# The cache holds, for each struct type, the payload steps that apply to it.
struct _Plan
    meta::Any
    packages::Dict{String,Tuple{Module,Vector{MigrationStep}}}
    cache::IdDict{Any,Vector{MigrationStep}}
end

# The steps that each package declares, as of a world age. A method lookup costs more than
# a small decode, so the decode looks up a package again only after a method is defined.
const _DECLARED = Dict{Module,Any}()   # package module => steps, or `nothing`
const _DECLARED_WORLD = Ref{UInt}(0)    # the world age of the entries of `_DECLARED`
const _DECLARED_LOCK = ReentrantLock()

function _declared_steps_cached(name::String, m::Module)
    world = Base.get_world_counter()
    lock(_DECLARED_LOCK)
    try
        if _DECLARED_WORLD[] != world
            empty!(_DECLARED)
            _DECLARED_WORLD[] = world
        end
        return get!(() -> _declared_steps(name, m), _DECLARED, m)
    finally
        unlock(_DECLARED_LOCK)
    end
end

# The steps that the package `name`, loaded as `m`, declares; `nothing` if it declares none.
function _declared_steps(name::String, m::Module)
    key = Val(Symbol(name))
    meth = which(migrations, Tuple{typeof(key)})
    meth.module === (@__MODULE__) && return nothing   # the fallback
    if Base.moduleroot(meth.module) !== m
        @warn(
            "TypeAgnosticSerialisation: the method `migrations(::Val{:$(name)})` is defined " *
            "in $(meth.module), not in the package $(name) of the version record. The " *
            "decode ignores its steps.",
            maxlog = 1,
            _id = Symbol("foreign migrations ", name, " ", meth.module),
        )
        return nothing
    end
    return _check_steps(Base.invokelatest(migrations, key), name)
end

function _check_steps(steps, name::String)
    if !(steps isa Union{Tuple,AbstractVector}) || !all(s -> s isa MigrationStep, steps)
        error(
            "TypeAgnosticSerialisation: `migrations(::Val{:$(name)})` must give a tuple of " *
            "`MigrationStep`s, and it gives $(repr(steps)).",
        )
    end
    return steps
end

# Add to `plan` the `steps` of the package of the record entry `e` (see `_record_entry`)
# that apply to the document. The plan stays `nothing` until a step applies.
_add_steps(plan, meta, e, ::Nothing) = plan

function _add_steps(plan, meta, e, steps)
    keep = MigrationStep[s for s in steps if e.recorded < s.version <= e.loaded]
    isempty(keep) && return plan
    sort!(keep; by = s -> (s.version, _step_order(s)), alg = Base.Sort.DEFAULT_STABLE)
    if plan === nothing
        plan = _Plan(
            meta,
            Dict{String,Tuple{Module,Vector{MigrationStep}}}(),
            IdDict{Any,Vector{MigrationStep}}(),
        )
    end
    plan.packages[e.package] = (e.mod, keep)
    return plan
end

# A type descriptor `{"name", "module", "params"}` after the type steps of the plan.
_migrate_desc(desc, ::Nothing) = desc

function _migrate_desc(desc, plan::_Plan)
    parts = split(string(desc["module"]), '.')
    entry = get(plan.packages, parts[1], nothing)
    entry === nothing && return desc
    key = join((parts[2:end]..., string(desc["name"])), '.')
    params = desc["params"]
    changed = false
    for s in entry[2]
        if s isa RenameType && s.from == key
            key = s.to
            changed = true
        elseif s isa ParameterMigration && s.type == key
            params = _run_step(s, key, () -> s.f(collect(Any, params)))
            params isa AbstractVector || error(
                "TypeAgnosticSerialisation: the `ParameterMigration` of $(parts[1]) " *
                "v$(s.version) for $(key) gives $(repr(params)), which is not a vector.",
            )
            changed = true
        end
    end
    changed || return desc
    path = split(key, '.')
    return Dict{String,Any}(
        "name" => String(path[end]),
        "module" => join((parts[1], path[1:(end-1)]...), '.'),
        "params" => collect(Any, params),
    )
end

# The payload of a struct of type `T` after the payload steps of the plan.
_migrate_payload(payload, @nospecialize(T), ::Nothing) = payload

function _migrate_payload(payload, @nospecialize(T), plan::_Plan)
    payload isa AbstractDict || return payload
    steps = get!(() -> _payload_steps(plan, T), plan.cache, _wrapper(T))
    isempty(steps) && return payload
    p = copy(payload)   # the caller's tree never changes
    for s in steps
        p = _apply_step(s, p, plan.meta)
    end
    return p
end

# The payload steps for the struct type `T`, in order. The walk goes back from the last step
# and undoes each type rename, so that it compares each step with the name of the type as of
# the release of the step.
function _payload_steps(plan::_Plan, @nospecialize(T))
    w = _wrapper(T)
    m = parentmodule(w)
    root = Base.moduleroot(m)
    entry = get(plan.packages, string(nameof(root)), nothing)
    (entry === nothing || entry[1] !== root) && return MigrationStep[]
    key = join((map(string, fullname(m)[2:end])..., string(nameof(w))), '.')
    out = MigrationStep[]
    for s in Iterators.reverse(entry[2])
        if s isa RenameType
            s.to == key && (key = s.from)
        elseif _is_payload_step(s) && s.type == key
            push!(out, s)
        end
    end
    return reverse!(out)
end

function _apply_step(s::RenameField, p, meta)
    haskey(p, s.from) || return p
    if haskey(p, s.to)
        error(
            "TypeAgnosticSerialisation: the step `RenameField` of v$(s.version) renames the " *
            "field `$(s.from)` of $(s.type) to `$(s.to)`, but the document has both keys.",
        )
    end
    p[s.to] = pop!(p, s.from)
    return p
end

function _apply_step(s::AddField, p, meta)
    p[s.name] = deepcopy(s.value)   # a later step must not change the value of the step
    return p
end

function _apply_step(s::RemoveField, p, meta)
    delete!(p, s.name)
    return p
end

function _apply_step(s::Migration, p, meta)
    q = _run_step(s, s.type, () -> s.f(deepcopy(p), meta))
    q isa AbstractDict || error(
        "TypeAgnosticSerialisation: the `Migration` of v$(s.version) for $(s.type) gives " *
        "$(repr(q)), which is not a dict.",
    )
    return q
end

# Run the function of a step, and name the step in its error.
function _run_step(s::MigrationStep, type, f)
    try
        return f()
    catch e
        e isa InterruptException && rethrow()
        error(
            "TypeAgnosticSerialisation: the `$(nameof(typeof(s)))` of v$(s.version) for " *
            "$(type) fails: $(sprint(showerror, e))",
        )
    end
end
