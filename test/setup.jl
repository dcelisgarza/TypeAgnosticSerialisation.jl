# Shared test domain and helpers. Every test file that needs them starts with
#
#     isdefined(@__MODULE__, :TestSerdeModule) || include("setup.jl")
#
# so the files run in any order, alone or under runtests.jl.
using TypeAgnosticSerialisation
using TypeAgnosticSerialisation:
    SerdeContext, encode, decode, to_json, from_json, from_json_direct
using Test
# Loading the backends activates the format extensions.
import JSON, MsgPack, TOML, YAML

# ---------------------------------------------------------------------------
# A self-contained domain to exercise the whole library. Nothing here depends on
# anything outside Base/Core, so the suite is hermetic.
# ---------------------------------------------------------------------------
module TestSerdeModule

export AbstractShape, Circle, Rect, Square, Color, red, green, blue
export Scene, Doc, KwOnly, Handle, NoDefault, Loose

abstract type AbstractShape end

# Parametric struct with a validating inner constructor: `from_json` must enforce the
# `r > 0` invariant, `from_json_direct` must be able to bypass it.
struct Circle{T} <: AbstractShape
    r::T
    function Circle{T}(r::T) where {T}
        r > 0 || error("Circle: radius must be positive (got $r)")
        return new{T}(r)
    end
end
Circle(r::T) where {T} = Circle{T}(r)

struct Rect{T} <: AbstractShape
    w::T
    h::T
end

struct Square <: AbstractShape end   # singleton, zero fields

@enum Color red green blue

# The payoff type: a heterogeneous `Vector{AbstractShape}`, an enum, and an `Any`-valued
# dict — none of the element types are known statically, so each carries its own tag.
struct Scene
    shapes::Vector{AbstractShape}
    bg::Color
    meta::Dict{String,Any}
end

# A "live" non-data handle: a raw pointer that cannot be serialised structurally. Used to
# show `opaque` skipping and the "fail loudly" path.
struct Handle
    ptr::Ptr{Cvoid}
    Handle() = new(C_NULL)
end

# Data wrapping a live handle, to show surrounding data survives when the handle is opaque.
struct Doc
    title::String
    handle::Handle
end

# Only a keyword constructor -> exercises `_construct_safe`'s keyword-by-field-name fallback.
struct KwOnly
    a::Int
    b::Int
    KwOnly(; a, b) = new(a, b)
end

# Opaque type with no zero-argument constructor -> `_construct_opaque` must fail loudly.
struct NoDefault
    x::Int
end

# Only an unparameterised constructor, which always derives `T` from the field: a
# `Loose{Real}` (built with `new`) cannot be rebuilt at its exact type by `_construct_safe`.
struct Loose{T}
    x::T
    Loose(x::T) where {T} = new{T}(x)
end

end # module TestSerdeModule

using .TestSerdeModule
const M = TestSerdeModule

# ---------------------------------------------------------------------------
# Test helpers (kept out of the package — they are not public API).
# ---------------------------------------------------------------------------

# Structural equality: user structs rarely define `==`, and `NaN != NaN`, so compare
# field-by-field with `isequal` at the leaves.
function structeq(a, b)
    typeof(a) === typeof(b) || return false
    T = typeof(a)
    if a isa AbstractFloat
        return isequal(a, b)                       # handles NaN / signed zero
    elseif a isa Number ||
           a isa AbstractString ||
           a isa Symbol ||
           a isa AbstractChar ||
           a isa Base.Enum
        return a == b
    elseif a isa AbstractArray
        size(a) == size(b) || return false
        return all(structeq(x, y) for (x, y) in zip(a, b))
    elseif a isa AbstractDict
        length(a) == length(b) || return false
        for (k, v) in a
            haskey(b, k) || return false
            structeq(v, b[k]) || return false
        end
        return true
    elseif a isa Tuple || a isa NamedTuple
        return all(structeq(getfield(a, i), getfield(b, i)) for i = 1:nfields(a))
    elseif isstructtype(T)
        for i = 1:fieldcount(T)
            (isdefined(a, i) == isdefined(b, i)) || return false
            isdefined(a, i) || continue
            structeq(getfield(a, i), getfield(b, i)) || return false
        end
        return true
    else
        return isequal(a, b)
    end
end

# Round-trip `x` through BOTH the tree layer (encode/decode) and the text layer
# (to_json/from_json*), returning the reconstructed values and whether they match.
function roundtrip(x; modules = (), opaque = (), validate = false)
    ctx = SerdeContext(modules; opaque = opaque, validate = validate)
    x_tree = decode(encode(x, ctx), ctx)
    js = to_json(x; modules = modules, opaque = opaque)
    x_text =
        validate ? from_json(js; modules = modules, opaque = opaque) :
        from_json_direct(js; modules = modules, opaque = opaque)
    return (;
        tree = x_tree,
        text = x_text,
        ok_tree = structeq(x, x_tree),
        ok_text = structeq(x, x_text),
    )
end

# A representative Scene: three shapes of three different concrete types under one abstract
# element type, plus a heterogeneous metadata dict.
sample_scene() = Scene(
    AbstractShape[Circle(1.5), Rect(3, 4), Square()],
    green,
    Dict{String,Any}("author" => "ada", "count" => 3, "ratio" => 2.5),
)
