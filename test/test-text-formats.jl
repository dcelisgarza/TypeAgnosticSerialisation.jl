isdefined(@__MODULE__, :TestSerdeModule) || include("setup.jl")

# Every format is a package extension over the same plain tree, so every format must pass
# the same round-trip, allowlist and validation checks. `(to, from, from_direct)` per format.
const FORMATS = (
    "json" => (to_json, from_json, from_json_direct),
    "yaml" => (to_yaml, from_yaml, from_yaml_direct),
    "toml" => (to_toml, from_toml, from_toml_direct),
    "msgpack" => (to_msgpack, from_msgpack, from_msgpack_direct),
)

# Values chosen to stress each format: strings that YAML/TOML could misread as another
# type, every number width (MessagePack has no Float16), non-finite floats, big numbers,
# empty containers, and nested arrays.
const FORMAT_VALUES = Any[
    ["123", "true", "null", "yes", "1e5", "~", "", " lead", "a\nb", "2024-01-01", "ü∑"],
    Int8(-3),
    UInt8(250),
    UInt32(4_000_000_000),
    typemax(Int64),
    typemin(Int64),
    typemax(UInt64),
    Float16(1.5),
    Float16[0.1, -2.5],
    Float32(0.1),
    -0.0,
    5e-324,
    NaN,
    -Inf,
    big(2)^100,
    Int128(1)<<100,
    true,
    nothing,
    missing,
    (),
    (1, "a", :b),
    Int[],
    Dict{String,Any}(),
    Dict(1 => "a"),
    [1 2; 3 4],
    [[1, 2], [3]],
    'x',
    (a = 1, b = 2.0),
    Complex(1.0, 2.0),
    3//4,
    Any[nothing, missing, 1, "s"],
    # Abstract element types: a Union, a partially-applied UnionAll and a Vararg each
    # need their own type descriptor.
    Union{Missing,Float64}[1.0, missing],
    Vector{Vector{<:Real}}([[1], [2.0]]),
    Tuple[(1,), (1, "a")],
]

@testset "$name" for (name, (to, from, from_direct)) in FORMATS
    @testset "Scene (validate=$v)" for v in (false, true)
        scene = sample_scene()
        got = (v ? from : from_direct)(to(scene; modules = (M,)); modules = (M,))
        @test structeq(scene, got)
        @test got.shapes[1] isa Circle{Float64}
        @test got.shapes[2] isa Rect{Int}
        @test got.bg === green
    end

    @testset "value = $(repr(x))" for x in FORMAT_VALUES
        @test structeq(x, from(to(x)))
        @test structeq(x, from_direct(to(x)))
    end

    @testset "keyword constructor, opaque" begin
        @test structeq(
            KwOnly(; a = 1, b = 2),
            from(to(KwOnly(; a = 1, b = 2)); modules = M),
        )
        data = to(Doc("report", Handle()); modules = M, opaque = (Handle,))
        got = from(data; modules = M, opaque = (Handle,))
        @test got.title == "report"
        @test got.handle.ptr == C_NULL
    end

    @testset "allowlist" begin
        data = to(sample_scene(); modules = M)
        @test_throws ErrorException from(data; modules = ())
        @test_throws ErrorException from_direct(data; modules = ())
    end

    @testset "validated refuses a broken value, direct loads it" begin
        # A broken Circle (r < 0) made through the non-validating loader.
        broken = from_json_direct(
            replace(to_json(Circle(7.0); modules = M), "7.0" => "-7.0");
            modules = M,
        )
        data = to(broken; modules = M)
        @test_throws ErrorException from(data; modules = M)
        @test from_direct(data; modules = M).r == -7.0
    end
end

@testset "YAML refuses anchors/aliases" begin
    # A valid tree in which the same `params` list is reused through an alias.
    doc = """
    __type__:
      name: "Tuple"
      module: "Core"
      params:
        - type: &leaf {name: "Int64", module: "Core", params: []}
        - type: *leaf
    __value__: [1, 2]
    """
    @test_throws ErrorException from_yaml(doc)
    @test_throws ErrorException from_yaml_direct(doc)
    # The same document with the alias written out in full loads.
    @test from_yaml(
        replace(
            doc,
            "&leaf " => "",
            "*leaf" => "{name: \"Int64\", module: \"Core\", params: []}",
        ),
    ) === (1, 2)
end

@testset "format keyword arguments are forwarded" begin
    @test occursin('\n', to_json(Dict("a" => 1); pretty = 2))
    s = to_toml((b = 1, a = 2); sorted = true)
    @test from_toml(s) === (b = 1, a = 2)
    bytes = to_msgpack([1.0, 2.0])
    @test from_msgpack(view(bytes, 1:length(bytes))) == [1.0, 2.0]
end

@testset "core loads no backend; formats name the missing package" begin
    # Run in a fresh process with only the core loaded: no format package is pulled in,
    # and a format function fails with a message that says which package to load. The
    # system image of Julia 1.10 holds the TOML stdlib, so TOML is loaded before the core
    # there, and its extension loads with the core: that format must then work.
    project = dirname(Base.active_project())
    code = """
    before = Set(string(m) for m in values(Base.loaded_modules))
    using TypeAgnosticSerialisation
    loaded = Set(string(m) for m in values(Base.loaded_modules))
    @assert !any(in(setdiff(loaded, before)), ("JSON", "YAML", "TOML", "MsgPack"))
    for (f, pkg) in ((to_json, "JSON"), (to_yaml, "YAML"), (to_toml, "TOML"), (to_msgpack, "MsgPack"))
        msg = try
            f(1); ""
        catch e
            sprint(showerror, e)
        end
        if pkg in before
            @assert isempty(msg) msg
        else
            @assert occursin("import \$pkg", msg) msg
        end
    end
    print("ok")
    """
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$project -e $code`
    @test read(cmd, String) == "ok"
end
