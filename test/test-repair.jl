isdefined(@__MODULE__, :TestSerdeModule) || include("setup.jl")

# A release of a package can change a type after a document was written. These tests
# write a document with the types of `RepairOld`, and read it with the types of the same
# name in `RepairNew`, as a later release would define them. Each test set uses types of
# its own, because a repair warning logs once for each type and change in a session.

module RepairOld
struct Circle{T}
    r::T
end
struct Disc{T}
    r::T
end
struct Ring
    r::Float64
end
struct Arc
    r::Float64
end
struct Named
    r::Float64
end
struct Point{T,S}
    x::T
    y::S
end
struct Box
    w::Float64
end
struct Grid{T}
    n::T
end
struct Bounded{T}
    x::T
end
struct Shift{T}
    x::T
end
struct Shape
    r::Float64
end
end

module RepairNew
Base.@kwdef struct Circle{T}
    r::T
    colour::String = "red"
end
Base.@kwdef struct Disc{T}
    r::T
    colour::String = "red"
end
struct Ring
    r::Float64
    colour::String
end
struct Arc end
Base.@kwdef struct Named
    radius::Float64 = 1.0
end
# A parameter removed: `y` is an `Int` now.
struct Point{T}
    x::T
    y::Int
end
# A first parameter added, with a new field.
Base.@kwdef struct Box{L}
    w::Float64
    tag::L = nothing
end
# A parameter added at the end, with a new field.
Base.@kwdef struct Grid{T,S}
    n::T
    s::S = nothing
end
# The bound of the parameter changed: the field of the old document has no tag.
struct Bounded{T<:AbstractFloat}
    x::T
end
# A constructor that builds another parameter than the one of the document.
Base.@kwdef struct Shift{T,S}
    x::T
    s::S = nothing
    Shift{T,S}(x, s) where {T,S} = new{T,S}(x, s)
end
Shift(x::Int, s) = Shift{Float64,typeof(s)}(float(x), s)
# Unchanged, for a document with no change.
struct Shape
    r::Float64
end
end

const OLD = string(RepairOld)
const NEW = string(RepairNew)

# Point each type of the tree from `RepairOld` to `RepairNew`.
function moved!(tree)
    if tree isa AbstractDict
        for (k, v) in tree
            if k == "module" && v == OLD
                tree[k] = NEW
            else
                moved!(v)
            end
        end
    elseif tree isa AbstractVector
        foreach(moved!, tree)
    end
    return tree
end
moved(x) = moved!(encode(x, SerdeContext(RepairOld)))

ctx(; kwargs...) = SerdeContext(RepairNew; kwargs...)
message(f) =
    try
        f()
        ""
    catch e
        sprint(showerror, e)
    end

@testset "a missing field with no repair is an error that names it" begin
    tree = moved(RepairOld.Circle(1.5))
    for validate in (true, false)
        msg = message(() -> decode(tree, ctx(; validate)))
        @test occursin("has no field `colour` for $(NEW).Circle{Float64}", msg)
        @test occursin("Pass `repair = true`", msg)
    end
end

@testset "repair fills a missing field from the keyword constructor" begin
    x = @test_logs (:warn, r"no field `colour`.*fills it with its default") decode(
        moved(RepairOld.Circle(1.5)),
        ctx(; validate = true, repair = true),
    )
    @test x isa RepairNew.Circle{Float64}
    @test (x.r, x.colour) == (1.5, "red")
end

@testset "every loader passes repair on: $(nameof(from))" for (to, from) in (
    (to_json, from_json),
    (to_yaml, from_yaml),
    (to_toml, from_toml),
)
    doc = replace(to(RepairOld.Disc(2.0); modules = RepairOld), OLD => NEW)
    @test_throws ErrorException from(doc; modules = RepairNew)
    x = from(doc; modules = RepairNew, repair = true)
    @test x isa RepairNew.Disc{Float64}
    @test (x.r, x.colour) == (2.0, "red")
end

@testset "the direct mode cannot fill a missing field" begin
    msg = message(() -> decode(moved(RepairOld.Circle(1.5)), ctx(; repair = true)))
    @test occursin("has no field `colour`", msg)
    @test occursin("Load with the validated mode and `repair = true`", msg)
end

@testset "a missing field with no default names the constructor that failed" begin
    msg = message(
        () -> decode(moved(RepairOld.Ring(1.0)), ctx(; validate = true, repair = true)),
    )
    @test occursin("has no field `colour` for $(NEW).Ring", msg)
    @test occursin("the keyword constructor `Ring(; r)` fails", msg)
    @test occursin("Give the field a default", msg)
end

@testset "an extra key is dropped with no warning unless repair is set" begin
    tree = moved(RepairOld.Arc(1.0))
    for validate in (true, false)
        @test (@test_logs decode(tree, ctx(; validate))) isa RepairNew.Arc
    end
    # Both modes drop the key with a warning.
    for validate in (true, false)
        @test (@test_logs (:warn, r"gives .*Arc the keys `r`.*drops them") decode(
            tree,
            ctx(; validate, repair = true),
        )) isa RepairNew.Arc
    end
end

