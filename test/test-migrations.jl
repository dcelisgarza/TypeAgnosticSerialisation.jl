isdefined(@__MODULE__, :TestSerdeModule) || include("setup.jl")

# A package declares a step for each release that changed one of its types
# (`TypeAgnosticSerialisation.migrations`). The two-argument `decode` applies the steps
# whose version is after the recorded version and not after the loaded one. The record
# names only a package, so these tests use the fixture package `MigrationFixture`, release
# 3.0.0, and write each document as an earlier release wrote it.

const FIXTURE_DIR = joinpath(@__DIR__, "MigrationFixture")
FIXTURE_DIR in LOAD_PATH || push!(LOAD_PATH, FIXTURE_DIR)
using MigrationFixture
const MF = MigrationFixture
const TASM = TypeAgnosticSerialisation

# A tree of `x`, with the recorded version `v` of the fixture.
function fixture_tree(x, v)
    tree = encode(x, SerdeContext(MF))
    tree["__meta__"]["packages"]["MigrationFixture"]["version"] = v
    return tree
end

# A `Circle` as release 1.0 wrote it: the type `OldCircle`, the fields `rad` and `border`.
function circle_v1(payload = Dict{String,Any}("rad" => 1.5, "border" => 0.1))
    tree = fixture_tree(MF.Circle(1.5, "blue"), "1.0.0")
    tree["__type__"]["name"] = "OldCircle"
    tree["__value__"] = payload
    return tree
end

decode_error(f) =
    try
        f()
        nothing
    catch e
        sprint(showerror, e)
    end

@testset "the macro declares the steps of the package that holds the call" begin
    m = which(TASM.migrations, Tuple{Val{:MigrationFixture}})
    @test m.module === MF
    steps = TASM.migrations(Val(:MigrationFixture))
    @test steps isa Tuple
    @test all(s -> s isa MigrationStep, steps)
    @test TASM.migrations(Val(:NoSuchPackage)) === ()
    # One step with no block.
    ex = @macroexpand @migrations RenameType(v"2.0.0", "A" => "B")
    @test Meta.isexpr(ex, :(=))
end

@testset "the steps of v1.5 and v2 bring an OldCircle of v1 to a Circle" begin
    tree = circle_v1()
    snapshot = deepcopy(tree)
    for ctx in (
        SerdeContext(MF),
        SerdeContext(MF; validate = true),
        SerdeContext(MF; validate = true, repair = true),
    )
        # No warning: the package declares its steps, and `RemoveField` drops `border`.
        x = @test_logs decode(tree, ctx)
        @test x isa MF.Circle{Float64}
        @test (x.radius, x.colour) == (1.5, "red")
    end
    # The caller's tree does not change.
    @test tree == snapshot
end

@testset "a step names a type as of its own release" begin
    # Release 1.5 wrote `r`: the step of v1.5 does not apply.
    tree = circle_v1(Dict{String,Any}("r" => 2.0, "border" => 0.1))
    tree["__meta__"]["packages"]["MigrationFixture"]["version"] = "1.5.0"
    x = decode(tree, SerdeContext(MF))
    @test (x.radius, x.colour) == (2.0, "red")
    # Release 2.0 wrote the current `Circle`: no step of v2 applies.
    tree = fixture_tree(MF.Circle(3.0, "blue"), "2.0.0")
    x = decode(tree, SerdeContext(MF))
    @test (x.radius, x.colour) == (3.0, "blue")
    # The rename of v2 does not apply to a document of v2.
    tree = circle_v1()
    tree["__meta__"]["packages"]["MigrationFixture"]["version"] = "2.0.0"
    @test occursin(
        "OldCircle is not defined",
        decode_error(() -> decode(tree, SerdeContext(MF))),
    )
end

@testset "a document with no record, or of the loaded release, gets no step" begin
    tree = circle_v1()
    delete!(tree, "__meta__")
    @test occursin(
        "OldCircle is not defined",
        decode_error(() -> decode(tree, SerdeContext(MF))),
    )
    tree = circle_v1()
    tree["__meta__"]["packages"]["MigrationFixture"]["version"] = "3.0.0"
    @test occursin(
        "OldCircle is not defined",
        decode_error(() -> decode(tree, SerdeContext(MF))),
    )
    # The three-argument form reads no record.
    tree = circle_v1()
    @test occursin(
        "OldCircle is not defined",
        decode_error(() -> decode(tree, Any, SerdeContext(MF))),
    )
end

@testset "a payload step applies to a value with no tag" begin
    tree = fixture_tree(MF.Frame(MF.Circle(1.0, "blue")), "1.0.0")
    tree["__value__"]["c"] = Dict{String,Any}("rad" => 4.0, "border" => 0.0)
    x = decode(tree, SerdeContext(MF))
    @test x isa MF.Frame
    @test (x.c.radius, x.c.colour) == (4.0, "red")
end

@testset "a parent step runs before the steps of its children" begin
    scene = MF.Scene(Any[MF.Circle(1.0, "blue")], 0.5)
    tree = fixture_tree(scene, "1.0.0")
    tree["__value__"]["scale"] = 50.0
    child = tree["__value__"]["shapes"]["data"][1]
    child["__type__"]["name"] = "OldCircle"
    child["__value__"] = Dict{String,Any}("rad" => 1.0, "border" => 0.0)
    x = decode(tree, SerdeContext(MF; validate = true))
    @test x.scale == 0.5
    @test only(x.shapes) isa MF.Circle{Float64}
    @test only(x.shapes).colour == "red"
    # Release 3.0 wrote a fraction: the step does not apply.
    tree = fixture_tree(scene, "3.0.0")
    @test decode(tree, SerdeContext(MF)).scale == 0.5
