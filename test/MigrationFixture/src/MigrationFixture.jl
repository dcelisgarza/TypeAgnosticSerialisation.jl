# A package for test/test-migrations.jl. The version record names only a package, with a
# UUID and a version, so the tests of the declared steps need one. This is release 3.0.0.
# The tests write documents as the earlier releases wrote them.
module MigrationFixture

using TypeAgnosticSerialisation

# v1.0: `OldCircle{T}(rad::T, border::Float64)`. v1.5: the field `rad` became `r`.
# v2.0: the type became `Circle`, `r` became `radius`, `colour` came, `border` went.
struct Circle{T}
    radius::T
    colour::String
end

# v1: `Shapes.Square`, in the submodule `Shapes`. v2: `Square`, in the package module.
struct Square
    side::Float64
end

# v3: `scale` is a fraction, not a percent.
struct Scene
    shapes::Vector{Any}
    scale::Float64
end

# A field with a concrete declared type, so that the document holds its value with no tag.
struct Frame
    c::Circle{Float64}
end

# v3: `Swap{B,A}` became `Swap{A,B}`.
struct Swap{A,B}
    a::A
    b::B
end

# v3: a field that a step fills from the version record.
struct Stamp
    julia::String
end

# Steps that fail or give a wrong value, for the tests of the errors.
struct Broken
    x::Float64
end
struct NotDict
    x::Float64
end
struct BadParams{T}
    x::T
end

@migrations begin
    RenameField(v"1.5.0", "OldCircle", "rad" => "r")
    RenameField(v"2.0.0", "Circle", "r" => "radius")
    RenameType(v"2.0.0", "OldCircle" => "Circle")
    AddField(v"2.0.0", "Circle", "colour" => "red")
    RemoveField(v"2.0.0", "Circle", "border")
    RenameType(v"2.0.0", "Shapes.Square" => "Square")
    Migration(v"3.0.0", "Scene") do payload, meta
        payload["scale"] = payload["scale"] / 100
        return payload
    end
    ParameterMigration(v"3.0.0", "Swap") do params
        return reverse(params)
    end
    Migration(v"3.0.0", "Stamp") do payload, meta
        payload["julia"] = meta["julia"]
        return payload
    end
    Migration((payload, meta) -> error("no step"), v"3.0.0", "Broken")
    Migration((payload, meta) -> nothing, v"3.0.0", "NotDict")
    ParameterMigration(params -> nothing, v"3.0.0", "BadParams")
end

end