@testset "a renamed field is a missing field and an extra key" begin
    tree = moved(RepairOld.Named(2.0))
    msg = message(() -> decode(tree, ctx(; validate = true)))
    @test occursin("has no field `radius`", msg)
    @test occursin("It has the keys `r`, which are no fields of $(NEW).Named", msg)
    @test occursin("A renamed field gives such a pair", msg)
    # The repair cannot see the rename: the default fills `radius`, and `r` is dropped.
    x = @test_logs (:warn, r"keys `r`") (:warn, r"no field `radius`") decode(
        tree,
        ctx(; validate = true, repair = true),
    )
    @test x.radius == 1.0
end

@testset "a removed parameter keeps the leading parameters" begin
    tree = moved(RepairOld.Point(1.0, 2))
    msg = message(() -> decode(tree, ctx()))
    @test occursin(
        "gives $(NEW).Point the parameters {Float64, Int64}, which do not fit its " *
        "definition $(NEW).Point{T}",
        msg,
    )
    @test occursin("Pass `repair = true`", msg)
    x = @test_logs (:warn, r"The decode uses .*Point\{Float64\}\.") decode(
        tree,
        ctx(; repair = true),
    )
    @test x isa RepairNew.Point{Float64}
    @test (x.x, x.y) == (1.0, 2)
    # The leading list is a `DataType`, so the validated mode gives the same value.
    y = decode(tree, ctx(; validate = true, repair = true))
    @test y isa RepairNew.Point{Float64}
    @test (y.x, y.y) == (1.0, 2)
end

@testset "a first parameter: the constructor finds it from the fields" begin
    tree = moved(RepairOld.Box(1.0))
    msg = message(() -> decode(tree, ctx(; validate = true)))
    @test occursin("gives $(NEW).Box no parameters", msg)
    x = @test_logs (:warn, r"no parameters.*finds the free parameters") (
        :warn,
        r"no field `tag`",
    ) decode(tree, ctx(; validate = true, repair = true))
    @test x isa RepairNew.Box{Nothing}
    @test (x.w, x.tag) == (1.0, nothing)
    msg = message(() -> decode(tree, ctx(; repair = true)))
    @test occursin("has free parameters, and the direct mode builds a struct", msg)
end

@testset "a parameter added at the end" begin
    tree = moved(RepairOld.Grid(3))
    @test occursin(
        "the parameters {Int64}, which do not fit its definition $(NEW).Grid{T, S}",
        message(() -> decode(tree, ctx(; validate = true))),
    )
    # Julia shows the partial type `Grid{Int64, S} where S` as `Grid{Int64}`.
    x = @test_logs (:warn, r"uses .*Grid\{Int64\}, and the constructor") (
        :warn,
        r"no field `s`",
    ) decode(tree, ctx(; validate = true, repair = true))
    @test x isa RepairNew.Grid{Int64,Nothing}
    @test (x.n, x.s) == (3, nothing)
end

@testset "a free parameter of an untagged field cannot be repaired" begin
    tree = moved(RepairOld.Bounded(1))
    msg = message(() -> decode(tree, ctx(; validate = true, repair = true)))
    @test occursin("the field `x` of $(NEW).Bounded uses a free parameter", msg)
    @test occursin("no type tag", msg)
end

@testset "the constructor must keep the leading parameters" begin
    tree = moved(RepairOld.Shift(1))
    msg = message(() -> decode(tree, ctx(; validate = true, repair = true)))
    @test occursin("the constructor of $(NEW).Shift built a $(NEW).Shift{Float64,", msg)
    @test occursin("which is not a $(NEW).Shift{Int64}.", msg)
end

@testset "a document with no change decodes the same with repair" begin
    tree = moved(RepairOld.Shape(1.0))
    for validate in (true, false), repair in (true, false)
        x = @test_logs decode(tree, ctx(; validate, repair))
        @test x isa RepairNew.Shape && x.r == 1.0
    end
    s = sample_scene()
    for validate in (true, false)
        back = @test_logs decode(
            encode(s, SerdeContext(M)),
            SerdeContext(M; validate, repair = true),
        )
        @test back isa Scene
        @test length(back.shapes) == length(s.shapes)
    end
end

@testset "a failed repair after a version change names the change" begin
    tree = moved(RepairOld.Ring(1.0))
    now = pkgversion(TypeAgnosticSerialisation)
    pkgs = tree["__meta__"]["packages"]["TypeAgnosticSerialisation"]
    pkgs["version"] = string(VersionNumber(now.major + 1, 0, 0))
    r =
        @test_logs (:warn, r"a breaking version change") @test_throws VersionChangeError decode(
            tree,
            ctx(; validate = true, repair = true),
        )
    msg = sprint(showerror, r.value)
    @test occursin("has no field `colour`", msg)
    @test occursin("a breaking version change", msg)
end

@testset "the positional form of v0.4.0 has repair = false" begin
    c = SerdeContext(M)
    old = SerdeContext(
        c.modules,
        c.plain_only,
        c.opaque,
        c.functions,
        c.function_types,
        c.dicts,
        c.validate,
        nothing,
    )
    @test !old.repair
    @test SerdeContext(M; repair = true).repair
end