end

@testset "a step can move a type to another submodule of the package" begin
    tree = fixture_tree(MF.Square(2.0), "1.0.0")
    tree["__type__"]["module"] = "MigrationFixture.Shapes"
    @test decode(tree, SerdeContext(MF)) == MF.Square(2.0)
end

@testset "a parameter step changes the parameter list, also in a type parameter" begin
    tree = fixture_tree(MF.Swap(1, "x"), "2.0.0")
    reverse!(tree["__type__"]["params"])   # release 2.0 wrote `Swap{String,Int64}`
    x = decode(tree, SerdeContext(MF))
    @test x isa MF.Swap{Int,String}
    @test (x.a, x.b) == (1, "x")
    tree = fixture_tree([MF.Swap(1, "x")], "2.0.0")
    reverse!(tree["__type__"]["params"][1]["type"]["params"])
    x = decode(tree, SerdeContext(MF; validate = true))
    @test x isa Vector{MF.Swap{Int,String}}
end

@testset "a step reads the version record" begin
    tree = fixture_tree(MF.Stamp("old"), "2.0.0")
    delete!(tree["__value__"], "julia")
    @test decode(tree, SerdeContext(MF)).julia == string(VERSION)
end

@testset "the steps apply in every format" begin
    tree = circle_v1()
    x = from_json(JSON.json(tree); modules = MF)
    @test (x.radius, x.colour) == (1.5, "red")
end

@testset "a step that fails names the step" begin
    # A rename to a key that the payload already has.
    tree = circle_v1(Dict{String,Any}("rad" => 1.0, "r" => 2.0, "border" => 0.0))
    msg = decode_error(() -> decode(tree, SerdeContext(MF)))
    @test occursin("VersionChangeError", msg)
    @test occursin("renames the field `rad` of OldCircle to `r`", msg)
    @test occursin("has both keys", msg)
    tree = fixture_tree(MF.Broken(1.0), "2.0.0")
    msg = decode_error(() -> decode(tree, SerdeContext(MF)))
    @test occursin("the `Migration` of v3.0.0 for Broken fails: no step", msg)
    tree = fixture_tree(MF.NotDict(1.0), "2.0.0")
    msg = decode_error(() -> decode(tree, SerdeContext(MF)))
    @test occursin("for NotDict gives nothing, which is not a dict", msg)
    tree = fixture_tree(MF.BadParams(1.0), "2.0.0")
    msg = decode_error(() -> decode(tree, SerdeContext(MF)))
    @test occursin("for BadParams gives nothing, which is not a vector", msg)
end

@testset "a method that another module defines for a package is ignored" begin
    @eval TASM.migrations(::Val{:MsgPack}) = (RenameType(v"0.0.1", "A" => "B"),)
    try
        tree = encode(MsgPack.Extension(Int8(1), UInt8[2]), SerdeContext(MsgPack))
        x = @test_logs (:warn, r"is defined in Main, not in the package MsgPack") decode(
            tree,
            SerdeContext(MsgPack),
        )
        @test x isa MsgPack.Extension
    finally
        Base.delete_method(which(TASM.migrations, Tuple{Val{:MsgPack}}))
    end
end

@testset "the cache of the declared steps follows a new or a deleted method" begin
    # `MsgPack` declares no steps. The cache holds that, and must see a method added later.
    @test TASM._declared_steps_cached("MsgPack", MsgPack) === nothing
    @eval MsgPack $(TASM).migrations(::Val{:MsgPack}) = ()
    try
        @test TASM._declared_steps_cached("MsgPack", MsgPack) === ()
    finally
        Base.delete_method(which(TASM.migrations, Tuple{Val{:MsgPack}}))
    end
    @test TASM._declared_steps_cached("MsgPack", MsgPack) === nothing
end

@testset "the steps must be a tuple of steps" begin
    @test occursin("must give a tuple", decode_error(() -> TASM._check_steps((1,), "X")))
    @test occursin("must give a tuple", decode_error(() -> TASM._check_steps(1, "X")))
    @test TASM._check_steps([RemoveField(v"1.0.0", "T", "x")], "X") isa Vector
end

@testset "the constructors of the steps check the names" begin
    @test_throws ArgumentError RenameType(v"1.0.0", "A" => "A")
    @test_throws ArgumentError RenameField(v"1.0.0", "T", "a" => "a")
    @test_throws ArgumentError RemoveField(v"1.0.0", "T", "")
    s = RenameField(v"1.0.0", :T, :a => :b)
    @test (s.type, s.from, s.to) == ("T", "a", "b")
    s = AddField(v"1.0.0", "T", :x => 1)
    @test (s.name, s.value) == ("x", 1)
end

@testset "the positional form with repair has no plan" begin
    c = SerdeContext(M)
    old = SerdeContext(
        c.modules,
        c.plain_only,
        c.opaque,
        c.functions,
        c.function_types,
        c.dicts,
        c.validate,
        true,
        nothing,
    )
    @test old.repair
    @test old.plan === nothing
end
