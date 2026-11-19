isdefined(@__MODULE__, :TestSerdeModule) || include("setup.jl")

# The top-level `encode(v, ctx)` writes a `"__meta__"` record beside the envelope: the Julia
# version, and the UUID and version of each package whose types the document names, and of
# TypeAgnosticSerialisation itself. The top-level `decode(tree, ctx)` warns when a recorded
# package is loaded at a breaking or an older version.

const TAS = TypeAgnosticSerialisation
const TAS_NAME = "TypeAgnosticSerialisation"

@testset "the record names Julia and TypeAgnosticSerialisation" begin
    tree = encode(1.5, SerdeContext())
    meta = tree["__meta__"]
    @test meta["julia"] == string(VERSION)
    @test meta["packages"][TAS_NAME]["version"] == string(pkgversion(TAS))
    @test meta["packages"][TAS_NAME]["uuid"] == string(Base.PkgId(TAS).uuid)
    # Base, Core and Main are no packages: they have no entry.
    @test sort(collect(keys(meta["packages"]))) == [TAS_NAME]
end

@testset "the record names each package whose types the document holds" begin
    x = Any[MsgPack.Extension(Int8(1), UInt8[2, 3]), Circle(1.0)]
    ctx = SerdeContext((MsgPack, M))
    meta = encode(x, ctx)["__meta__"]
    @test meta["packages"]["MsgPack"]["version"] == string(pkgversion(MsgPack))
    @test meta["packages"]["MsgPack"]["uuid"] == string(Base.PkgId(MsgPack).uuid)
    # `TestSerdeModule` is a module of `Main`, not a package.
    @test sort(collect(keys(meta["packages"]))) == ["MsgPack", TAS_NAME]
    # A type that only sits in a type parameter counts as well.
    meta = encode(Vector{MsgPack.Extension}[], ctx)["__meta__"]
    @test haskey(meta["packages"], "MsgPack")
end

@testset "the caller's context does not change" begin
    ctx = SerdeContext(M)
    encode(sample_scene(), ctx)
    @test ctx.seen === nothing
    # The three-argument form writes no record.
    @test !haskey(encode(1, Any, ctx), "__meta__")
end

@testset "every format carries the record: $(nameof(to))" for (to, from, from_direct) in (
    (to_json, from_json, from_json_direct),
    (to_yaml, from_yaml, from_yaml_direct),
    (to_toml, from_toml, from_toml_direct),
    (to_msgpack, from_msgpack, from_msgpack_direct),
)
    doc = to(MsgPack.Extension(Int8(1), UInt8[2]); modules = MsgPack)
    for load in (from, from_direct)
        x = load(doc; modules = MsgPack)
        @test x isa MsgPack.Extension
        @test (x.type, x.data) == (Int8(1), UInt8[2])
    end
end

@testset "a document from before v0.4.0 decodes with no check" begin
    ctx = SerdeContext(M)
    tree = encode(sample_scene(), ctx)
    delete!(tree, "__meta__")
    @test (@test_logs decode(tree, ctx)) isa Scene
end

# Set the recorded version of `TypeAgnosticSerialisation` in a fresh tree of `x`.
function tree_with_version(v, x = 1.5, ctx = SerdeContext())
    tree = encode(x, ctx)
    tree["__meta__"]["packages"][TAS_NAME]["version"] = v
    return tree
end

# The same, with a payload that the decode of a `Float64` cannot parse.
function broken_tree_with_version(v)
    tree = tree_with_version(v)
    tree["__value__"] = "one and a half"
    return tree
end

# A dict type whose `setindex!` is interrupted, to show that the decode does not wrap an
# `InterruptException`.
module VersionErrorTypes
struct InterruptDict{K,V} <: AbstractDict{K,V}
    InterruptDict{K,V}() where {K,V} = new{K,V}()
end
Base.setindex!(::InterruptDict, v, k) = throw(InterruptException())
end

@testset "a compatible version decodes with no warning" begin
    @test (@test_logs decode(tree_with_version(string(pkgversion(TAS))), SerdeContext())) ==
          1.5
end

