# The decode gates: a document names the types and functions that it holds, so each name
# must pass the allowlists before a value is built. Every value here is harmless; the
# tests show only that the gates refuse a name that the caller did not allow.
isdefined(@__MODULE__, :TestSerdeModule) || include("setup.jl")

const TAS = TypeAgnosticSerialisation
const NOT_LISTED_FN = "is not in the `functions` allowlist"

# A tagged tree of type `T` with the given payload, written by hand.
tagged(T, payload) = Dict{String,Any}(
    "__type__" => TAS._type_desc(T, SerdeContext((Base, Core, M))),
    "__value__" => payload,
)

@testset "a function that is not listed is refused (validate=$v)" for v in (false, true)
    load = v ? from_json : from_json_direct
    js = to_json(Holder(sin); modules = (M,))
    # No list at all: the default is empty.
    @test_throws NOT_LISTED_FN load(js; modules = (M,))
    # A list that holds other functions only.
    @test_throws NOT_LISTED_FN load(js; modules = (M,), functions = (cos, bump))
    # Listing the module of the function does not let the function in.
    @test_throws NOT_LISTED_FN load(js; modules = (M, Base))
    js = to_json(Smoother(bump, 0.5); modules = (M,))
    @test_throws NOT_LISTED_FN load(js; modules = (M,), functions = (sin,))
    # A function at the top level, and in a vector.
    @test_throws NOT_LISTED_FN load(to_json(sin); functions = (cos,))
    @test_throws NOT_LISTED_FN load(to_json(Any[1, sin]))
    # A reference to the type of a function is refused too.
    @test_throws NOT_LISTED_FN load(to_json(typeof(sin)))
    # An anonymous function with no captures is a singleton function as well.
    anon = x -> 2x
    js = to_json(Holder(anon); modules = (M, @__MODULE__))
    @test_throws NOT_LISTED_FN load(js; modules = (M, @__MODULE__))
    @test load(js; modules = (M, @__MODULE__), functions = (anon,)).f === anon
end

@testset "functions must hold named functions" begin
    @test_throws "not a named function" SerdeContext(; functions = (1,))
    @test_throws "not a named function" SerdeContext(; functions = (Base.Fix1(+, 1),))
end

@testset "a dict type that is not listed is refused (validate=$v)" for v in (false, true)
    M.DICT_WRITES[] = 0
    payload = encode(Dict("a" => 1), Dict{String,Int}, SerdeContext())
    # A dict type of a listed module: the decode refuses it before it builds one.
    ctx = SerdeContext((M,); validate = v)
    tree = tagged(CountingDict{String,Int}, payload)
    @test_throws "is not in the allowlist" decode(tree, ctx)
    js = JSON.json(tree)
    @test_throws "is not in the allowlist" (v ? from_json : from_json_direct)(
        js;
        modules = (M,),
    )
    @test M.DICT_WRITES[] == 0
    # A dict type of Base is refused even when the caller lists Base.
    tree = tagged(WeakKeyDict{Any,Any}, Dict{String,Any}("pairs" => Any[]))
    @test_throws "is not in the allowlist" decode(tree, SerdeContext((Base,); validate = v))
    # Dict and IdDict decode.
    for D in (Dict{String,Int}, IdDict{String,Int})
        @test decode(tagged(D, payload), SerdeContext(; validate = v)) == D("a" => 1)
    end
end

@testset "Base and Core give only their plain data types (validate=$v)" for v in
                                                                            (false, true)
    tree = tagged(Base.RefValue{Int}, Dict{String,Any}("x" => 1))
    @test_throws "not a plain data type of Base" decode(tree, SerdeContext(; validate = v))
    # Listing Base trusts all of it.
    @test decode(tree, SerdeContext((Base,); validate = v))[] == 1
    # A path through a listed module does not reach Base: `parentmodule(Base) === Main`.
    desc =
        Dict{String,Any}("module" => "Main.Base", "name" => "RefValue", "params" => Any[])
    @test_throws "not a plain data type of Base" TAS._resolve_type(
        desc,
        SerdeContext((Main,)),
    )
    # A module that a listed module only imports is not trusted.
    desc = Dict{String,Any}("module" => "Main.Test", "name" => "Pass", "params" => Any[])
    @test_throws "which is not in the allowlist" TAS._resolve_type(
        desc,
        SerdeContext((Main,)),
    )
    # The plain data types still round-trip with no modules at all.
    for x in Any[
        1.5,
        big"2",
        3//4,
        1+2im,
        "s",
        :s,
        'c',
        nothing,
        missing,
        1:3,
        range(0.0, 1.0; length = 5),
        (1, "a"),
        (; a = 1),
        1=>"a",
        Some(1),
        [1.0 2.0; 3.0 4.0],
        Dict(:a => [1, 2]),
        Vector{Real}[[1, 2.0]],
    ]
        @test structeq(roundtrip(x; validate = v).text, x)
    end
    load = v ? from_json : from_json_direct
    for T in (Float64, Vector{<:Real}, Union{Nothing,Int}, Union{})
        @test load(to_json(T)) === T
    end
end

@testset "Holder(sin) round-trips when sin is listed (issue #10)" begin
    js = to_json(Holder(sin); modules = (M,))
    for load in (from_json, from_json_direct)
        y = load(js; modules = (M,), functions = (sin,))
        @test y isa Holder{typeof(sin)}
        @test y.f === sin
    end
    # The same through the other formats.
    for (enc, decs) in (
        (to_yaml, (from_yaml, from_yaml_direct)),
        (to_toml, (from_toml, from_toml_direct)),
        (to_msgpack, (from_msgpack, from_msgpack_direct)),
    )
        data = enc(Holder(sin); modules = (M,))
        for load in decs
            @test load(data; modules = (M,), functions = (sin,)).f === sin
        end
    end
end
