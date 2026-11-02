module TypeAgnosticSerialisationJSONExt

using TypeAgnosticSerialisation: TypeAgnosticSerialisation
import JSON

function TypeAgnosticSerialisation._render(::Val{:json}, tree; kwargs...)
    return JSON.json(tree; kwargs...)
end

function TypeAgnosticSerialisation._parse(::Val{:json}, str::AbstractString)
    return JSON.parse(str; dicttype = Dict{String,Any})
end

end # module