@testset "a breaking or an older version warns and decodes" begin
    now = pkgversion(TAS)
    breaking = string(VersionNumber(now.major + 1, 0, 0))
    @test (@test_logs (:warn, r"a breaking version change") decode(
        tree_with_version(breaking),
        SerdeContext(),
    )) == 1.5
    # The same breaking part, a later patch: the loaded version is older.
    older = string(VersionNumber(now.major, now.minor, now.patch + 1))
    @test (@test_logs (:warn, r"an older version") decode(
        tree_with_version(older),
        SerdeContext(),
    )) == 1.5
end

@testset "a failed decode after a version change names the change" begin
    now = pkgversion(TAS)
    for (v, why) in (
        (VersionNumber(now.major + 1, 0, 0), "a breaking version change"),
        (VersionNumber(now.major, now.minor, now.patch + 1), "an older version"),
    )
        r = @test_logs (:warn, Regex(why)) @test_throws VersionChangeError decode(
            broken_tree_with_version(string(v)),
            SerdeContext(),
        )
        err = r.value
        @test err.error isa ArgumentError
        c = only(err.changes)
        @test c.package == TAS_NAME
        @test c.uuid == Base.PkgId(TAS).uuid
        @test (c.recorded, c.loaded, c.why) == (v, now, why)
        msg = sprint(showerror, err)
        @test startswith(msg, "VersionChangeError: ArgumentError: cannot parse")
        @test occursin(
            "the document was written with $(TAS_NAME) v$(v), and $(TAS_NAME) v$(now) " *
            "is loaded, $(why).",
            msg,
        )
    end
    # An error of the decode itself, such as a type that is not defined, is wrapped too.
    tree = tree_with_version(string(VersionNumber(now.major + 1, 0, 0)))
    tree["__type__"]["name"] = "NoSuchFloat"
    r = @test_logs (:warn,) @test_throws VersionChangeError decode(tree, SerdeContext())
    @test r.value.error isa ErrorException
    @test occursin("Core.NoSuchFloat is not defined", sprint(showerror, r.value))
end

@testset "a failed decode with no version change gives the error unchanged" begin
    @test_logs @test_throws ArgumentError decode(
        broken_tree_with_version(string(pkgversion(TAS))),
        SerdeContext(),
    )
    # A tree with no record, from before v0.4.0.
    tree = broken_tree_with_version(string(pkgversion(TAS)))
    delete!(tree, "__meta__")
    @test_logs @test_throws ArgumentError decode(tree, SerdeContext())
end

@testset "an interrupt of the decode is not wrapped" begin
    V = VersionErrorTypes
    ctx = SerdeContext(V; dicts = (V.InterruptDict,))
    breaking = string(VersionNumber(pkgversion(TAS).major + 1, 0, 0))
    tree = tree_with_version(breaking, Dict("a" => 1), ctx)
    tree["__type__"]["name"] = "InterruptDict"
    tree["__type__"]["module"] = string(V)
    @test_logs (:warn,) @test_throws InterruptException decode(tree, ctx)
end

@testset "the semver rule of a breaking change" begin
    bp = TAS._breaking_part
    @test bp(v"1.2.3") == bp(v"1.9.0")
    @test bp(v"1.2.3") != bp(v"2.0.0")
    @test bp(v"0.3.1") == bp(v"0.3.9")
    @test bp(v"0.3.1") != bp(v"0.4.0")
    @test bp(v"0.0.1") != bp(v"0.0.2")
end

@testset "a malformed record is skipped, never an error" begin
    ctx = SerdeContext()
    for meta in Any[
        3,
        Dict{String,Any}(),
        Dict{String,Any}("packages" => 3),
        Dict{String,Any}("packages" => Dict{String,Any}("X" => 3)),
        Dict{String,Any}(
            "packages" => Dict{String,Any}("X" => Dict{String,Any}("uuid" => "no")),
        ),
        Dict{String,Any}(
            "packages" => Dict{String,Any}(
                TAS_NAME => Dict{String,Any}(
                    "uuid" => string(Base.PkgId(TAS).uuid),
                    "version" => 3,
                ),
            ),
        ),
        # A package that is not loaded.
        Dict{String,Any}(
            "packages" => Dict{String,Any}(
                "NotLoaded" => Dict{String,Any}(
                    "uuid" => "00000000-0000-0000-0000-000000000001",
                    "version" => "9.0.0",
                ),
            ),
        ),
    ]
        tree = encode(1.5, ctx)
        tree["__meta__"] = meta
        @test (@test_logs decode(tree, ctx)) == 1.5
    end
end
