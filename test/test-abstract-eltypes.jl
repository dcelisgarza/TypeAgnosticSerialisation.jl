isdefined(@__MODULE__, :TestSerdeModule) || include("setup.jl")

# Arrays (and other containers) whose element type is abstract. A plain abstract DataType
# (`Real`, `AbstractShape`) is described like any DataType; a `Union`, a partially-applied
# `UnionAll` and a `Vararg` need their own descriptors. Every element is tagged with its
# own concrete type, so the values inside are heterogeneous.
const ABSTRACT_ELTYPE_VALUES = Any[
    Real[1, 2.0, 3//4],
    Number[1 2.0; 3 4.0f0],
    Array{AbstractFloat,3}(reshape(Float64.(1:8), 2, 2, 2)),
    AbstractVector{Float64}[[1.0], 1.0:2.0],
    Real[],
    # Union element types.
    Union{Missing,Float64}[1.0, missing],
    Union{Nothing,Int}[1, nothing],
    Matrix{Union{Nothing,Int}}([1 nothing; nothing 4]),
    Vector{Union{Int,String,Nothing}}([1, "a", nothing]),
    Union{Missing,Float64}[],
    # Partially-applied UnionAll element types.
    Vector[[1], [2.0]],
    Vector{Array{Float64}}([[1.0], [1.0 2.0]]),
    Vector{Vector{<:Real}}([[1], [2.0]]),
    Vector{Dict{K,V} where {V} where K<:Integer}([Dict(1 => "a"), Dict(0x02 => 3)]),
    Dict{String,Vector}("a" => [1], "b" => ["x"]),
    # Vararg: the abstract `Tuple` is `Tuple{Vararg{Any}}`.
    Tuple[(1,), (1, "a")],
    Vector{NTuple{N,Int} where N}([(1,), (1, 2)]),
    Vector{Tuple{Int,Vararg{Float64}}}([(1,), (1, 2.0)]),
    # Nested: a Union of a UnionAll.
    Vector{Union{Missing,Vector{<:Real}}}([missing, [1], [2.0]]),
]

@testset "round-trip $(typeof(x)) (validate=$v)" for x in ABSTRACT_ELTYPE_VALUES,
    v in (false, true)

    r = roundtrip(x; validate = v)
    @test r.ok_tree
    @test r.ok_text
    @test typeof(r.text) === typeof(x)
end

@testset "abstract element type from an allowlisted module" begin
    shapes = Union{Nothing,AbstractShape}[Circle(1.0), nothing, Rect(1, 2)]
    for v in (false, true)
        r = roundtrip(shapes; modules = (M,), validate = v)
        @test r.ok_tree
        @test r.ok_text
    end
    # A Union member is resolved through the allowlist like any other type.
    @test_throws ErrorException from_json(to_json(shapes; modules = (M,)); modules = ())
    # So is the body of a UnionAll.
    circles = Vector{Circle{<:Real}}([Circle(1), Circle(2.0)])
    @test structeq(from_json(to_json(circles; modules = (M,)); modules = (M,)), circles)
    @test_throws ErrorException from_json(to_json(circles; modules = (M,)); modules = ())
end

@testset "type values round-trip" begin
    ctx = SerdeContext((M,))
    typ(x) = decode(encode(x, ctx), ctx)
    for T in (
        Union{Int,Float64},
        Union{Missing,Circle{Float64}},
        Array{Float64},
        Vector{<:Real},
        Tuple,
        NTuple{3,Int},
        Tuple{Int,Vararg{String}},
        NTuple{N,Int} where {N},
        Tuple{T,T} where {T<:Number},
        Pair{K,V} where {V<:K} where {K},   # a bound that references an outer variable
        Ref{T} where {Int<:T<:Real},        # a lower bound
        Vector{Vector{T} where T},          # a UnionAll nested inside a DataType
    )
        @test typ(T) == T
    end
end

@testset "type-descriptor errors" begin
    ctx = SerdeContext((M,))
    tvs = TypeAgnosticSerialisation
    # A free type variable has no binder to refer to.
    @test_throws ErrorException tvs._type_desc(TypeVar(:T), ctx)
    # An outer variable shadowed by an inner one of the same name cannot be named.
    outer, inner = TypeVar(:T), TypeVar(:T)
    shadowed = UnionAll(outer, UnionAll(inner, Pair{inner,outer}))
    @test_throws ErrorException tvs._type_desc(shadowed, ctx)
    # A reference to a variable that no "where" binds is refused on decode.
    @test_throws ErrorException tvs._resolve_type(Dict{String,Any}("typevar" => "T"), ctx)
end
