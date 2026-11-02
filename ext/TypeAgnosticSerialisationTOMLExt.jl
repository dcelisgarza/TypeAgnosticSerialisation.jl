module TypeAgnosticSerialisationTOMLExt

using TypeAgnosticSerialisation: TypeAgnosticSerialisation
import TOML

# The top level of an encoded tree is always the tagged envelope (a Dict), so it is
# always a valid TOML table.
function TypeAgnosticSerialisation._render(::Val{:toml}, tree; kwargs...)
    io = IOBuffer()
    TOML.print(io, tree; kwargs...)
    return String(take!(io))
end

function TypeAgnosticSerialisation._parse(::Val{:toml}, str::AbstractString)
    return TOML.parse(String(str))
end

end # module
