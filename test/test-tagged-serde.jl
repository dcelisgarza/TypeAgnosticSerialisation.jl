isdefined(@__MODULE__, :TestSerdeModule) || include("setup.jl")

# ===========================================================================

@testset "core round-trip: Scene (validate=$v)" for v in (false, true)
    scene = sample_scene()
    r = roundtrip(scene; modules = (M,), validate = v)
    @test r.ok_tree
    @test r.ok_text
    # The whole point: abstract-typed fields return as the EXACT concrete types.
    for got in (r.tree, r.text)
        @test got isa Scene
        @test got.shapes[1] isa Circle{Float64}
        @test got.shapes[1].r == 1.5
        @test got.shapes[2] isa Rect{Int}
        @test (got.shapes[2].w, got.shapes[2].h) == (3, 4)
        @test got.shapes[3] isa Square
        @test got.bg === green
        @test got.meta["author"] == "ada"
    end
end

@testset "scalars & primitives round-trip" begin
    scalars = Any[
        0,
        -7,
        Int8(3),
        Int16(-4),
        Int32(5),
        UInt8(9),
        UInt16(10),
        UInt32(11),
        UInt64(12),
        3.14,
        Float32(2.5),
        Float16(1.5),
        true,
        false,
        "hello",
        "",
        :a_symbol,
        'x',
        Int128(2)^70,
        big"123456789012345678901234567890",
        big"1.5",
        1//3,
        Complex(1.0, -2.0),
        nothing,
        missing,
        (1, "two", :three),
        (a = 1, b = "two"),
        [1, 2, 3],
        Float64[],
        [1 2; 3 4],
        Any[1, "two", :three],
        Dict("x" => 1, "y" => 2),
    ]
    @testset "value = $(repr(x))" for x in scalars
        r = roundtrip(x; modules = ())
        @test r.ok_tree
        @test r.ok_text
    end

    @testset "non-finite floats: $(repr(x))" for x in (NaN, Inf, -Inf, NaN32, Inf32, -Inf16)
        r = roundtrip(x; modules = ())
        @test r.ok_tree
        @test r.ok_text
    end
end

@testset "enum round-trip" begin
    for c in instances(Color)
        r = roundtrip(c; modules = (M,))
        @test r.ok_tree
        @test r.ok_text
    end
    # A tag naming a non-existent member is refused.
    ctx = SerdeContext((M,))
    @test_throws ErrorException TypeAgnosticSerialisation._decode_plain(
        "not_a_color",
        Color,
        ctx,
    )
end

@testset "type values round-trip" begin
    ctx = SerdeContext((M,))
    typ(x) = decode(encode(x, ctx), ctx)
    @test typ(Int64) === Int64                 # leaf DataType
    @test typ(Union{}) === Union{}             # Bottom
    @test typ(Tuple{}) === Tuple{}             # empty-tuple special case
    @test typ(M.Circle) === M.Circle           # bare UnionAll wrapper
    @test typ(M.Rect{Int}) === M.Rect{Int}     # parametric DataType
    @test typ(Vector{Float64}) === Vector{Float64}  # value-valued type parameter (the `1`)
    # A field that itself holds a type round-trips too.
    struct_with_type = (kind = M.Circle, dims = Vector{Int})
    @test typ(struct_with_type) === struct_with_type
end

@testset "type-descriptor errors" begin
    ctx = SerdeContext((M,))
    # A value that is not a type, a TypeVar or a Vararg has no type descriptor.
    @test_throws ErrorException TypeAgnosticSerialisation._type_desc(1, ctx)
end

@testset "module allowlist" begin
    scene = sample_scene()
    js = to_json(scene; modules = (M,))
    # M not on the allowlist on the way back in -> resolution refused.
    @test_throws ErrorException from_json(js; modules = ())

    ctx = SerdeContext((M,))
    # Nested submodule whose root is allowed resolves (BigFloat lives in Base.MPFR).
    @test TypeAgnosticSerialisation._lookup_module("Base.MPFR", ctx) === Base.MPFR
    @test TypeAgnosticSerialisation._lookup_module("Base.GMP", ctx) === Base.GMP
    # Root not allowed, or a non-existent submodule of an allowed root -> error.
    @test_throws ErrorException TypeAgnosticSerialisation._lookup_module(
        "NoSuchModule",
        ctx,
    )
    @test_throws ErrorException TypeAgnosticSerialisation._lookup_module(
        "Base.NoSuchSubmodule",
        ctx,
    )
end

@testset "resolve-type errors" begin
    ctx = SerdeContext((M,))
    @test_throws ErrorException TypeAgnosticSerialisation._resolve_type(
        Dict{String,Any}("name" => "Nope", "module" => "Base", "params" => Any[]),
        ctx,
    )
    @test_throws ErrorException TypeAgnosticSerialisation._resolve_type(
        Dict{String,Any}("name" => "println", "module" => "Base", "params" => Any[]),
        ctx,
    )
end

@testset "validated invariant enforcement vs direct bypass" begin
    good = to_json(Circle(7.0); modules = (M,))
    bad = replace(good, "7.0" => "-7.0"; count = 1)   # tamper the radius negative

    # from_json (validated): the inner constructor's check fires -> load refused.
    @test_throws ErrorException from_json(bad; modules = (M,))
    # from_json_direct: no validation -> a broken value is materialised.
    broken = from_json_direct(bad; modules = (M,))
    @test broken isa Circle{Float64}
    @test broken.r == -7.0
end

@testset "validated rebuild at the exact type parameters" begin
    # The unparameterised constructor re-derives narrower parameters from the field values
    # (`Pair(1, "a")` is a `Pair{Int,String}`); the value must come back at the encoded type.
    for x in Any[
        Pair{Int,Any}(1, "a"),
        Pair{Real,AbstractString}(1, "x"),
        Vector{Pair{<:Integer}}([1 => "a", 0x02 => 3]),
        Circle{Real}(1),
        Some{Any}(1),
    ]
        r = roundtrip(x; modules = (M,), validate = true)
        @test r.ok_tree
        @test r.ok_text
    end
    # Validation still runs first: a negative radius is refused even at `Circle{Real}`.
    ctx = SerdeContext((M,))
    bad = encode(TypeAgnosticSerialisation._newbuild(Circle{Real}, Any[-1]), ctx)
    @test_throws ErrorException decode(bad, SerdeContext((M,); validate = true))
    # No parameterised constructor and no `convert` -> fail loudly, not a wrong type.
    loose = encode(TypeAgnosticSerialisation._newbuild(Loose{Real}, Any[1]), ctx)
    @test_throws ErrorException decode(loose, SerdeContext((M,); validate = true))
    @test decode(loose, ctx) isa Loose{Real}   # direct mode builds it with `new`
end

@testset "named function as a value (validate=$v)" for v in (false, true)
    # The type of a named function is a singleton with no constructor. The validated
    # decode gives back its one instance, the function itself.
    for x in Any[bump, Smoother(bump, 0.5), Any[bump, sin]]
        r = roundtrip(x; modules = (M,), validate = v)
        @test r.ok_tree
        @test r.ok_text
    end
    @test roundtrip(Smoother(bump, 0.5); modules = (M,), validate = v).text.kernel === bump
end

@testset "keyword-fallback constructor (KwOnly)" begin
    x = KwOnly(; a = 1, b = 2)
    for v in (false, true)
        r = roundtrip(x; modules = (M,), validate = v)
        @test r.ok_tree
        @test r.ok_text
    end
end

@testset "opaque handling (validate=$v)" for v in (false, true)
    # A live handle cannot be serialised structurally: without opting it out, encoding
    # fails loudly rather than emitting a broken artifact.
    @test_throws ErrorException to_json(Handle(); modules = (M,))
    @test_throws ErrorException to_json(Doc("report", Handle()); modules = (M,))

    # Marking the handle opaque lets the surrounding data round-trip; the handle itself is
    # skipped and rebuilt with its no-argument constructor.
    r = roundtrip(Doc("report", Handle()); modules = (M,), opaque = (Handle,), validate = v)
    @test r.ok_tree
    @test r.ok_text
    for got in (r.tree, r.text)
        @test got isa Doc
        @test got.title == "report"
        @test got.handle isa Handle
        @test got.handle.ptr == C_NULL
    end
end

@testset "opaque with no zero-arg constructor fails" begin
    ctx = SerdeContext((M,); opaque = (NoDefault,))
    tree = encode(NoDefault(5), ctx)          # placeholder only, ctor not called yet
    @test_throws ErrorException decode(tree, ctx)
    @test_throws ErrorException TypeAgnosticSerialisation._construct_opaque(NoDefault)
end

@testset "file save/load, $label" for (label, loader) in (
    "from_json (validated)" => from_json,
    "from_json_direct" => from_json_direct,
)
    scene = sample_scene()
    path = tempname() * ".json"
    # `modules = M` (a bare Module, not a tuple) exercises the single-Module constructor.
    open(io -> write(io, to_json(scene; modules = M, pretty = 2)), path, "w")
    reloaded = loader(read(path, String); modules = (M,))
    @test typeof(reloaded) === typeof(scene)
    @test structeq(scene, reloaded)
    rm(path)
end

@testset "text-agnostic core (TOML layer)" begin
    # The encode/decode core is text-agnostic. A concrete hint yields a bare structural
    # payload (no envelope), which for `Rect` is a plain table any TOML writer can render.
    ctx = SerdeContext((M,))
    r = Rect(3, 4)
    tree = encode(r, Rect{Int}, ctx)          # concrete hint -> {"w" => 3, "h" => 4}
    io = IOBuffer()
    TOML.print(io, tree)
    tree2 = TOML.parse(String(take!(io)))
    r2 = decode(tree2, Rect{Int}, ctx)
    @test structeq(r, r2)
end

@testset "decode/encode error branches" begin
    ctx = SerdeContext((M,))
    # Untagged payload with an abstract hint cannot be resolved.
    @test_throws ErrorException decode(Dict{String,Any}("w" => 1), M.AbstractShape, ctx)
    # A type with no encode/decode rule.
    @test_throws ErrorException TypeAgnosticSerialisation._encode_plain(
        C_NULL,
        Ptr{Cvoid},
        ctx,
    )
    @test_throws ErrorException TypeAgnosticSerialisation._decode_plain(
        "x",
        Ptr{Cvoid},
        ctx,
    )
    # #undef fields are unsupported.
    incomplete = ccall(:jl_new_struct_uninit, Any, (Any,), Rect{Any})
    @test_throws ErrorException encode(incomplete, ctx)
end

@testset "internal reconstruction guards" begin
    # Field-count mismatch (e.g. a truncated/oversized payload).
    @test_throws ErrorException TypeAgnosticSerialisation._newbuild(
        M.Rect{Int},
        Any[1, 2, 3],
    )
    # `new` cannot build a non-concrete type.
    @test_throws ErrorException TypeAgnosticSerialisation._new_impl(M.AbstractShape, ())
end

@testset "SerdeContext constructors" begin
    @test SerdeContext() isa SerdeContext
    @test SerdeContext(M) isa SerdeContext
    @test SerdeContext((M,)) isa SerdeContext
    @test SerdeContext(; modules = (M,)) isa SerdeContext
    # Base and Core are always present.
    ctx = SerdeContext()
    @test ctx.modules["Base"] === Base
    @test ctx.modules["Core"] === Core
end
